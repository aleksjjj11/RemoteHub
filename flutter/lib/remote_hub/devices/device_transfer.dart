import 'dart:convert';
import 'dart:io';

import 'device_record.dart';

/// Device metadata transfer between the owner's controllers (plan 12.2,
/// 13.2, RH-020). Only secret-free metadata moves: exports drop the
/// credential handle and ownership confirmation, imports never connect,
/// reset confirmation and session history, and are shown to the owner
/// before anything is saved.

/// The text the owner copies to another controller.
String exportDevices(DeviceCatalog catalog) => catalog.encode(forExport: true);

/// Why an imported device is not added.
enum ImportSkipReason { sameId, sameEndpoint }

class SkippedImport {
  const SkippedImport(this.device, this.reason);

  final DeviceRecord device;
  final ImportSkipReason reason;
}

/// What an import would change; nothing is saved until the owner confirms.
class DeviceImportPlan {
  const DeviceImportPlan({required this.added, required this.skipped});

  /// New, unconfirmed devices without a stored password.
  final List<DeviceRecord> added;

  /// Devices already in the list (same id or same endpoint), left untouched.
  final List<SkippedImport> skipped;
}

/// Parses [text] as an import and decides which devices it adds to
/// [current]. Existing devices are never replaced, so an import cannot change
/// an endpoint the owner already confirmed or drop a stored password.
///
/// Throws [DeviceConfigException] for invalid metadata or when the result
/// would exceed [kMaxDevices].
DeviceImportPlan planDeviceImport(DeviceCatalog current, String text) {
  final imported = DeviceCatalog.decode(text, fromImport: true);
  final ids = {for (final d in current.devices) d.id};
  final endpoints = {for (final d in current.devices) d.endpoint};
  final added = <DeviceRecord>[];
  final skipped = <SkippedImport>[];
  for (final d in imported.devices) {
    if (ids.contains(d.id)) {
      skipped.add(SkippedImport(d, ImportSkipReason.sameId));
    } else if (endpoints.contains(d.endpoint)) {
      skipped.add(SkippedImport(d, ImportSkipReason.sameEndpoint));
    } else {
      // Session history belongs to the controller that made the sessions.
      added.add(DeviceRecord.create(
        id: d.id,
        label: d.label,
        platform: d.platform,
        endpoint: d.endpoint,
        preferences: d.preferences,
      ));
      endpoints.add(d.endpoint);
    }
  }
  if (current.devices.length + added.length > kMaxDevices) {
    throw DeviceConfigException('at most $kMaxDevices devices');
  }
  return DeviceImportPlan(added: added, skipped: skipped);
}

/// Whether two plans add the same devices with the same endpoints.
bool sameImportPlan(DeviceImportPlan a, DeviceImportPlan b) =>
    a.added.length == b.added.length &&
    [
      for (var i = 0; i < a.added.length; i++)
        a.added[i].id == b.added[i].id &&
            a.added[i].endpoint == b.added[i].endpoint &&
            a.added[i].label == b.added[i].label
    ].every((same) => same);

/// The list after the owner confirmed [plan].
DeviceCatalog applyDeviceImport(DeviceCatalog current, DeviceImportPlan plan) =>
    DeviceCatalog([...current.devices, ...plan.added]);

/// Reads an import file the owner picked. The size is checked before
/// reading, so an oversized file is never loaded into memory.
Future<String> readDeviceImportFile(File file) async {
  final int length;
  try {
    length = await file.length();
  } on FileSystemException {
    throw DeviceConfigException('metadata file could not be read');
  }
  if (length > kMaxMetadataBytes) {
    throw DeviceConfigException('metadata file is larger than 64 KiB');
  }
  try {
    return utf8.decode(await file.readAsBytes());
  } on FileSystemException {
    throw DeviceConfigException('metadata file could not be read');
  } on FormatException {
    throw DeviceConfigException('metadata file is not UTF-8 text');
  }
}
