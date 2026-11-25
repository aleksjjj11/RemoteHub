//! Test-only TLS fixtures: an in-memory test CA and a Tailscale Serve stand-in.
//! Compiled for this crate's tests and for dependents that enable the
//! `test-support` feature as a dev-dependency only; never in a release build
//! (plan 24.3: the test CA is never a production trust root).

use crate::{
    error::RemoteHubError,
    transport::{BridgeConfig, Target, TlsBridge},
};
use rcgen::{
    date_time_ymd, BasicConstraints, Certificate, CertificateParams, DnType, IsCa, KeyPair,
};
use std::{net::SocketAddr, sync::Arc};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::{
    rustls::{
        self,
        pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer},
        RootCertStore, ServerConfig,
    },
    TlsAcceptor,
};

pub struct TestCa {
    cert: Certificate,
    key: KeyPair,
}

impl TestCa {
    pub fn new() -> Self {
        let key = KeyPair::generate().expect("test key");
        let mut params = CertificateParams::new(Vec::<String>::new()).expect("test params");
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params
            .distinguished_name
            .push(DnType::CommonName, "Remote Hub test CA");
        let cert = params.self_signed(&key).expect("test CA");
        Self { cert, key }
    }

    pub fn roots(&self) -> RootCertStore {
        let mut roots = RootCertStore::empty();
        roots.add(self.cert.der().clone()).expect("test root");
        roots
    }

    pub fn issue(
        &self,
        name: &str,
        expired: bool,
    ) -> (CertificateDer<'static>, PrivateKeyDer<'static>) {
        let key = KeyPair::generate().expect("test key");
        let mut params = CertificateParams::new(vec![name.to_owned()]).expect("test params");
        if expired {
            params.not_before = date_time_ymd(2020, 1, 1);
            params.not_after = date_time_ymd(2021, 1, 1);
        }
        let cert = params
            .signed_by(&key, &self.cert, &self.key)
            .expect("test leaf");
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        (cert.der().clone(), key)
    }
}

impl Default for TestCa {
    fn default() -> Self {
        Self::new()
    }
}

pub fn tls_acceptor(cert: CertificateDer<'static>, key: PrivateKeyDer<'static>) -> TlsAcceptor {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("test TLS versions")
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .expect("test TLS cert");
    TlsAcceptor::from(Arc::new(config))
}

/// Stand-in for `tailscale serve --tls-terminated-tcp=21118 tcp://127.0.0.1:22118`:
/// terminates TLS on a loopback port and forwards each connection to `backend`.
pub async fn serve_tls_terminated_tcp(
    cert: CertificateDer<'static>,
    key: PrivateKeyDer<'static>,
    backend: SocketAddr,
) -> SocketAddr {
    let acceptor = tls_acceptor(cert, key);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("test bind");
    let addr = listener.local_addr().expect("test addr");
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let Ok(mut tls) = acceptor.accept(tcp).await else {
                    return;
                };
                let Ok(mut plain) = TcpStream::connect(backend).await else {
                    return;
                };
                let _ = tokio::io::copy_bidirectional(&mut tls, &mut plain).await;
            });
        }
    });
    addr
}

impl TlsBridge {
    /// Like [`TlsBridge::open`] but trusting `roots` and dialing `addr`, so a
    /// test can use a loopback fixture with a test CA.
    pub async fn open_for_test(
        addr: SocketAddr,
        server_name: &str,
        roots: RootCertStore,
        cfg: BridgeConfig,
    ) -> Result<Self, RemoteHubError> {
        Self::open_target(Target::new(addr, server_name, roots)?, cfg).await
    }
}
