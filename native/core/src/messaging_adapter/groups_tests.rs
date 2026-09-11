use super::*;

fn fixture(directory: &Path, name: &str) -> GroupMember {
    let root = directory.join(name).to_string_lossy().into_owned();
    identity::ensure_identity(&root, "group-management-tests", None, None).unwrap();
    let local = identity::active_identity().unwrap();
    group_member(
        PublishedIdentity::new(
            &local.signing_key().unwrap(),
            local
                .public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
                .unwrap(),
            vec![1; 512],
            crate::peer_identity::PublicProfile {
                display_name: Some(name.to_owned()),
                avatar_base64: None,
            },
            None,
        )
        .unwrap(),
    )
    .unwrap()
}

fn activate(directory: &Path, name: &str) {
    let root = directory.join(name).to_string_lossy().into_owned();
    identity::activate_from_storage(&root, "group-management-tests").unwrap();
    configure_storage(&root).unwrap();
}

fn group(admin: &GroupMember, members: Vec<GroupMember>, mode: &str) -> StoredGroup {
    StoredGroup {
        id: format!("test-{mode}"),
        name: "Gruppo di prova".to_owned(),
        description: String::new(),
        mode: mode.to_owned(),
        admin_id: admin.id.clone(),
        created_at_ms: current_time_ms().unwrap(),
        members,
        management: Management::default(),
    }
}

#[test]
fn offline_group_backlog_is_deferred_then_received_out_of_order_without_loss() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-backlog-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let alice = fixture(&directory, "Alice");
    let bob = fixture(&directory, "Bob");
    activate(&directory, "Alice");
    let device = bob.identity.delivery_devices().unwrap().remove(0);
    let packets = (1..=3)
        .map(|id| {
            let body = format!(
                "{GROUP_MESSAGE_PREFIX}test-group:{}",
                STANDARD_NO_PAD.encode(format!("messaggio {id}"))
            );
            secure_packet::seal_for_test_with_id(&device, &body, &[id; 16])
                .unwrap()
                .0
        })
        .collect::<Vec<_>>();
    activate(&directory, "Bob");
    let mut value = group(&admin, vec![admin.clone(), alice.clone()], "group");
    value.management.policy.slow_mode_seconds = 30;
    save(value.clone()).unwrap();
    assert!(persist_inbound_payload(&packets[2]).unwrap());
    for packet in [&packets[0], &packets[1]] {
        let error = persist_inbound_payload(packet).unwrap_err();
        assert!(matches!(error, CoreError::InboundDeferred));
        assert!(!should_discard_inbound(&error));
    }
    // Advance the local receive window without sleeping. Retrying the exact
    // ciphertext also checks rollback of the uncommitted Signal receive state.
    for packet in [&packets[0], &packets[1]] {
        for message in &mut contact_store().lock().unwrap().messages {
            message.received_at_ms = current_time_ms().unwrap() - 31_000;
        }
        assert!(persist_inbound_payload(packet).unwrap());
    }
    activate(&directory, "Bob");
    let messages = list_messages(&value.id, None, None, None).unwrap();
    assert_eq!(messages["messages"].as_array().unwrap().len(), 3);
    for packet in &packets {
        assert!(!persist_inbound_payload(packet).unwrap());
    }
    // Permanent content/policy rejections still discard packets.
    value.management.policy.aggressive_antispam = true;
    let error = enforce_inbound(&value, &alice.id, "@a @b @c @d @e @f", false).unwrap_err();
    assert!(matches!(error, CoreError::SpamRejected));
    assert!(should_discard_inbound(&error));
    value.management.policy.send_messages = false;
    assert!(matches!(
        enforce_inbound(&value, &alice.id, "test", false),
        Err(CoreError::GroupPermissionDenied)
    ));
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn inbound_antispam_timing_is_retryable_while_local_send_limits_remain_errors() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-spam-backlog-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let member = fixture(&directory, "Member");
    activate(&directory, "Admin");
    let mut value = group(&admin, vec![member.clone()], "group");
    value.admin_id = "me".to_owned();
    value.management.policy.aggressive_antispam = true;
    save(value.clone()).unwrap();
    let now = current_time_ms().unwrap();
    {
        let mut store = contact_store().lock().unwrap();
        ensure_messages_loaded(&mut store).unwrap();
        store.messages.push(StoredMessage {
            id: new_id(),
            conversation_id: value.id.clone(),
            author_id: member.id.clone(),
            body: "ripetizione".to_owned(),
            sent_at_ms: now - 120_000,
            received_at_ms: now,
            author_name: None,
            is_outgoing: false,
            is_read: false,
            delivery_state: "delivered".to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
        });
    }
    assert!(matches!(
        enforce(&value, &member.id, "ripetizione", false),
        Err(CoreError::SpamRejected)
    ));
    assert!(matches!(
        enforce_inbound(&value, &member.id, "ripetizione", false),
        Err(CoreError::InboundDeferred)
    ));
    {
        let mut store = contact_store().lock().unwrap();
        let first = store.messages[0].clone();
        for _ in 0..4 {
            let mut message = first.clone();
            message.id = new_id();
            store.messages.push(message);
        }
    }
    let error = enforce_inbound(&value, &member.id, "testo diverso", false).unwrap_err();
    assert!(matches!(error, CoreError::InboundDeferred));
    assert!(!should_discard_inbound(&error));
    for message in &mut contact_store().lock().unwrap().messages {
        message.received_at_ms = now - 61_000;
    }
    assert!(enforce_inbound(&value, &member.id, "ripetizione", false).is_ok());
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn invited_members_send_to_everyone_in_normal_and_business_groups_with_shared_ids() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-group-management-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let alice = fixture(&directory, "Alice");
    let bob = fixture(&directory, "Bob");
    for mode in ["group", "channel"] {
        activate(&directory, "Alice");
        crate::peer_identity::set_public_profile(crate::peer_identity::PublicProfile {
            display_name: Some("Alice Rossi".to_owned()),
            avatar_base64: None,
        })
        .unwrap();
        let local_group = group(&admin, vec![admin.clone(), bob.clone()], mode);
        save(local_group.clone()).unwrap();
        let mut packets = Vec::new();
        let sent = send_text_with(
            &local_group.id,
            "Risposta del membro #progetto @Bob",
            |recipient, body, id| {
                let device = recipient.delivery_devices()?.remove(0);
                let (payload, message_id) =
                    secure_packet::seal_for_test_with_id(&device, body, id)?;
                packets.push(payload.clone());
                Ok((
                    vec![secure_packet::SealedDelivery {
                        payload,
                        route_blob: vec![1; 512],
                        offline_keys: None,
                    }],
                    message_id,
                ))
            },
        )
        .unwrap();
        assert_eq!(packets.len(), 2);
        assert!(can_write(&local_group).unwrap());
        activate(&directory, "Admin");
        assert_eq!(
            secure_packet::inspect(&packets[0]).unwrap().message_id,
            sent["message_id"].as_str().unwrap()
        );
        let mut admin_group = group(&admin, vec![alice.clone(), bob.clone()], mode);
        admin_group.admin_id = "me".to_owned();
        save(admin_group).unwrap();
        assert!(persist_inbound_payload(&packets[0]).unwrap());
        let received = list_messages(&local_group.id, None, None, None).unwrap();
        assert_eq!(
            received["messages"][0]["body"],
            "Risposta del membro #progetto @Bob"
        );
        assert_eq!(received["messages"][0]["id"], sent["message_id"]);
        assert_eq!(received["messages"][0]["author_name"], "Alice Rossi");
        activate(&directory, "Admin");
        assert_eq!(
            list_messages(&local_group.id, None, None, None).unwrap()["messages"][0]["author_name"],
            "Alice Rossi"
        );
        activate(&directory, "Bob");
        assert_eq!(
            secure_packet::inspect(&packets[1]).unwrap().message_id,
            sent["message_id"].as_str().unwrap()
        );
        save(group(&admin, vec![admin.clone(), alice.clone()], mode)).unwrap();
        assert!(persist_inbound_payload(&packets[1]).unwrap());
        assert_eq!(
            list_messages(&local_group.id, None, None, None).unwrap()["messages"][0]["id"],
            sent["message_id"]
        );
    }
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn group_permissions_restrictions_slow_mode_and_spam_are_enforced_natively() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-group-policy-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let member = fixture(&directory, "Member");
    activate(&directory, "Member");
    let mut value = group(&admin, vec![admin.clone()], "channel");
    let mut legacy = serde_json::to_value(&value).unwrap();
    legacy.as_object_mut().unwrap().remove("management");
    let legacy: StoredGroup = serde_json::from_value(legacy).unwrap();
    assert!(can_write(&legacy).unwrap());
    assert!(enforce(&value, &member.id, "test", false).is_ok());
    value.management.policy.send_messages = false;
    assert!(matches!(
        enforce(&value, &member.id, "test", false),
        Err(CoreError::GroupPermissionDenied)
    ));
    assert!(!can_write(&value).unwrap());
    value.management.policy.send_messages = true;
    value.management.restrictions.insert(
        member.id.clone(),
        Policy {
            send_media: false,
            send_links: false,
            ..Policy::default()
        },
    );
    assert!(matches!(
        enforce(&value, &member.id, "foto.png", true),
        Err(CoreError::GroupPermissionDenied)
    ));
    assert!(matches!(
        enforce(&value, &member.id, "https://example.com", false),
        Err(CoreError::GroupPermissionDenied)
    ));
    value.management.restrictions.clear();
    value.management.policy.send_links = false;
    for link in [
        "example.com",
        "(WWW.Example.com/path)",
        "link:example.com?x=1",
        "[vai](https://example.com)",
        "example\u{200b}.com",
        "192.168.1.1:8080",
        "пример.рф",
        "sylphy:abc",
    ] {
        assert!(
            matches!(
                enforce(&value, &member.id, link, false),
                Err(CoreError::GroupPermissionDenied)
            ),
            "{link}"
        );
    }
    assert!(enforce(&value, &member.id, "ciao @Alice, versione 1.2", false).is_ok());
    value.management.policy.send_links = true;
    let rights = AdminPermissions {
        pin_messages: true,
        ..AdminPermissions::default()
    };
    value.management.admins.insert(member.id.clone(), rights);
    assert!(
        authorized(
            &value,
            &member.id,
            &Action::Pin {
                message_id: "abc".to_owned(),
                pinned: true
            }
        )
        .is_ok()
    );
    assert!(matches!(
        authorized(&value, &member.id, &Action::Close),
        Err(CoreError::GroupPermissionDenied)
    ));
    assert!(matches!(
        authorized(
            &value,
            &member.id,
            &Action::SetAdmin {
                member_id: "other".to_owned(),
                permissions: Some(AdminPermissions::all())
            }
        ),
        Err(CoreError::GroupPermissionDenied)
    ));
    value.management.admins.clear();
    {
        let mut store = contact_store().lock().unwrap();
        ensure_messages_loaded(&mut store).unwrap();
        store.messages.push(StoredMessage {
            id: new_id(),
            conversation_id: value.id.clone(),
            author_id: "me".to_owned(),
            body: "ripetizione".to_owned(),
            sent_at_ms: current_time_ms().unwrap(),
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: "sent".to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
        });
    }
    value.management.policy.slow_mode_seconds = 30;
    assert!(matches!(
        enforce(&value, &member.id, "nuovo", false),
        Err(CoreError::SlowModeActive)
    ));
    value.management.policy.slow_mode_seconds = 0;
    value.management.policy.aggressive_antispam = true;
    assert!(matches!(
        enforce(&value, &member.id, "ripetizione", false),
        Err(CoreError::SpamRejected)
    ));
    assert!(matches!(
        enforce(&value, &member.id, "@a @b @c @d @e @f", false),
        Err(CoreError::SpamRejected)
    ));
    value.management.closed = true;
    assert!(matches!(
        enforce(&value, &admin.id, "test", false),
        Err(CoreError::GroupClosed)
    ));
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn owner_snapshots_reject_forgery_preserve_order_and_close_even_before_invitation() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-group-snapshot-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let member = fixture(&directory, "Member");
    let attacker = fixture(&directory, "Other");
    activate(&directory, "Member");
    let mut snapshot = group(&admin, vec![admin.clone(), member.clone()], "group");
    snapshot.management.revision = 1;
    snapshot.management.coordinator = Some(admin.identity.clone());
    let control = Control::Snapshot {
        group: snapshot.clone(),
        notice: "Permessi aggiornati".to_owned(),
        event_id: new_id(),
    };
    assert!(matches!(
        receive_control(control.clone(), &attacker.identity),
        Err(CoreError::VerificationFailed)
    ));
    assert!(receive_control(control.clone(), &admin.identity).unwrap());
    assert!(!receive_control(control, &admin.identity).unwrap());
    snapshot.management.revision = 2;
    snapshot.management.policy.send_messages = false;
    assert!(
        receive_control(
            Control::Snapshot {
                group: snapshot.clone(),
                notice: "Scrittura limitata".to_owned(),
                event_id: new_id()
            },
            &admin.identity
        )
        .unwrap()
    );
    activate(&directory, "Member");
    assert!(!can_write(&current_group(&snapshot.id).unwrap().unwrap()).unwrap());
    snapshot.management.revision = 1;
    snapshot.management.policy.send_messages = true;
    assert!(
        !receive_control(
            Control::Snapshot {
                group: snapshot.clone(),
                notice: "Vecchio stato".to_owned(),
                event_id: new_id()
            },
            &admin.identity
        )
        .unwrap()
    );
    snapshot.management.revision = 3;
    snapshot.management.closed = true;
    receive_control(
        Control::Snapshot {
            group: snapshot.clone(),
            notice: "Gruppo chiuso".to_owned(),
            event_id: new_id(),
        },
        &admin.identity,
    )
    .unwrap();
    assert!(
        list_conversations().unwrap()["conversations"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        list_messages(&snapshot.id, None, None, None).unwrap()["messages"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    snapshot.management.revision = 4;
    snapshot.management.closed = false;
    assert!(matches!(
        receive_control(
            Control::Snapshot {
                group: snapshot.clone(),
                notice: "Riapri".to_owned(),
                event_id: new_id()
            },
            &admin.identity
        ),
        Err(CoreError::GroupClosed)
    ));
    snapshot.id = "close-before-invite".to_owned();
    snapshot.management.closed = true;
    assert!(
        receive_control(
            Control::Snapshot {
                group: snapshot.clone(),
                notice: "Chiusura fuori ordine".to_owned(),
                event_id: new_id()
            },
            &admin.identity
        )
        .unwrap()
    );
    activate(&directory, "Member");
    assert!(
        current_group(&snapshot.id)
            .unwrap()
            .unwrap()
            .management
            .closed
    );
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn delegated_requests_cannot_inject_candidates_or_escalate_roles_and_replies_validate() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-group-requests-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let member = fixture(&directory, "Member");
    activate(&directory, "Admin");
    let mut local = group(&admin, vec![member.clone()], "group");
    local.admin_id = "me".to_owned();
    local.management.admins.insert(
        member.id.clone(),
        AdminPermissions {
            change_info: true,
            ..AdminPermissions::default()
        },
    );
    save(local.clone()).unwrap();
    let request = Request {
        id: new_id(),
        actor: member.id.clone(),
        action: Action::Info {
            name: "Nuovo nome".to_owned(),
            description: String::new(),
        },
        candidate: None,
    };
    assert!(
        receive_control(
            Control::Request {
                group_id: local.id.clone(),
                request: request.clone()
            },
            &member.identity
        )
        .unwrap()
    );
    assert!(
        !receive_control(
            Control::Request {
                group_id: local.id.clone(),
                request: request.clone()
            },
            &member.identity
        )
        .unwrap()
    );
    let mut forged = request.clone();
    forged.id = new_id();
    forged.candidate = Some(member.clone());
    assert!(matches!(
        receive_control(
            Control::Request {
                group_id: local.id.clone(),
                request: forged
            },
            &member.identity
        ),
        Err(CoreError::GroupPermissionDenied)
    ));
    let mut forged = request;
    forged.id = new_id();
    forged.action = Action::Policy {
        policy: Policy::default(),
    };
    assert!(matches!(
        receive_control(
            Control::Request {
                group_id: local.id.clone(),
                request: forged
            },
            &member.identity
        ),
        Err(CoreError::GroupPermissionDenied)
    ));
    activate(&directory, "Admin");
    assert_eq!(
        current_group(&local.id)
            .unwrap()
            .unwrap()
            .management
            .requests
            .len(),
        1
    );
    let encoded = encode_text("Risposta con #tag", Some("original-id")).unwrap();
    assert_eq!(
        text_metadata(&encoded).unwrap(),
        (
            "Risposta con #tag".to_owned(),
            Some("original-id".to_owned())
        )
    );
    assert!(text_metadata("sylphy-group-text-v1:bad!").is_err());
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn owner_is_recognized_by_identity_even_when_device_number_changes() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    let directory = std::env::temp_dir().join(format!("sylphy-owner-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let member = fixture(&directory, "Member");
    activate(&directory, "Admin");
    let mut group = group(&admin, vec![member], "group");
    let mut endpoint = admin.identity.clone();
    let key = endpoint.bundle.signal_pre_key.as_mut().unwrap();
    key.device_id = if key.device_id == 1 { 2 } else { 1 };
    group.management.coordinator = Some(endpoint);
    assert!(is_coordinator(&group).unwrap());
    activate(&directory, "Member");
    assert!(!is_coordinator(&group).unwrap());
    fs::remove_dir_all(directory).unwrap();
}

fn take_controls() -> Vec<Vec<u8>> {
    let mut store = contact_store().lock().unwrap();
    let payloads = store
        .outbox
        .iter()
        .filter(|delivery| delivery.is_control)
        .map(|delivery| delivery.payload.clone())
        .collect();
    let retained = store
        .outbox
        .iter()
        .filter(|delivery| !delivery.is_control)
        .cloned()
        .collect::<Vec<_>>();
    persist_outbox(store.outbox_path.as_deref().unwrap(), &retained).unwrap();
    store.outbox = retained;
    payloads
}

#[test]
fn departure_is_durable_blocks_resurrection_and_transfers_ownership() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    struct Cleanup;
    impl Drop for Cleanup {
        fn drop(&mut self) {
            TEST_BLOBS.with(|value| *value.borrow_mut() = None);
        }
    }
    let _cleanup = Cleanup;
    TEST_BLOBS.with(|value| *value.borrow_mut() = Some(HashMap::new()));
    let directory = std::env::temp_dir().join(format!("sylphy-departure-{}", new_id()));
    let owner = fixture(&directory, "Owner");
    let alice = fixture(&directory, "Alice");
    let bob = fixture(&directory, "Bob");
    activate(&directory, "Owner");
    let mut original = group(&owner, vec![alice.clone(), bob.clone()], "group");
    original.admin_id = "me".to_owned();
    original.management.coordinator = Some(owner.identity.clone());
    save(original.clone()).unwrap();
    // Removing every privilege leaves the admin role present in the core and UI model.
    act(
        &original.id,
        Action::SetAdmin {
            member_id: alice.id.clone(),
            permissions: Some(AdminPermissions::default()),
        },
    )
    .unwrap();
    let initial = take_controls();
    activate(&directory, "Alice");
    deliver_controls(&initial);
    assert!(is_admin(&current_group(&original.id).unwrap().unwrap()).unwrap());
    assert_eq!(
        list_conversations().unwrap()["conversations"][0]["is_admin"],
        true
    );
    let before_leave = current_group(&original.id).unwrap().unwrap();
    activate(&directory, "Bob");
    deliver_controls(&initial);
    // Prepare an update and text while Alice is still a member, then deliver them late.
    activate(&directory, "Owner");
    act(
        &original.id,
        Action::Info {
            name: "Aggiornamento ritardato".to_owned(),
            description: String::new(),
        },
    )
    .unwrap();
    let stale = take_controls();
    let device = alice.identity.delivery_devices().unwrap().remove(0);
    let body = format!(
        "{GROUP_MESSAGE_PREFIX}{}:{}",
        original.id,
        STANDARD_NO_PAD.encode("Messaggio ritardato")
    );
    let (late_message, _) = secure_packet::seal_for_test(&device, &body).unwrap();
    activate(&directory, "Alice");
    delete_conversation(&original.id).unwrap();
    let leave_event = contact_store()
        .lock()
        .unwrap()
        .device_sync_outbox
        .iter()
        .find_map(|pending| match &pending.event {
            DeviceSyncEvent::UpsertGroup { group } if group.management.left => {
                Some(pending.event.clone())
            }
            _ => None,
        })
        .expect("departure is queued for other account devices");
    // A second device may already know a newer group revision. Leaving still wins.
    let mut second_device = before_leave.clone();
    second_device.management.revision += 50;
    save(second_device).unwrap();
    apply_device_sync_plaintext(&serde_json::to_vec(&leave_event).unwrap()).unwrap();
    activate(&directory, "Alice"); // Departure intent and tombstone survive a restart.
    assert!(
        list_conversations().unwrap()["conversations"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    process_requests();
    // Simulate the crash boundary after sealing but before moving the departure
    // into the transport outbox, followed by a stale account snapshot.
    let sealed = contact_store().lock().unwrap().outbox[0].clone();
    let mut durable = current_group(&original.id).unwrap().unwrap();
    durable.management.outbound.push(sealed.clone());
    let mut delayed_sync = before_leave.clone();
    preserve_local_queues(&durable, &mut delayed_sync);
    assert_eq!(delayed_sync.management.outbound[0].id, sealed.id);
    assert!(delayed_sync.management.left);
    let departure = take_controls();
    deliver_controls(&stale);
    assert!(matches!(
        persist_inbound_payload(&late_message),
        Err(CoreError::GroupClosed)
    ));
    let mut stale_sync = before_leave.clone();
    stale_sync.management.revision += 100;
    apply_device_sync_plaintext(
        &serde_json::to_vec(&DeviceSyncEvent::UpsertGroup { group: stale_sync }).unwrap(),
    )
    .unwrap();
    assert!(
        current_group(&original.id)
            .unwrap()
            .unwrap()
            .management
            .left
    );
    assert!(
        list_conversations().unwrap()["conversations"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        list_messages(&original.id, None, None, None).unwrap()["messages"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    activate(&directory, "Bob");
    deliver_controls(&departure);
    deliver_controls(&stale); // Owner has not seen the departure yet.
    assert!(
        !current_group(&original.id)
            .unwrap()
            .unwrap()
            .members
            .iter()
            .any(|m| m.id == alice.id)
    );
    activate(&directory, "Owner");
    deliver_controls(&departure);
    assert!(
        !current_group(&original.id)
            .unwrap()
            .unwrap()
            .members
            .iter()
            .any(|m| m.id == alice.id)
    );
    // With no remaining admins the owner hands off to Bob, without closing the group.
    delete_conversation(&original.id).unwrap();
    process_requests();
    let handoff = take_controls();
    activate(&directory, "Bob");
    deliver_controls(&handoff);
    let inherited = current_group(&original.id).unwrap().unwrap();
    assert_eq!(inherited.admin_id, "me");
    assert!(is_coordinator(&inherited).unwrap());
    assert!(inherited.members.is_empty());
    assert!(!inherited.management.closed);
    assert_eq!(
        details(&original.id).unwrap()["members"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    // Preference uses the role, even for an admin with no extra privileges.
    let mut choose_admin = original;
    choose_admin
        .management
        .admins
        .insert(alice.id.clone(), AdminPermissions::default());
    activate(&directory, "Owner");
    prepare_leave(&mut choose_admin).unwrap();
    assert_eq!(
        choose_admin.management.pending_departure.unwrap().successor,
        Some(alice.id)
    );
    fs::remove_dir_all(directory).unwrap();
}

fn deliver_controls(packets: &[Vec<u8>]) {
    let mut received = 0;
    for packet in packets {
        if secure_packet::inspect(packet).is_ok() {
            persist_inbound_payload_with(packet, fetch_bytes).unwrap();
            received += 1;
        }
    }
    assert!(received > 0);
}

#[test]
fn encrypted_management_round_trip_delegation_join_link_revocation_removal_and_close() {
    let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
    struct Cleanup;
    impl Drop for Cleanup {
        fn drop(&mut self) {
            TEST_BLOBS.with(|storage| *storage.borrow_mut() = None);
        }
    }
    let _cleanup = Cleanup;
    TEST_BLOBS.with(|storage| *storage.borrow_mut() = Some(HashMap::new()));
    let directory = std::env::temp_dir().join(format!("sylphy-group-round-trip-{}", new_id()));
    let admin = fixture(&directory, "Admin");
    let alice = fixture(&directory, "Alice");
    let bob = fixture(&directory, "Bob");
    activate(&directory, "Admin");
    let mut local = group(&admin, vec![alice.clone()], "channel");
    local.admin_id = "me".to_owned();
    local.management.coordinator = Some(admin.identity.clone());
    save(local.clone()).unwrap();
    act(
        &local.id,
        Action::Policy {
            policy: Policy {
                send_messages: false,
                ..Policy::default()
            },
        },
    )
    .unwrap();
    validate_account_backup(&export_account_backup().unwrap()).unwrap();
    let packets = take_controls();
    activate(&directory, "Alice");
    deliver_controls(&packets);
    assert!(!can_write(&current_group(&local.id).unwrap().unwrap()).unwrap());
    activate(&directory, "Admin");
    act(
        &local.id,
        Action::SetAdmin {
            member_id: alice.id.clone(),
            permissions: Some(AdminPermissions {
                change_info: true,
                invite_members: true,
                ..AdminPermissions::default()
            }),
        },
    )
    .unwrap();
    let packets = take_controls();
    activate(&directory, "Alice");
    deliver_controls(&packets);
    assert_eq!(
        act(
            &local.id,
            Action::Info {
                name: "Team aggiornato".to_owned(),
                description: "Gestito da Alice".to_owned()
            }
        )
        .unwrap()["state"],
        "pending_owner"
    );
    let packets = take_controls();
    activate(&directory, "Admin");
    deliver_controls(&packets);
    process_requests();
    assert_eq!(
        current_group(&local.id).unwrap().unwrap().name,
        "Team aggiornato"
    );
    let packets = take_controls();
    activate(&directory, "Alice");
    deliver_controls(&packets);
    assert_eq!(details(&local.id).unwrap()["name"], "Team aggiornato");
    assert!(matches!(
        act(
            &local.id,
            Action::Policy {
                policy: Policy::default()
            }
        ),
        Err(CoreError::GroupPermissionDenied)
    ));
    activate(&directory, "Admin");
    act(&local.id, Action::InviteLink).unwrap();
    let link = details(&local.id).unwrap()["invite_link"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(link.len() < 2048);
    let packets = take_controls();
    activate(&directory, "Alice");
    deliver_controls(&packets);
    activate(&directory, "Bob");
    assert_eq!(join(&link).unwrap()["state"], "pending_owner");
    let packets = take_controls();
    activate(&directory, "Admin");
    deliver_controls(&packets);
    process_requests();
    assert!(
        current_group(&local.id)
            .unwrap()
            .unwrap()
            .members
            .iter()
            .any(|member| member.id == bob.id)
    );
    let packets = take_controls();
    activate(&directory, "Bob");
    deliver_controls(&packets);
    assert!(
        !current_group(&local.id)
            .unwrap()
            .unwrap()
            .management
            .removed
    );
    activate(&directory, "Admin");
    act(&local.id, Action::RevokeInviteLink).unwrap();
    assert!(details(&local.id).unwrap()["invite_link"].is_null());
    assert!(matches!(
        receive_control(
            Control::Join {
                group_id: local.id.clone(),
                token: "forged".to_owned(),
                request_id: new_id()
            },
            &bob.identity
        ),
        Err(CoreError::GroupPermissionDenied)
    ));
    act(&local.id, Action::RemoveMember { member_id: bob.id }).unwrap();
    let packets = take_controls();
    activate(&directory, "Bob");
    deliver_controls(&packets);
    assert!(
        current_group(&local.id)
            .unwrap()
            .unwrap()
            .management
            .removed
    );
    activate(&directory, "Admin");
    act(&local.id, Action::Close).unwrap();
    let packets = take_controls();
    activate(&directory, "Alice");
    deliver_controls(&packets);
    assert!(current_group(&local.id).unwrap().unwrap().management.closed);
    assert!(
        list_conversations().unwrap()["conversations"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    fs::remove_dir_all(directory).unwrap();
}
