use super::*;

#[derive(Deserialize, Serialize)]
struct Preferences {
    version: u8,
    muted: HashSet<String>,
}

pub(super) fn load(path: &Path) -> CoreResult<HashSet<String>> {
    if !path.exists() {
        return Ok(HashSet::new());
    }
    if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > 512 * 1024 {
        return Err(CoreError::LimitExceeded);
    }
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let plaintext = vault::open_with_key(&identity::active_identity()?.storage_key()?, &encrypted)?;
    let preferences: Preferences =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    if preferences.version != 1 || preferences.muted.len() > 2 * MAX_CONTACTS {
        return Err(CoreError::VerificationFailed);
    }
    for id in &preferences.muted {
        validate_conversation_id(id)?;
    }
    Ok(preferences.muted)
}

pub(super) fn set_muted(conversation_id: &str, muted: bool) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    if !store
        .contacts
        .iter()
        .any(|contact| contact.id == conversation_id)
        && !store.groups.iter().any(|group| {
            group.id == conversation_id && !group.management.left && !group.management.closed
        })
    {
        return Err(CoreError::InvalidInput);
    }
    let mut updated = store.muted_conversations.clone();
    // Drop preferences for conversations that no longer exist on this device.
    updated.retain(|id| {
        store.contacts.iter().any(|contact| &contact.id == id)
            || store
                .groups
                .iter()
                .any(|group| &group.id == id && !group.management.left && !group.management.closed)
    });
    if muted {
        updated.insert(conversation_id.to_owned());
    } else {
        updated.remove(conversation_id);
    }
    if updated.len() > 2 * MAX_CONTACTS {
        return Err(CoreError::LimitExceeded);
    }
    let encoded = zeroize::Zeroizing::new(
        serde_json::to_vec(&Preferences {
            version: 1,
            muted: updated.clone(),
        })
        .map_err(|_| CoreError::Internal)?,
    );
    let encrypted = vault::seal_with_key(&identity::active_identity()?.storage_key()?, &encoded)?;
    persist_bytes(
        store
            .notification_preferences_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &encrypted,
    )?;
    store.muted_conversations = updated;
    store.revision = store.revision.wrapping_add(1);
    Ok(json!({"conversation_id": conversation_id, "is_muted": muted}))
}

type IncomingId = (String, String, String);

fn incoming_id(message: &StoredMessage) -> IncomingId {
    (
        message.conversation_id.clone(),
        message.author_id.clone(),
        message.id.clone(),
    )
}

pub(super) fn incoming_ids(store: &ContactStore) -> HashSet<IncomingId> {
    store
        .messages
        .iter()
        .filter(|message| !message.is_outgoing && !message.is_read)
        .map(incoming_id)
        .collect()
}

pub(super) fn count_new(store: &ContactStore, before: &HashSet<IncomingId>) -> usize {
    store
        .messages
        .iter()
        .filter(|message| {
            !message.is_outgoing
                && !message.is_read
                && !before.contains(&incoming_id(message))
                && !store.muted_conversations.contains(&message.conversation_id)
        })
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn muted_chats_keep_incoming_messages_without_alerting_or_replaying_old_alerts() {
        let mut old = super::super::tests::history_message(1);
        old.is_outgoing = false;
        old.is_read = false;
        let mut store = ContactStore {
            messages: vec![old.clone()],
            ..Default::default()
        };
        let before = incoming_ids(&store);
        let mut incoming = old.clone();
        incoming.id = "new".into();
        store.messages.push(incoming);
        store.muted_conversations.insert("chat".into());
        assert_eq!(count_new(&store, &before), 0);
        assert_eq!(store.messages.len(), 2);
        // Another conversation can use the same message ID and still alert.
        let mut other = old.clone();
        other.conversation_id = "other".into();
        store.messages.push(other);
        assert_eq!(count_new(&store, &before), 1);
        // Unmuting applies only to messages received after the next snapshot.
        let after = incoming_ids(&store);
        store.muted_conversations.clear();
        assert_eq!(count_new(&store, &after), 0);
        let mut unread = old.clone();
        unread.id = "unmuted".into();
        store.messages.push(unread);
        assert_eq!(count_new(&store, &after), 1);
        let mut outgoing = old;
        outgoing.id = "outgoing".into();
        outgoing.is_outgoing = true;
        store.messages.push(outgoing);
        assert_eq!(count_new(&store, &after), 1);
    }

    #[test]
    fn preferences_survive_restart_and_failed_writes_leave_previous_state() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory = std::env::temp_dir().join(format!("sylphy-mute-{}", groups::new_id()));
        let root = directory.to_string_lossy();
        identity::ensure_identity(&root, "notification-test-secret", None, None).unwrap();
        let bundle = identity::active_identity()
            .unwrap()
            .public_bundle(None)
            .unwrap();
        let contact = StoredContact {
            id: contact_id(&bundle.identity_ed25519),
            display_name: "Contact".into(),
            fingerprint: fingerprint(&bundle.identity_ed25519),
            added_at_ms: 1,
            bundle,
            published_identity: None,
            verified: false,
            invitation_code: None,
            previous_bundles: vec![],
        };
        let id = contact.id.clone();
        let saved = std::mem::take(&mut *contact_store().lock().unwrap());
        configure_storage(&root).unwrap();
        {
            let mut store = contact_store().lock().unwrap();
            persist_contacts(
                store.path.as_deref().unwrap(),
                std::slice::from_ref(&contact),
            )
            .unwrap();
            store.contacts.push(contact);
            store.groups.push(StoredGroup {
                id: "group".into(),
                name: "Group".into(),
                description: String::new(),
                mode: "group".into(),
                admin_id: "me".into(),
                created_at_ms: 1,
                members: vec![],
                management: Default::default(),
            });
            persist_groups(store.groups_path.as_deref().unwrap(), &store.groups).unwrap();
        }
        assert!(
            !list_conversations().unwrap()["conversations"][0]["is_muted"]
                .as_bool()
                .unwrap()
        );
        set_muted(&id, true).unwrap();
        set_muted("group", true).unwrap();
        let path = directory.join("messaging/conversation-notifications-v1.vault");
        assert!(!String::from_utf8_lossy(&fs::read(&path).unwrap()).contains(&id));
        configure_storage(&root).unwrap();
        assert_eq!(
            list_conversations().unwrap()["conversations"][0]["is_muted"],
            true
        );
        assert_eq!(
            list_conversations().unwrap()["conversations"][1]["is_muted"],
            true
        );
        let revision = contact_store().lock().unwrap().revision;
        let missing_parent = directory.join("not-a-directory");
        fs::write(&missing_parent, b"blocked").unwrap();
        contact_store()
            .lock()
            .unwrap()
            .notification_preferences_path = Some(missing_parent.join("preferences"));
        assert!(set_muted(&id, false).is_err());
        {
            let store = contact_store().lock().unwrap();
            assert!(store.muted_conversations.contains(&id));
            assert_eq!(store.revision, revision);
        }
        configure_storage(&root).unwrap();
        set_muted(&id, false).unwrap();
        configure_storage(&root).unwrap();
        assert_eq!(
            list_conversations().unwrap()["conversations"][0]["is_muted"],
            false
        );
        assert_eq!(
            list_conversations().unwrap()["conversations"][1]["is_muted"],
            true
        );
        set_muted("group", false).unwrap();
        configure_storage(&root).unwrap();
        assert_eq!(
            list_conversations().unwrap()["conversations"][1]["is_muted"],
            false
        );
        assert!(set_muted("unknown", true).is_err());
        *contact_store().lock().unwrap() = saved;
        fs::remove_dir_all(directory).unwrap();
    }
}
