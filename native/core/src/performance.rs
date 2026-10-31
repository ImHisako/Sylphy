//! Bounded, process-local timings. No message, account, route or content identifiers.
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

const SAMPLES: usize = 128;

#[derive(Clone, Copy)]
pub(crate) enum Stage {
    CommandWait,
    TextPrepare,
    Upload,
    Direct,
    Offline,
    InboundPersist,
    MailboxPoll,
}
impl Stage {
    const ALL: [Self; 7] = [
        Self::CommandWait,
        Self::TextPrepare,
        Self::Upload,
        Self::Direct,
        Self::Offline,
        Self::InboundPersist,
        Self::MailboxPoll,
    ];
    fn name(self) -> &'static str {
        match self {
            Self::CommandWait => "command_wait",
            Self::TextPrepare => "text_prepare",
            Self::Upload => "upload",
            Self::Direct => "direct",
            Self::Offline => "offline",
            Self::InboundPersist => "inbound_persist",
            Self::MailboxPoll => "mailbox_poll",
        }
    }
}

#[derive(Default)]
struct Samples {
    total: u64,
    values: VecDeque<(u64, bool)>,
}
impl Samples {
    fn record(&mut self, elapsed: Duration, success: bool) {
        self.total = self.total.saturating_add(1);
        if self.values.len() == SAMPLES {
            self.values.pop_front();
        }
        self.values.push_back((
            elapsed.as_micros().min(u128::from(u64::MAX)) as u64,
            success,
        ));
    }
    fn sorted(&self, successful_only: bool) -> Vec<u64> {
        let mut values: Vec<_> = self
            .values
            .iter()
            .filter(|(_, success)| !successful_only || *success)
            .map(|(us, _)| *us)
            .collect();
        values.sort_unstable();
        values
    }
    fn json(&self) -> Value {
        let values = self.sorted(false);
        let ms = |value: u64| value as f64 / 1000.0;
        json!({"total": self.total, "sampled": values.len(),
            "successful": self.values.iter().filter(|(_, ok)| *ok).count(),
            "unsuccessful": self.values.iter().filter(|(_, ok)| !*ok).count(),
            "min_ms": values.first().copied().map(ms),
            "p50_ms": percentile(&values, 50).map(ms),
            "p95_ms": percentile(&values, 95).map(ms),
            "max_ms": values.last().copied().map(ms)})
    }
}
fn percentile(values: &[u64], percent: usize) -> Option<u64> {
    values
        .get((values.len() * percent).div_ceil(100).saturating_sub(1))
        .copied()
}

#[derive(Default)]
struct Metrics {
    stages: [Samples; 7],
    offline_fallbacks: u64,
    epoch: u64,
}
impl Metrics {
    fn reset(&mut self) {
        *self = Self {
            epoch: self.epoch.wrapping_add(1),
            ..Self::default()
        };
    }
    fn record(&mut self, stage: Stage, elapsed: Duration, success: bool, epoch: u64) {
        if epoch == self.epoch {
            self.stages[stage as usize].record(elapsed, success);
        }
    }
}
static METRICS: OnceLock<Mutex<Metrics>> = OnceLock::new();
fn metrics() -> &'static Mutex<Metrics> {
    METRICS.get_or_init(|| Mutex::new(Metrics::default()))
}

pub(crate) fn epoch() -> u64 {
    metrics().lock().map(|metrics| metrics.epoch).unwrap_or(0)
}
pub(crate) struct Timer {
    stage: Stage,
    started: Instant,
    epoch: u64,
}
impl Timer {
    pub(crate) fn start(stage: Stage) -> Self {
        Self::start_in(stage, epoch())
    }
    pub(crate) fn start_in(stage: Stage, epoch: u64) -> Self {
        Self {
            stage,
            started: Instant::now(),
            epoch,
        }
    }
    pub(crate) fn finish(self, success: bool) {
        if let Ok(mut metrics) = metrics().lock() {
            metrics.record(self.stage, self.started.elapsed(), success, self.epoch);
        }
    }
}
pub(crate) fn fallback_started(epoch: u64) {
    if let Ok(mut metrics) = metrics().lock() {
        if metrics.epoch == epoch {
            metrics.offline_fallbacks = metrics.offline_fallbacks.saturating_add(1);
        }
    }
}
// Learn from completed successful direct calls; an initial network stall cannot
// increase the grace indefinitely. Cancellation and failures are not RTT samples.
pub(crate) fn fallback_grace() -> Duration {
    let Ok(metrics) = metrics().lock() else {
        return Duration::from_secs(2);
    };
    grace(&metrics.stages[Stage::Direct as usize])
}
fn grace(samples: &Samples) -> Duration {
    let values = samples.sorted(true);
    if values.len() < 8 {
        return Duration::from_secs(2);
    }
    let us = percentile(&values, 95)
        .unwrap_or(1_000_000)
        .saturating_mul(2)
        .saturating_add(250_000)
        .clamp(750_000, 4_000_000);
    Duration::from_micros(us)
}
pub(crate) fn snapshot(reset: bool) -> Value {
    let Ok(mut metrics) = metrics().lock() else {
        return json!({"version": 1, "stages": {}});
    };
    let stages: serde_json::Map<_, _> = Stage::ALL
        .into_iter()
        .map(|stage| {
            (
                stage.name().to_owned(),
                metrics.stages[stage as usize].json(),
            )
        })
        .collect();
    let result = json!({"version": 1, "clock": "process_monotonic", "sample_capacity": SAMPLES,
        "offline_fallbacks": metrics.offline_fallbacks, "fallback_grace_ms": grace(&metrics.stages[Stage::Direct as usize]).as_millis(),
        "stages": stages});
    if reset {
        metrics.reset();
    }
    result
}
pub(crate) fn clear() {
    let _ = snapshot(true);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completions_from_a_previous_measurement_or_account_do_not_repopulate_reset_metrics() {
        let mut metrics = Metrics::default();
        let old = metrics.epoch;
        metrics.reset();
        metrics.record(Stage::Upload, Duration::from_secs(1), true, old);
        assert_eq!(metrics.stages[Stage::Upload as usize].total, 0);
        metrics.record(Stage::Upload, Duration::from_secs(1), true, metrics.epoch);
        assert_eq!(metrics.stages[Stage::Upload as usize].total, 1);
    }
    #[test]
    fn samples_are_bounded_and_failures_do_not_train_the_direct_grace() {
        let mut samples = Samples::default();
        assert_eq!(grace(&samples), Duration::from_secs(2));
        for _ in 0..200 {
            samples.record(Duration::from_millis(100), true);
        }
        assert_eq!(samples.values.len(), SAMPLES);
        assert_eq!(samples.json()["total"], 200);
        assert_eq!(samples.json()["p95_ms"], 100.0);
        for _ in 0..20 {
            samples.record(Duration::from_secs(12), false);
        }
        assert_eq!(grace(&samples), Duration::from_millis(750));
        for _ in 0..SAMPLES {
            samples.record(Duration::from_secs(12), true);
        }
        assert_eq!(grace(&samples), Duration::from_secs(4));
        assert_eq!(Samples::default().json()["p50_ms"], Value::Null);
    }
}
