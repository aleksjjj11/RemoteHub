import '../errors.dart';
import 'reconnect_policy.dart';

/// Drives the upstream viewer's automatic "Reconnect" countdown with the
/// Remote Hub policy: 1, 2, 4, 8, 15 s, then ~15 s, within 90 s of the first
/// failure, and only for network failures. Every retry is a new session, so no
/// key, click or paste is replayed (plan 10.3).
class ReconnectWindow {
  ReconnectWindow({ReconnectPolicy? policy, DateTime Function()? now})
      : _policy = policy ?? ReconnectPolicy(),
        _now = now ?? DateTime.now;

  final ReconnectPolicy _policy;
  final DateTime Function() _now;
  int _attempt = 0;
  DateTime? _start;

  /// Delay for a message box the engine marked as retryable ([hasRetry]) or
  /// not. A final (non-retryable) message ends the attempt, so a later manual
  /// retry starts a fresh window.
  int? delayForMessage(String errorText, {required bool hasRetry}) {
    if (!hasRetry) {
      reset();
      return null;
    }
    return nextDelaySeconds(errorText);
  }

  /// Whole seconds until the next retry after [errorText], or null to stop.
  int? nextDelaySeconds(String errorText) {
    final start = _start ??= _now();
    final delay = _policy.nextDelay(
      attempt: _attempt,
      elapsed: _now().difference(start),
      lastError: retryErrorOf(errorText),
    );
    if (delay == null) {
      reset();
      return null;
    }
    _attempt++;
    final seconds = (delay.inMilliseconds / 1000).ceil();
    return seconds < 1 ? 1 : seconds;
  }

  /// Called once the session shows a picture again.
  void reset() {
    _attempt = 0;
    _start = null;
  }
}

/// "CODE: detail" maps to its code; an engine transport error without a
/// Remote Hub code (reset, timeout) counts as a lost connection.
RemoteHubErrorCode retryErrorOf(String text) {
  final match = RegExp(r'^([A-Z_]+):').firstMatch(text.trim());
  if (match == null) return RemoteHubErrorCode.connectionLost;
  final code = match.group(1)!;
  final known = RemoteHubErrorCode.values.any((e) => e.code == code);
  return known
      ? RemoteHubErrorCode.fromCode(code)
      : RemoteHubErrorCode.connectionLost;
}
