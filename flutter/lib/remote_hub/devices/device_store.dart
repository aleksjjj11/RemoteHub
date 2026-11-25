import 'dart:convert';
import 'dart:io';

import 'device_record.dart';

/// Local metadata file with atomic replace and a backup before a schema
/// change (plan 13.7). The file name is fixed, so nothing from the metadata
/// can steer a write outside [directory].
class DeviceStore {
  DeviceStore(this.directory);

  static const fileName = 'remote_hub_devices.json';

  final Directory directory;

  File get _file => File('${directory.path}${Platform.pathSeparator}$fileName');

  /// A missing file is an empty catalog. A damaged file is reported and left
  /// in place, never silently replaced. Anything else at the path (a
  /// directory, an unreadable file) throws a [FileSystemException].
  Future<DeviceCatalog> load() async {
    final type = await FileSystemEntity.type(_file.path, followLinks: true);
    if (type == FileSystemEntityType.notFound) return DeviceCatalog(const []);
    return DeviceCatalog.decode(await _file.readAsString(), fromImport: false);
  }

  Future<void> save(DeviceCatalog catalog) async {
    await directory.create(recursive: true);
    await _backupUnlessValidCurrentSchema();
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(catalog.encode(forExport: false), flush: true);
    await tmp.rename(_file.path);
  }

  /// Only a file that fully decodes as the current schema may be replaced
  /// without a copy; anything else is kept for recovery.
  Future<void> _backupUnlessValidCurrentSchema() async {
    if (!await _file.exists()) return;
    final text = await _file.readAsString();
    try {
      DeviceCatalog.decode(text, fromImport: false);
      return;
    } on DeviceConfigException {
      // Fall through to the backup below.
    }
    Object? version;
    try {
      final json = jsonDecode(text);
      version = json is Map ? json['schemaVersion'] : null;
    } on FormatException {
      version = null;
    }
    final tag = version is int && version != kDeviceSchemaVersion
        ? 'v$version'
        : 'unreadable';
    await _file.copy('${_file.path}.$tag.bak');
  }
}

/// Result of [openDeviceStore]: a usable store with its catalog, or the
/// message to show instead of the list.
class DeviceStoreOpening {
  const DeviceStoreOpening.ready(DeviceStore this.store, this.catalog)
      : error = null;
  DeviceStoreOpening.failed(String this.error)
      : store = null,
        catalog = DeviceCatalog(const []);

  final DeviceStore? store;
  final DeviceCatalog catalog;
  final String? error;
}

/// Opens the metadata store under the directory [baseDirectory] returns.
/// Never throws: a damaged file or unavailable local storage becomes a
/// visible [DeviceStoreOpening.error] and the store stays closed, so
/// nothing is written over data that could not be read.
Future<DeviceStoreOpening> openDeviceStore(
    Future<Directory> Function() baseDirectory) async {
  try {
    final base = await baseDirectory();
    final store = DeviceStore(Directory('${base.path}/remote_hub'));
    return DeviceStoreOpening.ready(store, await store.load());
  } on DeviceConfigException catch (e) {
    return DeviceStoreOpening.failed(
        'The saved computer list is damaged and was left unchanged: '
        '${e.message}');
  } catch (e) {
    return DeviceStoreOpening.failed(
        'The saved computer list could not be read from local storage '
        '(${_ioReason(e)}). Nothing was changed. Try again.');
  }
}

/// A short reason without file paths, which the owner may share.
String _ioReason(Object e) {
  if (e is FileSystemException) {
    return e.osError?.message ?? e.message;
  }
  return e.runtimeType.toString();
}
