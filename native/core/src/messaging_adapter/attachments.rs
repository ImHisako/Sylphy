//! Explicit, bounded file retrieval. The network worker never accesses account
//! state or the FFI command lock; results are committed by the local command thread.
use super::*;
use std::{
    collections::VecDeque,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, TryRecvError},
    },
};

#[derive(Clone)]
struct Job {
    generation: u64,
    id: String,
    conversation: String,
    author: String,
    pointer: AttachmentPointer,
    cancelled: Arc<AtomicBool>,
}

struct Active {
    job: Job,
    receiver: Receiver<CoreResult<String>>,
}

#[derive(Default)]
struct Transfers {
    queue: VecDeque<Job>,
    active: Option<Active>,
    failed: VecDeque<(u64, String)>,
}

static TRANSFERS: OnceLock<Mutex<Transfers>> = OnceLock::new();
fn transfers() -> &'static Mutex<Transfers> {
    TRANSFERS.get_or_init(|| Mutex::new(Transfers::default()))
}

impl Transfers {
    fn enqueue(&mut self, job: Job) -> CoreResult<()> {
        let jobs = self.queue.iter().chain(self.active.iter().map(|a| &a.job));
        if jobs.clone().any(|j| {
            j.generation == job.generation && j.id == job.id && !j.cancelled.load(Ordering::Relaxed)
        }) {
            return Ok(());
        }
        // Four explicit requests globally and one per sender. A cancelled worker
        // continues occupying its slot until it exits, including account switches.
        if jobs.clone().count() >= 4
            || jobs
                .clone()
                .any(|j| j.generation == job.generation && j.author == job.author)
        {
            return Err(CoreError::LimitExceeded);
        }
        self.failed
            .retain(|(generation, id)| *generation != job.generation || *id != job.id);
        self.queue.push_back(job);
        Ok(())
    }

    fn start_with(&mut self, fetch: impl FnOnce(&Job) -> CoreResult<String> + Send + 'static) {
        if self.active.is_some() {
            return;
        }
        let Some(job) = self.queue.pop_front() else {
            return;
        };
        let worker_job = job.clone();
        let (sender, receiver) = mpsc::channel();
        // A dropped sender is treated as a failed download, including spawn/panic.
        let _ = std::thread::Builder::new()
            .name("sylphy-attachment".to_owned())
            .spawn(move || {
                let result = if worker_job.cancelled.load(Ordering::Relaxed) {
                    Err(CoreError::FeatureUnavailable)
                } else {
                    fetch(&worker_job)
                };
                let _ = sender.send(result);
            });
        self.active = Some(Active { job, receiver });
    }

    fn take_result(&mut self) -> Option<(Job, CoreResult<String>)> {
        let active = self.active.as_ref()?;
        let result = match active.receiver.try_recv() {
            Ok(result) => result,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => Err(CoreError::NetworkAttachFailed),
        };
        Some((self.active.take()?.job, result))
    }

    fn fail(&mut self, job: &Job) {
        self.failed.push_back((job.generation, job.id.clone()));
        while self.failed.len() > 32 {
            self.failed.pop_front();
        }
    }

    fn cancel(&mut self, generation: u64, id: &str) {
        self.queue
            .retain(|job| job.generation != generation || job.id != id);
        if let Some(active) = &self.active {
            if active.job.generation == generation && active.job.id == id {
                active.job.cancelled.store(true, Ordering::Relaxed);
            }
        }
        self.failed.retain(|(g, i)| *g != generation || i != id);
    }
}

fn start(transfers: &mut Transfers) {
    transfers.start_with(|job| {
        decrypt_attachment(&job.pointer, |key, count| {
            veilid_adapter::fetch_attachment_blob_cancellable(key, count, &job.cancelled)
        })
    });
}

pub(super) fn reset() {
    if let Ok(mut transfers) = transfers().lock() {
        transfers.queue.clear();
        transfers.failed.clear();
        if let Some(active) = &transfers.active {
            active.job.cancelled.store(true, Ordering::Relaxed);
        }
    }
}

pub(super) fn status(generation: u64, id: &str) -> &'static str {
    let Ok(transfers) = transfers().lock() else {
        return "pending";
    };
    if transfers.active.as_ref().is_some_and(|a| {
        a.job.generation == generation && a.job.id == id && !a.job.cancelled.load(Ordering::Relaxed)
    }) {
        return "downloading";
    }
    if transfers
        .queue
        .iter()
        .any(|j| j.generation == generation && j.id == id)
    {
        return "queued";
    }
    if transfers
        .failed
        .iter()
        .any(|(g, i)| *g == generation && i == id)
    {
        return "failed";
    }
    "pending"
}

pub fn request(conversation_id: &str, message_id: &str, cancel: bool) -> CoreResult<Value> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let message = store
        .messages
        .iter()
        .find(|m| m.id == message_id && m.conversation_id == conversation_id)
        .ok_or(CoreError::InvalidInput)?;
    if message.attachment_base64.is_some() {
        return Ok(json!({"state": "ready"}));
    }
    let pointer = message
        .attachment_pointer
        .clone()
        .ok_or(CoreError::InvalidInput)?;
    validate_attachment_pointer(&pointer)?;
    let mut transfers = transfers().lock().map_err(|_| CoreError::Internal)?;
    if cancel {
        transfers.cancel(store.generation, message_id);
    } else {
        transfers.enqueue(Job {
            generation: store.generation,
            id: message_id.to_owned(),
            conversation: conversation_id.to_owned(),
            author: message.author_id.clone(),
            pointer,
            cancelled: Arc::new(AtomicBool::new(false)),
        })?;
        start(&mut transfers);
    }
    store.revision = store.revision.wrapping_add(1);
    Ok(json!({"state": if cancel { "pending" } else { "queued" }}))
}

pub(super) fn poll() -> CoreResult<()> {
    let completed = transfers()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .take_result();
    if let Some((job, result)) = completed {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        // Never resurrect a deleted message or commit a previous account's result.
        if store.generation == job.generation && !job.cancelled.load(Ordering::Relaxed) {
            if let Some(index) = store.messages.iter().position(|m| {
                m.id == job.id
                    && m.conversation_id == job.conversation
                    && m.attachment_pointer.as_ref() == Some(&job.pointer)
                    && m.attachment_base64.is_none()
            }) {
                let persisted = (|| {
                    let bytes = result?;
                    let mut message = store.messages[index].clone();
                    message.attachment_base64 = Some(bytes);
                    validate_stored_message(&message)?;
                    let path = store
                        .message_path
                        .as_ref()
                        .ok_or(CoreError::FeatureUnavailable)?;
                    append_message_event(
                        path,
                        &MessageEvent::Upsert {
                            message: message.clone(),
                        },
                    )?;
                    store.messages[index] = message;
                    store.message_event_count += 1;
                    Ok::<(), CoreError>(())
                })();
                if persisted.is_err() {
                    transfers()
                        .lock()
                        .map_err(|_| CoreError::Internal)?
                        .fail(&job);
                }
                store.revision = store.revision.wrapping_add(1);
            }
        }
    }
    // Exclude deleted or replaced queued references before starting any I/O.
    let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let mut transfers = self::transfers().lock().map_err(|_| CoreError::Internal)?;
    if let Some(active) = &transfers.active {
        if active.job.generation != store.generation
            || !store
                .messages
                .iter()
                .any(|m| m.id == active.job.id && m.conversation_id == active.job.conversation)
        {
            active.job.cancelled.store(true, Ordering::Relaxed);
        }
    }
    transfers.queue.retain(|j| {
        j.generation == store.generation
            && store.messages.iter().any(|m| {
                m.id == j.id
                    && m.conversation_id == j.conversation
                    && m.attachment_pointer.as_ref() == Some(&j.pointer)
                    && m.attachment_base64.is_none()
            })
    });
    let was_idle = transfers.active.is_none();
    start(&mut transfers);
    let started = was_idle && transfers.active.is_some();
    drop(transfers);
    drop(store);
    if started {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        store.revision = store.revision.wrapping_add(1);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn job(id: &str, author: &str) -> Job {
        Job {
            generation: 1,
            id: id.to_owned(),
            conversation: "chat".to_owned(),
            author: author.to_owned(),
            pointer: AttachmentPointer {
                version: 1,
                file_name: "file.bin".to_owned(),
                size: 3,
                record_key: "record".to_owned(),
                chunk_count: 1,
                key_base64: STANDARD_NO_PAD.encode([7; 32]),
                nonce_base64: STANDARD_NO_PAD.encode([8; 24]),
                channel_id: None,
            },
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }

    #[test]
    fn slow_download_is_nonblocking_bounded_and_cancellable() {
        let _commands = crate::ffi::COMMAND_LOCK.lock().unwrap();
        let mut transfers = Transfers::default();
        transfers.enqueue(job("one", "sender-1")).unwrap();
        let (release, wait) = mpsc::channel();
        let (entered, started) = mpsc::channel();
        transfers.start_with(move |_| {
            entered.send(()).unwrap();
            wait.recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            Ok(STANDARD.encode([1, 2, 3]))
        });
        // The worker starts even while the message command lock is held.
        started
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        assert!(transfers.take_result().is_none());
        assert!(
            transfers
                .enqueue(job("duplicate-sender", "sender-1"))
                .is_err()
        );
        for i in 2..=4 {
            transfers
                .enqueue(job(&format!("{i}"), &format!("sender-{i}")))
                .unwrap();
        }
        assert!(transfers.enqueue(job("overflow", "sender-5")).is_err());
        transfers.cancel(1, "one");
        assert!(
            transfers
                .active
                .as_ref()
                .unwrap()
                .job
                .cancelled
                .load(Ordering::Relaxed)
        );
        transfers.cancel(1, "2");
        assert_eq!(transfers.queue.len(), 2);
        release.send(()).unwrap();
        assert!(
            transfers
                .active
                .as_ref()
                .unwrap()
                .receiver
                .recv_timeout(std::time::Duration::from_secs(2))
                .unwrap()
                .is_ok()
        );
    }

    #[test]
    fn cancelled_deleted_and_old_account_results_are_discarded() {
        let _identity = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let saved = {
            let mut store = contact_store().lock().unwrap();
            std::mem::take(&mut *store)
        };
        for kind in ["cancelled", "deleted", "old-account"] {
            let mut job = job("one", "sender");
            let mut message = super::super::tests::history_message(1);
            message.id = job.id.clone();
            message.conversation_id = job.conversation.clone();
            message.attachment_name = Some(job.pointer.file_name.clone());
            message.attachment_pointer = Some(job.pointer.clone());
            let mut store = contact_store().lock().unwrap();
            store.generation = 1;
            store.messages_loaded = true;
            store.messages = vec![message];
            match kind {
                "cancelled" => job.cancelled.store(true, Ordering::Relaxed),
                "deleted" => store.messages.clear(),
                _ => job.generation = 0,
            }
            drop(store);
            let (sender, receiver) = mpsc::channel();
            sender.send(Ok(STANDARD.encode([1, 2, 3]))).unwrap();
            *transfers().lock().unwrap() = Transfers {
                active: Some(Active { job, receiver }),
                ..Default::default()
            };
            poll().unwrap();
            assert!(
                contact_store()
                    .lock()
                    .unwrap()
                    .messages
                    .iter()
                    .all(|m| m.attachment_base64.is_none())
            );
        }
        *contact_store().lock().unwrap() = saved;
        *transfers().lock().unwrap() = Transfers::default();
    }

    #[cfg(feature = "signal-ratchet")]
    #[test]
    fn pending_attachment_survives_restart_and_does_not_block_next_message() {
        let _identity = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-deferred-{}-{}",
            std::process::id(),
            current_time_ms().unwrap()
        ));
        let alice = directory.join("alice").to_string_lossy().into_owned();
        let bob = directory.join("bob").to_string_lossy().into_owned();
        identity::ensure_identity(&bob, "test-bob-vault", None, None).unwrap();
        let device = crate::peer_identity::PublishedDevice {
            bundle: identity::active_identity()
                .unwrap()
                .public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
                .unwrap(),
            route_blob: vec![1],
        };
        identity::ensure_identity(&alice, "test-alice-vault", None, None).unwrap();
        let pointer = job("file", "alice").pointer;
        let control = format!(
            "{ATTACHMENT_PREFIX}{}",
            STANDARD_NO_PAD.encode(serde_json::to_vec(&pointer).unwrap())
        );
        let (file_packet, file_id) = secure_packet::seal_for_test(&device, &control).unwrap();
        let (text_packet, _) =
            secure_packet::seal_for_test_with_id(&device, "Testo successivo", &[24; 16]).unwrap();
        identity::activate_from_storage(&bob, "test-bob-vault").unwrap();
        configure_storage(&bob).unwrap();
        configure_privacy(true).unwrap();
        assert!(
            persist_inbound_payload_with(&file_packet, |_, _| panic!("receipt must not fetch"))
                .unwrap()
        );
        assert!(
            persist_inbound_payload_with(&text_packet, |_, _| panic!("text must not fetch"))
                .unwrap()
        );
        assert!(!persist_inbound_payload(&file_packet).unwrap());
        configure_storage(&bob).unwrap();
        let conversations = list_conversations().unwrap();
        let conversation = conversations["conversations"][0]["id"].as_str().unwrap();
        let messages = list_messages(conversation, None, None, None).unwrap();
        assert_eq!(messages["messages"].as_array().unwrap().len(), 2);
        let file = messages["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == file_id)
            .unwrap();
        assert_eq!(file["attachment_state"], "pending");
        assert!(file["attachment_base64"].is_null());
        assert!(transfers().lock().unwrap().active.is_none());
        // Complete a user-requested download and verify durable storage.
        let message = contact_store()
            .lock()
            .unwrap()
            .messages
            .iter()
            .find(|m| m.id == file_id)
            .unwrap()
            .clone();
        let (sender, receiver) = mpsc::channel();
        sender.send(Ok(STANDARD.encode([1, 2, 3]))).unwrap();
        let generation = contact_store().lock().unwrap().generation;
        let mut task = job(&file_id, &message.author_id);
        task.generation = generation;
        task.conversation = conversation.to_owned();
        transfers().lock().unwrap().active = Some(Active {
            job: task,
            receiver,
        });
        poll().unwrap();
        configure_storage(&bob).unwrap();
        let messages = list_messages(conversation, None, None, None).unwrap();
        let file = messages["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == file_id)
            .unwrap();
        assert_eq!(file["attachment_state"], "ready");
        assert_eq!(file["attachment_base64"], STANDARD.encode([1, 2, 3]));
        fs::remove_dir_all(directory).unwrap();
    }
}
