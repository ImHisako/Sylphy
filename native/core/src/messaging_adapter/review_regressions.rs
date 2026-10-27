use super::*;

#[test]
fn unconfirmed_direct_handoff_falls_back_or_keeps_the_packet_queued() {
    let expected = crate::direct_delivery::acknowledgement(b"encrypted packet");
    for response in [
        Err(CoreError::NetworkAttachFailed), // lock/queue clear or timeout
        Ok(Vec::new()),
        Ok(b"sylphy-rejected-v1".to_vec()),
        Ok(crate::direct_delivery::acknowledgement(b"other packet")),
    ] {
        let mut deposited = false;
        assert!(deliver_with_offline_fallback(
            || crate::direct_delivery::confirm(&expected, response),
            || {
                deposited = true;
                Ok(())
            },
        ));
        assert!(deposited);
    }
    assert!(!deliver_with_offline_fallback(
        || crate::direct_delivery::confirm(&expected, Err(CoreError::NetworkAttachFailed)),
        || Err(CoreError::StorageFull),
    ));
    assert!(deliver_with_offline_fallback(
        || crate::direct_delivery::confirm(&expected, Ok(expected.clone())),
        || panic!("committed packet requires no offline deposit"),
    ));
}

#[test]
fn outgoing_history_limit_precedes_outbox_and_encryption() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let saved = {
        let mut store = contact_store().lock().unwrap();
        std::mem::replace(
            &mut *store,
            ContactStore {
                messages_loaded: true,
                messages: (0..MAX_MESSAGES)
                    .map(super::tests::history_message)
                    .collect(),
                ..ContactStore::default()
            },
        )
    };
    let path = std::env::temp_dir().join(format!("sylphy-capacity-{}.log", groups::new_id()));
    let mut message = super::tests::history_message(MAX_MESSAGES);
    message.id = "overflow".into();
    let result = queue_outgoing(
        &path,
        message,
        vec![secure_packet::SealedDelivery {
            payload: vec![1],
            route_blob: vec![1],
            offline_keys: None,
        }],
    );
    assert!(matches!(result, Err(CoreError::StorageFull)));
    assert!(matches!(
        send_text_with("chat", "overflow", |_, _, _| panic!(
            "full history advanced ratchet"
        )),
        Err(CoreError::StorageFull)
    ));
    assert!(!path.exists());
    let mut store = contact_store().lock().unwrap();
    assert_eq!(store.messages.len(), MAX_MESSAGES);
    assert!(store.outbox.is_empty());
    store.messages.pop();
    assert!(check_message_capacity(&store).is_ok());
    *store = saved;
}

#[cfg(feature = "signal-ratchet")]
fn endpoint(root: &str) -> PublishedIdentity {
    identity::ensure_identity(root, "regression-vault-secret", None, None).unwrap();
    let local = identity::active_identity().unwrap();
    PublishedIdentity::new(
        &local.signing_key().unwrap(),
        local
            .public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
            .unwrap(),
        vec![1; 512],
        crate::peer_identity::PublicProfile::default(),
        None,
    )
    .unwrap()
}

#[cfg(feature = "signal-ratchet")]
fn activate(root: &str) {
    identity::activate_from_storage(root, "regression-vault-secret").unwrap();
    configure_storage(root).unwrap();
}

#[test]
#[cfg(feature = "signal-ratchet")]
fn ratchet_journal_recovers_partial_commit_and_failed_prepare_is_retryable() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory =
        std::env::temp_dir().join(format!("sylphy-ratchet-recovery-{}", groups::new_id()));
    let alice = directory.join("alice").to_string_lossy().into_owned();
    let bob = directory.join("bob").to_string_lossy().into_owned();
    let recipient = endpoint(&bob);
    endpoint(&alice);
    let device = recipient.delivery_devices().unwrap().remove(0);
    let (first, _) = secure_packet::seal_for_test(&device, "retry after prepare failure").unwrap();
    let (second, _) =
        secure_packet::seal_for_test_with_id(&device, "recover after partial commit", &[24; 16])
            .unwrap();
    activate(&bob);
    ratchet_adapter::public_pre_key_bundle().unwrap();
    let journal = PathBuf::from(&bob).join("messaging/signal-transaction-v1.vault");
    fs::create_dir(&journal).unwrap();
    assert!(persist_inbound_payload(&first).is_err());
    assert!(contact_store().lock().unwrap().messages.is_empty());
    fs::remove_dir(&journal).unwrap();
    fs::write(&journal, b"damaged local transaction").unwrap();
    let error = persist_inbound_payload(&first).unwrap_err();
    assert!(!should_discard_inbound(&error));
    assert!(contact_store().lock().unwrap().messages.is_empty());
    fs::remove_file(&journal).unwrap();
    assert!(persist_inbound_payload(&first).unwrap());
    let global = PathBuf::from(&bob).join("messaging/signal-account-v2.vault");
    let previous = fs::read(&global).unwrap();
    fs::remove_file(&global).unwrap();
    fs::create_dir(&global).unwrap();
    // Session replacement succeeds, global replacement fails. The durable
    // journal preserves both the ratchet transition and the saved message.
    assert!(persist_inbound_payload(&second).unwrap());
    assert!(journal.is_file());
    assert_eq!(contact_store().lock().unwrap().messages.len(), 2);
    assert!(
        !fs::read(&journal)
            .unwrap()
            .windows(7)
            .any(|v| v == b"recover")
    );
    fs::remove_dir(&global).unwrap();
    fs::write(&global, previous).unwrap();
    activate(&bob);
    ratchet_adapter::public_pre_key_bundle().unwrap();
    assert!(!journal.exists());
    assert!(!persist_inbound_payload(&second).unwrap());
    assert_eq!(contact_store().lock().unwrap().messages.len(), 2);
    // A fresh packet still decrypts against the recovered pre-key/session state.
    activate(&alice);
    let (third, _) =
        secure_packet::seal_for_test_with_id(&device, "after recovery", &[25; 16]).unwrap();
    activate(&bob);
    assert!(persist_inbound_payload(&third).unwrap());
    fs::remove_dir_all(directory).unwrap();
}

#[test]
#[cfg(feature = "signal-ratchet")]
fn four_signed_devices_publish_and_resolve_across_multiple_values() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory =
        std::env::temp_dir().join(format!("sylphy-identity-publication-{}", groups::new_id()));
    endpoint(&directory.to_string_lossy());
    let local = identity::active_identity().unwrap();
    let signing = local.signing_key().unwrap();
    let base = ratchet_adapter::public_pre_key_bundle().unwrap().unwrap();
    let mut previous = None;
    for device_id in 1..=4 {
        let mut signal = base.clone();
        signal.device_id = device_id;
        let merged = PublishedIdentity::merged_for_current_device(
            &signing,
            previous.as_ref(),
            local.public_bundle(Some(signal)).unwrap(),
            vec![1; 512],
            crate::peer_identity::PublicProfile {
                display_name: Some("Profile".into()),
                avatar_base64: Some(STANDARD.encode(vec![1; 8 * 1024])),
            },
            None,
        )
        .unwrap();
        let encoded = serde_json::to_vec(&merged).unwrap();
        let mut blob = Vec::new();
        let value = crate::identity_publication::encode(encoded.clone(), |data| {
            blob = data.to_vec();
            Ok((
                "test-record".into(),
                data.len().div_ceil(crate::blob_transport::CHUNK_BYTES) as u16,
            ))
        })
        .unwrap();
        assert!(value.len() <= crate::identity_publication::VALUE_BYTES);
        if device_id > 1 {
            assert!(!blob.is_empty());
        }
        let restored = crate::identity_publication::decode(&value, |_, _| Ok(blob)).unwrap();
        assert_eq!(restored, encoded);
        let resolved: PublishedIdentity = serde_json::from_slice(&restored).unwrap();
        resolved.validate().unwrap();
        assert_eq!(
            resolved.delivery_devices().unwrap().len(),
            device_id as usize
        );
        previous = Some(merged);
    }
    fs::remove_dir_all(directory).unwrap();
}

#[cfg(feature = "signal-ratchet")]
fn contact(value: PublishedIdentity) -> StoredContact {
    StoredContact {
        id: contact_id(&value.bundle.identity_ed25519),
        display_name: "known peer".into(),
        fingerprint: fingerprint(&value.bundle.identity_ed25519),
        added_at_ms: 1,
        bundle: value.bundle.clone(),
        published_identity: Some(value),
        verified: false,
        invitation_code: None,
        previous_bundles: Vec::new(),
    }
}

#[test]
#[cfg(feature = "signal-ratchet")]
fn same_id_from_different_senders_survives_replay_restart_and_replication() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-further-id-{}", groups::new_id()));
    let bob = directory.join("bob").to_string_lossy().into_owned();
    let alice = directory.join("alice").to_string_lossy().into_owned();
    let mallory = directory.join("mallory").to_string_lossy().into_owned();
    let recipient = endpoint(&bob);
    let alice_identity = endpoint(&alice);
    let target = recipient.delivery_devices().unwrap().remove(0);
    let (legitimate, _) =
        secure_packet::seal_for_test_with_id(&target, "legitimate group message", &[91; 16])
            .unwrap();
    let mallory_identity = endpoint(&mallory);
    let (other_chat, _) =
        secure_packet::seal_for_test_with_id(&target, "another sender's message", &[91; 16])
            .unwrap();
    activate(&bob);
    configure_privacy(false).unwrap();
    {
        let mut store = contact_store().lock().unwrap();
        store.contacts = vec![contact(alice_identity), contact(mallory_identity)];
        persist_contacts(store.path.as_ref().unwrap(), &store.contacts).unwrap();
    }
    assert!(secure_packet::inspect(&legitimate).is_ok());
    assert!(persist_inbound_payload(&other_chat).unwrap());
    assert!(persist_inbound_payload(&legitimate).unwrap());
    assert!(!persist_inbound_payload(&legitimate).unwrap());
    configure_storage(&bob).unwrap();
    let mut store = contact_store().lock().unwrap();
    ensure_messages_loaded(&mut store).unwrap();
    assert_eq!(store.messages.len(), 2);
    assert_eq!(store.messages[0].body, "another sender's message");
    assert_eq!(store.messages[1].body, "legitimate group message");
    assert_ne!(store.messages[0].id, store.messages[1].id);
    let mut replicated = store.messages[1].clone();
    replicated.id = message_ids::wire(&replicated.id).to_owned();
    let contact = store
        .contacts
        .iter()
        .find(|contact| contact.id == replicated.author_id)
        .unwrap()
        .clone();
    drop(store);
    apply_device_sync_plaintext(
        &serde_json::to_vec(&DeviceSyncEvent::UpsertMessage {
            contact,
            message: replicated,
        })
        .unwrap(),
    )
    .unwrap();
    assert_eq!(contact_store().lock().unwrap().messages.len(), 2);
    configure_privacy(true).unwrap();
    fs::remove_dir_all(directory).unwrap();
}
