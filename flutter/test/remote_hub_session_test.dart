import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:flutter_hbb/remote_hub/credentials/credential_vault.dart';
import 'package:flutter_hbb/remote_hub/devices/device_edit_page.dart';
import 'package:flutter_hbb/remote_hub/devices/device_record.dart';
import 'package:flutter_hbb/remote_hub/diagnostics/redaction.dart';
import 'package:flutter_hbb/remote_hub/errors.dart';
import 'package:flutter_hbb/remote_hub/host/host_panel.dart';
import 'package:flutter_hbb/remote_hub/remote_hub_build.dart';
import 'package:flutter_hbb/remote_hub/sessions/reconnect_policy.dart';
import 'package:flutter_hbb/remote_hub/sessions/connect_stage_line.dart';
import 'package:flutter_hbb/remote_hub/sessions/reconnect_window.dart';
import 'package:flutter_hbb/remote_hub/sessions/remote_hub_connector.dart';
import 'package:flutter_hbb/remote_hub/sessions/viewer_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = 'mac-a.example-tailnet.ts.net';
const _id = '8a56e38b-cfad-44d9-b0ad-6e97eb38e496';

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

class _MemoryStore implements SecretStore {
  final Map<String, String> values = {};
  bool fail = false;
  bool failWrites = false;
  @override
  Future<String?> read(String key) async {
    if (fail) throw Exception('keystore unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail || failWrites) throw Exception('keystore unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A keystore whose read finishes only when [value] does.
class _SlowStore implements SecretStore {
  _SlowStore(this.value);
  final Future<String?> value;
  @override
  Future<String?> read(String key) => value;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _FakeNative implements RemoteHubNative {
  String registerResult = '';
  final List<String> registered = [];
  @override
  String registerDevice(String peerId, String tailnetIpv4, String serverName) {
    registered.add('$peerId $tailnetIpv4 $serverName');
    return registerResult;
  }

  @override
  String verifiedServerName(String peerId) => '';

  /// Password the host accepted, by peer id; set when the fake host logs in.
  final Map<String, String> accepted = {};
  int acceptedChecks = 0;
  @override
  bool loginAccepted(String peerId, String password) {
    acceptedChecks++;
    return accepted[peerId] == password;
  }

  @override
  bool loginDone(String peerId) => accepted.containsKey(peerId);

  /// Native dial stage by peer id ("securing", "secured", "failed ...").
  final Map<String, String> dial = {};
  @override
  String dialStage(String peerId) => dial[peerId] ?? '';

  /// "peer quality inputMode displayId" for each applied preference set.
  final List<String> appliedPrefs = [];
  String applyPrefsResult = '';
  @override
  String applyViewerPreferences(String peerId, DevicePreferences prefs) {
    appliedPrefs.add('$peerId ${prefs.quality.name} ${prefs.inputMode.name} '
        '${prefs.displayId ?? ''}');
    return applyPrefsResult;
  }

  /// Password staged for the next session, by peer id.
  final Map<String, String> staged = {};
  @override
  void stagePassword(String peerId, String password) {
    if (password.isEmpty) {
      staged.remove(peerId);
    } else {
      staged[peerId] = password;
    }
  }
}

DeviceRecord _device({bool confirmed = true, bool stored = false}) =>
    DeviceRecord.create(
      id: _id,
      label: 'MacBook A',
      platform: HostPlatform.macos,
      endpoint: RemoteEndpoint.validated(
          tailnetIpv4: '100.101.102.20', tlsServerName: _host),
      ownerConfirmed: confirmed,
      hasStoredCredential: stored,
    );

class _Harness {
  final store = _MemoryStore();

  /// The device list as the app keeps it; [failListWrites] makes the next
  /// writes fail like a full or read-only disk.
  DeviceCatalog catalog = DeviceCatalog([_device()]);
  int failListWrites = 0;
  Future<void> writeRecord(DeviceRecord updated) async {
    if (failListWrites > 0) {
      failListWrites--;
      throw Exception('disk full');
    }
    catalog = DeviceCatalog(
        [for (final d in catalog.devices) d.id == updated.id ? updated : d]);
  }

  final native = _FakeNative();

  /// "peer/password" for each opened viewer, where the password is the one
  /// staged natively when the viewer opened.
  final opened = <String>[];
  Object? openError;
  late final connector = RemoteHubConnector(
    native: native,
    vault: CredentialVault(store),
    openViewer: (peerId) async {
      final error = openError;
      if (error != null) throw error;
      opened.add('$peerId/${native.staged[peerId]}');
    },
  );
}

class _FakeHost implements HostSettings {
  final Map<String, String> options = {};
  @override
  Future<String> getOption(String key) async => options[key] ?? '';
  @override
  Future<String?> writeOptions(Map<String, String> changes) async {
    options.addAll(changes);
    return null;
  }

  @override
  Future<bool> setPassword(String password) async => true;

  /// What the host listener answers to an access change; null confirms it.
  String? accessError;
  @override
  Future<String?> setAccess(bool allow) async {
    if (accessError != null) return accessError;
    options[kOptionRemoteHubHostEnabled] = allow ? 'Y' : 'N';
    return null;
  }

  @override
  String status() => '{}';
  @override
  int beginPasswordDisplay() => 0;
  @override
  bool renewPasswordDisplay(int lease) => false;
  @override
  void endPasswordDisplay(int lease) {}
}

void main() {
  test('connect dials only confirmed devices through the logical peer id',
      () async {
    final h = _Harness();
    final refused = await h.connector
        .connect(_device(confirmed: false), typedPassword: 'pw');
    expect(refused, isA<ConnectRefused>());
    expect(h.native.registered, isEmpty);
    expect(h.opened, isEmpty);

    final ok = await h.connector.connect(_device(), typedPassword: 'pw');
    final peer = peerIdFor(_id);
    expect(peer, 'rh8a56e38bcfad44d9b0ad6e97eb38e496');
    expect((ok as ViewerOpened).peerId, peer);
    expect(h.native.registered, ['$peer 100.101.102.20 $_host']);
    expect(h.opened, ['$peer/pw']);
  });

  test('the viewer gets no password; the session takes it from native memory',
      () async {
    // Upstream puts a viewer password into the desktop window arguments,
    // which the child window prints at start (review finding, round 8).
    final h = _Harness();
    final peer = peerIdFor(_id);
    String? seenByViewer;
    final connector = RemoteHubConnector(
      native: h.native,
      vault: CredentialVault(h.store),
      openViewer: (peerId) async => seenByViewer = h.native.staged[peerId],
    );
    final out = await connector.connect(_device(), typedPassword: 'secret');
    expect(out, isA<ViewerOpened>());
    expect(seenByViewer, 'secret', reason: 'staged before the viewer opens');

    // A viewer that fails to open leaves nothing staged behind.
    h.native.staged.clear();
    h.openError = StateError('window failed');
    await expectLater(h.connector.connect(_device(), typedPassword: 'secret'),
        throwsStateError);
    expect(h.native.staged, isNot(contains(peer)));

    // Refused or password-less attempts stage nothing.
    h.openError = null;
    expect(
        await h.connector
            .connect(_device(confirmed: false), typedPassword: 'secret'),
        isA<ConnectRefused>());
    expect(await h.connector.connect(_device()), isA<PasswordRequired>());
    expect(h.native.staged, isEmpty);
  });

  test('a native refusal stops the attempt with its error code', () async {
    final h = _Harness()
      ..native.registerResult = 'INVALID_DEVICE_CONFIG: bad name';
    final out = await h.connector.connect(_device(), typedPassword: 'pw');
    expect(
        (out as ConnectRefused).error, RemoteHubErrorCode.invalidDeviceConfig);
    expect(h.opened, isEmpty);
  });

  test('password is stored only when the owner chooses it', () async {
    final h = _Harness();
    final peer = peerIdFor(_id);
    h.native.accepted[peer] = 'not-saved';
    await h.connector.connect(_device(), typedPassword: 'not-saved');
    expect(h.store.values, isEmpty);
    await h.connector
        .connect(_device(), typedPassword: 'saved', savePassword: true);
    h.native.accepted[peer] = 'saved';
    expect(
        await h.connector.savePasswordAfterLogin(_device(), 'saved',
            stillCurrent: () => true, writeRecord: h.writeRecord),
        PasswordSaveResult.saved);
    expect(h.store.values, {DeviceRecord.credentialRefFor(_id): 'saved'});

    h.opened.clear();
    await h.connector.connect(_device(stored: true));
    expect(h.opened, ['$peer/saved']);
  });

  test('a typed password is saved only after the host accepted it', () async {
    final h = _Harness();
    final peer = peerIdFor(_id);
    final out = await h.connector
        .connect(_device(), typedPassword: 'wrong', savePassword: true);
    expect(out, isA<ViewerOpened>());
    expect(h.opened, ['$peer/wrong']);
    expect(h.store.values, isEmpty, reason: 'opening the viewer is not auth');

    // The host refuses it (or the owner logs in with another password in
    // the viewer): nothing is stored.
    h.native.accepted[peer] = 'typed-in-viewer';
    final refused = await h.connector.savePasswordAfterLogin(_device(), 'wrong',
        stillCurrent: () => true,
        writeRecord: h.writeRecord,
        timeout: const Duration(milliseconds: 60),
        interval: const Duration(milliseconds: 10));
    expect(refused, PasswordSaveResult.notAccepted);
    expect(h.store.values, isEmpty);

    // No login yet: it times out without storing anything.
    h.native.accepted.remove(peer);
    expect(
        await h.connector.savePasswordAfterLogin(_device(), 'right',
            stillCurrent: () => true,
            writeRecord: h.writeRecord,
            timeout: const Duration(milliseconds: 60),
            interval: const Duration(milliseconds: 10)),
        PasswordSaveResult.notAccepted);
    expect(h.store.values, isEmpty);

    // Accepted after a few polls: stored then.
    final pending = h.connector.savePasswordAfterLogin(_device(), 'right',
        stillCurrent: () => true,
        writeRecord: h.writeRecord,
        interval: const Duration(milliseconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(h.store.values, isEmpty);
    h.native.accepted[peer] = 'right';
    expect(await pending, PasswordSaveResult.saved);
    expect(h.store.values, {DeviceRecord.credentialRefFor(_id): 'right'});
  });

  test('a device edited while the login was pending keeps its vault entry',
      () async {
    final h = _Harness();
    final ref = DeviceRecord.credentialRefFor(_id);
    h.native.accepted[peerIdFor(_id)] = 'old-host-password';
    var current = true;
    final pending = h.connector.savePasswordAfterLogin(
        _device(), 'old-host-password',
        stillCurrent: () => current,
        writeRecord: h.writeRecord,
        interval: const Duration(milliseconds: 10));
    // The owner points the device at a new endpoint with a new password.
    h.store.values[ref] = 'new-host-password';
    current = false;
    expect(await pending, PasswordSaveResult.deviceChanged);
    expect(h.store.values, {ref: 'new-host-password'});
  });

  test('an accepted login records the last successful session', () async {
    final h = _Harness();
    final out = await h.connector.connect(_device(), typedPassword: 'pw');
    h.native.accepted[peerIdFor(_id)] = 'pw';
    expect(
        await h.connector
            .waitForLogin(_device(), (out as ViewerOpened).password),
        isTrue);
    final at = DateTime.utc(2026, 11, 24, 9, 30);
    final next = recordLoginSuccess(DeviceCatalog([_device()]), _id, at,
        storedCredential: true);
    final reloaded =
        DeviceCatalog.decode(next.encode(forExport: false), fromImport: false)
            .devices
            .single;
    expect(reloaded.lastSuccessfulConnectionAt, at);
    expect(reloaded.credentialRef, DeviceRecord.credentialRefFor(_id));
  });

  test('an accepted password that the vault cannot store is reported',
      () async {
    final h = _Harness()..store.fail = true;
    h.native.accepted[peerIdFor(_id)] = 'pw';
    expect(
        await h.connector.savePasswordAfterLogin(_device(), 'pw',
            stillCurrent: () => true, writeRecord: h.writeRecord),
        PasswordSaveResult.vaultFailed);
  });

  group('an accepted password keeps the list and the vault consistent', () {
    final at = DateTime.utc(2026, 11, 24, 9, 30);
    test('a list that cannot be written leaves no password in the vault',
        () async {
      final h = _Harness()..failListWrites = 1;
      expect(
          await commitAcceptedPassword(
              CredentialVault(h.store), _device(), 'pw',
              stillCurrent: () => true, writeRecord: h.writeRecord, at: at),
          PasswordSaveResult.catalogFailed);
      expect(h.store.values, isEmpty,
          reason: 'removing the device later would not delete it');
      expect(h.catalog.devices.single.credentialRef, isNull);
    });

    test('a vault that cannot store withdraws the list reference', () async {
      final h = _Harness()..store.failWrites = true;
      expect(
          await commitAcceptedPassword(
              CredentialVault(h.store), _device(), 'pw',
              stillCurrent: () => true, writeRecord: h.writeRecord, at: at),
          PasswordSaveResult.vaultFailed);
      expect(h.store.values, isEmpty);
      final saved = h.catalog.devices.single;
      expect(saved.credentialRef, isNull);
      expect(saved.lastSuccessfulConnectionAt, at);
    });

    test(
        'a failed replacement keeps the reference to the old password, '
        'so removing the device still deletes it', () async {
      final ref = DeviceRecord.credentialRefFor(_id);
      final h = _Harness()..catalog = DeviceCatalog([_device(stored: true)]);
      h.store.values[ref] = 'old-password';
      h.store.failWrites = true;
      final written = <DeviceRecord>[];
      Future<void> writeRecord(DeviceRecord updated) {
        written.add(updated);
        return h.writeRecord(updated);
      }

      expect(
          await commitAcceptedPassword(
              CredentialVault(h.store), _device(stored: true), 'new-password',
              stillCurrent: () => true, writeRecord: writeRecord, at: at),
          PasswordSaveResult.vaultFailed);
      expect(h.store.values, {ref: 'old-password'});
      expect(written, isNotEmpty);
      for (final r in written) {
        expect(r.credentialRef, ref,
            reason: 'the old password must never lose its reference');
      }
      final saved = h.catalog.devices.single;
      expect(saved.credentialRef, ref);
      expect(saved.lastSuccessfulConnectionAt, at);

      // The owner removes the device: its old password goes with it.
      h.store.failWrites = false;
      final next = await commitDeviceRemoval(
          CredentialVault(h.store), h.catalog, saved,
          writeCatalog: (c) async => h.catalog = c,
          onError: (m) => fail('unexpected error: $m'));
      expect(next?.devices, isEmpty);
      expect(h.store.values, isEmpty, reason: 'no secret outlives its device');
    });

    test(
        'a failed replacement whose list write also fails leaves the old '
        'record and password unchanged', () async {
      final ref = DeviceRecord.credentialRefFor(_id);
      final h = _Harness()
        ..catalog = DeviceCatalog([_device(stored: true)])
        ..failListWrites = 1;
      h.store.values[ref] = 'old-password';
      h.store.failWrites = true;
      expect(
          await commitAcceptedPassword(
              CredentialVault(h.store), _device(stored: true), 'new-password',
              stillCurrent: () => true, writeRecord: h.writeRecord, at: at),
          PasswordSaveResult.vaultFailed);
      expect(h.store.values, {ref: 'old-password'});
      expect(h.catalog.devices.single.credentialRef, ref);
    });

    test('a replacement that the vault stores keeps the reference', () async {
      final ref = DeviceRecord.credentialRefFor(_id);
      final h = _Harness()..catalog = DeviceCatalog([_device(stored: true)]);
      h.store.values[ref] = 'old-password';
      expect(
          await commitAcceptedPassword(
              CredentialVault(h.store), _device(stored: true), 'new-password',
              stillCurrent: () => true, writeRecord: h.writeRecord, at: at),
          PasswordSaveResult.saved);
      expect(h.store.values, {ref: 'new-password'});
      expect(h.catalog.devices.single.credentialRef, ref);
      expect(h.catalog.devices.single.lastSuccessfulConnectionAt, at);
    });
  });

  test('no stored password or a broken vault asks again and never connects',
      () async {
    final h = _Harness();
    final missing = await h.connector.connect(_device());
    expect((missing as PasswordRequired).vaultFailed, isFalse);

    h.store.fail = true;
    final broken = await h.connector.connect(_device(stored: true));
    expect((broken as PasswordRequired).vaultFailed, isTrue);
    expect(h.opened, isEmpty);
  });

  group('the owner can cancel a connect at every stage (plan 12.3)', () {
    test('stages are reported in order up to the accepted login', () async {
      final h = _Harness();
      h.store.values[DeviceRecord.credentialRefFor(_id)] = 'pw';
      final stages = <ConnectStage>[];
      final attempt = ConnectAttempt(onStage: stages.add);
      final out =
          await h.connector.connect(_device(stored: true), attempt: attempt);
      expect(out, isA<ViewerOpened>());
      h.native.dial[peerIdFor(_id)] = 'secured';
      h.native.accepted[peerIdFor(_id)] = 'pw';
      expect(await h.connector.waitForLogin(_device(), 'pw', attempt: attempt),
          isTrue);
      expect(stages, [
        ConnectStage.checkingDevice,
        ConnectStage.readingPassword,
        ConnectStage.securingConnection,
        ConnectStage.checkingPassword,
        ConnectStage.connected,
      ]);
    });

    test(
        'a password corrected in the viewer completes the connect '
        'but is not saved', () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final stages = <ConnectStage>[];
      final attempt = ConnectAttempt(onStage: stages.add);
      final out = await h.connector.connect(_device(),
          typedPassword: 'wrong', savePassword: true, attempt: attempt);
      expect(out, isA<ViewerOpened>());
      h.native.dial[peer] = 'secured';
      // The host refused 'wrong'; the owner enters the right one in the
      // viewer, and the host accepts that login.
      final waiting = h.connector.waitForLogin(_device(), 'wrong',
          attempt: attempt,
          timeout: const Duration(seconds: 5),
          interval: const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      h.native.accepted[peer] = 'typed-in-viewer';
      expect(await waiting.timeout(const Duration(seconds: 1)), isTrue,
          reason: 'the card must not wait for its timeout');
      expect(attempt.stage, ConnectStage.connected);
      expect(stages.last, ConnectStage.connected);

      // Neither the refused password nor the viewer one is saved.
      expect(h.connector.acceptedWith(_device(), 'wrong'), isFalse);
      expect(
          await h.connector.savePasswordAfterLogin(_device(), 'wrong',
              stillCurrent: () => true, writeRecord: h.writeRecord),
          PasswordSaveResult.notAccepted);
      expect(h.store.values, isEmpty);
    });

    test('cancelled before it starts: nothing is registered or opened',
        () async {
      final h = _Harness();
      final attempt = ConnectAttempt()..cancel();
      expect(
          await h.connector
              .connect(_device(), typedPassword: 'pw', attempt: attempt),
          isA<ConnectCancelled>());
      expect(h.native.registered, isEmpty);
      expect(h.opened, isEmpty);
    });

    test('cancelled while the vault is read: the viewer never opens', () async {
      final h = _Harness();
      final read = Completer<String?>();
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(_SlowStore(read.future)),
        openViewer: (peerId) async => h.opened.add(peerId),
      );
      final attempt = ConnectAttempt();
      final pending =
          connector.connect(_device(stored: true), attempt: attempt);
      await Future<void>.delayed(Duration.zero);
      expect(attempt.stage, ConnectStage.readingPassword);
      attempt.cancel();
      expect(await pending, isA<ConnectCancelled>(),
          reason: 'returns without waiting for the keystore');
      read.complete('pw');
      await Future<void>.delayed(Duration.zero);
      expect(h.opened, isEmpty);
      expect(h.native.staged, isEmpty);
    });

    test('cancelled while the viewer opens: it is closed once it is up',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final windowUp = Completer<void>();
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) => windowUp.future,
        closeViewer: (peerId) async => closed.add(peerId),
      );
      final attempt = ConnectAttempt();
      final pending =
          connector.connect(_device(), typedPassword: 'pw', attempt: attempt);
      await Future<void>.delayed(Duration.zero);
      expect(attempt.stage, ConnectStage.securingConnection);
      expect(h.native.staged[peer], 'pw');
      attempt.cancel();
      expect(await pending, isA<ConnectCancelled>(),
          reason: 'returns without waiting for the window');
      expect(closed, isEmpty, reason: 'the window is not there yet');
      expect(h.native.staged, isEmpty);
      windowUp.complete();
      await Future<void>.delayed(Duration.zero);
      expect(closed, [peer]);
    });

    test('cancelled while the viewer window stalls: cancel still completes',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        // The window never comes up.
        openViewer: (_) => Completer<void>().future,
        closeViewer: (peerId) async => closed.add(peerId),
      );
      final attempt = ConnectAttempt();
      final pending =
          connector.connect(_device(), typedPassword: 'pw', attempt: attempt);
      await Future<void>.delayed(Duration.zero);
      expect(attempt.stage, ConnectStage.securingConnection);
      attempt.cancel();
      expect(
          await pending.timeout(const Duration(seconds: 1),
              onTimeout: () => fail('Cancel waited for the stalled window')),
          isA<ConnectCancelled>());
      expect(h.native.staged.containsKey(peer), isFalse);
      expect(closed, isEmpty);
    });

    test('a viewer that fails to open after cancel is still closed', () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final windowUp = Completer<void>();
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) => windowUp.future,
        closeViewer: (peerId) async => closed.add(peerId),
      );
      final attempt = ConnectAttempt();
      final pending =
          connector.connect(_device(), typedPassword: 'pw', attempt: attempt);
      await Future<void>.delayed(Duration.zero);
      attempt.cancel();
      expect(await pending, isA<ConnectCancelled>());
      windowUp.completeError(StateError('window failed'));
      await Future<void>.delayed(Duration.zero);
      expect(closed, [peer]);
    });

    test('cancelled while the host checks the password: the session closes',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) async {},
        closeViewer: (peerId) async => closed.add(peerId),
      );
      final attempt = ConnectAttempt();
      await connector.connect(_device(), typedPassword: 'pw', attempt: attempt);
      expect(attempt.stage, ConnectStage.securingConnection);
      h.native.dial[peer] = 'secured';
      final waiting = connector.waitForLogin(_device(), 'pw',
          attempt: attempt, interval: const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      expect(attempt.stage, ConnectStage.checkingPassword);
      attempt.cancel();
      expect(await waiting, isFalse,
          reason: 'stops at once, not after the poll interval');
      expect(closed, [peer]);
      expect(attempt.stage, ConnectStage.checkingPassword);
    });
  });

  group('changing the address ends the session to the old host', () {
    test('an open viewer is closed at once, without waiting for one', () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final waited = <String>[];
      final closedNow = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) async {},
        closeViewer: (peerId) async => waited.add(peerId),
        closeOpenViewer: (peerId) async {
          closedNow.add(peerId);
          return true;
        },
      );
      expect(await connector.connect(_device(), typedPassword: 'pw'),
          isA<ViewerOpened>());
      expect(h.native.staged[peer], 'pw');
      final moved = _device().withEndpoint(RemoteEndpoint.validated(
          tailnetIpv4: '100.101.102.21', tlsServerName: _host));
      expect(await connector.endSession(moved), isTrue);
      expect(closedNow, [peer]);
      expect(waited, isEmpty);
      expect(h.native.staged, isEmpty);
    });

    test('a connect in progress is cancelled and closes its own viewer',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) async {},
        closeViewer: (peerId) async => closed.add('wait $peerId'),
        closeOpenViewer: (peerId) async {
          closed.add('now $peerId');
          return true;
        },
      );
      final attempt = ConnectAttempt();
      await connector.connect(_device(), typedPassword: 'pw', attempt: attempt);
      final waiting = connector.waitForLogin(_device(), 'pw',
          attempt: attempt, interval: const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      await connector.endSession(_device(), attempt: attempt);
      expect(attempt.isCancelled, isTrue);
      expect(await waiting, isFalse);
      expect(closed, ['now $peer', 'wait $peer']);
      expect(h.native.staged, isEmpty);
    });
  });

  group('removing a device revokes its session (SEC-19)', () {
    test('an open viewer is closed and its connect cancelled', () async {
      final h = _Harness()..catalog = DeviceCatalog([_device()]);
      final peer = peerIdFor(_id);
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) async {},
        closeViewer: (peerId) async => closed.add('wait $peerId'),
        closeOpenViewer: (peerId) async {
          closed.add('now $peerId');
          return true;
        },
      );
      final attempt = ConnectAttempt();
      expect(
          await connector.connect(_device(),
              typedPassword: 'pw', attempt: attempt),
          isA<ViewerOpened>());
      final waiting = connector.waitForLogin(_device(), 'pw',
          attempt: attempt, interval: const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      final removed = await connector.removeDevice(_device(),
          attempt: attempt,
          remove: () async =>
              await commitDeviceRemoval(
                  CredentialVault(h.store), h.catalog, _device(),
                  writeCatalog: (c) async => h.catalog = c,
                  onError: (m) => fail('unexpected error: $m')) !=
              null);
      expect(removed, DeviceRemoval.removed);
      expect(h.catalog.devices, isEmpty);
      expect(attempt.isCancelled, isTrue);
      expect(await waiting, isFalse);
      expect(closed, contains('now $peer'));
      expect(h.native.staged, isEmpty,
          reason: 'no password stays staged for a removed device');
    });

    test('a removal that failed keeps the device and its session', () async {
      final h = _Harness();
      final closed = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) async {},
        closeOpenViewer: (peerId) async {
          closed.add(peerId);
          return true;
        },
      );
      final attempt = ConnectAttempt();
      await connector.connect(_device(), typedPassword: 'pw', attempt: attempt);
      expect(
          await connector.removeDevice(_device(),
              attempt: attempt, remove: () async => false),
          DeviceRemoval.notRemoved);
      expect(attempt.isCancelled, isFalse);
      expect(closed, isEmpty);
      expect(h.native.staged[peerIdFor(_id)], 'pw');
    });
  });

  group('a viewer that cannot be confirmed closed is reported', () {
    // Review finding: endSession ignored whether the close did anything, so
    // a removal reported success and an endpoint edit allowed a new connect
    // while the old viewer could still open or stay connected.
    RemoteHubConnector connectorWith(_Harness h, List<bool> answers,
            {OpenViewer? openViewer}) =>
        RemoteHubConnector(
          native: h.native,
          vault: CredentialVault(h.store),
          openViewer: openViewer ?? (_) async {},
          closeOpenViewer: (_) async =>
              answers.length > 1 ? answers.removeAt(0) : answers.single,
          openTimeout: const Duration(milliseconds: 50),
          endTimeout: const Duration(milliseconds: 50),
          endInterval: const Duration(milliseconds: 5),
        );

    test('an unconfirmed close does not end the session', () async {
      final h = _Harness();
      final connector = connectorWith(h, [false]);
      await connector.connect(_device(), typedPassword: 'pw');
      expect(await connector.endSession(_device()), isFalse);
      expect(h.native.staged, isEmpty);
    });

    test('a close is retried until the viewer answers', () async {
      final h = _Harness();
      final connector = connectorWith(h, [false, false, true]);
      expect(await connector.endSession(_device()), isTrue);
    });

    test('a removal with a viewer still open says so', () async {
      final h = _Harness()..catalog = DeviceCatalog([_device()]);
      final connector = connectorWith(h, [false]);
      await connector.connect(_device(), typedPassword: 'pw');
      expect(
          await connector.removeDevice(_device(), remove: () async => true),
          DeviceRemoval.removedSessionOpen);
    });

    test('a viewer still being opened is waited for, then closed', () async {
      final h = _Harness();
      final opening = Completer<void>();
      final closes = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (_) => opening.future,
        closeOpenViewer: (peerId) async {
          closes.add(opening.isCompleted ? 'after open' : 'before open');
          return true;
        },
        openTimeout: const Duration(seconds: 5),
      );
      final attempt = ConnectAttempt();
      final connecting = connector.connect(_device(),
          typedPassword: 'pw', attempt: attempt);
      await Future<void>.delayed(Duration.zero);
      final ending = connector.endSession(_device(), attempt: attempt);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closes, isEmpty, reason: 'its window is not there yet');
      opening.complete();
      expect(await ending, isTrue);
      expect(closes.first, 'after open');
      expect(await connecting, isA<ConnectCancelled>());
    });

    test('a viewer that never finishes opening is not reported closed',
        () async {
      final h = _Harness();
      final connector = connectorWith(h, [true],
          openViewer: (_) => Completer<void>().future);
      final attempt = ConnectAttempt();
      unawaited(connector.connect(_device(),
          typedPassword: 'pw', attempt: attempt));
      await Future<void>.delayed(Duration.zero);
      expect(await connector.endSession(_device(), attempt: attempt), isFalse);
    });
  });

  group('the stage follows the native dial, not the viewer window', () {
    test('opening the window leaves the connect securing the connection',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final attempt = ConnectAttempt();
      expect(
          await h.connector
              .connect(_device(), typedPassword: 'pw', attempt: attempt),
          isA<ViewerOpened>());
      // The window is up but TLS has not been verified yet.
      expect(attempt.stage, ConnectStage.securingConnection);

      h.native.dial[peer] = 'securing';
      final waiting = h.connector.waitForLogin(_device(), 'pw',
          attempt: attempt, interval: const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempt.stage, ConnectStage.securingConnection);

      h.native.dial[peer] = 'secured';
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempt.stage, ConnectStage.checkingPassword);
      expect(attempt.dialFailure, isNull);

      h.native.accepted[peer] = 'pw';
      expect(await waiting, isTrue);
      expect(attempt.stage, ConnectStage.connected);
    });

    test('a TLS failure ends the attempt and never shows the password stage',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final stages = <ConnectStage>[];
      final attempt = ConnectAttempt(onStage: stages.add);
      await h.connector
          .connect(_device(), typedPassword: 'pw', attempt: attempt);
      h.native.dial[peer] = 'failed TLS_NAME_MISMATCH: certificate is for '
          'other.example-tailnet.ts.net';
      expect(
          await h.connector.waitForLogin(_device(), 'pw',
              attempt: attempt, interval: const Duration(milliseconds: 5)),
          isFalse);
      expect(stages, isNot(contains(ConnectStage.checkingPassword)));
      expect(attempt.stage, ConnectStage.securingConnection);
      expect(attempt.dialFailure?.code, RemoteHubErrorCode.tlsNameMismatch);
      expect(attempt.dialFailure?.isFinal, isTrue);
      expect(h.native.staged, isEmpty);
    });

    test('a network failure keeps waiting for the reconnect and shows it',
        () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final attempt = ConnectAttempt();
      await h.connector
          .connect(_device(), typedPassword: 'pw', attempt: attempt);
      h.native.dial[peer] = 'failed ENDPOINT_UNREACHABLE: timed out';
      final waiting = h.connector.waitForLogin(_device(), 'pw',
          attempt: attempt, interval: const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempt.stage, ConnectStage.securingConnection);
      expect(attempt.dialFailure?.isFinal, isFalse);

      // The viewer reconnects and gets through.
      h.native.dial[peer] = 'secured';
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempt.stage, ConnectStage.checkingPassword);
      expect(attempt.dialFailure, isNull);
      h.native.accepted[peer] = 'pw';
      expect(await waiting, isTrue);
    });

    test('dial stages parse; unknown or uncoded failures are not final', () {
      expect(DialProgress.parse(''), isA<DialNotStarted>());
      expect(DialProgress.parse('bogus'), isA<DialNotStarted>());
      expect(DialProgress.parse('securing'), isA<DialSecuring>());
      expect(DialProgress.parse('secured'), isA<DialSecured>());
      final uncoded = DialProgress.parse('failed Connection reset by peer');
      expect((uncoded as DialFailed).code, isNull);
      expect(uncoded.isFinal, isFalse);
      final tls = DialProgress.parse('failed TLS_CERTIFICATE_INVALID: x');
      expect((tls as DialFailed).isFinal, isTrue);
    });

    testWidgets('the stage line names a failed dial', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ConnectStageLine(
                  stage: ConnectStage.securingConnection,
                  failure: const DialFailed('ENDPOINT_UNREACHABLE: timeout'),
                  onCancel: () {}))));
      expect(
          find.text('Establishing a secure connection (retrying: '
              'The computer does not answer.)'),
          findsOneWidget);
    });
  });

  group('saved viewer preferences reach the session', () {
    test('every connect applies the record before the viewer opens', () async {
      final h = _Harness();
      final peer = peerIdFor(_id);
      final order = <String>[];
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (peerId) async =>
            order.add('open after ${h.native.appliedPrefs.length}'),
      );
      final device = DeviceRecord.create(
        id: _id,
        label: 'MacBook A',
        platform: HostPlatform.macos,
        endpoint: RemoteEndpoint.validated(
            tailnetIpv4: '100.101.102.20', tlsServerName: _host),
        ownerConfirmed: true,
        preferences: const DevicePreferences(
            quality: QualityPreset.economy,
            inputMode: InputMode.touch,
            displayId: '69734272'),
      );
      await connector.connect(device, typedPassword: 'pw');
      expect(h.native.appliedPrefs, ['$peer economy touch 69734272']);
      expect(order, ['open after 1']);

      // Defaults are written too, so an earlier session's choice is reset.
      await connector.connect(_device(), typedPassword: 'pw');
      expect(h.native.appliedPrefs.last, '$peer balanced trackpad ');
    });

    test('a failure to apply them does not block the connect', () async {
      final h = _Harness();
      final failures = <String>[];
      h.native.applyPrefsResult = 'INTERNAL_ERROR: disk full';
      final connector = RemoteHubConnector(
        native: h.native,
        vault: CredentialVault(h.store),
        openViewer: (peerId) async => h.opened.add(peerId),
        onPreferencesFailed: failures.add,
      );
      expect(await connector.connect(_device(), typedPassword: 'pw'),
          isA<ViewerOpened>());
      expect(failures, ['INTERNAL_ERROR: disk full']);
    });

    test('the saved display is chosen by the name the host reports', () {
      final names = ['69734272', '69734273'];
      expect(chooseRemoteHubDisplay(names, '').index, isNull);
      expect(chooseRemoteHubDisplay(names, '').missing, isFalse);
      expect(chooseRemoteHubDisplay(names, '69734273').index, 1);
      final gone = chooseRemoteHubDisplay(names, '11111111');
      expect(gone.index, isNull);
      expect(gone.missing, isTrue);
    });
  });

  testWidgets('the connect stage line shows the stage and cancels',
      (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ConnectStageLine(
                stage: ConnectStage.securingConnection,
                onCancel: () => cancelled++))));
    expect(find.text('Establishing a secure connection'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);
  });

  test('generated host passwords are 32 CSPRNG characters', () {
    final a = generateHostPassword();
    expect(a.length, 32);
    expect(RegExp(r'^[A-Za-z0-9]{32}$').hasMatch(a), isTrue);
    expect(generateHostPassword(), isNot(a));
  });

  test('reconnect backoff follows the schedule and stays in the window', () {
    final policy = ReconnectPolicy(random: _FixedRandom(1.0));
    Duration? delay(int attempt, int elapsedSeconds,
            [RemoteHubErrorCode error = RemoteHubErrorCode.connectionLost]) =>
        policy.nextDelay(
            attempt: attempt,
            elapsed: Duration(seconds: elapsedSeconds),
            lastError: error);

    expect(
        [for (var i = 0; i < 5; i++) delay(i, 0)!.inSeconds], [1, 2, 4, 8, 15]);
    expect(delay(5, 30), const Duration(seconds: 18));
    expect(delay(6, 85), const Duration(seconds: 5));
    expect(delay(6, 90), isNull);
    expect(delay(0, 0, RemoteHubErrorCode.authenticationFailed), isNull);
    expect(delay(0, 0, RemoteHubErrorCode.tlsNameMismatch), isNull);
  });

  test('viewer retries network drops for 90 s but never TLS or host refusals',
      () {
    var now = DateTime(2026, 1, 1);
    final w = ReconnectWindow(
        policy: ReconnectPolicy(random: _FixedRandom(0.5)), now: () => now);
    final delays = <int>[];
    int? d;
    while ((d = w.nextDelaySeconds('Connection reset by peer')) != null) {
      delays.add(d!);
      now = now.add(Duration(seconds: d));
    }
    expect(delays.take(5), [1, 2, 4, 8, 15]);
    expect(delays.fold<int>(0, (a, b) => a + b), lessThanOrEqualTo(90));

    for (final text in [
      'TLS_NAME_MISMATCH: certificate is for another host',
      'TLS_CERTIFICATE_EXPIRED: expired',
      'HOST_BUSY: Another controller is connected',
      'INVALID_DEVICE_CONFIG: not approved',
    ]) {
      expect(ReconnectWindow().nextDelaySeconds(text), isNull, reason: text);
    }
    expect(
        ReconnectWindow().nextDelaySeconds('ENDPOINT_UNREACHABLE: timeout'), 1);
  });

  test('a final error resets the window so a manual retry starts fresh', () {
    var now = DateTime(2026, 1, 1);
    final w = ReconnectWindow(
        policy: ReconnectPolicy(random: _FixedRandom(0.5)), now: () => now);
    // Network retries use up most of the 90 s window.
    for (var i = 0; i < 5; i++) {
      final d = w.delayForMessage('Connection reset by peer', hasRetry: true)!;
      now = now.add(Duration(seconds: d));
    }
    now = now.add(const Duration(seconds: 60));
    // The attempt ends with an error the engine does not retry.
    expect(
        w.delayForMessage('HOST_BUSY: Another controller is connected',
            hasRetry: false),
        isNull);
    // A manual retry later in the same viewer gets a new window.
    expect(w.delayForMessage('Connection reset by peer', hasRetry: true), 1);
  });

  test('becoming a host applies the restricted options with access off',
      () async {
    final host = _FakeHost();
    await setHostRole(host, true);
    expect(host.options[kOptionRemoteHubRole], 'host');
    expect(host.options[kOptionRemoteHubHostEnabled], 'N');
    expect(host.options['approve-mode'], 'password');
    expect(host.options['verification-method'], 'use-permanent-password');
    expect(host.options['enable-file-transfer'], 'N');

    await setHostAccess(host, true);
    expect(host.options[kOptionRemoteHubHostEnabled], 'Y');
    await setHostAccess(host, false);
    expect(host.options[kOptionRemoteHubHostEnabled], 'N');
    await setHostRole(host, false);
    expect(host.options[kOptionRemoteHubRole], '');
  });

  test('leaving the host role keeps it when the stop is not confirmed',
      () async {
    final host = _FakeHost();
    await setHostRole(host, true);
    await setHostAccess(host, true);
    host.accessError = 'the host service is not reachable';
    await expectLater(
        setHostRole(host, false), throwsA(isA<HostAccessError>()));
    expect(host.options[kOptionRemoteHubRole], 'host');
    expect(host.options[kOptionRemoteHubHostEnabled], 'Y');
  });

  test('diagnostics export masks addresses, host names and labels', () {
    final out = redactDiagnostics(
        '12:34:56 MacBook A 100.101.102.20 fd7a:115c:a1e0::1 $_host ok',
        labels: ['MacBook A']);
    expect(out, '12:34:56 <label> <ip> <ip> <host> ok');
  });
}
