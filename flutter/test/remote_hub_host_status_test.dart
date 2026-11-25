import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/remote_hub/host/host_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// A host whose status follows its options, recording the order of changes.
class _Host implements HostSettings {
  _Host({bool access = true, bool host = true}) {
    options[kOptionRemoteHubRole] = host ? 'host' : '';
    options[kOptionRemoteHubHostEnabled] = access ? 'Y' : 'N';
  }
  final Map<String, String> options = {};
  final List<String> log = [];
  bool passwordOk = true;

  /// When set, the platform password setter throws it.
  Object? passwordThrows;

  /// Runs when the password is set, to see what the host looked like then.
  void Function()? onSetPassword;

  bool get access => options[kOptionRemoteHubHostEnabled] == 'Y';

  @override
  Future<String> getOption(String key) async => options[key] ?? '';

  /// When set, writing options throws it (e.g. the bridge itself fails).
  Object? optionThrows;

  /// When set, the host service reports this instead of storing anything
  /// (e.g. it is not running), as the native writer does.
  String? optionError;

  @override
  Future<String?> writeOptions(Map<String, String> changes) async {
    for (final e in changes.entries) {
      log.add('${e.key}=${e.value}');
    }
    if (optionThrows != null) throw optionThrows!;
    if (optionError != null) return optionError;
    options.addAll(changes);
    return null;
  }

  /// When set, the password setter waits for it (a slow IPC call).
  Completer<void>? passwordGate;

  @override
  Future<bool> setPassword(String password) async {
    log.add('password');
    onSetPassword?.call();
    await passwordGate?.future;
    if (passwordThrows != null) throw passwordThrows!;
    return passwordOk;
  }

  /// What the host listener answers to an access change: null confirms it,
  /// a text is the failure (e.g. the host service is unreachable).
  String? accessError;

  /// Runs after a confirmed change.
  void Function()? onConfirmed;

  /// When set, a confirmation waits for it (sessions still closing).
  Completer<void>? confirmation;

  @override
  Future<String?> setAccess(bool allow) async {
    log.add('access=${allow ? 'Y' : 'N'}');
    // As natively: allowing is refused while a new password is shown, and
    // no password may be shown while an allow is in flight.
    if (allow && lease != null) {
      return 'a new host password is shown on this computer; '
          'hide it before allowing access';
    }
    if (allow) allowing++;
    try {
      await confirmation?.future;
      if (accessError != null) return accessError;
      options[kOptionRemoteHubHostEnabled] = allow ? 'Y' : 'N';
      log.add('confirmed');
      onConfirmed?.call();
      return null;
    } finally {
      if (allow) allowing--;
    }
  }

  @override
  String status() => '{"role":"${options[kOptionRemoteHubRole]}",'
      '"accessEnabled":$access,'
      '"passwordReady":true,"listening":$access,'
      '"listener":"${access ? 'listening' : 'stopped'}"}';

  /// The native lease shared by every panel (window) of the app.
  int? lease;
  int allowing = 0;
  int _next = 1;
  int renewals = 0;

  @override
  int beginPasswordDisplay() {
    if (access || allowing > 0) return 0;
    lease = _next++;
    return lease!;
  }

  @override
  bool renewPasswordDisplay(int l) {
    renewals++;
    return lease == l;
  }

  @override
  void endPasswordDisplay(int l) {
    if (lease == l) lease = null;
  }

  /// The lease ran out natively (e.g. nobody renewed it in time).
  void expire() => lease = null;
}

Widget _panel(_Host host) => HostPanel(settings: host);

/// Two host panels of one app, as in two windows.
Future<void> _twoPanels(WidgetTester tester, _Host host) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(2400, 1400);
  addTearDown(tester.view.reset);
  return tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Row(children: [
    Expanded(child: KeyedSubtree(key: const Key('A'), child: _panel(host))),
    Expanded(child: KeyedSubtree(key: const Key('B'), child: _panel(host))),
  ]))));
}

Finder _in(String panel, Finder f) =>
    find.descendant(of: find.byKey(Key(panel)), matching: f);

/// Rotates in panel [panel] while access is on, through the dialog.
Future<void> _rotate(WidgetTester tester, String panel) async {
  await tester.tap(_in(panel, find.text('Set a new password')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Stop access and continue'));
  await tester.pump();
  await tester.pump();
}

String _status(String listener, {bool listening = false}) =>
    '{"role":"host","accessEnabled":true,"passwordReady":true,'
    '"listening":$listening,"listener":"$listener"}';

void main() {
  test('only the listener loop itself counts as accepting', () {
    expect(
        HostStatus.fromJson(_status('listening', listening: true)).listenerText,
        'Accepting');
    expect(HostStatus.fromJson(_status('port_unavailable')).listenerText,
        'Port 22118 is used by another program');
    expect(HostStatus.fromJson(_status('stopped')).listenerText,
        'Not listening (access is off)');
    expect(HostStatus.fromJson(_status('not_running')).listenerText,
        'Host service is not running');
  });

  test('missing or broken status never reads as accepting', () {
    expect(HostStatus.fromJson('{}').listenerText, 'Not listening');
    expect(HostStatus.fromJson('not json').listening, isFalse);
  });

  group('password rotation never shows a password to a connected controller',
      () {
    test('the password changes only after the host confirmed the stop',
        () async {
      final host = _Host()..confirmation = Completer();
      var accessWhenSet = true;
      host.onSetPassword = () => accessWhenSet = host.access;
      final pending = rotateHostPassword(host, generate: () => 'new-pw');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(host.log, ['access=N'],
          reason: 'sessions still closing: no password yet');
      host.confirmation!.complete();
      final shown = await pending;
      expect(shown?.password, 'new-pw');
      expect(host.lease, shown?.lease, reason: 'shown only under a lease');
      expect(accessWhenSet, isFalse);
      expect(host.log, ['access=N', 'confirmed', 'password']);
      expect(host.access, isFalse, reason: 'access stays off after rotation');
    });

    test('an unconfirmed stop changes and shows nothing', () async {
      // Review finding: with IPC down the old path still "succeeded" and
      // showed a new password after a fixed delay.
      final host = _Host()..accessError = 'the host service is not reachable';
      await expectLater(rotateHostPassword(host, generate: () => 'new-pw'),
          throwsA(isA<HostAccessError>()));
      expect(host.log, isNot(contains('password')));
      expect(host.access, isTrue);
    });

    test('nothing is changed or shown if access came back on meanwhile',
        () async {
      final host = _Host()..confirmation = Completer();
      final pending = rotateHostPassword(host, generate: () => 'new-pw');
      await Future<void>.delayed(Duration.zero);
      host.confirmation!.complete();
      // Allowed again (e.g. by another window) before the rotation ran.
      host.onConfirmed = () => host.options[kOptionRemoteHubHostEnabled] = 'Y';
      expect(await pending, isNull);
      expect(host.log, isNot(contains('password')));
      expect(host.lease, isNull);
    });

    test('nothing is changed while another window is allowing access',
        () async {
      final host = _Host(access: false)..allowing = 1;
      expect(await rotateHostPassword(host, generate: () => 'x'), isNull);
      expect(host.log, isNot(contains('password')));
      expect(host.lease, isNull);
    });

    test('a failed change shows nothing and releases the lease', () async {
      final host = _Host(access: false)..passwordOk = false;
      expect(await rotateHostPassword(host, generate: () => 'x'), isNull);
      expect(host.lease, isNull);
    });

    test('a throwing password setter releases the lease', () async {
      final host = _Host(access: false)..passwordThrows = StateError('io');
      await expectLater(rotateHostPassword(host, generate: () => 'x'),
          throwsA(isA<StateError>()));
      expect(host.lease, isNull, reason: 'Allow access must not stay blocked');
    });

    test('the lease is renewed while a slow password change runs',
        () async {
      // Review finding: the lease was taken once and not renewed while the
      // setter ran, so it could run out before the password was shown.
      final host = _Host(access: false)..passwordGate = Completer();
      final pending = rotateHostPassword(host,
          generate: () => 'x', renewEvery: const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(host.renewals, greaterThan(1),
          reason: 'renewed during the change, not only after it');
      host.passwordGate!.complete();
      final shown = await pending;
      expect(shown?.password, 'x');
      expect(host.lease, shown?.lease);
    });

    test('a lease lost during the change shows nothing', () async {
      final host = _Host(access: false)..passwordGate = Completer();
      final pending = rotateHostPassword(host,
          generate: () => 'x', renewEvery: const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The lease ran out natively; another window may allow access now.
      host.expire();
      host.passwordGate!.complete();
      await expectLater(pending, throwsA(isA<HostPasswordNotShownError>()));
      expect(host.lease, isNull);
    });

    test('a lease lost just before the change finished shows nothing',
        () async {
      final host = _Host(access: false);
      host.onSetPassword = host.expire;
      await expectLater(
          rotateHostPassword(host,
              generate: () => 'x', renewEvery: const Duration(seconds: 30)),
          throwsA(isA<HostPasswordNotShownError>()));
    });

    testWidgets('panel recovers when the password setter throws',
        (tester) async {
      // Review finding: only HostAccessError was caught, so the panel kept
      // its rotating state and the password controls stayed disabled.
      final host = _Host(access: false)..passwordThrows = StateError('io');
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HostPanel(settings: host))));
      await tester.tap(find.text('Set a new password'));
      await tester.pump();
      await tester.pump();
      expect(host.lease, isNull);
      expect(find.textContaining('could not be changed'), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text('Set a new password'),
          matching: find.bySubtype<ButtonStyleButton>()));
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('panel ends access before showing, and hides on re-allow',
        (tester) async {
      final host = _Host()..confirmation = Completer();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HostPanel(settings: host))));

      await tester.tap(find.text('Set a new password'));
      await tester.pumpAndSettle();
      expect(find.text('Stop access and continue'), findsOneWidget);
      expect(host.log, isEmpty, reason: 'nothing happens before confirming');
      await tester.tap(find.text('Stop access and continue'));
      await tester.pump();

      // The stop is requested but not confirmed yet: no password.
      expect(host.log, ['access=N']);
      expect(find.text('Ending sessions…'), findsOneWidget);
      expect(find.text('New host password (shown once)'), findsNothing);

      host.confirmation!.complete();
      host.confirmation = null;
      await tester.pump();
      await tester.pump();
      expect(host.log, ['access=N', 'confirmed', 'password']);
      expect(find.text('New host password (shown once)'), findsOneWidget);

      // Allowing access again takes the password off the screen.
      await tester.tap(find.text('Allow access'));
      await tester.pump();
      await tester.pump();
      expect(host.access, isTrue);
      expect(find.text('New host password (shown once)'), findsNothing);
      expect(host.lease, isNull);

      await tester.pumpWidget(const SizedBox());
    });

    // Review finding: a second panel could allow access after the rotation's
    // check, and the first kept showing the new password until its refresh.
    testWidgets('another window cannot allow access while a password shows',
        (tester) async {
      final host = _Host();
      await _twoPanels(tester, host);
      await _rotate(tester, 'A');
      expect(_in('A', find.text('New host password (shown once)')),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // B sees access off.

      await tester.tap(_in('B', find.text('Allow access')));
      await tester.pump();
      await tester.pump();
      expect(host.access, isFalse, reason: 'refused while A shows it');
      expect(
          find.textContaining('Access could not be allowed: a new host '
              'password is shown'),
          findsOneWidget);
      expect(_in('A', find.text('New host password (shown once)')),
          findsOneWidget);

      // Once A hides it, B can allow.
      await tester.tap(_in('A', find.byTooltip('Hide password')));
      await tester.pump();
      expect(host.lease, isNull);
      expect(
          _in('A', find.text('New host password (shown once)')), findsNothing);
      await tester.tap(_in('B', find.text('Allow access')));
      await tester.pump();
      await tester.pump();
      expect(host.access, isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a lost lease takes the password off the screen in time',
        (tester) async {
      final host = _Host();
      await _twoPanels(tester, host);
      await _rotate(tester, 'A');
      final before = host.renewals;
      await tester.pump(kHostPasswordLeaseTtl * 2);
      expect(host.renewals, greaterThan(before), reason: 'kept alive');
      expect(_in('A', find.text('New host password (shown once)')),
          findsOneWidget);

      // The lease ends natively (or a newer password in another window
      // replaced it): gone at the next renewal, well within the TTL.
      host.expire();
      await tester.pump(kHostPasswordRenewEvery);
      expect(
          _in('A', find.text('New host password (shown once)')), findsNothing);
      expect(kHostPasswordRenewEvery + kHostPasswordHideMargin,
          lessThanOrEqualTo(kHostPasswordLeaseTtl));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('closing the panel releases the lease', (tester) async {
      final host = _Host();
      await _twoPanels(tester, host);
      await _rotate(tester, 'A');
      expect(host.lease, isNotNull);
      await tester.pumpWidget(const SizedBox());
      expect(host.lease, isNull);
    });
  });

  group('stop access is shown as done only when the host confirmed it', () {
    testWidgets('an unreachable host keeps access ON and says so',
        (tester) async {
      final host = _Host()..accessError = 'the host service is not reachable';
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HostPanel(settings: host))));
      await tester.tap(find.text('Stop access'));
      await tester.pump();
      await tester.pump();
      expect(host.access, isTrue);
      expect(find.text('ON'), findsOneWidget);
      expect(find.text('Stop access'), findsOneWidget);
      expect(
          find.text('Access could not be stopped: '
              'the host service is not reachable'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('OFF appears only after the confirmation', (tester) async {
      final host = _Host()..confirmation = Completer();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HostPanel(settings: host))));
      await tester.tap(find.text('Stop access'));
      await tester.pump();
      expect(find.text('Stopping…'), findsOneWidget);
      expect(find.text('ON'), findsOneWidget);
      host.confirmation!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('OFF'), findsOneWidget);
      expect(find.text('Allow access'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets(
      'host setup the service did not store says so and stays a controller',
      (tester) async {
    // Review finding: the real adapter used mainSetOption, which drops IPC
    // write errors, so an unreachable host service looked like success.
    final host = _Host(access: false, host: false)
      ..optionError = 'the host service is not reachable; nothing was saved';
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HostPanel(settings: host))));
    await tester.tap(find.text('Make this computer a host'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
        find.textContaining('host service is not reachable'), findsOneWidget);
    expect(find.text('Make this computer a host'), findsOneWidget);
    expect(host.options[kOptionRemoteHubRole], isNot('host'));
    await tester.pumpWidget(const SizedBox());
  });

  test('a host role is written in one request with its restrictions', () async {
    final host = _Host(access: false, host: false)
      ..optionError = 'the host service did not store: remote-hub-role';
    await expectLater(
        setHostRole(host, true), throwsA(isA<HostSettingsError>()));
    expect(host.options[kOptionRemoteHubRole], isNot('host'));
  });

  testWidgets('host setup that cannot be saved says so and stays a controller',
      (tester) async {
    final host = _Host(access: false, host: false)
      ..optionThrows = StateError('settings store failed');
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HostPanel(settings: host))));
    await tester.tap(find.text('Make this computer a host'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
        find.textContaining('The change could not be applied'), findsOneWidget);
    expect(find.text('Make this computer a host'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
