//! Receipts travel as authenticated encrypted controls through the durable outbox.
use super::*;

const PREFIX: &str = "sylphy-receipt-v1:";
static SEND_READ: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn delivery_state_rank(state: &str) -> u8 {
    match state {
        "queued" => 1,
        "sent" => 2,
        "delivered" => 3,
        "read" => 4,
        _ => 0,
    }
}

pub(super) fn merge(existing: &mut Tracking, incoming: &Tracking) {
    if existing.recipients.is_empty() {
        existing.recipients = incoming.recipients.clone();
    }
    for (actor, state) in &incoming.acknowledgements {
        let old = existing
            .acknowledgements
            .get(actor)
            .map(String::as_str)
            .unwrap_or("");
        if delivery_state_rank(state) > delivery_state_rank(old) {
            existing
                .acknowledgements
                .insert(actor.clone(), state.clone());
        }
    }
    // `sent` describes this device's durable receipt outbox and stays local.
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub(super) struct Tracking {
    #[serde(default)]
    pub recipients: Vec<String>,
    #[serde(default)]
    pub acknowledgements: HashMap<String, String>,
    #[serde(default)]
    sent: String,
}

#[derive(Deserialize, Serialize)]
struct Receipt {
    message_ids: Vec<String>,
    state: String,
}

pub(super) fn configure(send_read: bool) {
    SEND_READ.store(send_read, std::sync::atomic::Ordering::Relaxed);
}

fn wanted(message: &StoredMessage) -> &'static str {
    if message.is_read && SEND_READ.load(std::sync::atomic::Ordering::Relaxed) {
        "read"
    } else {
        "delivered"
    }
}

pub(super) fn flush() {
    let _ = flush_with(secure_packet::seal_for_all);
}

fn flush_with(
    mut seal: impl FnMut(
        &PublishedIdentity,
        &str,
    ) -> CoreResult<(Vec<secure_packet::SealedDelivery>, String)>,
) -> CoreResult<()> {
    // Batch by author and state. The saved marker changes only after ciphertext
    // is durable, so restarts and temporary network failures cannot lose receipts.
    let (generation, batches) = {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
        let mut batches: HashMap<(String, String), (PublishedIdentity, Vec<String>)> =
            HashMap::new();
        let mut endpoints: HashMap<&str, Option<PublishedIdentity>> = HashMap::new();
        for message in store.messages.iter().rev().filter(|m| !m.is_outgoing) {
            let state = wanted(message);
            if delivery_state_rank(&message.receipts.sent) >= delivery_state_rank(state) {
                continue;
            }
            let key = (message.author_id.clone(), state.to_owned());
            if batches.get(&key).is_some_and(|(_, ids)| ids.len() >= 64)
                || (batches.len() >= 4 && !batches.contains_key(&key))
            {
                continue;
            }
            // Verify each author's endpoint once per pass, including old clients
            // without receipt support; large histories must not repeat crypto work.
            let endpoint = endpoints.entry(&message.author_id).or_insert_with(|| {
                store
                    .contacts
                    .iter()
                    .find(|c| c.id == message.author_id)
                    .and_then(|c| c.published_identity.clone())
                    .or_else(|| {
                        store
                            .groups
                            .iter()
                            .flat_map(|g| &g.members)
                            .find(|m| m.id == message.author_id)
                            .map(|m| m.identity.clone())
                    })
                    .filter(|endpoint| {
                        endpoint.delivery_devices().is_ok_and(|devices| {
                            devices.iter().all(|device| {
                                device
                                    .bundle
                                    .capabilities
                                    .iter()
                                    .any(|capability| capability == "message-receipts-v1")
                            })
                        })
                    })
            });
            if let Some(endpoint) = endpoint {
                let batch = batches
                    .entry(key)
                    .or_insert_with(|| (endpoint.clone(), Vec::new()));
                if batch.1.len() < 64 {
                    batch.1.push(message.id.clone());
                }
            }
        }
        (store.generation, batches)
    };
    for ((_, state), (recipient, ids)) in batches {
        let body = format!(
            "{PREFIX}{}",
            serde_json::to_string(&Receipt {
                message_ids: ids.clone(),
                state: state.clone(),
            })
            .map_err(|_| CoreError::Internal)?
        );
        let (deliveries, control_id) = seal(&recipient, &body)?;
        if deliveries.is_empty() {
            return Err(CoreError::FeatureUnavailable);
        }
        let now = current_time_ms()?;
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        if store.generation != generation {
            return Err(CoreError::FeatureUnavailable);
        }
        let mut outbox = store.outbox.clone();
        for delivery in deliveries {
            outbox.push(PendingDelivery {
                id: groups::new_id(),
                message_id: control_id.clone(),
                is_control: true,
                route_blob: delivery.route_blob,
                payload: delivery.payload,
                offline_keys: delivery.offline_keys,
                created_at_ms: now,
                attempts: 0,
                next_attempt_ms: 0,
            });
        }
        if outbox.len() > MAX_OUTBOX_DELIVERIES {
            return Err(CoreError::StorageFull);
        }
        persist_outbox(
            store
                .outbox_path
                .as_deref()
                .ok_or(CoreError::FeatureUnavailable)?,
            &outbox,
        )?;
        store.outbox = outbox;
        let path = store
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        for id in ids {
            if let Some(index) = store
                .messages
                .iter()
                .position(|m| m.id == id && !m.is_outgoing)
            {
                let mut message = store.messages[index].clone();
                message.receipts.sent = state.clone();
                append_message_event(
                    &path,
                    &MessageEvent::Upsert {
                        message: message.clone(),
                    },
                )?;
                store.messages[index] = message;
                store.message_event_count += 1;
            }
        }
        compact_message_log_if_needed(&mut store)?;
    }
    Ok(())
}

fn apply(message: &mut StoredMessage, actor: &str, state: &str) -> CoreResult<bool> {
    if !message.is_outgoing || !message.receipts.recipients.iter().any(|id| id == actor) {
        return Err(CoreError::AuthenticationFailed);
    }
    let old = message
        .receipts
        .acknowledgements
        .get(actor)
        .map(String::as_str)
        .unwrap_or("");
    if delivery_state_rank(old) >= delivery_state_rank(state) {
        return Ok(false);
    }
    message
        .receipts
        .acknowledgements
        .insert(actor.to_owned(), state.to_owned());
    refresh_state(message);
    Ok(true)
}

pub(super) fn refresh_state(message: &mut StoredMessage) {
    if !message.is_outgoing
        || message.receipts.recipients.is_empty()
        || message.receipts.acknowledgements.is_empty()
    {
        return;
    }
    let all_at_least = |state: &str| {
        message.receipts.recipients.iter().all(|id| {
            message
                .receipts
                .acknowledgements
                .get(id)
                .is_some_and(|value| delivery_state_rank(value) >= delivery_state_rank(state))
        })
    };
    let next = if all_at_least("read") {
        "read"
    } else if all_at_least("delivered") {
        "delivered"
    } else {
        "sent"
    };
    if delivery_state_rank(next) > delivery_state_rank(&message.delivery_state) {
        message.delivery_state = next.to_owned();
    }
}

pub(super) fn receive(body: &str, sender: &PublishedIdentity) -> CoreResult<Option<bool>> {
    let Some(encoded) = body.strip_prefix(PREFIX) else {
        return Ok(None);
    };
    let receipt: Receipt = serde_json::from_str(encoded).map_err(|_| CoreError::InvalidInput)?;
    if !matches!(receipt.state.as_str(), "delivered" | "read")
        || receipt.message_ids.is_empty()
        || receipt.message_ids.len() > 64
    {
        return Err(CoreError::InvalidInput);
    }
    let actor = contact_id(&sender.bundle.identity_ed25519);
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let mut changes = Vec::new();
    for id in receipt.message_ids {
        let Some(index) = store.messages.iter().position(|m| m.id == id) else {
            continue;
        };
        let mut message = store.messages[index].clone();
        // Compatibility for messages saved before recipient tracking existed.
        if message.receipts.recipients.is_empty() {
            message.receipts.recipients = store
                .groups
                .iter()
                .find(|g| g.id == message.conversation_id)
                .map(|g| g.members.iter().map(|m| m.id.clone()).collect())
                .unwrap_or_else(|| vec![message.conversation_id.clone()]);
        }
        if apply(&mut message, &actor, &receipt.state)? {
            changes.push((index, message));
        }
    }
    let changed = !changes.is_empty();
    let mut events = Vec::new();
    for (index, message) in changes {
        append_message_event(
            &path,
            &MessageEvent::Upsert {
                message: message.clone(),
            },
        )?;
        if let Some(group) = store
            .groups
            .iter()
            .find(|g| g.id == message.conversation_id)
        {
            events.push(DeviceSyncEvent::UpsertGroupMessage {
                group: group.clone(),
                message: message.clone(),
            });
        } else if let Some(contact) = store
            .contacts
            .iter()
            .find(|c| c.id == message.conversation_id)
        {
            events.push(DeviceSyncEvent::UpsertMessage {
                contact: contact.clone(),
                message: message.clone(),
            });
        }
        store.messages[index] = message;
        store.message_event_count += 1;
        store.revision = store.revision.wrapping_add(1);
    }
    compact_message_log_if_needed(&mut store)?;
    drop(store);
    for event in events {
        queue_device_sync(&event);
    }
    Ok(Some(changed))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message() -> StoredMessage {
        serde_json::from_value(json!({
            "id": "m1", "conversation_id": "chat", "author_id": "me",
            "body": "ciao", "sent_at_ms": 1000, "is_outgoing": true,
            "delivery_state": "queued",
            "receipts": {"recipients": ["alice", "bob"]}
        }))
        .unwrap()
    }

    #[test]
    fn group_receipts_require_every_recipient_and_never_regress() {
        let mut message = message();
        assert!(apply(&mut message, "mallory", "read").is_err());
        assert!(apply(&mut message, "alice", "read").unwrap());
        assert_eq!(message.delivery_state, "sent");
        assert!(!apply(&mut message, "alice", "delivered").unwrap());
        apply(&mut message, "bob", "delivered").unwrap();
        assert_eq!(message.delivery_state, "delivered");
        apply(&mut message, "bob", "read").unwrap();
        assert_eq!(message.delivery_state, "read");
        assert!(!apply(&mut message, "bob", "read").unwrap());
        message.is_outgoing = false;
        assert!(apply(&mut message, "alice", "read").is_err());
    }

    #[test]
    fn private_read_state_and_outbox_marker_stay_local_during_sync() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let mut message = message();
        message.is_read = true;
        configure(false);
        assert_eq!(wanted(&message), "delivered");
        configure(true);
        assert_eq!(wanted(&message), "read");
        configure(false);
        let mut remote = message.receipts.clone();
        remote.sent = "read".to_owned();
        remote
            .acknowledgements
            .insert("alice".to_owned(), "read".to_owned());
        merge(&mut message.receipts, &remote);
        assert!(message.receipts.sent.is_empty());
        assert_eq!(message.receipts.acknowledgements["alice"], "read");
        let mut other_device = message.clone();
        message.receipts.acknowledgements.clear();
        apply(&mut message, "alice", "read").unwrap();
        other_device.receipts.acknowledgements.clear();
        apply(&mut other_device, "bob", "read").unwrap();
        assert_eq!(
            merge_synced_message(&message, &other_device)
                .unwrap()
                .delivery_state,
            "read"
        );
    }

    #[cfg(feature = "signal-ratchet")]
    #[test]
    fn encrypted_receipts_survive_restart_and_update_sender_without_chat_controls() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory = std::env::temp_dir().join(format!("sylphy-receipts-{}", groups::new_id()));
        let fixture = |name: &str| {
            let root = directory.join(name).to_string_lossy().into_owned();
            identity::ensure_identity(&root, "receipt-test-vault", None, None).unwrap();
            let local = identity::active_identity().unwrap();
            let endpoint = PublishedIdentity::new(
                &local.signing_key().unwrap(),
                local
                    .public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
                    .unwrap(),
                vec![1; 512],
                crate::peer_identity::PublicProfile::default(),
                None,
            )
            .unwrap();
            (root, endpoint)
        };
        let (alice_root, alice) = fixture("Alice");
        let (bob_root, bob) = fixture("Bob");
        let activate = |root: &str| {
            identity::activate_from_storage(root, "receipt-test-vault").unwrap();
            configure_storage(root).unwrap();
        };
        activate(&alice_root);
        let device = bob.delivery_devices().unwrap().remove(0);
        let (packet, id) = secure_packet::seal_for_test(&device, "ciao").unwrap();
        let mut outgoing = message();
        outgoing.id = id.clone();
        outgoing.conversation_id = contact_id(&bob.bundle.identity_ed25519);
        outgoing.receipts.recipients = vec![outgoing.conversation_id.clone()];
        {
            let mut store = contact_store().lock().unwrap();
            ensure_messages_loaded(&mut store).unwrap();
            let path = store.message_path.clone().unwrap();
            append_message_event(
                &path,
                &MessageEvent::Upsert {
                    message: outgoing.clone(),
                },
            )
            .unwrap();
            store.messages.push(outgoing);
        }
        activate(&bob_root);
        configure_privacy(true).unwrap();
        assert!(persist_inbound_payload(&packet).unwrap());
        let seal = |recipient: &PublishedIdentity, text: &str| {
            let device = recipient.delivery_devices()?.remove(0);
            let (payload, id) = secure_packet::seal_for_test_with_id(&device, text, &[42; 16])?;
            Ok((
                vec![secure_packet::SealedDelivery {
                    payload,
                    route_blob: vec![1; 512],
                    offline_keys: None,
                }],
                id,
            ))
        };
        configure(false);
        flush_with(seal).unwrap();
        activate(&bob_root);
        let delivery = contact_store().lock().unwrap().outbox[0].payload.clone();
        activate(&alice_root);
        assert!(persist_inbound_payload(&delivery).unwrap());
        assert_eq!(
            list_messages(&contact_id(&bob.bundle.identity_ed25519), None, None, None).unwrap()["messages"]
                [0]["delivery_state"],
            "delivered"
        );
        activate(&bob_root);
        mark_conversation_read(&contact_id(&alice.bundle.identity_ed25519)).unwrap();
        configure(true);
        flush_with(seal).unwrap();
        let read = contact_store()
            .lock()
            .unwrap()
            .outbox
            .last()
            .unwrap()
            .payload
            .clone();
        activate(&alice_root);
        assert!(persist_inbound_payload(&read).unwrap());
        activate(&alice_root);
        let messages =
            list_messages(&contact_id(&bob.bundle.identity_ed25519), None, None, None).unwrap();
        assert_eq!(messages["messages"].as_array().unwrap().len(), 1);
        assert_eq!(messages["messages"][0]["delivery_state"], "read");
        configure(false);
        fs::remove_dir_all(directory).unwrap();
    }
}
