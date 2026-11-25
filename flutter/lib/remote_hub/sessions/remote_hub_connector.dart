import 'dart:async';

import '../credentials/credential_vault.dart';
import '../devices/device_record.dart';
import '../errors.dart';
import '../remote_hub_build.dart';
import 'viewer_close.dart';

/// The native calls Remote Hub needs, behind an interface so the connect flow
/// is testable without the Rust library.
abstract interface class RemoteHubNative {
  /// Registers the approved endpoint under [peerId]. Returns "" or a message
  /// that starts with an error code.
  String registerDevice(String peerId, String tailnetIpv4, String serverName);

  /// Certificate name the live bridge of [peerId] verified, or "".
  String verifiedServerName(String peerId);

  /// True once the host accepted a login of [peerId] made with exactly
  /// [password] since the device was last registered for a connect.
  bool loginAccepted(String peerId, String password);

  /// True once the host accepted any login of [peerId] since the device was
  /// last registered for a connect, whatever password was used: the owner
  /// may correct a refused password in the viewer.
  bool loginDone(String peerId);

  /// Hands [password] to the next session of [peerId] in native memory; ""
  /// clears it. The viewer then opens without the password, which keeps it
  /// out of navigation and desktop window arguments (those are logged).
  void stagePassword(String peerId, String password);

  /// How far the newest dial of [peerId] got since it was registered for
  /// this connect: "", "securing", "secured" (certificate verified, engine
  /// connected to the bridge) or "failed " followed by a coded message.
  String dialStage(String peerId);

  /// Writes the device's saved viewer preferences into the peer settings of
  /// [peerId], which the viewer reads when its session starts. Returns "" or
  /// a coded error.
  String applyViewerPreferences(String peerId, DevicePreferences prefs);
}

/// What [RemoteHubNative.dialStage] reports.
sealed class DialProgress {
  const DialProgress();

  static DialProgress parse(String raw) {
    if (raw == 'securing') return const DialSecuring();
    if (raw == 'secured') return const DialSecured();
    if (raw.startsWith('failed ')) {
      return DialFailed(raw.substring('failed '.length));
    }
    return const DialNotStarted();
  }
}

class DialNotStarted extends DialProgress {
  const DialNotStarted();
}

class DialSecuring extends DialProgress {
  const DialSecuring();
}

class DialSecured extends DialProgress {
  const DialSecured();
}

class DialFailed extends DialProgress {
  const DialFailed(this.message);
  final String message;

  /// The code the message starts with, or null for an uncoded transport
  /// error (the viewer decides about reconnecting those itself).
  RemoteHubErrorCode? get code {
    final colon = message.indexOf(':');
    if (colon <= 0) return null;
    final code = message.substring(0, colon).trim();
    for (final c in RemoteHubErrorCode.values) {
      if (c.code == code) return c;
    }
    return null;
  }

  /// A coded failure that no reconnect can fix (TLS, configuration): the
  /// attempt ends.
  bool get isFinal =>
      switch (code) { final c? => !c.isRetryable, null => false };
}

/// Opens the upstream viewer (native video surface and input) for [peerId].
/// It gets no password: the session takes the one staged natively by
/// [RemoteHubNative.stagePassword] as a preset for this session only.
typedef OpenViewer = Future<void> Function(String peerId);

/// Closes the viewer session of [peerId] opened by [OpenViewer], if any.
typedef CloseViewer = Future<void> Function(String peerId);

/// Closes the viewer of [peerId] if one is open now, without waiting for
/// one that is still starting. True only when no viewer of [peerId]
/// remains: false when one may still be open or open later (its window did
/// not answer, or it is still being opened).
typedef EndViewer = Future<bool> Function(String peerId);

/// Result of [RemoteHubConnector.removeDevice].
enum DeviceRemoval {
  /// The device was not removed; its session is as it was.
  notRemoved,

  /// The device is removed and none of its viewers remains.
  removed,

  /// The device is removed, but a viewer of it could not be confirmed
  /// closed: it may still be connected to the host.
  removedSessionOpen,
}

/// The stage of a connect the owner sees (plan 12.3), in order.
enum ConnectStage {
  /// The record is checked and its TLS endpoint registered natively.
  checkingDevice,

  /// The stored password is read from the platform vault.
  readingPassword,

  /// The viewer opens; it dials the TLS bridge and verifies the certificate.
  /// The connect stays here until the native dial reports the certificate
  /// verified, also while the viewer reconnects after a failure.
  securingConnection,

  /// TLS is verified and the engine connected through the bridge; the host
  /// checks the password and grants the screen.
  checkingPassword,

  /// The host accepted the login.
  connected;

  String get label => switch (this) {
        checkingDevice => 'Checking the device',
        readingPassword => 'Reading the saved password',
        securingConnection => 'Establishing a secure connection',
        checkingPassword => 'Checking the password, waiting for screen access',
        connected => 'Connected',
      };
}

/// One connect the owner can cancel at any stage. [stage] follows the flow;
/// [cancel] stops it: a pending vault read or viewer start is abandoned, the
/// staged password cleared, and an opened viewer closed.
class ConnectAttempt {
  ConnectAttempt({this.onStage});

  /// Called on every stage change.
  final void Function(ConnectStage stage)? onStage;

  ConnectStage _stage = ConnectStage.checkingDevice;
  ConnectStage get stage => _stage;

  /// The last failed dial of this attempt while securing the connection,
  /// cleared once a dial gets through. Shown next to the stage.
  DialFailed? get dialFailure => _dialFailure;
  DialFailed? _dialFailure;

  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void _enter(ConnectStage next) {
    if (isCancelled) return;
    _stage = next;
    onStage?.call(next);
  }

  /// Follows the native dial: the password stage only once TLS got through.
  void _follow(DialProgress dial) {
    if (isCancelled) return;
    switch (dial) {
      case DialSecured():
        final changed = _dialFailure != null;
        _dialFailure = null;
        if (_stage != ConnectStage.checkingPassword) {
          _enter(ConnectStage.checkingPassword);
        } else if (changed) {
          onStage?.call(_stage);
        }
      case DialSecuring():
        // A reconnect: back to securing, keeping the last failure visible.
        if (_stage != ConnectStage.securingConnection) {
          _enter(ConnectStage.securingConnection);
        }
      case DialFailed():
        _dialFailure = dial;
        _enter(ConnectStage.securingConnection);
      case DialNotStarted():
        break;
    }
  }

  /// [work], or null as soon as the attempt is cancelled.
  Future<T?> _unlessCancelled<T>(Future<T> work) =>
      Future.any<T?>([work, whenCancelled.then<T?>((_) => null)]);
}

sealed class ConnectOutcome {
  const ConnectOutcome();
}

class ViewerOpened extends ConnectOutcome {
  const ViewerOpened(this.peerId, this.password);
  final String peerId;

  /// The password the viewer was opened with, to watch for the host's
  /// acceptance ([RemoteHubConnector.waitForLogin]). Kept in memory only.
  final String password;
}

/// Result of [RemoteHubConnector.savePasswordAfterLogin] and
/// [commitAcceptedPassword].
enum PasswordSaveResult {
  /// The host accepted the password and the vault now holds it.
  saved,

  /// The host did not accept this password in time (wrong password, the
  /// owner cancelled, or a different password was typed in the viewer).
  /// Nothing was written.
  notAccepted,

  /// The host accepted it, but the vault write failed. The device list
  /// does not point at a stored password that is not there.
  vaultFailed,

  /// The host accepted it, but the device list could not be written. The
  /// vault holds no password that the list does not point at.
  catalogFailed,

  /// The owner edited or removed the device while the login was pending.
  /// Nothing was written, so an old password never lands behind a new
  /// endpoint or over a password the owner just changed.
  deviceChanged,
}

/// No stored password (or the vault failed): ask the owner and call
/// [RemoteHubConnector.connect] again with it.
class PasswordRequired extends ConnectOutcome {
  const PasswordRequired({required this.vaultFailed});
  final bool vaultFailed;
}

/// The owner cancelled the attempt; nothing is left staged or open.
class ConnectCancelled extends ConnectOutcome {
  const ConnectCancelled();
}

class ConnectRefused extends ConnectOutcome {
  const ConnectRefused(this.error, this.detail);
  final RemoteHubErrorCode error;
  final String detail;
}

/// Plan 10.2 steps 1-6 on the controller: check the record and the owner's
/// confirmation, register the fixed TLS target natively, get the secret, and
/// open the engine session. TLS verification happens natively before the
/// engine dials; the host checks the password itself.
class RemoteHubConnector {
  RemoteHubConnector({
    required this.native,
    required this.vault,
    required this.openViewer,
    CloseViewer? closeViewer,
    EndViewer? closeOpenViewer,
    this.onPreferencesFailed,
    this.openTimeout = const Duration(seconds: 15),
    this.endTimeout = const Duration(seconds: 15),
    this.endInterval = const Duration(milliseconds: 200),
  })  : closeViewer = closeViewer ?? ((_) async {}),
        closeOpenViewer = closeOpenViewer ??
            ((peerId) async {
              await (closeViewer ?? (_) async {})(peerId);
              return true;
            });

  /// Told when the saved viewer preferences could not be applied.
  final void Function(String error)? onPreferencesFailed;

  final RemoteHubNative native;
  final CredentialVault vault;
  final OpenViewer openViewer;
  final CloseViewer closeViewer;

  /// Closes a viewer that is open now; unlike [closeViewer] it does not
  /// wait for one that is still starting, but reports whether none remains.
  final EndViewer closeOpenViewer;

  /// How long [endSession] waits for a viewer still being opened.
  final Duration openTimeout;

  /// How long [endSession] keeps closing until no viewer remains, and how
  /// often it tries.
  final Duration endTimeout;
  final Duration endInterval;

  /// Viewers being opened by [connect], per peer, until [openViewer] ends.
  final Map<String, Future<void>> _opening = {};

  /// Ends the session of [device], if it has one: the owner changed its
  /// address, so an open viewer is connected to a host the record no longer
  /// names. Without this, the next connect of the same device would find
  /// that viewer, bring it to the front and never dial the new address.
  /// [attempt], a connect still in progress, is cancelled.
  ///
  /// True only once no viewer of [device] remains: a viewer still being
  /// opened is waited for (up to [openTimeout]) and then closed, and a close
  /// that cannot be confirmed is retried until [endTimeout]. False means a
  /// viewer may still be open or connected to the former host.
  Future<bool> endSession(DeviceRecord device,
      {ConnectAttempt? attempt}) async {
    final peerId = peerIdFor(device.id);
    attempt?.cancel();
    native.stagePassword(peerId, '');
    final opening = _opening[peerId];
    if (opening != null) {
      final settled = await Future.any<bool>([
        opening.then((_) => true, onError: (_) => true),
        Future<bool>.delayed(openTimeout, () => false),
      ]);
      if (!settled) return false;
    }
    return closeViewerConfirmed(
      tryClose: () async => await closeOpenViewer(peerId)
          ? ViewerCloseResult.noneOpen
          : ViewerCloseResult.unconfirmed,
      timeout: endTimeout,
      interval: endInterval,
    );
  }

  /// Plan SEC-19: removing a device revokes its session. [remove] deletes
  /// the record and its stored password and returns whether it did; only
  /// then is [attempt] cancelled and any viewer closed, so a controller
  /// keeps no screen or input access to a computer it no longer lists. A
  /// removal that failed leaves the device and its session as they were. A
  /// viewer that cannot be confirmed closed is reported, not hidden.
  Future<DeviceRemoval> removeDevice(DeviceRecord device,
      {required Future<bool> Function() remove,
      ConnectAttempt? attempt}) async {
    if (!await remove()) return DeviceRemoval.notRemoved;
    return await endSession(device, attempt: attempt)
        ? DeviceRemoval.removed
        : DeviceRemoval.removedSessionOpen;
  }

  /// Runs the connect through the [ConnectStage]s up to an open viewer.
  /// Cancelling [attempt] at any of them returns [ConnectCancelled].
  Future<ConnectOutcome> connect(
    DeviceRecord device, {
    String? typedPassword,
    bool savePassword = false,
    ConnectAttempt? attempt,
  }) async {
    final a = attempt ?? ConnectAttempt();
    if (a.isCancelled) return const ConnectCancelled();
    a._enter(ConnectStage.checkingDevice);
    if (!device.ownerConfirmed) {
      return const ConnectRefused(RemoteHubErrorCode.invalidDeviceConfig,
          'Confirm the address and name of this computer first.');
    }
    final peerId = peerIdFor(device.id);
    final registered = native.registerDevice(
        peerId, device.endpoint.tailnetIpv4, device.endpoint.tlsServerName);
    if (registered.isNotEmpty) {
      return ConnectRefused(errorCodeOf(registered), registered);
    }
    if (a.isCancelled) return const ConnectCancelled();
    var password = typedPassword;
    if (password == null || password.isEmpty) {
      a._enter(ConnectStage.readingPassword);
      final String? stored;
      try {
        stored = await a._unlessCancelled<String?>(vault.read(device));
      } on VaultException {
        if (a.isCancelled) return const ConnectCancelled();
        return const PasswordRequired(vaultFailed: true);
      }
      if (a.isCancelled) return const ConnectCancelled();
      if (stored == null) return const PasswordRequired(vaultFailed: false);
      password = stored;
    }
    // The device record, not a previous session, decides quality, input
    // mode and display. A failure keeps the viewer defaults; it does not
    // block the connect.
    final prefsError =
        native.applyViewerPreferences(peerId, device.preferences);
    if (prefsError.isNotEmpty) onPreferencesFailed?.call(prefsError);
    // A typed password is not saved here: opening the viewer does not mean
    // the host accepted it. See [savePasswordAfterLogin].
    a._enter(ConnectStage.securingConnection);
    native.stagePassword(peerId, password);
    var opened = false;
    final opening = openViewer(peerId).then((_) => opened = true);
    final tracked = opening.then<void>((_) {}, onError: (_) {});
    _opening[peerId] = tracked;
    unawaited(tracked.whenComplete(() {
      if (identical(_opening[peerId], tracked)) _opening.remove(peerId);
    }));
    try {
      await a._unlessCancelled(opening);
    } catch (_) {
      native.stagePassword(peerId, '');
      if (a.isCancelled) return const ConnectCancelled();
      rethrow;
    }
    if (a.isCancelled) {
      native.stagePassword(peerId, '');
      if (opened) {
        await closeViewer(peerId);
      } else {
        // The viewer may still be starting, and its window may never come
        // up: close it once it is there, without making Cancel wait for it.
        unawaited(opening
            .then<void>((_) {}, onError: (_) {})
            .then<void>((_) => closeViewer(peerId))
            .catchError((_) {}));
      }
      return const ConnectCancelled();
    }
    // The window is up, but the native dial and the login run on from here:
    // the stage advances in [waitForLogin] as the dial reports progress.
    return ViewerOpened(peerId, password);
  }

  /// True once the host accepted a login of [device]; polls the native
  /// session state every [interval] until [timeout]. Cancelling [attempt]
  /// stops waiting (false) and closes the viewer of [device].
  ///
  /// Any accepted login counts, also one with a password the owner corrected
  /// in the viewer after [password] was refused; whether [password] itself
  /// was the accepted one is [acceptedWith], which decides saving.
  ///
  /// [attempt] follows the native dial: it shows the password stage only
  /// after TLS was verified. A coded dial failure no reconnect can fix (TLS,
  /// configuration) ends the wait with false and stays in
  /// [ConnectAttempt.dialFailure]; the viewer shows its own error.
  Future<bool> waitForLogin(
    DeviceRecord device,
    String password, {
    Duration timeout = const Duration(minutes: 2),
    Duration interval = const Duration(milliseconds: 500),
    ConnectAttempt? attempt,
  }) async {
    final peerId = peerIdFor(device.id);
    final deadline = DateTime.now().add(timeout);
    while (!native.loginDone(peerId)) {
      if (attempt != null && attempt.isCancelled) {
        native.stagePassword(peerId, '');
        await closeViewer(peerId);
        return false;
      }
      final dial = DialProgress.parse(native.dialStage(peerId));
      attempt?._follow(dial);
      if (dial is DialFailed && dial.isFinal) {
        // The viewer keeps its error on screen; nothing is left staged.
        native.stagePassword(peerId, '');
        return false;
      }
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future.any<void>([
        Future<void>.delayed(interval),
        if (attempt != null) attempt.whenCancelled,
      ]);
    }
    if (attempt != null && attempt.isCancelled) {
      // Accepted just as the owner cancelled: the owner's choice wins.
      native.stagePassword(peerId, '');
      await closeViewer(peerId);
      return false;
    }
    attempt?._follow(const DialSecured());
    attempt?._enter(ConnectStage.connected);
    return true;
  }

  /// True if the last login the host accepted for [device] used exactly
  /// [password]. A password the owner entered in the viewer instead is not
  /// [password] and is never saved from here.
  bool acceptedWith(DeviceRecord device, String password) =>
      native.loginAccepted(peerIdFor(device.id), password);

  /// Saves a typed [password] for [device] only after the host accepted a
  /// login with it (plan 13.5); a wrong password is never stored, also when
  /// the owner then logs in with another one. The vault and the device list
  /// are updated by [commitAcceptedPassword].
  Future<PasswordSaveResult> savePasswordAfterLogin(
    DeviceRecord device,
    String password, {
    required bool Function() stillCurrent,
    required RecordWriter writeRecord,
    DateTime Function() now = DateTime.now,
    Duration timeout = const Duration(minutes: 2),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    if (!await waitForLogin(device, password,
            timeout: timeout, interval: interval) ||
        !acceptedWith(device, password)) {
      return PasswordSaveResult.notAccepted;
    }
    return commitAcceptedPassword(vault, device, password,
        stillCurrent: stillCurrent, writeRecord: writeRecord, at: now());
  }
}

/// Replaces the saved record of the same device with the given one in the
/// device list on local storage; throws when it was not written.
typedef RecordWriter = Future<void> Function(DeviceRecord updated);

/// Stores [password], which the host accepted for [device], and records the
/// session at [at], keeping the vault and the device list consistent.
/// [stillCurrent] is asked first: false means the owner changed the device
/// meanwhile and nothing is written.
///
/// A device without a stored password gets its list reference first and the
/// vault entry second; if the vault write fails the reference is withdrawn.
/// So a failure never leaves a password that no record points at, which a
/// later removal of the device would not delete. A device that already has
/// a stored password keeps its reference, also when the vault entry cannot
/// be replaced: the old password may still be there.
Future<PasswordSaveResult> commitAcceptedPassword(
  CredentialVault vault,
  DeviceRecord device,
  String password, {
  required bool Function() stillCurrent,
  required RecordWriter writeRecord,
  required DateTime at,
}) async {
  if (!stillCurrent()) return PasswordSaveResult.deviceChanged;
  final withoutPassword = device.withLastSuccessfulConnection(at);
  final withPassword = withoutPassword.withStoredCredential(true);
  if (device.credentialRef == null) {
    try {
      await writeRecord(withPassword);
    } catch (_) {
      return PasswordSaveResult.catalogFailed;
    }
    try {
      await vault.save(device.id, password);
    } on VaultException {
      try {
        await writeRecord(withoutPassword);
      } catch (_) {
        // The list keeps a reference to a missing password: the next connect
        // finds none and asks the owner. No secret is left behind.
      }
      return PasswordSaveResult.vaultFailed;
    }
    return PasswordSaveResult.saved;
  }
  try {
    await vault.save(device.id, password);
  } on VaultException {
    // A failed replacement may leave the old password in the vault, so the
    // record must keep pointing at it: a later removal of the device then
    // still deletes it. Only the session time is recorded.
    try {
      await writeRecord(withPassword);
    } catch (_) {}
    return PasswordSaveResult.vaultFailed;
  }
  try {
    await writeRecord(withPassword);
  } catch (_) {
    // The record already points at the entry, which now holds the accepted
    // password; only the session time was not recorded.
    return PasswordSaveResult.catalogFailed;
  }
  return PasswordSaveResult.saved;
}

/// [catalog] with the session time of [deviceId] set to [at] and, when
/// [storedCredential], its vault entry attached. Other devices are unchanged.
DeviceCatalog recordLoginSuccess(
  DeviceCatalog catalog,
  String deviceId,
  DateTime at, {
  bool storedCredential = false,
}) =>
    DeviceCatalog([
      for (final d in catalog.devices)
        if (d.id != deviceId)
          d
        else
          (storedCredential ? d.withStoredCredential(true) : d)
              .withLastSuccessfulConnection(at)
    ]);

/// Maps "CODE: detail" from the native side to the catalog.
RemoteHubErrorCode errorCodeOf(String message) {
  final colon = message.indexOf(':');
  final code = colon > 0 ? message.substring(0, colon).trim() : message.trim();
  return RemoteHubErrorCode.fromCode(code);
}
