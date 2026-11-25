//! Remote Hub: tailnet-only network policy and the controller-side TLS bridge.
//!
//! Nothing here replaces the RustDesk engine. The engine keeps its protocol and
//! authentication; this crate only decides which sockets may exist and carries
//! engine bytes over a verified TLS channel to one owner-approved host.

pub mod endpoint;
pub mod error;
pub mod log_retention;
mod log_throttle;
pub mod policy;
#[cfg(any(test, feature = "test-support"))]
pub mod test_support;
pub mod transport;

pub use endpoint::RemoteEndpoint;
pub use error::ErrorCode;
pub use policy::{Capability, DialTarget, Role, TailnetOnlyPolicy};
pub use transport::{BridgeConfig, TlsBridge};
