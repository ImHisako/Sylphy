//! One durable intent joins the local read model and the ciphertext outbox.
use super::*;
use zeroize::Zeroizing;

const FILE: &str = "outgoing-transaction-v1.vault";
const MAX_BYTES: u64 = MAX_MESSAGE_STORE_BYTES + (MAX_ATTACHMENT_BYTES * 2) as u64 + 4096;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Transaction {
    version: u8,
    message: StoredMessage,
    pending: Vec<PendingDelivery>,
}

fn validate(transaction: &Transaction) -> CoreResult<()> {
    if transaction.version != 1
        || !transaction.message.is_outgoing
        || transaction.pending.len() > MAX_OUTBOX_DELIVERIES
    {
        return Err(CoreError::VerificationFailed);
    }
    validate_stored_message(&transaction.message)?;
    for pending in &transaction.pending {
        if pending.id.is_empty()
            || pending.message_id != transaction.message.id
            || pending.is_control
            || pending.payload.is_empty()
            || pending.payload.len() > 32 * 1024
            || pending.route_blob.is_empty()
            || pending.route_blob.len() > 16 * 1024
        {
            return Err(CoreError::VerificationFailed);
        }
    }
    Ok(())
}

pub(super) fn check_history_capacity(
    path: &Path,
    history: &[StoredMessage],
    message: &StoredMessage,
    limit: u64,
) -> CoreResult<()> {
    let key = identity::active_identity()?.storage_key()?;
    let frame_overhead = 4 + vault::seal_with_key(&key, &[])?.len() as u64;
    let event_size = |message: &StoredMessage| -> CoreResult<u64> {
        let encoded = Zeroizing::new(
            serde_json::to_vec(&MessageEvent::Upsert {
                message: message.clone(),
            })
            .map_err(|_| CoreError::Internal)?,
        );
        Ok(encoded.len() as u64 + frame_overhead)
    };
    let addition = event_size(message)?;
    let current = match fs::metadata(path) {
        Ok(metadata) => metadata.len(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            MESSAGE_LOG_MAGIC.len() as u64
        }
        Err(_) => return Err(CoreError::Internal),
    };
    if current.saturating_add(addition) <= limit {
        return Ok(());
    }
    // Reject a logical capacity failure before committing the intent. Otherwise
    // recovery could block even the deletion needed to make the new message fit.
    let mut compacted = MESSAGE_LOG_MAGIC.len() as u64 + addition;
    for message in history {
        compacted = compacted.saturating_add(event_size(message)?);
        if compacted > limit {
            return Err(CoreError::StorageFull);
        }
    }
    if compacted > limit {
        return Err(CoreError::StorageFull);
    }
    Ok(())
}

pub(super) fn commit(
    path: &Path,
    message: &StoredMessage,
    pending: &[PendingDelivery],
    outbox: &[PendingDelivery],
) -> CoreResult<()> {
    let directory = path.parent().ok_or(CoreError::Internal)?;
    recover(directory)?;
    validate_stored_message(message)?;
    let key = identity::active_identity()?.storage_key()?;
    let encryption_overhead = vault::seal_with_key(&key, &[])?.len() as u64;
    if outbox.len() > MAX_OUTBOX_DELIVERIES
        || serde_json::to_vec(outbox)
            .map_err(|_| CoreError::Internal)?
            .len() as u64
            + encryption_overhead
            > MAX_MESSAGE_STORE_BYTES
    {
        return Err(CoreError::StorageFull);
    }
    let transaction = Transaction {
        version: 1,
        message: message.clone(),
        pending: pending.to_vec(),
    };
    validate(&transaction)?;
    let plaintext =
        Zeroizing::new(serde_json::to_vec(&transaction).map_err(|_| CoreError::Internal)?);
    let encrypted = vault::seal_with_key(&key, &plaintext)?;
    if encrypted.len() as u64 > MAX_BYTES {
        return Err(CoreError::StorageFull);
    }
    let journal = directory.join(FILE);
    if let Err(error) = atomic_file::replace(&journal, &encrypted) {
        if fs::read(&journal).ok().as_deref() != Some(encrypted.as_slice()) {
            return Err(error);
        }
    }
    // The encrypted intent is now durable. Recovery must finish before network
    // dispatch or subsequent mutations; a materialization error cannot revoke it.
    let _ = recover(directory);
    Ok(())
}

pub(super) fn recover(directory: &Path) -> CoreResult<()> {
    recover_inner(directory).map_err(|error| match error {
        CoreError::StorageFull => error,
        _ => CoreError::Internal, // Local corruption never invalidates a network packet.
    })
}

fn recover_inner(directory: &Path) -> CoreResult<()> {
    let journal = directory.join(FILE);
    let metadata = match fs::metadata(&journal) {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(CoreError::Internal),
    };
    if metadata.len() > MAX_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let plaintext = vault::open_with_key(
        &identity::active_identity()?.storage_key()?,
        &fs::read(&journal).map_err(|_| CoreError::Internal)?,
    )?;
    let transaction: Transaction =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    validate(&transaction)?;
    let outbox_path = directory.join(OUTBOX_FILE);
    let mut outbox = load_outbox(&outbox_path)?;
    for pending in transaction.pending {
        if !outbox.iter().any(|item| item.id == pending.id) {
            outbox.push(pending);
        }
    }
    if outbox.len() > MAX_OUTBOX_DELIVERIES {
        return Err(CoreError::StorageFull);
    }
    append_message_event_with_limit(
        &directory.join(MESSAGE_LOG_FILE),
        &MessageEvent::Upsert {
            message: transaction.message,
        },
        MAX_MESSAGE_STORE_BYTES,
    )?;
    persist_outbox_raw(&outbox_path, &outbox)?;
    fs::remove_file(&journal).map_err(|_| CoreError::Internal)?;
    atomic_file::sync_parent(directory)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn intent() -> Transaction {
        let mut message = super::super::tests::history_message(1);
        message.body = "recover sender history and ciphertext together".into();
        message.delivery_state = "queued".into();
        let pending = PendingDelivery {
            id: "delivery".into(),
            message_id: message.id.clone(),
            route_blob: vec![1],
            payload: vec![2],
            is_control: false,
            created_at_ms: 1,
            offline_keys: None,
            attempts: 0,
            next_attempt_ms: 0,
        };
        Transaction {
            version: 1,
            message,
            pending: vec![pending],
        }
    }

    #[test]
    fn every_partial_commit_recovers_idempotently_before_startup_exposes_the_outbox() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let root =
            std::env::temp_dir().join(format!("sylphy-outgoing-recovery-{}", groups::new_id()));
        identity::ensure_identity(
            &root.to_string_lossy(),
            "transaction-recovery-secret",
            None,
            None,
        )
        .unwrap();
        for phase in 0..4 {
            let directory = root.join(format!("phase-{phase}/messaging"));
            fs::create_dir_all(&directory).unwrap();
            let transaction = intent();
            let encrypted = vault::seal_with_key(
                &identity::active_identity().unwrap().storage_key().unwrap(),
                &serde_json::to_vec(&transaction).unwrap(),
            )
            .unwrap();
            fs::write(directory.join(FILE), &encrypted).unwrap();
            assert!(
                !encrypted
                    .windows(transaction.message.body.len())
                    .any(|part| part == transaction.message.body.as_bytes())
            );
            // Crash after intent, history, outbox, or both materialized.
            if phase & 1 != 0 {
                append_message_event_with_limit(
                    &directory.join(MESSAGE_LOG_FILE),
                    &MessageEvent::Upsert {
                        message: transaction.message.clone(),
                    },
                    MAX_MESSAGE_STORE_BYTES,
                )
                .unwrap();
            }
            if phase & 2 != 0 {
                persist_outbox_raw(&directory.join(OUTBOX_FILE), &transaction.pending).unwrap();
            }
            configure_storage(&root.join(format!("phase-{phase}")).to_string_lossy()).unwrap();
            assert!(!directory.join(FILE).exists());
            for _ in 0..2 {
                let mut store = contact_store().lock().unwrap();
                ensure_messages_loaded(&mut store).unwrap();
                assert_eq!(store.messages.len(), 1);
                assert_eq!(store.messages[0].body, transaction.message.body);
                assert_eq!(store.outbox.len(), 1);
                assert_eq!(store.outbox[0].message_id, store.messages[0].id);
                drop(store);
                recover(&directory).unwrap();
            }
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_failed_materialization_keeps_the_durable_intent_and_blocks_later_writes() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let root =
            std::env::temp_dir().join(format!("sylphy-outgoing-blocked-{}", groups::new_id()));
        identity::ensure_identity(
            &root.to_string_lossy(),
            "transaction-recovery-secret",
            None,
            None,
        )
        .unwrap();
        configure_storage(&root.to_string_lossy()).unwrap();
        let directory = root.join("messaging");
        let path = directory.join(MESSAGE_LOG_FILE);
        fs::create_dir(&path).unwrap();
        let transaction = intent();
        commit(
            &path,
            &transaction.message,
            &transaction.pending,
            &transaction.pending,
        )
        .unwrap();
        assert!(directory.join(FILE).is_file());
        assert!(ensure_messages_loaded(&mut contact_store().lock().unwrap()).is_err());
        assert!(persist_outbox(&directory.join(OUTBOX_FILE), &[]).is_err());
        assert!(
            append_message_event(
                &path,
                &MessageEvent::DeleteConversation {
                    conversation_id: "chat".into()
                }
            )
            .is_err()
        );
        fs::remove_dir(&path).unwrap();
        configure_storage(&root.to_string_lossy()).unwrap();
        let mut store = contact_store().lock().unwrap();
        ensure_messages_loaded(&mut store).unwrap();
        assert_eq!(store.messages.len(), 1);
        assert_eq!(store.outbox.len(), 1);
        let mut next = transaction.message.clone();
        next.id = "next-message".into();
        let size = fs::metadata(&path).unwrap().len();
        assert!(matches!(
            check_history_capacity(&path, &store.messages, &next, size + 1),
            Err(CoreError::StorageFull)
        ));
        assert!(
            check_history_capacity(&path, &store.messages, &next, MAX_MESSAGE_STORE_BYTES).is_ok()
        );
        assert!(!directory.join(FILE).exists());
        drop(store);
        // Local damage must be retried, never treated as a bad inbound packet.
        fs::write(directory.join(FILE), b"corrupt local intent").unwrap();
        let error = recover(&directory).unwrap_err();
        assert!(!should_discard_inbound(&error));
        assert!(directory.join(FILE).is_file());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_orphans_wait_while_saved_messages_and_control_packets_can_dispatch() {
        let transaction = intent();
        let mut store = ContactStore::default();
        store.outbox = transaction.pending.clone();
        assert_eq!(dispatchable_outbox(&store).count(), 0);
        let mut impostor = transaction.message.clone();
        impostor.is_outgoing = false;
        store.messages.push(impostor);
        assert_eq!(dispatchable_outbox(&store).count(), 0);
        store.messages = vec![transaction.message];
        assert_eq!(dispatchable_outbox(&store).count(), 1);
        store.messages.clear();
        store.outbox[0].is_control = true;
        assert_eq!(dispatchable_outbox(&store).count(), 1);
    }
}
