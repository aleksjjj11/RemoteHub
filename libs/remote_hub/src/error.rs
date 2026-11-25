use std::fmt;

/// Error catalog shared with the UI (plan section 9.5). Codes are stable
/// strings; the user-facing text never contains secrets, keystrokes or packets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    InvalidDeviceConfig,
    TailnetUnavailable,
    EndpointUnreachable,
    TlsNameMismatch,
    TlsCertificateInvalid,
    TlsCertificateExpired,
    TlsHandshakeFailed,
    AuthenticationFailed,
    AuthenticationRateLimited,
    HostBusy,
    HostDisabled,
    HostPermissionRequired,
    HostSessionUnavailable,
    CaptureUnavailable,
    InputNotAllowed,
    UnsupportedCapability,
    NativeLibraryUnavailable,
    ProtocolMismatch,
    ConnectionLost,
    Cancelled,
    InternalError,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidDeviceConfig => "INVALID_DEVICE_CONFIG",
            Self::TailnetUnavailable => "TAILNET_UNAVAILABLE",
            Self::EndpointUnreachable => "ENDPOINT_UNREACHABLE",
            Self::TlsNameMismatch => "TLS_NAME_MISMATCH",
            Self::TlsCertificateInvalid => "TLS_CERTIFICATE_INVALID",
            Self::TlsCertificateExpired => "TLS_CERTIFICATE_EXPIRED",
            Self::TlsHandshakeFailed => "TLS_HANDSHAKE_FAILED",
            Self::AuthenticationFailed => "AUTHENTICATION_FAILED",
            Self::AuthenticationRateLimited => "AUTHENTICATION_RATE_LIMITED",
            Self::HostBusy => "HOST_BUSY",
            Self::HostDisabled => "HOST_DISABLED",
            Self::HostPermissionRequired => "HOST_PERMISSION_REQUIRED",
            Self::HostSessionUnavailable => "HOST_SESSION_UNAVAILABLE",
            Self::CaptureUnavailable => "CAPTURE_UNAVAILABLE",
            Self::InputNotAllowed => "INPUT_NOT_ALLOWED",
            Self::UnsupportedCapability => "UNSUPPORTED_CAPABILITY",
            Self::NativeLibraryUnavailable => "NATIVE_LIBRARY_UNAVAILABLE",
            Self::ProtocolMismatch => "PROTOCOL_MISMATCH",
            Self::ConnectionLost => "CONNECTION_LOST",
            Self::Cancelled => "CANCELLED",
            Self::InternalError => "INTERNAL_ERROR",
        }
    }

    /// TLS failures stop the attempt: they are never retried under a weaker
    /// policy and never fall back to raw TCP or a relay (plan 7.6, 10.3).
    pub fn is_tls_failure(self) -> bool {
        matches!(
            self,
            Self::TlsNameMismatch
                | Self::TlsCertificateInvalid
                | Self::TlsCertificateExpired
                | Self::TlsHandshakeFailed
        )
    }

    /// Only network-level failures may reconnect automatically; a wrong
    /// password, a busy or stopped host and every TLS failure stop (plan 10.3).
    pub fn is_retryable(self) -> bool {
        matches!(
            self,
            Self::TailnetUnavailable | Self::EndpointUnreachable | Self::ConnectionLost
        )
    }

    /// The code a "CODE: detail" message starts with, if any.
    pub fn from_message_prefix(text: &str) -> Option<Self> {
        let code = text.split(':').next()?.trim();
        Self::ALL.into_iter().find(|c| c.as_str() == code)
    }

    pub const ALL: [ErrorCode; 21] = [
        Self::InvalidDeviceConfig,
        Self::TailnetUnavailable,
        Self::EndpointUnreachable,
        Self::TlsNameMismatch,
        Self::TlsCertificateInvalid,
        Self::TlsCertificateExpired,
        Self::TlsHandshakeFailed,
        Self::AuthenticationFailed,
        Self::AuthenticationRateLimited,
        Self::HostBusy,
        Self::HostDisabled,
        Self::HostPermissionRequired,
        Self::HostSessionUnavailable,
        Self::CaptureUnavailable,
        Self::InputNotAllowed,
        Self::UnsupportedCapability,
        Self::NativeLibraryUnavailable,
        Self::ProtocolMismatch,
        Self::ConnectionLost,
        Self::Cancelled,
        Self::InternalError,
    ];
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A typed failure with a code and a short, secret-free detail for diagnostics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteHubError {
    pub code: ErrorCode,
    pub detail: String,
}

impl RemoteHubError {
    pub fn new(code: ErrorCode, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }
}

impl fmt::Display for RemoteHubError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.detail)
    }
}

impl std::error::Error for RemoteHubError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_network_codes_retry_and_prefixes_parse() {
        assert_eq!(
            ErrorCode::from_message_prefix("TLS_NAME_MISMATCH: invalid peer certificate"),
            Some(ErrorCode::TlsNameMismatch)
        );
        assert_eq!(
            ErrorCode::from_message_prefix("Connection reset by peer"),
            None
        );
        for c in ErrorCode::ALL {
            assert_eq!(ErrorCode::from_message_prefix(c.as_str()), Some(c));
            assert_eq!(
                c.is_retryable(),
                matches!(
                    c,
                    ErrorCode::TailnetUnavailable
                        | ErrorCode::EndpointUnreachable
                        | ErrorCode::ConnectionLost
                ),
                "{c}"
            );
        }
    }
}
