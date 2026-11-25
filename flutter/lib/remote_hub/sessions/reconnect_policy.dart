import 'dart:math';

import '../errors.dart';

/// Reconnect backoff from plan 10.3: 1, 2, 4, 8, 15 s, then 15 s with ±20%
/// jitter, never past a 90 s total window. Only network failures retry.
class ReconnectPolicy {
  ReconnectPolicy({Random? random, this.window = const Duration(seconds: 90)})
      : _random = random ?? Random.secure();

  static const List<Duration> initialDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];
  static const Duration steadyDelay = Duration(seconds: 15);
  static const double jitter = 0.2;

  final Duration window;
  final Random _random;

  /// Delay before retry number [attempt] (0-based), or null to stop.
  /// [elapsed] is the time since the connection was interrupted.
  Duration? nextDelay({
    required int attempt,
    required Duration elapsed,
    required RemoteHubErrorCode lastError,
  }) {
    if (!lastError.isRetryable || attempt < 0) return null;
    final remaining = window - elapsed;
    if (remaining <= Duration.zero) return null;
    final Duration delay;
    if (attempt < initialDelays.length) {
      delay = initialDelays[attempt];
    } else {
      final factor = 1 - jitter + _random.nextDouble() * 2 * jitter;
      delay =
          Duration(milliseconds: (steadyDelay.inMilliseconds * factor).round());
    }
    return delay < remaining ? delay : remaining;
  }
}
