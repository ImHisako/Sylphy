use std::{
    collections::{HashMap, HashSet},
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::Aead};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{
    atomic_file,
    bundle::PublicBundle,
    error::{CoreError, CoreResult},
    identity,
    peer_identity::PublishedIdentity,
    secure_packet, vault, veilid_adapter,
};

const MAX_CONVERSATION_ID_BYTES: usize = 128;
const MAX_DISPLAY_NAME_CHARS: usize = 64;
const MAX_INVITATION_TEXT_BYTES: usize = 64 * 1024;
const MAX_CONTACT_STORE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_MESSAGE_STORE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_CONTACTS: usize = 1024;
const MAX_MESSAGES: usize = 100_000;
const MAX_OUTBOX_DELIVERIES: usize = 4096;
const MAX_ATTACHMENT_BYTES: usize = 700 * 1024;
const MAX_ATTACHMENT_NAME_CHARS: usize = 128;
const MAX_MESSAGE_BODY_BYTES: usize = 16 * 1024;
const MAX_MESSAGE_ID_BYTES: usize = 128;
const MAX_CLOCK_SKEW_MS: u64 = 5 * 60 * 1000;
const DEFAULT_MESSAGE_PAGE_SIZE: usize = 120;
const MAX_MESSAGE_PAGE_SIZE: usize = 500;
const ATTACHMENT_PREFIX: &str = "sylphy-attachment-v1:";
const DEVICE_SYNC_PREFIX: &[u8] = b"SYLPHY-DEVICE-SYNC-V1\0";
const CONTACT_STORE_FILE: &str = "contacts-v2.vault";
const LEGACY_CONTACT_STORE_FILE: &str = "contacts-v1.json";
const MESSAGE_STORE_FILE: &str = "messages-v1.vault";
const MESSAGE_LOG_FILE: &str = "messages-v2.log";
const OUTBOX_FILE: &str = "outbox-v1.vault";
const ATTACHMENT_LEASE_FILE: &str = "attachment-leases-v1.vault";
const DEVICE_SYNC_OUTBOX_FILE: &str = "device-sync-outbox-v1.vault";
const ATTACHMENT_RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;
const MESSAGE_LOG_MAGIC: &[u8; 4] = b"SLM2";
const MESSAGE_LOG_COMPACT_BYTES: u64 = 48 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredContact {
    id: String,
    display_name: String,
    fingerprint: String,
    added_at_ms: u64,
    bundle: PublicBundle,
    #[serde(default)]
    published_identity: Option<PublishedIdentity>,
    #[serde(default)]
    verified: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    invitation_code: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredMessage {
    id: String,
    conversation_id: String,
    author_id: String,
    body: String,
    sent_at_ms: u64,
    is_outgoing: bool,
    #[serde(default)]
    is_read: bool,
    #[serde(default = "default_delivery_state")]
    delivery_state: String,
    #[serde(default)]
    attachment_name: Option<String>,
    #[serde(default)]
    attachment_base64: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct MessagingAccountBackup {
    version: u8,
    contacts: Vec<StoredContact>,
    messages: Vec<StoredMessage>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum MessageEvent {
    Upsert { message: StoredMessage },
    DeleteMessage { message_id: String },
    MarkRead { conversation_id: String },
    DeleteConversation { conversation_id: String },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum DeviceSyncEvent {
    UpsertContact {
        contact: StoredContact,
    },
    UpsertMessage {
        contact: StoredContact,
        message: StoredMessage,
    },
}

#[derive(Debug, Deserialize, Serialize)]
struct AttachmentPointer {
    version: u8,
    file_name: String,
    size: usize,
    record_key: String,
    chunk_count: u16,
    key_base64: String,
    nonce_base64: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PendingDelivery {
    id: String,
    message_id: String,
    route_blob: Vec<u8>,
    payload: Vec<u8>,
    created_at_ms: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct AttachmentLease {
    record_key: String,
    chunk_count: u16,
    delete_after_ms: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PendingDeviceSync {
    id: String,
    event: DeviceSyncEvent,
}

#[derive(Default)]
struct ContactStore {
    path: Option<PathBuf>,
    message_path: Option<PathBuf>,
    legacy_message_path: Option<PathBuf>,
    outbox_path: Option<PathBuf>,
    attachment_lease_path: Option<PathBuf>,
    device_sync_outbox_path: Option<PathBuf>,
    contacts: Vec<StoredContact>,
    messages: Vec<StoredMessage>,
    messages_loaded: bool,
    message_event_count: usize,
    outbox: Vec<PendingDelivery>,
    attachment_leases: Vec<AttachmentLease>,
    device_sync_outbox: Vec<PendingDeviceSync>,
    revision: u64,
}

static CONTACT_STORE: OnceLock<Mutex<ContactStore>> = OnceLock::new();
static ALLOW_UNKNOWN_CONTACTS: OnceLock<Mutex<bool>> = OnceLock::new();

fn contact_store() -> &'static Mutex<ContactStore> {
    CONTACT_STORE.get_or_init(|| Mutex::new(ContactStore::default()))
}

pub fn configure_privacy(allow_unknown_contacts: bool) -> CoreResult<()> {
    *ALLOW_UNKNOWN_CONTACTS
        .get_or_init(|| Mutex::new(true))
        .lock()
        .map_err(|_| CoreError::Internal)? = allow_unknown_contacts;
    Ok(())
}

fn allows_unknown_contacts() -> CoreResult<bool> {
    Ok(*ALLOW_UNKNOWN_CONTACTS
        .get_or_init(|| Mutex::new(true))
        .lock()
        .map_err(|_| CoreError::Internal)?)
}

pub fn configure_storage(storage_directory: &str) -> CoreResult<()> {
    if storage_directory.trim().is_empty() || storage_directory.len() > 4096 {
        return Err(CoreError::InvalidInput);
    }
    let directory = PathBuf::from(storage_directory).join("messaging");
    fs::create_dir_all(&directory).map_err(|_| CoreError::Internal)?;
    let path = directory.join(CONTACT_STORE_FILE);
    let legacy_path = directory.join(LEGACY_CONTACT_STORE_FILE);
    let (contacts, migrated) = load_contacts(&path, &legacy_path)?;
    if migrated {
        persist_contacts(&path, &contacts)?;
        remove_private_file(&legacy_path)?;
    }
    let outbox_path = directory.join(OUTBOX_FILE);
    let outbox = load_outbox(&outbox_path)?;
    let attachment_lease_path = directory.join(ATTACHMENT_LEASE_FILE);
    let attachment_leases = load_attachment_leases(&attachment_lease_path)?;
    let device_sync_outbox_path = directory.join(DEVICE_SYNC_OUTBOX_FILE);
    let device_sync_outbox = load_device_sync_outbox(&device_sync_outbox_path)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    store.path = Some(path);
    store.message_path = Some(directory.join(MESSAGE_LOG_FILE));
    store.legacy_message_path = Some(directory.join(MESSAGE_STORE_FILE));
    store.outbox_path = Some(outbox_path);
    store.attachment_lease_path = Some(attachment_lease_path);
    store.device_sync_outbox_path = Some(device_sync_outbox_path);
    store.contacts = contacts;
    store.messages.clear();
    store.messages_loaded = false;
    store.message_event_count = 0;
    store.outbox = outbox;
    store.attachment_leases = attachment_leases;
    store.device_sync_outbox = device_sync_outbox;
    store.revision = 0;
    Ok(())
}

pub(crate) fn export_account_backup() -> CoreResult<Value> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    serde_json::to_value(MessagingAccountBackup {
        version: 1,
        contacts: store.contacts.clone(),
        messages: store.messages.clone(),
    })
    .map_err(|_| CoreError::Internal)
}

pub(crate) fn import_account_backup(value: Value) -> CoreResult<()> {
    validate_account_backup(&value)?;
    let backup: MessagingAccountBackup =
        serde_json::from_value(value).map_err(|_| CoreError::VerificationFailed)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    persist_contacts(&contact_path, &backup.contacts)?;
    write_message_snapshot(&message_path, &backup.messages)?;
    store.contacts = backup.contacts;
    store.messages = backup.messages;
    store.messages_loaded = true;
    store.message_event_count = store.messages.len();
    store.revision = store.revision.wrapping_add(1);
    Ok(())
}

pub(crate) fn validate_account_backup(value: &Value) -> CoreResult<()> {
    let backup: MessagingAccountBackup =
        serde_json::from_value(value.clone()).map_err(|_| CoreError::VerificationFailed)?;
    if backup.version != 1
        || backup.contacts.len() > MAX_CONTACTS
        || backup.messages.len() > MAX_MESSAGES
    {
        return Err(CoreError::LimitExceeded);
    }
    for contact in &backup.contacts {
        validate_conversation_id(&contact.id)?;
        validate_display_name(&contact.display_name)?;
        contact.bundle.validate()?;
        if contact.id != contact_id(&contact.bundle.identity_ed25519)
            || contact.fingerprint != fingerprint(&contact.bundle.identity_ed25519)
        {
            return Err(CoreError::VerificationFailed);
        }
        if let Some(published) = &contact.published_identity {
            published.validate()?;
            if published.bundle.identity_ed25519 != contact.bundle.identity_ed25519 {
                return Err(CoreError::VerificationFailed);
            }
        }
    }
    validate_backup_messages(&backup.contacts, &backup.messages)
}

fn validate_backup_messages(
    contacts: &[StoredContact],
    messages: &[StoredMessage],
) -> CoreResult<()> {
    let contact_ids = contacts
        .iter()
        .map(|contact| contact.id.as_str())
        .collect::<HashSet<_>>();
    let mut message_ids = HashSet::with_capacity(messages.len());
    for message in messages {
        validate_stored_message(message)?;
        if !contact_ids.contains(message.conversation_id.as_str())
            || (!message.is_outgoing && message.author_id != message.conversation_id)
            || (message.is_outgoing && message.author_id != "me")
            || !message_ids.insert(message.id.as_str())
        {
            return Err(CoreError::VerificationFailed);
        }
    }
    Ok(())
}

fn validate_stored_message(message: &StoredMessage) -> CoreResult<()> {
    validate_conversation_id(&message.conversation_id)?;
    if message.id.is_empty()
        || message.id.len() > MAX_MESSAGE_ID_BYTES
        || message.id.chars().any(char::is_control)
        || message.author_id.is_empty()
        || message.author_id.len() > MAX_CONVERSATION_ID_BYTES
        || message.body.is_empty()
        || message.body.len() > MAX_MESSAGE_BODY_BYTES
        || !matches!(
            message.delivery_state.as_str(),
            "queued" | "sent" | "delivered" | "read"
        )
        || message.sent_at_ms > current_time_ms()?.saturating_add(MAX_CLOCK_SKEW_MS)
    {
        return Err(CoreError::VerificationFailed);
    }
    match (&message.attachment_name, &message.attachment_base64) {
        (None, None) => {}
        (Some(name), Some(encoded)) => {
            validate_attachment_name(name)?;
            if encoded.len() > (MAX_ATTACHMENT_BYTES * 4 / 3) + 8 {
                return Err(CoreError::LimitExceeded);
            }
            let bytes = STANDARD
                .decode(encoded)
                .map_err(|_| CoreError::VerificationFailed)?;
            if bytes.is_empty() || bytes.len() > MAX_ATTACHMENT_BYTES {
                return Err(CoreError::LimitExceeded);
            }
        }
        _ => return Err(CoreError::VerificationFailed),
    }
    Ok(())
}

pub fn list_conversations() -> CoreResult<Value> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let mut summaries: HashMap<&str, (Option<&StoredMessage>, usize)> = HashMap::new();
    for message in &store.messages {
        let summary = summaries
            .entry(message.conversation_id.as_str())
            .or_insert((None, 0));
        if summary
            .0
            .is_none_or(|current| current.sent_at_ms <= message.sent_at_ms)
        {
            summary.0 = Some(message);
        }
        if !message.is_outgoing && !message.is_read {
            summary.1 += 1;
        }
    }
    let conversations = store
        .contacts
        .iter()
        .map(|contact| {
            let public_profile = contact
                .published_identity
                .as_ref()
                .map(|identity| &identity.profile);
            let visible_name = public_profile
                .and_then(|profile| profile.display_name.as_deref())
                .unwrap_or(&contact.display_name);
            let (last, unread) = summaries
                .get(contact.id.as_str())
                .copied()
                .unwrap_or((None, 0));
            let can_message = contact.published_identity.is_some();
            json!({
                "id": contact.id,
                "name": visible_name,
                "initials": initials(visible_name),
                "avatar_base64": public_profile.and_then(|profile| profile.avatar_base64.as_deref()),
                "accent_value": accent_value(&contact.bundle.identity_ed25519),
                "last_message": last.map(|message| message.body.as_str()).unwrap_or(
                    if can_message { "Conversazione pronta" } else { "Aggiorna l'ID Sylphy del contatto" }
                ),
                "last_activity_ms": last.map(|message| message.sent_at_ms).unwrap_or(contact.added_at_ms),
                "unread_count": unread,
                "is_online": false,
                "is_group": false,
                "safety": if contact.verified { "verified" } else if can_message { "pending" } else { "refresh_required" },
                "fingerprint": contact.fingerprint,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "state": if store.path.is_some() { "ready" } else { "storage_unconfigured" },
        "can_send": store.contacts.iter().any(|contact| contact.published_identity.is_some()),
        "conversations": conversations,
        "revision": store.revision,
    }))
}

pub fn list_messages(
    conversation_id: &str,
    before_ms: Option<u64>,
    before_id: Option<&str>,
    limit: Option<usize>,
) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    if before_id.is_some() && before_ms.is_none() {
        return Err(CoreError::InvalidInput);
    }
    if let Some(id) = before_id
        && (id.is_empty() || id.len() > MAX_MESSAGE_ID_BYTES || id.chars().any(char::is_control))
    {
        return Err(CoreError::InvalidInput);
    }
    let limit = limit.unwrap_or(DEFAULT_MESSAGE_PAGE_SIZE);
    if limit == 0 || limit > MAX_MESSAGE_PAGE_SIZE {
        return Err(CoreError::LimitExceeded);
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let mut messages = store
        .messages
        .iter()
        .filter(|message| message.conversation_id == conversation_id)
        .filter(|message| match (before_ms, before_id) {
            (Some(before), Some(id)) => (message.sent_at_ms, message.id.as_str()) < (before, id),
            (Some(before), None) => message.sent_at_ms < before,
            (None, None) => true,
            (None, Some(_)) => false,
        })
        .cloned()
        .collect::<Vec<_>>();
    messages.sort_by(|left, right| {
        right
            .sent_at_ms
            .cmp(&left.sent_at_ms)
            .then_with(|| right.id.cmp(&left.id))
    });
    let has_more = messages.len() > limit;
    messages.truncate(limit);
    messages.reverse();
    let next_before_ms = messages.first().map(|message| message.sent_at_ms);
    let next_before_id = messages.first().map(|message| message.id.clone());
    Ok(json!({
        "conversation_id": conversation_id,
        "messages": messages.into_iter().map(message_json).collect::<Vec<_>>(),
        "next_before_ms": next_before_ms,
        "next_before_id": next_before_id,
        "has_more": has_more,
        "revision": store.revision,
    }))
}

pub fn add_contact(_legacy_display_name: &str, invitation_code: &str) -> CoreResult<Value> {
    let (bundle, published_identity) = decode_invitation(invitation_code)?;
    // A contact name is identity data, not local input. It is covered by the
    // Ed25519 signature of PublishedIdentity and therefore cannot be replaced
    // by the person importing the invitation.
    let published_identity = published_identity.ok_or(CoreError::VerificationFailed)?;
    let profile_name = published_identity
        .profile
        .display_name
        .as_deref()
        .map(validate_display_name)
        .transpose()?;
    let now_ms = current_time_ms()?;
    if bundle.expires_at_ms <= now_ms {
        return Err(CoreError::VerificationFailed);
    }
    let id = contact_id(&bundle.identity_ed25519);
    let fingerprint = fingerprint(&bundle.identity_ed25519);
    let normalized_name = profile_name.unwrap_or_else(|| {
        let suffix = fingerprint.replace(' ', "");
        let suffix = &suffix[suffix.len().saturating_sub(8)..];
        format!("Contatto Sylphy {suffix}")
    });
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    if store.path.is_none() {
        return Err(CoreError::FeatureUnavailable);
    }
    if store.contacts.iter().any(|contact| contact.id == id) {
        return Err(CoreError::VerificationFailed);
    }
    if store.contacts.len() >= MAX_CONTACTS {
        return Err(CoreError::LimitExceeded);
    }
    let contact = StoredContact {
        id: id.clone(),
        display_name: normalized_name,
        fingerprint: fingerprint.clone(),
        added_at_ms: now_ms,
        bundle,
        published_identity: Some(published_identity),
        verified: false,
        invitation_code: Some(invitation_code.trim().to_owned()),
    };
    let mut updated = store.contacts.clone();
    updated.push(contact);
    persist_contacts(
        store.path.as_deref().ok_or(CoreError::FeatureUnavailable)?,
        &updated,
    )?;
    store.contacts = updated;
    store.revision = store.revision.wrapping_add(1);
    let sync_contact = store.contacts.iter().find(|item| item.id == id).cloned();
    drop(store);
    if let Some(contact) = sync_contact {
        queue_device_sync(&DeviceSyncEvent::UpsertContact { contact });
    }
    Ok(json!({"contact_id": id, "fingerprint": fingerprint, "safety": "pending"}))
}

pub fn send_text(conversation_id: &str, plaintext: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let message_path = {
        let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        store
            .contacts
            .iter()
            .find(|contact| contact.id == conversation_id)
            .ok_or(CoreError::InvalidInput)?;
        store
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?
    };
    let recipient = refreshed_recipient(conversation_id)?;
    let (deliveries, message_id) = secure_packet::seal_for_all(&recipient, plaintext)?;
    let now_ms = current_time_ms()?;
    let message = StoredMessage {
        id: message_id.clone(),
        conversation_id: conversation_id.to_owned(),
        author_id: "me".to_owned(),
        body: plaintext.trim().to_owned(),
        sent_at_ms: now_ms,
        is_outgoing: true,
        is_read: true,
        delivery_state: "queued".to_owned(),
        attachment_name: None,
        attachment_base64: None,
    };
    queue_outgoing(&message_path, message.clone(), deliveries)?;
    let delivered = flush_outbox(Some(&message_id));
    Ok(json!({
        "message_id": message_id,
        "delivery_state": if delivered { "sent" } else { "queued" }
    }))
}

pub fn send_attachment(
    conversation_id: &str,
    file_name: &str,
    bytes_base64: &str,
) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let file_name = validate_attachment_name(file_name)?;
    let bytes = STANDARD
        .decode(bytes_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    if bytes.is_empty() || bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let message_path = {
        let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        store
            .contacts
            .iter()
            .find(|contact| contact.id == conversation_id)
            .ok_or(CoreError::InvalidInput)?;
        store
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?
    };
    let recipient = refreshed_recipient(conversation_id)?;
    let mut key = [0_u8; 32];
    let mut nonce = [0_u8; 24];
    OsRng.fill_bytes(&mut key);
    OsRng.fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new((&key).into());
    let encrypted = cipher
        .encrypt(XNonce::from_slice(&nonce), bytes.as_slice())
        .map_err(|_| CoreError::Internal)?;
    let (record_key, chunk_count) = veilid_adapter::publish_attachment_blob(&encrypted)?;
    if let Err(error) = register_attachment_lease(&record_key, chunk_count) {
        let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
        return Err(error);
    }
    let pointer = AttachmentPointer {
        version: 1,
        file_name: file_name.clone(),
        size: bytes.len(),
        record_key: record_key.clone(),
        chunk_count,
        key_base64: STANDARD_NO_PAD.encode(key),
        nonce_base64: STANDARD_NO_PAD.encode(nonce),
    };
    let control = format!(
        "{ATTACHMENT_PREFIX}{}",
        STANDARD_NO_PAD.encode(serde_json::to_vec(&pointer).map_err(|_| CoreError::Internal)?)
    );
    let (deliveries, message_id) = match secure_packet::seal_for_all(&recipient, &control) {
        Ok(value) => value,
        Err(error) => {
            let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
            remove_attachment_lease(&record_key);
            return Err(error);
        }
    };
    let now_ms = current_time_ms()?;
    let message = StoredMessage {
        id: message_id.clone(),
        conversation_id: conversation_id.to_owned(),
        author_id: "me".to_owned(),
        body: format!("📎 {file_name}"),
        sent_at_ms: now_ms,
        is_outgoing: true,
        is_read: true,
        delivery_state: "queued".to_owned(),
        attachment_name: Some(file_name),
        attachment_base64: Some(STANDARD.encode(bytes)),
    };
    if let Err(error) = queue_outgoing(&message_path, message, deliveries) {
        let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
        remove_attachment_lease(&record_key);
        return Err(error);
    }
    let delivered = flush_outbox(Some(&message_id));
    Ok(json!({
        "message_id": message_id,
        "delivery_state": if delivered { "sent" } else { "queued" }
    }))
}

pub fn mark_conversation_read(conversation_id: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let changed = store.messages.iter().any(|message| {
        message.conversation_id == conversation_id && !message.is_outgoing && !message.is_read
    });
    if changed {
        append_message_event(
            &path,
            &MessageEvent::MarkRead {
                conversation_id: conversation_id.to_owned(),
            },
        )?;
        for message in &mut store.messages {
            if message.conversation_id == conversation_id && !message.is_outgoing {
                message.is_read = true;
            }
        }
        store.message_event_count += 1;
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
    }
    Ok(json!({"conversation_id": conversation_id, "read": true}))
}

pub fn delete_conversation(conversation_id: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let original_len = store.contacts.len();
    let updated = store
        .contacts
        .iter()
        .filter(|contact| contact.id != conversation_id)
        .cloned()
        .collect::<Vec<_>>();
    if updated.len() == original_len {
        return Err(CoreError::InvalidInput);
    }
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    ensure_messages_loaded(&mut store)?;
    let messages = store
        .messages
        .iter()
        .filter(|message| message.conversation_id != conversation_id)
        .cloned()
        .collect::<Vec<_>>();
    persist_contacts(&contact_path, &updated)?;
    append_message_event(
        &message_path,
        &MessageEvent::DeleteConversation {
            conversation_id: conversation_id.to_owned(),
        },
    )?;
    store.contacts = updated;
    store.messages = messages;
    store.message_event_count += 1;
    store.revision = store.revision.wrapping_add(1);
    compact_message_log_if_needed(&mut store)?;
    Ok(json!({"conversation_id": conversation_id, "deleted": true}))
}

pub fn set_contact_verified(conversation_id: &str, verified: bool) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let mut updated = store.contacts.clone();
    let contact = updated
        .iter_mut()
        .find(|contact| contact.id == conversation_id)
        .ok_or(CoreError::InvalidInput)?;
    contact.verified = verified;
    persist_contacts(
        store.path.as_deref().ok_or(CoreError::FeatureUnavailable)?,
        &updated,
    )?;
    store.contacts = updated;
    store.revision = store.revision.wrapping_add(1);
    Ok(json!({
        "conversation_id": conversation_id,
        "safety": if verified { "verified" } else { "pending" },
    }))
}

pub fn sync_inbound_messages() -> CoreResult<Value> {
    // Loading/decrypting a large vault can be expensive. This command is
    // always invoked on the Dart background executor, so warm it here before
    // synchronous UI reads access the in-memory message index.
    {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
    }
    let _ = flush_outbox(None);
    flush_device_sync_outbox();
    cleanup_expired_attachments();
    let payloads = veilid_adapter::take_inbound_payloads()?;
    let mut persisted = 0_usize;
    let mut discarded = 0_usize;
    for payload in payloads {
        match persist_inbound_payload(&payload.payload) {
            Ok(()) => {
                persisted += 1;
                veilid_adapter::acknowledge_inbound_payload(payload)?;
            }
            Err(error) if should_discard_inbound(&error) => {
                // A permanently invalid packet must not poison one of the
                // finite mailbox slots. Transient storage/network failures are
                // deliberately left unacknowledged and will be fetched again.
                discarded += 1;
                let _ = veilid_adapter::acknowledge_inbound_payload(payload);
            }
            Err(_) => {}
        }
    }
    let revision = contact_store()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .revision;
    Ok(json!({"persisted": persisted, "discarded": discarded, "revision": revision}))
}

fn should_discard_inbound(error: &CoreError) -> bool {
    matches!(
        error,
        CoreError::InvalidInput
            | CoreError::UnsupportedVersion
            | CoreError::AuthenticationFailed
            | CoreError::VerificationFailed
            | CoreError::LimitExceeded
    )
}

fn persist_inbound_payload(payload: &[u8]) -> CoreResult<()> {
    if let Some(encrypted) = payload.strip_prefix(DEVICE_SYNC_PREFIX) {
        return apply_device_sync(encrypted);
    }
    let inspected = secure_packet::inspect(payload)?;
    if inspected.sent_at_ms > current_time_ms()?.saturating_add(MAX_CLOCK_SKEW_MS) {
        return Err(CoreError::VerificationFailed);
    }
    let id = contact_id(&inspected.sender.bundle.identity_ed25519);
    {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
        let known = store.contacts.iter().any(|contact| contact.id == id);
        if !known && !allows_unknown_contacts()? {
            return Err(CoreError::AuthenticationFailed);
        }
        if store
            .messages
            .iter()
            .any(|message| message.id == inspected.message_id)
        {
            return Ok(());
        }
    }
    let mut opened = secure_packet::open(payload)?;
    // Attachment retrieval may perform network I/O and must never run while
    // the global contact/message store is locked.
    let (body, attachment_name, attachment_base64) = decode_incoming_content(&opened.plaintext)?;
    let message = StoredMessage {
        id: opened.message_id.clone(),
        conversation_id: id.clone(),
        author_id: id.clone(),
        body,
        sent_at_ms: opened.sent_at_ms,
        is_outgoing: false,
        is_read: false,
        delivery_state: "delivered".to_owned(),
        attachment_name,
        attachment_base64,
    };
    validate_stored_message(&message)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    ensure_messages_loaded(&mut store)?;
    if store.messages.iter().any(|item| item.id == message.id) {
        return Ok(());
    }
    if let Some(contact) = store.contacts.iter_mut().find(|contact| contact.id == id) {
        contact.bundle = opened.sender.bundle.clone();
        contact.published_identity = Some(opened.sender.clone());
    } else if allows_unknown_contacts()? && store.contacts.len() < MAX_CONTACTS {
        let contact_fingerprint = fingerprint(&opened.sender.bundle.identity_ed25519);
        let suffix = contact_fingerprint.replace(' ', "");
        let suffix = &suffix[suffix.len().saturating_sub(8)..];
        store.contacts.push(StoredContact {
            id: id.clone(),
            display_name: format!("Nuovo contatto {suffix}"),
            fingerprint: contact_fingerprint,
            added_at_ms: opened.sent_at_ms,
            bundle: opened.sender.bundle.clone(),
            published_identity: Some(opened.sender.clone()),
            verified: false,
            invitation_code: None,
        });
    } else {
        return Err(CoreError::AuthenticationFailed);
    }
    persist_contacts(&contact_path, &store.contacts)?;
    append_message_event(
        &message_path,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    )?;
    store.message_event_count += 1;
    store.messages.push(message.clone());
    store.revision = store.revision.wrapping_add(1);
    let sync_contact = store.contacts.iter().find(|item| item.id == id).cloned();
    drop(store);
    if let Err(error) = opened.commit_ratchet() {
        rollback_message(&message.id);
        return Err(error);
    }
    if let Ok(mut store) = contact_store().lock() {
        let _ = compact_message_log_if_needed(&mut store);
    }
    if let Some(contact) = sync_contact {
        let mut sync_message = message;
        if sync_message
            .attachment_base64
            .as_ref()
            .is_some_and(|value| value.len() > 20 * 1024)
        {
            sync_message.attachment_base64 = None;
            sync_message.attachment_name = None;
        }
        queue_device_sync(&DeviceSyncEvent::UpsertMessage {
            contact,
            message: sync_message,
        });
    }
    Ok(())
}

fn rollback_message(message_id: &str) {
    let Ok(mut store) = contact_store().lock() else {
        return;
    };
    let Some(message_path) = store.message_path.clone() else {
        return;
    };
    store.messages.retain(|message| message.id != message_id);
    if append_message_event(
        &message_path,
        &MessageEvent::DeleteMessage {
            message_id: message_id.to_owned(),
        },
    )
    .is_ok()
    {
        store.message_event_count += 1;
        store.revision = store.revision.wrapping_add(1);
    }
}

fn broadcast_device_sync(event: &DeviceSyncEvent) -> CoreResult<()> {
    let encoded = serde_json::to_vec(event).map_err(|_| CoreError::Internal)?;
    let encrypted = vault::seal_with_key(&identity::active_identity()?.storage_key()?, &encoded)?;
    let mut payload = Vec::with_capacity(DEVICE_SYNC_PREFIX.len() + encrypted.len());
    payload.extend_from_slice(DEVICE_SYNC_PREFIX);
    payload.extend_from_slice(&encrypted);
    let descriptor = identity::active_dht_descriptor()?.ok_or(CoreError::FeatureUnavailable)?;
    let published = veilid_adapter::resolve_owned_identity(&descriptor)?;
    let local_device_id = crate::ratchet_adapter::public_pre_key_bundle()?
        .ok_or(CoreError::UnsupportedVersion)?
        .device_id;
    let targets = published
        .delivery_devices()?
        .into_iter()
        .filter(|device| {
            device
                .bundle
                .signal_pre_key
                .as_ref()
                .is_some_and(|pre_key| pre_key.device_id != local_device_id)
        })
        .collect::<Vec<_>>();
    if targets.is_empty() {
        return Ok(());
    }
    let mut failed = false;
    for target in targets {
        if veilid_adapter::deliver_payload(&target.route_blob, None, payload.clone()).is_err() {
            failed = true;
        }
    }
    if !failed {
        return Ok(());
    }
    let mailbox =
        crate::peer_identity::current_public_mailbox().ok_or(CoreError::FeatureUnavailable)?;
    veilid_adapter::store_mailbox_payload(&mailbox, &payload)
}

fn queue_device_sync(event: &DeviceSyncEvent) {
    // Device synchronization is a secondary replication step. Once the local
    // mutation is durable it must never turn the primary operation into a
    // failure; mailbox delivery is retried by subsequent sync passes.
    let Ok(encoded) = serde_json::to_vec(event) else {
        return;
    };
    let pending = PendingDeviceSync {
        id: compact_hex(&Sha256::digest(&encoded)[..16]),
        event: event.clone(),
    };
    let stored = (|| -> CoreResult<()> {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        let path = store
            .device_sync_outbox_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        if store
            .device_sync_outbox
            .iter()
            .any(|item| item.id == pending.id)
        {
            return Ok(());
        }
        if store.device_sync_outbox.len() >= MAX_OUTBOX_DELIVERIES {
            return Err(CoreError::LimitExceeded);
        }
        store.device_sync_outbox.push(pending);
        if let Err(error) = persist_device_sync_outbox(&path, &store.device_sync_outbox) {
            store.device_sync_outbox.pop();
            return Err(error);
        }
        Ok(())
    })();
    if stored.is_ok() {
        flush_device_sync_outbox();
    }
}

fn flush_device_sync_outbox() {
    let pending = match contact_store().lock() {
        Ok(store) => store.device_sync_outbox.clone(),
        Err(_) => return,
    };
    let delivered = pending
        .iter()
        .filter(|item| broadcast_device_sync(&item.event).is_ok())
        .map(|item| item.id.clone())
        .collect::<HashSet<_>>();
    if delivered.is_empty() {
        return;
    }
    let Ok(mut store) = contact_store().lock() else {
        return;
    };
    let Some(path) = store.device_sync_outbox_path.clone() else {
        return;
    };
    let retained = store
        .device_sync_outbox
        .iter()
        .filter(|item| !delivered.contains(&item.id))
        .cloned()
        .collect::<Vec<_>>();
    if persist_device_sync_outbox(&path, &retained).is_ok() {
        store.device_sync_outbox = retained;
    }
}

fn queue_outgoing(
    message_path: &Path,
    message: StoredMessage,
    deliveries: Vec<secure_packet::SealedDelivery>,
) -> CoreResult<()> {
    let now_ms = current_time_ms()?;
    let pending = deliveries
        .into_iter()
        .map(|delivery| {
            let mut digest = Sha256::new();
            digest.update(message.id.as_bytes());
            digest.update(&delivery.route_blob);
            digest.update(&delivery.payload);
            PendingDelivery {
                id: compact_hex(&digest.finalize()[..16]),
                message_id: message.id.clone(),
                route_blob: delivery.route_blob,
                payload: delivery.payload,
                created_at_ms: now_ms,
            }
        })
        .collect::<Vec<_>>();
    if pending.is_empty() {
        return Err(CoreError::VerificationFailed);
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let outbox_path = store
        .outbox_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let original_len = store.outbox.len();
    if original_len.saturating_add(pending.len()) > MAX_OUTBOX_DELIVERIES {
        return Err(CoreError::LimitExceeded);
    }
    store.outbox.extend(pending);
    if let Err(error) = persist_outbox(&outbox_path, &store.outbox) {
        store.outbox.truncate(original_len);
        return Err(error);
    }
    if let Err(error) = append_message_event(
        message_path,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    ) {
        store.outbox.truncate(original_len);
        let _ = persist_outbox(&outbox_path, &store.outbox);
        return Err(error);
    }
    store.message_event_count += 1;
    store.messages.push(message);
    store.revision = store.revision.wrapping_add(1);
    compact_message_log_if_needed(&mut store)
}

fn flush_outbox(only_message_id: Option<&str>) -> bool {
    let pending = match contact_store().lock() {
        Ok(store) => store
            .outbox
            .iter()
            .filter(|item| only_message_id.is_none_or(|id| item.message_id == id))
            .cloned()
            .collect::<Vec<_>>(),
        Err(_) => return false,
    };
    if pending.is_empty() {
        return false;
    }
    let mut delivered_ids = HashSet::new();
    let mut delivered_messages = HashSet::new();
    for item in pending {
        if veilid_adapter::deliver_payload(&item.route_blob, None, item.payload).is_ok() {
            delivered_ids.insert(item.id);
            delivered_messages.insert(item.message_id);
        }
    }
    if delivered_ids.is_empty() {
        return false;
    }
    let sync_events = (|| -> CoreResult<Vec<DeviceSyncEvent>> {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        let outbox_path = store
            .outbox_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let message_path = store
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let retained = store
            .outbox
            .iter()
            .filter(|item| !delivered_ids.contains(&item.id))
            .cloned()
            .collect::<Vec<_>>();
        persist_outbox(&outbox_path, &retained)?;
        store.outbox = retained;
        let mut events = Vec::new();
        for message_id in delivered_messages {
            let Some(index) = store.messages.iter().position(|item| item.id == message_id) else {
                continue;
            };
            if store.messages[index].delivery_state == "queued" {
                store.messages[index].delivery_state = "sent".to_owned();
                let message = store.messages[index].clone();
                append_message_event(
                    &message_path,
                    &MessageEvent::Upsert {
                        message: message.clone(),
                    },
                )?;
                store.message_event_count += 1;
                if let Some(contact) = store
                    .contacts
                    .iter()
                    .find(|item| item.id == message.conversation_id)
                    .cloned()
                {
                    events.push(DeviceSyncEvent::UpsertMessage { contact, message });
                }
            }
        }
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
        Ok(events)
    })()
    .unwrap_or_default();
    for event in sync_events {
        queue_device_sync(&event);
    }
    true
}

fn refreshed_recipient(conversation_id: &str) -> CoreResult<PublishedIdentity> {
    let (current, invitation, contact_path) = {
        let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        let contact = store
            .contacts
            .iter()
            .find(|contact| contact.id == conversation_id)
            .ok_or(CoreError::InvalidInput)?;
        (
            contact
                .published_identity
                .clone()
                .ok_or(CoreError::FeatureUnavailable)?,
            contact.invitation_code.clone(),
            store.path.clone().ok_or(CoreError::FeatureUnavailable)?,
        )
    };
    let Some(invitation) = invitation else {
        return Ok(current);
    };
    let refreshed = match veilid_adapter::resolve_identity(&invitation) {
        Ok(value) => value,
        Err(_error) if current.bundle.expires_at_ms > current_time_ms()? => return Ok(current),
        Err(error) => return Err(error),
    };
    if refreshed.bundle.identity_ed25519 != current.bundle.identity_ed25519 {
        return Err(CoreError::VerificationFailed);
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    if let Some(contact) = store
        .contacts
        .iter_mut()
        .find(|contact| contact.id == conversation_id)
    {
        contact.bundle = refreshed.bundle.clone();
        contact.published_identity = Some(refreshed.clone());
        persist_contacts(&contact_path, &store.contacts)?;
        store.revision = store.revision.wrapping_add(1);
    }
    Ok(refreshed)
}

fn apply_device_sync(encrypted: &[u8]) -> CoreResult<()> {
    let plaintext = vault::open_with_key(&identity::active_identity()?.storage_key()?, encrypted)?;
    let event: DeviceSyncEvent =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    ensure_messages_loaded(&mut store)?;
    let mut changed = false;
    match event {
        DeviceSyncEvent::UpsertContact { contact } => {
            validate_conversation_id(&contact.id)?;
            contact.bundle.validate()?;
            if let Some(existing) = store.contacts.iter_mut().find(|item| item.id == contact.id) {
                if !same_contact(existing, &contact) {
                    *existing = contact;
                    changed = true;
                }
            } else if store.contacts.len() < MAX_CONTACTS {
                store.contacts.push(contact);
                changed = true;
            }
        }
        DeviceSyncEvent::UpsertMessage { contact, message } => {
            validate_conversation_id(&contact.id)?;
            validate_stored_message(&message)?;
            contact.bundle.validate()?;
            if let Some(existing) = store.contacts.iter_mut().find(|item| item.id == contact.id) {
                if !same_contact(existing, &contact) {
                    *existing = contact;
                    changed = true;
                }
            } else if store.contacts.len() < MAX_CONTACTS {
                store.contacts.push(contact);
                changed = true;
            }
            if !store.messages.iter().any(|item| item.id == message.id)
                && store.messages.len() < MAX_MESSAGES
            {
                append_message_event(
                    &message_path,
                    &MessageEvent::Upsert {
                        message: message.clone(),
                    },
                )?;
                store.messages.push(message);
                store.message_event_count += 1;
                changed = true;
            }
        }
    }
    if changed {
        persist_contacts(&contact_path, &store.contacts)?;
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
    }
    Ok(())
}

fn same_contact(first: &StoredContact, second: &StoredContact) -> bool {
    match (serde_json::to_vec(first), serde_json::to_vec(second)) {
        (Ok(first), Ok(second)) => first == second,
        _ => false,
    }
}

fn decode_invitation(code: &str) -> CoreResult<(PublicBundle, Option<PublishedIdentity>)> {
    let trimmed = code.trim();
    if trimmed.is_empty() || trimmed.len() > MAX_INVITATION_TEXT_BYTES {
        return Err(CoreError::InvalidInput);
    }
    if trimmed.starts_with("sylphy:VLD") || trimmed.starts_with("VLD") {
        let published = veilid_adapter::resolve_identity(trimmed)?;
        return Ok((published.bundle.clone(), Some(published)));
    }
    let normalized = trimmed.strip_prefix("sylphy:").unwrap_or(trimmed);
    let bytes = STANDARD_NO_PAD
        .decode(normalized)
        .map_err(|_| CoreError::InvalidInput)?;
    let bundle: PublicBundle =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidInput)?;
    bundle.validate()?;
    Ok((bundle, None))
}

fn load_contacts(path: &Path, legacy_path: &Path) -> CoreResult<(Vec<StoredContact>, bool)> {
    let (bytes, migrated) = if path.exists() {
        if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > MAX_CONTACT_STORE_BYTES + 64
        {
            return Err(CoreError::LimitExceeded);
        }
        let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
        let key = identity::active_identity()?.storage_key()?;
        (vault::open_with_key(&key, &encrypted)?.to_vec(), false)
    } else if legacy_path.exists() {
        if fs::metadata(legacy_path)
            .map_err(|_| CoreError::Internal)?
            .len()
            > MAX_CONTACT_STORE_BYTES
        {
            return Err(CoreError::LimitExceeded);
        }
        (
            fs::read(legacy_path).map_err(|_| CoreError::Internal)?,
            true,
        )
    } else {
        return Ok((Vec::new(), false));
    };
    if bytes.len() as u64 > MAX_CONTACT_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let contacts: Vec<StoredContact> =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::VerificationFailed)?;
    if contacts.len() > MAX_CONTACTS {
        return Err(CoreError::LimitExceeded);
    }
    for contact in &contacts {
        validate_conversation_id(&contact.id)?;
        validate_display_name(&contact.display_name)?;
        contact.bundle.validate()?;
        if let Some(published) = &contact.published_identity {
            published.validate()?;
        }
        if contact.fingerprint.is_empty() || contact.fingerprint.len() > 128 {
            return Err(CoreError::VerificationFailed);
        }
    }
    Ok((contacts, migrated))
}

fn persist_contacts(path: &Path, contacts: &[StoredContact]) -> CoreResult<()> {
    let encoded = serde_json::to_vec(contacts).map_err(|_| CoreError::Internal)?;
    if encoded.len() as u64 > MAX_CONTACT_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let key = identity::active_identity()?.storage_key()?;
    let encrypted = vault::seal_with_key(&key, &encoded)?;
    persist_bytes(path, &encrypted)
}

fn load_outbox(path: &Path) -> CoreResult<Vec<PendingDelivery>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > MAX_MESSAGE_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let key = identity::active_identity()?.storage_key()?;
    let plaintext = vault::open_with_key(&key, &encrypted)?;
    let entries: Vec<PendingDelivery> =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    if entries.len() > MAX_OUTBOX_DELIVERIES {
        return Err(CoreError::LimitExceeded);
    }
    for entry in &entries {
        if entry.id.is_empty()
            || entry.message_id.is_empty()
            || entry.route_blob.is_empty()
            || entry.route_blob.len() > 16 * 1024
            || entry.payload.is_empty()
            || entry.payload.len() > 32 * 1024
        {
            return Err(CoreError::VerificationFailed);
        }
    }
    Ok(entries)
}

fn persist_outbox(path: &Path, entries: &[PendingDelivery]) -> CoreResult<()> {
    if entries.len() > MAX_OUTBOX_DELIVERIES {
        return Err(CoreError::LimitExceeded);
    }
    let encoded = serde_json::to_vec(entries).map_err(|_| CoreError::Internal)?;
    if encoded.len() as u64 > MAX_MESSAGE_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let key = identity::active_identity()?.storage_key()?;
    let encrypted = vault::seal_with_key(&key, &encoded)?;
    persist_bytes(path, &encrypted)
}

fn load_attachment_leases(path: &Path) -> CoreResult<Vec<AttachmentLease>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let key = identity::active_identity()?.storage_key()?;
    let plaintext = vault::open_with_key(&key, &encrypted)?;
    let leases: Vec<AttachmentLease> =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    if leases.len() > MAX_OUTBOX_DELIVERIES
        || leases
            .iter()
            .any(|lease| lease.record_key.is_empty() || lease.chunk_count == 0)
    {
        return Err(CoreError::LimitExceeded);
    }
    Ok(leases)
}

fn persist_attachment_leases(path: &Path, leases: &[AttachmentLease]) -> CoreResult<()> {
    let encoded = serde_json::to_vec(leases).map_err(|_| CoreError::Internal)?;
    let key = identity::active_identity()?.storage_key()?;
    persist_bytes(path, &vault::seal_with_key(&key, &encoded)?)
}

fn load_device_sync_outbox(path: &Path) -> CoreResult<Vec<PendingDeviceSync>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let key = identity::active_identity()?.storage_key()?;
    let plaintext = vault::open_with_key(&key, &encrypted)?;
    let entries: Vec<PendingDeviceSync> =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    if entries.len() > MAX_OUTBOX_DELIVERIES {
        return Err(CoreError::LimitExceeded);
    }
    Ok(entries)
}

fn persist_device_sync_outbox(path: &Path, entries: &[PendingDeviceSync]) -> CoreResult<()> {
    let encoded = serde_json::to_vec(entries).map_err(|_| CoreError::Internal)?;
    let key = identity::active_identity()?.storage_key()?;
    persist_bytes(path, &vault::seal_with_key(&key, &encoded)?)
}

fn register_attachment_lease(record_key: &str, chunk_count: u16) -> CoreResult<()> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let path = store
        .attachment_lease_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let lease = AttachmentLease {
        record_key: record_key.to_owned(),
        chunk_count,
        delete_after_ms: current_time_ms()?.saturating_add(ATTACHMENT_RETENTION_MS),
    };
    store.attachment_leases.push(lease);
    if let Err(error) = persist_attachment_leases(&path, &store.attachment_leases) {
        store.attachment_leases.pop();
        return Err(error);
    }
    Ok(())
}

fn remove_attachment_lease(record_key: &str) {
    let Ok(mut store) = contact_store().lock() else {
        return;
    };
    let Some(path) = store.attachment_lease_path.clone() else {
        return;
    };
    store
        .attachment_leases
        .retain(|lease| lease.record_key != record_key);
    let _ = persist_attachment_leases(&path, &store.attachment_leases);
}

fn cleanup_expired_attachments() {
    let now_ms = current_time_ms().unwrap_or_default();
    let leases = match contact_store().lock() {
        Ok(store) => store
            .attachment_leases
            .iter()
            .filter(|lease| lease.delete_after_ms <= now_ms)
            .cloned()
            .collect::<Vec<_>>(),
        Err(_) => return,
    };
    for lease in leases {
        if veilid_adapter::delete_attachment_blob(&lease.record_key, lease.chunk_count).is_ok() {
            remove_attachment_lease(&lease.record_key);
        }
    }
}

fn remove_private_file(path: &Path) -> CoreResult<()> {
    if !path.exists() {
        return Ok(());
    }
    let length = fs::metadata(path).map_err(|_| CoreError::Internal)?.len();
    if length > 0 {
        let mut file = OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|_| CoreError::Internal)?;
        let zeros = vec![
            0_u8;
            usize::try_from(length.min(MAX_CONTACT_STORE_BYTES))
                .map_err(|_| CoreError::Internal)?
        ];
        file.write_all(&zeros).map_err(|_| CoreError::Internal)?;
        file.sync_all().map_err(|_| CoreError::Internal)?;
    }
    fs::remove_file(path).map_err(|_| CoreError::Internal)
}

fn ensure_messages_loaded(store: &mut ContactStore) -> CoreResult<()> {
    if store.messages_loaded {
        return Ok(());
    }
    let Some(path) = store.message_path.as_deref() else {
        store.messages = Vec::new();
        store.messages_loaded = true;
        return Ok(());
    };
    let (messages, event_count) = if path.exists() {
        load_message_log(path)?
    } else if let Some(legacy) = store
        .legacy_message_path
        .as_deref()
        .filter(|path| path.exists())
    {
        let messages = load_legacy_messages(legacy)?;
        write_message_snapshot(path, &messages)?;
        let count = messages.len();
        (messages, count)
    } else {
        (Vec::new(), 0)
    };
    store.messages = messages;
    store.message_event_count = event_count;
    store.messages_loaded = true;
    Ok(())
}

fn load_legacy_messages(path: &Path) -> CoreResult<Vec<StoredMessage>> {
    if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > MAX_MESSAGE_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let password = identity::active_identity()?.storage_password()?;
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let plaintext = vault::open(&password, &encrypted)?;
    let messages: Vec<StoredMessage> =
        serde_json::from_slice(plaintext.as_slice()).map_err(|_| CoreError::VerificationFailed)?;
    if messages.len() > MAX_MESSAGES {
        return Err(CoreError::LimitExceeded);
    }
    Ok(messages)
}

fn load_message_log(path: &Path) -> CoreResult<(Vec<StoredMessage>, usize)> {
    let bytes = fs::read(path).map_err(|_| CoreError::Internal)?;
    if bytes.len() as u64 > MAX_MESSAGE_STORE_BYTES || !bytes.starts_with(MESSAGE_LOG_MAGIC) {
        return Err(CoreError::VerificationFailed);
    }
    let key = identity::active_identity()?.storage_key()?;
    let mut messages = Vec::new();
    let mut cursor = MESSAGE_LOG_MAGIC.len();
    let mut event_count = 0_usize;
    while cursor < bytes.len() {
        if bytes.len() - cursor < 4 {
            break;
        }
        let length = u32::from_be_bytes(
            bytes[cursor..cursor + 4]
                .try_into()
                .map_err(|_| CoreError::VerificationFailed)?,
        ) as usize;
        if length == 0 || length > MAX_ATTACHMENT_BYTES * 2 {
            return Err(CoreError::VerificationFailed);
        }
        if bytes.len() - cursor - 4 < length {
            break;
        }
        let frame_end = cursor + 4 + length;
        let plaintext = vault::open_with_key(&key, &bytes[cursor + 4..frame_end])?;
        let event: MessageEvent =
            serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
        apply_message_event(&mut messages, event)?;
        event_count += 1;
        cursor = frame_end;
    }
    if cursor != bytes.len() {
        OpenOptions::new()
            .write(true)
            .open(path)
            .and_then(|file| file.set_len(cursor as u64))
            .map_err(|_| CoreError::Internal)?;
    }
    Ok((messages, event_count))
}

fn apply_message_event(messages: &mut Vec<StoredMessage>, event: MessageEvent) -> CoreResult<()> {
    match event {
        MessageEvent::Upsert { message } => {
            validate_conversation_id(&message.conversation_id)?;
            if messages.len() >= MAX_MESSAGES {
                return Err(CoreError::LimitExceeded);
            }
            if !messages.iter().any(|item| item.id == message.id) {
                messages.push(message);
            }
        }
        MessageEvent::DeleteMessage { message_id } => {
            messages.retain(|message| message.id != message_id);
        }
        MessageEvent::MarkRead { conversation_id } => {
            validate_conversation_id(&conversation_id)?;
            for message in messages {
                if message.conversation_id == conversation_id && !message.is_outgoing {
                    message.is_read = true;
                }
            }
        }
        MessageEvent::DeleteConversation { conversation_id } => {
            validate_conversation_id(&conversation_id)?;
            messages.retain(|message| message.conversation_id != conversation_id);
        }
    }
    Ok(())
}

fn append_message_event(path: &Path, event: &MessageEvent) -> CoreResult<()> {
    if !path.exists() {
        atomic_file::replace(path, MESSAGE_LOG_MAGIC)?;
    }
    let encoded = serde_json::to_vec(event).map_err(|_| CoreError::Internal)?;
    let encrypted = vault::seal_with_key(&identity::active_identity()?.storage_key()?, &encoded)?;
    let length = u32::try_from(encrypted.len()).map_err(|_| CoreError::LimitExceeded)?;
    let current = fs::metadata(path).map_err(|_| CoreError::Internal)?.len();
    if current + 4 + u64::from(length) > MAX_MESSAGE_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let mut options = OpenOptions::new();
    options.append(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|_| CoreError::Internal)?;
    file.write_all(&length.to_be_bytes())
        .and_then(|_| file.write_all(&encrypted))
        .map_err(|_| CoreError::Internal)?;
    file.sync_data().map_err(|_| CoreError::Internal)
}

fn compact_message_log_if_needed(store: &mut ContactStore) -> CoreResult<()> {
    let Some(path) = store.message_path.as_deref() else {
        return Ok(());
    };
    let size = fs::metadata(path).map(|value| value.len()).unwrap_or(0);
    if size < MESSAGE_LOG_COMPACT_BYTES
        && store.message_event_count <= store.messages.len().saturating_mul(2).saturating_add(256)
    {
        return Ok(());
    }
    write_message_snapshot(path, &store.messages)?;
    store.message_event_count = store.messages.len();
    Ok(())
}

fn write_message_snapshot(path: &Path, messages: &[StoredMessage]) -> CoreResult<()> {
    if messages.len() > MAX_MESSAGES {
        return Err(CoreError::LimitExceeded);
    }
    let key = identity::active_identity()?.storage_key()?;
    let mut output = Vec::from(MESSAGE_LOG_MAGIC.as_slice());
    for message in messages {
        let event = MessageEvent::Upsert {
            message: message.clone(),
        };
        let encoded = serde_json::to_vec(&event).map_err(|_| CoreError::Internal)?;
        let encrypted = vault::seal_with_key(&key, &encoded)?;
        let length = u32::try_from(encrypted.len()).map_err(|_| CoreError::LimitExceeded)?;
        output.extend_from_slice(&length.to_be_bytes());
        output.extend_from_slice(&encrypted);
        if output.len() as u64 > MAX_MESSAGE_STORE_BYTES {
            return Err(CoreError::LimitExceeded);
        }
    }
    atomic_file::replace(path, &output)
}

fn persist_bytes(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    atomic_file::replace(path, bytes)
}

fn message_json(message: StoredMessage) -> Value {
    json!({
        "id": message.id,
        "author_id": message.author_id,
        "body": message.body,
        "sent_at_ms": message.sent_at_ms,
        "is_outgoing": message.is_outgoing,
        "delivery_state": message.delivery_state,
        "attachment_name": message.attachment_name,
        "attachment_base64": message.attachment_base64,
    })
}

fn default_delivery_state() -> String {
    "sent".to_owned()
}

fn decode_incoming_content(
    plaintext: &str,
) -> CoreResult<(String, Option<String>, Option<String>)> {
    let Some(encoded) = plaintext.strip_prefix(ATTACHMENT_PREFIX) else {
        return Ok((plaintext.to_owned(), None, None));
    };
    let pointer_bytes = STANDARD_NO_PAD
        .decode(encoded)
        .map_err(|_| CoreError::InvalidInput)?;
    let pointer: AttachmentPointer =
        serde_json::from_slice(&pointer_bytes).map_err(|_| CoreError::InvalidInput)?;
    if pointer.version != 1 || pointer.size == 0 || pointer.size > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::InvalidInput);
    }
    let file_name = validate_attachment_name(&pointer.file_name)?;
    let encrypted =
        veilid_adapter::fetch_attachment_blob(&pointer.record_key, pointer.chunk_count)?;
    let key = STANDARD_NO_PAD
        .decode(&pointer.key_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    let nonce = STANDARD_NO_PAD
        .decode(&pointer.nonce_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    if key.len() != 32 || nonce.len() != 24 {
        return Err(CoreError::InvalidInput);
    }
    let cipher = XChaCha20Poly1305::new_from_slice(&key).map_err(|_| CoreError::InvalidInput)?;
    let bytes = cipher
        .decrypt(XNonce::from_slice(&nonce), encrypted.as_slice())
        .map_err(|_| CoreError::AuthenticationFailed)?;
    if bytes.len() != pointer.size {
        return Err(CoreError::VerificationFailed);
    }
    Ok((
        format!("📎 {file_name}"),
        Some(file_name),
        Some(STANDARD.encode(bytes)),
    ))
}

fn validate_attachment_name(value: &str) -> CoreResult<String> {
    let name = value.trim();
    if name.is_empty()
        || name.chars().count() > MAX_ATTACHMENT_NAME_CHARS
        || name.chars().any(char::is_control)
        || name.contains('/')
        || name.contains('\\')
    {
        return Err(CoreError::InvalidInput);
    }
    Ok(name.to_owned())
}

fn validate_display_name(value: &str) -> CoreResult<String> {
    let normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let length = normalized.chars().count();
    if length == 0 || length > MAX_DISPLAY_NAME_CHARS || normalized.chars().any(char::is_control) {
        return Err(CoreError::InvalidInput);
    }
    Ok(normalized)
}

fn validate_conversation_id(conversation_id: &str) -> CoreResult<()> {
    let length = conversation_id.len();
    if length == 0 || length > MAX_CONVERSATION_ID_BYTES {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}

fn current_time_ms() -> CoreResult<u64> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::Internal)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| CoreError::Internal)
}

fn contact_id(identity: &[u8]) -> String {
    let digest = Sha256::digest(identity);
    format!("contact-{}", compact_hex(&digest[..16]))
}

fn fingerprint(identity: &[u8]) -> String {
    grouped_hex(&Sha256::digest(identity))
}

fn initials(display_name: &str) -> String {
    display_name
        .split_whitespace()
        .take(2)
        .filter_map(|part| part.chars().next())
        .flat_map(char::to_uppercase)
        .collect()
}

fn accent_value(identity: &[u8]) -> u32 {
    let digest = Sha256::digest(identity);
    0xff00_0000 | (u32::from(digest[0]) << 16) | (u32::from(digest[1]) << 8) | u32::from(digest[2])
}

fn compact_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02X}")).collect()
}

fn grouped_hex(bytes: &[u8]) -> String {
    bytes
        .chunks(4)
        .map(compact_hex)
        .collect::<Vec<_>>()
        .join(" ")
}
