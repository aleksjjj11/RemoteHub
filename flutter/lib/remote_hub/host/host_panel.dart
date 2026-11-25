import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../credentials/credential_vault.dart';

/// Host options read by the native `remote_hub` module and the engine.
const kOptionRemoteHubRole = 'remote-hub-role';
const kOptionRemoteHubHostEnabled = 'remote-hub-host-enabled';

/// Engine options a Remote Hub host always uses: permanent password only, no
/// click approval, a visible connection window, and every v0.1-excluded
/// feature off. The host also enforces these per message (plan 17.3).
const Map<String, String> kRemoteHubHostOptions = {
  'approve-mode': 'password',
  'verification-method': 'use-permanent-password',
  'allow-hide-cm': 'N',
  'enable-clipboard': 'N',
  'enable-file-transfer': 'N',
  'enable-audio': 'N',
  'enable-tunnel': 'N',
  'enable-remote-restart': 'N',
  'enable-record-session': 'N',
  'enable-block-input': 'N',
  'enable-terminal': 'N',
  'enable-camera': 'N',
  'enable-remote-printer': 'N',
  'direct-server': 'N',
};

abstract interface class HostSettings {
  Future<String> getOption(String key);

  /// Writes [changes] (an empty value removes the option) to the host
  /// service and completes once it read them back: null then, or what
  /// failed. A failed write must never be reported as saved.
  Future<String?> writeOptions(Map<String, String> changes);
  Future<bool> setPassword(String password);

  /// Stops or allows access through the host listener itself. Completes
  /// only after the listener confirmed it (on stop: listener closed and
  /// every session ended); returns null then, or what failed. On failure
  /// nothing was changed.
  Future<String?> setAccess(bool allow);

  /// JSON from the native side: role, accessEnabled, passwordReady,
  /// listening and listener (the listener loop's own state, never a port
  /// probe).
  String status();

  /// Before a new password is set and shown: a lease (> 0) shared by every
  /// panel of this app, or 0 when access is on or being allowed in any
  /// window. While a lease is live no window can allow access.
  int beginPasswordDisplay();

  /// Keeps the lease for [kHostPasswordLeaseTtl] more. False when it ran out,
  /// ended or was replaced by a newer password: hide the password now.
  bool renewPasswordDisplay(int lease);

  /// The password left the screen; access may be allowed again.
  void endPasswordDisplay(int lease);
}

/// How long a password lease lasts without renewal (native
/// `PASSWORD_DISPLAY_TTL`). A panel renews every [kHostPasswordRenewEvery]
/// and hides the password on its own [kHostPasswordHideMargin] before the
/// lease can run out, so no window can allow access while it is visible.
const kHostPasswordLeaseTtl = Duration(seconds: 10);
const kHostPasswordRenewEvery = Duration(seconds: 2);
const kHostPasswordHideMargin = Duration(seconds: 2);

/// A host password just set, with the lease that allows showing it.
class NewHostPassword {
  NewHostPassword(this.password, this.lease);
  final String password;
  final int lease;
}

class HostStatus {
  HostStatus.fromJson(String raw) : _json = _decode(raw);
  final Map<String, dynamic> _json;

  static Map<String, dynamic> _decode(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : const {};
    } on FormatException {
      return const {};
    }
  }

  bool get isHost => _json['role'] == 'host';
  bool get accessEnabled => _json['accessEnabled'] == true;
  bool get passwordReady => _json['passwordReady'] == true;
  bool get listening => _json['listening'] == true;

  /// What the Listener row says. "Accepting" only when the Remote Hub loop
  /// itself holds the port; another program on 22118 is named as such.
  String get listenerText {
    if (listening) return 'Accepting';
    switch (_json['listener']) {
      case 'port_unavailable':
        return 'Port 22118 is used by another program';
      case 'stopped':
        return 'Not listening (access is off)';
      case 'not_running':
        return 'Host service is not running';
      default:
        return 'Not listening';
    }
  }
}

/// The host did not confirm an access change; [message] says what failed.
class HostAccessError implements Exception {
  HostAccessError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The host service did not store the host settings; [message] says why.
class HostSettingsError implements Exception {
  HostSettingsError(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<void> _writeOptions(HostSettings s, Map<String, String> changes) async {
  final error = await s.writeOptions(changes);
  if (error != null) throw HostSettingsError(error);
}

/// Turns this computer into a host or back. Becoming a host applies the
/// restricted engine options but leaves access off until the owner allows it.
/// Leaving the host role first stops access with confirmation and throws
/// [HostAccessError] (keeping the role) if the host did not confirm it.
/// Throws [HostSettingsError] when the host service did not store the role
/// and its restrictions; the role is written in the same request as the
/// restrictions, so it is never stored without them.
Future<void> setHostRole(HostSettings s, bool host) async {
  if (host) {
    await _writeOptions(s, {
      ...kRemoteHubHostOptions,
      kOptionRemoteHubHostEnabled: 'N',
      kOptionRemoteHubRole: 'host',
    });
  } else {
    await setHostAccess(s, false);
    await _writeOptions(s, {kOptionRemoteHubRole: ''});
  }
}

/// Local "Stop access" / "Allow access" (plan 17.5). Stopping is stored, so it
/// survives restarts. Completes only after the host listener confirmed the
/// change (on stop: listener closed, every session ended); throws
/// [HostAccessError] otherwise, so a stop is never shown as done when the
/// host process still accepts.
Future<void> setHostAccess(HostSettings s, bool allow) async {
  final error = await s.setAccess(allow);
  if (error != null) throw HostAccessError(error);
}

/// The host password was changed, but its display lease ran out while the
/// change was in progress: another window may have allowed access since,
/// so the password is not shown. The owner sets a new one.
class HostPasswordNotShownError implements Exception {
  const HostPasswordNotShownError();
  @override
  String toString() => 'the password was changed but can no longer be '
      'shown safely';
}

/// Sets a new host password without letting a connected controller see it.
///
/// A controller sees the host screen, so a password shown while one is
/// connected would let it keep access after the rotation. Access is stopped
/// first and the host must confirm that its listener is closed and every
/// session ended. Then a display lease is taken, which fails if any window
/// allowed access again meanwhile and keeps every window from allowing it
/// while the password is shown; only then is the password changed. The
/// lease is renewed every [renewEvery] while the change runs, so a slow
/// setter does not let it run out; if it is lost anyway, nothing is shown
/// and [HostPasswordNotShownError] is thrown when the password did change.
/// Access stays off: the owner allows it again once the password is copied.
/// Returns null when the password was not changed, so nothing is shown;
/// throws [HostAccessError] when the host did not confirm the stop.
Future<NewHostPassword?> rotateHostPassword(
  HostSettings s, {
  String Function() generate = generateHostPassword,
  Duration renewEvery = kHostPasswordRenewEvery,
}) async {
  await setHostAccess(s, false);
  final lease = s.beginPasswordDisplay();
  if (lease <= 0) return null;
  var held = true;
  final renewal = Timer.periodic(renewEvery, (t) {
    if (!s.renewPasswordDisplay(lease)) {
      held = false;
      t.cancel();
    }
  });
  final String password;
  final bool changed;
  try {
    password = generate();
    changed = await s.setPassword(password);
  } catch (_) {
    // Nothing will be shown: never leave the lease blocking "Allow access".
    s.endPasswordDisplay(lease);
    rethrow;
  } finally {
    renewal.cancel();
  }
  // The lease must still be live now, not only at the last tick.
  if (held && !s.renewPasswordDisplay(lease)) held = false;
  if (!changed || !held) {
    s.endPasswordDisplay(lease);
    if (changed) throw const HostPasswordNotShownError();
    return null;
  }
  return NewHostPassword(password, lease);
}

/// Local host panel (plan 12.6).
class HostPanel extends StatefulWidget {
  const HostPanel({super.key, required this.settings});
  final HostSettings settings;

  @override
  State<HostPanel> createState() => _HostPanelState();
}

class _HostPanelState extends State<HostPanel> {
  late HostStatus _status;
  Timer? _timer;
  bool _rotating = false;

  /// The new password on screen, only while its lease is live.
  NewHostPassword? _shown;
  Timer? _renewTimer;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _status = HostStatus.fromJson(widget.settings.status());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hidePassword(rebuild: false);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _status = HostStatus.fromJson(widget.settings.status());
    });
    // A password stays on screen only while no controller can connect.
    if (_status.accessEnabled) _hidePassword();
  }

  /// Shows [p] for as long as its lease is renewed. Returns false (and shows
  /// nothing) when the lease is already gone.
  bool _showPassword(NewHostPassword p) {
    _shown = p;
    if (!_renewLease()) return false;
    _renewTimer = Timer.periodic(kHostPasswordRenewEvery, (_) => _renewLease());
    setState(() {});
    return true;
  }

  /// The hide deadline starts before the renewal, so it is always earlier
  /// than the lease's end: once another window may allow access, this
  /// password is already gone from the screen.
  bool _renewLease() {
    final p = _shown;
    if (p == null) return false;
    final deadline =
        Timer(kHostPasswordLeaseTtl - kHostPasswordHideMargin, _hidePassword);
    if (!widget.settings.renewPasswordDisplay(p.lease)) {
      deadline.cancel();
      _hidePassword();
      return false;
    }
    _hideTimer?.cancel();
    _hideTimer = deadline;
    return true;
  }

  void _hidePassword({bool rebuild = true}) {
    _renewTimer?.cancel();
    _renewTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    final p = _shown;
    if (p == null) return;
    _shown = null;
    widget.settings.endPasswordDisplay(p.lease);
    if (rebuild && mounted) setState(() {});
  }

  bool _busy = false;

  void _showError(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs [action]; access changes complete only once the host confirmed
  /// them, so the refreshed status is what the host really does.
  Future<void> _run(Future<void> Function() action,
      {String failure = 'The change could not be applied'}) async {
    setState(() => _busy = true);
    try {
      await action();
    } on HostAccessError catch (e) {
      _showError('$failure: $e');
    } catch (e) {
      // e.g. a settings write failed: the change is not done, so say so
      // rather than leave an unhandled error and a silent panel.
      _showError('$failure: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  /// The new password leaves the screen before anyone can connect again.
  void _allowAccess() {
    _hidePassword();
    _run(() => setHostAccess(widget.settings, true),
        failure: 'Access could not be allowed');
  }

  Future<void> _changePassword() async {
    if (_status.accessEnabled) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Set a new password?'),
          content: const Text('Remote access will be stopped and the '
              'connected controller disconnected before the new password '
              'is shown. Allow access again when you have copied it.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Stop access and continue')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    _hidePassword();
    setState(() => _rotating = true);
    NewHostPassword? password;
    String? error;
    try {
      password = await rotateHostPassword(widget.settings);
    } on HostAccessError catch (e) {
      error = 'Access could not be stopped, so the password was not '
          'changed: $e';
    } on HostPasswordNotShownError {
      error = 'The password was changed but can no longer be shown '
          'safely. Set a new password again.';
    } catch (e) {
      // E.g. the platform password setter threw. The lease is already
      // released; the controls must not stay disabled.
      error = 'The password could not be changed: $e';
    }
    if (!mounted) {
      if (password != null) widget.settings.endPasswordDisplay(password.lease);
      return;
    }
    setState(() => _rotating = false);
    if (password == null) {
      _showError(error ??
          'The password was not changed: access is on or '
              'being allowed in another window.');
    } else if (!_showPassword(password)) {
      _showError('The password was changed but can no longer be shown '
          'safely. Set a new password again.');
    }
    _refresh();
  }

  Widget _row(String title, String value, {bool ok = true}) => ListTile(
        dense: true,
        title: Text(title),
        trailing: Text(value,
            style: TextStyle(
                color: ok ? null : Theme.of(context).colorScheme.error)),
      );

  @override
  Widget build(BuildContext context) {
    final s = _status;
    if (!s.isHost) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('This computer is a controller. It does not accept '
            'remote sessions.'),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(() => setHostRole(widget.settings, true)),
          child: const Text('Make this computer a host'),
        ),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      _row('Remote access', s.accessEnabled ? 'ON' : 'OFF',
          ok: s.accessEnabled),
      _row('Network', 'Only through Tailscale Serve (127.0.0.1:22118)'),
      _row('Listener', s.listenerText, ok: s.listening || !s.accessEnabled),
      _row('Host password', s.passwordReady ? 'Set' : 'Not set',
          ok: s.passwordReady),
      const ListTile(
        dense: true,
        title: Text('Screen and control permissions'),
        subtitle: Text('Granted in System Settings > Privacy & Security '
            '(Screen Recording, Accessibility). Active sessions are shown '
            'in the connection window.'),
      ),
      if (_shown != null && !s.accessEnabled)
        Card(
          child: ListTile(
            title: const Text('New host password (shown once)'),
            subtitle: SelectableText(_shown!.password),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _shown!.password)),
              ),
              IconButton(
                icon: const Icon(Icons.visibility_off),
                tooltip: 'Hide password',
                onPressed: _hidePassword,
              ),
            ]),
          ),
        ),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (s.accessEnabled && !_rotating)
          FilledButton.icon(
            icon: const Icon(Icons.stop_circle),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: _busy
                ? null
                : () => _run(() => setHostAccess(widget.settings, false),
                    failure: 'Access could not be stopped'),
            label: Text(_busy ? 'Stopping…' : 'Stop access'),
          )
        else
          FilledButton(
            onPressed:
                s.passwordReady && !_rotating && !_busy ? _allowAccess : null,
            child: const Text('Allow access'),
          ),
        OutlinedButton(
          onPressed: _rotating || _busy ? null : _changePassword,
          child: Text(_rotating ? 'Ending sessions…' : 'Set a new password'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() => setHostRole(widget.settings, false),
                  failure: 'Access could not be stopped'),
          child: const Text('Stop being a host'),
        ),
      ]),
    ]);
  }
}
