//! Event-driven mailbox reads, with four polled futures owned by the node task.
//! Dropping the task synchronously drops all mailbox capabilities in flight.
use super::*;
use futures_util::{StreamExt, future::BoxFuture, stream::FuturesUnordered};
use std::{
    collections::{HashSet, VecDeque},
    sync::{
        Weak,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use veilid_core::RecordKey;

type Id = [u8; 32];
const CONCURRENCY: usize = 4;
const MAX_WATCHES: usize = 64;
const BACKSTOP: Duration = Duration::from_secs(10);
const RENEW: Duration = Duration::from_secs(45);

struct Watch {
    id: Id,
    renewed: Instant,
    active: bool,
}
#[derive(Default)]
struct Inner {
    targets: HashSet<Id>,
    allowed: HashSet<Id>,
    records: HashMap<RecordKey, Watch>,
    dirty: HashSet<Id>,
}
#[derive(Default)]
pub(super) struct State {
    inner: Mutex<Inner>,
    revision: AtomicU64,
    wake: tokio::sync::Notify,
    runtime: Mutex<Option<tokio::runtime::Handle>>,
}
static CURRENT: OnceLock<Mutex<Weak<State>>> = OnceLock::new();
impl State {
    pub fn install() -> Arc<Self> {
        let state = Arc::new(Self::default());
        if let Ok(mut runtime) = state.runtime.lock() {
            *runtime = tokio::runtime::Handle::try_current().ok();
        }
        if let Ok(mut current) = CURRENT.get_or_init(|| Mutex::new(Weak::new())).lock() {
            *current = Arc::downgrade(&state);
        }
        state
    }
    pub async fn close_all(&self, api: &veilid_core::VeilidAPI) -> CoreResult<()> {
        let removed = {
            let mut inner = self.inner.lock().map_err(|_| CoreError::Internal)?;
            inner.targets.clear();
            inner.allowed.clear();
            inner.dirty.clear();
            std::mem::take(&mut inner.records)
        };
        self.revision.fetch_add(1, Ordering::Release);
        futures_util::stream::iter(removed)
            .for_each_concurrent(Some(CONCURRENCY), |(key, watch)| {
                let api = api.clone();
                async move {
                    if let Ok(lock) = offline_record_lock(watch.id) {
                        let _guard = lock.lock().await;
                        if let Ok(routing) = api.routing_context() {
                            let _ = routing.cancel_dht_watch(key.clone(), None).await;
                            let _ = routing.close_dht_record(key).await;
                        }
                    }
                }
            })
            .await;
        Ok(())
    }
    pub fn changed(&self, key: &RecordKey, expired: bool) {
        if let Ok(mut inner) = self.inner.lock() {
            if expired {
                if let Some(watch) = inner.records.get_mut(key) {
                    watch.active = false;
                }
            }
            if let Some(id) = inner.records.get(key).map(|watch| watch.id) {
                inner.dirty.insert(id);
                self.wake.notify_one();
            }
        }
    }
    pub fn targets(self: &Arc<Self>, api: &veilid_core::VeilidAPI, ids: impl Iterator<Item = Id>) {
        let ids: Vec<_> = ids.collect();
        let allowed: HashSet<_> = ids.iter().take(MAX_WATCHES).copied().collect();
        let targets: HashSet<_> = ids.into_iter().collect();
        let removed = {
            let Ok(mut inner) = self.inner.lock() else {
                return;
            };
            if inner.targets == targets && inner.allowed == allowed {
                return;
            }
            let removed: Vec<_> = inner
                .records
                .iter()
                .filter(|(_, watch)| !allowed.contains(&watch.id))
                .map(|(key, watch)| (key.clone(), watch.id))
                .collect();
            for (key, _) in &removed {
                inner.records.remove(key);
            }
            inner.dirty.retain(|id| targets.contains(id));
            inner.targets = targets;
            inner.allowed = allowed;
            removed
        };
        for (key, id) in removed {
            cleanup(api.clone(), key, id, Arc::downgrade(self), true);
        }
        self.revision.fetch_add(1, Ordering::Release);
        self.wake.notify_one();
    }
    fn watched(&self, key: &RecordKey) -> bool {
        self.inner
            .lock()
            .is_ok_and(|inner| inner.records.get(key).is_some_and(|watch| watch.active))
    }
    pub fn contains(&self, id: &Id) -> bool {
        self.inner
            .lock()
            .is_ok_and(|inner| inner.targets.contains(id))
    }
    pub async fn watch(&self, routing: &veilid_core::RoutingContext, key: &RecordKey, id: Id) {
        let renew = {
            let Ok(mut inner) = self.inner.lock() else {
                return;
            };
            if !inner.allowed.contains(&id) {
                return;
            }
            if inner
                .records
                .get(key)
                .is_some_and(|watch| watch.active && watch.renewed.elapsed() < RENEW)
            {
                false
            } else {
                inner.records.insert(
                    key.clone(),
                    Watch {
                        id,
                        renewed: Instant::now(),
                        active: false,
                    },
                );
                true
            }
        };
        if !renew {
            return;
        }
        let active = routing
            .watch_dht_values(key.clone(), None, None, None)
            .await
            .unwrap_or(false);
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(watch) = inner.records.get_mut(key) {
                watch.active = active;
            }
        }
    }
    fn dirty(&self) -> HashSet<Id> {
        self.inner
            .lock()
            .map(|mut inner| std::mem::take(&mut inner.dirty))
            .unwrap_or_default()
    }
}

fn current() -> Weak<State> {
    CURRENT
        .get()
        .and_then(|current| current.lock().ok().map(|weak| weak.clone()))
        .unwrap_or_default()
}
fn cleanup(api: veilid_core::VeilidAPI, key: RecordKey, id: Id, state: Weak<State>, cancel: bool) {
    let runtime = tokio::runtime::Handle::try_current().ok().or_else(|| {
        state.upgrade().and_then(|state| {
            state
                .runtime
                .lock()
                .ok()
                .and_then(|runtime| runtime.clone())
        })
    });
    let Some(runtime) = runtime else {
        return;
    };
    runtime.spawn(async move {
        let Ok(lock) = offline_record_lock(id) else {
            return;
        };
        let _guard = lock.lock().await;
        if state.upgrade().is_some_and(|state| state.watched(&key)) {
            return;
        }
        if let Ok(routing) = api.routing_context() {
            if cancel {
                let _ = routing.cancel_dht_watch(key.clone(), None).await;
            }
            let _ = routing.close_dht_record(key).await;
        }
    });
}

// Future cancellation (including a successful hedged direct delivery) must
// close un-watched DHT handles, while live watches keep their records open.
pub(super) struct Lease {
    api: veilid_core::VeilidAPI,
    key: RecordKey,
    id: Id,
    state: Weak<State>,
    finished: bool,
}
impl Lease {
    pub fn new(api: &veilid_core::VeilidAPI, key: &RecordKey, id: Id) -> Self {
        Self {
            api: api.clone(),
            key: key.clone(),
            id,
            state: current(),
            finished: false,
        }
    }
    pub async fn finish(&mut self) {
        if !self
            .state
            .upgrade()
            .is_some_and(|state| state.watched(&self.key))
        {
            if let Ok(routing) = self.api.routing_context() {
                let _ = routing.close_dht_record(self.key.clone()).await;
            }
        }
        self.finished = true;
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if !self.finished {
            cleanup(
                self.api.clone(),
                self.key.clone(),
                self.id,
                self.state.clone(),
                false,
            );
        }
    }
}

#[derive(Default)]
struct Schedule {
    pending: VecDeque<Id>,
    queued: HashSet<Id>,
    running: HashSet<Id>,
    again: HashSet<Id>,
    urgent: HashSet<Id>,
    priority_streak: usize,
}
impl Schedule {
    fn enqueue(&mut self, id: Id, priority: bool) {
        if self.running.contains(&id) {
            if priority {
                self.again.insert(id);
            }
            return;
        }
        if !self.queued.insert(id) {
            if !priority {
                return;
            }
            self.pending.retain(|queued| queued != &id);
        }
        if priority {
            self.urgent.insert(id);
        }
        if priority {
            self.pending.push_front(id);
        } else {
            self.pending.push_back(id);
        }
    }
    fn next(&mut self) -> Option<Id> {
        if self.running.len() >= CONCURRENCY {
            return None;
        }
        let normal = (self.priority_streak >= CONCURRENCY)
            .then(|| self.pending.iter().position(|id| !self.urgent.contains(id)))
            .flatten();
        let id = match normal {
            Some(index) => self.pending.remove(index)?,
            None => self.pending.pop_front()?,
        };
        if self.urgent.remove(&id) {
            self.priority_streak = self.priority_streak.saturating_add(1);
        } else {
            self.priority_streak = 0;
        }
        self.queued.remove(&id);
        self.running.insert(id);
        Some(id)
    }
    fn done(&mut self, id: Id) {
        self.running.remove(&id);
        if self.again.remove(&id) {
            self.enqueue(id, true);
        }
    }
    fn retain(&mut self, valid: &HashSet<Id>) {
        self.pending.retain(|id| valid.contains(id));
        self.queued.retain(|id| valid.contains(id));
        self.again.retain(|id| valid.contains(id));
        self.urgent.retain(|id| valid.contains(id));
    }
}

pub(super) async fn poll(
    api: veilid_core::VeilidAPI,
    inbox: Arc<Mutex<VecDeque<InboundPayload>>>,
    targets: Arc<Mutex<Vec<crate::offline_mailbox::MailboxKeys>>>,
    seen: Arc<Mutex<HashMap<Id, bool>>>,
    state: Arc<State>,
) {
    if let Ok(mut runtime) = state.runtime.lock() {
        *runtime = Some(tokio::runtime::Handle::current());
    }
    let mut jobs: FuturesUnordered<BoxFuture<'static, Id>> = FuturesUnordered::new();
    let mut schedule = Schedule::default();
    let mut revision = u64::MAX;
    let mut keys = HashMap::new();
    let mut next_full = tokio::time::Instant::now();
    loop {
        if revision != state.revision.load(Ordering::Acquire) {
            revision = state.revision.load(Ordering::Acquire);
            keys = targets
                .lock()
                .map(|targets| {
                    targets
                        .iter()
                        .map(|keys| (keys.id(), keys.clone()))
                        .collect()
                })
                .unwrap_or_default();
            let valid = keys.keys().copied().collect();
            schedule.retain(&valid);
            for id in keys.keys() {
                schedule.enqueue(*id, false);
            }
        }
        if !network_available() {
            jobs.clear();
            schedule = Schedule::default();
            tokio::select! {
                _ = NETWORK_WAKE.notified() => {},
                _ = state.wake.notified() => {},
                _ = tokio::time::sleep(Duration::from_secs(60)) => {},
            }
            next_full = tokio::time::Instant::now();
            continue;
        }
        if tokio::time::Instant::now() >= next_full {
            for id in keys.keys() {
                schedule.enqueue(*id, false);
            }
            next_full = tokio::time::Instant::now() + BACKSTOP;
        }
        for id in state.dirty() {
            if keys.contains_key(&id) {
                schedule.enqueue(id, true);
            }
        }
        while let Some(id) = schedule.next() {
            let Some(keys) = keys.get(&id).cloned() else {
                schedule.done(id);
                continue;
            };
            let (api, inbox, seen, state) =
                (api.clone(), inbox.clone(), seen.clone(), state.clone());
            jobs.push(Box::pin(async move {
                let timer =
                    crate::performance::Timer::start(crate::performance::Stage::MailboxPoll);
                let result = tokio::time::timeout(
                    Duration::from_secs(20),
                    poll_offline_mailbox_once(&api, &inbox, &seen, &keys, &state),
                )
                .await
                .unwrap_or(Err(CoreError::NetworkAttachFailed));
                timer.finish(result.is_ok());
                id
            }));
        }
        tokio::select! {
            Some(id) = jobs.next(), if !jobs.is_empty() => { schedule.done(id); },
            _ = state.wake.notified() => {},
            _ = NETWORK_WAKE.notified() => { next_full = tokio::time::Instant::now(); },
            _ = tokio::time::sleep_until(next_full) => {},
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn continuous_events_do_not_starve_periodic_reads() {
        let mut schedule = Schedule::default();
        schedule.enqueue([99; 32], false);
        for index in 0..16 {
            schedule.enqueue([index; 32], true);
        }
        let mut selected = Vec::new();
        for _ in 0..=CONCURRENCY {
            let id = schedule.next().unwrap();
            selected.push(id);
            schedule.done(id);
        }
        assert!(selected.contains(&[99; 32]));
    }
    #[test]
    fn events_take_priority_with_bounded_parallelism_and_changes_in_flight_are_rechecked() {
        let mut schedule = Schedule::default();
        for i in 0..12 {
            schedule.enqueue([i; 32], false);
        }
        let first: Vec<_> = (0..CONCURRENCY).map(|_| schedule.next().unwrap()).collect();
        assert!(schedule.next().is_none());
        schedule.enqueue(first[0], true);
        schedule.enqueue([11; 32], true);
        schedule.done(first[0]);
        assert_eq!(schedule.next(), Some(first[0]));
        schedule.done(first[1]);
        assert_eq!(schedule.next(), Some([11; 32]));
        assert_eq!(schedule.running.len(), CONCURRENCY);
        schedule.retain(&HashSet::new());
        schedule.done(first[2]);
        assert!(schedule.next().is_none());
    }
}
