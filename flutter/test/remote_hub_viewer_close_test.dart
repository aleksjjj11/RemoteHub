import 'dart:async';

import 'package:flutter_hbb/remote_hub/remote_hub_build.dart';
import 'package:flutter_hbb/remote_hub/sessions/viewer_close.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake clock the waits advance, so the tests do not sleep.
class _Clock {
  DateTime t = DateTime(2026, 1, 1);
  DateTime now() => t;
  Future<void> sleep(Duration d) async => t = t.add(d);
}

void main() {
  group('closeViewerWhenItAppears', () {
    test('closes a viewer whose tab appears after the cancel', () async {
      // The window is registered, but its tab only exists from the fourth
      // try on: the first tries find nothing to close.
      final clock = _Clock();
      var tries = 0;
      var tabOpen = false;
      final closed = await closeViewerWhenItAppears(
        tryClose: () async {
          tries++;
          if (tries == 4) tabOpen = true;
          if (!tabOpen) return false;
          tabOpen = false;
          return true;
        },
        superseded: () => false,
        sleep: clock.sleep,
        now: clock.now,
      );
      expect(closed, isTrue);
      expect(tries, 4);
      expect(tabOpen, isFalse);
    });

    test('a window without a handler yet is retried, not given up on',
        () async {
      final clock = _Clock();
      var tries = 0;
      final closed = await closeViewerWhenItAppears(
        tryClose: () async {
          tries++;
          if (tries < 3) throw StateError('MissingPluginException');
          return true;
        },
        superseded: () => false,
        sleep: clock.sleep,
        now: clock.now,
      );
      expect(closed, isTrue);
      expect(tries, 3);
    });

    test('stops when a newer connect of the same device started', () async {
      final clock = _Clock();
      final generations = ViewerGenerations();
      generations.opened('rh1');
      final at = generations.current('rh1');
      var tries = 0;
      final closed = await closeViewerWhenItAppears(
        tryClose: () async {
          tries++;
          // The owner connects again before the cancelled tab appeared.
          if (tries == 2) generations.opened('rh1');
          return false;
        },
        superseded: () => generations.current('rh1') != at,
        sleep: clock.sleep,
        now: clock.now,
      );
      expect(closed, isFalse);
      expect(tries, 2, reason: 'the new session must not be closed');
    });

    test('gives up after the timeout when no viewer ever appears', () async {
      final clock = _Clock();
      var tries = 0;
      final closed = await closeViewerWhenItAppears(
        tryClose: () async {
          tries++;
          return false;
        },
        superseded: () => false,
        timeout: const Duration(seconds: 1),
        interval: const Duration(milliseconds: 200),
        sleep: clock.sleep,
        now: clock.now,
      );
      expect(closed, isFalse);
      expect(tries, 6);
    });
  });

  test('generations are counted per device', () {
    final g = ViewerGenerations();
    g.opened('a');
    g.opened('a');
    g.opened('b');
    expect(g.current('a'), 2);
    expect(g.current('b'), 1);
    expect(g.current('c'), 0);
  });

  group('ViewerTracker', () {
    const hubPeer = 'rh0123456789abcdef0123456789abcdef';

    test('tracks a Remote Hub viewer while it is being opened', () async {
      final tracker = ViewerTracker(enabled: true);
      final opened = Completer<int>();
      final result = tracker.track(hubPeer, () => opened.future);
      expect(tracker.isOpening(hubPeer), isTrue);
      expect(tracker.generations.current(hubPeer), 1);
      opened.complete(7);
      expect(await result, 7);
      expect(tracker.isOpening(hubPeer), isFalse);
      expect(tracker.generations.current(hubPeer), 1);
    });

    test('a failed open is no longer counted as opening', () async {
      final tracker = ViewerTracker(enabled: true);
      await expectLater(
          tracker.track<int>(hubPeer, () async => throw StateError('x')),
          throwsStateError);
      expect(tracker.isOpening(hubPeer), isFalse);
    });

    // Review finding: every upstream newRemoteDesktop updated the Remote Hub
    // bookkeeping, even in a build without Remote Hub.
    test('without Remote Hub the viewer is only opened', () async {
      final tracker = ViewerTracker(enabled: false);
      final opened = Completer<int>();
      final result = tracker.track(hubPeer, () => opened.future);
      expect(tracker.isOpening(hubPeer), isFalse);
      expect(tracker.generations.current(hubPeer), 0);
      opened.complete(1);
      expect(await result, 1);
    });

    test('a peer that is not a Remote Hub device is not tracked', () async {
      final tracker = ViewerTracker(enabled: true);
      final opened = Completer<int>();
      final result = tracker.track('123456789', () => opened.future);
      expect(tracker.isOpening('123456789'), isFalse);
      expect(tracker.generations.current('123456789'), 0);
      opened.complete(1);
      expect(await result, 1);
    });

    test('Remote Hub peer ids match the native format', () {
      expect(isRemoteHubPeerId(hubPeer), isTrue);
      expect(
          isRemoteHubPeerId(
              peerIdFor('01234567-89ab-cdef-0123-456789abcdef')),
          isTrue);
      expect(isRemoteHubPeerId('rh0123'), isFalse);
      expect(isRemoteHubPeerId('rh0123456789ABCDEF0123456789abcdef'), isFalse);
      expect(isRemoteHubPeerId('123456789'), isFalse);
    });
  });

  group('closeInWindows', () {
    // Review finding: a window that did not answer read as "nothing open".
    Future<ViewerCloseResult> close(Map<int, Object?> answers,
            {bool opening = false}) =>
        closeInWindows(
          windows: answers.keys,
          opening: opening,
          invoke: (id) async {
            final a = answers[id];
            if (a is Exception) throw a;
            return a;
          },
        );

    test('a closed tab in any window is closed', () async {
      expect(await close({1: false, 2: true}), ViewerCloseResult.closed);
    });

    test('every window answering false means none open', () async {
      expect(await close({1: false, 2: false}), ViewerCloseResult.noneOpen);
      expect(await close({}), ViewerCloseResult.noneOpen);
    });

    test('a window that throws or does not answer is unconfirmed', () async {
      expect(await close({1: true, 2: Exception('no handler')}),
          ViewerCloseResult.unconfirmed);
      expect(await close({1: false, 2: null}), ViewerCloseResult.unconfirmed);
    });

    test('a viewer still being opened is unconfirmed', () async {
      expect(await close({1: false}, opening: true),
          ViewerCloseResult.unconfirmed);
    });
  });

  group('closeViewerConfirmed', () {
    test('retries until confirmed', () async {
      final answers = [
        ViewerCloseResult.unconfirmed,
        ViewerCloseResult.noneOpen,
      ];
      var waits = 0;
      expect(
          await closeViewerConfirmed(
              tryClose: () async => answers.removeAt(0),
              sleep: (_) async => waits++),
          isTrue);
      expect(waits, 1);
    });

    test('gives up after the timeout', () async {
      var t = DateTime(2026);
      expect(
          await closeViewerConfirmed(
              tryClose: () async => throw StateError('x'),
              timeout: const Duration(seconds: 1),
              now: () => t,
              sleep: (d) async => t = t.add(d)),
          isFalse);
    });
  });
}
