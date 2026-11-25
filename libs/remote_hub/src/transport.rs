//! Controller-side TLS bridge (plan section 7).
//!
//! The engine dials a temporary `127.0.0.1:<port>`; every accepted socket is
//! carried over its own TLS channel to the one endpoint fixed at creation. The
//! first channel is verified before the loopback port even exists, so the
//! engine cannot send a password before the host certificate is checked. There
//! is no code path that dials the target without TLS.

use crate::log_throttle::throttled_log;
use crate::{
    endpoint::RemoteEndpoint,
    error::{ErrorCode, RemoteHubError},
};
use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{copy_buf, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use tokio_rustls::{
    client::TlsStream,
    rustls::{self, pki_types::ServerName, CertificateError, ClientConfig, RootCertStore},
    TlsConnector,
};

/// Starting limits from plan 7.5. Change them only with a measured reason.
#[derive(Debug, Clone)]
pub struct BridgeConfig {
    pub connect_timeout: Duration,
    pub handshake_timeout: Duration,
    /// How long the pre-verified first channel waits for the engine to dial.
    /// It does not apply to a running session.
    pub prepare_timeout: Duration,
    pub max_sockets: usize,
    pub buffer_size: usize,
}

impl Default for BridgeConfig {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(8),
            handshake_timeout: Duration::from_secs(8),
            prepare_timeout: Duration::from_secs(15),
            max_sockets: 4,
            buffer_size: 256 * 1024,
        }
    }
}

#[derive(Clone)]
pub(crate) struct Target {
    addr: SocketAddr,
    server_name: ServerName<'static>,
    connector: TlsConnector,
}

impl Target {
    pub(crate) fn new(
        addr: SocketAddr,
        server_name: &str,
        roots: RootCertStore,
    ) -> Result<Self, RemoteHubError> {
        let server_name = ServerName::try_from(server_name.to_owned()).map_err(|_| {
            RemoteHubError::new(ErrorCode::InvalidDeviceConfig, "invalid TLS server name")
        })?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|e| RemoteHubError::new(ErrorCode::InternalError, e.to_string()))?
            .with_root_certificates(roots)
            .with_no_client_auth();
        // Passwords and input must never travel as replayable 0-RTT data.
        config.enable_early_data = false;
        Ok(Self {
            addr,
            server_name,
            connector: TlsConnector::from(Arc::new(config)),
        })
    }

    async fn open_channel(
        &self,
        cfg: &BridgeConfig,
    ) -> Result<TlsStream<TcpStream>, RemoteHubError> {
        let tcp = match timeout(cfg.connect_timeout, TcpStream::connect(self.addr)).await {
            Ok(Ok(tcp)) => tcp,
            Ok(Err(err)) => {
                return Err(RemoteHubError::new(
                    ErrorCode::EndpointUnreachable,
                    format!("TCP connect failed: {:?}", err.kind()),
                ))
            }
            Err(_) => {
                return Err(RemoteHubError::new(
                    ErrorCode::EndpointUnreachable,
                    "TCP connect timed out",
                ))
            }
        };
        tcp.set_nodelay(true).ok();
        match timeout(
            cfg.handshake_timeout,
            self.connector.connect(self.server_name.clone(), tcp),
        )
        .await
        {
            Ok(Ok(tls)) => Ok(tls),
            Ok(Err(err)) => Err(classify_tls_error(&err)),
            Err(_) => Err(RemoteHubError::new(
                ErrorCode::TlsHandshakeFailed,
                "TLS handshake timed out",
            )),
        }
    }
}

fn classify_tls_error(err: &io::Error) -> RemoteHubError {
    let tls = err
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<rustls::Error>());
    let code = match tls {
        Some(rustls::Error::InvalidCertificate(cert)) => match cert {
            CertificateError::NotValidForName | CertificateError::NotValidForNameContext { .. } => {
                ErrorCode::TlsNameMismatch
            }
            CertificateError::Expired | CertificateError::ExpiredContext { .. } => {
                ErrorCode::TlsCertificateExpired
            }
            _ => ErrorCode::TlsCertificateInvalid,
        },
        _ => ErrorCode::TlsHandshakeFailed,
    };
    let detail = match tls {
        Some(e) => e.to_string(),
        None => format!("{:?}", err.kind()),
    };
    RemoteHubError::new(code, detail)
}

/// One bridge per session. The bridge ends by itself when the session (the
/// first engine socket) ends from either side; dropping or closing it does
/// the same earlier. Either way the loopback port is released and every
/// channel is closed.
pub struct TlsBridge {
    engine_dial_address: SocketAddr,
    verified_server_name: String,
    task: JoinHandle<()>,
}

impl TlsBridge {
    /// Verifies `endpoint` with the TLS library's bundled WebPKI roots, then
    /// opens the loopback port the engine should dial.
    pub async fn open(
        endpoint: &RemoteEndpoint,
        cfg: BridgeConfig,
    ) -> Result<Self, RemoteHubError> {
        let roots = RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        };
        let target = Target::new(endpoint.socket_addr(), endpoint.tls_server_name(), roots)?;
        Self::open_target(target, cfg).await
    }

    pub(crate) async fn open_target(
        target: Target,
        cfg: BridgeConfig,
    ) -> Result<Self, RemoteHubError> {
        let first = target.open_channel(&cfg).await?;
        let verified_server_name = match &target.server_name {
            ServerName::DnsName(name) => name.as_ref().to_owned(),
            other => format!("{other:?}"),
        };
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(|e| {
                RemoteHubError::new(ErrorCode::InternalError, format!("{:?}", e.kind()))
            })?;
        let engine_dial_address = listener.local_addr().map_err(|e| {
            RemoteHubError::new(ErrorCode::InternalError, format!("{:?}", e.kind()))
        })?;
        let task = tokio::spawn(serve(listener, first, target, cfg));
        Ok(Self {
            engine_dial_address,
            verified_server_name,
            task,
        })
    }

    /// The temporary `127.0.0.1:<port>` for the engine. Never persist anything
    /// (passwords, settings, history) under this address.
    pub fn engine_dial_address(&self) -> SocketAddr {
        self.engine_dial_address
    }

    pub fn verified_server_name(&self) -> &str {
        &self.verified_server_name
    }

    /// True once the session ended, the engine never dialed in time, or the
    /// bridge was closed.
    pub fn is_closed(&self) -> bool {
        self.task.is_finished()
    }

    pub async fn close(mut self) {
        self.task.abort();
        let _ = (&mut self.task).await;
    }
}

impl Drop for TlsBridge {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn serve(
    listener: TcpListener,
    first: TlsStream<TcpStream>,
    target: Target,
    cfg: BridgeConfig,
) {
    let local = match timeout(cfg.prepare_timeout, listener.accept()).await {
        Ok(Ok((local, _))) => local,
        Ok(Err(err)) => {
            throttled_log!(warn, "Remote Hub bridge accept failed: {:?}", err.kind());
            return;
        }
        Err(_) => {
            throttled_log!(warn, "Remote Hub bridge: engine did not connect in time");
            return;
        }
    };
    // The first engine socket is the session. When it ends the session is
    // over: returning drops the listener (releasing the loopback port) and
    // the `JoinSet`, which aborts any extra channel still open. Nothing can
    // reuse the bridge afterwards.
    let session = pump(local, first, cfg.buffer_size);
    tokio::pin!(session);
    let mut pumps = JoinSet::new();
    loop {
        tokio::select! {
            () = &mut session => {
                throttled_log!(info, "Remote Hub bridge: session ended, closing bridge");
                break;
            }
            accepted = listener.accept() => {
                let local = match accepted {
                    Ok((local, _)) => local,
                    Err(err) => {
                        throttled_log!(warn, "Remote Hub bridge accept failed: {:?}", err.kind());
                        break;
                    }
                };
                // Channels that already ended free their slot; the `1` is
                // the session socket.
                while pumps.try_join_next().is_some() {}
                if 1 + pumps.len() >= cfg.max_sockets {
                    // The engine decides how often this happens.
                    throttled_log!(warn, "Remote Hub bridge socket limit reached ({})", cfg.max_sockets);
                    continue;
                }
                let target = target.clone();
                let cfg = cfg.clone();
                // The engine's bytes stay unread in the bounded socket buffer
                // until this socket's own TLS channel is verified.
                pumps.spawn(async move {
                    match target.open_channel(&cfg).await {
                        Ok(remote) => pump(local, remote, cfg.buffer_size).await,
                        Err(err) => throttled_log!(warn, "Remote Hub bridge channel failed: {err}"),
                    }
                });
            }
            // Reap finished extra channels; the session itself is above.
            Some(_) = pumps.join_next(), if !pumps.is_empty() => {}
        }
    }
}

/// Carries bytes both ways until either side ends. The protocol never
/// half-closes, so the first EOF or error from the engine or the host ends
/// the channel: the other side is shut down and both sockets are dropped.
async fn pump(mut local: TcpStream, remote: TlsStream<TcpStream>, buffer_size: usize) {
    local.set_nodelay(true).ok();
    let (local_read, mut local_write) = local.split();
    let (remote_read, mut remote_write) = tokio::io::split(remote);
    let mut local_read = BufReader::with_capacity(buffer_size, local_read);
    let mut remote_read = BufReader::with_capacity(buffer_size, remote_read);
    let (direction, result) = tokio::select! {
        r = copy_buf(&mut local_read, &mut remote_write) => ("engine", r),
        r = copy_buf(&mut remote_read, &mut local_write) => ("host", r),
    };
    let _ = remote_write.shutdown().await;
    let _ = local_write.shutdown().await;
    match result {
        // Every channel ends; only a failure is worth a (throttled) line.
        Ok(_) => log::trace!("Remote Hub bridge channel ended by the {direction}"),
        Err(err) => throttled_log!(
            debug,
            "Remote Hub bridge channel to the {direction} failed: {:?}",
            err.kind()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{tls_acceptor, TestCa};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer};

    const HOST: &str = "mac-a.example-tailnet.ts.net";

    struct TestServer {
        addr: SocketAddr,
        connections: Arc<AtomicUsize>,
    }

    /// TLS echo server on loopback that counts TCP connections.
    async fn tls_echo_server(
        cert: CertificateDer<'static>,
        key: PrivateKeyDer<'static>,
    ) -> TestServer {
        let acceptor = tls_acceptor(cert, key);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let connections = Arc::new(AtomicUsize::new(0));
        let counter = connections.clone();
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                counter.fetch_add(1, Ordering::SeqCst);
                let acceptor = acceptor.clone();
                tokio::spawn(async move {
                    if let Ok(tls) = acceptor.accept(tcp).await {
                        let (mut r, mut w) = tokio::io::split(tls);
                        let _ = tokio::io::copy(&mut r, &mut w).await;
                    }
                });
            }
        });
        TestServer { addr, connections }
    }

    fn fast_config() -> BridgeConfig {
        BridgeConfig {
            connect_timeout: Duration::from_secs(2),
            handshake_timeout: Duration::from_secs(2),
            prepare_timeout: Duration::from_secs(2),
            ..BridgeConfig::default()
        }
    }

    async fn open(
        server_addr: SocketAddr,
        roots: RootCertStore,
        cfg: BridgeConfig,
    ) -> Result<TlsBridge, RemoteHubError> {
        TlsBridge::open_target(Target::new(server_addr, HOST, roots).unwrap(), cfg).await
    }

    async fn echo_roundtrip(addr: SocketAddr, payload: &[u8]) -> Vec<u8> {
        let mut engine = TcpStream::connect(addr).await.unwrap();
        engine.write_all(payload).await.unwrap();
        let mut buf = vec![0; payload.len()];
        engine.read_exact(&mut buf).await.unwrap();
        buf
    }

    #[tokio::test]
    async fn carries_engine_bytes_after_verifying_the_host_certificate() {
        let ca = TestCa::new();
        let (cert, key) = ca.issue(HOST, false);
        let server = tls_echo_server(cert, key).await;
        let bridge = open(server.addr, ca.roots(), fast_config()).await.unwrap();
        assert!(bridge.engine_dial_address().ip().is_loopback());
        assert_eq!(bridge.verified_server_name(), HOST);
        assert_eq!(
            echo_roundtrip(bridge.engine_dial_address(), b"hello").await,
            b"hello"
        );
    }

    #[tokio::test]
    async fn tls_failures_are_typed_and_never_fall_back() {
        let ca = TestCa::new();
        let cases = [
            (
                ca.issue("mac-b.example-tailnet.ts.net", false),
                ca.roots(),
                ErrorCode::TlsNameMismatch,
            ),
            (
                ca.issue(HOST, true),
                ca.roots(),
                ErrorCode::TlsCertificateExpired,
            ),
            (
                ca.issue(HOST, false),
                TestCa::new().roots(),
                ErrorCode::TlsCertificateInvalid,
            ),
        ];
        for ((cert, key), roots, expected) in cases {
            let server = tls_echo_server(cert, key).await;
            let err = open(server.addr, roots, fast_config()).await.err().unwrap();
            assert_eq!(err.code, expected, "{err}");
            assert_eq!(
                server.connections.load(Ordering::SeqCst),
                1,
                "no retry or downgrade"
            );
        }
    }

    #[tokio::test]
    async fn plain_tcp_endpoint_is_rejected_not_used_raw() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut r, mut w) = tcp.into_split();
                    let _ = tokio::io::copy(&mut r, &mut w).await;
                });
            }
        });
        let err = open(addr, TestCa::new().roots(), fast_config())
            .await
            .err()
            .unwrap();
        assert_eq!(err.code, ErrorCode::TlsHandshakeFailed);
    }

    #[tokio::test]
    async fn unreachable_endpoint_reports_typed_error() {
        let addr = TcpListener::bind("127.0.0.1:0")
            .await
            .unwrap()
            .local_addr()
            .unwrap();
        let err = open(addr, TestCa::new().roots(), fast_config())
            .await
            .err()
            .unwrap();
        assert_eq!(err.code, ErrorCode::EndpointUnreachable);
    }

    #[tokio::test]
    async fn close_and_prepare_timeout_release_the_loopback_port() {
        let ca = TestCa::new();
        let (cert, key) = ca.issue(HOST, false);
        let server = tls_echo_server(cert, key).await;

        let bridge = open(server.addr, ca.roots(), fast_config()).await.unwrap();
        let addr = bridge.engine_dial_address();
        bridge.close().await;
        assert!(TcpStream::connect(addr).await.is_err());

        let cfg = BridgeConfig {
            prepare_timeout: Duration::from_millis(50),
            ..fast_config()
        };
        let bridge = open(server.addr, ca.roots(), cfg).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(bridge.is_closed());
        assert!(TcpStream::connect(bridge.engine_dial_address())
            .await
            .is_err());
    }

    async fn wait_closed(bridge: &TlsBridge) {
        timeout(Duration::from_secs(5), async {
            while !bridge.is_closed() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("bridge must close when its session ends");
    }

    #[tokio::test]
    async fn session_end_closes_the_bridge_and_its_extra_channels() {
        let ca = TestCa::new();
        let (cert, key) = ca.issue(HOST, false);
        let server = tls_echo_server(cert, key).await;
        let bridge = open(server.addr, ca.roots(), fast_config()).await.unwrap();
        let addr = bridge.engine_dial_address();

        let mut session = TcpStream::connect(addr).await.unwrap();
        session.write_all(b"s").await.unwrap();
        let mut buf = [0u8; 1];
        session.read_exact(&mut buf).await.unwrap();
        let mut extra = TcpStream::connect(addr).await.unwrap();
        extra.write_all(b"e").await.unwrap();
        extra.read_exact(&mut buf).await.unwrap();
        assert!(!bridge.is_closed());

        // The engine closes the session socket: the viewer was closed.
        drop(session);
        wait_closed(&bridge).await;
        assert!(
            TcpStream::connect(addr).await.is_err(),
            "loopback port is released"
        );
        let read = timeout(Duration::from_secs(2), extra.read(&mut buf))
            .await
            .unwrap();
        assert!(matches!(read, Ok(0) | Err(_)), "extra channel is closed");
        assert_eq!(server.connections.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn host_closing_the_session_closes_the_bridge() {
        let ca = TestCa::new();
        let (cert, key) = ca.issue(HOST, false);
        let acceptor = tls_acceptor(cert, key);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = listener.local_addr().unwrap();
        // Host accepts the TLS channel, then ends the session.
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                let acceptor = acceptor.clone();
                tokio::spawn(async move {
                    if let Ok(mut tls) = acceptor.accept(tcp).await {
                        let mut buf = [0u8; 1];
                        let _ = tls.read_exact(&mut buf).await;
                        let _ = tls.shutdown().await;
                    }
                });
            }
        });
        let bridge = open(server_addr, ca.roots(), fast_config()).await.unwrap();
        let addr = bridge.engine_dial_address();
        let mut session = TcpStream::connect(addr).await.unwrap();
        session.write_all(b"x").await.unwrap();
        // The engine keeps its socket open; the host's close alone ends it.
        wait_closed(&bridge).await;
        assert!(TcpStream::connect(addr).await.is_err());
        let mut buf = [0u8; 1];
        let read = timeout(Duration::from_secs(2), session.read(&mut buf))
            .await
            .unwrap();
        assert!(matches!(read, Ok(0) | Err(_)), "engine sees the end");
    }

    #[tokio::test]
    async fn extra_engine_sockets_get_own_channels_up_to_the_limit() {
        let ca = TestCa::new();
        let (cert, key) = ca.issue(HOST, false);
        let server = tls_echo_server(cert, key).await;
        let cfg = BridgeConfig {
            max_sockets: 2,
            ..fast_config()
        };
        let bridge = open(server.addr, ca.roots(), cfg).await.unwrap();
        let addr = bridge.engine_dial_address();
        let mut first = TcpStream::connect(addr).await.unwrap();
        // The second channel stays open, so both slots are in use.
        let mut second = TcpStream::connect(addr).await.unwrap();
        second.write_all(b"2").await.unwrap();
        let mut buf = [0u8; 1];
        second.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"2");
        assert_eq!(server.connections.load(Ordering::SeqCst), 2);

        let mut over_limit = TcpStream::connect(addr).await.unwrap();
        let read = timeout(Duration::from_secs(2), over_limit.read(&mut buf))
            .await
            .unwrap();
        assert!(
            matches!(read, Ok(0) | Err(_)),
            "socket over the limit is closed"
        );
        assert_eq!(server.connections.load(Ordering::SeqCst), 2);

        first.write_all(b"x").await.unwrap();
        first.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"x");
    }

    #[tokio::test]
    async fn finished_extra_channels_free_their_slot() {
        let ca = TestCa::new();
        let (cert, key) = ca.issue(HOST, false);
        let server = tls_echo_server(cert, key).await;
        let cfg = BridgeConfig {
            max_sockets: 2,
            ..fast_config()
        };
        let bridge = open(server.addr, ca.roots(), cfg).await.unwrap();
        let addr = bridge.engine_dial_address();
        let mut session = TcpStream::connect(addr).await.unwrap();

        // Each replacement channel ends (the engine drops it) before the next
        // one opens, so the session never has more than two sockets at once.
        for round in 0..5u8 {
            let payload = [b'a' + round];
            let echoed = timeout(Duration::from_secs(5), async {
                loop {
                    let mut engine = TcpStream::connect(addr).await.unwrap();
                    engine.write_all(&payload).await.unwrap();
                    let mut buf = [0u8; 1];
                    // A refused socket is closed; the slot may still be
                    // releasing from the previous round, so retry.
                    if matches!(engine.read(&mut buf).await, Ok(1)) {
                        return buf;
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            })
            .await
            .expect("a finished channel must free its slot");
            assert_eq!(echoed, payload);
        }
        assert_eq!(server.connections.load(Ordering::SeqCst), 6);

        let mut buf = [0u8; 1];
        session.write_all(b"s").await.unwrap();
        session.read_exact(&mut buf).await.unwrap();
        assert!(!bridge.is_closed());
    }
}
