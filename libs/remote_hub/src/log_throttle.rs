//! At most one log line per interval for sites whose rate someone else sets
//! (the engine opening sockets, a host refusing channels). Same behaviour as
//! `hbb_common::log_throttle`, which this standalone crate does not depend on:
//! an isolated event logs at once, a burst collapses to one line with a count.

use std::sync::Mutex;
use std::time::{Duration, Instant};

pub(crate) struct LogThrottle {
    interval: Duration,
    state: Mutex<(u64, Option<Instant>)>,
}

impl LogThrottle {
    pub(crate) const fn new(interval: Duration) -> Self {
        Self {
            interval,
            state: Mutex::new((0, None)),
        }
    }

    /// Records one occurrence. `Some(n)` when a line is due, `n` counting this
    /// occurrence and every one suppressed since the last line.
    pub(crate) fn due(&self) -> Option<u64> {
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        state.0 += 1;
        if state.1.is_some_and(|last| last.elapsed() < self.interval) {
            return None;
        }
        state.1 = Some(Instant::now());
        Some(std::mem::replace(&mut state.0, 0))
    }
}

/// `throttled_log!(level, "...", args)`: one line per minute from this call
/// site, suffixed with ` (xN)` when it stands for more than one event.
macro_rules! throttled_log {
    ($level:ident, $($arg:tt)+) => {{
        static THROTTLE: $crate::log_throttle::LogThrottle =
            $crate::log_throttle::LogThrottle::new(::std::time::Duration::from_secs(60));
        if let Some(n) = THROTTLE.due() {
            if n > 1 {
                ::log::$level!("{} (x{})", format_args!($($arg)+), n);
            } else {
                ::log::$level!("{}", format_args!($($arg)+));
            }
        }
    }};
}
pub(crate) use throttled_log;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_burst_writes_one_line_with_its_count() {
        let t = LogThrottle::new(Duration::from_secs(60));
        assert_eq!(t.due(), Some(1));
        for _ in 0..1_000 {
            assert_eq!(t.due(), None);
        }
        let quiet = LogThrottle::new(Duration::ZERO);
        assert_eq!(quiet.due(), Some(1));
        assert_eq!(quiet.due(), Some(1));
    }
}
