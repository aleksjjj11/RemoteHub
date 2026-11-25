//! Remote Hub hooks into the RustDesk engine, compiled only with the
//! `remote_hub` feature. Policy and the TLS bridge live in `libs/remote_hub`;
//! this file connects them to the engine's dial, listener and login paths.
//!
//! A Remote Hub build never talks to RustDesk rendezvous, relay or API
//! servers and never runs LAN discovery: `start_all` replaces the upstream
//! background loop, `dial` replaces every client connection path, and the
//! remaining upstream entry points (online query, LAN discovery, update check,
//! NAT test) bail out with `NETWORK_DENIED`.

use hbb_common::{
    allow_err, bail,
    config::{Config, CONNECT_TIMEOUT},
    log,
    password_security::{self as password, ApproveMode},
    socket_client::connect_tcp_local,
    tokio::{self, net::TcpListener},
    ResultType, Stream,
};
use remote_hub::{BridgeConfig, DialTarget, RemoteEndpoint, Role, TailnetOnlyPolicy, TlsBridge};
use std::{collections::HashMap, sync::Mutex};

/// "host" on a computer the owner explicitly turned into a host. Anything else,
/// including unset, is a controller that never listens.
pub const OPTION_ROLE: &str = "remote-hub-role";
/// "Y" while the owner allows remote access on a host. The local "Stop access"
/// button stores "N"; the value survives restarts.
pub const OPTION_HOST_ENABLED: &str = "remote-hub-host-enabled";
const ROLE_HOST: &str = "host";

pub fn role() -> Role {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return Role::Controller;
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if Config::get_option(OPTION_ROLE) == ROLE_HOST {
        Role::Host
    } else {
        Role::Controller
    }
}

pub fn policy() -> TailnetOnlyPolicy {
    TailnetOnlyPolicy::for_role(role())
}

/// True only on a host whose owner switched access on. Not routed through
/// `option2bool`, which treats an unknown empty option as enabled.
pub fn host_access_enabled() -> bool {
    role() == Role::Host && Config::get_option(OPTION_HOST_ENABLED) == "Y"
}

pub const NETWORK_DENIED: &str =
    "Remote Hub: RustDesk servers, relays, updates and LAN discovery are disabled";

/// Fails with `NETWORK_DENIED` while Remote Hub is active. Every upstream
/// HTTP entry point (API posts, the general request FFI, the TCP proxy,
/// TLS probes, downloads and updates) calls this before it dials, so the
/// only traffic a Remote Hub build sends goes through its TLS bridge.
pub fn deny_network() -> ResultType<()> {
    if is_active() {
        bail!("{}", NETWORK_DENIED);
    }
    Ok(())
}

/// Whether the upstream "Connection Error" box may reconnect automatically.
/// A message with a Remote Hub code is decided here, network failures retry
/// and everything else stops; plain transport errors (resets, timeouts) get
/// `None` and keep the upstream decision. The upstream text filter must not
/// see coded messages: "TCP connect failed" contains "failed", which it
/// never retries.
pub fn retry_decision(text: &str) -> Option<bool> {
    remote_hub::ErrorCode::from_message_prefix(text).map(|c| c.is_retryable())
}

/// A Remote Hub build always replaces the upstream network paths. A function
/// rather than `cfg!` so hooks read as early returns without dead-code noise.
pub fn is_active() -> bool {
    true
}

/// Only the owner's permanent host password unlocks a session: no click
/// approval, no one-time password, no hidden connection window.
pub fn host_password_ready() -> bool {
    password::approve_mode() == ApproveMode::Password
        && !password::temporary_enabled()
        && Config::has_permanent_password()
        && !password::hide_cm()
}

/// The host listener's own state, kept by the process that runs the loop.
/// The panel reports this rather than probing port 22118: another program on
/// that port would answer a probe while the Remote Hub bind failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListenerState {
    /// No listener loop answered: the host service is not running here.
    NotRunning,
    /// The loop runs, but access is off (or this computer is a controller).
    Stopped,
    /// Remote Hub itself holds 127.0.0.1:22118 and accepts connections.
    Listening,
    /// Access is on but the bind failed, e.g. another program owns the port.
    PortUnavailable,
}

impl ListenerState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotRunning => "not_running",
            Self::Stopped => "stopped",
            Self::Listening => "listening",
            Self::PortUnavailable => "port_unavailable",
        }
    }

    /// Unknown text (an older or foreign peer) is never read as listening.
    pub fn parse(text: &str) -> Self {
        match text {
            "stopped" => Self::Stopped,
            "listening" => Self::Listening,
            "port_unavailable" => Self::PortUnavailable,
            _ => Self::NotRunning,
        }
    }
}

/// State of one listener loop. Shared between the loop and whoever reports
/// it; `running` is false until a loop started in this process.
struct ListenerStatus {
    running: std::sync::atomic::AtomicBool,
    state: Mutex<ListenerState>,
    /// Sessions this loop accepted that have not ended yet.
    sessions: std::sync::atomic::AtomicUsize,
    /// Bumped at the start of every loop pass, before the loop reads whether
    /// access is enabled. A pass that starts after a change has seen it.
    passes: std::sync::atomic::AtomicU64,
    /// Serializes access changes to this loop (from the local panel and from
    /// every IPC connection) and counts them. A change stores its setting and
    /// waits for its confirmation while holding this, so no other change can
    /// store a different setting in between and make a confirmation stale.
    /// The count lets an unconfirmed allow be taken back only if no later
    /// change replaced it.
    changes: tokio::sync::Mutex<u64>,
}

/// Counts one accepted session for as long as it lives.
struct SessionGuard(&'static ListenerStatus);

impl SessionGuard {
    fn new(status: &'static ListenerStatus) -> Self {
        status
            .sessions
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Self(status)
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        self.0
            .sessions
            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

impl ListenerStatus {
    const fn new() -> Self {
        Self {
            running: std::sync::atomic::AtomicBool::new(false),
            state: Mutex::new(ListenerState::NotRunning),
            sessions: std::sync::atomic::AtomicUsize::new(0),
            passes: std::sync::atomic::AtomicU64::new(0),
            changes: tokio::sync::Mutex::const_new(0),
        }
    }

    fn sessions(&self) -> usize {
        self.sessions.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn passes(&self) -> u64 {
        self.passes.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn set(&self, state: ListenerState) {
        *self.state.lock().unwrap() = state;
    }

    /// `Some` only in the process that runs the loop.
    fn local(&self) -> Option<ListenerState> {
        if self.running.load(std::sync::atomic::Ordering::SeqCst) {
            Some(*self.state.lock().unwrap())
        } else {
            None
        }
    }
}

/// The production listener, run by `start_all` in the host service process.
static HOST_LISTENER: ListenerStatus = ListenerStatus::new();

/// Answer for the IPC query: the state of the loop in this process, or
/// `NotRunning` if this process does not run it.
pub fn listener_state_for_ipc() -> ListenerState {
    HOST_LISTENER.local().unwrap_or(ListenerState::NotRunning)
}

/// Last listener state the host service process (the IPC server) reported to
/// this UI process. Kept by the UI's existing IPC status loop
/// (`ui_interface::check_connect_status_`), which asks every second; no
/// runtime or connection is created for the panel.
static SERVICE_LISTENER: Mutex<ListenerState> = Mutex::new(ListenerState::NotRunning);

/// `None` when the IPC connection to the service is gone: the panel cannot
/// confirm a listener then.
pub fn note_service_listener(state: Option<&str>) {
    *SERVICE_LISTENER.lock().unwrap() =
        state.map_or(ListenerState::NotRunning, ListenerState::parse);
}

/// For the local host panel. The listener state comes from the loop itself:
/// in this process if it runs here, otherwise as last reported by the host
/// service over IPC. Never blocks and never creates a runtime.
pub fn host_status_json() -> String {
    let listener = panel_listener_state(&HOST_LISTENER);
    status_json(
        role(),
        panel_access_enabled(host_access_enabled(), listener),
        host_password_ready(),
        listener,
    )
}

fn panel_listener_state(local: &ListenerStatus) -> ListenerState {
    local
        .local()
        .unwrap_or_else(|| *SERVICE_LISTENER.lock().unwrap())
}

/// Access as the panel shows it: on when stored on in this process, and
/// also whenever the listener itself accepts or tries to, whatever this
/// process stored. The panel never says "off" (and so never keeps a new
/// password on screen) while the host listener accepts sessions.
fn panel_access_enabled(stored: bool, listener: ListenerState) -> bool {
    stored
        || matches!(
            listener,
            ListenerState::Listening | ListenerState::PortUnavailable
        )
}

fn status_json(
    role: Role,
    access_enabled: bool,
    password_ready: bool,
    listener: ListenerState,
) -> String {
    serde_json::json!({
        "role": if role == Role::Host { "host" } else { "controller" },
        "accessEnabled": access_enabled,
        "passwordReady": password_ready,
        "listening": listener == ListenerState::Listening,
        "listener": listener.as_str(),
    })
    .to_string()
}

/// Replaces `RendezvousMediator::start_all`: no rendezvous registration, NAT
/// test, sysinfo sync, updater or LAN listener. A host only gets the loopback
/// listener; a controller gets nothing.
pub async fn start_all() {
    let server = crate::server::new();
    host_listener(server, &HOST_LISTENER, host_access_enabled, || {
        Ok(policy().host_listen_addr()?)
    })
    .await;
}

/// Loopback-only direct listener for Tailscale Serve. Polls the role and the
/// local stop switch: stopping access closes the listener and every session.
/// `status` always says what this loop really holds.
async fn host_listener(
    server: crate::server::ServerPtr,
    status: &'static ListenerStatus,
    enabled: impl Fn() -> bool,
    listen_addr: impl Fn() -> ResultType<std::net::SocketAddr>,
) {
    let mut listener: Option<TcpListener> = None;
    let mut bind_failed = false;
    status.set(ListenerState::Stopped);
    status
        .running
        .store(true, std::sync::atomic::Ordering::SeqCst);
    loop {
        status
            .passes
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if !enabled() {
            if listener.take().is_some() {
                log::info!("Remote Hub host access stopped; listener closed");
                server.write().unwrap().close_connections();
            }
            status.set(ListenerState::Stopped);
            bind_failed = false;
            hbb_common::sleep(1.).await;
            continue;
        }
        let Some(l) = listener.as_mut() else {
            match listen_host_loopback(&listen_addr).await {
                Ok(l) => {
                    log::info!("Remote Hub host listening on {:?}", l.local_addr());
                    listener = Some(l);
                    status.set(ListenerState::Listening);
                    bind_failed = false;
                }
                Err(err) => {
                    if !bind_failed {
                        log::error!("Remote Hub host listener unavailable: {err}");
                    }
                    status.set(ListenerState::PortUnavailable);
                    bind_failed = true;
                    hbb_common::sleep(5.).await;
                }
            }
            continue;
        };
        match hbb_common::timeout(1000, l.accept()).await {
            Ok(Ok((stream, addr))) => {
                stream.set_nodelay(true).ok();
                let local_addr = match stream.local_addr() {
                    Ok(a) => a,
                    Err(err) => {
                        log::warn!("Remote Hub host: no local address: {err}");
                        continue;
                    }
                };
                let server = server.clone();
                let session = SessionGuard::new(status);
                tokio::spawn(async move {
                    let _session = session;
                    allow_err!(
                        crate::server::create_tcp_connection(
                            server,
                            Stream::from(stream, local_addr),
                            addr,
                            false,
                            crate::server::ConnectionMeta::default(),
                        )
                        .await
                    );
                });
            }
            Ok(Err(err)) => {
                hbb_common::throttled_log!(
                    std::time::Duration::from_secs(60),
                    warn,
                    "Remote Hub host accept failed: {err}"
                );
                hbb_common::sleep(0.1).await;
            }
            Err(_) => {}
        }
    }
}

/// How long a caller waits for the host listener to apply an access change.
/// The loop sees a change within about a second; ending sessions takes a few
/// more.
const ACCESS_APPLY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Waits until the listener loop behind `status` applied an access change
/// made before this call. Stopping counts only once the loop closed its
/// listener and every session it accepted has ended; allowing counts once the
/// loop listens or reports why it cannot. `Err` names what did not happen.
async fn wait_access_applied(
    status: &ListenerStatus,
    enabled: bool,
    timeout: std::time::Duration,
) -> ResultType<ListenerState> {
    let deadline = std::time::Instant::now() + timeout;
    let start = status.passes();
    loop {
        let Some(state) = status.local() else {
            bail!("the host listener is not running");
        };
        // Only a pass that began after the change has read it.
        if status.passes() > start {
            let applied = if enabled {
                matches!(
                    state,
                    ListenerState::Listening | ListenerState::PortUnavailable
                )
            } else {
                state == ListenerState::Stopped && status.sessions() == 0
            };
            if applied {
                return Ok(state);
            }
        }
        if std::time::Instant::now() >= deadline {
            if enabled {
                bail!("the host listener did not start");
            }
            bail!(
                "the host did not confirm that access stopped ({} session(s) still open)",
                status.sessions()
            );
        }
        hbb_common::sleep(0.05).await;
    }
}

fn store_host_access(enabled: bool) {
    Config::set_option(
        OPTION_HOST_ENABLED.to_owned(),
        if enabled { "Y" } else { "N" }.to_owned(),
    );
}

/// Run by the process that holds the host listener: stores the access switch
/// and returns only after the loop applied it. With no loop in this process
/// nothing accepts sessions here, so stopping succeeds and allowing fails. A
/// failed allow leaves access stored as off, so a listener that starts or
/// resumes later does not accept sessions the caller was told were refused.
async fn apply_host_access_here(enabled: bool) -> ResultType<()> {
    apply_access(
        &HOST_LISTENER,
        store_host_access,
        enabled,
        ACCESS_APPLY_TIMEOUT,
    )
    .await
    .map(|_| ())
}

/// Stores `enabled` with `store` and waits until the loop behind `status`
/// applied it. Allowing stores nothing unless the loop runs here; if the loop
/// then does not confirm, access is stored as off again and the loop is given
/// the time to close whatever it opened meanwhile.
///
/// Changes run one at a time (`ListenerStatus::changes`): a change waits for
/// the one in progress to be confirmed or reverted first, so a confirmed stop
/// means access is off when this returns. Returns the number of the change.
async fn apply_access(
    status: &ListenerStatus,
    store: impl Fn(bool),
    enabled: bool,
    timeout: std::time::Duration,
) -> ResultType<u64> {
    let mut changes = status.changes.lock().await;
    *changes += 1;
    let change = *changes;
    if status.local().is_none() {
        if enabled {
            bail!("the host listener is not running");
        }
        store(false);
        return Ok(change);
    }
    store(enabled);
    let result = wait_access_applied(status, enabled, timeout).await;
    if enabled {
        if let Err(err) = &result {
            store(false);
            if let Err(stop) = wait_access_applied(status, false, timeout).await {
                log::warn!("Remote Hub: allow failed ({err}); reverting it: {stop}");
            }
        }
    }
    result.map(|_| change)
}

/// Serializes the access changes this process requests, local or over IPC,
/// so two panels never race on the stored setting.
static HOST_ACCESS_CHANGES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Local "Stop access" / "Allow access" for the host panel. Returns only
/// after the host listener confirmed the change: on stop, its listener is
/// closed and every session it accepted has ended. If the listener runs in
/// another process (the host service) the change goes there over IPC; an
/// unreachable or silent service is an error and nothing is stored here, so
/// the panel never shows access as off while the service still accepts.
///
/// Runs on the caller's runtime; it never creates one.
pub async fn set_host_access(enabled: bool) -> ResultType<()> {
    let _one_at_a_time = HOST_ACCESS_CHANGES.lock().await;
    if HOST_LISTENER.local().is_some() {
        // Allowing waits for no new password to be on screen in any window;
        // it holds `_allowing` until done so none starts showing one
        // meanwhile. The leases live here because the listener does (see
        // `begin_password_display`).
        let _allowing = if enabled {
            Some(PASSWORD_DISPLAY.begin_allow(std::time::Instant::now())?)
        } else {
            None
        };
        return apply_host_access_here(enabled).await;
    }
    // The service checks the leases itself: they live there, shared by
    // every app process (`serve_access_request`).
    set_host_access_via_ipc(enabled).await
}

/// Runs `fut` on `runtime`, a runtime that already exists and is driven
/// elsewhere (the UI's IPC status loop), and blocks this synchronous caller
/// until it finishes. Creates no runtime, so it also works on a thread that
/// belongs to some other runtime. Errors if `runtime` drops the task.
pub fn complete_on<T, F>(runtime: &tokio::runtime::Handle, fut: F) -> ResultType<T>
where
    T: Send + 'static,
    F: std::future::Future<Output = ResultType<T>> + Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    runtime.spawn(async move {
        let _ = tx.send(fut.await);
    });
    rx.recv()
        .unwrap_or_else(|_| bail!("the runtime stopped before the operation finished"))
}

/// How long the host service holds an allow it applied for the UI before the
/// UI confirms it received the answer. Without that confirmation (the answer
/// was lost, the UI gave up or went away) the service stops access again on
/// its own: an allow the UI was not told succeeded never stays in effect.
const ACCESS_COMMIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// How long the UI waits for the service's answer. A failed allow is
/// reverted before the service answers: up to two waits.
const ACCESS_ANSWER_TIMEOUT: std::time::Duration =
    std::time::Duration::from_millis(2 * ACCESS_APPLY_TIMEOUT.as_millis() as u64 + 2_000);

async fn set_host_access_via_ipc(enabled: bool) -> ResultType<()> {
    let mut c = match crate::ipc::connect(1000, "").await {
        Ok(c) => c,
        Err(e) => {
            if enabled {
                store_host_access(false);
            }
            bail!("the host service is not reachable: {e}");
        }
    };
    let result = request_host_access(&mut c, enabled, ACCESS_ANSWER_TIMEOUT).await;
    // Keep this process's copy in step. A failed allow is never stored as
    // on here; the service takes it back itself (see `serve_access_request`)
    // because this process did not confirm it, so no second request (which
    // could fail as well) is needed to leave access off.
    match &result {
        Ok(()) => {
            store_host_access(enabled);
            if !enabled {
                // Confirmed closed: do not wait for the next status poll.
                note_service_listener(Some(ListenerState::Stopped.as_str()));
            }
        }
        Err(_) if enabled => store_host_access(false),
        Err(_) => {}
    }
    result
}

/// How long the UI waits for each answer of the host service to an options
/// read or write.
const OPTIONS_ANSWER_TIMEOUT_MS: u64 = 2_000;

/// Writes the host role and its restricted engine options (`changes`; an
/// empty value removes a key) to the process that holds the host settings
/// and returns only once it read them back unchanged. The upstream
/// `main_set_option` drops IPC write errors, so a host service that is not
/// running would leave the role and restrictions unsaved while the panel
/// showed success. Desktop only; this process stores them itself when it
/// runs the host listener.
pub async fn write_host_options(changes: HashMap<String, String>) -> ResultType<()> {
    if HOST_LISTENER.local().is_some() {
        for (key, value) in &changes {
            Config::set_option(key.clone(), value.clone());
        }
        return check_options_saved(&Config::get_options(), &changes);
    }
    let mut c = match crate::ipc::connect(1000, "").await {
        Ok(c) => c,
        Err(e) => bail!("the host service is not reachable; nothing was saved: {e}"),
    };
    let saved = write_options_over(&mut c, &changes, OPTIONS_ANSWER_TIMEOUT_MS).await?;
    // Keep this process's copy in step with what the service stored.
    Config::set_options(saved);
    Ok(())
}

/// The IPC part of [`write_host_options`]: reads the service's options,
/// writes them back with `changes` merged in (the service replaces the
/// whole set), and reads them again to confirm every change was stored.
/// Returns the options the service holds afterwards.
async fn write_options_over<T>(
    c: &mut crate::ipc::ConnectionTmpl<T>,
    changes: &HashMap<String, String>,
    timeout_ms: u64,
) -> ResultType<HashMap<String, String>>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    let mut merged = read_options_over(c, timeout_ms).await?;
    for (key, value) in changes {
        if value.is_empty() {
            merged.remove(key);
        } else {
            merged.insert(key.clone(), value.clone());
        }
    }
    c.send(&crate::ipc::Data::Options(Some(merged))).await?;
    match c.next_timeout(timeout_ms).await {
        Ok(Some(crate::ipc::Data::Options(None))) => {}
        Ok(Some(crate::ipc::Data::SecurityConfigError(error))) => {
            bail!("the host service refused the settings: {error}")
        }
        Ok(_) => bail!("the host service did not confirm the settings were saved"),
        Err(e) => bail!("the host service did not confirm the settings were saved: {e}"),
    }
    let saved = read_options_over(c, timeout_ms).await?;
    check_options_saved(&saved, changes)?;
    Ok(saved)
}

async fn read_options_over<T>(
    c: &mut crate::ipc::ConnectionTmpl<T>,
    timeout_ms: u64,
) -> ResultType<HashMap<String, String>>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    c.send(&crate::ipc::Data::Options(None)).await?;
    match c.next_timeout(timeout_ms).await {
        Ok(Some(crate::ipc::Data::Options(Some(options)))) => Ok(options),
        Ok(_) => bail!("the host service did not report its settings"),
        Err(e) => bail!("the host service did not report its settings: {e}"),
    }
}

fn check_options_saved(
    saved: &HashMap<String, String>,
    changes: &HashMap<String, String>,
) -> ResultType<()> {
    let mut missing: Vec<&str> = changes
        .iter()
        .filter(|(key, value)| saved.get(*key).map_or("", String::as_str) != value.as_str())
        .map(|(key, _)| key.as_str())
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    missing.sort_unstable();
    bail!("the host service did not store: {}", missing.join(", "))
}

/// UI side of an access change over IPC. An allow counts only once the
/// service answered success and this side confirmed it received that answer
/// (`RemoteHubAccessCommit`); the service stops access again otherwise.
async fn request_host_access<T>(
    c: &mut crate::ipc::ConnectionTmpl<T>,
    enabled: bool,
    timeout: std::time::Duration,
) -> ResultType<()>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    c.send(&crate::ipc::Data::RemoteHubSetAccess(enabled))
        .await?;
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        match c.next_timeout(left.as_millis() as u64).await {
            Ok(Some(crate::ipc::Data::RemoteHubAccessResult(error))) => {
                if !error.is_empty() {
                    bail!(error);
                }
                if enabled {
                    c.send(&crate::ipc::Data::RemoteHubAccessCommit)
                        .await
                        .map_err(|e| {
                            hbb_common::anyhow::anyhow!(
                                "could not confirm the allow to the host service: {e}"
                            )
                        })?;
                }
                return Ok(());
            }
            // Unrelated messages the service may push on this connection.
            Ok(Some(_)) => continue,
            Ok(None) => bail!("the host service closed the connection"),
            Err(e) => bail!("the host service did not answer: {e}"),
        }
    }
}

/// Service side of `Data::RemoteHubSetAccess`, answered on the connection it
/// came on. Run by the process that holds the host listener.
pub async fn serve_access_request<T>(stream: &mut crate::ipc::ConnectionTmpl<T>, enabled: bool)
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    serve_access_request_with(
        stream,
        &HOST_LISTENER,
        &PASSWORD_DISPLAY,
        store_host_access,
        enabled,
        ACCESS_APPLY_TIMEOUT,
        ACCESS_COMMIT_TIMEOUT,
    )
    .await
}

/// Applies the change, answers, and for an allow waits for the requester's
/// `RemoteHubAccessCommit`. Anything else (a lost answer, a closed
/// connection, silence) stops access again: the requester reports a failed
/// allow then, and access must not stay on behind its back.
///
/// An allow is refused while any app process shows a new password: every
/// process takes its display lease from `display` here, so this check covers
/// them all, and no lease starts until the allow is over.
async fn serve_access_request_with<T>(
    stream: &mut crate::ipc::ConnectionTmpl<T>,
    status: &ListenerStatus,
    display: &'static PasswordDisplay,
    store: impl Fn(bool),
    enabled: bool,
    apply_timeout: std::time::Duration,
    commit_timeout: std::time::Duration,
) where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    let allowing = if enabled {
        display.begin_allow(std::time::Instant::now()).map(Some)
    } else {
        Ok(None)
    };
    let (_allowing, result) = match allowing {
        Ok(guard) => (
            guard,
            apply_access(status, &store, enabled, apply_timeout).await,
        ),
        Err(err) => (None, Err(err)),
    };
    let answer = match &result {
        Ok(_) => String::new(),
        Err(err) => {
            log::warn!("Remote Hub access change not confirmed: {err}");
            err.to_string()
        }
    };
    let sent = stream
        .send(&crate::ipc::Data::RemoteHubAccessResult(answer))
        .await;
    let change = match result {
        Ok(change) if enabled => change,
        _ => {
            allow_err!(sent);
            return;
        }
    };
    let committed = match sent {
        Ok(()) => matches!(
            stream.next_timeout(commit_timeout.as_millis() as u64).await,
            Ok(Some(crate::ipc::Data::RemoteHubAccessCommit))
        ),
        Err(err) => {
            log::warn!("Remote Hub: could not answer an allow: {err}");
            false
        }
    };
    if !committed {
        let changes = status.changes.lock().await;
        if *changes != change {
            // A later change (a confirmed allow or a stop) replaced this one;
            // taking it back now would undo that change instead.
            log::warn!("Remote Hub: an unconfirmed allow was already replaced by a later change");
            return;
        }
        log::warn!("Remote Hub: the allow was not confirmed by the requester; stopping access");
        store(false);
        if let Err(err) = wait_access_applied(status, false, apply_timeout).await {
            log::error!("Remote Hub: taking back an unconfirmed allow: {err}");
        }
        drop(changes);
    }
}

/// How long a lease on showing a new host password lasts without renewal.
/// The panel renews it every few seconds and takes the password off its
/// screen before this runs out (`kHostPasswordLeaseTtl` in `host_panel.dart`).
pub const PASSWORD_DISPLAY_TTL: std::time::Duration = std::time::Duration::from_secs(10);

/// Coordinates "a new host password is on screen" with "access is allowed"
/// across every host panel of this app (all windows share this library).
/// A panel shows a new password only while it holds a live lease; access is
/// allowed only while no lease is live, and no lease starts while access is
/// on or being allowed. A window that dies without ending its lease blocks
/// allowing for at most `PASSWORD_DISPLAY_TTL`.
pub struct PasswordDisplay {
    inner: Mutex<PasswordDisplayState>,
}

struct PasswordDisplayState {
    next: i64,
    /// Lease and when it runs out. At most one: a newer password replaces
    /// the one another window shows, which is no longer valid.
    lease: Option<(i64, std::time::Instant)>,
    /// Access changes to "allowed" in flight.
    allowing: usize,
}

impl PasswordDisplayState {
    fn live_lease(&mut self, now: std::time::Instant) -> Option<i64> {
        match self.lease {
            Some((id, until)) if now < until => Some(id),
            Some(_) => {
                self.lease = None;
                None
            }
            None => None,
        }
    }
}

/// Held while access is being allowed; see `PasswordDisplay::begin_allow`.
pub struct AllowingAccess(&'static PasswordDisplay);

impl Drop for AllowingAccess {
    fn drop(&mut self) {
        self.0.inner.lock().unwrap().allowing -= 1;
    }
}

impl PasswordDisplay {
    pub const fn new() -> Self {
        Self {
            inner: Mutex::new(PasswordDisplayState {
                next: 1,
                lease: None,
                allowing: 0,
            }),
        }
    }

    /// A lease (> 0) to show a password just set, or 0 when access is on or
    /// being allowed: then the password must not be changed or shown.
    /// `access_enabled` is read under the lock: an allow stores "on" before
    /// its guard is released, so it is seen either way.
    pub fn begin(&self, access_enabled: impl FnOnce() -> bool, now: std::time::Instant) -> i64 {
        let mut s = self.inner.lock().unwrap();
        if s.allowing > 0 || access_enabled() {
            return 0;
        }
        let id = s.next;
        s.next += 1;
        s.lease = Some((id, now + PASSWORD_DISPLAY_TTL));
        id
    }

    /// Extends a live lease. False when it ran out, ended or was replaced:
    /// its password must leave the screen.
    pub fn renew(&self, lease: i64, now: std::time::Instant) -> bool {
        let mut s = self.inner.lock().unwrap();
        if s.live_lease(now) != Some(lease) {
            return false;
        }
        s.lease = Some((lease, now + PASSWORD_DISPLAY_TTL));
        true
    }

    pub fn end(&self, lease: i64) {
        let mut s = self.inner.lock().unwrap();
        if matches!(s.lease, Some((id, _)) if id == lease) {
            s.lease = None;
        }
    }

    /// Refuses while a new password is on screen; otherwise blocks new
    /// leases until the returned guard is dropped.
    pub fn begin_allow(&'static self, now: std::time::Instant) -> ResultType<AllowingAccess> {
        let mut s = self.inner.lock().unwrap();
        if s.live_lease(now).is_some() {
            bail!("a new host password is shown on this computer; hide it before allowing access");
        }
        s.allowing += 1;
        Ok(AllowingAccess(self))
    }
}

/// The leases of the process that holds the host listener. Panels in other
/// processes (each app instance is one) reach them over IPC, so a lease in
/// one instance blocks an allow from any other.
pub static PASSWORD_DISPLAY: PasswordDisplay = PasswordDisplay::new();

/// A request on `PASSWORD_DISPLAY` from another process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde_derive::Serialize, serde_derive::Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum PasswordDisplayOp {
    Begin,
    Renew(i64),
    End(i64),
}

/// The answer the service sends: the lease (> 0) or 0 for `Begin`, 1 or 0
/// for `Renew`, 0 for `End`.
fn apply_password_display_op(
    display: &PasswordDisplay,
    access_enabled: impl FnOnce() -> bool,
    op: PasswordDisplayOp,
    now: std::time::Instant,
) -> i64 {
    match op {
        PasswordDisplayOp::Begin => display.begin(access_enabled, now),
        PasswordDisplayOp::Renew(lease) => display.renew(lease, now) as i64,
        PasswordDisplayOp::End(lease) => {
            display.end(lease);
            0
        }
    }
}

/// Service side of `Data::RemoteHubPasswordDisplay`. A process that does not
/// hold the listener is not the authority: it grants nothing.
pub async fn serve_password_display<T>(
    stream: &mut crate::ipc::ConnectionTmpl<T>,
    op: PasswordDisplayOp,
) where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    let answer = if HOST_LISTENER.local().is_some() {
        apply_password_display_op(
            &PASSWORD_DISPLAY,
            host_access_enabled,
            op,
            std::time::Instant::now(),
        )
    } else {
        0
    };
    allow_err!(
        stream
            .send(&crate::ipc::Data::RemoteHubPasswordDisplayResult(answer))
            .await
    );
}

/// How long a panel waits for the service's answer on a lease. These calls
/// run on the UI thread; a slow or absent service hides the password.
const PASSWORD_DISPLAY_IPC_TIMEOUT_MS: u64 = 500;

/// UI side of `Data::RemoteHubPasswordDisplay`.
async fn request_password_display<T>(
    c: &mut crate::ipc::ConnectionTmpl<T>,
    op: PasswordDisplayOp,
    timeout_ms: u64,
) -> ResultType<i64>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + std::marker::Unpin,
{
    c.send(&crate::ipc::Data::RemoteHubPasswordDisplay(op))
        .await?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        match c.next_timeout(left.as_millis() as u64).await {
            Ok(Some(crate::ipc::Data::RemoteHubPasswordDisplayResult(v))) => return Ok(v),
            Ok(Some(_)) => continue,
            Ok(None) => bail!("the host service closed the connection"),
            Err(e) => bail!("the host service did not answer: {e}"),
        }
    }
}

/// Runs `op` where the leases live: here if this process holds the host
/// listener, else in the host service. An unreachable service answers 0:
/// no lease, nothing renewed, so no password is shown.
fn password_display(op: PasswordDisplayOp) -> i64 {
    if HOST_LISTENER.local().is_some() {
        return apply_password_display_op(
            &PASSWORD_DISPLAY,
            host_access_enabled,
            op,
            std::time::Instant::now(),
        );
    }
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        // The panel's status polling has started it long before.
        let wait = std::time::Duration::from_millis(200);
        let Some(runtime) = crate::ui_interface::ui_runtime(wait) else {
            log::warn!("Remote Hub: no UI runtime for a password lease");
            return 0;
        };
        let result = complete_on(&runtime, async move {
            let mut c = crate::ipc::connect(PASSWORD_DISPLAY_IPC_TIMEOUT_MS, "").await?;
            request_password_display(&mut c, op, PASSWORD_DISPLAY_IPC_TIMEOUT_MS).await
        });
        match result {
            Ok(v) => v,
            Err(err) => {
                hbb_common::throttled_log!(
                    std::time::Duration::from_secs(60),
                    warn,
                    "Remote Hub: password lease not reached: {err}"
                );
                0
            }
        }
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let _ = op;
        0
    }
}

pub fn begin_password_display() -> i64 {
    password_display(PasswordDisplayOp::Begin)
}

pub fn renew_password_display(lease: i64) -> bool {
    password_display(PasswordDisplayOp::Renew(lease)) == 1
}

pub fn end_password_display(lease: i64) {
    password_display(PasswordDisplayOp::End(lease));
}

/// Binds 127.0.0.1:22118 only. No SO_REUSEPORT and no wildcard fallback: if
/// the port is taken the host stays unreachable.
async fn listen_host_loopback(
    listen_addr: &impl Fn() -> ResultType<std::net::SocketAddr>,
) -> ResultType<TcpListener> {
    Ok(TcpListener::bind(listen_addr()?).await?)
}

/// Own config directory, IPC names and logs, so Remote Hub never shares state
/// with an installed RustDesk (plan 5.7, RH-009). Runs before any config read.
pub const APP_NAME: &str = "RemoteHub";

pub fn apply_app_identity() {
    *hbb_common::config::APP_NAME.write().unwrap() = APP_NAME.to_owned();
}

/// Replaces `hbb_common::init_log` in a Remote Hub build (plan 18.3): the
/// file logger rotates at 5 MiB and keeps 5 files, and files older than 7
/// days are deleted at start and every few hours. Nothing is uploaded.
/// Debug builds log to stderr like upstream.
pub fn init_log(name: &str) {
    #[cfg(debug_assertions)]
    {
        hbb_common::init_log(false, name);
    }
    #[cfg(not(debug_assertions))]
    {
        use hbb_common::flexi_logger::*;
        use remote_hub::log_retention::{prune_logs, MAX_LOG_FILES, MAX_LOG_FILE_BYTES};
        static INIT: std::sync::Once = std::sync::Once::new();
        INIT.call_once(|| {
            let mut dir = Config::log_path();
            #[cfg(target_os = "android")]
            if !Config::get_home().exists() {
                return;
            }
            if !name.is_empty() {
                dir.push(name);
            }
            allow_err!(prune_logs(&dir, std::time::SystemTime::now()));
            let Ok(logger) = Logger::try_with_env_or_str(
                "debug,reqwest=warn,hyper_util=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn,webrtc_ice::agent::agent_internal=error,webrtc::peer_connection=error,smithay_client_toolkit=warn",
            ) else {
                return;
            };
            let handle = logger
                .log_to_file(FileSpec::default().directory(&dir))
                .write_mode(WriteMode::Direct)
                // Appending lets [`delete_logs`] empty the open file in place.
                .append()
                .format(opt_format)
                .rotate(
                    Criterion::Size(MAX_LOG_FILE_BYTES),
                    Naming::Timestamps,
                    // The current file is the fifth.
                    Cleanup::KeepLogFiles(MAX_LOG_FILES - 1),
                )
                .start();
            match handle {
                Ok(handle) => {
                    // The logger stops when its handle is dropped.
                    std::mem::forget(handle);
                    let _ = std::thread::Builder::new()
                        .name("remote-hub-log-retention".to_owned())
                        .spawn(move || loop {
                            std::thread::sleep(std::time::Duration::from_secs(6 * 60 * 60));
                            allow_err!(prune_logs(&dir, std::time::SystemTime::now()));
                        });
                }
                Err(err) => eprintln!("Remote Hub: file logging unavailable: {err}"),
            }
        });
    }
}

/// Deletes the local diagnostic logs of all Remote Hub processes on the
/// owner's request (plan 18.3). Returns "" or a coded error.
pub fn delete_logs() -> String {
    match remote_hub::log_retention::delete_logs(&Config::log_path()) {
        Ok(_) => String::new(),
        Err(e) => format!(
            "{}: some log files could not be deleted: {e}",
            remote_hub::ErrorCode::InternalError
        ),
    }
}

/// Owner-approved endpoints by Remote Hub peer id. The peer id is the logical
/// device id, so upstream peer settings never attach to a loopback port.
static DEVICES: Mutex<Option<HashMap<String, RemoteEndpoint>>> = Mutex::new(None);
/// Live bridges by peer id, with the endpoint each one was opened for. Each
/// one closes itself (port and channels) when its engine session ends or after
/// the 15 s prepare timeout; finished entries are pruned on the next dial or
/// status read. A new dial never cuts another.
static BRIDGES: Mutex<Vec<(String, RemoteEndpoint, TlsBridge)>> = Mutex::new(Vec::new());

/// Per peer id: the salt and salted password hash (`h1`) of the last login the
/// host accepted. Lets the UI save a typed password only after the host took
/// it. Cleared on every `register_device`, i.e. before each new connect.
static ACCEPTED_LOGINS: Mutex<Option<HashMap<String, (String, Vec<u8>)>>> = Mutex::new(None);

/// How far the newest dial of a peer id got, for the connect stage the
/// owner sees. Cleared on every `register_device`, i.e. before each connect.
#[derive(Clone, Debug, PartialEq, Eq)]
enum DialStage {
    /// TLS to the host is being established and verified.
    Securing,
    /// The certificate was verified and the engine is connected to the bridge.
    Secured,
    /// The dial failed; the message starts with an error code.
    Failed(String),
}

static DIAL_STAGES: Mutex<Option<HashMap<String, DialStage>>> = Mutex::new(None);

fn note_dial_stage(peer_id: &str, stage: DialStage) {
    DIAL_STAGES
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .insert(peer_id.to_owned(), stage);
}

/// The newest dial of `peer_id` for the UI: "" before any dial of the
/// current connect, "securing", "secured", or "failed " and the message.
pub fn dial_stage(peer_id: &str) -> String {
    match DIAL_STAGES
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|m| m.get(peer_id))
    {
        None => String::new(),
        Some(DialStage::Securing) => "securing".to_owned(),
        Some(DialStage::Secured) => "secured".to_owned(),
        Some(DialStage::Failed(message)) => format!("failed {message}"),
    }
}

pub fn note_login_accepted(peer_id: &str, salt: &str, h1: &[u8]) {
    // A login without a password is recorded too (it counts for
    // [`login_done`]); [`login_accepted_with`] never matches it.
    if !is_peer_id(peer_id) {
        return;
    }
    ACCEPTED_LOGINS
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .insert(peer_id.to_owned(), (salt.to_owned(), h1.to_vec()));
}

/// True if the last accepted login of `peer_id` used exactly `password`.
pub fn login_accepted_with(peer_id: &str, password: &str) -> bool {
    use hbb_common::sha2::{Digest, Sha256};
    if password.is_empty() {
        return false;
    }
    let guard = ACCEPTED_LOGINS.lock().unwrap();
    let Some((salt, h1)) = guard.as_ref().and_then(|m| m.get(peer_id)) else {
        return false;
    };
    if h1.is_empty() {
        return false;
    }
    // Same derivation as the client's `handle_hash`.
    let mut hasher = Sha256::new();
    hasher.update(password);
    hasher.update(salt);
    hasher.finalize()[..] == h1[..]
}

/// True once the host accepted any login of `peer_id` since it was last
/// registered, whatever password the owner used (also one typed in the
/// viewer after the first was refused).
pub fn login_done(peer_id: &str) -> bool {
    ACCEPTED_LOGINS
        .lock()
        .unwrap()
        .as_ref()
        .map_or(false, |m| m.contains_key(peer_id))
}

/// Passwords handed from the Remote Hub UI to the next session of a peer id,
/// in process memory only. The viewer is opened without a password, so it
/// never travels in navigation or desktop window arguments, which upstream
/// prints at child window start.
static STAGED_PASSWORDS: Mutex<Option<HashMap<String, (String, std::time::Instant)>>> =
    Mutex::new(None);
/// A staged password the viewer did not pick up within this time is dropped.
const STAGED_PASSWORD_TTL: std::time::Duration = std::time::Duration::from_secs(60);

/// Hands `password` to the next session of `peer_id` (see [`take_staged_password`]).
pub fn stage_password(peer_id: &str, password: &str) {
    if !is_peer_id(peer_id) {
        return;
    }
    let mut guard = STAGED_PASSWORDS.lock().unwrap();
    let map = guard.get_or_insert_with(HashMap::new);
    map.retain(|_, (_, at)| at.elapsed() < STAGED_PASSWORD_TTL);
    if password.is_empty() {
        map.remove(peer_id);
    } else {
        map.insert(
            peer_id.to_owned(),
            (password.to_owned(), std::time::Instant::now()),
        );
    }
}

/// The password staged for `peer_id`, once: it is removed on read.
pub fn take_staged_password(peer_id: &str) -> Option<String> {
    let (password, at) = STAGED_PASSWORDS.lock().unwrap().as_mut()?.remove(peer_id)?;
    (at.elapsed() < STAGED_PASSWORD_TTL).then_some(password)
}

pub fn register_device(peer_id: &str, tailnet_ipv4: &str, tls_server_name: &str) -> ResultType<()> {
    if !is_peer_id(peer_id) {
        bail!(
            "{}: invalid Remote Hub device id",
            remote_hub::ErrorCode::InvalidDeviceConfig
        );
    }
    let endpoint = RemoteEndpoint::new(
        tailnet_ipv4,
        remote_hub::policy::SERVE_TLS_PORT,
        tls_server_name,
    )
    .map_err(|e| hbb_common::anyhow::anyhow!("{e}"))?;
    if let Some(accepted) = ACCEPTED_LOGINS.lock().unwrap().as_mut() {
        accepted.remove(peer_id);
    }
    if let Some(stages) = DIAL_STAGES.lock().unwrap().as_mut() {
        stages.remove(peer_id);
    }
    DEVICES
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .insert(peer_id.to_owned(), endpoint);
    Ok(())
}

/// Peer option holding the host display the owner chose for a device (the
/// name the host reports, never an index). The viewer selects it once the
/// host lists its displays.
pub const OPTION_PREFERRED_DISPLAY: &str = "remote-hub-display";
/// Upstream peer option the viewer reads for touch (direct) input.
const OPTION_TOUCH_MODE: &str = "touch-mode";
const MAX_DISPLAY_ID_LEN: usize = 64;

/// The saved device preferences, mapped to the per-peer settings the
/// upstream viewer reads when its session starts.
#[derive(Debug, PartialEq, Eq)]
struct ViewerPreferences {
    /// Upstream `image_quality`: "low", "balanced" or "best".
    image_quality: &'static str,
    touch_mode: bool,
    display: Option<String>,
}

impl ViewerPreferences {
    fn parse(quality: &str, input_mode: &str, display_id: &str) -> ResultType<Self> {
        let invalid = remote_hub::ErrorCode::InvalidDeviceConfig;
        let image_quality = match quality {
            "economy" => "low",
            "balanced" => "balanced",
            "quality" => "best",
            _ => bail!("{invalid}: unsupported quality"),
        };
        let touch_mode = match input_mode {
            "trackpad" => false,
            "touch" => true,
            _ => bail!("{invalid}: unsupported input mode"),
        };
        if display_id.len() > MAX_DISPLAY_ID_LEN || display_id.chars().any(char::is_control) {
            bail!("{invalid}: invalid display id");
        }
        Ok(Self {
            image_quality,
            touch_mode,
            display: (!display_id.is_empty()).then(|| display_id.to_owned()),
        })
    }

    fn apply_to(&self, config: &mut hbb_common::config::PeerConfig) {
        config.image_quality = self.image_quality.to_owned();
        let mut set = |key: &str, value: Option<String>| match value {
            Some(v) => {
                config.options.insert(key.to_owned(), v);
            }
            None => {
                config.options.remove(key);
            }
        };
        set(OPTION_TOUCH_MODE, self.touch_mode.then(|| "Y".to_owned()));
        set(OPTION_PREFERRED_DISPLAY, self.display.clone());
    }
}

/// Writes a device's saved viewer preferences (quality preset, input mode,
/// preferred display) into the peer settings of `peer_id`, which the viewer
/// loads when its session starts. Called before each connect, so the
/// device record, not a previous session, decides.
pub fn apply_viewer_preferences(
    peer_id: &str,
    quality: &str,
    input_mode: &str,
    display_id: &str,
) -> ResultType<()> {
    if !is_peer_id(peer_id) {
        bail!(
            "{}: invalid Remote Hub device id",
            remote_hub::ErrorCode::InvalidDeviceConfig
        );
    }
    let prefs = ViewerPreferences::parse(quality, input_mode, display_id)?;
    let mut config = hbb_common::config::PeerConfig::load(peer_id);
    prefs.apply_to(&mut config);
    config.store(peer_id);
    Ok(())
}

/// Remote Hub peer ids are `rh` + 32 lowercase hex digits (a UUID without dashes).
pub fn is_peer_id(id: &str) -> bool {
    id.len() == 34
        && id.starts_with("rh")
        && id[2..]
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn endpoint_of(peer_id: &str) -> Option<RemoteEndpoint> {
    DEVICES.lock().unwrap().as_ref()?.get(peer_id).cloned()
}

/// The only way a Remote Hub controller reaches a host: verify the TLS
/// endpoint first, then hand the engine the bridge's loopback address.
/// Errors start with the plan's error code so the UI can show it.
pub async fn dial(peer_id: &str) -> ResultType<Stream> {
    dial_with(&policy(), peer_id).await
}

/// Records how far the dial got for the connect stage, then returns it.
async fn dial_with(policy: &TailnetOnlyPolicy, peer_id: &str) -> ResultType<Stream> {
    let valid = is_peer_id(peer_id);
    if valid {
        note_dial_stage(peer_id, DialStage::Securing);
    }
    let result = dial_steps(policy, peer_id).await;
    if valid {
        note_dial_stage(
            peer_id,
            match &result {
                Ok(_) => DialStage::Secured,
                Err(err) => DialStage::Failed(err.to_string()),
            },
        );
    }
    result
}

async fn dial_steps(policy: &TailnetOnlyPolicy, peer_id: &str) -> ResultType<Stream> {
    policy.check_dial(DialTarget::TlsBridge)?;
    let Some(endpoint) = endpoint_of(peer_id) else {
        bail!(
            "{}: this device is not an approved Remote Hub device",
            remote_hub::ErrorCode::InvalidDeviceConfig
        );
    };
    let bridge = TlsBridge::open(&endpoint, BridgeConfig::default())
        .await
        .map_err(|e| hbb_common::anyhow::anyhow!("{e}"))?;
    let addr = bridge.engine_dial_address();
    // Peer-paced: a host that keeps ending sessions triggers a dial each time.
    log::trace!(
        "Remote Hub: TLS verified for {}",
        bridge.verified_server_name()
    );
    {
        let mut bridges = BRIDGES.lock().unwrap();
        bridges.retain(|(_, _, b)| !b.is_closed());
        bridges.push((peer_id.to_owned(), endpoint, bridge));
    }
    connect_tcp_local(addr, None, CONNECT_TIMEOUT).await
}

/// Server name whose certificate a live bridge of `peer_id` verified, or
/// empty when there is none. Drives the security indicator. A bridge opened
/// for an endpoint the device no longer has does not count.
pub fn verified_server_name(peer_id: &str) -> String {
    let current = endpoint_of(peer_id);
    let mut bridges = BRIDGES.lock().unwrap();
    // A bridge closes itself when its session ends; drop the finished ones.
    bridges.retain(|(_, _, b)| !b.is_closed());
    live_verified_name(
        bridges
            .iter()
            .filter(|(_, _, b)| !b.is_closed())
            .map(|(id, e, b)| (id.as_str(), e, b.verified_server_name())),
        peer_id,
        current.as_ref(),
    )
    .unwrap_or_default()
    .to_owned()
}

/// The newest live bridge of `peer_id` opened for its `current` endpoint.
fn live_verified_name<'a>(
    live: impl DoubleEndedIterator<Item = (&'a str, &'a RemoteEndpoint, &'a str)>,
    peer_id: &str,
    current: Option<&RemoteEndpoint>,
) -> Option<&'a str> {
    let current = current?;
    live.rev()
        .find(|(id, endpoint, _)| *id == peer_id && *endpoint == current)
        .map(|(_, _, name)| name)
}

/// The login `username` names the host's approved endpoint, like an upstream
/// direct-IP login, instead of the logical id the host does not know.
pub fn login_username(peer_id: &str) -> Option<String> {
    endpoint_of(peer_id).map(|e| e.socket_addr().to_string())
}

/// Held by tests that bind the fixed host port 127.0.0.1:22118, so they
/// do not run at the same time.
#[cfg(test)]
static HOST_PORT_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;

    /// The host-access FFI used to build its own runtime and `block_on`,
    /// which panics on a thread inside a runtime. It must reuse a runtime
    /// that already runs elsewhere.
    #[test]
    fn complete_on_uses_the_existing_runtime_even_from_a_runtime_thread() {
        let (handle_tx, handle_rx) = std::sync::mpsc::channel();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
        let ui = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            handle_tx.send(rt.handle().clone()).unwrap();
            rt.block_on(async {
                let _ = stop_rx.await;
            });
        });
        let existing = handle_rx.recv().unwrap();
        let ran_on = existing.clone();
        let caller = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let caller_thread = std::thread::current().id();
        let got = caller.block_on(async move {
            complete_on(&ran_on, async move {
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                Ok(std::thread::current().id())
            })
        });
        assert_ne!(got.unwrap(), caller_thread);
        stop_tx.send(()).unwrap();
        ui.join().unwrap();
    }

    #[test]
    fn complete_on_reports_a_stopped_runtime_instead_of_hanging() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let handle = rt.handle().clone();
        drop(rt);
        let err = complete_on(&handle, async { Ok(()) }).unwrap_err();
        assert!(err.to_string().contains("runtime stopped"), "{err}");
    }

    const ID: &str = "rh8a56e38bcfad44d9b0ad6e97eb38e496";

    fn controller() -> TailnetOnlyPolicy {
        TailnetOnlyPolicy::for_role(Role::Controller)
    }

    async fn dial_error(policy: &TailnetOnlyPolicy, peer: &str) -> String {
        match dial_with(policy, peer).await {
            Ok(_) => panic!("dial to {peer} must fail"),
            Err(err) => err.to_string(),
        }
    }

    /// Saved device preferences reach the settings the viewer reads (review
    /// finding: they were stored but never applied).
    #[test]
    fn viewer_preferences_map_to_the_upstream_peer_settings() {
        let mut config = hbb_common::config::PeerConfig::default();
        config
            .options
            .insert(OPTION_TOUCH_MODE.to_owned(), "Y".to_owned());
        config
            .options
            .insert(OPTION_PREFERRED_DISPLAY.to_owned(), "old".to_owned());
        ViewerPreferences::parse("economy", "trackpad", "")
            .unwrap()
            .apply_to(&mut config);
        assert_eq!(config.image_quality, "low");
        assert!(!config.options.contains_key(OPTION_TOUCH_MODE));
        assert!(!config.options.contains_key(OPTION_PREFERRED_DISPLAY));

        ViewerPreferences::parse("quality", "touch", "69734272")
            .unwrap()
            .apply_to(&mut config);
        assert_eq!(config.image_quality, "best");
        assert_eq!(config.options[OPTION_TOUCH_MODE], "Y");
        assert_eq!(config.options[OPTION_PREFERRED_DISPLAY], "69734272");
        assert_eq!(
            ViewerPreferences::parse("balanced", "trackpad", "")
                .unwrap()
                .image_quality,
            "balanced"
        );

        for (q, i, d) in [
            ("best", "trackpad", ""),
            ("balanced", "mouse", ""),
            ("balanced", "trackpad", "a\nb"),
        ] {
            let err = ViewerPreferences::parse(q, i, d).unwrap_err();
            assert!(
                err.to_string().starts_with("INVALID_DEVICE_CONFIG"),
                "{err}"
            );
        }
        assert!(ViewerPreferences::parse("balanced", "trackpad", &"x".repeat(65)).is_err());
        assert!(apply_viewer_preferences("100.101.102.20", "balanced", "trackpad", "").is_err());
    }

    /// The UI shows "checking the password" only once the dial got through
    /// TLS; a failed dial is reported with its code, and a new connect starts
    /// over (review finding: the stage advanced when the window opened).
    #[tokio::test]
    async fn dial_stage_reports_failures_and_resets_on_a_new_connect() {
        const PEER: &str = "rh00000000000000000000000000000d1a";
        assert_eq!(dial_stage(PEER), "", "no dial yet");
        // Not registered: the dial fails before any network access.
        let err = dial_error(&controller(), PEER).await;
        assert_eq!(dial_stage(PEER), format!("failed {err}"));
        assert!(dial_stage(PEER).starts_with("failed INVALID_DEVICE_CONFIG"));
        assert_eq!(
            dial_stage("rh00000000000000000000000000000d1b"),
            "",
            "other peers unaffected"
        );

        register_device(PEER, "100.101.102.20", "mac-a.example-tailnet.ts.net").unwrap();
        assert_eq!(dial_stage(PEER), "", "a new connect starts over");

        note_dial_stage(PEER, DialStage::Securing);
        assert_eq!(dial_stage(PEER), "securing");
        note_dial_stage(PEER, DialStage::Secured);
        assert_eq!(dial_stage(PEER), "secured");
    }

    #[test]
    fn only_the_password_the_host_accepted_counts_and_a_new_connect_resets() {
        use hbb_common::sha2::{Digest, Sha256};
        const PEER: &str = "rh00000000000000000000000000000a11";
        let h1 = |password: &str, salt: &str| {
            let mut h = Sha256::new();
            h.update(password);
            h.update(salt);
            h.finalize()[..].to_vec()
        };
        register_device(PEER, "100.101.102.20", "mac-a.example-tailnet.ts.net").unwrap();
        assert!(!login_accepted_with(PEER, "right"), "nothing accepted yet");

        note_login_accepted(PEER, "salt-1", &h1("right", "salt-1"));
        assert!(login_accepted_with(PEER, "right"));
        assert!(!login_accepted_with(PEER, "wrong"));
        assert!(!login_accepted_with(PEER, ""));
        assert!(!login_accepted_with(ID, "right"), "other peers unaffected");

        // A new connect must not reuse the previous session's acceptance.
        register_device(PEER, "100.101.102.20", "mac-a.example-tailnet.ts.net").unwrap();
        assert!(!login_accepted_with(PEER, "right"));

        // A login with no password has nothing to save, but it is a login.
        assert!(!login_done(PEER));
        note_login_accepted(PEER, "salt-2", &[]);
        assert!(!login_accepted_with(PEER, "right"));
        assert!(!login_accepted_with(PEER, ""));
        assert!(login_done(PEER));
        assert!(!login_done(ID), "other peers unaffected");

        // The owner corrects the password in the viewer: the session is
        // logged in, and only the corrected password matches.
        register_device(PEER, "100.101.102.20", "mac-a.example-tailnet.ts.net").unwrap();
        assert!(!login_done(PEER));
        note_login_accepted(PEER, "salt-3", &h1("corrected", "salt-3"));
        assert!(login_done(PEER));
        assert!(!login_accepted_with(PEER, "first-typed"));
        assert!(login_accepted_with(PEER, "corrected"));
    }

    #[test]
    fn a_staged_password_reaches_only_the_next_session_of_its_peer() {
        const PEER: &str = "rh00000000000000000000000000000b22";
        const OTHER: &str = "rh00000000000000000000000000000b33";
        assert_eq!(take_staged_password(PEER), None);
        stage_password(PEER, "secret");
        assert_eq!(take_staged_password(OTHER), None, "other peers unaffected");
        assert_eq!(take_staged_password(PEER).as_deref(), Some("secret"));
        assert_eq!(take_staged_password(PEER), None, "taken only once");

        // A newer stage replaces the older; an empty one clears it.
        stage_password(PEER, "old");
        stage_password(PEER, "new");
        assert_eq!(take_staged_password(PEER).as_deref(), Some("new"));
        stage_password(PEER, "old");
        stage_password(PEER, "");
        assert_eq!(take_staged_password(PEER), None);

        // Only Remote Hub peer ids are accepted.
        stage_password("127.0.0.1:52000", "secret");
        assert_eq!(take_staged_password("127.0.0.1:52000"), None);
    }

    /// Review finding: a second panel could allow access while the first
    /// still showed the new password. Showing and allowing now exclude each
    /// other across every panel of the app.
    #[test]
    fn a_shown_password_and_allowed_access_exclude_each_other() {
        use std::time::{Duration, Instant};
        let d: &'static PasswordDisplay = Box::leak(Box::new(PasswordDisplay::new()));
        let t0 = Instant::now();

        // No lease while access is on.
        assert_eq!(d.begin(|| true, t0), 0);

        // While a password is shown, no window can allow access.
        let lease = d.begin(|| false, t0);
        assert!(lease > 0);
        let err = d.begin_allow(t0 + Duration::from_secs(1)).err().unwrap();
        assert!(err.to_string().contains("hide it"), "{err}");

        // Renewal keeps it; past the TTL it is gone and cannot be renewed.
        let t1 = t0 + PASSWORD_DISPLAY_TTL - Duration::from_millis(1);
        assert!(d.renew(lease, t1));
        assert!(d
            .begin_allow(t1 + PASSWORD_DISPLAY_TTL - Duration::from_millis(1))
            .is_err());
        let late = t1 + PASSWORD_DISPLAY_TTL;
        assert!(!d.renew(lease, late));

        // A lease that ran out (a closed window) no longer blocks allowing,
        // and while an allow is in flight no password may be shown.
        let allowing = d.begin_allow(late).unwrap();
        assert_eq!(d.begin(|| false, late), 0);
        drop(allowing);

        // The allow stored "on" before releasing: a later begin sees it,
        // read under the lock.
        assert_eq!(d.begin(|| true, late), 0);

        // Hiding ends the lease at once.
        let lease = d.begin(|| false, late);
        d.end(lease);
        assert!(!d.renew(lease, late));
        drop(d.begin_allow(late).unwrap());

        // A newer password replaces the one another window shows.
        let first = d.begin(|| false, late);
        let second = d.begin(|| false, late);
        assert!(!d.renew(first, late));
        d.end(first);
        assert!(
            d.begin_allow(late).is_err(),
            "ending a stale lease keeps the new one"
        );
        assert!(d.renew(second, late));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn session_add_uses_the_staged_password_only_for_its_own_peer() {
        const PEER: &str = "rh00000000000000000000000000000c44";
        stage_password(PEER, "secret");
        assert_eq!(
            crate::flutter::remote_hub_session_password(PEER, String::new()),
            "secret"
        );
        // An explicit password wins and leaves nothing staged behind.
        stage_password(PEER, "secret");
        assert_eq!(
            crate::flutter::remote_hub_session_password(PEER, "typed".to_owned()),
            "typed"
        );
        assert_eq!(take_staged_password(PEER), None);
    }

    #[tokio::test]
    async fn a_host_never_dials() {
        let host = TailnetOnlyPolicy::for_role(Role::Host);
        register_device(ID, "100.101.102.20", "mac-a.example-tailnet.ts.net").unwrap();
        let err = dial_error(&host, ID).await;
        assert!(err.contains("not allowed"), "{err}");
    }

    #[test]
    fn peer_ids_are_logical_ids_not_addresses() {
        assert!(is_peer_id(ID));
        for bad in [
            "127.0.0.1:52000",
            "100.101.102.20",
            "123456789",
            "rh8A56E38BCFAD44D9B0AD6E97EB38E496",
            "rh8a56e38b-cfad-44d9-b0ad-6e97eb38e4",
            "",
        ] {
            assert!(!is_peer_id(bad), "{bad}");
        }
    }

    #[test]
    fn register_rejects_non_tailnet_or_bad_names() {
        assert!(register_device(ID, "192.168.1.5", "mac-a.example-tailnet.ts.net").is_err());
        assert!(register_device(ID, "100.101.102.20", "mac-a.local").is_err());
        assert!(register_device(
            "127.0.0.1:52000",
            "100.101.102.20",
            "mac-a.example-tailnet.ts.net"
        )
        .is_err());
        register_device(ID, "100.101.102.20", "mac-a.example-tailnet.ts.net").unwrap();
        assert_eq!(login_username(ID).as_deref(), Some("100.101.102.20:21118"));
    }

    #[tokio::test]
    async fn dial_refuses_unregistered_peers_instead_of_any_fallback() {
        for peer in [
            "123456789",
            "100.101.102.20",
            "example.com:21118",
            "rh00000000000000000000000000000000",
        ] {
            let err = dial_error(&controller(), peer).await;
            assert!(err.starts_with("INVALID_DEVICE_CONFIG"), "{peer}: {err}");
        }
    }

    #[tokio::test]
    async fn dial_to_an_unreachable_endpoint_fails_typed_without_fallback() {
        // 100.64.0.1 is a tailnet-range address; with no Tailscale route the
        // connect fails or times out, and nothing else is tried.
        let id = "rh0123456789abcdef0123456789abcdef";
        register_device(id, "100.64.0.1", "nobody.example-tailnet.ts.net").unwrap();
        let err = dial_error(&controller(), id).await;
        assert!(
            err.starts_with("ENDPOINT_UNREACHABLE") || err.starts_with("TLS_"),
            "{err}"
        );
        assert_eq!(verified_server_name(id), "");
    }

    #[test]
    fn verified_name_follows_the_current_endpoint() {
        let port = remote_hub::policy::SERVE_TLS_PORT;
        let old = RemoteEndpoint::new("100.64.0.1", port, "old.example-tailnet.ts.net").unwrap();
        let moved = RemoteEndpoint::new("100.64.0.2", port, "old.example-tailnet.ts.net").unwrap();
        let renamed =
            RemoteEndpoint::new("100.64.0.1", port, "new.example-tailnet.ts.net").unwrap();
        let live = [(ID, &old, "old.example-tailnet.ts.net")];
        let name = |current: Option<&RemoteEndpoint>| {
            live_verified_name(live.iter().copied(), ID, current)
        };
        assert_eq!(name(Some(&old)), Some("old.example-tailnet.ts.net"));
        // An edited device does not show the old endpoint's verification.
        assert_eq!(name(Some(&moved)), None);
        assert_eq!(name(Some(&renamed)), None);
        assert_eq!(name(None), None);
        assert_eq!(
            live_verified_name(live.iter().copied(), "rh-other", Some(&old)),
            None
        );
    }

    #[test]
    fn only_network_failures_reconnect() {
        assert_eq!(
            retry_decision("Connection reset by peer (os error 54)"),
            None
        );
        assert_eq!(
            retry_decision("ENDPOINT_UNREACHABLE: TCP connect timed out"),
            Some(true)
        );
        for text in [
            "TLS_NAME_MISMATCH: certificate not valid for name",
            "TLS_CERTIFICATE_INVALID: UnknownIssuer",
            "TLS_CERTIFICATE_EXPIRED: expired",
            "INVALID_DEVICE_CONFIG: this device is not an approved Remote Hub device",
            "HOST_BUSY: Another controller is connected",
        ] {
            assert_eq!(retry_decision(text), Some(false), "{text}");
        }
    }

    #[tokio::test]
    async fn host_listener_binds_loopback_only_and_does_not_share_the_port() {
        let _port = HOST_PORT_TESTS.lock().unwrap_or_else(|e| e.into_inner());
        let controller = || Ok(TailnetOnlyPolicy::for_role(Role::Controller).host_listen_addr()?);
        let err = listen_host_loopback(&controller).await.unwrap_err();
        assert!(err.to_string().contains("hosting is not allowed"), "{err}");

        let host = || Ok(TailnetOnlyPolicy::for_role(Role::Host).host_listen_addr()?);
        let listener = listen_host_loopback(&host).await.unwrap();
        assert_eq!(
            listener.local_addr().unwrap().to_string(),
            "127.0.0.1:22118"
        );
        assert!(listen_host_loopback(&host).await.is_err());
    }

    #[test]
    fn status_reports_the_listener_state_not_the_port() {
        let json = |state| -> serde_json::Value {
            serde_json::from_str(&status_json(Role::Host, true, true, state)).unwrap()
        };
        for state in [
            ListenerState::NotRunning,
            ListenerState::Stopped,
            ListenerState::PortUnavailable,
        ] {
            assert_eq!(json(state)["listening"], false, "{state:?}");
            assert_eq!(json(state)["listener"], state.as_str());
            assert_eq!(ListenerState::parse(state.as_str()), state);
        }
        assert_eq!(json(ListenerState::Listening)["listening"], true);
        assert_eq!(ListenerState::parse("accepting"), ListenerState::NotRunning);
        assert_eq!(ListenerState::parse(""), ListenerState::NotRunning);
    }

    /// The panel polls from the Flutter thread, which may be inside a Tokio
    /// runtime: the state must come from what the UI's IPC loop cached, not
    /// from a runtime created on the spot.
    #[tokio::test]
    async fn panel_reads_the_service_listener_inside_a_runtime() {
        let no_local_loop = ListenerStatus::new();
        note_service_listener(Some("port_unavailable"));
        assert_eq!(
            panel_listener_state(&no_local_loop),
            ListenerState::PortUnavailable
        );
        note_service_listener(Some("listening"));
        assert_eq!(
            panel_listener_state(&no_local_loop),
            ListenerState::Listening
        );
        note_service_listener(None);
        assert_eq!(
            panel_listener_state(&no_local_loop),
            ListenerState::NotRunning
        );
    }

    /// Stopping access is confirmed only once the loop closed its listener
    /// and every session it accepted ended (review finding: a stop that
    /// could not reach the host still looked successful).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_is_confirmed_only_after_listener_and_sessions_end() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        use tokio::time::{sleep, Duration};

        // No loop in this process: nothing to confirm with.
        let none: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        assert!(wait_access_applied(none, false, Duration::from_millis(200))
            .await
            .is_err());

        let addr = {
            let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            probe.local_addr().unwrap()
        };
        let status: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        let enabled = Arc::new(AtomicBool::new(true));
        let flag = enabled.clone();
        tokio::spawn(host_listener(
            crate::server::new(),
            status,
            move || flag.load(Ordering::SeqCst),
            move || Ok(addr),
        ));
        while status.local().is_none() {
            sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            wait_access_applied(status, true, Duration::from_secs(5))
                .await
                .unwrap(),
            ListenerState::Listening
        );

        // A session that does not end in time: stop is not confirmed.
        let session = SessionGuard::new(status);
        enabled.store(false, Ordering::SeqCst);
        let err = wait_access_applied(status, false, Duration::from_millis(2_500))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("1 session(s) still open"), "{err}");
        assert_eq!(status.local(), Some(ListenerState::Stopped));

        // Once it ends, the stop is confirmed and the port is closed.
        let ended = tokio::spawn(async move {
            sleep(Duration::from_millis(300)).await;
            drop(session);
        });
        assert_eq!(
            wait_access_applied(status, false, Duration::from_secs(5))
                .await
                .unwrap(),
            ListenerState::Stopped
        );
        ended.await.unwrap();
        assert_eq!(status.sessions(), 0);
        assert!(std::net::TcpStream::connect(addr).is_err());
    }

    /// A stale "Stopped" from before the change does not confirm it: the
    /// loop must have run a pass that read the new setting.
    #[tokio::test]
    async fn a_state_from_before_the_change_does_not_confirm_it() {
        let status: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        status.set(ListenerState::Stopped);
        status
            .running
            .store(true, std::sync::atomic::Ordering::SeqCst);
        // No pass happens: the loop is stuck, so nothing is confirmed.
        assert!(
            wait_access_applied(status, false, std::time::Duration::from_millis(200))
                .await
                .is_err()
        );
    }

    /// Review finding: a failed allow stored "enabled" anyway, so the
    /// listener could accept sessions once it started or resumed although
    /// the panel reported the allow as failed.
    #[tokio::test]
    async fn a_failed_allow_leaves_access_off() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        use std::time::Duration;

        // No listener in this process: nothing is stored as enabled.
        let none = ListenerStatus::new();
        let stored = Arc::new(AtomicBool::new(false));
        let flag = stored.clone();
        assert!(apply_access(
            &none,
            move |v| flag.store(v, Ordering::SeqCst),
            true,
            Duration::from_millis(200),
        )
        .await
        .is_err());
        assert!(!stored.load(Ordering::SeqCst));

        // A listener that does not confirm in time: access is reverted.
        let stuck = ListenerStatus::new();
        stuck.set(ListenerState::Stopped);
        stuck.running.store(true, Ordering::SeqCst);
        let flag = stored.clone();
        assert!(apply_access(
            &stuck,
            move |v| flag.store(v, Ordering::SeqCst),
            true,
            Duration::from_millis(200),
        )
        .await
        .is_err());
        assert!(!stored.load(Ordering::SeqCst));
    }

    /// A confirmed allow keeps access on; a stop without a listener here is
    /// stored and succeeds.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_confirmed_allow_keeps_access_on() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        use tokio::time::{sleep, Duration};

        let stored = Arc::new(AtomicBool::new(true));
        let flag = stored.clone();
        apply_access(
            &ListenerStatus::new(),
            move |v| flag.store(v, Ordering::SeqCst),
            false,
            Duration::from_millis(200),
        )
        .await
        .unwrap();
        assert!(!stored.load(Ordering::SeqCst));

        let addr = {
            let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            probe.local_addr().unwrap()
        };
        let status: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        let read = stored.clone();
        tokio::spawn(host_listener(
            crate::server::new(),
            status,
            move || read.load(Ordering::SeqCst),
            move || Ok(addr),
        ));
        while status.local().is_none() {
            sleep(Duration::from_millis(10)).await;
        }
        let flag = stored.clone();
        apply_access(
            status,
            move |v| flag.store(v, Ordering::SeqCst),
            true,
            Duration::from_secs(5),
        )
        .await
        .unwrap();
        assert!(stored.load(Ordering::SeqCst));
        assert_eq!(status.local(), Some(ListenerState::Listening));
        stored.store(false, Ordering::SeqCst);
    }

    /// Review finding: concurrent access changes each stored their setting
    /// and then waited for a shared listener state. A Stop could see the
    /// "Stopped" pass it caused, report success, and leave behind the "on"
    /// that a concurrent Allow stored meanwhile: the next pass reopened
    /// access. Changes now run one at a time, so a confirmed Stop means
    /// access is off when it returns.
    #[tokio::test(flavor = "current_thread")]
    async fn a_concurrent_allow_cannot_undo_a_confirmed_stop() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        use std::time::Duration;
        use tokio::time::sleep;

        // A loop whose passes the test runs by hand.
        let status: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        status.set(ListenerState::Listening);
        status.running.store(true, Ordering::SeqCst);
        let stored = Arc::new(AtomicBool::new(true));
        let pass = {
            let stored = stored.clone();
            move || {
                status.passes.fetch_add(1, Ordering::SeqCst);
                status.set(if stored.load(Ordering::SeqCst) {
                    ListenerState::Listening
                } else {
                    ListenerState::Stopped
                });
            }
        };

        // Stop: stores "off" and waits for a pass.
        let flag = stored.clone();
        let read = stored.clone();
        let stop = tokio::spawn(async move {
            let result = apply_access(
                status,
                move |v| flag.store(v, Ordering::SeqCst),
                false,
                Duration::from_secs(5),
            )
            .await;
            // Read before yielding: what the stop leaves behind.
            (result, read.load(Ordering::SeqCst))
        });
        sleep(Duration::from_millis(5)).await;
        // The loop reads "off" and closes.
        pass();
        // Another panel allows before the stop saw that pass.
        let flag = stored.clone();
        let allow = tokio::spawn(async move {
            apply_access(
                status,
                move |v| flag.store(v, Ordering::SeqCst),
                true,
                Duration::from_secs(5),
            )
            .await
        });
        sleep(Duration::from_millis(5)).await;
        let (result, on_at_return) = stop.await.unwrap();
        assert!(result.is_ok(), "{result:?}");
        assert!(
            !on_at_return,
            "the stop was confirmed while access was stored as on"
        );

        // The allow runs after the stop, as its own change.
        let looping = tokio::spawn(async move {
            loop {
                pass();
                sleep(Duration::from_millis(10)).await;
            }
        });
        allow.await.unwrap().unwrap();
        looping.abort();
        assert!(stored.load(Ordering::SeqCst));
        assert_eq!(status.local(), Some(ListenerState::Listening));
    }

    /// A host listener on a free loopback port, run by a test, whose access
    /// switch is the returned flag.
    async fn test_listener(
        enabled: bool,
    ) -> (
        &'static ListenerStatus,
        std::sync::Arc<std::sync::atomic::AtomicBool>,
    ) {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        let addr = {
            let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            probe.local_addr().unwrap()
        };
        let status: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        let stored = Arc::new(AtomicBool::new(enabled));
        let read = stored.clone();
        tokio::spawn(host_listener(
            crate::server::new(),
            status,
            move || read.load(Ordering::SeqCst),
            move || Ok(addr),
        ));
        while status.local().is_none() {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        (status, stored)
    }

    /// Review finding: the host service applied an allow but its answer
    /// was lost; the UI then reported a failure (and stored access off only
    /// in its own process) while the service kept accepting. The service now
    /// takes back any allow the requester did not confirm receiving.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_allow_the_requester_did_not_confirm_is_taken_back() {
        use crate::ipc::{ConnectionTmpl, Data};
        use std::sync::atomic::Ordering;
        use std::time::Duration;

        // The requester goes away without reading the answer (it timed out).
        let (status, stored) = test_listener(false).await;
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let mut service = ConnectionTmpl::new(service_end);
        drop(ui_end);
        let flag = stored.clone();
        serve_access_request_with(
            &mut service,
            status,
            fresh_display(),
            move |v| flag.store(v, Ordering::SeqCst),
            true,
            Duration::from_secs(5),
            Duration::from_millis(500),
        )
        .await;
        assert!(!stored.load(Ordering::SeqCst));
        assert_eq!(status.local(), Some(ListenerState::Stopped));

        // The requester reads the answer but never confirms it.
        let (status, stored) = test_listener(false).await;
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let mut service = ConnectionTmpl::new(service_end);
        let mut ui = ConnectionTmpl::new(ui_end);
        let flag = stored.clone();
        let serve = tokio::spawn(async move {
            serve_access_request_with(
                &mut service,
                status,
                fresh_display(),
                move |v| flag.store(v, Ordering::SeqCst),
                true,
                Duration::from_secs(5),
                Duration::from_millis(500),
            )
            .await
        });
        assert!(matches!(
            ui.next_timeout(10_000).await,
            Ok(Some(Data::RemoteHubAccessResult(e))) if e.is_empty()
        ));
        serve.await.unwrap();
        assert!(!stored.load(Ordering::SeqCst));
        assert_eq!(status.local(), Some(ListenerState::Stopped));
        drop(ui);
    }

    /// Review finding: an allow whose requester did not confirm it was
    /// taken back even when a later allow had been confirmed meanwhile,
    /// storing "off" behind that requester's back. Only an allow no later
    /// change replaced is taken back.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_later_confirmed_allow_is_not_taken_back() {
        use crate::ipc::{ConnectionTmpl, Data};
        use std::sync::atomic::Ordering;
        use std::time::Duration;

        let (status, stored) = test_listener(false).await;

        // First allow: the requester reads the answer but never confirms.
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let mut service = ConnectionTmpl::new(service_end);
        let mut silent = ConnectionTmpl::new(ui_end);
        let flag = stored.clone();
        let first = tokio::spawn(async move {
            serve_access_request_with(
                &mut service,
                status,
                fresh_display(),
                move |v| flag.store(v, Ordering::SeqCst),
                true,
                Duration::from_secs(5),
                Duration::from_millis(1_500),
            )
            .await
        });
        assert!(matches!(
            silent.next_timeout(10_000).await,
            Ok(Some(Data::RemoteHubAccessResult(e))) if e.is_empty()
        ));

        // Second allow, on another connection, confirmed by its requester.
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let mut service = ConnectionTmpl::new(service_end);
        let mut ui = ConnectionTmpl::new(ui_end);
        let flag = stored.clone();
        let second = tokio::spawn(async move {
            // The request itself is read by the IPC server loop.
            assert!(matches!(
                service.next_timeout(5_000).await,
                Ok(Some(Data::RemoteHubSetAccess(true)))
            ));
            serve_access_request_with(
                &mut service,
                status,
                fresh_display(),
                move |v| flag.store(v, Ordering::SeqCst),
                true,
                Duration::from_secs(5),
                Duration::from_secs(5),
            )
            .await
        });
        request_host_access(&mut ui, true, Duration::from_secs(10))
            .await
            .unwrap();
        second.await.unwrap();

        // The first allow's confirmation runs out after the second applied.
        first.await.unwrap();
        assert!(stored.load(Ordering::SeqCst));
        assert_eq!(status.local(), Some(ListenerState::Listening));
        stored.store(false, Ordering::SeqCst);
        drop((silent, ui));
    }

    /// A host service on `service`: answers option reads with `stored`
    /// and stores option writes unless `drop_writes`, as `ipc::handle` does.
    async fn serve_options(
        mut service: crate::ipc::ConnectionTmpl<tokio::io::DuplexStream>,
        mut stored: HashMap<String, String>,
        drop_writes: bool,
    ) -> HashMap<String, String> {
        use crate::ipc::Data;
        while let Ok(Some(data)) = service.next_timeout(5_000).await {
            match data {
                Data::Options(None) => service
                    .send(&Data::Options(Some(stored.clone())))
                    .await
                    .unwrap(),
                Data::Options(Some(v)) => {
                    if !drop_writes {
                        stored = v;
                    }
                    service.send(&Data::Options(None)).await.unwrap()
                }
                _ => break,
            }
        }
        stored
    }

    fn host_changes() -> HashMap<String, String> {
        HashMap::from([
            (OPTION_ROLE.to_owned(), ROLE_HOST.to_owned()),
            (OPTION_HOST_ENABLED.to_owned(), "N".to_owned()),
            ("enable-file-transfer".to_owned(), "N".to_owned()),
            ("stale-key".to_owned(), "".to_owned()),
        ])
    }

    /// The host role and restrictions are merged into the service's own
    /// options, an empty value removes a key, and other keys survive.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn host_options_are_merged_and_read_back() {
        use crate::ipc::ConnectionTmpl;
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let before = HashMap::from([
            ("custom-key".to_owned(), "kept".to_owned()),
            ("stale-key".to_owned(), "old".to_owned()),
        ]);
        let service = tokio::spawn(serve_options(
            ConnectionTmpl::new(service_end),
            before,
            false,
        ));
        let mut ui = ConnectionTmpl::new(ui_end);
        let saved = write_options_over(&mut ui, &host_changes(), 2_000)
            .await
            .unwrap();
        drop(ui);
        let stored = service.await.unwrap();
        assert_eq!(saved, stored);
        assert_eq!(stored.get(OPTION_ROLE).map(String::as_str), Some(ROLE_HOST));
        assert_eq!(stored.get("custom-key").map(String::as_str), Some("kept"));
        assert!(!stored.contains_key("stale-key"));
    }

    /// Review finding: host setup went through `main_set_option`, which
    /// drops IPC write errors, so the panel showed success when the host
    /// service had stored nothing.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn host_options_the_service_did_not_store_are_reported() {
        use crate::ipc::ConnectionTmpl;
        // The service acknowledges the write but keeps its old options.
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let service = tokio::spawn(serve_options(
            ConnectionTmpl::new(service_end),
            HashMap::new(),
            true,
        ));
        let mut ui = ConnectionTmpl::new(ui_end);
        let err = write_options_over(&mut ui, &host_changes(), 2_000)
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("did not store"), "{err}");
        assert!(err.contains(OPTION_ROLE), "{err}");
        drop(ui);
        service.await.unwrap();

        // The service went away: nothing is reported as saved.
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        drop(service_end);
        let mut ui = ConnectionTmpl::new(ui_end);
        assert!(write_options_over(&mut ui, &host_changes(), 500)
            .await
            .is_err());

        // The service refuses the write.
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let refuse = tokio::spawn(async move {
            use crate::ipc::Data;
            let mut service = ConnectionTmpl::new(service_end);
            let _ = service.next_timeout(5_000).await;
            service
                .send(&Data::Options(Some(HashMap::new())))
                .await
                .unwrap();
            let _ = service.next_timeout(5_000).await;
            service
                .send(&Data::SecurityConfigError("denied".to_owned()))
                .await
                .unwrap();
        });
        let mut ui = ConnectionTmpl::new(ui_end);
        let err = write_options_over(&mut ui, &host_changes(), 2_000)
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("refused"), "{err}");
        refuse.await.unwrap();
    }

    fn fresh_display() -> &'static PasswordDisplay {
        Box::leak(Box::new(PasswordDisplay::new()))
    }

    /// Review finding: leases were kept per app process, and the host
    /// service applied an allow from another instance without looking at
    /// them, so one instance could show a new password while another allowed
    /// access. Leases now live in the service, which refuses the allow.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_allow_from_another_process_is_refused_while_a_password_is_shown() {
        use crate::ipc::{ConnectionTmpl, Data};
        use std::sync::atomic::Ordering;
        use std::time::Duration;

        let (status, stored) = test_listener(false).await;
        let display = fresh_display();

        // Instance A takes a lease from the service over IPC.
        let access_off = stored.clone();
        let lease = {
            let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
            let mut service = ConnectionTmpl::new(service_end);
            let mut ui = ConnectionTmpl::new(ui_end);
            let serve = tokio::spawn(async move {
                let Ok(Some(Data::RemoteHubPasswordDisplay(op))) =
                    service.next_timeout(5_000).await
                else {
                    panic!("no lease request");
                };
                let v = apply_password_display_op(
                    display,
                    || access_off.load(Ordering::SeqCst),
                    op,
                    std::time::Instant::now(),
                );
                service
                    .send(&Data::RemoteHubPasswordDisplayResult(v))
                    .await
                    .unwrap();
            });
            let lease = request_password_display(&mut ui, PasswordDisplayOp::Begin, 5_000)
                .await
                .unwrap();
            serve.await.unwrap();
            lease
        };
        assert!(lease > 0);

        // Instance B asks the service to allow access: refused, nothing stored.
        let allow = |stored: std::sync::Arc<std::sync::atomic::AtomicBool>| async move {
            let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
            let mut service = ConnectionTmpl::new(service_end);
            let mut ui = ConnectionTmpl::new(ui_end);
            let serve = tokio::spawn(async move {
                let _ = service.next_timeout(5_000).await;
                serve_access_request_with(
                    &mut service,
                    status,
                    display,
                    move |v| stored.store(v, Ordering::SeqCst),
                    true,
                    Duration::from_secs(5),
                    Duration::from_secs(5),
                )
                .await
            });
            let result = request_host_access(&mut ui, true, Duration::from_secs(15)).await;
            serve.await.unwrap();
            result
        };
        let err = allow(stored.clone()).await.unwrap_err();
        assert!(err.to_string().contains("password is shown"), "{err}");
        assert!(!stored.load(Ordering::SeqCst));
        assert_eq!(status.local(), Some(ListenerState::Stopped));

        // Once A hides it, B's allow goes through, and no lease starts then.
        assert_eq!(
            apply_password_display_op(
                display,
                || false,
                PasswordDisplayOp::End(lease),
                std::time::Instant::now()
            ),
            0
        );
        allow(stored.clone()).await.unwrap();
        assert!(stored.load(Ordering::SeqCst));
        assert_eq!(
            apply_password_display_op(
                display,
                || stored.load(Ordering::SeqCst),
                PasswordDisplayOp::Begin,
                std::time::Instant::now()
            ),
            0
        );
    }

    /// Renewing answers 1 only for the live lease; the wire format is the
    /// one the UI decodes.
    #[test]
    fn password_display_ops_answer_over_the_wire_shape() {
        let d = PasswordDisplay::new();
        let now = std::time::Instant::now();
        let lease = apply_password_display_op(&d, || false, PasswordDisplayOp::Begin, now);
        assert!(lease > 0);
        assert_eq!(
            apply_password_display_op(&d, || false, PasswordDisplayOp::Renew(lease), now),
            1
        );
        assert_eq!(
            apply_password_display_op(&d, || false, PasswordDisplayOp::Renew(lease + 1), now),
            0
        );
        let data = crate::ipc::Data::RemoteHubPasswordDisplay(PasswordDisplayOp::Renew(lease));
        let json = serde_json::to_string(&data).unwrap();
        let back: crate::ipc::Data = serde_json::from_str(&json).unwrap();
        assert!(matches!(
            back,
            crate::ipc::Data::RemoteHubPasswordDisplay(PasswordDisplayOp::Renew(l)) if l == lease
        ));
    }

    /// The UI side confirms a successful allow, so it stays on; a stop
    /// needs no confirmation.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_confirmed_allow_over_ipc_stays_on() {
        use crate::ipc::ConnectionTmpl;
        use std::sync::atomic::Ordering;
        use std::time::Duration;

        let (status, stored) = test_listener(false).await;
        for enabled in [true, false] {
            let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
            let mut service = ConnectionTmpl::new(service_end);
            let mut ui = ConnectionTmpl::new(ui_end);
            let flag = stored.clone();
            let serve = tokio::spawn(async move {
                // The request itself is read by the IPC server loop.
                assert!(matches!(
                    service.next_timeout(5_000).await,
                    Ok(Some(crate::ipc::Data::RemoteHubSetAccess(v))) if v == enabled
                ));
                serve_access_request_with(
                    &mut service,
                    status,
                    fresh_display(),
                    move |v| flag.store(v, Ordering::SeqCst),
                    enabled,
                    Duration::from_secs(5),
                    Duration::from_secs(5),
                )
                .await
            });
            request_host_access(&mut ui, enabled, Duration::from_secs(15))
                .await
                .unwrap();
            serve.await.unwrap();
            assert_eq!(stored.load(Ordering::SeqCst), enabled);
            let want = if enabled {
                ListenerState::Listening
            } else {
                ListenerState::Stopped
            };
            assert_eq!(status.local(), Some(want));
        }
    }

    /// A failed allow over IPC is reported as failed to the UI side.
    #[tokio::test]
    async fn a_failed_allow_over_ipc_is_an_error() {
        use crate::ipc::ConnectionTmpl;
        use std::time::Duration;

        let none: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        let (service_end, ui_end) = tokio::io::duplex(64 * 1024);
        let mut service = ConnectionTmpl::new(service_end);
        let mut ui = ConnectionTmpl::new(ui_end);
        let serve = tokio::spawn(async move {
            let _ = service.next_timeout(5_000).await;
            serve_access_request_with(
                &mut service,
                none,
                fresh_display(),
                |_| {},
                true,
                Duration::from_millis(200),
                Duration::from_millis(200),
            )
            .await
        });
        let err = request_host_access(&mut ui, true, Duration::from_secs(5))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not running"), "{err}");
        serve.await.unwrap();
    }

    /// The panel never says "off" while the host listener accepts, whatever
    /// this process stored.
    #[test]
    fn the_panel_shows_access_on_while_the_listener_accepts() {
        assert!(panel_access_enabled(false, ListenerState::Listening));
        assert!(panel_access_enabled(false, ListenerState::PortUnavailable));
        assert!(!panel_access_enabled(false, ListenerState::Stopped));
        assert!(!panel_access_enabled(false, ListenerState::NotRunning));
        assert!(panel_access_enabled(true, ListenerState::Stopped));
    }

    /// Another program on the host port answers a probe, but Remote Hub did
    /// not bind it: the panel must not say "Accepting".
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_foreign_program_on_the_port_is_not_reported_as_listening() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        use tokio::time::{sleep, Duration, Instant};

        async fn wait_for(status: &ListenerStatus, want: ListenerState, secs: u64) {
            let deadline = Instant::now() + Duration::from_secs(secs);
            while status.local() != Some(want) {
                assert!(
                    Instant::now() < deadline,
                    "listener state {:?}, want {want:?}",
                    status.local()
                );
                sleep(Duration::from_millis(50)).await;
            }
        }

        let foreign = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = foreign.local_addr().unwrap();
        let status: &'static ListenerStatus = Box::leak(Box::new(ListenerStatus::new()));
        assert_eq!(status.local(), None, "no loop runs yet");
        let enabled = Arc::new(AtomicBool::new(true));
        let flag = enabled.clone();
        tokio::spawn(host_listener(
            crate::server::new(),
            status,
            move || flag.load(Ordering::SeqCst),
            move || Ok(addr),
        ));

        wait_for(status, ListenerState::PortUnavailable, 3).await;
        // A port probe would have succeeded here (the old false "Accepting").
        assert!(std::net::TcpStream::connect(addr).is_ok());
        let json: serde_json::Value = serde_json::from_str(&status_json(
            Role::Host,
            true,
            true,
            status.local().unwrap(),
        ))
        .unwrap();
        assert_eq!(json["listening"], false);
        assert_eq!(json["listener"], "port_unavailable");

        // Once the port is free, the loop binds it and says so.
        drop(foreign);
        wait_for(status, ListenerState::Listening, 10).await;

        // Stop access: the loop releases the port and reports it.
        enabled.store(false, Ordering::SeqCst);
        wait_for(status, ListenerState::Stopped, 5).await;
        sleep(Duration::from_millis(200)).await;
        assert!(std::net::TcpStream::connect(addr).is_err());
    }
}

/// Whole production chain on one machine, with a test CA in place of the
/// Tailscale certificate: engine socket -> `TlsBridge` -> TLS terminator
/// (stand-in for `tailscale serve --tls-terminated-tcp`) -> Remote Hub host
/// listener on 127.0.0.1:22118 -> the real host `Connection` login code.
#[cfg(test)]
mod e2e {
    use super::*;
    use base::message_proto::{login_request, message, FileTransfer, LoginRequest, Message};
    use hbb_common::{
        config::compute_permanent_password_h1,
        protobuf::Message as _,
        sha2::{Digest, Sha256},
        tokio::time::{sleep, Duration},
    };
    use remote_hub::test_support::{serve_tls_terminated_tcp, TestCa};

    const SERVER_NAME: &str = "host-e2e.example-tailnet.ts.net";
    const PASSWORD: &str = "e2e-Host-Password-1";

    /// A throwaway config directory, so the test never touches a real
    /// RustDesk or Remote Hub installation on this machine.
    fn isolated_config() {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| {
            *hbb_common::config::APP_NAME.write().unwrap() =
                format!("RemoteHubE2ETest{}", uuid::Uuid::new_v4().simple());
        });
        let file = Config::file();
        assert!(
            file.to_string_lossy().contains("RemoteHubE2ETest"),
            "config already loaded from {file:?}; run this test on its own"
        );
    }

    /// One login = one engine session = one bridge, as `dial` does.
    async fn login(serve: &Serve, password: &str, file_transfer: bool) -> String {
        let bridge = TlsBridge::open_for_test(
            serve.addr,
            SERVER_NAME,
            serve.ca.roots(),
            BridgeConfig::default(),
        )
        .await
        .unwrap();
        assert_eq!(bridge.verified_server_name(), SERVER_NAME);
        let mut stream = connect_tcp_local(bridge.engine_dial_address(), None, 5_000)
            .await
            .unwrap();
        let hash = loop {
            let bytes = stream.next_timeout(10_000).await.unwrap().unwrap();
            if let Some(message::Union::Hash(h)) = Message::parse_from_bytes(&bytes).unwrap().union
            {
                break h;
            }
        };
        let h1 = compute_permanent_password_h1(password, &hash.salt);
        let mut h2 = Sha256::new();
        h2.update(h1);
        h2.update(hash.challenge.as_bytes());
        let mut lr = LoginRequest {
            username: "100.64.0.10:21118".to_owned(),
            password: h2.finalize()[..].to_vec().into(),
            my_id: "e2e-controller".to_owned(),
            my_name: "e2e".to_owned(),
            version: crate::VERSION.to_owned(),
            ..Default::default()
        };
        if file_transfer {
            lr.union = Some(login_request::Union::FileTransfer(FileTransfer::new()));
        }
        let mut msg = Message::new();
        msg.set_login_request(lr);
        stream.send(&msg).await.unwrap();
        let outcome = loop {
            let Some(Ok(bytes)) = stream.next_timeout(10_000).await else {
                break "closed".to_owned();
            };
            if let Ok(Message {
                union: Some(message::Union::LoginResponse(res)),
                ..
            }) = Message::parse_from_bytes(&bytes)
            {
                break if res.has_peer_info() {
                    "accepted".to_owned()
                } else {
                    res.error().to_owned()
                };
            }
        };
        if outcome == "accepted" {
            // Keep the session open while the caller checks the lease.
            LIVE.lock().unwrap().push((stream, bridge));
        } else {
            // The host ended the session, so its bridge must close too.
            drop(stream);
            for _ in 0..100 {
                if bridge.is_closed() {
                    break;
                }
                sleep(Duration::from_millis(50)).await;
            }
            assert!(
                bridge.is_closed(),
                "bridge outlived its session ({outcome})"
            );
        }
        outcome
    }

    static LIVE: Mutex<Vec<(Stream, TlsBridge)>> = Mutex::new(Vec::new());

    /// Waits until the host no longer holds an earlier, already refused
    /// login from loopback among its unauthenticated ones (they go when
    /// the host notices their end), so the cap starts empty.
    async fn wait_no_pending_logins() {
        let loopback: std::net::IpAddr = "127.0.0.1".parse().unwrap();
        for _ in 0..100 {
            if crate::server::unauthorized_count_from(loopback) == 0 {
                return;
            }
            sleep(Duration::from_millis(50)).await;
        }
        panic!(
            "{} refused login(s) still pending",
            crate::server::unauthorized_count_from(loopback)
        );
    }

    struct Serve {
        addr: std::net::SocketAddr,
        ca: TestCa,
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn tls_bridge_to_restricted_host_end_to_end() {
        // Its logins count among the host's unauthenticated connections,
        // which other tests fill on purpose.
        let _serial = crate::server::UNAUTHORIZED_TESTS
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _port = HOST_PORT_TESTS.lock().unwrap_or_else(|e| e.into_inner());
        isolated_config();
        for (k, v) in [
            (OPTION_ROLE, ROLE_HOST),
            (OPTION_HOST_ENABLED, "Y"),
            ("approve-mode", "password"),
            ("verification-method", "use-permanent-password"),
        ] {
            Config::set_option(k.to_owned(), v.to_owned());
        }
        assert!(Config::set_permanent_password(PASSWORD));
        assert!(host_password_ready());

        tokio::spawn(start_all());
        let backend: std::net::SocketAddr = "127.0.0.1:22118".parse().unwrap();
        for _ in 0..50 {
            if HOST_LISTENER.local() == Some(ListenerState::Listening) {
                break;
            }
            sleep(Duration::from_millis(100)).await;
        }
        assert_eq!(listener_state_for_ipc(), ListenerState::Listening);

        let ca = TestCa::new();
        let (cert, key) = ca.issue(SERVER_NAME, false);
        let addr = serve_tls_terminated_tcp(cert, key, backend).await;
        let serve = &Serve { addr, ca };

        // SEC-01/SEC-03: a loopback connection still needs the password.
        assert_eq!(
            login(serve, "wrong-password", false).await,
            "Wrong Password"
        );
        // SEC-11: file transfer is refused before any password check.
        let ft = login(serve, PASSWORD, true).await;
        assert!(ft.starts_with("UNSUPPORTED_CAPABILITY"), "{ft}");
        wait_no_pending_logins().await;
        // SEC-12: logins racing each other give control to exactly one.
        let (a, b, c, d) = hbb_common::tokio::join!(
            login(serve, PASSWORD, false),
            login(serve, PASSWORD, false),
            login(serve, PASSWORD, false),
            login(serve, PASSWORD, false),
        );
        let outcomes = [a, b, c, d];
        assert_eq!(
            outcomes.iter().filter(|o| *o == "accepted").count(),
            1,
            "{outcomes:?}"
        );
        for o in outcomes.iter().filter(|o| *o != "accepted") {
            assert!(o.starts_with("HOST_BUSY"), "{outcomes:?}");
        }
        // SEC-12: a second controller does not take over the session.
        let busy = login(serve, PASSWORD, false).await;
        assert!(busy.starts_with("HOST_BUSY"), "{busy}");

        // Plan 7.5: Serve brings every login from 127.0.0.1, and at most
        // four wait unauthenticated; a fifth is turned away at once.
        wait_no_pending_logins().await;
        let mut pending = Vec::new();
        for _ in 0..4 {
            let mut s = connect_tcp_local(backend, None, 5_000).await.unwrap();
            assert!(
                matches!(s.next_timeout(5_000).await, Some(Ok(_))),
                "one of the first four pending logins"
            );
            pending.push(s);
        }
        let mut fifth = connect_tcp_local(backend, None, 5_000).await.unwrap();
        assert!(
            !matches!(fifth.next_timeout(5_000).await, Some(Ok(_))),
            "a fifth pending login is refused"
        );
        drop(pending);

        // Plan 17.5: stopping access ends the session and closes the listener.
        Config::set_option(OPTION_HOST_ENABLED.to_owned(), "N".to_owned());
        let (mut live, bridge) = LIVE.lock().unwrap().pop().unwrap();
        let ended = async {
            loop {
                match live.next_timeout(5_000).await {
                    Some(Ok(_)) => continue,
                    _ => break,
                }
            }
        };
        hbb_common::tokio::time::timeout(Duration::from_secs(10), ended)
            .await
            .expect("session must end after Stop access");
        sleep(Duration::from_secs(2)).await;
        assert!(hbb_common::tokio::net::TcpStream::connect(backend)
            .await
            .is_err());
        assert_eq!(listener_state_for_ipc(), ListenerState::Stopped);
        // The ended session took its bridge and loopback port with it.
        assert!(bridge.is_closed());
    }
}
