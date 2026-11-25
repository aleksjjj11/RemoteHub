/// Remote Hub error catalog (plan 9.5). The same codes are produced by the
/// native `remote_hub` crate (`libs/remote_hub/src/error.rs`).
enum RemoteHubErrorCode {
  invalidDeviceConfig(
      'INVALID_DEVICE_CONFIG', 'The device settings are invalid.'),
  tailnetUnavailable('TAILNET_UNAVAILABLE', 'Tailscale is not connected.'),
  endpointUnreachable('ENDPOINT_UNREACHABLE', 'The computer does not answer.'),
  tlsNameMismatch(
      'TLS_NAME_MISMATCH', 'The certificate belongs to a different computer.'),
  tlsCertificateInvalid(
      'TLS_CERTIFICATE_INVALID', 'The host certificate is not trusted.'),
  tlsCertificateExpired(
      'TLS_CERTIFICATE_EXPIRED', 'The host certificate has expired.'),
  tlsHandshakeFailed(
      'TLS_HANDSHAKE_FAILED', 'A secure connection could not be set up.'),
  authenticationFailed('AUTHENTICATION_FAILED', 'Wrong password.'),
  authenticationRateLimited(
      'AUTHENTICATION_RATE_LIMITED', 'Too many attempts. Wait and try again.'),
  hostBusy('HOST_BUSY', 'Another controller is already connected.'),
  hostDisabled(
      'HOST_DISABLED', 'Remote access is turned off on this computer.'),
  hostPermissionRequired('HOST_PERMISSION_REQUIRED',
      'The computer needs screen or input permission.'),
  hostSessionUnavailable(
      'HOST_SESSION_UNAVAILABLE', 'No user session is available on the host.'),
  captureUnavailable('CAPTURE_UNAVAILABLE', 'The screen cannot be captured.'),
  inputNotAllowed('INPUT_NOT_ALLOWED', 'Control is not allowed: view only.'),
  unsupportedCapability(
      'UNSUPPORTED_CAPABILITY', 'This action is not supported.'),
  nativeLibraryUnavailable(
      'NATIVE_LIBRARY_UNAVAILABLE', 'The native engine failed to load.'),
  protocolMismatch(
      'PROTOCOL_MISMATCH', 'The host runs an incompatible version.'),
  connectionLost('CONNECTION_LOST', 'The connection was lost.'),
  cancelled('CANCELLED', 'Cancelled.'),
  internalError('INTERNAL_ERROR', 'Internal error.');

  const RemoteHubErrorCode(this.code, this.userMessage);

  final String code;
  final String userMessage;

  /// Only network-level failures may trigger an automatic reconnect. A wrong
  /// password or any TLS failure stops the attempt (plan 7.6, 10.3).
  bool get isRetryable =>
      this == tailnetUnavailable ||
      this == endpointUnreachable ||
      this == connectionLost;

  static RemoteHubErrorCode fromCode(String code) => RemoteHubErrorCode.values
      .firstWhere((e) => e.code == code, orElse: () => internalError);
}
