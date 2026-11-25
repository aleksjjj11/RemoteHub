use std::{
    fmt,
    net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4},
};

/// Tailscale Serve TLS entry point on every host (only reachable in the tailnet).
pub const SERVE_TLS_PORT: u16 = 21118;
/// The host engine's direct listener. Loopback only; Serve forwards to it.
pub const HOST_BIND_PORT: u16 = 22118;
/// Logins a host holds open before they authenticate (plan 7.5). Serve hands
/// every session to the loopback listener from 127.0.0.1, so this is the cap
/// for the one address all of them share.
pub const UNAUTHENTICATED_SESSION_CAP: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Controller,
    Host,
}

/// Network destinations a Remote Hub process may try to reach.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DialTarget {
    /// The in-process TLS bridge to an owner-approved endpoint.
    TlsBridge,
    /// A raw TCP connection straight to a remote host, bypassing TLS.
    RawRemote,
    /// RustDesk ID/rendezvous servers.
    PublicRendezvous,
    /// RustDesk relay servers.
    RustdeskRelay,
    /// LAN broadcast discovery.
    LanDiscovery,
}

/// Session capabilities. Only the first five are granted in v0.1 (plan 17.3);
/// everything else is denied by the host regardless of what the UI shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capability {
    ViewScreen,
    SendPointer,
    SendKeyboard,
    SelectDisplay,
    AdjustSupportedQuality,
    Clipboard,
    FileTransfer,
    Terminal,
    Tunnel,
    Audio,
    RemotePrinter,
    Recording,
    RestartHost,
    BlockInput,
    PrivacyMode,
    Camera,
}

impl Capability {
    pub const ALLOWED_V0_1: [Capability; 5] = [
        Capability::ViewScreen,
        Capability::SendPointer,
        Capability::SendKeyboard,
        Capability::SelectDisplay,
        Capability::AdjustSupportedQuality,
    ];
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PolicyError {
    HostingNotAllowed,
    DialNotAllowed(DialTarget),
    NonLoopbackBind(SocketAddr),
    UnexpectedBindPort(u16),
}

impl fmt::Display for PolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::HostingNotAllowed => f.write_str("hosting is not allowed for a controller"),
            Self::DialNotAllowed(t) => write!(f, "network destination {t:?} is not allowed"),
            Self::NonLoopbackBind(a) => write!(f, "refusing to listen on non-loopback {a}"),
            Self::UnexpectedBindPort(p) => {
                write!(f, "host listener must use port {HOST_BIND_PORT}, not {p}")
            }
        }
    }
}

impl std::error::Error for PolicyError {}

/// The project's own network contract (plan 6.3). Not an upstream flag set:
/// the engine must consult it before starting background tasks and whenever it
/// picks a network path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TailnetOnlyPolicy {
    pub role: Role,
    pub allow_hosting: bool,
    pub allow_public_rendezvous: bool,
    pub allow_rustdesk_relay: bool,
    pub allow_lan_discovery: bool,
    pub allow_raw_remote_dial: bool,
    pub allow_tls_bridge_dial: bool,
    pub require_authentication: bool,
}

impl TailnetOnlyPolicy {
    pub fn for_role(role: Role) -> Self {
        Self {
            role,
            allow_hosting: role == Role::Host,
            allow_public_rendezvous: false,
            allow_rustdesk_relay: false,
            allow_lan_discovery: false,
            allow_raw_remote_dial: false,
            allow_tls_bridge_dial: role == Role::Controller,
            require_authentication: true,
        }
    }

    pub fn check_dial(&self, target: DialTarget) -> Result<(), PolicyError> {
        let allowed = match target {
            DialTarget::TlsBridge => self.allow_tls_bridge_dial,
            DialTarget::RawRemote => self.allow_raw_remote_dial,
            DialTarget::PublicRendezvous => self.allow_public_rendezvous,
            DialTarget::RustdeskRelay => self.allow_rustdesk_relay,
            DialTarget::LanDiscovery => self.allow_lan_discovery,
        };
        if allowed {
            Ok(())
        } else {
            Err(PolicyError::DialNotAllowed(target))
        }
    }

    /// The only address a host may listen on. A controller gets an error.
    pub fn host_listen_addr(&self) -> Result<SocketAddr, PolicyError> {
        if !self.allow_hosting {
            return Err(PolicyError::HostingNotAllowed);
        }
        let addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, HOST_BIND_PORT));
        validate_host_bind(addr)?;
        Ok(addr)
    }

    pub fn is_capability_allowed(&self, capability: Capability) -> bool {
        self.allow_hosting && Capability::ALLOWED_V0_1.contains(&capability)
    }
}

/// Rejects wildcard, LAN, public and IPv6 binds. There is no fallback: if
/// 127.0.0.1:22118 cannot be bound the host stays unavailable (plan 3.3).
pub fn validate_host_bind(addr: SocketAddr) -> Result<(), PolicyError> {
    if addr.ip() != IpAddr::V4(Ipv4Addr::LOCALHOST) {
        return Err(PolicyError::NonLoopbackBind(addr));
    }
    if addr.port() != HOST_BIND_PORT {
        return Err(PolicyError::UnexpectedBindPort(addr.port()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controller_cannot_host_and_only_dials_through_tls_bridge() {
        let p = TailnetOnlyPolicy::for_role(Role::Controller);
        assert_eq!(p.host_listen_addr(), Err(PolicyError::HostingNotAllowed));
        assert!(p.check_dial(DialTarget::TlsBridge).is_ok());
        for t in [
            DialTarget::RawRemote,
            DialTarget::PublicRendezvous,
            DialTarget::RustdeskRelay,
            DialTarget::LanDiscovery,
        ] {
            assert_eq!(p.check_dial(t), Err(PolicyError::DialNotAllowed(t)));
        }
        assert!(!p.is_capability_allowed(Capability::ViewScreen));
    }

    #[test]
    fn host_listens_only_on_loopback_22118() {
        let p = TailnetOnlyPolicy::for_role(Role::Host);
        assert_eq!(p.host_listen_addr().unwrap().to_string(), "127.0.0.1:22118");
        assert!(p.require_authentication);
        assert!(p.check_dial(DialTarget::PublicRendezvous).is_err());
        assert!(p.check_dial(DialTarget::LanDiscovery).is_err());
        for bad in [
            "0.0.0.0:22118",
            "[::]:22118",
            "[::1]:22118",
            "192.168.1.5:22118",
            "8.8.8.8:22118",
        ] {
            let addr: SocketAddr = bad.parse().unwrap();
            assert_eq!(
                validate_host_bind(addr),
                Err(PolicyError::NonLoopbackBind(addr))
            );
        }
        assert_eq!(
            validate_host_bind("127.0.0.1:21118".parse().unwrap()),
            Err(PolicyError::UnexpectedBindPort(21118))
        );
    }

    #[test]
    fn host_grants_only_the_v0_1_capabilities() {
        let p = TailnetOnlyPolicy::for_role(Role::Host);
        for c in Capability::ALLOWED_V0_1 {
            assert!(p.is_capability_allowed(c));
        }
        for c in [
            Capability::Clipboard,
            Capability::FileTransfer,
            Capability::Terminal,
            Capability::Tunnel,
            Capability::Audio,
            Capability::RemotePrinter,
            Capability::Recording,
            Capability::RestartHost,
            Capability::BlockInput,
            Capability::PrivacyMode,
            Capability::Camera,
        ] {
            assert!(!p.is_capability_allowed(c), "{c:?}");
        }
    }
}
