import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../credentials/credential_vault.dart';
import '../devices/device_edit_page.dart';
import '../devices/device_record.dart';
import '../devices/device_status.dart';
import '../devices/device_store.dart';
import '../devices/device_transfer.dart';
import '../diagnostics/log_deletion.dart';
import '../diagnostics/redaction.dart';
import '../errors.dart';
import '../host/host_panel.dart';
import '../remote_hub_build.dart';
import '../sessions/connect_stage_line.dart';
import '../sessions/remote_hub_connector.dart';

class _FfiNative implements RemoteHubNative {
  @override
  String registerDevice(String peerId, String tailnetIpv4, String serverName) =>
      bind.remoteHubRegisterDevice(
          id: peerId, tailnetIpv4: tailnetIpv4, tlsServerName: serverName);

  @override
  String verifiedServerName(String peerId) =>
      bind.remoteHubVerifiedServerName(id: peerId);

  @override
  bool loginAccepted(String peerId, String password) =>
      bind.remoteHubLoginAccepted(id: peerId, password: password);

  @override
  bool loginDone(String peerId) => bind.remoteHubLoginDone(id: peerId);

  @override
  void stagePassword(String peerId, String password) =>
      bind.remoteHubStagePassword(id: peerId, password: password);

  @override
  String dialStage(String peerId) => bind.remoteHubDialStage(id: peerId);

  @override
  String applyViewerPreferences(String peerId, DevicePreferences prefs) =>
      bind.remoteHubApplyViewerPreferences(
          id: peerId,
          quality: prefs.quality.name,
          inputMode: prefs.inputMode.name,
          displayId: prefs.displayId ?? '');
}

class _FfiHostSettings implements HostSettings {
  @override
  Future<String> getOption(String key) => bind.mainGetOption(key: key);
  @override
  Future<String?> writeOptions(Map<String, String> changes) async {
    // Not mainSetOption: it drops IPC write errors, so an unreachable host
    // service would look like a saved role.
    final error =
        await bind.remoteHubSetHostOptions(optionsJson: jsonEncode(changes));
    return error.isEmpty ? null : error;
  }
  @override
  Future<bool> setPassword(String password) =>
      bind.mainSetPermanentPasswordWithResult(password: password);
  @override
  Future<String?> setAccess(bool allow) async {
    final error = await bind.remoteHubSetHostAccess(enabled: allow);
    return error.isEmpty ? null : error;
  }

  @override
  String status() => bind.remoteHubHostStatus();
  @override
  int beginPasswordDisplay() => bind.remoteHubBeginPasswordDisplay();
  @override
  bool renewPasswordDisplay(int lease) =>
      bind.remoteHubRenewPasswordDisplay(lease: lease);
  @override
  void endPasswordDisplay(int lease) =>
      bind.remoteHubEndPasswordDisplay(lease: lease);
}

/// Remote Hub main screen (plan 12.1): the owner's computers, the local host
/// panel on desktop, and diagnostics. Sessions open in the upstream viewer.
class RemoteHubHome extends StatefulWidget {
  const RemoteHubHome({super.key});

  @override
  State<RemoteHubHome> createState() => _RemoteHubHomeState();
}

class _DeviceState {
  RemoteHubErrorCode? lastError;
  String? lastDetail;
  String? verifiedServerName;

  /// The connect in progress, shown with its stage and a cancel action.
  ConnectAttempt? attempt;

  /// Endpoint of the last connect; a verification only counts for it.
  RemoteEndpoint? connectedEndpoint;

  /// Closing the session of the previous endpoint; a connect waits for it.
  /// Completes with whether no viewer of the device remains.
  Future<bool>? closing;

  /// Forgets everything learned about the previous endpoint.
  void endpointChanged() {
    lastError = null;
    lastDetail = null;
    verifiedServerName = null;
    connectedEndpoint = null;
  }

  /// Password typed in the device form and whether to save it. Kept in
  /// memory for the next connect, which saves it only after the host
  /// accepted it.
  (String, bool)? formPassword;
}

class _RemoteHubHomeState extends State<RemoteHubHome>
    with WidgetsBindingObserver {
  final _vault = CredentialVault(PlatformSecretStore());
  final _native = _FfiNative();
  late final RemoteHubConnector _connector = RemoteHubConnector(
    native: _native,
    vault: _vault,
    // No password here: upstream puts it into the desktop window arguments,
    // which the child window prints. The session takes it from native memory.
    openViewer: (peerId) async => connect(context, peerId),
    closeViewer: _closeViewer,
    closeOpenViewer: _closeOpenViewer,
    onPreferencesFailed: (error) =>
        _note('Viewer preferences not applied: ${errorCodeOf(error).code}'),
  );

  /// Closes the viewer of [peerId]: on desktop its tab in the remote window,
  /// on mobile the viewer route. Closing it ends the engine session.
  static Future<void> _closeViewer(String peerId) async {
    if (isDesktop) {
      // Keeps trying in the background until the tab exists (its window is
      // registered first); Cancel does not wait for it.
      unawaited(rustDeskWinManager.closeRemoteDesktopSession(peerId));
    } else {
      closeConnection(id: peerId);
    }
  }

  /// Closes the viewer of [peerId] if it is open now; true when none
  /// remains. On desktop a window that did not answer, or a viewer still
  /// being opened, leaves it unconfirmed.
  static Future<bool> _closeOpenViewer(String peerId) async {
    if (isDesktop) {
      return (await rustDeskWinManager.closeOpenRemoteDesktopSession(peerId))
          .confirmed;
    }
    closeConnection(id: peerId);
    return true;
  }

  DeviceStore? _store;
  DeviceCatalog _catalog = DeviceCatalog(const []);
  final Map<String, _DeviceState> _states = {};
  String? _loadError;
  final List<String> _log = [];

  /// A bridge closes by itself when its session ends; this keeps the card
  /// from showing a verification that no longer exists.
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _refreshVerified();
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Plan 16.3: on Pixel a session lives only in the visible viewer. Going to
  /// the background closes it; the host then releases held keys and buttons.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (isAndroid &&
        state == AppLifecycleState.paused &&
        !stateGlobal.isInMainPage) {
      _note('Session closed: app moved to the background');
      closeConnection();
    }
    if (state == AppLifecycleState.resumed) _refreshVerified();
  }

  void _note(String event) {
    _log.add('${DateTime.now().toIso8601String()} $event');
    if (_log.length > 500) _log.removeAt(0);
  }

  Future<void> _load() async {
    final opened = await openDeviceStore(getApplicationSupportDirectory);
    if (!mounted) return;
    if (opened.error != null) _note('Device list not loaded: ${opened.error}');
    setState(() {
      _store = opened.store;
      _catalog = opened.catalog;
      _loadError = opened.error;
    });
  }

  /// Writes [next] to local storage and shows it; throws when it was not
  /// written, so callers can keep the vault consistent with the list.
  Future<void> _write(DeviceCatalog next) async {
    final store = _store;
    if (store == null) throw StateError('device list is not open');
    try {
      await store.save(next);
    } catch (e) {
      _note('Device list not saved: ${e.runtimeType}');
      rethrow;
    }
    _catalog = next;
    if (mounted) setState(() {});
  }

  /// Replaces the saved record with the same id as [updated] in the list.
  Future<void> _writeRecord(DeviceRecord updated) => _write(DeviceCatalog(
      [for (final d in _catalog.devices) d.id == updated.id ? updated : d]));

  Future<void> _changes = Future.value();

  /// Runs list and vault changes one at a time, so one change never reads
  /// a list or vault state that another is halfway through updating.
  Future<T> _exclusive<T>(Future<T> Function() change) {
    final run = _changes.then((_) => change());
    _changes = run.then((_) {}, onError: (_) {});
    return run;
  }

  void _refreshVerified() {
    var changed = false;
    for (final d in _catalog.devices) {
      final state = _states[d.id];
      final connectedTo = state?.connectedEndpoint;
      final name = connectedTo == null
          ? null
          : verifiedNameFor(d.endpoint,
              connectedTo: connectedTo,
              nativeName: _native.verifiedServerName(peerIdFor(d.id)));
      if (state != null && state.verifiedServerName != name) {
        state.verifiedServerName = name;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  Future<void> _addOrEdit([DeviceRecord? existing]) async {
    final result = await Navigator.of(context).push<DeviceEditResult>(
        MaterialPageRoute(builder: (_) => DeviceEditPage(existing: existing)));
    if (result == null) return;
    final saved = await _exclusive(() => commitDeviceEdit(
        _vault, _catalog, existing, result,
        writeCatalog: _write, onError: _showError));
    // Null: neither the list nor the vault changed.
    if (saved == null) return;
    final record = result.record;
    final state = _states.putIfAbsent(record.id, _DeviceState.new);
    if (existing != null && existing.endpoint != record.endpoint) {
      final attempt = state.attempt;
      state.attempt = null;
      state.endpointChanged();
      _note('Endpoint changed for device ${record.id}; closing its session');
      state.closing = _connector
          .endSession(record, attempt: attempt)
          .catchError((Object e) {
        _note('Session not closed: ${e.runtimeType}');
        return false;
      }).then((ended) {
        if (!ended) {
          _note('Viewer of device ${record.id} not confirmed closed');
        }
        return ended;
      });
    }
    state.formPassword =
        result.password.isEmpty ? null : (result.password, result.savePassword);
    if (mounted) setState(() {});
  }

  Future<void> _delete(DeviceRecord d) async {
    final state = _states[d.id];
    try {
      final removal = await _connector.removeDevice(d,
          attempt: state?.attempt,
          // Null: the device and its stored password are both still there.
          remove: () async =>
              await _exclusive(() => commitDeviceRemoval(_vault, _catalog, d,
                  writeCatalog: _write, onError: _showError)) !=
              null);
      switch (removal) {
        case DeviceRemoval.notRemoved:
          return;
        case DeviceRemoval.removed:
          _note('Device ${d.id} removed; its session was closed');
        case DeviceRemoval.removedSessionOpen:
          _note('Device ${d.id} removed; its viewer not confirmed closed');
          _showError('The device was removed, but its viewer window could '
              'not be closed. Close it yourself to end the session.');
      }
    } catch (e) {
      _note('Device removal did not finish: ${e.runtimeType}');
      if (_catalog.devices.any((x) => x.id == d.id)) return;
    }
    if (identical(_states[d.id], state)) _states.remove(d.id);
    if (mounted) setState(() {});
  }

  void _showError(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _connect(DeviceRecord d,
      {String? password, bool save = false}) async {
    final state = _states.putIfAbsent(d.id, _DeviceState.new);
    final fromForm = state.formPassword;
    if (password == null && fromForm != null) {
      state.formPassword = null;
      return _connect(d, password: fromForm.$1, save: fromForm.$2);
    }
    if (state.attempt != null) return;
    final closing = state.closing;
    if (closing != null) {
      // The viewer of the old endpoint must be gone, or this connect would
      // only bring it to the front.
      var ended = await closing;
      if (!ended && identical(state.closing, closing)) {
        // Try once more: the old viewer may have answered since.
        ended = await _connector.endSession(d).catchError((_) => false);
      }
      if (!ended) {
        _showError('The viewer of the previous address is still open. '
            'Close it before connecting to the new address.');
        return;
      }
      if (identical(state.closing, closing)) state.closing = null;
      if (state.attempt != null) return;
    }
    _note('Connect requested for device ${d.id}');
    // The connector registers this endpoint; an older bridge stops counting.
    state.connectedEndpoint = d.endpoint;
    state.verifiedServerName = null;
    final attempt = ConnectAttempt(onStage: (stage) {
      _note('Connect stage for device ${d.id}: ${stage.name}');
      if (mounted) setState(() {});
    });
    state.attempt = attempt;
    setState(() {});
    void finish() {
      if (identical(state.attempt, attempt)) state.attempt = null;
      if (mounted) setState(() {});
    }

    final ConnectOutcome outcome;
    try {
      outcome = await _connector.connect(d,
          typedPassword: password, savePassword: save, attempt: attempt);
    } catch (e) {
      finish();
      _note('Viewer did not open: ${e.runtimeType}');
      _showError('The session window could not be opened.');
      return;
    }
    if (outcome is! ViewerOpened) finish();
    if (!mounted) return;
    switch (outcome) {
      case ViewerOpened(password: final used):
        state.lastError = null;
        state.lastDetail = null;
        // Not awaited: the viewer is open and the owner may log in there.
        // The card keeps the stage and the cancel action until it ends.
        _afterLogin(d, used, save: save && password != null, attempt: attempt)
            .whenComplete(finish);
      case ConnectCancelled():
        _note('Connect cancelled for device ${d.id}');
      case PasswordRequired(:final vaultFailed):
        if (vaultFailed) {
          _showError('The stored password could not be read. Enter it again.');
        }
        final entered = await _askPassword(d);
        if (entered != null) {
          await _connect(d, password: entered.$1, save: entered.$2);
        }
      case ConnectRefused(:final error, :final detail):
        state.lastError = error;
        state.lastDetail = detail;
        _note('Connect refused: ${error.code}');
        _showError(error.userMessage);
    }
    if (mounted) setState(() {});
  }

  /// Once the host accepted the login: stores the typed password if the
  /// owner asked for it and records the successful session. Both happen only
  /// while [d] is still the saved record; any edit or removal replaces it.
  Future<void> _afterLogin(DeviceRecord d, String password,
      {required bool save, required ConnectAttempt attempt}) async {
    bool stillCurrent() =>
        mounted && _catalog.devices.any((x) => identical(x, d));
    if (!await _connector.waitForLogin(d, password, attempt: attempt)) {
      if (attempt.isCancelled) {
        _note('Connect cancelled for device ${d.id} while logging in');
        return;
      }
      final failure = attempt.dialFailure;
      if (failure != null && failure.isFinal) {
        final code = failure.code!;
        _note('Secure connection failed for device ${d.id}: ${code.code}');
        final state = _states[d.id];
        if (state != null && mounted) {
          setState(() {
            state.lastError = code;
            state.lastDetail = failure.message;
          });
        }
        _showError(code.userMessage);
        return;
      }
      if (save) {
        _note('Password not saved for device ${d.id}: host did not accept it');
        _showError(
            'The password was not saved: the computer did not accept it.');
      }
      return;
    }
    // The session is logged in, but possibly with a password the owner
    // corrected in the viewer: that one is not saved, only [password] is,
    // and only if the host accepted exactly it.
    final keep = save && _connector.acceptedWith(d, password);
    if (save && !keep) {
      _note('Password not saved for device ${d.id}: '
          'the host accepted a different password');
      _showError('The password was not saved: the computer accepted a '
          'different password than the one you asked to save.');
    }
    if (!keep) {
      await _exclusive(() async {
        if (!stillCurrent()) return;
        try {
          await _write(recordLoginSuccess(_catalog, d.id, DateTime.now()));
        } catch (_) {
          // Only the session time is lost; already noted by _write.
        }
      });
      return;
    }
    // Waiting is outside the lock; the vault and list update is inside it.
    final result = await _exclusive(() => commitAcceptedPassword(
        _vault, d, password,
        stillCurrent: stillCurrent,
        writeRecord: _writeRecord,
        at: DateTime.now()));
    switch (result) {
      case PasswordSaveResult.saved:
        _note('Password saved for device ${d.id} after the host accepted it');
      case PasswordSaveResult.notAccepted:
        break;
      case PasswordSaveResult.vaultFailed:
        _showError('The password could not be stored. It was not saved.');
      case PasswordSaveResult.catalogFailed:
        _showError(d.credentialRef == null
            ? 'The computer list could not be saved to local storage, so the '
                'password was not saved.'
            : 'The computer list could not be saved to local storage. The '
                'new password was stored.');
      case PasswordSaveResult.deviceChanged:
        _note('Password not saved for device ${d.id}: settings changed');
        _showError('The password was not saved: the computer\'s settings '
            'changed while logging in.');
    }
  }

  Future<(String, bool)?> _askPassword(DeviceRecord d) {
    final controller = TextEditingController();
    var save = false;
    return showDialog<(String, bool)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Password for ${d.label}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Host password'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: save,
              onChanged: (v) => setLocal(() => save = v ?? false),
              title: const Text('Save on this device'),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    Navigator.pop(context, (controller.text, save));
                  }
                },
                child: const Text('Connect')),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(DeviceRecord d) {
    final s = _states[d.id];
    final status = deviceStatusLine(
        lastError: s?.lastError, verifiedServerName: s?.verifiedServerName);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(d.platform == HostPlatform.macos
                ? Icons.laptop_mac
                : Icons.laptop_windows),
            const SizedBox(width: 8),
            Expanded(
                child: Text(d.label,
                    style: Theme.of(context).textTheme.titleMedium)),
            if (!d.ownerConfirmed) const Chip(label: Text('Not confirmed')),
          ]),
          const SizedBox(height: 4),
          Text(
              '${d.endpoint.tlsServerName} · ${d.endpoint.tailnetIpv4}:${d.endpoint.tlsPort}'),
          Text(status),
          if (s?.attempt case final attempt?)
            ConnectStageLine(
                stage: attempt.stage,
                failure: attempt.dialFailure,
                onCancel: () {
                  _note('Cancel requested for device ${d.id}');
                  attempt.cancel();
                }),
          if (d.lastSuccessfulConnectionAt != null)
            Text(
                'Last successful session: ${d.lastSuccessfulConnectionAt!.toLocal()}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: d.ownerConfirmed && s?.attempt == null
                    ? () => _connect(d)
                    : null,
                child: const Text('Connect')),
            OutlinedButton(
                onPressed: () => _addOrEdit(d), child: const Text('Settings')),
            TextButton(
                onPressed: () => _delete(d), child: const Text('Remove')),
          ]),
        ]),
      ),
    );
  }

  Widget _devices() {
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_loadError!),
          const SizedBox(height: 12),
          FilledButton(onPressed: _load, child: const Text('Try again')),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _refreshVerified(),
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Text('My computers', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_catalog.devices.isEmpty)
          const Text('No computers yet. Add one with its Tailscale address '
              'and full MagicDNS name.'),
        for (final d in _catalog.devices) _deviceCard(d),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.icon(
              onPressed: _store == null ? null : () => _addOrEdit(),
              icon: const Icon(Icons.add),
              label: const Text('Add computer')),
          OutlinedButton.icon(
              onPressed: _store == null ? null : _importDevices,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Import')),
          OutlinedButton.icon(
              onPressed: _catalog.devices.isEmpty ? null : _exportDevices,
              icon: const Icon(Icons.upload_outlined),
              label: const Text('Export')),
          OutlinedButton.icon(
              onPressed: _showDiagnostics,
              icon: const Icon(Icons.medical_information_outlined),
              label: const Text('Diagnostics')),
        ]),
      ]),
    );
  }

  /// Plan 13.2: exports carry no password, credential handle or ownership
  /// confirmation. The owner copies the text to the other controller.
  void _exportDevices() {
    final text = exportDevices(_catalog);
    _note('Device list exported (${_catalog.devices.length} devices)');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export computers'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Names and addresses only. Passwords are not '
                'included; each computer must be confirmed again after '
                'import.'),
            const SizedBox(height: 8),
            Flexible(child: SingleChildScrollView(child: SelectableText(text))),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                _showError('Copied to the clipboard.');
              },
              child: const Text('Copy')),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  /// Plan 13.2: an import is pasted or read from a picked file, validated,
  /// and shown in full before anything is saved. It never connects; added
  /// computers stay unconfirmed until the owner confirms them in Settings.
  Future<void> _importDevices() async {
    final text = await showDialog<String>(
        context: context, builder: (_) => const _ImportSourceDialog());
    if (text == null || !mounted) return;
    final DeviceImportPlan plan;
    try {
      plan = planDeviceImport(_catalog, text);
    } on DeviceConfigException catch (e) {
      _note('Import rejected: ${e.code}');
      _showError('Import rejected: ${e.message}.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ImportPreviewDialog(plan: plan),
    );
    if (confirmed != true || plan.added.isEmpty) return;
    await _exclusive(() async {
      final before = _catalog.devices.length;
      final DeviceCatalog next;
      try {
        // Re-planned against the list as it is now, inside the lock.
        final now = planDeviceImport(_catalog, text);
        // The list changed while the preview was open: what was reviewed is
        // no longer what would be added.
        if (!sameImportPlan(now, plan)) {
          _showError('The computer list changed. Import again to review it.');
          return;
        }
        next = applyDeviceImport(_catalog, now);
      } on DeviceConfigException catch (e) {
        _showError('Import rejected: ${e.message}.');
        return;
      }
      try {
        await _write(next);
      } catch (_) {
        _showError('The computer list could not be saved to local storage.');
        return;
      }
      _note('Imported ${next.devices.length - before} unconfirmed devices');
    });
  }

  void _showDiagnostics() {
    final labels = _catalog.devices.map((d) => d.label);
    final lines = <String>[
      'Remote Hub diagnostics',
      'Tailscale path: unknown (not queried by the app)',
      for (final d in _catalog.devices)
        '${d.label}: TLS endpoint '
            '${_states[d.id]?.verifiedServerName != null ? 'verified ${_states[d.id]!.verifiedServerName}' : 'not checked'}; '
            'last error ${_states[d.id]?.lastError?.code ?? 'none'}',
      ..._log,
    ];
    final masked = redactDiagnostics(lines.join('\n'), labels: labels);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Diagnostics (masked)'),
        content: SingleChildScrollView(child: SelectableText(masked)),
        actions: [
          TextButton(
              onPressed: () {
                final failed = deleteDiagnostics(
                  clearMemoryLog: () => setState(_log.clear),
                  deleteNativeLogs: () => bind.remoteHubDeleteLogs(),
                );
                // The dialog shows what was just deleted.
                Navigator.pop(context);
                if (failed != null) {
                  _showError(failed);
                } else if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('Diagnostic logs deleted')));
                }
              },
              child: const Text('Delete log')),
          TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: masked)),
              child: const Text('Copy')),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!bind.remoteHubIsBuild()) {
      return Scaffold(
          body: Center(
              child: Text(
                  RemoteHubErrorCode.nativeLibraryUnavailable.userMessage)));
    }
    if (!isDesktop) {
      return Scaffold(
          appBar: AppBar(title: const Text('Remote Hub')), body: _devices());
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Remote Hub'),
          bottom: const TabBar(tabs: [
            Tab(text: 'My computers'),
            Tab(text: 'This computer'),
          ]),
        ),
        body: TabBarView(children: [
          _devices(),
          HostPanel(settings: _FfiHostSettings()),
        ]),
      ),
    );
  }
}

/// Asks for the import text: pasted, or read from a file the owner picks.
/// The file is only read (size-checked first), never written.
class _ImportSourceDialog extends StatefulWidget {
  const _ImportSourceDialog();

  @override
  State<_ImportSourceDialog> createState() => _ImportSourceDialogState();
}

class _ImportSourceDialogState extends State<_ImportSourceDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFile() async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final text = await readDeviceImportFile(File(path));
      if (mounted) Navigator.pop(context, text);
    } on DeviceConfigException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import computers'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Paste an export from another Remote Hub controller, '
              'or open an exported .json file.'),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            minLines: 4,
            maxLines: 10,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
                border: const OutlineInputBorder(), errorText: _error),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(onPressed: _openFile, child: const Text('Open file')),
        FilledButton(
            onPressed: () {
              if (_controller.text.trim().isNotEmpty) {
                Navigator.pop(context, _controller.text);
              }
            },
            child: const Text('Review')),
      ],
    );
  }
}

/// Shows every imported name and endpoint before anything is saved.
class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.plan});

  final DeviceImportPlan plan;

  static String _endpoint(DeviceRecord d) =>
      '${d.endpoint.tlsServerName} · ${d.endpoint.tailnetIpv4}:${d.endpoint.tlsPort}';

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    return AlertDialog(
      title: const Text('Review import'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (plan.added.isEmpty)
                  const Text('Nothing new to add.')
                else ...[
                  Text('Will be added, not confirmed:', style: style),
                  const Text('Check each address. Nothing connects until you '
                      'confirm the computer in its Settings.'),
                  for (final d in plan.added)
                    ListTile(
                        dense: true,
                        title: Text(d.label),
                        subtitle: Text(_endpoint(d))),
                ],
                if (plan.skipped.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Already in your list, left unchanged:', style: style),
                  for (final s in plan.skipped)
                    ListTile(
                        dense: true,
                        title: Text(s.device.label),
                        subtitle: Text(_endpoint(s.device))),
                ],
              ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed:
                plan.added.isEmpty ? null : () => Navigator.pop(context, true),
            child: Text('Add ${plan.added.length}')),
      ],
    );
  }
}
