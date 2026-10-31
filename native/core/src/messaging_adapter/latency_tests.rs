use super::*;
use crate::bundle::SignalPreKeyBundle;
use ed25519_dalek::SigningKey;

fn delivery(id: &str) -> PendingDelivery {
    PendingDelivery {
        id: id.to_owned(),
        message_id: id.to_owned(),
        is_control: false,
        route_blob: id.as_bytes().to_vec(),
        payload: vec![2],
        created_at_ms: 1,
        offline_keys: None,
        attempts: 0,
        next_attempt_ms: 0,
    }
}

fn select(
    pending: &[PendingDelivery],
    active: &HashSet<String>,
    capacity: usize,
    schedule: &outbox_schedule::Schedule,
) -> Vec<PendingDelivery> {
    outbox_schedule::select(
        &queued_store(pending),
        active,
        capacity,
        100,
        None,
        *schedule,
    )
}

fn queued_store(pending: &[PendingDelivery]) -> ContactStore {
    let mut seen = HashSet::new();
    let messages = pending
        .iter()
        .filter(|item| !item.is_control && seen.insert(item.message_id.clone()))
        .map(|item| StoredMessage {
            id: item.message_id.clone(),
            conversation_id: "chat".to_owned(),
            author_id: "me".to_owned(),
            body: "Queued text".to_owned(),
            sent_at_ms: 1,
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: "queued".to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
            attachment_pointer: None,
            pending_upload: None,
        })
        .collect();
    ContactStore {
        outbox: pending.to_vec(),
        messages,
        ..Default::default()
    }
}

#[test]
fn free_slots_dispatch_new_messages_while_a_slow_peer_is_still_running() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    *OUTBOX_TRANSPORT.lock().unwrap() = None;
    let initial = vec![delivery("slow"), delivery("fast")];
    let mut started = Vec::new();
    let mut completions = Vec::new();
    assert!(
        poll_outbox_transport_with(
            42,
            |active, capacity, schedule| select(&initial, active, capacity, schedule),
            |item, sender| {
                started.push(item.id.clone());
                completions.push((item, sender));
                true
            }
        )
        .is_none()
    );
    assert_eq!(started, ["slow", "fast"]);
    let (fast, sender) = completions.pop().unwrap();
    sender.send((fast.clone(), true)).unwrap();
    let next = vec![delivery("slow"), delivery("fast"), delivery("new")];
    let results = poll_outbox_transport_with(
        42,
        |active, capacity, schedule| select(&next, active, capacity, schedule),
        |item, sender| {
            started.push(item.id.clone());
            completions.push((item, sender));
            true
        },
    )
    .unwrap();
    assert_eq!(started, ["slow", "fast", "new"]);
    assert_eq!(results[0].0.id, "fast");
    // An unsuccessful durable commit must not lose the completion or resend it.
    let repeated = poll_outbox_transport_with(
        42,
        |active, capacity, schedule| select(&next, active, capacity, schedule),
        |_, _| panic!("duplicate send"),
    )
    .unwrap();
    assert_eq!(repeated[0].0.id, "fast");
    acknowledge_outbox_results(42, &HashSet::from(["fast".into()]), &HashSet::new());
    assert!(poll_outbox_transport_with(42, |_, _, _| vec![], |_, _| unreachable!()).is_none());
    let state = OUTBOX_TRANSPORT.lock().unwrap();
    let state = state.as_ref().unwrap();
    assert!(state.in_flight.contains("slow"));
    assert!(state.in_flight.contains("new"));
    assert!(!state.in_flight.contains("fast"));
}

#[test]
fn worker_limits_spawn_failures_and_account_changes_do_not_duplicate_or_apply_old_sends() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    *OUTBOX_TRANSPORT.lock().unwrap() = None;
    let pending = (0..8)
        .map(|index| delivery(&format!("id-{index}")))
        .collect::<Vec<_>>();
    let mut started = Vec::new();
    let mut old_sender = None;
    poll_outbox_transport_with(
        100,
        |active, capacity, schedule| select(&pending, active, capacity, schedule),
        |item, sender| {
            started.push(item.id);
            old_sender = Some(sender);
            true
        },
    );
    assert_eq!(started.len(), MAX_OUTBOX_IN_FLIGHT);
    poll_outbox_transport_with(
        100,
        |active, capacity, schedule| select(&pending, active, capacity, schedule),
        |_, _| panic!("capacity exceeded"),
    );
    assert!(poll_outbox_transport_with(101, |_, _, _| Vec::new(), |_, _| unreachable!()).is_none());
    assert!(
        old_sender
            .unwrap()
            .send((pending[0].clone(), true))
            .is_err()
    );
    assert!(
        OUTBOX_TRANSPORT
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .completed
            .is_empty()
    );
    poll_outbox_transport_with(101, |_, _, _| vec![pending[0].clone()], |_, _| false);
    assert!(
        OUTBOX_TRANSPORT
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .in_flight
            .is_empty()
    );
    let mut restarted = false;
    poll_outbox_transport_with(
        101,
        |_, _, _| vec![pending[0].clone()],
        |_, _| {
            restarted = true;
            true
        },
    );
    assert!(restarted);
}

#[test]
fn one_message_with_many_devices_leaves_room_for_later_messages_in_the_same_chat() {
    let mut pending = (0..8)
        .map(|index| {
            let mut item = delivery(&format!("old-device-{index}"));
            item.message_id = "old-message".to_owned();
            item
        })
        .collect::<Vec<_>>();
    pending.extend([delivery("later-one"), delivery("later-two")]);
    let selected = select(&pending, &HashSet::new(), 4, &Default::default());
    assert_eq!(selected.len(), 4);
    assert_eq!(
        selected
            .iter()
            .filter(|item| item.message_id == "old-message")
            .count(),
        2
    );
    assert!(selected.iter().any(|item| item.id == "later-one"));
    assert!(selected.iter().any(|item| item.id == "later-two"));
    // Existing workers count too, including a completion not yet durable.
    let active = HashSet::from(["old-device-0".into(), "old-device-1".into()]);
    let selected = select(&pending, &active, 2, &Default::default());
    assert_eq!(
        selected
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["later-one", "later-two"]
    );
}

#[test]
fn unreachable_destination_and_retry_backlog_cannot_occupy_every_worker() {
    let mut pending = (0..8)
        .map(|index| {
            let mut item = delivery(&format!("failed-{index}"));
            item.route_blob = vec![1];
            item.attempts = 5;
            item
        })
        .collect::<Vec<_>>();
    let mut later_same_chat = delivery("later-same-chat");
    later_same_chat.route_blob = vec![1];
    pending.extend([later_same_chat, delivery("another-destination")]);
    let selected = select(&pending, &HashSet::new(), 4, &Default::default());
    assert!(selected.iter().any(|item| item.id == "later-same-chat"));
    assert!(selected.iter().any(|item| item.id == "another-destination"));
    assert_eq!(selected.len(), 4);
    let active = HashSet::from(["failed-0".into(), "failed-1".into(), "failed-2".into()]);
    let selected = select(&pending, &active, 1, &Default::default());
    assert_eq!(selected[0].id, "another-destination");
}

#[test]
fn fresh_messages_and_due_retries_both_progress_across_single_slot_polls() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let mut state = OutboxTransport::new(500);
    state
        .in_flight
        .extend(["busy-a".into(), "busy-b".into(), "busy-c".into()]);
    *OUTBOX_TRANSPORT.lock().unwrap() = Some(state);
    let mut pending = (0..9)
        .map(|index| delivery(&format!("fresh-{index}")))
        .collect::<Vec<_>>();
    let mut retry = delivery("retry");
    retry.attempts = 1;
    pending.insert(0, retry);
    let mut order = Vec::new();
    for _ in 0..8 {
        poll_outbox_transport_with(
            500,
            |active, capacity, schedule| select(&pending, active, capacity, schedule),
            |item, sender| {
                order.push(item.id.clone());
                sender.send((item, true)).unwrap();
                true
            },
        );
        let results =
            poll_outbox_transport_with(500, |_, _, _| vec![], |_, _| unreachable!()).unwrap();
        let id = results[0].0.id.clone();
        acknowledge_outbox_results(500, &HashSet::from([id.clone()]), &HashSet::new());
        if id != "retry" {
            pending.retain(|item| item.id != id);
        }
    }
    assert_eq!(
        order,
        [
            "fresh-0", "fresh-1", "fresh-2", "retry", "fresh-3", "fresh-4", "fresh-5", "retry"
        ]
    );
    *OUTBOX_TRANSPORT.lock().unwrap() = None;
}

#[test]
fn scheduling_respects_backoff_hidden_messages_and_the_message_filter() {
    let mut sleeping = delivery("sleeping");
    sleeping.next_attempt_ms = 101;
    let mut store = queued_store(&[sleeping, delivery("hidden"), delivery("ready")]);
    store.messages.retain(|item| item.id != "hidden");
    let choose =
        |id| outbox_schedule::select(&store, &HashSet::new(), 4, 100, id, Default::default());
    assert_eq!(
        choose(None)
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["ready"]
    );
    assert!(choose(Some("sleeping")).is_empty());
    assert!(choose(Some("hidden")).is_empty());
    assert_eq!(choose(Some("ready"))[0].id, "ready");
}

#[test]
fn failure_keeps_its_ciphertext_while_the_next_message_is_sent_and_survives_restart() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!(
        "sylphy-independent-{}-{}",
        std::process::id(),
        current_time_ms().unwrap()
    ));
    let root = directory.to_string_lossy();
    identity::ensure_identity(&root, "queue-test-vault", None, None).unwrap();
    configure_storage(&root).unwrap();
    let pending = vec![delivery("failed"), delivery("successful")];
    let generation = {
        let mut store = contact_store().lock().unwrap();
        store.messages = queued_store(&pending).messages;
        store.messages_loaded = true;
        store.outbox = pending.clone();
        for message in &store.messages {
            append_message_event(
                store.message_path.as_ref().unwrap(),
                &MessageEvent::Upsert {
                    message: message.clone(),
                },
            )
            .unwrap();
        }
        persist_outbox(store.outbox_path.as_ref().unwrap(), &store.outbox).unwrap();
        store.generation
    };
    let mut transport = OutboxTransport::new(generation);
    transport
        .in_flight
        .extend(pending.iter().map(|item| item.id.clone()));
    transport.sender.send((pending[0].clone(), false)).unwrap();
    transport.sender.send((pending[1].clone(), true)).unwrap();
    *OUTBOX_TRANSPORT.lock().unwrap() = Some(transport);
    assert!(!flush_outbox(None));
    configure_storage(&root).unwrap();
    let mut store = contact_store().lock().unwrap();
    ensure_messages_loaded(&mut store).unwrap();
    assert_eq!(store.outbox.len(), 1);
    assert_eq!(store.outbox[0].id, "failed");
    assert_eq!(store.outbox[0].payload, pending[0].payload);
    assert_eq!(store.outbox[0].attempts, 1);
    assert!(store.outbox[0].next_attempt_ms > current_time_ms().unwrap());
    assert_eq!(
        store
            .messages
            .iter()
            .find(|item| item.id == "failed")
            .unwrap()
            .delivery_state,
        "queued"
    );
    assert_eq!(
        store
            .messages
            .iter()
            .find(|item| item.id == "successful")
            .unwrap()
            .delivery_state,
        "sent"
    );
    drop(store);
    fs::remove_dir_all(directory).unwrap();
}

fn published(key: &SigningKey, expires_at_ms: u64) -> PublishedIdentity {
    let prekey = SignalPreKeyBundle {
        registration_id: 1,
        device_id: 1,
        signed_pre_key_id: 1,
        signed_pre_key_public: vec![1; 33],
        signed_pre_key_signature: vec![2; 64],
        kyber_pre_key_id: 1,
        kyber_pre_key_public: vec![3; 1184],
        kyber_pre_key_signature: vec![4; 64],
        identity_key: vec![5; 33],
    };
    let bundle =
        PublicBundle::new_signed(key, &[1; 32], &[2; 1184], expires_at_ms, Some(prekey)).unwrap();
    PublishedIdentity::new(key, bundle, vec![1], Default::default(), None).unwrap()
}

#[test]
fn refreshed_routes_preserve_ciphertext_and_only_follow_the_same_authenticated_device() {
    let key = SigningKey::generate(&mut OsRng);
    let previous = published(&key, current_time_ms().unwrap() + 60_000);
    let refreshed = PublishedIdentity::new(
        &key,
        previous.bundle.clone(),
        vec![7],
        Default::default(),
        None,
    )
    .unwrap();
    let mut pending = vec![delivery("route-recovery")];
    pending[0].route_blob = previous.route_blob.clone();
    pending[0].next_attempt_ms = u64::MAX;
    let ciphertext = pending[0].payload.clone();
    assert!(reroute_pending_deliveries(&mut pending, &previous, &refreshed).unwrap());
    assert_eq!(pending[0].route_blob, vec![7]);
    assert_eq!(pending[0].payload, ciphertext);
    assert_eq!(pending[0].next_attempt_ms, 0);
    let foreign = published(
        &SigningKey::generate(&mut OsRng),
        current_time_ms().unwrap() + 60_000,
    );
    assert!(reroute_pending_deliveries(&mut pending, &previous, &foreign).is_err());
    let mut replacement_bundle = previous.bundle.signal_pre_key.clone().unwrap();
    replacement_bundle.identity_key = vec![9; 33];
    let replaced = PublicBundle::new_signed(
        &key,
        &[1; 32],
        &[2; 1184],
        current_time_ms().unwrap() + 60_000,
        Some(replacement_bundle),
    )
    .unwrap();
    let replaced =
        PublishedIdentity::new(&key, replaced, vec![8], Default::default(), None).unwrap();
    pending[0].route_blob = previous.route_blob.clone();
    assert!(!reroute_pending_deliveries(&mut pending, &previous, &replaced).unwrap());
    assert_eq!(pending[0].route_blob, previous.route_blob);
    assert_eq!(pending[0].payload, ciphertext);
}

#[test]
fn valid_signed_endpoints_skip_dht_and_expired_or_substituted_keys_are_rejected() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let key = SigningKey::generate(&mut OsRng);
    let now = current_time_ms().unwrap();
    let current = published(&key, now + 60_000);
    let id = contact_id(&current.bundle.identity_ed25519);
    let saved = {
        let mut store = contact_store().lock().unwrap();
        std::mem::replace(
            &mut *store,
            ContactStore {
                path: Some(PathBuf::from("must-not-write")),
                contacts: vec![StoredContact {
                    id: id.clone(),
                    display_name: "Peer".into(),
                    fingerprint: "peer".into(),
                    added_at_ms: now,
                    bundle: current.bundle.clone(),
                    published_identity: Some(current.clone()),
                    verified: true,
                    invitation_code: Some("sylphy:VLD0:discovery".into()),
                    previous_bundles: vec![],
                }],
                ..Default::default()
            },
        )
    };
    let endpoint =
        refreshed_recipient_with(&id, |_| panic!("cached send must not wait for DHT")).unwrap();
    assert_eq!(
        endpoint.bundle.identity_ed25519,
        current.bundle.identity_ed25519
    );
    let substituted = published(&SigningKey::generate(&mut OsRng), now + 60_000);
    contact_store().lock().unwrap().contacts[0].published_identity = Some(substituted);
    assert!(refreshed_recipient_with(&id, |_| panic!("cached account key mismatch")).is_err());
    let mut corrupt = current.clone();
    corrupt.signature[0] ^= 1;
    contact_store().lock().unwrap().contacts[0].published_identity = Some(corrupt);
    assert!(refreshed_recipient_with(&id, |_| panic!("invalid cached signature")).is_err());
    let expired = published(&key, now - 1);
    contact_store().lock().unwrap().contacts[0].published_identity = Some(expired.clone());
    assert!(refreshed_recipient_with(&id, |_| Err(CoreError::NetworkStartupFailed)).is_err());
    assert!(refreshed_recipient_with(&id, |_| Ok(expired)).is_err());
    let other = published(&SigningKey::generate(&mut OsRng), now + 60_000);
    assert!(refreshed_recipient_with(&id, |_| Ok(other)).is_err());
    *contact_store().lock().unwrap() = saved;
}
