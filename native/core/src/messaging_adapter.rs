use std::{
    collections::HashMap,
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
const MAX_ATTACHMENT_BYTES: usize = 700 * 1024;
const MAX_ATTACHMENT_NAME_CHARS: usize = 128;
const ATTACHMENT_PREFIX: &str = "sylphy-attachment-v1:";
const CONTACT_STORE_FILE: &str = "contacts-v1.json";
const MESSAGE_STORE_FILE: &str = "messages-v1.vault";
const MESSAGE_LOG_FILE: &str = "messages-v2.log";
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
#[serde(tag = "operation", rename_all = "snake_case")]
enum MessageEvent {
    Upsert { message: StoredMessage },
    MarkRead { conversation_id: String },
    DeleteConversation { conversation_id: String },
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

#[derive(Default)]
struct ContactStore {
    path: Option<PathBuf>,
    message_path: Option<PathBuf>,
    legacy_message_path: Option<PathBuf>,
    contacts: Vec<StoredContact>,
    messages: Vec<StoredMessage>,
    messages_loaded: bool,
    message_event_count: usize,
    revision: u64,
}

static CONTACT_STORE: OnceLock<Mutex<ContactStore>> = OnceLock::new();

fn contact_store() -> &'static Mutex<ContactStore> {
    CONTACT_STORE.get_or_init(|| Mutex::new(ContactStore::default()))
}

pub fn configure_storage(storage_directory: &str) -> CoreResult<()> {
    if storage_directory.trim().is_empty() || storage_directory.len() > 4096 {
        return Err(CoreError::InvalidInput);
    }
    let directory = PathBuf::from(storage_directory).join("messaging");
    fs::create_dir_all(&directory).map_err(|_| CoreError::Internal)?;
    let path = directory.join(CONTACT_STORE_FILE);
    let contacts = load_contacts(&path)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    store.path = Some(path);
    store.message_path = Some(directory.join(MESSAGE_LOG_FILE));
    store.legacy_message_path = Some(directory.join(MESSAGE_STORE_FILE));
    store.contacts = contacts;
    store.messages.clear();
    store.messages_loaded = false;
    store.message_event_count = 0;
    store.revision = 0;
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

pub fn list_messages(conversation_id: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let mut messages = store
        .messages
        .iter()
        .filter(|message| message.conversation_id == conversation_id)
        .cloned()
        .collect::<Vec<_>>();
    messages.sort_by_key(|message| message.sent_at_ms);
    Ok(json!({
        "conversation_id": conversation_id,
        "messages": messages.into_iter().map(message_json).collect::<Vec<_>>(),
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
    };
    let mut updated = store.contacts.clone();
    updated.push(contact);
    persist_contacts(
        store.path.as_deref().ok_or(CoreError::FeatureUnavailable)?,
        &updated,
    )?;
    store.contacts = updated;
    store.revision = store.revision.wrapping_add(1);
    Ok(json!({"contact_id": id, "fingerprint": fingerprint, "safety": "pending"}))
}

pub fn send_text(conversation_id: &str, plaintext: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let (recipient, message_path) = {
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
            store
                .message_path
                .clone()
                .ok_or(CoreError::FeatureUnavailable)?,
        )
    };
    let (payload, message_id) = secure_packet::seal_for(&recipient, plaintext)?;
    veilid_adapter::deliver_payload(&recipient.route_blob, recipient.mailbox.as_ref(), payload)?;
    let now_ms = current_time_ms()?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let message = StoredMessage {
        id: message_id.clone(),
        conversation_id: conversation_id.to_owned(),
        author_id: "me".to_owned(),
        body: plaintext.trim().to_owned(),
        sent_at_ms: now_ms,
        is_outgoing: true,
        is_read: true,
        delivery_state: "sent".to_owned(),
        attachment_name: None,
        attachment_base64: None,
    };
    append_message_event(
        &message_path,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    )?;
    store.message_event_count += 1;
    store.messages.push(message);
    store.revision = store.revision.wrapping_add(1);
    let _ = compact_message_log_if_needed(&mut store);
    Ok(json!({"message_id": message_id, "delivery_state": "sent"}))
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
    let mut key = [0_u8; 32];
    let mut nonce = [0_u8; 24];
    OsRng.fill_bytes(&mut key);
    OsRng.fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new((&key).into());
    let encrypted = cipher
        .encrypt(XNonce::from_slice(&nonce), bytes.as_slice())
        .map_err(|_| CoreError::Internal)?;
    let (record_key, chunk_count) = veilid_adapter::publish_attachment_blob(&encrypted)?;
    let pointer = AttachmentPointer {
        version: 1,
        file_name: file_name.clone(),
        size: bytes.len(),
        record_key,
        chunk_count,
        key_base64: STANDARD_NO_PAD.encode(key),
        nonce_base64: STANDARD_NO_PAD.encode(nonce),
    };
    let control = format!(
        "{ATTACHMENT_PREFIX}{}",
        STANDARD_NO_PAD.encode(serde_json::to_vec(&pointer).map_err(|_| CoreError::Internal)?)
    );
    let (recipient, message_path) = {
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
            store
                .message_path
                .clone()
                .ok_or(CoreError::FeatureUnavailable)?,
        )
    };
    let (payload, message_id) = secure_packet::seal_for(&recipient, &control)?;
    veilid_adapter::deliver_payload(&recipient.route_blob, recipient.mailbox.as_ref(), payload)?;
    let now_ms = current_time_ms()?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let message = StoredMessage {
        id: message_id.clone(),
        conversation_id: conversation_id.to_owned(),
        author_id: "me".to_owned(),
        body: format!("📎 {file_name}"),
        sent_at_ms: now_ms,
        is_outgoing: true,
        is_read: true,
        delivery_state: "sent".to_owned(),
        attachment_name: Some(file_name),
        attachment_base64: Some(STANDARD.encode(bytes)),
    };
    append_message_event(
        &message_path,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    )?;
    store.message_event_count += 1;
    store.messages.push(message);
    store.revision = store.revision.wrapping_add(1);
    let _ = compact_message_log_if_needed(&mut store);
    Ok(json!({"message_id": message_id, "delivery_state": "sent"}))
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
        let _ = compact_message_log_if_needed(&mut store);
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
    let _ = compact_message_log_if_needed(&mut store);
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
    let payloads = veilid_adapter::take_inbound_payloads()?;
    let mut persisted = 0_usize;
    let mut discarded = 0_usize;
    for payload in payloads {
        match persist_inbound_payload(&payload.payload) {
            Ok(()) => {
                persisted += 1;
                let _ = veilid_adapter::acknowledge_inbound_payload(payload);
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
    )
}

fn persist_inbound_payload(payload: &[u8]) -> CoreResult<()> {
    let opened = secure_packet::open(payload)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let id = contact_id(&opened.sender.bundle.identity_ed25519);
    if let Some(contact) = store.contacts.iter_mut().find(|contact| contact.id == id) {
        contact.bundle = opened.sender.bundle.clone();
        contact.published_identity = Some(opened.sender.clone());
    } else if store.contacts.len() < MAX_CONTACTS {
        let fingerprint = fingerprint(&opened.sender.bundle.identity_ed25519);
        let suffix = fingerprint.replace(' ', "");
        let suffix = &suffix[suffix.len().saturating_sub(8)..];
        store.contacts.push(StoredContact {
            id: id.clone(),
            display_name: format!("Nuovo contatto {suffix}"),
            fingerprint,
            added_at_ms: opened.sent_at_ms,
            bundle: opened.sender.bundle.clone(),
            published_identity: Some(opened.sender.clone()),
            verified: false,
        });
    } else {
        return Err(CoreError::LimitExceeded);
    }
    ensure_messages_loaded(&mut store)?;
    if store
        .messages
        .iter()
        .any(|message| message.id == opened.message_id)
    {
        persist_contacts(&contact_path, &store.contacts)?;
        return Ok(());
    }
    let (body, attachment_name, attachment_base64) = decode_incoming_content(&opened.plaintext)?;
    persist_contacts(&contact_path, &store.contacts)?;
    let message = StoredMessage {
        id: opened.message_id,
        conversation_id: id.clone(),
        author_id: id,
        body,
        sent_at_ms: opened.sent_at_ms,
        is_outgoing: false,
        is_read: false,
        delivery_state: "delivered".to_owned(),
        attachment_name,
        attachment_base64,
    };
    append_message_event(
        &message_path,
        &MessageEvent::Upsert {
            message: message.clone(),
        },
    )?;
    store.message_event_count += 1;
    store.messages.push(message);
    store.revision = store.revision.wrapping_add(1);
    let _ = compact_message_log_if_needed(&mut store);
    Ok(())
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

fn load_contacts(path: &Path) -> CoreResult<Vec<StoredContact>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > MAX_CONTACT_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let bytes = fs::read(path).map_err(|_| CoreError::Internal)?;
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
    Ok(contacts)
}

fn persist_contacts(path: &Path, contacts: &[StoredContact]) -> CoreResult<()> {
    let encoded = serde_json::to_vec(contacts).map_err(|_| CoreError::Internal)?;
    if encoded.len() as u64 > MAX_CONTACT_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    persist_bytes(path, &encoded)
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
