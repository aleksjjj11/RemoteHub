/// True in a Remote Hub build (`--dart-define=REMOTE_HUB=true`, set by
/// `tools/build-*.sh`). It only selects the UI; the native `remote_hub` cargo
/// feature enforces the network policy, and the app refuses to start the
/// Remote Hub UI on a native library built without it.
const bool kRemoteHub = bool.fromEnvironment('REMOTE_HUB');

/// Engine peer id of a device: `rh` + the logical UUID without dashes. Upstream
/// peer settings are stored under it, never under a temporary loopback port.
String peerIdFor(String deviceId) => 'rh${deviceId.replaceAll('-', '')}';
