use super::*;
use crate::bundle::SignalPreKeyBundle;
use ed25519_dalek::SigningKey;

fn delivery(id: &str) -> PendingDelivery {
    PendingDelivery {
        id: id.to_owned(),
        message_id: id.to_owned(),
        is_control: false,
        route_blob: vec![1],
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
) -> Vec<PendingDelivery> {
    pending
        .iter()
        .filter(|item| !active.contains(&item.id))
        .take(capacity)
        .cloned()
        .collect()
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
            |active, capacity| select(&initial, active, capacity),
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
        |active, capacity| select(&next, active, capacity),
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
        |active, capacity| select(&next, active, capacity),
        |_, _| panic!("duplicate send"),
    )
    .unwrap();
    assert_eq!(repeated[0].0.id, "fast");
    acknowledge_outbox_results(42, &HashSet::from(["fast".into()]), &HashSet::new());
    assert!(poll_outbox_transport_with(42, |_, _| vec![], |_, _| unreachable!()).is_none());
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
        |active, capacity| select(&pending, active, capacity),
        |item, sender| {
            started.push(item.id);
            old_sender = Some(sender);
            true
        },
    );
    assert_eq!(started.len(), MAX_OUTBOX_IN_FLIGHT);
    poll_outbox_transport_with(
        100,
        |active, capacity| select(&pending, active, capacity),
        |_, _| panic!("capacity exceeded"),
    );
    assert!(poll_outbox_transport_with(101, |_, _| Vec::new(), |_, _| unreachable!()).is_none());
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
    poll_outbox_transport_with(101, |_, _| vec![pending[0].clone()], |_, _| false);
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
        |_, _| vec![pending[0].clone()],
        |_, _| {
            restarted = true;
            true
        },
    );
    assert!(restarted);
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
