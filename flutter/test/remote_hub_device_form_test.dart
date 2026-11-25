import 'package:flutter/material.dart';
import 'package:flutter_hbb/remote_hub/credentials/credential_vault.dart';
import 'package:flutter_hbb/remote_hub/devices/device_edit_page.dart';
import 'package:flutter_hbb/remote_hub/devices/device_record.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '8a56e38b-cfad-44d9-b0ad-6e97eb38e496';

class _MemoryStore implements SecretStore {
  final Map<String, String> values = {};
  bool failWrites = false;
  bool failDeletes = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw Exception('keystore unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw Exception('keystore unavailable');
    values.remove(key);
  }
}

/// The device list on local storage; [fail] makes writes fail.
class _List {
  _List(this.catalog);
  DeviceCatalog catalog;
  bool fail = false;
  Future<void> write(DeviceCatalog next) async {
    if (fail) throw Exception('disk full');
    catalog = next;
  }
}

DeviceRecord _existing({bool stored = true}) => DeviceRecord.create(
      id: _id,
      label: 'MacBook A',
      platform: HostPlatform.macos,
      endpoint: RemoteEndpoint.validated(
          tailnetIpv4: '100.101.102.20',
          tlsServerName: 'mac-a.example-tailnet.ts.net'),
      ownerConfirmed: true,
      hasStoredCredential: stored,
    );

Future<DeviceEditResult?> _edit(
    WidgetTester tester, Future<void> Function() change,
    {bool stored = false}) async {
  final existing = DeviceRecord.create(
    id: _id,
    label: 'MacBook A',
    platform: HostPlatform.macos,
    endpoint: RemoteEndpoint.validated(
        tailnetIpv4: '100.101.102.20',
        tlsServerName: 'mac-a.example-tailnet.ts.net'),
    ownerConfirmed: true,
    hasStoredCredential: stored,
  );
  // Tall enough that the whole form, including Save, is laid out.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  DeviceEditResult? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.of(context).push<DeviceEditResult>(
              MaterialPageRoute(
                  builder: (_) => DeviceEditPage(existing: existing)));
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await change();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('editing the address of a confirmed device needs reconfirmation',
      (tester) async {
    final result = await _edit(tester, () async {
      await tester.enterText(
          find.widgetWithText(TextFormField, '100.101.102.20'),
          '100.101.102.21');
      await tester.pump();
    });
    expect(result!.record.endpoint.tailnetIpv4, '100.101.102.21');
    expect(result.record.ownerConfirmed, isFalse);
  });

  testWidgets('renaming without touching the endpoint keeps the confirmation',
      (tester) async {
    final result = await _edit(tester, () async {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'MacBook A'), 'Work Mac');
      await tester.pump();
    });
    expect(result!.record.label, 'Work Mac');
    expect(result.record.ownerConfirmed, isTrue);
  });

  testWidgets('a new address does not reuse the stored password',
      (tester) async {
    final result = await _edit(tester, () async {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'mac-a.example-tailnet.ts.net'),
          'mac-b.example-tailnet.ts.net');
      await tester.pump();
    }, stored: true);
    expect(result!.record.credentialRef, isNull);
    expect(result.forgetStoredPassword, isTrue);
    expect(result.savePassword, isFalse);
  });

  testWidgets('a new address with a new password drops the old one',
      (tester) async {
    final result = await _edit(tester, () async {
      await tester.enterText(
          find.widgetWithText(TextFormField, '100.101.102.20'),
          '100.101.102.21');
      await tester.pump();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Host password'), 'new-secret');
      await tester.tap(find.text('Save the password on this device'));
      await tester.pump();
    }, stored: true);
    // The new one is saved only after the host accepts it on connect.
    expect(result!.record.credentialRef, isNull);
    expect(result.forgetStoredPassword, isTrue);
    expect(result.password, 'new-secret');
    expect(result.savePassword, isTrue);
  });

  testWidgets('unchecking saving forgets the stored password', (tester) async {
    final result = await _edit(tester, () async {
      await tester.tap(find.text('Save the password on this device'));
      await tester.pump();
    }, stored: true);
    expect(result!.record.credentialRef, isNull);
    expect(result.forgetStoredPassword, isTrue);
  });

  testWidgets('a typed password is not stored until the host accepts it',
      (tester) async {
    final result = await _edit(tester, () async {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Host password'), 'mistyped');
      await tester.pump();
    }, stored: true);
    expect(result!.password, 'mistyped');
    expect(result.savePassword, isTrue);

    final store = _MemoryStore()
      ..values[DeviceRecord.credentialRefFor(_id)] = 'old';
    final errors = <String>[];
    final list = _List(DeviceCatalog([_existing()]));
    final next = await tester.runAsync(() => commitDeviceEdit(
        CredentialVault(store), list.catalog, _existing(), result,
        writeCatalog: list.write, onError: errors.add));
    expect(errors, isEmpty);
    expect(next!.devices.single.credentialRef, isNotNull);
    expect(store.values, {DeviceRecord.credentialRefFor(_id): 'old'});
  });

  test('adding a device with a password to save writes nothing yet', () async {
    final store = _MemoryStore();
    final list = _List(DeviceCatalog(const []));
    final next = await commitDeviceEdit(CredentialVault(store), list.catalog,
        null, DeviceEditResult(_existing(stored: false), 'typed', true),
        writeCatalog: list.write, onError: (_) {});
    expect(next!.devices.single.credentialRef, isNull);
    expect(list.catalog, same(next));
    expect(store.values, isEmpty);
  });

  test('unchecking saving removes the stored password', () async {
    final store = _MemoryStore()
      ..values[DeviceRecord.credentialRefFor(_id)] = 'old';
    final list = _List(DeviceCatalog([_existing()]));
    final next = await commitDeviceEdit(
        CredentialVault(store),
        list.catalog,
        _existing(),
        DeviceEditResult(_existing(stored: false), '', false,
            forgetStoredPassword: true),
        writeCatalog: list.write,
        onError: (_) {});
    expect(next!.devices.single.credentialRef, isNull);
    expect(store.values, isEmpty);
  });

  testWidgets('an unchanged endpoint keeps the stored password',
      (tester) async {
    final result = await _edit(tester, () async {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'MacBook A'), 'Work Mac');
      await tester.pump();
    }, stored: true);
    expect(result!.record.credentialRef, isNotNull);
    expect(result.forgetStoredPassword, isFalse);
  });

  group('a vault that cannot delete keeps the saved record', () {
    DeviceRecord moved() => DeviceRecord.create(
          id: _id,
          label: 'MacBook A',
          platform: HostPlatform.macos,
          endpoint: RemoteEndpoint.validated(
              tailnetIpv4: '100.101.102.21',
              tlsServerName: 'mac-a.example-tailnet.ts.net'),
          ownerConfirmed: false,
          hasStoredCredential: false,
        );

    test('removing a device keeps it listed while its password remains',
        () async {
      final store = _MemoryStore()
        ..values[DeviceRecord.credentialRefFor(_id)] = 'old'
        ..failDeletes = true;
      final list = _List(DeviceCatalog([_existing()]));
      final errors = <String>[];
      final next = await commitDeviceRemoval(
          CredentialVault(store), list.catalog, _existing(),
          writeCatalog: list.write, onError: errors.add);
      expect(next, isNull);
      expect(errors, isNotEmpty);
      expect(list.catalog.devices, hasLength(1));
      expect(store.values, {DeviceRecord.credentialRefFor(_id): 'old'});

      // Once the vault works again the owner can retry from the same list.
      store.failDeletes = false;
      final retried = await commitDeviceRemoval(
          CredentialVault(store), list.catalog, _existing(),
          writeCatalog: list.write, onError: errors.add);
      expect(retried!.devices, isEmpty);
      expect(list.catalog.devices, isEmpty);
      expect(store.values, isEmpty);
    });

    test('removing a device without a stored password needs no vault',
        () async {
      final store = _MemoryStore()..failDeletes = true;
      final list = _List(DeviceCatalog([_existing(stored: false)]));
      final next = await commitDeviceRemoval(
          CredentialVault(store), list.catalog, _existing(stored: false),
          writeCatalog: list.write,
          onError: (_) => fail('no vault access expected'));
      expect(next!.devices, isEmpty);
    });

    test('an endpoint change is not applied while the old password remains',
        () async {
      final store = _MemoryStore()
        ..values[DeviceRecord.credentialRefFor(_id)] = 'old'
        ..failDeletes = true;
      final errors = <String>[];
      final list = _List(DeviceCatalog([_existing()]));
      final next = await commitDeviceEdit(
          CredentialVault(store),
          list.catalog,
          _existing(),
          DeviceEditResult(moved(), '', false, forgetStoredPassword: true),
          writeCatalog: list.write,
          onError: errors.add);
      expect(next, isNull);
      expect(errors, isNotEmpty);
      expect(
          list.catalog.devices.single.endpoint.tailnetIpv4, '100.101.102.20');
    });

    test('unchecking saving is not applied while the old password remains',
        () async {
      final store = _MemoryStore()
        ..values[DeviceRecord.credentialRefFor(_id)] = 'old'
        ..failDeletes = true;
      final list = _List(DeviceCatalog([_existing()]));
      final next = await commitDeviceEdit(
          CredentialVault(store),
          list.catalog,
          _existing(),
          DeviceEditResult(_existing(stored: false), '', false,
              forgetStoredPassword: true),
          writeCatalog: list.write,
          onError: (_) {});
      expect(next, isNull);
      expect(list.catalog.devices.single.credentialRef, isNotNull);
    });
  });

  group('a list that cannot be written keeps the stored password', () {
    final ref = DeviceRecord.credentialRefFor(_id);

    test('removing a device', () async {
      final store = _MemoryStore()..values[ref] = 'old';
      final list = _List(DeviceCatalog([_existing()]))..fail = true;
      final errors = <String>[];
      final next = await commitDeviceRemoval(
          CredentialVault(store), list.catalog, _existing(),
          writeCatalog: list.write, onError: errors.add);
      expect(next, isNull);
      expect(errors.single, contains('not kept'));
      expect(list.catalog.devices.single.credentialRef, ref);
      expect(store.values, {ref: 'old'},
          reason: 'the still-listed device must keep its password');
    });

    test('unchecking saving', () async {
      final store = _MemoryStore()..values[ref] = 'old';
      final list = _List(DeviceCatalog([_existing()]))..fail = true;
      final next = await commitDeviceEdit(
          CredentialVault(store),
          list.catalog,
          _existing(),
          DeviceEditResult(_existing(stored: false), '', false,
              forgetStoredPassword: true),
          writeCatalog: list.write,
          onError: (_) {});
      expect(next, isNull);
      expect(store.values, {ref: 'old'});
    });
  });
}
