//! A pending fanout or retry backlog must not monopolize the bounded workers.
use super::*;

const MAX_PER_MESSAGE: usize = 2;
const MAX_PER_DESTINATION: usize = MAX_OUTBOX_IN_FLIGHT - 1;
const FRESH_BURST: usize = 3;

#[derive(Clone, Copy, Default)]
pub(super) struct Schedule {
    fresh_streak: usize,
}

impl Schedule {
    pub(super) fn dispatched(&mut self, fresh: bool) {
        self.fresh_streak = if fresh {
            self.fresh_streak.saturating_add(1).min(FRESH_BURST)
        } else {
            0
        };
    }
}

fn destination(item: &PendingDelivery) -> [u8; 32] {
    if let Some(keys) = &item.offline_keys {
        keys.id()
    } else {
        let mut hash = Sha256::new();
        hash.update(b"sylphy/outbox-destination/v1");
        hash.update(&item.route_blob);
        hash.finalize().into()
    }
}

pub(super) fn select(
    store: &ContactStore,
    active: &HashSet<String>,
    capacity: usize,
    now: u64,
    only_message_id: Option<&str>,
    mut schedule: Schedule,
) -> Vec<PendingDelivery> {
    let mut messages = HashMap::<&str, usize>::new();
    let mut destinations = HashMap::<[u8; 32], usize>::new();
    for item in &store.outbox {
        if active.contains(&item.id) {
            *messages.entry(&item.message_id).or_default() += 1;
            *destinations.entry(destination(item)).or_default() += 1;
        }
    }
    // Queue references only; copy durable ciphertext for the selected workers.
    let mut fresh = Vec::new();
    let mut retries = Vec::new();
    for item in dispatchable_outbox(store).filter(|item| {
        item.next_attempt_ms <= now
            && !active.contains(&item.id)
            && only_message_id.is_none_or(|id| item.message_id == id)
    }) {
        if item.attempts == 0 {
            fresh.push(item);
        } else {
            retries.push(item);
        }
    }
    // Oldest due retry first; newly failed entries cannot jump ahead of it.
    retries.sort_by_key(|item| item.next_attempt_ms);
    let mut selected = Vec::new();
    while selected.len() < capacity.min(MAX_OUTBOX_IN_FLIGHT) {
        let allowed = |item: &&PendingDelivery| {
            messages.get(item.message_id.as_str()).copied().unwrap_or(0) < MAX_PER_MESSAGE
                && destinations.get(&destination(item)).copied().unwrap_or(0) < MAX_PER_DESTINATION
        };
        let next_fresh = fresh.iter().position(allowed);
        let next_retry = retries.iter().position(allowed);
        let (queue, index) = match (next_fresh, next_retry) {
            (Some(index), Some(_)) if schedule.fresh_streak < FRESH_BURST => (&mut fresh, index),
            (_, Some(index)) => (&mut retries, index),
            (Some(index), None) => (&mut fresh, index),
            (None, None) => break,
        };
        let item = queue.remove(index);
        *messages.entry(&item.message_id).or_default() += 1;
        *destinations.entry(destination(item)).or_default() += 1;
        schedule.dispatched(item.attempts == 0);
        selected.push(item.clone());
    }
    selected
}
