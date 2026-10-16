//! Content-free wakeups. Waiting never takes the command or account locks.
use std::sync::{Condvar, Mutex};
use std::time::Duration;

#[derive(Default)]
struct Events {
    sequence: Mutex<u64>,
    changed: Condvar,
}

impl Events {
    fn notify(&self) {
        let mut sequence = self
            .sequence
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        *sequence = sequence.wrapping_add(1);
        self.changed.notify_all();
    }

    fn wait(&self, after: u64, timeout: Duration) -> u64 {
        let sequence = self
            .sequence
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let (sequence, _) = self
            .changed
            .wait_timeout_while(sequence, timeout, |value| *value == after)
            .unwrap_or_else(|error| error.into_inner());
        *sequence
    }
}

static EVENTS: Events = Events {
    sequence: Mutex::new(0),
    changed: Condvar::new(),
};

pub(crate) fn notify() {
    EVENTS.notify();
}

pub(crate) fn wait(after: u64, timeout_ms: u64) -> u64 {
    EVENTS.wait(after, Duration::from_millis(timeout_ms.min(30_000)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wakes_every_waiter_and_preserves_events_before_waiting() {
        let events = std::sync::Arc::new(Events::default());
        let workers: Vec<_> = (0..2)
            .map(|_| {
                let events = events.clone();
                std::thread::spawn(move || events.wait(0, Duration::from_secs(2)))
            })
            .collect();
        events.notify();
        for worker in workers {
            assert_eq!(worker.join().unwrap(), 1);
        }
        events.notify();
        assert_eq!(events.wait(0, Duration::ZERO), 2);
        assert_eq!(events.wait(2, Duration::ZERO), 2);
    }
}
