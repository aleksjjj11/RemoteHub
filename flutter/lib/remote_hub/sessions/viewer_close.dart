import 'dart:async';

/// Closes a viewer that may not exist yet.
///
/// A desktop viewer window is registered before its Flutter tab is created,
/// so a cancel that arrives in between finds nothing to close. This retries
/// [tryClose] every [interval] until it reports a closed viewer, until
/// [superseded] says a newer connect of the same device has started (whose
/// viewer must stay open), or until [timeout]. Returns true once a viewer
/// was closed.
Future<bool> closeViewerWhenItAppears({
  required Future<bool> Function() tryClose,
  required bool Function() superseded,
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 200),
  Future<void> Function(Duration)? sleep,
  DateTime Function() now = DateTime.now,
}) async {
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  final deadline = now().add(timeout);
  while (true) {
    if (superseded()) return false;
    bool closed;
    try {
      closed = await tryClose();
    } catch (_) {
      // A window whose handler is not registered yet throws; try again.
      closed = false;
    }
    if (closed) return true;
    if (!now().isBefore(deadline)) return false;
    await wait(interval);
  }
}

/// Counts connects per peer so a pending close can tell that a newer
/// connect of the same peer started and must not be closed.
class ViewerGenerations {
  final Map<String, int> _generation = {};

  int current(String peerId) => _generation[peerId] ?? 0;

  /// Called when a new viewer for [peerId] is requested.
  void opened(String peerId) => _generation[peerId] = current(peerId) + 1;
}

/// Remote Hub bookkeeping of the desktop viewers being opened: how many
/// connects of each peer started ([generations]) and which are still being
/// opened (their window is not registered yet, so a close cannot reach
/// them). Only Remote Hub sessions are tracked: with [enabled] false (a
/// build without Remote Hub) or for a peer that is not a Remote Hub device,
/// [track] only opens the viewer, so the upstream path is unchanged.
class ViewerTracker {
  ViewerTracker({required this.enabled});

  final bool enabled;
  final generations = ViewerGenerations();
  final Map<String, int> _opening = {};

  /// True while a viewer of [peerId] is being opened.
  bool isOpening(String peerId) => _opening.containsKey(peerId);

  /// Runs [open], the upstream opening of a viewer of [peerId], and counts
  /// it as a new connect that is being opened until [open] completes.
  Future<T> track<T>(String peerId, Future<T> Function() open) async {
    if (!enabled || !isRemoteHubPeerId(peerId)) return open();
    generations.opened(peerId);
    _opening[peerId] = (_opening[peerId] ?? 0) + 1;
    try {
      return await open();
    } finally {
      final left = (_opening[peerId] ?? 1) - 1;
      if (left > 0) {
        _opening[peerId] = left;
      } else {
        _opening.remove(peerId);
      }
    }
  }
}

/// True for an engine peer id of a Remote Hub device (`peerIdFor`): `rh`
/// and 32 lowercase hex digits, as `remote_hub::is_peer_id` checks natively.
bool isRemoteHubPeerId(String peerId) =>
    RegExp(r'^rh[0-9a-f]{32}$').hasMatch(peerId);

/// What a close of the viewer of one peer found.
enum ViewerCloseResult {
  /// A viewer was open and is closed now.
  closed,

  /// Every viewer window answered and none showed the peer, and no viewer
  /// of the peer was still being opened.
  noneOpen,

  /// A window did not answer (its handler is not registered yet, so its
  /// tab may still appear, or the call failed), or a viewer of the peer is
  /// still being opened. It may still be open or open later.
  unconfirmed;

  /// True when no viewer of the peer remains.
  bool get confirmed => this != unconfirmed;
}

/// Asks every window in [windows] to close the viewer of a peer through
/// [invoke], which returns the window's answer: true when it closed one,
/// false when it had none. Any other answer, or an error, leaves the result
/// unconfirmed, as does [opening]: a viewer of the peer whose window is not
/// registered yet.
Future<ViewerCloseResult> closeInWindows({
  required Iterable<int> windows,
  required Future<Object?> Function(int windowId) invoke,
  required bool opening,
  void Function(int windowId, Object error)? onError,
}) async {
  var closed = false;
  var unconfirmed = opening;
  for (final windowId in List.of(windows)) {
    Object? answer;
    try {
      answer = await invoke(windowId);
    } catch (e) {
      onError?.call(windowId, e);
      unconfirmed = true;
      continue;
    }
    if (answer == true) {
      closed = true;
    } else if (answer != false) {
      unconfirmed = true;
    }
  }
  if (unconfirmed) return ViewerCloseResult.unconfirmed;
  return closed ? ViewerCloseResult.closed : ViewerCloseResult.noneOpen;
}

/// Closes the viewer of a peer until [tryClose] confirms that none remains,
/// retrying every [interval] until [timeout]. True once confirmed; false
/// when a viewer may still be open or still open later.
Future<bool> closeViewerConfirmed({
  required Future<ViewerCloseResult> Function() tryClose,
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 200),
  Future<void> Function(Duration)? sleep,
  DateTime Function() now = DateTime.now,
}) async {
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  final deadline = now().add(timeout);
  while (true) {
    ViewerCloseResult result;
    try {
      result = await tryClose();
    } catch (_) {
      result = ViewerCloseResult.unconfirmed;
    }
    if (result.confirmed) return true;
    if (!now().isBefore(deadline)) return false;
    await wait(interval);
  }
}
