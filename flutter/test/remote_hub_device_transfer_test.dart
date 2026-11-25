import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/remote_hub/devices/device_record.dart';
import 'package:flutter_hbb/remote_hub/devices/device_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

const _idA = '8a56e38b-cfad-44d9-b0ad-6e97eb38e496';
const _idB = '1b2c3d4e-0000-4000-8000-00000000000b';

DeviceRecord _record(String id, String ip, String name,
        {bool confirmed = true, bool stored = true}) =>
    DeviceRecord.create(
      id: id,
      label: 'Computer $id'.substring(0, 20),
      platform: HostPlatform.macos,
      endpoint: RemoteEndpoint.validated(
          tailnetIpv4: ip, tlsPort: kServeTlsPort, tlsServerName: name),
      ownerConfirmed: confirmed,
      hasStoredCredential: stored,
      lastSuccessfulConnectionAt: DateTime.utc(2026, 11, 1),
    );

void main() {
  final a = _record(_idA, '100.101.102.20', 'mac-a.example-tailnet.ts.net');
  final b = _record(_idB, '100.101.102.21', 'win-b.example-tailnet.ts.net');

  test('export carries no credential handle or confirmation', () {
    final text = exportDevices(DeviceCatalog([a]));
    expect(text, isNot(contains('credentialRef')));
    expect(text, isNot(contains('remotehub/device/')));
    final device = (jsonDecode(text)['devices'] as List).single as Map;
    expect(device['ownerConfirmed'], isFalse);
  });

  test('export from one controller imports on another, unconfirmed', () {
    final plan = planDeviceImport(
        DeviceCatalog(const []), exportDevices(DeviceCatalog([a, b])));
    expect(plan.added.map((d) => d.id), [_idA, _idB]);
    expect(plan.skipped, isEmpty);
    for (final d in plan.added) {
      expect(d.ownerConfirmed, isFalse);
      expect(d.credentialRef, isNull);
      expect(d.lastSuccessfulConnectionAt, isNull);
    }
    final next = applyDeviceImport(DeviceCatalog(const []), plan);
    expect(next.devices.map((d) => d.endpoint), [a.endpoint, b.endpoint]);
  });

  test('import never replaces an existing device or its password', () {
    final current = DeviceCatalog([a]);
    final moved = _record(_idA, '100.64.0.9', 'evil.example-tailnet.ts.net');
    final plan =
        planDeviceImport(current, exportDevices(DeviceCatalog([moved, b])));
    expect(plan.added.map((d) => d.id), [_idB]);
    expect(plan.skipped.single.reason, ImportSkipReason.sameId);
    final next = applyDeviceImport(current, plan);
    final kept = next.devices.firstWhere((d) => d.id == _idA);
    expect(kept.endpoint, a.endpoint);
    expect(kept.ownerConfirmed, isTrue);
    expect(kept.credentialRef, DeviceRecord.credentialRefFor(_idA));
  });

  test('a known endpoint under a new id is not added twice', () {
    final copy =
        _record(_idB, a.endpoint.tailnetIpv4, a.endpoint.tlsServerName);
    final plan = planDeviceImport(
        DeviceCatalog([a]), exportDevices(DeviceCatalog([copy])));
    expect(plan.added, isEmpty);
    expect(plan.skipped.single.reason, ImportSkipReason.sameEndpoint);
  });

  test('import that would exceed the device limit is rejected', () {
    final current = DeviceCatalog([
      for (var i = 0; i < kMaxDevices; i++)
        _record('00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            '100.100.0.${i + 1}', 'h$i.example-tailnet.ts.net')
    ]);
    expect(() => planDeviceImport(current, exportDevices(DeviceCatalog([b]))),
        throwsA(isA<DeviceConfigException>()));
  });

  test('invalid or unknown-field imports are rejected', () {
    expect(() => planDeviceImport(DeviceCatalog(const []), 'not json'),
        throwsA(isA<DeviceConfigException>()));
    final text = exportDevices(DeviceCatalog([b]))
        .replaceFirst('"label"', '"command": "rm -rf /", "label"');
    expect(() => planDeviceImport(DeviceCatalog(const []), text),
        throwsA(isA<DeviceConfigException>()));
  });

  test('plans differ when the list changed after review', () {
    final text = exportDevices(DeviceCatalog([a, b]));
    final reviewed = planDeviceImport(DeviceCatalog(const []), text);
    final now = planDeviceImport(DeviceCatalog([a]), text);
    expect(sameImportPlan(reviewed, reviewed), isTrue);
    expect(sameImportPlan(reviewed, now), isFalse);
  });

  group('import file', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('rh_import'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads an export file', () async {
      final f = File('${dir.path}/devices.json')
        ..writeAsStringSync(exportDevices(DeviceCatalog([b])));
      final plan = planDeviceImport(
          DeviceCatalog(const []), await readDeviceImportFile(f));
      expect(plan.added.single.id, _idB);
    });

    test('oversized file is rejected before it is read', () async {
      final f = File('${dir.path}/big.json')
        ..writeAsBytesSync(List.filled(kMaxMetadataBytes + 1, 0x20));
      await expectLater(
          readDeviceImportFile(f), throwsA(isA<DeviceConfigException>()));
    });

    test('missing or non-UTF-8 file is a config error', () async {
      await expectLater(readDeviceImportFile(File('${dir.path}/none.json')),
          throwsA(isA<DeviceConfigException>()));
      final f = File('${dir.path}/bin.json')..writeAsBytesSync([0xff, 0xfe]);
      await expectLater(
          readDeviceImportFile(f), throwsA(isA<DeviceConfigException>()));
    });
  });
}
