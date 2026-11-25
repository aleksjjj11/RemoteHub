import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/remote_hub/devices/device_record.dart';
import 'package:flutter_hbb/remote_hub/devices/device_status.dart';
import 'package:flutter_hbb/remote_hub/devices/device_store.dart';
import 'package:flutter_hbb/remote_hub/errors.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '8a56e38b-cfad-44d9-b0ad-6e97eb38e496';

Map<String, Object?> _device({Map<String, Object?> extra = const {}}) => {
      'id': _id,
      'label': 'MacBook A',
      'platform': 'macos',
      'endpoint': {
        'tailnetIpv4': '100.101.102.20',
        'tlsPort': 21118,
        'tlsServerName': 'mac-a.example-tailnet.ts.net',
      },
      'ownerConfirmed': true,
      'credentialRef': 'remotehub/device/$_id',
      'preferences': {
        'quality': 'balanced',
        'inputMode': 'trackpad',
        'displayId': null,
        'clipboardMode': 'disabled',
      },
      'lastSuccessfulConnectionAt': null,
      ...extra,
    };

String _catalog(List<Object?> devices, {Object? schema = 1}) =>
    jsonEncode({'schemaVersion': schema, 'devices': devices});

const _hostName = 'mac-a.example-tailnet.ts.net';

void main() {
  test('own store keeps confirmation and credential handle, export drops them',
      () {
    final catalog =
        DeviceCatalog.decode(_catalog([_device()]), fromImport: false);
    final d = catalog.devices.single;
    expect(d.ownerConfirmed, isTrue);
    expect(d.credentialRef, 'remotehub/device/$_id');
    expect(d.endpoint.tlsServerName, 'mac-a.example-tailnet.ts.net');

    final exported = catalog.encode(forExport: true);
    expect(exported, isNot(contains('credentialRef')));
    expect(exported, isNot(contains('remotehub/device')));

    final reimported = DeviceCatalog.decode(exported, fromImport: true);
    expect(reimported.devices.single.ownerConfirmed, isFalse);
    expect(reimported.devices.single.credentialRef, isNull);
  });

  test('import never takes over a credential handle or owner confirmation', () {
    final d = DeviceCatalog.decode(_catalog([_device()]), fromImport: true)
        .devices
        .single;
    expect(d.ownerConfirmed, isFalse);
    expect(d.credentialRef, isNull);
  });

  test('rejects unsafe or unsupported metadata', () {
    final rejected = <String>[
      _catalog([_device()], schema: 2),
      _catalog([
        _device(extra: {'password': 'secret'})
      ]),
      _catalog([
        _device(extra: {'credentialRef': 'remotehub/device/../x'})
      ]),
      _catalog([
        _device(extra: {'label': 'x' * 81})
      ]),
      _catalog([
        _device(extra: {'label': 'bad\u0000label'})
      ]),
      _catalog([
        _device(extra: {'platform': 'android'})
      ]),
      _catalog([
        _device(extra: {
          'endpoint': {
            'tailnetIpv4': '192.168.1.20',
            'tlsPort': 21118,
            'tlsServerName': 'mac-a.example-tailnet.ts.net',
          }
        })
      ]),
      _catalog([
        _device(extra: {
          'endpoint': {
            'tailnetIpv4': '100.101.102.20',
            'tlsPort': 21118,
            'tlsServerName': 'mac-a;rm -rf ~.example-tailnet.ts.net',
          }
        })
      ]),
      _catalog([_device(), _device()]),
      _catalog(List.generate(21, (_) => _device())),
      'x' * (kMaxMetadataBytes + 1),
      'not json',
    ];
    for (final text in rejected) {
      expect(() => DeviceCatalog.decode(text, fromImport: true),
          throwsA(isA<DeviceConfigException>()),
          reason: text.length > 120 ? text.substring(0, 120) : text);
    }
  });

  test('80-character Cyrillic label is accepted', () {
    final label = 'Ж' * 80;
    final d = DeviceCatalog.decode(
            _catalog([
              _device(extra: {'label': label})
            ]),
            fromImport: true)
        .devices
        .single;
    expect(d.label, label);
  });

  test('changing the endpoint requires new owner confirmation', () {
    final d = DeviceCatalog.decode(_catalog([_device()]), fromImport: false)
        .devices
        .single;
    final moved = d.withEndpoint(RemoteEndpoint.validated(
        tailnetIpv4: '100.101.102.21',
        tlsServerName: 'mac-a.example-tailnet.ts.net'));
    expect(moved.ownerConfirmed, isFalse);
    expect(moved.id, d.id);
  });

  test('opening the store reports unreadable storage instead of failing',
      () async {
    final base = await Directory.systemTemp.createTemp('remote_hub_open');
    addTearDown(() => base.delete(recursive: true));

    final ok = await openDeviceStore(() async => base);
    expect(ok.error, isNull);
    expect(ok.store, isNotNull);
    expect(ok.catalog.devices, isEmpty);

    // The application directory itself is unavailable.
    final noDir = await openDeviceStore(
        () async => throw const FileSystemException('no support dir'));
    expect(noDir.store, isNull, reason: 'nothing may be written');
    expect(noDir.error, contains('could not be read'));

    // The metadata file exists but cannot be read.
    final file = File('${base.path}/remote_hub/${DeviceStore.fileName}');
    await file.create(recursive: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['000', file.path]);
      final denied = await openDeviceStore(() async => base);
      expect(denied.store, isNull);
      expect(denied.error, contains('could not be read'));
      await Process.run('chmod', ['600', file.path]);
    }
    await file.delete();

    // Something other than a file sits at the metadata path.
    await Directory(file.path).create(recursive: true);
    final unreadable = await openDeviceStore(() async => base);
    expect(unreadable.store, isNull);
    expect(unreadable.catalog.devices, isEmpty);
    expect(unreadable.error, contains('could not be read'));
    expect(unreadable.error, isNot(contains(base.path)),
        reason: 'no local paths in a message the owner may share');
  });

  test('opening damaged metadata reports it and keeps the store closed',
      () async {
    final base = await Directory.systemTemp.createTemp('remote_hub_open');
    addTearDown(() => base.delete(recursive: true));
    final file = File('${base.path}/remote_hub/${DeviceStore.fileName}');
    await file.create(recursive: true);
    await file.writeAsString('{not json');
    final damaged = await openDeviceStore(() async => base);
    expect(damaged.store, isNull);
    expect(damaged.error, contains('damaged'));
    expect(await file.readAsString(), '{not json');
  });

  test('the device card claims only the checked certificate, not Tailscale',
      () {
    final verified = deviceStatusLine(verifiedServerName: _hostName);
    expect(verified, contains('Certificate verified: $_hostName'));
    expect(verified, contains('Transport: TLS'));
    expect(verified, contains('Network path: not checked'));
    expect(verified, isNot(contains('Tailscale')),
        reason: 'the app never checks the Tailscale route');
    expect(deviceStatusLine(), 'Status: not checked');
    expect(
        deviceStatusLine(
            lastError: RemoteHubErrorCode.hostBusy,
            verifiedServerName: _hostName),
        'Last attempt: ${RemoteHubErrorCode.hostBusy.userMessage}');
  });

  test('a verification only counts for the endpoint it was made for', () {
    final connected = RemoteEndpoint.validated(
        tailnetIpv4: '100.64.0.1', tlsServerName: _hostName);
    final moved = RemoteEndpoint.validated(
        tailnetIpv4: '100.64.0.2', tlsServerName: _hostName);
    final renamed = RemoteEndpoint.validated(
        tailnetIpv4: '100.64.0.1',
        tlsServerName: 'mac-b.example-tailnet.ts.net');
    expect(
        verifiedNameFor(connected,
            connectedTo: connected, nativeName: _hostName),
        _hostName);
    // The device was edited while a bridge to the old endpoint is still open.
    expect(
        verifiedNameFor(moved, connectedTo: connected, nativeName: _hostName),
        isNull);
    expect(
        verifiedNameFor(renamed, connectedTo: connected, nativeName: _hostName),
        isNull);
    // Never connected since the edit, or the bridge has closed.
    expect(verifiedNameFor(moved, connectedTo: null, nativeName: _hostName),
        isNull);
    expect(verifiedNameFor(connected, connectedTo: connected, nativeName: ''),
        isNull);
  });

  test('store writes atomically and backs up an older schema file', () async {
    final dir = await Directory.systemTemp.createTemp('remote_hub_store');
    addTearDown(() => dir.delete(recursive: true));
    final store = DeviceStore(dir);
    expect((await store.load()).devices, isEmpty);

    final file = File('${dir.path}/${DeviceStore.fileName}');
    await file.writeAsString(_catalog([], schema: 0));
    await expectLater(store.load(), throwsA(isA<DeviceConfigException>()));
    expect(await file.exists(), isTrue, reason: 'damaged config is kept');

    final catalog =
        DeviceCatalog.decode(_catalog([_device()]), fromImport: false);
    await store.save(catalog);
    expect(await File('${file.path}.v0.bak').readAsString(),
        _catalog([], schema: 0));
    expect(await File('${file.path}.tmp').exists(), isFalse);
    final loaded = await store.load();
    expect(loaded.devices.single.credentialRef, 'remotehub/device/$_id');
  });

  test('saving over damaged current-schema metadata keeps a backup', () async {
    final dir = await Directory.systemTemp.createTemp('remote_hub_store');
    addTearDown(() => dir.delete(recursive: true));
    final store = DeviceStore(dir);
    final file = File('${dir.path}/${DeviceStore.fileName}');
    final damaged = _catalog([
      _device(extra: {'tlsPassword': 'x'})
    ]);
    await file.writeAsString(damaged);
    await expectLater(store.load(), throwsA(isA<DeviceConfigException>()));

    await store.save(DeviceCatalog(const []));
    expect(await File('${file.path}.unreadable.bak').readAsString(), damaged);
    expect((await store.load()).devices, isEmpty);
  });
}
