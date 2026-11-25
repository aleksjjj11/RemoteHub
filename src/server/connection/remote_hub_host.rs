//! Remote Hub host rules, enforced where messages are received (plan 10.5,
//! 13.5, 17.3): password-only login, one controller at a time, and only the
//! v0.1 capabilities. Hiding a menu item on the controller is not enough.

use super::{ConnAuditPrimaryAuth, Connection, ALIVE_CONNS};
use base::message_proto::{
    message, misc, KeyEvent, LoginRequest, Message, MouseEvent, OptionMessage,
};
use hbb_common::log_throttle::LogThrottle;
use remote_hub::ErrorCode;
use std::{sync::Mutex, time::Duration};

/// Refused logins are peer-controlled (any peer that reaches the port can
/// retry across many connections), so both refusal sites share one throttle.
static REFUSED_LOGINS: LogThrottle = LogThrottle::new(Duration::from_secs(60));

/// Mouse buttons the single controller holds down; released when its session
/// closes, however it ends (plan 10.6). One lease, so one global set.
static HELD_BUTTONS: Mutex<Vec<i32>> = Mutex::new(Vec::new());
/// Keys the controller holds down (key-down events not yet followed by their
/// key-up), released the same way as the buttons.
static HELD_KEYS: Mutex<Vec<KeyEvent>> = Mutex::new(Vec::new());
/// A controller cannot really hold more keys than this; the cap keeps a
/// misbehaving peer from growing the set without bound.
const MAX_HELD_KEYS: usize = 64;
const MOUSE_TYPE_DOWN: i32 = 1;
const MOUSE_TYPE_UP: i32 = 2;

/// Connection id of the one authorized controller. Claimed in the same
/// synchronous step that authorizes the connection, so two logins that both
/// passed the early busy check cannot both get control.
static CONTROLLER: Mutex<Option<i32>> = Mutex::new(None);

impl Connection {
    /// `Ok(msg)` hands the (possibly narrowed) message to the upstream
    /// handler; `Err(keep_alive)` means Remote Hub handled it.
    pub(super) async fn remote_hub_check(&mut self, mut msg: Message) -> Result<Message, bool> {
        if self.authorized {
            if host_message_allowed(&msg) {
                restrict_host_message(&mut msg);
                match msg.union.as_ref() {
                    Some(message::Union::MouseEvent(me)) => {
                        track_buttons(&mut HELD_BUTTONS.lock().unwrap(), me.mask)
                    }
                    Some(message::Union::KeyEvent(ke)) => {
                        track_keys(&mut HELD_KEYS.lock().unwrap(), ke)
                    }
                    _ => {}
                }
                return Ok(msg);
            }
            hbb_common::throttled_log!(
                std::time::Duration::from_secs(60),
                warn,
                "Remote Hub host dropped a message outside the v0.1 capabilities"
            );
            return Err(true);
        }
        let Some(message::Union::LoginRequest(lr)) = msg.union.as_ref() else {
            return Ok(msg);
        };
        let other_controller = controller_held_by_other(
            *CONTROLLER.lock().unwrap(),
            self.inner.id,
            &ALIVE_CONNS.lock().unwrap(),
        );
        if let Some((code, text)) = login_denial(
            lr,
            crate::remote_hub::host_access_enabled(),
            crate::remote_hub::host_password_ready(),
            other_controller,
        ) {
            log_refused_login(code);
            self.send_login_error(format!("{code}: {text}")).await;
            hbb_common::sleep(1.).await;
            return Err(false);
        }
        restrict_host_message(&mut msg);
        self.clipboard = false;
        self.audio = false;
        self.file = false;
        self.restart = false;
        self.recording = false;
        self.block_input = false;
        self.privacy_mode = false;
        #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
        {
            self.enable_file_transfer = false;
        }
        Ok(msg)
    }

    /// Takes the controller lease right before the connection is marked
    /// authorized. `false` refuses the login. This is the one step every
    /// upstream authorization path goes through (password, connection-manager
    /// click, switch sides), so the password-only rule is enforced here: the
    /// login must have presented the current permanent password. Access is
    /// checked again too: "Stop access" may have come while this login was
    /// still authenticating, and such a connection is not yet among the ones
    /// the listener closes.
    pub(super) async fn remote_hub_claim_controller(&mut self) -> bool {
        let claimed = claim_controller(
            &mut CONTROLLER.lock().unwrap(),
            self.inner.id,
            &ALIVE_CONNS.lock().unwrap(),
            crate::remote_hub::host_access_enabled(),
            crate::remote_hub::host_password_ready(),
            self.conn_audit_primary_auth,
        );
        let Err((code, text)) = claimed else {
            return true;
        };
        log_refused_login(code);
        self.send_login_error(format!("{code}: {text}")).await;
        false
    }

    /// Polled every second by the connection loop: an authorized session
    /// ends as soon as access is stopped, whether or not the listener's close
    /// signal reached it (it may have been authorized just after the signal).
    pub(super) async fn remote_hub_access_revoked(&mut self) -> bool {
        if !session_access_revoked(self.authorized, crate::remote_hub::host_access_enabled()) {
            return false;
        }
        self.send_close_reason_no_retry(&format!("{}: {STOPPED_TEXT}", ErrorCode::HostDisabled))
            .await;
        true
    }
}

impl Connection {
    /// The upstream "recent session" shortcut lets a controller reconnect
    /// with the credential of its previous session for a while, without the
    /// current password. Remote Hub logins are password-only (plan 10.5), and
    /// an owner who rotates the password must lock out whoever knew the old
    /// one, so the shortcut is never taken on a Remote Hub host.
    pub(super) fn remote_hub_recent_session_login_allowed() -> bool {
        false
    }
}

/// Connection-manager permissions the v0.1 host never grants (plan 10.5).
/// Login clears them; this keeps a later permission switch from turning them
/// back on for the rest of the session.
const FORBIDDEN_PERMISSIONS: &[&str] = &[
    "clipboard",
    "audio",
    "file",
    "restart",
    "recording",
    "block_input",
    "privacy_mode",
];

/// The value a connection-manager permission switch may take on a Remote Hub
/// host: forbidden capabilities stay off whatever was requested.
pub(super) fn permission_switch_value(name: &str, enabled: bool) -> bool {
    enabled && !FORBIDDEN_PERMISSIONS.contains(&name)
}

const STOPPED_TEXT: &str = "Remote access is stopped on this computer";

fn session_access_revoked(authorized: bool, access_enabled: bool) -> bool {
    authorized && !access_enabled
}

impl Connection {
    /// Called when the connection closes: an authorized controller's held keys
    /// and buttons are released on the host and its lease is returned.
    ///
    /// The releases are queued on this connection's input thread, the same
    /// path its presses took: they run after any input still queued, and on
    /// Windows they reach the portable service when it does the input.
    pub(super) fn remote_hub_on_close(&self) {
        if !self.authorized {
            return;
        }
        let buttons = std::mem::take(&mut *HELD_BUTTONS.lock().unwrap());
        let keys = std::mem::take(&mut *HELD_KEYS.lock().unwrap());
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        {
            let (mouse_ups, key_ups) = release_events(buttons, keys);
            for evt in mouse_ups {
                self.input_mouse(evt, self.inner.id, String::new(), 0, true, false);
            }
            for evt in key_ups {
                self.input_key(evt, false);
            }
        }
        #[cfg(any(target_os = "android", target_os = "ios"))]
        let _ = (buttons, keys);
        release_controller(&mut CONTROLLER.lock().unwrap(), self.inner.id);
    }
}

fn log_refused_login(code: ErrorCode) {
    if let Some(line) = refused_login_line(&REFUSED_LOGINS, code) {
        hbb_common::log::warn!("{line}");
    }
}

/// One line per throttle interval, carrying how many refusals it stands for.
fn refused_login_line(throttle: &LogThrottle, code: ErrorCode) -> Option<String> {
    let n = throttle.due()?;
    Some(if n > 1 {
        format!("Remote Hub host refused a login: {code} (x{n})")
    } else {
        format!("Remote Hub host refused a login: {code}")
    })
}

/// A lease whose connection is gone (closed without `on_close`) is free.
fn controller_held_by_other(lease: Option<i32>, me: i32, alive: &[i32]) -> bool {
    lease.is_some_and(|holder| holder != me && alive.contains(&holder))
}

const PASSWORD_REQUIRED_TEXT: &str = "The host password is required";

/// Only a login that presented the current permanent password may control
/// the host. `validate_password` records `PermanentPassword` only after the
/// stored permanent password matched; a connection-manager click records
/// `Click` (overwriting it), switching sides `SwitchSides`, and a temporary
/// or recent-session password `TemporaryPassword`.
fn primary_auth_allowed(auth: ConnAuditPrimaryAuth) -> bool {
    auth == ConnAuditPrimaryAuth::PermanentPassword
}

fn claim_controller(
    lease: &mut Option<i32>,
    me: i32,
    alive: &[i32],
    access_enabled: bool,
    password_ready: bool,
    auth: ConnAuditPrimaryAuth,
) -> Result<(), (ErrorCode, &'static str)> {
    if !access_enabled {
        return Err((ErrorCode::HostDisabled, STOPPED_TEXT));
    }
    if !password_ready {
        return Err((
            ErrorCode::HostDisabled,
            "The host password is not set up for Remote Hub",
        ));
    }
    if !primary_auth_allowed(auth) {
        return Err((ErrorCode::AuthenticationFailed, PASSWORD_REQUIRED_TEXT));
    }
    if controller_held_by_other(*lease, me, alive) {
        return Err((ErrorCode::HostBusy, "Another controller is connected"));
    }
    *lease = Some(me);
    Ok(())
}

fn release_controller(lease: &mut Option<i32>, me: i32) {
    if *lease == Some(me) {
        *lease = None;
    }
}

/// Keeps only the option fields of the v0.1 capability set: image quality,
/// frame rate, codec negotiation and the remote cursor. Session lock, privacy
/// mode, input blocking, clipboard, file transfer, audio and the rest never
/// reach the upstream handler.
fn restrict_option(option: &OptionMessage) -> OptionMessage {
    OptionMessage {
        image_quality: option.image_quality,
        custom_image_quality: option.custom_image_quality,
        custom_fps: option.custom_fps,
        supported_decoding: option.supported_decoding.clone(),
        show_remote_cursor: option.show_remote_cursor,
        ..Default::default()
    }
}

/// Narrows allowed messages whose fields reach beyond the capability set.
fn restrict_host_message(msg: &mut Message) {
    match msg.union.as_mut() {
        Some(message::Union::LoginRequest(lr)) => {
            if let Some(option) = lr.option.as_mut() {
                *option = restrict_option(option);
            }
        }
        Some(message::Union::Misc(m)) => match m.union.as_mut() {
            Some(misc::Union::Option(option)) => *option = restrict_option(option),
            // Display selection only; upstream would also apply a resolution.
            Some(misc::Union::SwitchDisplay(s)) => {
                s.width = 0;
                s.height = 0;
            }
            _ => {}
        },
        _ => {}
    }
}

fn track_buttons(held: &mut Vec<i32>, mask: i32) {
    let buttons = mask >> 3;
    match mask & 0x7 {
        MOUSE_TYPE_DOWN if !held.contains(&buttons) => held.push(buttons),
        MOUSE_TYPE_UP => held.retain(|b| *b != buttons),
        _ => {}
    }
}

fn same_key(a: &KeyEvent, b: &KeyEvent) -> bool {
    a.mode == b.mode && a.union == b.union
}

/// A `press` event is a complete click, so only a plain key-down is held.
fn track_keys(held: &mut Vec<KeyEvent>, ke: &KeyEvent) {
    if ke.press {
        return;
    }
    if ke.down {
        if held.len() < MAX_HELD_KEYS && !held.iter().any(|k| same_key(k, ke)) {
            held.push(ke.clone());
        }
    } else {
        held.retain(|k| !same_key(k, ke));
    }
}

/// The mouse-up and key-up events that let go of what the controller held.
fn release_events(buttons: Vec<i32>, keys: Vec<KeyEvent>) -> (Vec<MouseEvent>, Vec<KeyEvent>) {
    let mouse_ups = buttons
        .into_iter()
        .map(|b| MouseEvent {
            mask: (b << 3) | MOUSE_TYPE_UP,
            ..Default::default()
        })
        .collect();
    let key_ups = keys
        .into_iter()
        .map(|k| KeyEvent {
            mode: k.mode,
            union: k.union,
            down: false,
            press: false,
            ..Default::default()
        })
        .collect();
    (mouse_ups, key_ups)
}

fn login_denial(
    lr: &LoginRequest,
    access_enabled: bool,
    password_ready: bool,
    other_controller: bool,
) -> Option<(ErrorCode, &'static str)> {
    if !access_enabled {
        return Some((ErrorCode::HostDisabled, STOPPED_TEXT));
    }
    if lr.union.is_some() {
        return Some((
            ErrorCode::UnsupportedCapability,
            "Only remote desktop sessions are allowed",
        ));
    }
    if !password_ready {
        return Some((
            ErrorCode::HostDisabled,
            "The host password is not set up for Remote Hub",
        ));
    }
    if other_controller {
        return Some((ErrorCode::HostBusy, "Another controller is connected"));
    }
    None
}

/// Allowlist of messages an authorized controller may send: view, pointer,
/// keyboard, display selection and quality. Everything else is dropped.
fn host_message_allowed(msg: &Message) -> bool {
    match msg.union.as_ref() {
        Some(
            message::Union::MouseEvent(_)
            | message::Union::PointerDeviceEvent(_)
            | message::Union::KeyEvent(_)
            | message::Union::TestDelay(_)
            | message::Union::LoginRequest(_),
        ) => true,
        Some(message::Union::Misc(m)) => matches!(
            m.union,
            Some(
                misc::Union::SwitchDisplay(_)
                    | misc::Union::CaptureDisplays(_)
                    | misc::Union::Option(_)
                    | misc::Union::RefreshVideo(_)
                    | misc::Union::RefreshVideoDisplay(_)
                    | misc::Union::VideoReceived(_)
                    | misc::Union::AutoAdjustFps(_)
                    | misc::Union::MessageQuery(_)
                    | misc::Union::RequestCursorData(_)
                    | misc::Union::CloseReason(_)
            )
        ),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{
        option_message::BoolOption, Clipboard, ControlKey, FileAction, FileTransfer, KeyboardMode,
        Misc, PortForward, SwitchDisplay, TerminalAction,
    };

    #[test]
    fn forbidden_permissions_cannot_be_switched_on_after_login() {
        for name in FORBIDDEN_PERMISSIONS {
            assert!(!permission_switch_value(name, true), "{name}");
            assert!(!permission_switch_value(name, false), "{name}");
        }
        assert!(permission_switch_value("keyboard", true));
        assert!(!permission_switch_value("keyboard", false));
    }

    /// A claim by a login that presented the permanent password.
    fn claim(
        lease: &mut Option<i32>,
        me: i32,
        alive: &[i32],
        access_enabled: bool,
    ) -> Result<(), (ErrorCode, &'static str)> {
        claim_controller(
            lease,
            me,
            alive,
            access_enabled,
            true,
            ConnAuditPrimaryAuth::PermanentPassword,
        )
    }

    #[test]
    fn only_a_permanent_password_login_claims_the_controller() {
        // An empty-password login that the connection manager then accepted
        // by click, a switch-sides login, a temporary or recent-session
        // password, and a login that verified nothing all reach the claim
        // through upstream authorization; none of them gets control.
        for auth in [
            ConnAuditPrimaryAuth::Click,
            ConnAuditPrimaryAuth::SwitchSides,
            ConnAuditPrimaryAuth::TemporaryPassword,
            ConnAuditPrimaryAuth::None,
        ] {
            let mut lease = None;
            assert_eq!(
                claim_controller(&mut lease, 1, &[1], true, true, auth).map_err(|e| e.0),
                Err(ErrorCode::AuthenticationFailed),
                "{auth:?}"
            );
            assert_eq!(lease, None, "{auth:?}");
        }
        // The password verified, but the host left password-only mode while
        // the login was still authenticating.
        let mut lease = None;
        assert_eq!(
            claim_controller(
                &mut lease,
                1,
                &[1],
                true,
                false,
                ConnAuditPrimaryAuth::PermanentPassword
            )
            .map_err(|e| e.0),
            Err(ErrorCode::HostDisabled)
        );
        assert_eq!(lease, None);
        assert!(claim_controller(
            &mut lease,
            1,
            &[1],
            true,
            true,
            ConnAuditPrimaryAuth::PermanentPassword
        )
        .is_ok());
        assert_eq!(lease, Some(1));
    }

    fn misc(f: impl FnOnce(&mut Misc)) -> Message {
        let mut m = Misc::new();
        f(&mut m);
        let mut msg = Message::new();
        msg.set_misc(m);
        msg
    }

    #[test]
    fn only_v0_1_capabilities_pass_after_login() {
        let mut mouse = Message::new();
        mouse.set_mouse_event(MouseEvent::new());
        let mut key = Message::new();
        key.set_key_event(KeyEvent::new());
        assert!(host_message_allowed(&mouse));
        assert!(host_message_allowed(&key));
        assert!(host_message_allowed(&misc(
            |m| m.set_switch_display(Default::default())
        )));

        let mut clip = Message::new();
        clip.set_clipboard(Clipboard::new());
        let mut file = Message::new();
        file.set_file_action(FileAction::new());
        let mut term = Message::new();
        term.set_terminal_action(TerminalAction::new());
        let mut none = Message::new();
        none.union = None;
        for denied in [
            clip,
            file,
            term,
            none,
            misc(|m| m.set_restart_remote_device(true)),
            misc(|m| m.set_toggle_privacy_mode(Default::default())),
            misc(|m| m.set_elevation_request(Default::default())),
            misc(|m| m.set_chat_message(Default::default())),
            misc(|m| m.set_change_resolution(Default::default())),
            misc(|m| m.set_toggle_virtual_display(Default::default())),
            // Windows user-session switching is outside screen/input/display.
            misc(|m| m.set_selected_sid(1)),
        ] {
            assert!(!host_message_allowed(&denied), "{denied:?}");
        }
    }

    #[test]
    fn options_are_narrowed_to_view_and_quality() {
        use base::message_proto::{ImageQuality, SupportedDecoding};
        let yes = BoolOption::Yes.into();
        let full = OptionMessage {
            image_quality: ImageQuality::Best.into(),
            custom_image_quality: 50,
            custom_fps: 30,
            supported_decoding: Some(SupportedDecoding::new()).into(),
            show_remote_cursor: yes,
            lock_after_session_end: yes,
            privacy_mode: yes,
            block_input: yes,
            disable_audio: BoolOption::No.into(),
            disable_clipboard: BoolOption::No.into(),
            enable_file_transfer: yes,
            disable_keyboard: yes,
            follow_remote_cursor: yes,
            follow_remote_window: yes,
            disable_camera: BoolOption::No.into(),
            terminal_persistent: yes,
            show_my_cursor: yes,
            ..Default::default()
        };
        let expected = OptionMessage {
            image_quality: ImageQuality::Best.into(),
            custom_image_quality: 50,
            custom_fps: 30,
            supported_decoding: Some(SupportedDecoding::new()).into(),
            show_remote_cursor: yes,
            ..Default::default()
        };

        let mut msg = misc(|m| m.set_option(full.clone()));
        assert!(host_message_allowed(&msg));
        restrict_host_message(&mut msg);
        assert_eq!(msg.misc().option(), &expected);

        let mut login = Message::new();
        login.set_login_request(LoginRequest {
            option: Some(full).into(),
            ..Default::default()
        });
        restrict_host_message(&mut login);
        assert_eq!(login.login_request().option, Some(expected).into());
    }

    #[test]
    fn switch_display_cannot_change_resolution() {
        let mut msg = misc(|m| {
            m.set_switch_display(SwitchDisplay {
                display: 1,
                width: 640,
                height: 480,
                ..Default::default()
            })
        });
        restrict_host_message(&mut msg);
        let s = msg.misc().switch_display();
        assert_eq!((s.display, s.width, s.height), (1, 0, 0));
    }

    #[test]
    fn only_one_concurrent_login_claims_the_controller() {
        let mut lease = None;
        let alive = [1, 2];
        // Both logins passed the early busy check before either was authorized.
        assert!(!controller_held_by_other(lease, 1, &alive));
        assert!(!controller_held_by_other(lease, 2, &alive));
        assert!(claim(&mut lease, 1, &alive, true).is_ok());
        assert_eq!(
            claim(&mut lease, 2, &alive, true).map_err(|e| e.0),
            Err(ErrorCode::HostBusy)
        );
        assert!(controller_held_by_other(lease, 2, &alive));

        release_controller(&mut lease, 2);
        assert_eq!(lease, Some(1));
        release_controller(&mut lease, 1);
        assert!(claim(&mut lease, 2, &alive, true).is_ok());

        // A holder that vanished without on_close does not block forever.
        assert!(claim(&mut lease, 3, &[3], true).is_ok());
    }

    #[test]
    fn login_finishing_after_stop_access_gets_no_control() {
        // The login passed the early access check, then the owner stopped
        // access while it was still authenticating.
        assert!(login_denial(&LoginRequest::new(), true, true, false).is_none());
        let mut lease = None;
        assert_eq!(
            claim(&mut lease, 1, &[1], false).map_err(|e| e.0),
            Err(ErrorCode::HostDisabled)
        );
        assert_eq!(lease, None);
    }

    #[test]
    fn rotated_password_is_not_bypassed_by_a_recent_session() {
        // A controller that kept the previous session's reconnect credential
        // must present the current permanent password like any other login.
        assert!(!Connection::recent_session_login_allowed());
    }

    #[test]
    fn authorized_session_ends_once_access_is_stopped() {
        // Authorized just after the listener's close signal went out.
        assert!(session_access_revoked(true, false));
        assert!(!session_access_revoked(true, true));
        // Not yet authorized: the claim refuses it instead.
        assert!(!session_access_revoked(false, false));
    }

    #[test]
    fn refused_login_warnings_are_throttled() {
        let throttle = LogThrottle::new(Duration::from_secs(60));
        assert_eq!(
            refused_login_line(&throttle, ErrorCode::HostBusy),
            Some(format!(
                "Remote Hub host refused a login: {}",
                ErrorCode::HostBusy
            ))
        );
        // A peer retrying across many connections writes nothing more inside
        // the interval, whichever refusal code it hits.
        for _ in 0..1_000 {
            assert!(refused_login_line(&throttle, ErrorCode::HostDisabled).is_none());
            assert!(refused_login_line(&throttle, ErrorCode::HostBusy).is_none());
        }

        let zero = LogThrottle::new(Duration::ZERO);
        assert!(refused_login_line(&zero, ErrorCode::HostBusy).is_some());
    }

    #[test]
    fn held_buttons_are_tracked_for_release() {
        let mut held = Vec::new();
        track_buttons(&mut held, (1 << 3) | MOUSE_TYPE_DOWN);
        track_buttons(&mut held, (2 << 3) | MOUSE_TYPE_DOWN);
        track_buttons(&mut held, (1 << 3) | MOUSE_TYPE_DOWN);
        track_buttons(&mut held, (2 << 3) | MOUSE_TYPE_UP);
        track_buttons(&mut held, 0); // move
        assert_eq!(held, vec![1]);
    }

    fn key(chr: u32, down: bool, press: bool) -> KeyEvent {
        let mut ke = KeyEvent::new();
        ke.set_chr(chr);
        ke.mode = KeyboardMode::Map.into();
        ke.down = down;
        ke.press = press;
        ke
    }

    #[test]
    fn held_keys_are_tracked_for_release() {
        let mut held = Vec::new();
        track_keys(&mut held, &key(30, true, false));
        track_keys(&mut held, &key(31, true, false));
        track_keys(&mut held, &key(30, true, false)); // auto-repeat
        track_keys(&mut held, &key(32, false, true)); // a full click
        track_keys(&mut held, &key(31, false, false));
        assert_eq!(held, vec![key(30, true, false)]);
        for chr in 0..1000 {
            track_keys(&mut held, &key(chr, true, false));
        }
        assert_eq!(held.len(), MAX_HELD_KEYS);
    }

    #[test]
    fn held_input_is_released_with_up_events() {
        let mut down = key(30, true, false);
        down.modifiers.push(ControlKey::Shift.into());
        let (mouse_ups, key_ups) = release_events(vec![1, 4], vec![down]);
        let masks: Vec<i32> = mouse_ups.iter().map(|m| m.mask).collect();
        assert_eq!(
            masks,
            vec![(1 << 3) | MOUSE_TYPE_UP, (4 << 3) | MOUSE_TYPE_UP]
        );
        assert_eq!(key_ups.len(), 1);
        let up = &key_ups[0];
        assert!(!up.down && !up.press);
        assert_eq!(up.chr(), 30);
        assert_eq!(up.mode.enum_value(), Ok(KeyboardMode::Map));
        // Modifiers on a key-up would be pressed again by the input code.
        assert!(up.modifiers.is_empty());
    }

    #[test]
    fn login_needs_access_on_a_password_and_no_other_controller() {
        let remote = LoginRequest::new();
        assert!(login_denial(&remote, true, true, false).is_none());
        assert_eq!(
            login_denial(&remote, false, true, false).map(|d| d.0),
            Some(ErrorCode::HostDisabled)
        );
        assert_eq!(
            login_denial(&remote, true, false, false).map(|d| d.0),
            Some(ErrorCode::HostDisabled)
        );
        assert_eq!(
            login_denial(&remote, true, true, true).map(|d| d.0),
            Some(ErrorCode::HostBusy)
        );
        let mut ft = LoginRequest::new();
        ft.set_file_transfer(FileTransfer::new());
        let mut pf = LoginRequest::new();
        pf.set_port_forward(PortForward::new());
        let mut term = LoginRequest::new();
        term.set_terminal(Default::default());
        for lr in [ft, pf, term] {
            assert_eq!(
                login_denial(&lr, true, true, false).map(|d| d.0),
                Some(ErrorCode::UnsupportedCapability)
            );
        }
    }
}
