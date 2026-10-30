//! Durable outgoing files, with bounded workers that see ciphertext only.
use super::*;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
    mpsc::{self, Receiver, Sender, TryRecvError},
};
use zeroize::Zeroizing;

pub(super) const MAX_PENDING: usize = 4;
const MAX_ACTIVE: usize = 2;
static WORKERS: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Pending {
    pub attempts: u32,
    pub next_attempt_ms: u64,
    pub channel_id: Option<String>,
    #[serde(default)]
    pub paused: bool,
}

struct Permit;
impl Permit {
    fn acquire() -> Option<Self> {
        WORKERS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < MAX_ACTIVE).then_some(count + 1)
            })
            .ok()
            .map(|_| Self)
    }
}
impl Drop for Permit {
    fn drop(&mut self) {
        WORKERS.fetch_sub(1, Ordering::AcqRel);
        crate::activity_events::notify();
    }
}

struct Job {
    generation: u64,
    id: String,
    conversation: String,
    pointer: AttachmentPointer,
    cancelled: Arc<AtomicBool>,
}
impl Drop for Job {
    fn drop(&mut self) {
        self.pointer.key_base64.zeroize();
        self.pointer.nonce_base64.zeroize();
        self.pointer.file_name.zeroize();
        self.pointer.channel_id.zeroize();
    }
}
struct Active {
    job: Job,
    result: Receiver<CoreResult<(String, u16)>>,
    acknowledge: Sender<bool>,
}
static ACTIVE: OnceLock<Mutex<Vec<Active>>> = OnceLock::new();
fn active() -> &'static Mutex<Vec<Active>> {
    ACTIVE.get_or_init(|| Mutex::new(Vec::new()))
}

pub(super) fn reset() {
    if let Ok(mut active) = active().lock() {
        for entry in active.iter() {
            entry.job.cancelled.store(true, Ordering::Release);
        }
        // Dropping acknowledgements tells completed workers to remove orphan blobs.
        // Workers keep their permits until network cleanup actually finishes.
        active.clear();
    }
}
pub(super) fn status(generation: u64, id: &str) -> &'static str {
    if active().lock().is_ok_and(|active| {
        active
            .iter()
            .any(|entry| entry.job.generation == generation && entry.job.id == id)
    }) {
        "uploading"
    } else {
        "upload_queued"
    }
}
pub(crate) fn active_count() -> usize {
    WORKERS.load(Ordering::Acquire)
}

fn prepare(generation: u64, message: &StoredMessage) -> CoreResult<(Job, Vec<u8>)> {
    let bytes = Zeroizing::new(
        STANDARD
            .decode(
                message
                    .attachment_base64
                    .as_deref()
                    .ok_or(CoreError::InvalidInput)?,
            )
            .map_err(|_| CoreError::InvalidInput)?,
    );
    if bytes.is_empty() || bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let mut key = Zeroizing::new([0_u8; 32]);
    let mut nonce = Zeroizing::new([0_u8; 24]);
    OsRng.fill_bytes(key.as_mut());
    OsRng.fill_bytes(nonce.as_mut());
    let encrypted = XChaCha20Poly1305::new((&*key).into())
        .encrypt(XNonce::from_slice(nonce.as_ref()), bytes.as_slice())
        .map_err(|_| CoreError::Internal)?;
    let pending = message
        .pending_upload
        .as_ref()
        .ok_or(CoreError::InvalidInput)?;
    Ok((
        Job {
            generation,
            id: message.id.clone(),
            conversation: message.conversation_id.clone(),
            cancelled: Arc::new(AtomicBool::new(false)),
            pointer: AttachmentPointer {
                version: 1,
                file_name: message
                    .attachment_name
                    .clone()
                    .ok_or(CoreError::InvalidInput)?,
                size: bytes.len(),
                record_key: String::new(),
                chunk_count: 0,
                key_base64: STANDARD_NO_PAD.encode(key.as_ref()),
                nonce_base64: STANDARD_NO_PAD.encode(nonce.as_ref()),
                channel_id: pending.channel_id.clone(),
            },
        },
        encrypted,
    ))
}

fn spawn(job: Job, encrypted: Vec<u8>, permit: Permit) -> CoreResult<Active> {
    spawn_with(
        job,
        encrypted,
        permit,
        veilid_adapter::publish_attachment_blob_cancellable,
    )
}

fn spawn_with(
    job: Job,
    encrypted: Vec<u8>,
    permit: Permit,
    publish: impl FnOnce(&[u8], &AtomicBool) -> CoreResult<(String, u16)> + Send + 'static,
) -> CoreResult<Active> {
    let (sender, result) = mpsc::channel();
    let (acknowledge, accepted) = mpsc::channel();
    let cancelled = job.cancelled.clone();
    let epoch = crate::performance::epoch();
    std::thread::Builder::new()
        .name("sylphy-upload".to_owned())
        .spawn(move || {
            let _permit = permit;
            let timer =
                crate::performance::Timer::start_in(crate::performance::Stage::Upload, epoch);
            let uploaded = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                publish(&encrypted, &cancelled)
            }))
            .unwrap_or(Err(CoreError::Internal));
            timer.finish(uploaded.is_ok());
            let blob = uploaded.as_ref().ok().cloned();
            let sent = sender.send(uploaded).is_ok();
            crate::activity_events::notify();
            // Acknowledgement is local and follows the durable message/outbox commit.
            // No timeout may delete a file while the command thread still needs it.
            let keep = sent && accepted.recv().unwrap_or(false);
            if !keep {
                if let Some((key, count)) = blob {
                    let _ = veilid_adapter::delete_attachment_blob(&key, count);
                }
            }
        })
        .map_err(|_| CoreError::Internal)?;
    Ok(Active {
        job,
        result,
        acknowledge,
    })
}

fn retry(job: &Job, error: &CoreError) -> CoreResult<()> {
    if job.cancelled.load(Ordering::Acquire) {
        return Ok(());
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    if store.generation != job.generation {
        return Ok(());
    }
    let Some(index) = store.messages.iter().position(|m| {
        m.id == job.id && m.conversation_id == job.conversation && m.pending_upload.is_some()
    }) else {
        return Ok(());
    };
    let mut message = store.messages[index].clone();
    let pending = message.pending_upload.as_mut().ok_or(CoreError::Internal)?;
    if pending.paused {
        return Ok(());
    }
    pending.paused = matches!(
        error,
        CoreError::GroupPermissionDenied
            | CoreError::GroupClosed
            | CoreError::InvalidInput
            | CoreError::VerificationFailed
            | CoreError::UnsupportedVersion
            | CoreError::SpamRejected
    );
    pending.attempts = pending.attempts.saturating_add(1);
    pending.next_attempt_ms = current_time_ms()?.saturating_add(retry_delay_ms(pending.attempts));
    append_message_event(
        store
            .message_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    )?;
    wipe_message_memory(&mut store.messages[index]);
    store.messages[index] = message;
    store.message_event_count += 1;
    store.revision = store.revision.wrapping_add(1);
    Ok(())
}

fn commit(job: &mut Job, key: String, count: u16) -> CoreResult<()> {
    let (mut message, path) = {
        let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        if store.generation != job.generation || job.cancelled.load(Ordering::Acquire) {
            return Err(CoreError::FeatureUnavailable);
        }
        let message = store
            .messages
            .iter()
            .find(|m| {
                m.id == job.id
                    && m.conversation_id == job.conversation
                    && m.pending_upload.as_ref().is_some_and(|p| !p.paused)
            })
            .cloned()
            .ok_or(CoreError::InvalidInput)?;
        (
            message,
            store
                .message_path
                .clone()
                .ok_or(CoreError::FeatureUnavailable)?,
        )
    };
    job.pointer.record_key = key.clone();
    job.pointer.chunk_count = count;
    validate_attachment_pointer(&job.pointer)?;
    let id: Vec<_> = (0..job.id.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&job.id[i..i + 2], 16).map_err(|_| CoreError::InvalidInput))
        .collect::<CoreResult<_>>()?;
    if id.len() != 16 {
        return Err(CoreError::InvalidInput);
    }
    let encoded =
        Zeroizing::new(serde_json::to_vec(&job.pointer).map_err(|_| CoreError::Internal)?);
    let control = Zeroizing::new(format!(
        "{ATTACHMENT_PREFIX}{}",
        STANDARD_NO_PAD.encode(encoded.as_slice())
    ));
    let deliveries = if let Some(group) = current_group(&job.conversation)? {
        let local = contact_id(&identity::active_identity()?.identity_public_key()?);
        groups::enforce_pending_media(&group, &local, &job.pointer.file_name, &job.id)?;
        groups::enforce_channel(&group, job.pointer.channel_id.as_deref())?;
        if job.pointer.channel_id.is_some() {
            groups::require_updated(&group)?;
        }
        let wrapped = Zeroizing::new(format!(
            "{GROUP_MESSAGE_PREFIX}{}:{}",
            job.conversation,
            STANDARD_NO_PAD.encode(control.as_bytes())
        ));
        let mut deliveries = Vec::new();
        for member in &group.members {
            let (mut sealed, _) =
                secure_packet::seal_for_all_with_id(&member.identity, &wrapped, &id)?;
            deliveries.append(&mut sealed);
        }
        deliveries
    } else {
        // Resolve expired routes through the existing background directory worker.
        // Never do a network lookup while committing a completed upload.
        let recipient = {
            let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
            store
                .contacts
                .iter()
                .find(|c| c.id == job.conversation)
                .and_then(|c| c.published_identity.clone())
                .ok_or(CoreError::InvalidInput)?
        };
        if recipient.bundle.expires_at_ms <= current_time_ms()? {
            request_contact_refresh(Some(job.conversation.clone()));
            return Err(CoreError::FeatureUnavailable);
        }
        secure_packet::seal_for_all_with_id(&recipient, &control, &id)?.0
    };
    register_attachment_lease(&key, count)?;
    message.pending_upload = None;
    let result = queue_outgoing(&path, message, deliveries);
    if result.is_err() {
        remove_attachment_lease(&key);
    }
    result
}

pub(super) fn poll() -> CoreResult<()> {
    let completed = {
        let mut active = active().lock().map_err(|_| CoreError::Internal)?;
        let mut completed = Vec::new();
        let mut index = 0;
        while index < active.len() {
            let result = match active[index].result.try_recv() {
                Ok(value) => value,
                Err(TryRecvError::Empty) => {
                    index += 1;
                    continue;
                }
                Err(TryRecvError::Disconnected) => Err(CoreError::NetworkAttachFailed),
            };
            completed.push((active.swap_remove(index), result));
        }
        completed
    };
    for (mut active, result) in completed {
        let result = result.and_then(|(key, count)| commit(&mut active.job, key, count));
        let committed = result.is_ok();
        let _ = active.acknowledge.send(committed);
        if let Err(error) = result {
            let _ = retry(&active.job, &error);
        }
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    // Called only by unlocked command handlers. Recovery loads encrypted pending
    // messages, so a process restart automatically reconstructs the bounded queue.
    ensure_messages_loaded(&mut store)?;
    let mut active = active().lock().map_err(|_| CoreError::Internal)?;
    for entry in active.iter() {
        if entry.job.generation != store.generation
            || !store
                .messages
                .iter()
                .any(|m| m.id == entry.job.id && m.pending_upload.is_some())
        {
            entry.job.cancelled.store(true, Ordering::Release);
        }
    }
    let now = current_time_ms()?;
    let mut started = false;
    for message in store.messages.iter().filter(|m| {
        m.pending_upload
            .as_ref()
            .is_some_and(|p| !p.paused && p.next_attempt_ms <= now)
    }) {
        if active
            .iter()
            .any(|a| a.job.generation == store.generation && a.job.id == message.id)
        {
            continue;
        }
        let Some(permit) = Permit::acquire() else {
            break;
        };
        let (job, encrypted) = prepare(store.generation, message)?;
        active.push(spawn(job, encrypted, permit)?);
        started = true;
    }
    if started {
        store.revision = store.revision.wrapping_add(1);
    }
    Ok(())
}

pub(super) fn request(conversation: &str, id: &str, cancel: bool) -> CoreResult<Value> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let index = store
        .messages
        .iter()
        .position(|m| m.id == id && m.conversation_id == conversation && m.pending_upload.is_some())
        .ok_or(CoreError::InvalidInput)?;
    if !cancel
        && store
            .messages
            .iter()
            .filter(|m| m.pending_upload.as_ref().is_some_and(|p| !p.paused))
            .count()
            >= MAX_PENDING
        && store.messages[index]
            .pending_upload
            .as_ref()
            .is_some_and(|p| p.paused)
    {
        return Err(CoreError::LimitExceeded);
    }
    let mut message = store.messages[index].clone();
    let pending = message
        .pending_upload
        .as_mut()
        .ok_or(CoreError::InvalidInput)?;
    pending.paused = cancel;
    pending.attempts = 0;
    pending.next_attempt_ms = 0;
    append_message_event(
        store
            .message_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    )?;
    wipe_message_memory(&mut store.messages[index]);
    store.messages[index] = message;
    store.message_event_count += 1;
    store.revision = store.revision.wrapping_add(1);
    if cancel {
        if let Ok(active) = active().lock() {
            for entry in active
                .iter()
                .filter(|a| a.job.generation == store.generation && a.job.id == id)
            {
                entry.job.cancelled.store(true, Ordering::Release);
            }
        }
    }
    drop(store);
    let _ = poll();
    crate::activity_events::notify();
    Ok(json!({"state": if cancel { "upload_failed" } else { "upload_queued" }}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn suspension_and_resume_survive_reopening_the_encrypted_history() {
        let _account = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory =
            std::env::temp_dir().join(format!("sylphy-upload-state-{}", groups::new_id()));
        identity::ensure_identity(
            &directory.to_string_lossy(),
            "upload-test-password",
            None,
            None,
        )
        .unwrap();
        configure_storage(&directory.to_string_lossy()).unwrap();
        let mut message = super::super::tests::history_message(1);
        message.id = "00112233445566778899aabbccddeeff".to_owned();
        message.conversation_id = "chat".to_owned();
        message.delivery_state = "queued".to_owned();
        message.attachment_name = Some("test.bin".to_owned());
        message.attachment_base64 = Some(STANDARD.encode([1, 2, 3]));
        message.pending_upload = Some(Pending {
            attempts: 0,
            next_attempt_ms: 0,
            channel_id: None,
            paused: false,
        });
        {
            let mut store = contact_store().lock().unwrap();
            ensure_messages_loaded(&mut store).unwrap();
            append_message_event(
                store.message_path.as_deref().unwrap(),
                &MessageEvent::Upsert {
                    message: message.clone(),
                },
            )
            .unwrap();
            store.messages.push(message.clone());
        }
        assert_eq!(
            request("chat", &message.id, true).unwrap()["state"],
            "upload_failed"
        );
        configure_storage(&directory.to_string_lossy()).unwrap();
        {
            let mut store = contact_store().lock().unwrap();
            ensure_messages_loaded(&mut store).unwrap();
            assert!(store.messages[0].pending_upload.as_ref().unwrap().paused);
        }
        assert_eq!(
            request("chat", &message.id, false).unwrap()["state"],
            "upload_queued"
        );
        configure_storage(&directory.to_string_lossy()).unwrap();
        {
            let mut store = contact_store().lock().unwrap();
            ensure_messages_loaded(&mut store).unwrap();
            assert!(!store.messages[0].pending_upload.as_ref().unwrap().paused);
        }
        wipe_memory().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while active_count() != 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(active_count(), 0);
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn blocked_upload_leaves_the_command_lock_free_and_reset_keeps_workers_bounded() {
        let _account = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        reset();
        let mut message = super::super::tests::history_message(1);
        message.id = "00112233445566778899aabbccddeeff".to_owned();
        message.attachment_name = Some("test.bin".to_owned());
        message.attachment_base64 = Some(STANDARD.encode([1, 2, 3]));
        message.pending_upload = Some(Pending {
            attempts: 0,
            next_attempt_ms: 0,
            channel_id: None,
            paused: false,
        });
        let (job, ciphertext) = prepare(1, &message).unwrap();
        let cancelled = job.cancelled.clone();
        let (started, ready) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let entry = spawn_with(job, ciphertext, Permit::acquire().unwrap(), move |_, _| {
            started.send(()).unwrap();
            let _ = gate.recv_timeout(std::time::Duration::from_secs(5));
            Err(CoreError::NetworkAttachFailed)
        })
        .unwrap();
        active().lock().unwrap().push(entry);
        ready
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        let command = crate::ffi::COMMAND_LOCK.try_lock().unwrap();
        drop(command);
        let second = Permit::acquire().unwrap();
        assert!(Permit::acquire().is_none());
        reset();
        assert!(cancelled.load(Ordering::Acquire));
        assert!(Permit::acquire().is_none());
        drop(second);
        release.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while active_count() != 0 && std::time::Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(active_count(), 0);
    }
    #[test]
    fn pending_uploads_require_outgoing_local_files_and_old_messages_remain_readable() {
        let mut message = super::super::tests::history_message(1);
        let original = serde_json::to_value(&message).unwrap();
        assert!(original.get("pending_upload").is_none());
        message.id = "00112233445566778899aabbccddeeff".to_owned();
        message.delivery_state = "queued".to_owned();
        message.attachment_name = Some("test.bin".to_owned());
        message.attachment_base64 = Some(STANDARD.encode([1, 2, 3]));
        message.pending_upload = Some(Pending {
            attempts: 0,
            next_attempt_ms: 0,
            channel_id: None,
            paused: false,
        });
        validate_stored_message(&message).unwrap();
        let (job, ciphertext) = prepare(17, &message).unwrap();
        assert_ne!(ciphertext, [1, 2, 3]);
        assert_eq!(job.generation, 17);
        let restored: StoredMessage =
            serde_json::from_value(serde_json::to_value(&message).unwrap()).unwrap();
        assert!(restored.pending_upload.is_some());
        message.is_outgoing = false;
        assert!(validate_stored_message(&message).is_err());
        message.is_outgoing = true;
        message.attachment_base64 = None;
        assert!(validate_stored_message(&message).is_err());
    }
}
