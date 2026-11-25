import 'dart:convert';

/// Versioned, secret-free device metadata (plan 13.1, 13.2).
///
/// Passwords never appear here: a record only carries an opaque
/// `credentialRef` naming the platform vault entry, and even that is dropped
/// from exports and ignored on import.
const int kDeviceSchemaVersion = 1;
const int kMaxMetadataBytes = 64 * 1024;
const int kMaxDevices = 20;
const int kMaxLabelLength = 80;
const int kServeTlsPort = 21118;
const int kMaxDisplayIdLength = 64;

class DeviceConfigException implements Exception {
  DeviceConfigException(this.message);

  final String message;

  String get code => 'INVALID_DEVICE_CONFIG';

  @override
  String toString() => '$code: $message';
}

enum HostPlatform { macos, windows }

enum QualityPreset { economy, balanced, quality }

enum InputMode { trackpad, touch }

/// v0.1 has no clipboard sync; the only accepted value is `disabled`.
enum ClipboardMode { disabled }

T _enumByName<T extends Enum>(List<T> values, Object? raw, String field) {
  for (final v in values) {
    if (v.name == raw) return v;
  }
  throw DeviceConfigException('unsupported $field');
}

Map<String, Object?> _object(Object? raw, Set<String> allowed, String what) {
  if (raw is! Map<String, dynamic>) {
    throw DeviceConfigException('$what must be an object');
  }
  final unknown = raw.keys.where((k) => !allowed.contains(k)).toList();
  if (unknown.isNotEmpty) {
    // Unknown fields could be security relevant; reject instead of guessing.
    throw DeviceConfigException('unknown field in $what');
  }
  return raw;
}

String _string(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is! String) throw DeviceConfigException('$key must be a string');
  return v;
}

final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _dnsLabel = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
final _controlChars = RegExp(r'[\u0000-\u001f\u007f]');

/// Owner-approved tailnet IPv4, fixed Serve port and the exact full MagicDNS
/// name the host certificate must match. Mirrors the native validation in
/// `libs/remote_hub/src/endpoint.rs`.
class RemoteEndpoint {
  RemoteEndpoint._(this.tailnetIpv4, this.tlsPort, this.tlsServerName);

  factory RemoteEndpoint.validated({
    required String tailnetIpv4,
    int tlsPort = kServeTlsPort,
    required String tlsServerName,
  }) {
    final ip = tailnetIpv4.trim();
    final octets = ip.split('.');
    final parsed =
        octets.map((o) => RegExp(r'^\d{1,3}$').hasMatch(o) ? int.parse(o) : -1);
    if (octets.length != 4 || parsed.any((o) => o < 0 || o > 255)) {
      throw DeviceConfigException('tailnet address is not IPv4');
    }
    final list = parsed.toList();
    if (list[0] != 100 || list[1] < 64 || list[1] > 127) {
      throw DeviceConfigException('address is outside 100.64.0.0/10');
    }
    if (tlsPort != kServeTlsPort) {
      throw DeviceConfigException('TLS port must be $kServeTlsPort');
    }
    var name = tlsServerName.trim().toLowerCase();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    final labels = name.split('.');
    if (name.length > 253 ||
        !name.endsWith('.ts.net') ||
        labels.length < 4 ||
        !labels.every(_dnsLabel.hasMatch)) {
      throw DeviceConfigException(
          'TLS server name must be the full MagicDNS name (*.ts.net)');
    }
    return RemoteEndpoint._(list.join('.'), tlsPort, name);
  }

  factory RemoteEndpoint.fromJson(Object? raw) {
    final json = _object(
        raw, const {'tailnetIpv4', 'tlsPort', 'tlsServerName'}, 'endpoint');
    final port = json['tlsPort'];
    if (port is! int) throw DeviceConfigException('tlsPort must be a number');
    return RemoteEndpoint.validated(
      tailnetIpv4: _string(json, 'tailnetIpv4'),
      tlsPort: port,
      tlsServerName: _string(json, 'tlsServerName'),
    );
  }

  final String tailnetIpv4;
  final int tlsPort;
  final String tlsServerName;

  Map<String, Object?> toJson() => {
        'tailnetIpv4': tailnetIpv4,
        'tlsPort': tlsPort,
        'tlsServerName': tlsServerName,
      };

  @override
  bool operator ==(Object other) =>
      other is RemoteEndpoint &&
      other.tailnetIpv4 == tailnetIpv4 &&
      other.tlsPort == tlsPort &&
      other.tlsServerName == tlsServerName;

  @override
  int get hashCode => Object.hash(tailnetIpv4, tlsPort, tlsServerName);
}

class DevicePreferences {
  const DevicePreferences({
    this.quality = QualityPreset.balanced,
    this.inputMode = InputMode.trackpad,
    this.displayId,
    this.clipboardMode = ClipboardMode.disabled,
  });

  factory DevicePreferences.fromJson(Object? raw) {
    final json = _object(
        raw,
        const {'quality', 'inputMode', 'displayId', 'clipboardMode'},
        'preferences');
    final displayId = json['displayId'];
    if (displayId != null &&
        (displayId is! String ||
            displayId.isEmpty ||
            displayId.length > kMaxDisplayIdLength ||
            _controlChars.hasMatch(displayId))) {
      throw DeviceConfigException('invalid displayId');
    }
    return DevicePreferences(
      quality: _enumByName(QualityPreset.values, json['quality'], 'quality'),
      inputMode: _enumByName(InputMode.values, json['inputMode'], 'inputMode'),
      displayId: displayId as String?,
      clipboardMode: _enumByName(
          ClipboardMode.values, json['clipboardMode'], 'clipboardMode'),
    );
  }

  final QualityPreset quality;
  final InputMode inputMode;

  /// Display ID reported by the host, never a static index.
  final String? displayId;
  final ClipboardMode clipboardMode;

  Map<String, Object?> toJson() => {
        'quality': quality.name,
        'inputMode': inputMode.name,
        'displayId': displayId,
        'clipboardMode': clipboardMode.name,
      };
}

class DeviceRecord {
  DeviceRecord._({
    required this.id,
    required this.label,
    required this.platform,
    required this.endpoint,
    required this.ownerConfirmed,
    required this.credentialRef,
    required this.preferences,
    required this.lastSuccessfulConnectionAt,
  });

  factory DeviceRecord.create({
    required String id,
    required String label,
    required HostPlatform platform,
    required RemoteEndpoint endpoint,
    bool ownerConfirmed = false,
    bool hasStoredCredential = false,
    DevicePreferences preferences = const DevicePreferences(),
    DateTime? lastSuccessfulConnectionAt,
  }) {
    if (!_uuid.hasMatch(id)) {
      throw DeviceConfigException('device id must be a lowercase UUID');
    }
    return DeviceRecord._(
      id: id,
      label: validateLabel(label),
      platform: platform,
      endpoint: endpoint,
      ownerConfirmed: ownerConfirmed,
      credentialRef: hasStoredCredential ? credentialRefFor(id) : null,
      preferences: preferences,
      lastSuccessfulConnectionAt: lastSuccessfulConnectionAt,
    );
  }

  /// [fromImport] marks data from outside the app's own store: ownership
  /// confirmation is reset and no credential handle is taken over.
  factory DeviceRecord.fromJson(Object? raw, {required bool fromImport}) {
    final json = _object(
        raw,
        const {
          'id',
          'label',
          'platform',
          'endpoint',
          'ownerConfirmed',
          'credentialRef',
          'preferences',
          'lastSuccessfulConnectionAt',
        },
        'device');
    final id = _string(json, 'id');
    final confirmed = json['ownerConfirmed'];
    if (confirmed is! bool) {
      throw DeviceConfigException('ownerConfirmed must be a boolean');
    }
    final credentialRef = json['credentialRef'];
    if (credentialRef != null && credentialRef != credentialRefFor(id)) {
      throw DeviceConfigException('credentialRef does not match the device');
    }
    final last = json['lastSuccessfulConnectionAt'];
    DateTime? lastAt;
    if (last != null) {
      lastAt = last is String ? DateTime.tryParse(last) : null;
      if (lastAt == null) {
        throw DeviceConfigException('invalid lastSuccessfulConnectionAt');
      }
    }
    return DeviceRecord.create(
      id: id,
      label: _string(json, 'label'),
      platform: _enumByName(HostPlatform.values, json['platform'], 'platform'),
      endpoint: RemoteEndpoint.fromJson(json['endpoint']),
      ownerConfirmed: fromImport ? false : confirmed,
      hasStoredCredential: !fromImport && credentialRef != null,
      preferences: DevicePreferences.fromJson(json['preferences']),
      lastSuccessfulConnectionAt: lastAt,
    );
  }

  static String credentialRefFor(String id) => 'remotehub/device/$id';

  static String validateLabel(String raw) {
    final label = raw.trim();
    if (label.isEmpty ||
        label.runes.length > kMaxLabelLength ||
        _controlChars.hasMatch(label)) {
      throw DeviceConfigException(
          'label must be 1-$kMaxLabelLength printable characters');
    }
    return label;
  }

  /// Stable logical ID: history, passwords and preferences are keyed by it,
  /// never by the bridge's temporary loopback port.
  final String id;
  final String label;
  final HostPlatform platform;
  final RemoteEndpoint endpoint;
  final bool ownerConfirmed;
  final String? credentialRef;
  final DevicePreferences preferences;
  final DateTime? lastSuccessfulConnectionAt;

  /// A changed address or name needs a new confirmation by the owner (7.4).
  DeviceRecord withEndpoint(RemoteEndpoint next) => DeviceRecord._(
        id: id,
        label: label,
        platform: platform,
        endpoint: next,
        ownerConfirmed: ownerConfirmed && next == endpoint,
        credentialRef: credentialRef,
        preferences: preferences,
        lastSuccessfulConnectionAt: lastSuccessfulConnectionAt,
      );

  /// Points the record at its vault entry, or detaches it.
  DeviceRecord withStoredCredential(bool stored) => DeviceRecord._(
        id: id,
        label: label,
        platform: platform,
        endpoint: endpoint,
        ownerConfirmed: ownerConfirmed,
        credentialRef: stored ? credentialRefFor(id) : null,
        preferences: preferences,
        lastSuccessfulConnectionAt: lastSuccessfulConnectionAt,
      );

  DeviceRecord withLastSuccessfulConnection(DateTime at) => DeviceRecord._(
        id: id,
        label: label,
        platform: platform,
        endpoint: endpoint,
        ownerConfirmed: ownerConfirmed,
        credentialRef: credentialRef,
        preferences: preferences,
        lastSuccessfulConnectionAt: at,
      );

  DeviceRecord confirmedByOwner() => DeviceRecord._(
        id: id,
        label: label,
        platform: platform,
        endpoint: endpoint,
        ownerConfirmed: true,
        credentialRef: credentialRef,
        preferences: preferences,
        lastSuccessfulConnectionAt: lastSuccessfulConnectionAt,
      );

  Map<String, Object?> toJson({required bool forExport}) => {
        'id': id,
        'label': label,
        'platform': platform.name,
        'endpoint': endpoint.toJson(),
        'ownerConfirmed': forExport ? false : ownerConfirmed,
        if (!forExport) 'credentialRef': credentialRef,
        'preferences': preferences.toJson(),
        'lastSuccessfulConnectionAt':
            lastSuccessfulConnectionAt?.toUtc().toIso8601String(),
      };
}

class DeviceCatalog {
  DeviceCatalog(List<DeviceRecord> devices)
      : devices = List.unmodifiable(devices) {
    if (devices.length > kMaxDevices) {
      throw DeviceConfigException('at most $kMaxDevices devices');
    }
    final ids = devices.map((d) => d.id).toSet();
    if (ids.length != devices.length) {
      throw DeviceConfigException('duplicate device id');
    }
  }

  final List<DeviceRecord> devices;

  /// Parses the app's own store ([fromImport] false) or an imported file.
  /// Imports never connect automatically; the UI must show every endpoint
  /// to the owner for confirmation.
  static DeviceCatalog decode(String text, {required bool fromImport}) {
    if (utf8.encode(text).length > kMaxMetadataBytes) {
      throw DeviceConfigException('metadata file is larger than 64 KiB');
    }
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw DeviceConfigException('metadata is not valid JSON');
    }
    final json = _object(raw, const {'schemaVersion', 'devices'}, 'metadata');
    if (json['schemaVersion'] != kDeviceSchemaVersion) {
      throw DeviceConfigException('unsupported schema version');
    }
    final list = json['devices'];
    if (list is! List) throw DeviceConfigException('devices must be a list');
    if (list.length > kMaxDevices) {
      throw DeviceConfigException('at most $kMaxDevices devices');
    }
    return DeviceCatalog([
      for (final d in list) DeviceRecord.fromJson(d, fromImport: fromImport)
    ]);
  }

  String encode({required bool forExport}) =>
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': kDeviceSchemaVersion,
        'devices': [for (final d in devices) d.toJson(forExport: forExport)],
      });
}
