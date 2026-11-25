use crate::{
    error::{ErrorCode, RemoteHubError},
    policy::SERVE_TLS_PORT,
};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

const MAX_DNS_NAME_LEN: usize = 253;
const MAX_DNS_LABEL_LEN: usize = 63;
const TAILSCALE_DNS_SUFFIX: &str = ".ts.net";

/// Owner-approved address of one host: a tailnet IPv4 to dial and the exact
/// full MagicDNS name the TLS certificate must match (plan 7.3, 7.4).
///
/// The IPv4 range check is only a format check. Being in 100.64.0.0/10 proves
/// nothing about which device answers; the certificate name does that.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteEndpoint {
    approved_tailnet_ipv4: Ipv4Addr,
    tls_port: u16,
    tls_server_name: String,
}

impl RemoteEndpoint {
    pub fn new(
        approved_tailnet_ipv4: &str,
        tls_port: u16,
        tls_server_name: &str,
    ) -> Result<Self, RemoteHubError> {
        let ip: Ipv4Addr = approved_tailnet_ipv4.trim().parse().map_err(|_| {
            RemoteHubError::new(
                ErrorCode::InvalidDeviceConfig,
                "tailnet address is not IPv4",
            )
        })?;
        if !is_tailscale_cgnat(ip) {
            return Err(RemoteHubError::new(
                ErrorCode::InvalidDeviceConfig,
                "address is outside the Tailscale range 100.64.0.0/10",
            ));
        }
        if tls_port != SERVE_TLS_PORT {
            return Err(RemoteHubError::new(
                ErrorCode::InvalidDeviceConfig,
                format!("TLS port must be {SERVE_TLS_PORT}"),
            ));
        }
        let name = normalize_magicdns_name(tls_server_name)?;
        Ok(Self {
            approved_tailnet_ipv4: ip,
            tls_port,
            tls_server_name: name,
        })
    }

    pub fn approved_tailnet_ipv4(&self) -> Ipv4Addr {
        self.approved_tailnet_ipv4
    }

    pub fn tls_port(&self) -> u16 {
        self.tls_port
    }

    pub fn tls_server_name(&self) -> &str {
        &self.tls_server_name
    }

    pub fn socket_addr(&self) -> SocketAddr {
        SocketAddr::V4(SocketAddrV4::new(self.approved_tailnet_ipv4, self.tls_port))
    }
}

fn is_tailscale_cgnat(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (64..=127).contains(&b)
}

/// Accepts only a full `<host>.<tailnet>.ts.net` DNS name: no IP literal, no
/// port, no scheme, no wildcard, nothing a shell or path could interpret.
fn normalize_magicdns_name(raw: &str) -> Result<String, RemoteHubError> {
    let invalid = |why: &str| RemoteHubError::new(ErrorCode::InvalidDeviceConfig, why.to_owned());
    let name = raw.trim().trim_end_matches('.').to_ascii_lowercase();
    if name.is_empty() || name.len() > MAX_DNS_NAME_LEN {
        return Err(invalid("TLS server name has an invalid length"));
    }
    if !name.ends_with(TAILSCALE_DNS_SUFFIX) {
        return Err(invalid(
            "TLS server name must be the full MagicDNS name (*.ts.net)",
        ));
    }
    let labels: Vec<&str> = name.split('.').collect();
    if labels.len() < 4 {
        return Err(invalid(
            "TLS server name must include the host and tailnet labels",
        ));
    }
    for label in &labels {
        let valid = !label.is_empty()
            && label.len() <= MAX_DNS_LABEL_LEN
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-');
        if !valid {
            return Err(invalid("TLS server name contains an invalid DNS label"));
        }
    }
    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_owner_approved_endpoint_and_normalizes_name() {
        let ep =
            RemoteEndpoint::new("100.101.102.20", 21118, "Mac-A.Example-Tailnet.ts.net.").unwrap();
        assert_eq!(ep.tls_server_name(), "mac-a.example-tailnet.ts.net");
        assert_eq!(ep.socket_addr().to_string(), "100.101.102.20:21118");
    }

    #[test]
    fn rejects_addresses_outside_tailnet_and_other_ports() {
        let name = "mac-a.example-tailnet.ts.net";
        for ip in [
            "192.168.1.20",
            "8.8.8.8",
            "127.0.0.1",
            "100.128.0.1",
            "fd7a::1",
            "",
        ] {
            let err = RemoteEndpoint::new(ip, 21118, name).unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidDeviceConfig, "{ip}");
        }
        for port in [22118, 21116, 443, 0] {
            assert!(RemoteEndpoint::new("100.101.102.20", port, name).is_err());
        }
    }

    #[test]
    fn rejects_names_that_are_not_full_magicdns_names() {
        for name in [
            "mac-a",
            "ts.net",
            "example-tailnet.ts.net",
            "100.101.102.20",
            "mac-a.example.com",
            "*.example-tailnet.ts.net",
            "mac-a.example-tailnet.ts.net:21118",
            "https://mac-a.example-tailnet.ts.net",
            "mac-a;rm -rf ~.example-tailnet.ts.net",
            "../mac-a.example-tailnet.ts.net",
            "-mac.example-tailnet.ts.net",
            "mac..example-tailnet.ts.net",
        ] {
            assert!(
                RemoteEndpoint::new("100.101.102.20", 21118, name).is_err(),
                "{name}"
            );
        }
    }
}
