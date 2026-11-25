import '../errors.dart';
import 'device_record.dart';

/// Status line of a device card. It states only what the app checked: the
/// TLS certificate name of a live bridge. The app does not query Tailscale,
/// so the network path (direct, DERP relay, or whether Tailscale carries the
/// connection at all) is reported as not checked, as in diagnostics.
String deviceStatusLine({
  RemoteHubErrorCode? lastError,
  String? verifiedServerName,
}) {
  if (lastError != null) return 'Last attempt: ${lastError.userMessage}';
  if (verifiedServerName != null) {
    return 'Certificate verified: $verifiedServerName · Transport: TLS · '
        'Network path: not checked';
  }
  return 'Status: not checked';
}

/// Certificate name to show for a device card at [shown], or null.
///
/// [nativeName] is what the live bridge of the device verified ("" when none
/// is open); [connectedTo] is the endpoint the app last connected to. After
/// the owner edits the endpoint, a bridge still open to the old one says
/// nothing about the new address, so it is not shown.
String? verifiedNameFor(
  RemoteEndpoint shown, {
  required RemoteEndpoint? connectedTo,
  required String nativeName,
}) {
  if (nativeName.isEmpty || connectedTo != shown) return null;
  return nativeName == shown.tlsServerName ? nativeName : null;
}
