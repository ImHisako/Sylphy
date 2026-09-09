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
