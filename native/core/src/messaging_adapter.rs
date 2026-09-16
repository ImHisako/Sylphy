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
    ratchet_adapter, secure_packet, vault, veilid_adapter,
};

mod attachments;
pub mod groups;
mod receipts;
mod search;

const MAX_CONVERSATION_ID_BYTES: usize = 128;
const MAX_DISPLAY_NAME_CHARS: usize = 64;
const MAX_INVITATION_TEXT_BYTES: usize = 64 * 1024;
const MAX_CONTACT_STORE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_MESSAGE_STORE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_CONTACTS: usize = 1024;
const MAX_MESSAGES: usize = 100_000;
const MAX_OUTBOX_DELIVERIES: usize = 4096;
const MAX_ATTACHMENT_BYTES: usize = crate::blob_transport::MAX_ATTACHMENT_BYTES;
const MAX_GROUP_INVITATION_BYTES: usize = 700 * 1024;
const MAX_ATTACHMENT_NAME_CHARS: usize = 128;
const MAX_MESSAGE_BODY_BYTES: usize = 16 * 1024;
const MAX_MESSAGE_ID_BYTES: usize = 128;
const MAX_CLOCK_SKEW_MS: u64 = 5 * 60 * 1000;
const DEFAULT_MESSAGE_PAGE_SIZE: usize = 120;
const MAX_MESSAGE_PAGE_SIZE: usize = 500;
const ATTACHMENT_PREFIX: &str = "sylphy-attachment-v1:";
const GROUP_INVITE_PREFIX: &str = "sylphy-group-invite-v1:";
const GROUP_INVITE_BLOB_PREFIX: &str = "sylphy-group-invite-v2:";
const GROUP_MESSAGE_PREFIX: &str = "sylphy-group-message-v1:";
const MAX_GROUP_MEMBERS: usize = 64;
const DEVICE_SYNC_PREFIX: &[u8] = b"SYLPHY-DEVICE-SYNC-V1\0";
const CONTACT_STORE_FILE: &str = "contacts-v2.vault";
const GROUP_STORE_FILE: &str = "groups-v1.vault";
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
    #[serde(default)]
    previous_bundles: Vec<PublicBundle>,
}

fn validate_previous_bundles(contact: &StoredContact) -> CoreResult<()> {
    if contact.previous_bundles.len() > 8 {
        return Err(CoreError::LimitExceeded);
    }
    for bundle in &contact.previous_bundles {
        bundle.validate()?;
        if bundle.identity_ed25519 != contact.bundle.identity_ed25519 {
            return Err(CoreError::VerificationFailed);
        }
    }
    Ok(())
}

fn update_contact_identity(
    contact: &mut StoredContact,
    refreshed: PublishedIdentity,
) -> CoreResult<()> {
    if refreshed.bundle.identity_ed25519 != contact.bundle.identity_ed25519 {
        return Err(CoreError::VerificationFailed);
    }
    let now = current_time_ms()?;
    if let Some(previous) = &contact.published_identity {
        for device in previous.delivery_devices()? {
            if device.bundle.signed_prekey_x25519 != refreshed.bundle.signed_prekey_x25519
                && !contact.previous_bundles.iter().any(|bundle| {
                    bundle.signed_prekey_x25519 == device.bundle.signed_prekey_x25519
                        && bundle.signal_pre_key.as_ref().map(|key| key.device_id)
                            == device
                                .bundle
                                .signal_pre_key
                                .as_ref()
                                .map(|key| key.device_id)
                })
            {
                contact.previous_bundles.push(device.bundle);
            }
        }
    }
    contact.previous_bundles.retain(|bundle| {
        bundle
            .expires_at_ms
            .saturating_add(crate::offline_mailbox::RETENTION_MS)
            > now
    });
    if contact.previous_bundles.len() > 8 {
        contact
            .previous_bundles
            .drain(..contact.previous_bundles.len() - 8);
    }
    contact.bundle = refreshed.bundle.clone();
    contact.published_identity = Some(refreshed);
    Ok(())
}

/// A group keeps the authenticated public identity of every member. The
/// private ratchet state remains owned by each direct session in the secure
/// core; this record is only the encrypted local directory and membership
/// policy used to fan out messages.
#[derive(Clone, Debug, Deserialize, Serialize)]
struct GroupMember {
    id: String,
    display_name: String,
    fingerprint: String,
    identity: PublishedIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    invitation_code: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredGroup {
    id: String,
    name: String,
    description: String,
    /// `group` is a classic chat; `channel` is a business group. Both default
    /// to open writing and use the same authenticated member fan-out.
    mode: String,
    admin_id: String,
    created_at_ms: u64,
    members: Vec<GroupMember>,
    #[serde(default)]
    management: groups::Management,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct GroupInvitation {
    version: u8,
    group: StoredGroup,
    admin: GroupMember,
}

#[derive(Debug, Deserialize, Serialize)]
struct GroupInvitationPointer {
    version: u8,
    size: usize,
    record_key: String,
    chunk_count: u16,
    key_base64: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredMessage {
    id: String,
    conversation_id: String,
    author_id: String,
    #[serde(default)]
    author_name: Option<String>,
    body: String,
    sent_at_ms: u64,
    #[serde(default)]
    received_at_ms: u64,
    is_outgoing: bool,
    #[serde(default)]
    is_read: bool,
    #[serde(default = "default_delivery_state")]
    delivery_state: String,
    #[serde(default)]
    receipts: receipts::Tracking,
    #[serde(default)]
    attachment_name: Option<String>,
    #[serde(default)]
    attachment_base64: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    attachment_pointer: Option<AttachmentPointer>,
}

#[derive(Debug, Deserialize, Serialize)]
struct MessagingAccountBackup {
    version: u8,
    contacts: Vec<StoredContact>,
    messages: Vec<StoredMessage>,
    #[serde(default)]
    groups: Vec<StoredGroup>,
    #[serde(default)]
    outbox: Vec<PendingDelivery>,
    #[serde(default)]
    attachment_leases: Vec<AttachmentLease>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum MessageEvent {
    Upsert {
        message: StoredMessage,
    },
    DeleteMessage {
        message_id: String,
    },
    MarkRead {
        conversation_id: String,
    },
    MarkChannelRead {
        conversation_id: String,
        channel_id: Option<String>,
    },
    DeleteConversation {
        conversation_id: String,
    },
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
    UpsertGroup {
        group: StoredGroup,
    },
    UpsertGroupMessage {
        group: StoredGroup,
        message: StoredMessage,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
struct AttachmentPointer {
    version: u8,
    file_name: String,
    size: usize,
    record_key: String,
    chunk_count: u16,
    key_base64: String,
    nonce_base64: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    channel_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PendingDelivery {
    id: String,
    message_id: String,
    #[serde(default)]
    is_control: bool,
    route_blob: Vec<u8>,
    payload: Vec<u8>,
    created_at_ms: u64,
    #[serde(default)]
    offline_keys: Option<crate::offline_mailbox::MailboxKeys>,
    #[serde(default)]
    attempts: u32,
    #[serde(default)]
    next_attempt_ms: u64,
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
    #[serde(default)]
    attempts: u32,
    #[serde(default)]
    next_attempt_ms: u64,
    #[serde(default)]
    blob: Option<crate::device_sync::BlobPointer>,
}

#[derive(Default)]
struct ContactStore {
    path: Option<PathBuf>,
    message_path: Option<PathBuf>,
    legacy_message_path: Option<PathBuf>,
    outbox_path: Option<PathBuf>,
    attachment_lease_path: Option<PathBuf>,
    device_sync_outbox_path: Option<PathBuf>,
    groups_path: Option<PathBuf>,
    contacts: Vec<StoredContact>,
    groups: Vec<StoredGroup>,
    messages: Vec<StoredMessage>,
    messages_loaded: bool,
    message_event_count: usize,
    outbox: Vec<PendingDelivery>,
    attachment_leases: Vec<AttachmentLease>,
    device_sync_outbox: Vec<PendingDeviceSync>,
    revision: u64,
    generation: u64,
}

static CONTACT_STORE: OnceLock<Mutex<ContactStore>> = OnceLock::new();
static ALLOW_UNKNOWN_CONTACTS: OnceLock<Mutex<bool>> = OnceLock::new();
static SYNC_LOCK: Mutex<()> = Mutex::new(());
#[derive(Default)]
struct PeerRefresh {
    generation: u64,
    cursor: usize,
    next_attempt_ms: u64,
    receiver: Option<std::sync::mpsc::Receiver<(String, CoreResult<PublishedIdentity>)>>,
}
static PEER_REFRESH: OnceLock<Mutex<PeerRefresh>> = OnceLock::new();
type TransportResults = Vec<(PendingDelivery, bool)>;
static OUTBOX_TRANSPORT: Mutex<Option<(u64, std::sync::mpsc::Receiver<TransportResults>)>> =
    Mutex::new(None);

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

pub fn configure_read_receipts(send_read_receipts: bool) {
    receipts::configure(send_read_receipts);
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
    let groups_path = directory.join(GROUP_STORE_FILE);
    let groups = load_groups(&groups_path)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    store.generation = store.generation.wrapping_add(1);
    attachments::reset();
    store.path = Some(path);
    store.message_path = Some(directory.join(MESSAGE_LOG_FILE));
    store.legacy_message_path = Some(directory.join(MESSAGE_STORE_FILE));
    store.outbox_path = Some(outbox_path);
    store.attachment_lease_path = Some(attachment_lease_path);
    store.device_sync_outbox_path = Some(device_sync_outbox_path);
    store.groups_path = Some(groups_path);
    store.contacts = contacts;
    store.groups = groups;
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
        groups: store.groups.clone(),
        outbox: store.outbox.clone(),
        attachment_leases: store.attachment_leases.clone(),
    })
    .map_err(|_| CoreError::Internal)
}

pub(crate) fn import_account_backup(value: Value) -> CoreResult<()> {
    validate_account_backup(&value)?;
    let mut backup: MessagingAccountBackup =
        serde_json::from_value(value).map_err(|_| CoreError::VerificationFailed)?;
    // Preserve already sealed packets, never clone live Signal sessions.
    // Old backups without the durable outbox cannot promise automatic retry.
    for message in &mut backup.messages {
        if message.delivery_state == "queued"
            && !backup
                .outbox
                .iter()
                .any(|entry| entry.message_id == message.id)
        {
            message.delivery_state = "not_restored".to_owned();
        }
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let groups_path = store
        .groups_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    persist_contacts(&contact_path, &backup.contacts)?;
    write_message_snapshot(&message_path, &backup.messages)?;
    persist_groups(&groups_path, &backup.groups)?;
    persist_outbox(
        store
            .outbox_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &backup.outbox,
    )?;
    persist_attachment_leases(
        store
            .attachment_lease_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &backup.attachment_leases,
    )?;
    store.outbox = backup.outbox;
    store.attachment_leases = backup.attachment_leases;
    store.contacts = backup.contacts;
    store.groups = backup.groups;
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
        || backup.groups.len() > MAX_CONTACTS
        || backup.outbox.len() > MAX_OUTBOX_DELIVERIES
        || backup.attachment_leases.len() > MAX_OUTBOX_DELIVERIES
    {
        return Err(CoreError::LimitExceeded);
    }
    validate_groups(&backup.groups)?;
    for delivery in &backup.outbox {
        if delivery.id.is_empty()
            || delivery.route_blob.is_empty()
            || delivery.payload.is_empty()
            || delivery.payload.len() > 32 * 1024
            || (!delivery.is_control
                && !backup
                    .messages
                    .iter()
                    .any(|message| message.id == delivery.message_id && message.is_outgoing))
        {
            return Err(CoreError::VerificationFailed);
        }
        secure_packet::validate_stored_delivery(&delivery.payload)?;
    }
    if backup.attachment_leases.iter().any(|lease| {
        lease.record_key.is_empty() || lease.chunk_count == 0 || lease.chunk_count > 128
    }) {
        return Err(CoreError::VerificationFailed);
    }
    let contact_ids = backup
        .contacts
        .iter()
        .map(|contact| contact.id.as_str())
        .collect::<HashSet<_>>();
    if backup
        .groups
        .iter()
        .any(|group| contact_ids.contains(group.id.as_str()))
    {
        return Err(CoreError::VerificationFailed);
    }
    for contact in &backup.contacts {
        validate_conversation_id(&contact.id)?;
        validate_display_name(&contact.display_name)?;
        contact.bundle.validate()?;
        validate_previous_bundles(contact)?;
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
    validate_backup_messages(&backup.contacts, &backup.groups, &backup.messages)
}

fn validate_backup_messages(
    contacts: &[StoredContact],
    groups: &[StoredGroup],
    messages: &[StoredMessage],
) -> CoreResult<()> {
    let contact_ids = contacts
        .iter()
        .map(|contact| contact.id.as_str())
        .collect::<HashSet<_>>();
    let mut message_ids = HashSet::with_capacity(messages.len());
    let group_ids = groups
        .iter()
        .map(|group| group.id.as_str())
        .collect::<HashSet<_>>();
    for message in messages {
        validate_stored_message(message)?;
        if (!contact_ids.contains(message.conversation_id.as_str())
            && !group_ids.contains(message.conversation_id.as_str()))
            || (!message.is_outgoing
                && !group_ids.contains(message.conversation_id.as_str())
                && message.author_id != message.conversation_id)
            || (message.is_outgoing && message.author_id != "me")
            || !message_ids.insert(message.id.as_str())
        {
            return Err(CoreError::VerificationFailed);
        }
    }
    Ok(())
}

fn validate_stored_message(message: &StoredMessage) -> CoreResult<()> {
    if let Some(pointer) = &message.attachment_pointer {
        validate_attachment_pointer(pointer)?;
        if message.attachment_name.as_deref() != Some(pointer.file_name.as_str()) {
            return Err(CoreError::VerificationFailed);
        }
    }
    if let Some(name) = &message.author_name {
        validate_display_name(name)?;
    }
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
            "queued" | "sent" | "delivered" | "read" | "not_restored"
        )
        || message.sent_at_ms > current_time_ms()?.saturating_add(MAX_CLOCK_SKEW_MS)
        || message.received_at_ms > current_time_ms()?.saturating_add(MAX_CLOCK_SKEW_MS)
    {
        return Err(CoreError::VerificationFailed);
    }
    match (&message.attachment_name, &message.attachment_base64) {
        (None, None) => {}
        (Some(name), None) if message.attachment_pointer.is_some() => {
            validate_attachment_name(name)?;
        }
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
    attachments::poll()?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let mut summaries: HashMap<&str, (Option<&StoredMessage>, usize)> = HashMap::new();
    for message in &store.messages {
        let summary = summaries
            .entry(message.conversation_id.as_str())
            .or_insert((None, 0));
        if summary
            .0
            .is_none_or(|current| message_order_ms(current) <= message_order_ms(message))
        {
            summary.0 = Some(message);
        }
        if !message.is_outgoing && !message.is_read {
            summary.1 += 1;
        }
    }
    let mut conversations = store
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
                "last_message": last.map(|message| message_preview(message, &store)).unwrap_or_else(||
                    if can_message { "Conversazione pronta" } else { "Aggiorna l'ID Sylphy del contatto" }.to_owned()
                ),
                "last_activity_ms": last.map(message_order_ms).unwrap_or(contact.added_at_ms),
                "unread_count": unread,
                "is_online": false,
                "is_group": false,
                "conversation_type": "direct",
                "member_count": 2,
                "is_admin": false,
                "description": "",
                "safety": if contact.verified { "verified" } else if can_message { "pending" } else { "refresh_required" },
                "fingerprint": contact.fingerprint,
            })
        })
        .collect::<Vec<_>>();
    conversations.extend(store.groups.iter().filter(|group| !group.management.closed && !group.management.left).map(|group| {
        let (last, unread) = summaries
            .get(group.id.as_str())
            .copied()
            .unwrap_or((None, 0));
        json!({
            "id": group.id,
            "name": group.name,
            "initials": initials(&group.name),
            "avatar_base64": Value::Null,
            "accent_value": accent_value(group.id.as_bytes()),
            "last_message": last.map(|message| message_preview(message, &store)).unwrap_or_else(|| "Gruppo creato".to_owned()),
            "last_activity_ms": last.map(message_order_ms).unwrap_or(group.created_at_ms),
            "unread_count": unread,
            "is_online": false,
            "is_group": true,
            "conversation_type": group.mode,
            "member_count": group.members.len() + usize::from(!group.management.removed),
            "is_admin": groups::is_admin(group).unwrap_or(false),
            "can_send_messages": groups::can_write(group).unwrap_or(false),
            "pinned_message_ids": group.management.pinned,
            "group_revision": group.management.revision,
            "description": group.description,
            "safety": "verified",
            "fingerprint": "Gruppo cifrato con sessioni individuali",
        })
    }));
    Ok(json!({
        "state": if store.path.is_some() { "ready" } else { "storage_unconfigured" },
        "can_send": store.contacts.iter().any(|contact| contact.published_identity.is_some())
            || !store.groups.is_empty(),
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
    attachments::poll()?;
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
    let group = store
        .groups
        .iter()
        .find(|group| group.id == conversation_id);
    let (mut messages, mut has_more) = select_message_page(
        &store.messages,
        conversation_id,
        before_ms,
        before_id,
        limit,
    );
    if let Some(group) = group {
        messages.retain(|message| {
            !group.management.closed
                && !group.management.left
                && !groups::message_deleted(group, message)
        });
        if group.management.closed || group.management.left {
            has_more = false;
        }
    }
    let next_before_ms = messages.first().map(|message| message_order_ms(message));
    let next_before_id = messages.first().map(|message| message.id.as_str());
    Ok(json!({
        "conversation_id": conversation_id,
        "messages": messages.into_iter().map(|message| message_json(message, &store)).collect::<Vec<_>>(),
        "next_before_ms": next_before_ms,
        "next_before_id": next_before_id,
        "has_more": has_more,
        "revision": store.revision,
        "group_revision": group.map(|group| group.management.revision),
    }))
}

// The remote wall clock is display metadata, not a shared clock. Use local
// reception for incoming messages so clock skew cannot partition a chat by author.
fn message_order_ms(message: &StoredMessage) -> u64 {
    if !message.is_outgoing && message.received_at_ms != 0 {
        message.received_at_ms
    } else {
        message.sent_at_ms
    }
}

fn select_message_page<'a>(
    history: &'a [StoredMessage],
    conversation_id: &str,
    before_ms: Option<u64>,
    before_id: Option<&str>,
    limit: usize,
) -> (Vec<&'a StoredMessage>, bool) {
    // Select references first: off-page bodies and attachments are never
    // cloned, and only the visible page needs a complete sort.
    let mut messages = history
        .iter()
        .filter(|message| message.conversation_id == conversation_id)
        .filter(|message| match (before_ms, before_id) {
            (Some(before), Some(id)) => {
                (message_order_ms(message), message.id.as_str()) < (before, id)
            }
            (Some(before), None) => message_order_ms(message) < before,
            (None, None) => true,
            (None, Some(_)) => false,
        })
        .collect::<Vec<_>>();
    let newest_first = |left: &&StoredMessage, right: &&StoredMessage| {
        message_order_ms(right)
            .cmp(&message_order_ms(left))
            .then_with(|| right.id.cmp(&left.id))
    };
    let has_more = messages.len() > limit;
    if has_more {
        messages.select_nth_unstable_by(limit, newest_first);
        messages.truncate(limit);
    }
    messages.sort_unstable_by(newest_first);
    messages.reverse();
    (messages, has_more)
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
        previous_bundles: Vec::new(),
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

fn local_published_identity() -> CoreResult<PublishedIdentity> {
    let local = identity::active_identity()?;
    let signing_key = local.signing_key()?;
    let bundle = local.public_bundle(ratchet_adapter::public_pre_key_bundle()?)?;
    PublishedIdentity::new(
        &signing_key,
        bundle,
        veilid_adapter::local_route_blob()?,
        crate::peer_identity::current_public_profile(),
        None,
    )
}

fn group_member(identity: PublishedIdentity) -> CoreResult<GroupMember> {
    let id = contact_id(&identity.bundle.identity_ed25519);
    let display_name = identity
        .profile
        .display_name
        .clone()
        .unwrap_or_else(|| format!("Contatto {}", &id[id.len().saturating_sub(8)..]));
    Ok(GroupMember {
        id,
        display_name,
        fingerprint: fingerprint(&identity.bundle.identity_ed25519),
        identity,
        invitation_code: None,
    })
}

fn update_group_endpoints(
    store: &mut ContactStore,
    id: &str,
    published: &PublishedIdentity,
) -> CoreResult<()> {
    published.validate()?;
    if contact_id(&published.bundle.identity_ed25519) != id {
        return Err(CoreError::VerificationFailed);
    }
    let invitation = store
        .contacts
        .iter()
        .find(|contact| contact.id == id)
        .and_then(|contact| contact.invitation_code.clone());
    let mut groups = store.groups.clone();
    let mut changed = false;
    for member in groups
        .iter_mut()
        .flat_map(|group| &mut group.members)
        .filter(|member| member.id == id)
    {
        if member.identity.bundle.expires_at_ms > published.bundle.expires_at_ms {
            continue;
        }
        if serde_json::to_vec(&member.identity).ok() != serde_json::to_vec(published).ok() {
            member.identity = published.clone();
            changed = true;
        }
        if member.invitation_code.is_none() && invitation.is_some() {
            member.invitation_code = invitation.clone();
            changed = true;
        }
    }
    if changed {
        persist_groups(
            store
                .groups_path
                .as_deref()
                .ok_or(CoreError::FeatureUnavailable)?,
            &groups,
        )?;
        store.groups = groups;
        store.revision = store.revision.wrapping_add(1);
    }
    Ok(())
}

fn current_group(id: &str) -> CoreResult<Option<StoredGroup>> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let Some(group) = store.groups.iter().find(|group| group.id == id).cloned() else {
        return Ok(None);
    };
    let contacts = store
        .contacts
        .iter()
        .filter(|contact| group.members.iter().any(|member| member.id == contact.id))
        .filter_map(|contact| {
            contact
                .published_identity
                .clone()
                .filter(|identity| {
                    group.members.iter().any(|member| {
                        member.id == contact.id
                            && member.identity.bundle.expires_at_ms < identity.bundle.expires_at_ms
                    })
                })
                .map(|identity| (contact.id.clone(), identity))
        })
        .collect::<Vec<_>>();
    for (id, identity) in contacts {
        update_group_endpoints(&mut store, &id, &identity)?;
    }
    Ok(store.groups.iter().find(|group| group.id == id).cloned())
}

pub fn create_group(
    name: &str,
    invitation_codes: &[String],
    professional: bool,
    description: &str,
) -> CoreResult<Value> {
    let name = validate_display_name(name)?;
    let description = description.trim().to_owned();
    if description.len() > MAX_MESSAGE_BODY_BYTES
        || invitation_codes.is_empty()
        || invitation_codes.len() > MAX_GROUP_MEMBERS
    {
        return Err(CoreError::LimitExceeded);
    }
    let admin_identity = local_published_identity()?;
    let mut admin = group_member(admin_identity.clone())?;
    admin.invitation_code = identity::active_dht_descriptor()?
        .and_then(|descriptor| veilid_adapter::owned_identity_code(&descriptor).ok());
    let admin_id = admin.id.clone();
    let mut members = Vec::with_capacity(invitation_codes.len());
    let mut ids = HashSet::new();
    for code in invitation_codes {
        let (_, published) = decode_invitation(code)?;
        let mut member = group_member(published.ok_or(CoreError::VerificationFailed)?)?;
        if code.trim().starts_with("sylphy:VLD") || code.trim().starts_with("VLD") {
            member.invitation_code = Some(code.trim().to_owned());
        }
        if member.identity.delivery_devices()?.iter().any(|device| {
            !device
                .bundle
                .capabilities
                .iter()
                .any(|value| value == "group-invite-blob-v2")
        }) {
            return Err(CoreError::UnsupportedVersion);
        }
        if member.id == admin_id || !ids.insert(member.id.clone()) {
            return Err(CoreError::VerificationFailed);
        }
        members.push(member);
    }
    let mut id_bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut id_bytes);
    let group_id = compact_hex(&id_bytes);
    let now_ms = current_time_ms()?;
    let group = StoredGroup {
        id: group_id.clone(),
        name,
        description,
        mode: if professional { "channel" } else { "group" }.to_owned(),
        // The local alias keeps the UI permission check independent of the
        // rotating identity key. The invitation carries the real key id.
        admin_id: "me".to_owned(),
        created_at_ms: now_ms,
        members: members.clone(),
        management: groups::Management::new(admin_identity),
    };
    groups::require_updated(&group)?;
    let invitation_group = StoredGroup {
        admin_id: admin_id.clone(),
        ..group.clone()
    };
    let invitation = GroupInvitation {
        version: 1,
        group: invitation_group,
        admin,
    };
    let message_path = contact_store()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    // Public identities (especially PQ prekeys and avatars) cannot fit in a
    // chat packet. Only the encrypted blob pointer travels in each session.
    let (plaintext, pointer) =
        encode_group_invitation(&invitation, veilid_adapter::publish_attachment_blob)?;
    let result = register_attachment_lease(&pointer.record_key, pointer.chunk_count)
        .and_then(|()| queue_created_group(&group, &plaintext, &message_path));
    if result.is_err() {
        let _ = veilid_adapter::delete_attachment_blob(&pointer.record_key, pointer.chunk_count);
        remove_attachment_lease(&pointer.record_key);
    }
    result
}

fn queue_created_group(
    group: &StoredGroup,
    plaintext: &str,
    message_path: &Path,
) -> CoreResult<Value> {
    let group_id = group.id.clone();
    let members = &group.members;
    // A single durable system message carries one encrypted delivery per
    // member. The secure packet still uses the member's individual session.
    let mut deliveries = Vec::new();
    for member in members {
        let (mut member_deliveries, _) = secure_packet::seal_for_all(&member.identity, plaintext)?;
        deliveries.append(&mut member_deliveries);
    }
    if deliveries.is_empty() {
        return Err(CoreError::VerificationFailed);
    }
    {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        let path = store
            .groups_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        if store.groups.len() >= MAX_CONTACTS
            || store.groups.iter().any(|item| item.id == group_id)
            || store.contacts.iter().any(|item| item.id == group_id)
        {
            return Err(CoreError::LimitExceeded);
        }
        let mut updated = store.groups.clone();
        updated.push(group.clone());
        persist_groups(&path, &updated)?;
        store.groups = updated;
        store.revision = store.revision.wrapping_add(1);
    }
    let system_message = StoredMessage {
        id: group_id.clone(),
        conversation_id: group_id.clone(),
        author_id: "me".to_owned(),
        body: "Gruppo creato".to_owned(),
        sent_at_ms: group.created_at_ms,
        received_at_ms: 0,
        author_name: None,
        is_outgoing: true,
        is_read: true,
        delivery_state: "queued".to_owned(),
        receipts: Default::default(),
        attachment_name: None,
        attachment_base64: None,
        attachment_pointer: None,
    };
    if let Err(error) = queue_outgoing(message_path, system_message, deliveries) {
        if let Ok(mut store) = contact_store().lock() {
            if let Some(path) = store.groups_path.clone() {
                let updated = store
                    .groups
                    .iter()
                    .filter(|item| item.id != group_id)
                    .cloned()
                    .collect::<Vec<_>>();
                if persist_groups(&path, &updated).is_ok() {
                    store.groups = updated;
                    store.revision = store.revision.wrapping_add(1);
                }
            }
        }
        return Err(error);
    }
    queue_device_sync(&DeviceSyncEvent::UpsertGroup {
        group: group.clone(),
    });
    Ok(
        json!({"group_id": group_id, "conversation_type": group.mode, "member_count": members.len() + 1}),
    )
}

pub fn send_reply(conversation_id: &str, plaintext: &str, reply_to: &str) -> CoreResult<Value> {
    let channel_id = {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
        let original = store
            .messages
            .iter()
            .find(|message| message.id == reply_to && message.conversation_id == conversation_id)
            .ok_or(CoreError::InvalidInput)?;
        groups::rich_metadata(&original.body)?.2
    };
    if let Some(channel_id) = channel_id {
        return groups::send_channel_text(conversation_id, plaintext, &channel_id, Some(reply_to));
    }
    send_text(
        conversation_id,
        &groups::encode_text(plaintext, Some(reply_to))?,
    )
}

pub fn send_text(conversation_id: &str, plaintext: &str) -> CoreResult<Value> {
    send_text_with(
        conversation_id,
        plaintext,
        secure_packet::seal_for_all_with_id,
    )
}

fn send_text_with(
    conversation_id: &str,
    plaintext: &str,
    mut seal: impl FnMut(
        &PublishedIdentity,
        &str,
        &[u8],
    ) -> CoreResult<(Vec<secure_packet::SealedDelivery>, String)>,
) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let group = current_group(conversation_id)?;
    if let Some(group) = group {
        let plaintext = plaintext.trim();
        let local_id = contact_id(&identity::active_identity()?.identity_public_key()?);
        let (text, _, channel) = groups::rich_metadata(plaintext)?;
        groups::enforce_channel(&group, channel.as_deref())?;
        if channel.is_some() {
            groups::require_updated(&group)?;
        }
        groups::enforce(&group, &local_id, &text, false)?;
        if plaintext.is_empty() || plaintext.len() > MAX_MESSAGE_BODY_BYTES {
            return Err(CoreError::LimitExceeded);
        }
        let body = format!(
            "{GROUP_MESSAGE_PREFIX}{conversation_id}:{}",
            STANDARD_NO_PAD.encode(plaintext.as_bytes())
        );
        let mut deliveries = Vec::new();
        let mut id_bytes = [0_u8; 16];
        OsRng.fill_bytes(&mut id_bytes);
        for member in &group.members {
            let (mut sealed, _) = seal(&member.identity, &body, &id_bytes)?;
            deliveries.append(&mut sealed);
        }
        if deliveries.is_empty() && !group.members.is_empty() {
            return Err(CoreError::VerificationFailed);
        }
        let delivery_state = if group.members.is_empty() {
            "delivered"
        } else {
            "queued"
        };
        let message_path = contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let message_id = compact_hex(&id_bytes);
        let message = StoredMessage {
            id: message_id.clone(),
            conversation_id: conversation_id.to_owned(),
            author_id: "me".to_owned(),
            body: plaintext.to_owned(),
            sent_at_ms: current_time_ms()?,
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: delivery_state.to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
            attachment_pointer: None,
        };
        queue_outgoing(&message_path, message, deliveries)?;
        return Ok(json!({"message_id": message_id, "delivery_state": delivery_state}));
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
    let (deliveries, message_id) = secure_packet::seal_for_all(&recipient, plaintext)?;
    let now_ms = current_time_ms()?;
    let message = StoredMessage {
        id: message_id.clone(),
        conversation_id: conversation_id.to_owned(),
        author_id: "me".to_owned(),
        body: plaintext.trim().to_owned(),
        sent_at_ms: now_ms,
        received_at_ms: 0,
        author_name: None,
        is_outgoing: true,
        is_read: true,
        delivery_state: "queued".to_owned(),
        receipts: Default::default(),
        attachment_name: None,
        attachment_base64: None,
        attachment_pointer: None,
    };
    queue_outgoing(&message_path, message.clone(), deliveries)?;
    Ok(json!({
        "message_id": message_id,
        "delivery_state": "queued"
    }))
}

pub fn send_attachment(
    conversation_id: &str,
    file_name: &str,
    bytes_base64: &str,
) -> CoreResult<Value> {
    send_attachment_in_channel(conversation_id, file_name, bytes_base64, None)
}

pub fn request_attachment(
    conversation_id: &str,
    message_id: &str,
    cancel: bool,
) -> CoreResult<Value> {
    attachments::request(conversation_id, message_id, cancel)
}

pub fn send_attachment_in_channel(
    conversation_id: &str,
    file_name: &str,
    bytes_base64: &str,
    channel_id: Option<&str>,
) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let file_name = validate_attachment_name(file_name)?;
    if bytes_base64.len() > MAX_ATTACHMENT_BYTES.div_ceil(3) * 4 {
        return Err(CoreError::LimitExceeded);
    }
    let bytes = STANDARD
        .decode(bytes_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    if bytes.is_empty() || bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let group = current_group(conversation_id)?;
    if let Some(group) = group {
        let local_id = contact_id(&identity::active_identity()?.identity_public_key()?);
        groups::enforce(&group, &local_id, &file_name, true)?;
        groups::enforce_channel(&group, channel_id)?;
        if channel_id.is_some() {
            groups::require_updated(&group)?;
        }
        if group.members.is_empty() {
            let message_path = contact_store()
                .lock()
                .map_err(|_| CoreError::Internal)?
                .message_path
                .clone()
                .ok_or(CoreError::FeatureUnavailable)?;
            let message_id = groups::new_id();
            let message = StoredMessage {
                id: message_id.clone(),
                conversation_id: conversation_id.to_owned(),
                author_id: "me".to_owned(),
                author_name: None,
                body: groups::encode_channel_text(&format!("📎 {file_name}"), None, channel_id)?,
                sent_at_ms: current_time_ms()?,
                received_at_ms: 0,
                is_outgoing: true,
                is_read: true,
                delivery_state: "delivered".to_owned(),
                receipts: Default::default(),
                attachment_name: Some(file_name),
                attachment_base64: Some(STANDARD.encode(bytes)),
                attachment_pointer: None,
            };
            queue_outgoing(&message_path, message, vec![])?;
            return Ok(json!({"message_id": message_id, "delivery_state": "delivered"}));
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
            channel_id: channel_id.map(str::to_owned),
        };
        let control = format!(
            "{ATTACHMENT_PREFIX}{}",
            STANDARD_NO_PAD.encode(serde_json::to_vec(&pointer).map_err(|_| CoreError::Internal)?,)
        );
        let wrapped = format!(
            "{GROUP_MESSAGE_PREFIX}{conversation_id}:{}",
            STANDARD_NO_PAD.encode(control.as_bytes())
        );
        let mut deliveries = Vec::new();
        let mut id_bytes = [0_u8; 16];
        OsRng.fill_bytes(&mut id_bytes);
        for member in &group.members {
            let result = secure_packet::seal_for_all_with_id(&member.identity, &wrapped, &id_bytes);
            match result {
                Ok((mut sealed, _)) => deliveries.append(&mut sealed),
                Err(error) => {
                    let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
                    remove_attachment_lease(&record_key);
                    return Err(error);
                }
            }
        }
        let message_path = contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let message_id = compact_hex(&id_bytes);
        let message = StoredMessage {
            id: message_id.clone(),
            conversation_id: conversation_id.to_owned(),
            author_id: "me".to_owned(),
            body: groups::encode_channel_text(&format!("📎 {file_name}"), None, channel_id)?,
            sent_at_ms: current_time_ms()?,
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: "queued".to_owned(),
            receipts: Default::default(),
            attachment_name: Some(file_name),
            attachment_base64: Some(STANDARD.encode(bytes)),
            attachment_pointer: None,
        };
        if let Err(error) = queue_outgoing(&message_path, message, deliveries) {
            let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
            remove_attachment_lease(&record_key);
            return Err(error);
        }
        return Ok(json!({
            "message_id": message_id,
            "delivery_state": "queued"
        }));
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
        channel_id: None,
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
        received_at_ms: 0,
        author_name: None,
        is_outgoing: true,
        is_read: true,
        delivery_state: "queued".to_owned(),
        receipts: Default::default(),
        attachment_name: Some(file_name),
        attachment_base64: Some(STANDARD.encode(bytes)),
        attachment_pointer: None,
    };
    if let Err(error) = queue_outgoing(&message_path, message, deliveries) {
        let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
        remove_attachment_lease(&record_key);
        return Err(error);
    }
    Ok(json!({
        "message_id": message_id,
        "delivery_state": "queued"
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

pub fn mark_channel_read(conversation_id: &str, channel_id: Option<&str>) -> CoreResult<Value> {
    let group = current_group(conversation_id)?.ok_or(CoreError::InvalidInput)?;
    groups::enforce_channel(&group, channel_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let matches = |message: &StoredMessage| {
        message.conversation_id == conversation_id
            && !message.is_outgoing
            && groups::rich_metadata(&message.body)
                .is_ok_and(|(_, _, id)| id.as_deref() == channel_id)
    };
    if store
        .messages
        .iter()
        .any(|message| matches(message) && !message.is_read)
    {
        append_message_event(
            &path,
            &MessageEvent::MarkChannelRead {
                conversation_id: conversation_id.to_owned(),
                channel_id: channel_id.map(str::to_owned),
            },
        )?;
        for message in &mut store.messages {
            if matches(message) {
                message.is_read = true;
            }
        }
        store.message_event_count += 1;
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
    }
    Ok(
        json!({"all_read": !store.messages.iter().any(|message| message.conversation_id == conversation_id && !message.is_outgoing && !message.is_read)}),
    )
}

pub fn delete_conversation(conversation_id: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    if store.groups.iter().any(|group| group.id == conversation_id) {
        let path = store
            .groups_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let mut updated = store.groups.clone();
        let group = updated
            .iter_mut()
            .find(|group| group.id == conversation_id)
            .unwrap();
        groups::prepare_leave(group)?;
        let departure = group.clone();
        let message_path = store
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        ensure_messages_loaded(&mut store)?;
        cancel_pending_conversation(&mut store, conversation_id)?;
        let messages = store
            .messages
            .iter()
            .filter(|message| message.conversation_id != conversation_id)
            .cloned()
            .collect::<Vec<_>>();
        persist_groups(&path, &updated)?;
        append_message_event(
            &message_path,
            &MessageEvent::DeleteConversation {
                conversation_id: conversation_id.to_owned(),
            },
        )?;
        store.groups = updated;
        store.messages = messages;
        store.message_event_count += 1;
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
        drop(store);
        queue_device_sync(&DeviceSyncEvent::UpsertGroup { group: departure });
        return Ok(json!({"conversation_id": conversation_id, "deleted": true}));
    }
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
    cancel_pending_conversation(&mut store, conversation_id)?;
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

fn cancel_pending_conversation(store: &mut ContactStore, conversation_id: &str) -> CoreResult<()> {
    let message_ids = store
        .messages
        .iter()
        .filter(|message| message.conversation_id == conversation_id)
        .map(|message| message.id.as_str())
        .collect::<HashSet<_>>();
    let retained = store
        .outbox
        .iter()
        .filter(|entry| !message_ids.contains(entry.message_id.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    if retained.len() != store.outbox.len() {
        persist_outbox(
            store
                .outbox_path
                .as_deref()
                .ok_or(CoreError::FeatureUnavailable)?,
            &retained,
        )?;
        store.outbox = retained;
    }
    Ok(())
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
    attachments::poll()?;
    let Ok(_sync_guard) = SYNC_LOCK.try_lock() else {
        let revision = contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .revision;
        return Ok(json!({"persisted": 0, "discarded": 0, "revision": revision}));
    };
    // Loading/decrypting a large vault can be expensive. This command is
    // always invoked on the Dart background executor, so warm it here before
    // synchronous UI reads access the in-memory message index.
    {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
    }
    refresh_contact_directory();
    let pinned_before = contact_store()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .groups
        .iter()
        .flat_map(|group| {
            group
                .management
                .pinned
                .iter()
                .map(|id| (group.id.clone(), id.clone()))
        })
        .collect::<HashSet<_>>();
    let _ = configure_offline_receivers();
    cleanup_expired_attachments();
    let payloads = veilid_adapter::take_inbound_payloads()?;
    let mut persisted = 0_usize;
    let mut discarded = 0_usize;
    let mut storage_full = false;
    for payload in payloads {
        match persist_inbound_payload(&payload.payload) {
            Ok(is_new) => {
                persisted += usize::from(is_new);
                veilid_adapter::acknowledge_inbound_payload(payload)?;
            }
            Err(error) if should_discard_inbound(&error) => {
                // A permanently invalid packet must not poison one of the
                // finite mailbox slots. Transient storage/network failures are
                // deliberately left unacknowledged and will be fetched again.
                discarded += 1;
                let _ = veilid_adapter::acknowledge_inbound_payload(payload);
            }
            Err(error) => {
                storage_full |= matches!(error, CoreError::StorageFull);
                veilid_adapter::retry_inbound_payload(payload);
            }
        }
    }
    // Receive first: a slow or unavailable recipient must not delay messages
    // that have already arrived for us.
    groups::process_requests();
    receipts::flush();
    let _ = flush_outbox(None);
    flush_device_sync_outbox();
    let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let revision = store.revision;
    let pin_notification = store.groups.iter().any(|group| {
        group
            .management
            .pinned
            .iter()
            .any(|id| !pinned_before.contains(&(group.id.clone(), id.clone())))
    });
    Ok(
        json!({"persisted": persisted, "discarded": discarded, "revision": revision, "storage_full": storage_full, "pin_notification": pin_notification}),
    )
}

fn configure_offline_receivers() -> CoreResult<()> {
    let local = identity::active_identity()?;
    let local_id = local.identity_public_key()?;
    let local_device = ratchet_adapter::public_pre_key_bundle()?
        .ok_or(CoreError::FeatureUnavailable)?
        .device_id;
    let bundles =
        {
            let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
            let peers =
                store
                    .contacts
                    .iter()
                    .filter_map(|contact| contact.published_identity.clone())
                    .chain(store.groups.iter().flat_map(|group| {
                        group.members.iter().map(|member| member.identity.clone())
                    }))
                    .collect::<Vec<_>>();
            let mut bundles = store
                .contacts
                .iter()
                .flat_map(|contact| contact.previous_bundles.clone())
                .collect::<Vec<_>>();
            for peer in peers {
                bundles.extend(
                    peer.delivery_devices()?
                        .into_iter()
                        .map(|device| device.bundle),
                );
            }
            bundles
        };
    let receiving_secrets = local.receiving_x25519_secrets()?;
    let mut seen_bundles = HashSet::new();
    let mut seen = HashSet::new();
    let mut targets = Vec::new();
    for bundle in bundles {
        if bundle.identity_ed25519 == local_id {
            continue;
        }
        let remote_device = bundle
            .signal_pre_key
            .as_ref()
            .ok_or(CoreError::UnsupportedVersion)?
            .device_id;
        // A peer can occur in the address book and several groups. Derive
        // its mailboxes once, retaining distinct devices and rotated prekeys.
        if !seen_bundles.insert((
            bundle.identity_ed25519.clone(),
            bundle.signed_prekey_x25519.clone(),
            remote_device,
        )) {
            continue;
        }
        for secret in &receiving_secrets {
            let keys = crate::offline_mailbox::MailboxKeys::derive(
                secret,
                &bundle.signed_prekey_x25519,
                &bundle.identity_ed25519,
                &local_id,
                remote_device,
                local_device,
            )?;
            if seen.insert(keys.id()) {
                targets.push(keys);
            }
        }
    }
    veilid_adapter::set_offline_targets(targets)
}

// Resolve one known short invitation at a time off the FFI thread. A contact
// can rotate prekeys while we are offline; refreshing only when sending would
// leave a receive-only user polling the old mailbox forever.
fn refresh_contact_directory() {
    use std::sync::mpsc::{self, TryRecvError};
    let Ok(mut refresh) = PEER_REFRESH
        .get_or_init(|| Mutex::new(PeerRefresh::default()))
        .lock()
    else {
        return;
    };
    let Ok(mut store) = contact_store().lock() else {
        return;
    };
    if refresh.generation != store.generation {
        *refresh = PeerRefresh {
            generation: store.generation,
            ..Default::default()
        };
    }
    if let Some(receiver) = &refresh.receiver {
        match receiver.try_recv() {
            Ok((id, Ok(published))) => {
                let mut contacts = store.contacts.clone();
                if let Some(contact) = contacts.iter_mut().find(|contact| contact.id == id) {
                    let changed = contact
                        .published_identity
                        .as_ref()
                        .and_then(|value| serde_json::to_vec(value).ok())
                        != serde_json::to_vec(&published).ok();
                    if changed
                        && published.bundle.expires_at_ms > current_time_ms().unwrap_or(u64::MAX)
                        && update_contact_identity(contact, published.clone()).is_ok()
                    {
                        if let Some(path) = &store.path {
                            if persist_contacts(path, &contacts).is_ok() {
                                store.contacts = contacts;
                                store.revision = store.revision.wrapping_add(1);
                            }
                        }
                    }
                }
                let _ = update_group_endpoints(&mut store, &id, &published);
            }
            Err(TryRecvError::Empty) => return,
            _ => {}
        }
        refresh.receiver = None;
    }
    let now = current_time_ms().unwrap_or(0);
    if now < refresh.next_attempt_ms {
        return;
    }
    let mut contacts = store
        .contacts
        .iter()
        .filter_map(|contact| {
            contact
                .invitation_code
                .as_ref()
                .filter(|code| code.starts_with("sylphy:VLD") || code.starts_with("VLD"))
                .map(|code| (contact.id.clone(), code.clone()))
        })
        .collect::<Vec<_>>();
    for member in store.groups.iter().flat_map(|group| &group.members) {
        if let Some(code) = &member.invitation_code {
            if !contacts.iter().any(|(id, _)| id == &member.id) {
                contacts.push((member.id.clone(), code.clone()));
            }
        }
    }
    if contacts.is_empty() {
        return;
    }
    let (id, invitation) = contacts[refresh.cursor % contacts.len()].clone();
    refresh.cursor = refresh.cursor.wrapping_add(1);
    refresh.next_attempt_ms = now.saturating_add(10_000);
    let (sender, receiver) = mpsc::channel();
    if std::thread::Builder::new()
        .name("sylphy-contact-refresh".to_owned())
        .spawn(move || {
            let _ = sender.send((id, veilid_adapter::resolve_identity(&invitation)));
        })
        .is_ok()
    {
        refresh.receiver = Some(receiver);
    }
}

fn should_discard_inbound(error: &CoreError) -> bool {
    matches!(
        error,
        CoreError::InvalidInput
            | CoreError::UnsupportedVersion
            | CoreError::AuthenticationFailed
            | CoreError::GroupPermissionDenied
            | CoreError::GroupClosed
            | CoreError::SlowModeActive
            | CoreError::SpamRejected
            | CoreError::VerificationFailed
            | CoreError::LimitExceeded
    )
}

fn persist_inbound_payload(payload: &[u8]) -> CoreResult<bool> {
    persist_inbound_payload_with(payload, veilid_adapter::fetch_attachment_blob)
}

fn persist_inbound_payload_with(
    payload: &[u8],
    fetch: impl FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<bool> {
    if let Some(encrypted) = payload.strip_prefix(crate::device_sync::PREFIX) {
        let key = identity::active_identity()?.storage_key()?;
        let plaintext =
            crate::device_sync::open_reference(&key, encrypted, veilid_adapter::fetch_sync_blob)?;
        let before = contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .revision;
        apply_device_sync_plaintext(&plaintext)?;
        return Ok(contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .revision
            != before);
    }
    if let Some(encrypted) = payload.strip_prefix(DEVICE_SYNC_PREFIX) {
        let before = contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .revision;
        apply_device_sync(encrypted)?;
        return Ok(contact_store()
            .lock()
            .map_err(|_| CoreError::Internal)?
            .revision
            != before);
    }
    let inspected = secure_packet::inspect(payload)?;
    if inspected.sent_at_ms > current_time_ms()?.saturating_add(MAX_CLOCK_SKEW_MS) {
        return Err(CoreError::VerificationFailed);
    }
    let id = contact_id(&inspected.sender.bundle.identity_ed25519);
    {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
        if store.messages.iter().any(|message| {
            message.id == inspected.message_id && !legacy_attachment_placeholder(message)
        }) {
            return Ok(false);
        }
    }
    let mut opened = secure_packet::open(payload)?;
    if let Some(changed) = receipts::receive(&opened.plaintext, &opened.sender)? {
        opened.commit_ratchet()?;
        return Ok(changed);
    }
    if groups::is_control(&opened.plaintext) {
        let changed = groups::receive(&opened.plaintext, &opened.sender, fetch)?.unwrap_or(false);
        opened.commit_ratchet()?;
        return Ok(changed);
    }
    if let Some(invitation) = decode_group_invitation_with(&opened.plaintext, fetch)? {
        if current_group(&invitation.group.id)?.is_some_and(|group| group.management.left) {
            opened.commit_ratchet()?;
            return Ok(false);
        }
        let mut sender = group_member(opened.sender.clone())?;
        if invitation.version != 1
            || invitation.group.admin_id != sender.id
            || invitation.admin.id != sender.id
            || invitation.admin.fingerprint != sender.fingerprint
            || invitation.group.members.len() > MAX_GROUP_MEMBERS
        {
            return Err(CoreError::VerificationFailed);
        }
        sender.invitation_code = invitation.admin.invitation_code;
        let mut group = invitation.group;
        validate_groups(std::slice::from_ref(&group))?;
        let local_id = contact_id(&identity::active_identity()?.identity_public_key()?);
        if !group.members.iter().any(|member| member.id == local_id) {
            return Err(CoreError::AuthenticationFailed);
        }
        // Store only remote endpoints, as on the creator's device. Otherwise
        // replies are sent back to ourselves and the member count is inflated.
        group.members.retain(|member| member.id != local_id);
        if !group.members.iter().any(|member| member.id == sender.id) {
            group.members.push(sender.clone());
        }
        validate_groups(std::slice::from_ref(&group))?;
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        if !allows_unknown_contacts()?
            && !store.contacts.iter().any(|contact| contact.id == sender.id)
        {
            return Err(CoreError::AuthenticationFailed);
        }
        let path = store
            .groups_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let is_new = !store.groups.iter().any(|item| item.id == group.id);
        if let Some(existing) = store.groups.iter().find(|item| item.id == group.id) {
            if existing.name != group.name || existing.admin_id != group.admin_id {
                return Err(CoreError::VerificationFailed);
            }
        } else {
            if store.groups.len() >= MAX_CONTACTS {
                return Err(CoreError::StorageFull);
            }
            let mut updated = store.groups.clone();
            updated.push(group);
            persist_groups(&path, &updated)?;
            store.groups = updated;
            store.revision = store.revision.wrapping_add(1);
        }
        drop(store);
        opened.commit_ratchet()?;
        return Ok(is_new);
    }
    let (conversation_id, plaintext) =
        if let Some((group_id, body)) = decode_group_message(&opened.plaintext)? {
            let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
            if let Some(group) = store.groups.iter().find(|group| group.id == group_id) {
                let sender_id = contact_id(&opened.sender.bundle.identity_ed25519);
                if group.management.closed || group.management.removed {
                    return Err(CoreError::GroupClosed);
                }
                if group
                    .management
                    .deleted_messages
                    .contains(&opened.message_id)
                {
                    drop(store);
                    opened.commit_ratchet()?;
                    return Ok(false);
                }
                if !group.members.iter().any(|member| member.id == sender_id)
                    && group.admin_id != sender_id
                {
                    return Err(CoreError::AuthenticationFailed);
                }
                let group = group.clone();
                drop(store);
                let (text, _, mut channel) = groups::rich_metadata(&body)?;
                if let Some(encoded) = body.strip_prefix(ATTACHMENT_PREFIX) {
                    let pointer: AttachmentPointer = serde_json::from_slice(
                        &STANDARD_NO_PAD
                            .decode(encoded)
                            .map_err(|_| CoreError::InvalidInput)?,
                    )
                    .map_err(|_| CoreError::InvalidInput)?;
                    channel = pointer.channel_id;
                }
                // A deleted channel is final; do not keep retrying late packets
                // as though their channel snapshot had not arrived yet.
                if channel
                    .as_ref()
                    .is_some_and(|id| group.management.deleted_channels.contains(id))
                {
                    opened.commit_ratchet()?;
                    return Ok(false);
                }
                // A channel snapshot may arrive after its first message.
                groups::enforce_channel(&group, channel.as_deref())
                    .map_err(|_| CoreError::InboundDeferred)?;
                groups::enforce_inbound(
                    &group,
                    &sender_id,
                    &text,
                    body.starts_with(ATTACHMENT_PREFIX),
                )?;
                (group_id, body)
            } else {
                // DHT delivery is unordered, including for known contacts.
                // Keep the authenticated packet until its group invitation arrives.
                return Err(CoreError::FeatureUnavailable);
            }
        } else {
            if !allows_unknown_contacts()? {
                let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
                if !store.contacts.iter().any(|contact| contact.id == id) {
                    return Err(CoreError::AuthenticationFailed);
                }
            }
            (id.clone(), opened.plaintext.clone())
        };
    // Persist the authenticated reference and commit the ratchet without fetching
    // any file. Downloads require an explicit local request on a separate worker.
    let attachment_pointer = parse_attachment_pointer(&plaintext)?;
    let (body, attachment_name) = if let Some(pointer) = &attachment_pointer {
        (attachment_body(pointer)?, Some(pointer.file_name.clone()))
    } else {
        groups::text_metadata(&plaintext)?;
        (plaintext, None)
    };
    let message = StoredMessage {
        id: opened.message_id.clone(),
        conversation_id: conversation_id.clone(),
        author_id: id.clone(),
        body,
        sent_at_ms: opened.sent_at_ms,
        received_at_ms: current_time_ms()?,
        author_name: opened.sender.profile.display_name.clone(),
        is_outgoing: false,
        is_read: false,
        delivery_state: "delivered".to_owned(),
        receipts: Default::default(),
        attachment_name,
        attachment_base64: None,
        attachment_pointer,
    };
    validate_stored_message(&message)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    ensure_messages_loaded(&mut store)?;
    if let Some(existing) = store.messages.iter().find(|item| item.id == message.id) {
        if !legacy_attachment_placeholder(existing) {
            return Ok(false);
        }
        let previous = existing.clone();
        let merged = merge_synced_message(existing, &message)?;
        upsert_synced_message(&mut store, &message_path, merged)?;
        store.revision = store.revision.wrapping_add(1);
        drop(store);
        if let Err(error) = opened.commit_ratchet() {
            let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
            append_message_event(
                &message_path,
                &MessageEvent::Upsert {
                    message: previous.clone(),
                },
            )?;
            if let Some(item) = store
                .messages
                .iter_mut()
                .find(|item| item.id == previous.id)
            {
                *item = previous;
            }
            store.revision = store.revision.wrapping_add(1);
            return Err(error);
        }
        return Ok(true);
    }
    if store.messages.len() >= MAX_MESSAGES {
        return Err(CoreError::StorageFull);
    }
    let is_group = store.groups.iter().any(|group| group.id == conversation_id);
    if is_group {
        update_group_endpoints(&mut store, &id, &opened.sender)?;
    } else if let Some(contact) = store.contacts.iter_mut().find(|contact| contact.id == id) {
        update_contact_identity(contact, opened.sender.clone())?;
    } else if allows_unknown_contacts()? {
        if store.contacts.len() >= MAX_CONTACTS {
            return Err(CoreError::StorageFull);
        }
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
            previous_bundles: Vec::new(),
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
        if !is_group {
            queue_device_sync(&DeviceSyncEvent::UpsertMessage {
                contact,
                message: message.clone(),
            });
        }
    }
    if is_group {
        let group = contact_store().lock().ok().and_then(|store| {
            store
                .groups
                .iter()
                .find(|group| group.id == conversation_id)
                .cloned()
        });
        if let Some(group) = group {
            queue_device_sync(&DeviceSyncEvent::UpsertGroupMessage { group, message });
        }
    }
    Ok(true)
}

#[cfg(test)]
pub(crate) fn receive_for_test(payload: &[u8]) -> CoreResult<()> {
    persist_inbound_payload(payload).map(|_| ())
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
        attempts: 0,
        next_attempt_ms: 0,
        blob: None,
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
    let now = current_time_ms().unwrap_or_default();
    let generation = match contact_store().lock() {
        Ok(store) => store.generation,
        Err(_) => return,
    };
    let Some(results) = crate::device_sync::poll(generation, || {
        let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        if store.generation != generation {
            return Err(CoreError::FeatureUnavailable);
        }
        let pending = store
            .device_sync_outbox
            .iter()
            .filter(|item| item.next_attempt_ms <= now)
            .take(2)
            .cloned()
            .collect::<Vec<_>>();
        drop(store);
        if pending.is_empty() {
            return Err(CoreError::FeatureUnavailable);
        }
        let context = crate::device_sync::Context {
            key: zeroize::Zeroizing::new(identity::active_identity()?.storage_key()?),
            descriptor: identity::active_dht_descriptor()?.ok_or(CoreError::FeatureUnavailable)?,
            device_id: ratchet_adapter::public_pre_key_bundle()?
                .ok_or(CoreError::FeatureUnavailable)?
                .device_id,
            mailbox: crate::peer_identity::current_public_mailbox(),
        };
        let prepared = pending
            .into_iter()
            .filter_map(|item| {
                serde_json::to_vec(&item.event)
                    .ok()
                    .map(|encoded| crate::device_sync::Pending {
                        id: item.id,
                        encoded: zeroize::Zeroizing::new(encoded),
                        blob: item.blob,
                    })
            })
            .collect();
        Ok((prepared, context))
    }) else {
        return;
    };
    let Ok(mut store) = contact_store().lock() else {
        return;
    };
    if store.generation != generation {
        return;
    }
    let Some(path) = store.device_sync_outbox_path.clone() else {
        return;
    };
    let mut retained = store.device_sync_outbox.clone();
    let mut leases = store.attachment_leases.clone();
    for result in results {
        if let Some(blob) = &result.blob {
            if !leases
                .iter()
                .any(|lease| lease.record_key == blob.record_key)
            {
                leases.push(AttachmentLease {
                    record_key: blob.record_key.clone(),
                    chunk_count: blob.chunk_count,
                    delete_after_ms: blob.created_at_ms.saturating_add(ATTACHMENT_RETENTION_MS),
                });
            }
        }
        if result.delivered {
            retained.retain(|item| item.id != result.id);
        } else if let Some(item) = retained.iter_mut().find(|item| item.id == result.id) {
            item.attempts = item.attempts.saturating_add(1);
            item.next_attempt_ms = now.saturating_add(retry_delay_ms(item.attempts));
            item.blob = result.blob;
        }
    }
    if let Some(lease_path) = &store.attachment_lease_path {
        if persist_attachment_leases(lease_path, &leases).is_err() {
            return;
        }
        store.attachment_leases = leases;
    }
    if persist_device_sync_outbox(&path, &retained).is_ok() {
        store.device_sync_outbox = retained;
    }
}
fn queue_outgoing(
    message_path: &Path,
    mut message: StoredMessage,
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
                is_control: false,
                id: compact_hex(&digest.finalize()[..16]),
                message_id: message.id.clone(),
                route_blob: delivery.route_blob,
                payload: delivery.payload,
                created_at_ms: now_ms,
                offline_keys: delivery.offline_keys,
                attempts: 0,
                next_attempt_ms: 0,
            }
        })
        .collect::<Vec<_>>();
    if pending.is_empty() {
        let group =
            current_group(&message.conversation_id)?.ok_or(CoreError::VerificationFailed)?;
        if !group.members.is_empty() || !groups::can_write(&group)? {
            return Err(CoreError::VerificationFailed);
        }
        message.delivery_state = "delivered".to_owned();
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    message.receipts.recipients = store
        .groups
        .iter()
        .find(|group| group.id == message.conversation_id)
        .map(|group| {
            group
                .members
                .iter()
                .map(|member| member.id.clone())
                .collect()
        })
        .unwrap_or_else(|| vec![message.conversation_id.clone()]);
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
    let _ = compact_message_log_if_needed(&mut store);
    Ok(())
}

fn flush_outbox(only_message_id: Option<&str>) -> bool {
    let now = current_time_ms().unwrap_or(0);
    let (generation, pending) = match contact_store().lock() {
        Ok(store) => (
            store.generation,
            store
                .outbox
                .iter()
                .filter(|item| only_message_id.is_none_or(|id| item.message_id == id))
                .filter(|item| item.next_attempt_ms <= now)
                .take(4)
                .cloned()
                .collect::<Vec<_>>(),
        ),
        Err(_) => return false,
    };
    let Some(results) = poll_outbox_transport(generation, pending) else {
        return false;
    };
    let mut delivered_ids = HashSet::new();
    let mut delivered_counts: HashMap<String, usize> = HashMap::new();
    let mut failed_ids = HashSet::new();
    for (item, delivered) in results {
        if delivered {
            delivered_ids.insert(item.id);
            *delivered_counts.entry(item.message_id).or_default() += 1;
        } else {
            failed_ids.insert(item.id);
        }
    }
    let sync_events = (|| -> CoreResult<Vec<DeviceSyncEvent>> {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        if store.generation != generation {
            return Err(CoreError::FeatureUnavailable);
        }
        let outbox_path = store
            .outbox_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let message_path = store
            .message_path
            .clone()
            .ok_or(CoreError::FeatureUnavailable)?;
        let mut retained = store
            .outbox
            .iter()
            .filter(|item| !delivered_ids.contains(&item.id))
            .cloned()
            .collect::<Vec<_>>();
        for entry in &mut retained {
            if failed_ids.contains(&entry.id) {
                entry.attempts = entry.attempts.saturating_add(1);
                entry.next_attempt_ms = now.saturating_add(retry_delay_ms(entry.attempts));
            }
        }
        let delivered_messages = delivered_counts
            .keys()
            .filter(|id| !retained.iter().any(|item| &item.message_id == *id))
            .cloned()
            .collect::<HashSet<_>>();
        let mut events = Vec::new();
        for message_id in delivered_messages {
            let Some(index) = store.messages.iter().position(|item| item.id == message_id) else {
                continue;
            };
            if store.messages[index].delivery_state == "queued" {
                let mut message = store.messages[index].clone();
                message.delivery_state = "sent".to_owned();
                append_message_event(
                    &message_path,
                    &MessageEvent::Upsert {
                        message: message.clone(),
                    },
                )?;
                store.messages[index] = message.clone();
                store.message_event_count += 1;
                if let Some(contact) = store
                    .contacts
                    .iter()
                    .find(|item| item.id == message.conversation_id)
                    .cloned()
                {
                    events.push(DeviceSyncEvent::UpsertMessage { contact, message });
                } else if let Some(group) = store
                    .groups
                    .iter()
                    .find(|item| item.id == message.conversation_id)
                    .cloned()
                {
                    events.push(DeviceSyncEvent::UpsertGroupMessage { group, message });
                }
            }
        }
        // Save read models before removing durable ciphertext. A crash may
        // cause a harmless duplicate, never a message stuck queued forever.
        persist_outbox(&outbox_path, &retained)?;
        store.outbox = retained;
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
        Ok(events)
    })();
    let Ok(sync_events) = sync_events else {
        return false;
    };
    for event in sync_events {
        queue_device_sync(&event);
    }
    contact_store().lock().is_ok_and(|store| {
        !store
            .outbox
            .iter()
            .any(|entry| only_message_id.is_none_or(|id| entry.message_id == id))
    })
}

// Only network work runs on this thread. Vault mutations are applied by the
// next sync command, after checking the account generation. Slow/offline peers
// therefore cannot monopolize Flutter's native command queue.
fn poll_outbox_transport(
    generation: u64,
    pending: Vec<PendingDelivery>,
) -> Option<TransportResults> {
    use std::sync::mpsc::{self, TryRecvError};
    let mut active = OUTBOX_TRANSPORT.lock().ok()?;
    if let Some((previous, receiver)) = active.as_ref() {
        if *previous == generation {
            match receiver.try_recv() {
                Ok(results) => {
                    // Keep collecting this batch: each destination reports
                    // independently, without waiting for slower/offline peers.
                    return Some(results);
                }
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {}
            }
        }
        *active = None;
    }
    if pending.is_empty() {
        return None;
    }
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name("sylphy-outbox".to_owned())
        .spawn(move || {
            std::thread::scope(|scope| {
                for item in pending {
                    let sender = sender.clone();
                    scope.spawn(move || {
                        let delivered = deliver_with_offline_fallback(
                            || {
                                veilid_adapter::deliver_payload(
                                    &item.route_blob,
                                    None,
                                    item.payload.clone(),
                                )
                            },
                            || {
                                item.offline_keys.as_ref().map_or(
                                    Err(CoreError::FeatureUnavailable),
                                    |keys| {
                                        veilid_adapter::store_offline_payload(keys, &item.payload)
                                    },
                                )
                            },
                        );
                        let _ = sender.send(vec![(item, delivered)]);
                    });
                }
            });
        })
        .ok()?;
    *active = Some((generation, receiver));
    None
}

fn deliver_with_offline_fallback(
    direct: impl FnOnce() -> CoreResult<()>,
    offline: impl FnOnce() -> CoreResult<()>,
) -> bool {
    // Either handoff is sufficient for `sent`. Do not hold a successful
    // direct send hostage to an unavailable/full offline mailbox.
    direct().is_ok() || offline().is_ok()
}

fn retry_delay_ms(attempts: u32) -> u64 {
    (5_000_u64 << attempts.saturating_sub(1).min(6)).min(300_000)
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
        update_contact_identity(contact, refreshed.clone())?;
        persist_contacts(&contact_path, &store.contacts)?;
        store.revision = store.revision.wrapping_add(1);
    }
    Ok(refreshed)
}

fn apply_device_sync(encrypted: &[u8]) -> CoreResult<()> {
    let plaintext = vault::open_with_key(&identity::active_identity()?.storage_key()?, encrypted)?;
    apply_device_sync_plaintext(&plaintext)
}

fn apply_device_sync_plaintext(plaintext: &[u8]) -> CoreResult<()> {
    let event: DeviceSyncEvent =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let contact_path = store.path.clone().ok_or(CoreError::FeatureUnavailable)?;
    let message_path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let groups_path = store
        .groups_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    ensure_messages_loaded(&mut store)?;
    let mut changed = false;
    match event {
        DeviceSyncEvent::UpsertContact { contact } => {
            validate_conversation_id(&contact.id)?;
            contact.bundle.validate()?;
            validate_previous_bundles(&contact)?;
            if let Some(existing) = store.contacts.iter_mut().find(|item| item.id == contact.id) {
                if !same_contact(existing, &contact) {
                    *existing = contact;
                    changed = true;
                }
            } else if store.contacts.len() < MAX_CONTACTS {
                store.contacts.push(contact);
                changed = true;
            } else {
                return Err(CoreError::StorageFull);
            }
        }
        DeviceSyncEvent::UpsertMessage { contact, message } => {
            if message.conversation_id != contact_id(&contact.bundle.identity_ed25519) {
                return Err(CoreError::VerificationFailed);
            }
            validate_conversation_id(&contact.id)?;
            validate_stored_message(&message)?;
            contact.bundle.validate()?;
            validate_previous_bundles(&contact)?;
            if let Some(existing) = store.contacts.iter_mut().find(|item| item.id == contact.id) {
                if !same_contact(existing, &contact) {
                    *existing = contact;
                    changed = true;
                }
            } else if store.contacts.len() < MAX_CONTACTS {
                store.contacts.push(contact);
                changed = true;
            } else {
                return Err(CoreError::StorageFull);
            }
            changed |= upsert_synced_message(&mut store, &message_path, message)?;
        }
        DeviceSyncEvent::UpsertGroup { mut group } => {
            validate_groups(std::slice::from_ref(&group))?;
            if let Some(existing) = store.groups.iter_mut().find(|item| item.id == group.id) {
                groups::preserve_local_queues(existing, &mut group);
                if ((group.management.left && !existing.management.left)
                    || (group.management.revision >= existing.management.revision
                        && !existing.management.closed))
                    && serde_json::to_vec(existing).ok() != serde_json::to_vec(&group).ok()
                {
                    *existing = group;
                    changed = true;
                }
            } else if store.groups.len() < MAX_CONTACTS {
                store.groups.push(group);
                changed = true;
            } else {
                return Err(CoreError::StorageFull);
            }
        }
        DeviceSyncEvent::UpsertGroupMessage { mut group, message } => {
            validate_groups(std::slice::from_ref(&group))?;
            validate_stored_message(&message)?;
            if message.conversation_id != group.id {
                return Err(CoreError::VerificationFailed);
            }
            if let Some(existing) = store.groups.iter_mut().find(|item| item.id == group.id) {
                groups::preserve_local_queues(existing, &mut group);
                if ((group.management.left && !existing.management.left)
                    || (group.management.revision >= existing.management.revision
                        && !existing.management.closed))
                    && serde_json::to_vec(existing).ok() != serde_json::to_vec(&group).ok()
                {
                    *existing = group.clone();
                    changed = true;
                }
            } else if store.groups.len() < MAX_CONTACTS {
                store.groups.push(group);
                changed = true;
            } else {
                return Err(CoreError::StorageFull);
            }
            if !store.groups.iter().any(|group| {
                group.id == message.conversation_id
                    && (group.management.closed
                        || group.management.left
                        || group.management.removed
                        || groups::message_deleted(group, &message))
            }) {
                changed |= upsert_synced_message(&mut store, &message_path, message)?;
            }
        }
    }
    // A previous attempt may have updated RAM before a disk failure. Retry
    // persistence even when this replay no longer changes the in-memory value.
    let left = store
        .groups
        .iter()
        .filter(|group| group.management.left)
        .map(|group| group.id.clone())
        .collect::<HashSet<_>>();
    for id in &left {
        cancel_pending_conversation(&mut store, id)?;
    }
    if store
        .messages
        .iter()
        .any(|message| left.contains(&message.conversation_id))
    {
        let messages = store
            .messages
            .iter()
            .filter(|message| !left.contains(&message.conversation_id))
            .cloned()
            .collect::<Vec<_>>();
        write_message_snapshot(&message_path, &messages)?;
        store.messages = messages;
        changed = true;
    }
    persist_contacts(&contact_path, &store.contacts)?;
    persist_groups(&groups_path, &store.groups)?;
    if changed {
        store.revision = store.revision.wrapping_add(1);
        compact_message_log_if_needed(&mut store)?;
    }
    Ok(())
}

fn merge_synced_message(
    existing: &StoredMessage,
    incoming: &StoredMessage,
) -> CoreResult<StoredMessage> {
    if existing.id != incoming.id
        || existing.conversation_id != incoming.conversation_id
        || existing.author_id != incoming.author_id
        || existing.sent_at_ms != incoming.sent_at_ms
        || existing.is_outgoing != incoming.is_outgoing
        || existing.body != incoming.body
    {
        return Err(CoreError::VerificationFailed);
    }
    let mut merged = existing.clone();
    receipts::merge(&mut merged.receipts, &incoming.receipts);
    let rank = |state: &str| match state {
        "not_restored" => 0,
        "queued" => 1,
        "sent" => 2,
        "delivered" => 3,
        "read" => 4,
        _ => 0,
    };
    if rank(&incoming.delivery_state) > rank(&existing.delivery_state) {
        merged.delivery_state = incoming.delivery_state.clone();
    }
    receipts::refresh_state(&mut merged);
    if existing.attachment_base64.is_none() && incoming.attachment_base64.is_some() {
        merged.attachment_name = incoming.attachment_name.clone();
        merged.attachment_base64 = incoming.attachment_base64.clone();
    }
    if merged.attachment_pointer.is_none() {
        merged.attachment_pointer = incoming.attachment_pointer.clone();
        if merged.attachment_name.is_none() {
            merged.attachment_name = incoming.attachment_name.clone();
        }
    }
    // Reading on one device must not overwrite the local read state.
    Ok(merged)
}

fn legacy_attachment_placeholder(message: &StoredMessage) -> bool {
    !message.is_outgoing
        && message.attachment_base64.is_none()
        && message.attachment_name.is_none()
        && message.body.starts_with("📎 ")
}

fn upsert_synced_message(
    store: &mut ContactStore,
    path: &Path,
    message: StoredMessage,
) -> CoreResult<bool> {
    if let Some(index) = store.messages.iter().position(|item| item.id == message.id) {
        let merged = merge_synced_message(&store.messages[index], &message)?;
        if serde_json::to_vec(&merged).ok() == serde_json::to_vec(&store.messages[index]).ok() {
            return Ok(false);
        }
        append_message_event(
            path,
            &MessageEvent::Upsert {
                message: merged.clone(),
            },
        )?;
        store.messages[index] = merged;
    } else {
        if store.messages.len() >= MAX_MESSAGES {
            return Err(CoreError::StorageFull);
        }
        append_message_event(
            path,
            &MessageEvent::Upsert {
                message: message.clone(),
            },
        )?;
        store.messages.push(message);
    }
    store.message_event_count += 1;
    Ok(true)
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
        validate_previous_bundles(contact)?;
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
        return Err(CoreError::StorageFull);
    }
    let key = identity::active_identity()?.storage_key()?;
    let encrypted = vault::seal_with_key(&key, &encoded)?;
    persist_bytes(path, &encrypted)
}

fn validate_groups(groups: &[StoredGroup]) -> CoreResult<()> {
    let mut ids = HashSet::with_capacity(groups.len());
    for group in groups {
        groups::validate(group)?;
        validate_conversation_id(&group.id)?;
        validate_display_name(&group.name)?;
        if group.description.len() > MAX_MESSAGE_BODY_BYTES
            || group.description.chars().any(char::is_control)
            || !matches!(group.mode.as_str(), "group" | "channel")
            || group.admin_id.is_empty()
            || group.members.len() > MAX_CONTACTS
            || !ids.insert(group.id.as_str())
        {
            return Err(CoreError::VerificationFailed);
        }
        let mut member_ids = HashSet::new();
        for member in &group.members {
            validate_conversation_id(&member.id)?;
            validate_display_name(&member.display_name)?;
            member.identity.validate()?;
            if member.invitation_code.as_ref().is_some_and(|code| {
                code.len() > 128 || !(code.starts_with("sylphy:VLD") || code.starts_with("VLD"))
            }) {
                return Err(CoreError::VerificationFailed);
            }
            if member.id != contact_id(&member.identity.bundle.identity_ed25519)
                || member.fingerprint != fingerprint(&member.identity.bundle.identity_ed25519)
                || !member_ids.insert(member.id.as_str())
            {
                return Err(CoreError::VerificationFailed);
            }
        }
    }
    Ok(())
}

fn load_groups(path: &Path) -> CoreResult<Vec<StoredGroup>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > MAX_CONTACT_STORE_BYTES + 64 {
        return Err(CoreError::LimitExceeded);
    }
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let key = identity::active_identity()?.storage_key()?;
    let plaintext = vault::open_with_key(&key, &encrypted)?;
    let groups: Vec<StoredGroup> =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    validate_groups(&groups)?;
    Ok(groups)
}

fn persist_groups(path: &Path, groups: &[StoredGroup]) -> CoreResult<()> {
    validate_groups(groups)?;
    let encoded = serde_json::to_vec(groups).map_err(|_| CoreError::Internal)?;
    if encoded.len() as u64 > MAX_CONTACT_STORE_BYTES {
        return Err(CoreError::StorageFull);
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
    crate::append_log::recover(path)?;
    if fs::metadata(path).map_err(|_| CoreError::Internal)?.len() > MAX_MESSAGE_STORE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
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
            .and_then(|file| file.set_len(cursor as u64).and_then(|_| file.sync_data()))
            .map_err(|_| CoreError::Internal)?;
    }
    Ok((messages, event_count))
}

fn apply_message_event(messages: &mut Vec<StoredMessage>, event: MessageEvent) -> CoreResult<()> {
    match event {
        MessageEvent::Upsert { message } => {
            validate_stored_message(&message)?;
            if let Some(index) = messages.iter().position(|item| item.id == message.id) {
                messages[index] = message;
            } else {
                if messages.len() >= MAX_MESSAGES {
                    return Err(CoreError::LimitExceeded);
                }
                messages.push(message);
            }
        }
        MessageEvent::DeleteMessage { message_id } => {
            messages.retain(|message| message.id != message_id);
        }
        MessageEvent::MarkChannelRead {
            conversation_id,
            channel_id,
        } => {
            validate_conversation_id(&conversation_id)?;
            if let Some(id) = &channel_id {
                validate_conversation_id(id)?;
            }
            for message in messages {
                if message.conversation_id == conversation_id
                    && !message.is_outgoing
                    && groups::rich_metadata(&message.body)?.2 == channel_id
                {
                    message.is_read = true;
                }
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
    append_message_event_with_limit(path, event, MAX_MESSAGE_STORE_BYTES)
}

fn append_message_event_with_limit(
    path: &Path,
    event: &MessageEvent,
    limit: u64,
) -> CoreResult<()> {
    if !path.exists() {
        crate::append_log::replace(path, MESSAGE_LOG_MAGIC)?;
    }
    crate::append_log::recover(path)?;
    let encoded = serde_json::to_vec(event).map_err(|_| CoreError::Internal)?;
    let encrypted = vault::seal_with_key(&identity::active_identity()?.storage_key()?, &encoded)?;
    let length = u32::try_from(encrypted.len()).map_err(|_| CoreError::LimitExceeded)?;
    let current = fs::metadata(path).map_err(|_| CoreError::Internal)?.len();
    if current + 4 + u64::from(length) > limit {
        // A local capacity error is retryable, not an invalid network packet.
        // Compact together with the event so deletion still works at capacity.
        let (mut messages, _) = load_message_log(path)?;
        apply_message_event(&mut messages, event.clone()).map_err(|error| match error {
            CoreError::LimitExceeded => CoreError::StorageFull,
            other => other,
        })?;
        return write_message_snapshot_with_limit(path, &messages, limit).map_err(
            |error| match error {
                CoreError::LimitExceeded => CoreError::StorageFull,
                other => other,
            },
        );
    }
    let mut frame = Vec::with_capacity(4 + encrypted.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(&encrypted);
    crate::append_log::append(path, &frame)
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
    write_message_snapshot_with_limit(path, messages, MAX_MESSAGE_STORE_BYTES)
}

fn write_message_snapshot_with_limit(
    path: &Path,
    messages: &[StoredMessage],
    limit: u64,
) -> CoreResult<()> {
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
        if output.len() as u64 > limit {
            return Err(CoreError::LimitExceeded);
        }
    }
    crate::append_log::replace(path, &output)
}

fn persist_bytes(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    atomic_file::replace(path, bytes)
}

fn message_preview(message: &StoredMessage, store: &ContactStore) -> String {
    let data = message_json(message, store);
    let text = data["body"].as_str().unwrap_or("Messaggio");
    if data["reply_to"].is_string() {
        format!(
            "{} ha risposto: {}",
            data["author_name"].as_str().unwrap_or("Utente"),
            text
        )
    } else {
        text.to_owned()
    }
}

fn message_json(message: &StoredMessage, store: &ContactStore) -> Value {
    let (text, reply_to, channel_id) = groups::rich_metadata(&message.body).unwrap_or((
        "Messaggio non disponibile".to_owned(),
        None,
        None,
    ));
    let author_name = if message.is_outgoing {
        "Tu".to_owned()
    } else {
        message
            .author_name
            .clone()
            .or_else(|| {
                store
                    .groups
                    .iter()
                    .find(|group| group.id == message.conversation_id)
                    .and_then(|group| {
                        group
                            .members
                            .iter()
                            .find(|member| member.id == message.author_id)
                    })
                    .map(|member| member.display_name.clone())
            })
            .or_else(|| {
                store
                    .contacts
                    .iter()
                    .find(|contact| contact.id == message.author_id)
                    .map(|contact| contact.display_name.clone())
            })
            .unwrap_or_else(|| {
                format!(
                    "Membro {}",
                    message.author_id.chars().take(12).collect::<String>()
                )
            })
    };
    json!({
        "id": message.id,
        "author_id": message.author_id,
        "author_name": author_name,
        "body": text,
        "reply_to": reply_to,
        "channel_id": channel_id,
        "sent_at_ms": message.sent_at_ms,
        "order_at_ms": message_order_ms(message),
        "is_outgoing": message.is_outgoing,
        "delivery_state": message.delivery_state,
        "attachment_name": message.attachment_name,
        "attachment_base64": message.attachment_base64,
        "attachment_size": message.attachment_pointer.as_ref().map(|pointer| pointer.size),
        "attachment_state": if message.attachment_base64.is_some() { "ready" }
            else if message.attachment_pointer.is_some() { attachments::status(store.generation, &message.id) }
            else { "unavailable" },
    })
}

fn default_delivery_state() -> String {
    "sent".to_owned()
}

fn encode_group_invitation(
    invitation: &GroupInvitation,
    publish: impl FnOnce(&[u8]) -> CoreResult<(String, u16)>,
) -> CoreResult<(String, GroupInvitationPointer)> {
    let bytes = serde_json::to_vec(invitation).map_err(|_| CoreError::Internal)?;
    if bytes.len() > MAX_GROUP_INVITATION_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let mut key = zeroize::Zeroizing::new([0_u8; 32]);
    OsRng.fill_bytes(key.as_mut());
    let encrypted = vault::seal_with_key(&key, &bytes)?;
    let (record_key, chunk_count) = publish(&encrypted)?;
    let pointer = GroupInvitationPointer {
        version: 2,
        size: bytes.len(),
        record_key,
        chunk_count,
        key_base64: STANDARD_NO_PAD.encode(key.as_ref()),
    };
    let encoded =
        STANDARD_NO_PAD.encode(serde_json::to_vec(&pointer).map_err(|_| CoreError::Internal)?);
    Ok((format!("{GROUP_INVITE_BLOB_PREFIX}{encoded}"), pointer))
}

fn decode_group_invitation_with(
    plaintext: &str,
    fetch: impl FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<Option<GroupInvitation>> {
    if let Some(encoded) = plaintext.strip_prefix(GROUP_INVITE_BLOB_PREFIX) {
        if encoded.len() > MAX_MESSAGE_BODY_BYTES {
            return Err(CoreError::LimitExceeded);
        }
        let bytes = STANDARD_NO_PAD
            .decode(encoded)
            .map_err(|_| CoreError::InvalidInput)?;
        let pointer: GroupInvitationPointer =
            serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidInput)?;
        if pointer.version != 2 {
            return Err(CoreError::UnsupportedVersion);
        }
        if pointer.size == 0
            || pointer.size > MAX_GROUP_INVITATION_BYTES
            || pointer.record_key.is_empty()
            || pointer.record_key.len() > 1024
            || pointer.chunk_count == 0
            || pointer.chunk_count > 32
        {
            return Err(CoreError::InvalidInput);
        }
        let key = zeroize::Zeroizing::new(
            STANDARD_NO_PAD
                .decode(&pointer.key_base64)
                .map_err(|_| CoreError::InvalidInput)?,
        );
        let key: &[u8; 32] = key
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?;
        let encrypted = fetch(&pointer.record_key, pointer.chunk_count)?;
        if encrypted.len() > pointer.size + 64 {
            return Err(CoreError::LimitExceeded);
        }
        let bytes = vault::open_with_key(key, &encrypted)?;
        if bytes.len() != pointer.size {
            return Err(CoreError::VerificationFailed);
        }
        return serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| CoreError::VerificationFailed);
    }
    let Some(encoded) = plaintext.strip_prefix(GROUP_INVITE_PREFIX) else {
        return Ok(None);
    };
    let bytes = STANDARD_NO_PAD
        .decode(encoded)
        .map_err(|_| CoreError::InvalidInput)?;
    if bytes.len() > MAX_MESSAGE_BODY_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let invitation: GroupInvitation =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::VerificationFailed)?;
    Ok(Some(invitation))
}

fn decode_group_message(plaintext: &str) -> CoreResult<Option<(String, String)>> {
    let Some(value) = plaintext.strip_prefix(GROUP_MESSAGE_PREFIX) else {
        return Ok(None);
    };
    let (group_id, encoded) = value.split_once(':').ok_or(CoreError::InvalidInput)?;
    validate_conversation_id(group_id)?;
    let bytes = STANDARD_NO_PAD
        .decode(encoded)
        .map_err(|_| CoreError::InvalidInput)?;
    let body = String::from_utf8(bytes).map_err(|_| CoreError::InvalidInput)?;
    if body.trim().is_empty() || body.len() > MAX_MESSAGE_BODY_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    Ok(Some((group_id.to_owned(), body)))
}

fn parse_attachment_pointer(plaintext: &str) -> CoreResult<Option<AttachmentPointer>> {
    let Some(encoded) = plaintext.strip_prefix(ATTACHMENT_PREFIX) else {
        return Ok(None);
    };
    if encoded.len() > MAX_MESSAGE_BODY_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let pointer_bytes = STANDARD_NO_PAD
        .decode(encoded)
        .map_err(|_| CoreError::InvalidInput)?;
    let pointer: AttachmentPointer =
        serde_json::from_slice(&pointer_bytes).map_err(|_| CoreError::InvalidInput)?;
    validate_attachment_pointer(&pointer)?;
    Ok(Some(pointer))
}

fn attachment_body(pointer: &AttachmentPointer) -> CoreResult<String> {
    groups::encode_channel_text(
        &format!("📎 {}", pointer.file_name),
        None,
        pointer.channel_id.as_deref(),
    )
}

fn validate_attachment_pointer(pointer: &AttachmentPointer) -> CoreResult<()> {
    if pointer.version != 1 || pointer.size == 0 || pointer.size > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::InvalidInput);
    }
    validate_attachment_name(&pointer.file_name)?;
    attachment_body(pointer)?;
    if pointer.chunk_count as usize
        != (pointer.size + 16).div_ceil(crate::blob_transport::CHUNK_BYTES)
    {
        return Err(CoreError::InvalidInput);
    }
    crate::blob_transport::records(&pointer.record_key, pointer.chunk_count)?;
    let key = zeroize::Zeroizing::new(
        STANDARD_NO_PAD
            .decode(&pointer.key_base64)
            .map_err(|_| CoreError::InvalidInput)?,
    );
    let nonce = STANDARD_NO_PAD
        .decode(&pointer.nonce_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    if key.len() != 32 || nonce.len() != 24 {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}

fn decrypt_attachment(
    pointer: &AttachmentPointer,
    fetch: impl FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<String> {
    validate_attachment_pointer(pointer)?;
    let key = zeroize::Zeroizing::new(
        STANDARD_NO_PAD
            .decode(&pointer.key_base64)
            .map_err(|_| CoreError::InvalidInput)?,
    );
    let nonce = STANDARD_NO_PAD
        .decode(&pointer.nonce_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    let encrypted = fetch(&pointer.record_key, pointer.chunk_count)?;
    if encrypted.len() != pointer.size + 16 {
        return Err(CoreError::VerificationFailed);
    }
    let cipher = XChaCha20Poly1305::new_from_slice(&key).map_err(|_| CoreError::InvalidInput)?;
    let bytes = zeroize::Zeroizing::new(
        cipher
            .decrypt(XNonce::from_slice(&nonce), encrypted.as_slice())
            .map_err(|_| CoreError::AuthenticationFailed)?,
    );
    if bytes.len() != pointer.size {
        return Err(CoreError::VerificationFailed);
    }
    Ok(STANDARD.encode(bytes.as_slice()))
}

#[cfg(test)]
fn decode_incoming_content_with(
    plaintext: &str,
    fetch: impl FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<(String, Option<String>, Option<String>)> {
    let pointer = parse_attachment_pointer(plaintext)?.ok_or(CoreError::InvalidInput)?;
    let bytes = decrypt_attachment(&pointer, fetch)?;
    Ok((
        attachment_body(&pointer)?,
        Some(pointer.file_name),
        Some(bytes),
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
    if length == 0
        || length > MAX_CONVERSATION_ID_BYTES
        || conversation_id.chars().any(char::is_control)
    {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_attachments_authenticate_before_becoming_messages() {
        let bytes = vec![42; MAX_ATTACHMENT_BYTES];
        let key = [7; 32];
        let nonce = [8; 24];
        let encrypted = XChaCha20Poly1305::new_from_slice(&key)
            .unwrap()
            .encrypt(XNonce::from_slice(&nonce), bytes.as_slice())
            .unwrap();
        let mut records = Vec::new();
        let (reference, count) = crate::blob_transport::publish(
            &encrypted,
            MAX_ATTACHMENT_BYTES + 16,
            |part| {
                records.push(part.to_vec());
                Ok(format!("record-{}", records.len() - 1))
            },
            |_| panic!("unexpected cleanup"),
        )
        .unwrap();
        let mut pointer = AttachmentPointer {
            version: 1,
            file_name: "large.bin".to_owned(),
            size: bytes.len(),
            record_key: reference,
            chunk_count: count,
            key_base64: STANDARD_NO_PAD.encode(key),
            nonce_base64: STANDARD_NO_PAD.encode(nonce),
            channel_id: None,
        };
        let control = |p: &AttachmentPointer| {
            format!(
                "{ATTACHMENT_PREFIX}{}",
                STANDARD_NO_PAD.encode(serde_json::to_vec(p).unwrap())
            )
        };
        let (_, name, encoded) = decode_incoming_content_with(&control(&pointer), |key, count| {
            crate::blob_transport::fetch(key, count, MAX_ATTACHMENT_BYTES + 16, |key, _| {
                let index: usize = key.strip_prefix("record-").unwrap().parse().unwrap();
                Ok(records[index].clone())
            })
        })
        .unwrap();
        assert_eq!(name.as_deref(), Some("large.bin"));
        assert_eq!(STANDARD.decode(encoded.unwrap()).unwrap(), bytes);
        let mut corrupt = encrypted.clone();
        corrupt[0] ^= 1;
        assert!(matches!(
            decode_incoming_content_with(&control(&pointer), |_, _| Ok(corrupt)),
            Err(CoreError::AuthenticationFailed)
        ));
        pointer.key_base64 = "bad".to_owned();
        assert!(
            decode_incoming_content_with(&control(&pointer), |_, _| panic!(
                "invalid key must not fetch"
            ))
            .is_err()
        );
        pointer.size = MAX_ATTACHMENT_BYTES + 1;
        assert!(
            decode_incoming_content_with(&control(&pointer), |_, _| panic!(
                "invalid size must not fetch"
            ))
            .is_err()
        );
        assert!(matches!(
            send_attachment(
                "contact-test",
                "large.bin",
                &STANDARD.encode(vec![0; MAX_ATTACHMENT_BYTES + 1])
            ),
            Err(CoreError::LimitExceeded)
        ));
    }

    #[test]
    fn synced_messages_complete_attachments_and_never_regress_receipts() {
        let mut old = history_message(1);
        old.delivery_state = "queued".to_owned();
        old.is_read = false;
        let mut new = old.clone();
        new.delivery_state = "read".to_owned();
        new.is_read = true;
        new.attachment_name = Some("file.bin".to_owned());
        new.attachment_base64 = Some(STANDARD.encode([1, 2, 3]));
        let merged = merge_synced_message(&old, &new).unwrap();
        assert_eq!(merged.delivery_state, "read");
        assert_eq!(merged.attachment_base64, new.attachment_base64);
        assert!(!merged.is_read);
        assert_eq!(
            merge_synced_message(&merged, &old).unwrap().delivery_state,
            "read"
        );
        new.body = "conflicting content".to_owned();
        assert!(merge_synced_message(&old, &new).is_err());
    }

    #[test]
    fn full_log_compacts_and_retains_unsaved_packets_until_space_is_freed() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory =
            std::env::temp_dir().join(format!("sylphy-capacity-{}", std::process::id()));
        identity::ensure_identity(
            &directory.to_string_lossy(),
            "capacity-test-vault",
            None,
            None,
        )
        .unwrap();
        let path = directory.join("capacity.log");
        let first = history_message(1);
        append_message_event(
            &path,
            &MessageEvent::Upsert {
                message: first.clone(),
            },
        )
        .unwrap();
        let limit = fs::metadata(&path).unwrap().len() + 10;
        // A receipt update would exceed the log, but its compacted snapshot fits.
        let mut update = first.clone();
        update.delivery_state = "read".to_owned();
        append_message_event_with_limit(&path, &MessageEvent::Upsert { message: update }, limit)
            .unwrap();
        let error = append_message_event_with_limit(
            &path,
            &MessageEvent::Upsert {
                message: history_message(2),
            },
            limit,
        )
        .unwrap_err();
        assert!(matches!(error, CoreError::StorageFull));
        assert!(!should_discard_inbound(&error));
        let (messages, _) = load_message_log(&path).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].delivery_state, "read");
        // Deletion also succeeds with no room to append another event.
        append_message_event_with_limit(
            &path,
            &MessageEvent::DeleteMessage {
                message_id: first.id,
            },
            limit,
        )
        .unwrap();
        assert!(load_message_log(&path).unwrap().0.is_empty());
        append_message_event_with_limit(
            &path,
            &MessageEvent::Upsert {
                message: history_message(2),
            },
            limit,
        )
        .unwrap();
        assert_eq!(load_message_log(&path).unwrap().0.len(), 1);
        // Startup truncates an interrupted tail before accepting another append.
        let committed_len = fs::metadata(&path).unwrap().len();
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&[0, 0]).unwrap();
        file.sync_data().unwrap();
        drop(file);
        assert_eq!(load_message_log(&path).unwrap().0.len(), 1);
        assert_eq!(fs::metadata(&path).unwrap().len(), committed_len);
        append_message_event(
            &path,
            &MessageEvent::Upsert {
                message: history_message(3),
            },
        )
        .unwrap();
        assert_eq!(load_message_log(&path).unwrap().0.len(), 2);
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(feature = "signal-ratchet")]
    #[test]
    fn backup_restores_sealed_outbox_and_legacy_backup_marks_missing_retries() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory =
            std::env::temp_dir().join(format!("sylphy-outbox-backup-{}", std::process::id()));
        let peer_root = directory.join("peer");
        identity::ensure_identity(
            &peer_root.to_string_lossy(),
            "backup-test-vault",
            None,
            None,
        )
        .unwrap();
        let peer = identity::active_identity().unwrap();
        let published = PublishedIdentity::new(
            &peer.signing_key().unwrap(),
            peer.public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
                .unwrap(),
            vec![1; 512],
            crate::peer_identity::PublicProfile {
                display_name: Some("Peer".to_owned()),
                avatar_base64: None,
            },
            None,
        )
        .unwrap();
        let member = group_member(published.clone()).unwrap();
        let contact = StoredContact {
            id: member.id.clone(),
            display_name: member.display_name.clone(),
            fingerprint: member.fingerprint.clone(),
            added_at_ms: current_time_ms().unwrap(),
            bundle: published.bundle.clone(),
            published_identity: Some(published.clone()),
            invitation_code: None,
            previous_bundles: Vec::new(),
            verified: false,
        };
        let local_root = directory.join("local");
        identity::ensure_identity(
            &local_root.to_string_lossy(),
            "backup-test-vault",
            None,
            None,
        )
        .unwrap();
        configure_storage(&local_root.to_string_lossy()).unwrap();
        let (payload, id) = secure_packet::seal_for_test(
            &published.delivery_devices().unwrap()[0],
            "Synthetic message",
        )
        .unwrap();
        let mut message = history_message(1);
        message.id = id.clone();
        message.conversation_id = contact.id.clone();
        message.delivery_state = "queued".to_owned();
        // Exercise the expanded attachment through backup, sync and log reload.
        message.attachment_name = Some("large.bin".to_owned());
        message.attachment_base64 = Some(STANDARD.encode(vec![42; MAX_ATTACHMENT_BYTES]));
        let sync_event = serde_json::to_vec(&DeviceSyncEvent::UpsertMessage {
            contact: contact.clone(),
            message: message.clone(),
        })
        .unwrap();
        assert!(vault::seal_with_key(&[9; 32], &sync_event).unwrap().len() <= 3 * 1024 * 1024);
        let mut delivery = pending_delivery(&id);
        delivery.payload = payload.clone();
        let backup = MessagingAccountBackup {
            version: 1,
            contacts: vec![contact.clone()],
            groups: Vec::new(),
            messages: vec![message.clone()],
            outbox: vec![delivery],
            attachment_leases: Vec::new(),
        };
        import_account_backup(serde_json::to_value(&backup).unwrap()).unwrap();
        configure_storage(&local_root.to_string_lossy()).unwrap();
        let restored = export_account_backup().unwrap();
        assert_eq!(
            restored["outbox"][0]["payload"],
            serde_json::to_value(payload).unwrap()
        );
        assert_eq!(restored["messages"][0]["delivery_state"], "queued");
        assert_eq!(
            restored["messages"][0]["attachment_base64"],
            message.attachment_base64.as_deref().unwrap()
        );
        // Upsert updates the existing ID and survives restarting the store.
        message.delivery_state = "sent".to_owned();
        apply_device_sync_plaintext(
            &serde_json::to_vec(&DeviceSyncEvent::UpsertMessage { contact, message }).unwrap(),
        )
        .unwrap();
        configure_storage(&local_root.to_string_lossy()).unwrap();
        assert_eq!(
            export_account_backup().unwrap()["messages"][0]["delivery_state"],
            "sent"
        );
        let mut legacy = serde_json::to_value(backup).unwrap();
        legacy.as_object_mut().unwrap().remove("outbox");
        import_account_backup(legacy).unwrap();
        assert_eq!(
            export_account_backup().unwrap()["messages"][0]["delivery_state"],
            "not_restored"
        );
        // Group endpoints receive authenticated route changes and persist them.
        let updated = PublishedIdentity::new(
            &peer.signing_key().unwrap(),
            published.bundle.clone(),
            vec![2; 512],
            published.profile.clone(),
            None,
        )
        .unwrap();
        {
            let mut store = contact_store().lock().unwrap();
            store.groups = vec![StoredGroup {
                id: "group-endpoints".to_owned(),
                name: "Group".to_owned(),
                description: String::new(),
                mode: "group".to_owned(),
                admin_id: "me".to_owned(),
                created_at_ms: current_time_ms().unwrap(),
                members: vec![member.clone()],
                management: groups::Management::default(),
            }];
            update_group_endpoints(&mut store, &member.id, &updated).unwrap();
        }
        configure_storage(&local_root.to_string_lossy()).unwrap();
        // An older address-book route with equal prekey expiry must not undo it.
        assert_eq!(
            current_group("group-endpoints").unwrap().unwrap().members[0]
                .identity
                .route_blob,
            vec![2; 512]
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn sender_names_survive_storage_and_old_messages_have_a_visible_fallback() {
        let store = ContactStore::default();
        let mut message = history_message(1);
        message.is_outgoing = false;
        message.author_id = "sender-alice".to_owned();
        message.author_name = Some("Alice Rossi".to_owned());
        let serialized = serde_json::to_value(&message).unwrap();
        let restored: StoredMessage = serde_json::from_value(serialized.clone()).unwrap();
        assert_eq!(
            message_json(&restored, &store)["author_name"],
            "Alice Rossi"
        );
        let mut legacy = serialized;
        legacy.as_object_mut().unwrap().remove("author_name");
        let restored: StoredMessage = serde_json::from_value(legacy).unwrap();
        assert_eq!(
            message_json(&restored, &store)["author_name"],
            "Membro sender-alice"
        );
        message.is_outgoing = true;
        assert_eq!(message_json(&message, &store)["author_name"], "Tu");
    }

    pub(super) fn history_message(index: usize) -> StoredMessage {
        StoredMessage {
            id: format!("message-{index:06}"),
            conversation_id: if index % 5 == 0 { "other" } else { "chat" }.to_owned(),
            author_id: "me".to_owned(),
            body: "Synthetic message".to_owned(),
            sent_at_ms: (index / 3) as u64,
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: "sent".to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
            attachment_pointer: None,
        }
    }

    #[test]
    fn message_pages_preserve_order_and_cursor_without_copying_history() {
        let mut history = (0..503).map(history_message).collect::<Vec<_>>();
        history.reverse();
        history.rotate_left(91);
        let mut expected = history
            .iter()
            .filter(|message| message.conversation_id == "chat")
            .collect::<Vec<_>>();
        expected.sort_by_key(|message| (message.sent_at_ms, message.id.as_str()));
        for limit in [1, 2, 7, 120, 500] {
            let mut before_ms = None;
            let mut before_id = None;
            let mut collected = Vec::new();
            loop {
                let (page, has_more) =
                    select_message_page(&history, "chat", before_ms, before_id, limit);
                assert!(page.len() <= limit);
                for message in &page {
                    assert!(
                        history
                            .iter()
                            .any(|original| std::ptr::eq(*message, original))
                    );
                }
                collected.splice(0..0, page.iter().map(|message| message.id.as_str()));
                if !has_more {
                    break;
                }
                before_ms = page.first().map(|message| message.sent_at_ms);
                before_id = page.first().map(|message| message.id.as_str());
            }
            assert_eq!(
                collected,
                expected
                    .iter()
                    .map(|message| message.id.as_str())
                    .collect::<Vec<_>>()
            );
        }
        let (page, has_more) = select_message_page(&history, "absent", None, None, 120);
        assert!(page.is_empty());
        assert!(!has_more);
        let (page, _) = select_message_page(&history, "chat", Some(12), None, 120);
        assert!(page.iter().all(|message| message.sent_at_ms < 12));
    }

    #[test]
    fn incoming_clock_skew_does_not_partition_history_or_break_pagination() {
        let history = (1..=6)
            .map(|i| {
                let mut message = history_message(i);
                message.conversation_id = "chat".to_owned();
                message.is_outgoing = i % 2 != 0;
                message.sent_at_ms = if message.is_outgoing {
                    i as u64 * 1000
                } else {
                    100
                };
                message.received_at_ms = if message.is_outgoing {
                    0
                } else {
                    i as u64 * 1000
                };
                message
            })
            .collect::<Vec<_>>();
        let (latest, more) = select_message_page(&history, "chat", None, None, 3);
        assert!(more);
        assert_eq!(
            latest
                .iter()
                .map(|m| message_order_ms(m))
                .collect::<Vec<_>>(),
            vec![4000, 5000, 6000]
        );
        let (older, more) = select_message_page(
            &history,
            "chat",
            Some(message_order_ms(latest[0])),
            Some(&latest[0].id),
            3,
        );
        assert!(!more);
        assert_eq!(
            older
                .iter()
                .map(|m| message_order_ms(m))
                .collect::<Vec<_>>(),
            vec![1000, 2000, 3000]
        );
        assert_eq!(latest[0].sent_at_ms, 100); // Preserve the sender's timestamp.
    }

    #[test]
    #[ignore = "manual synthetic performance comparison; no timing threshold"]
    fn benchmark_message_page_selection() {
        let mut history = (0..25_000)
            .map(|index| {
                let mut message = history_message(index);
                message.body = "x".repeat(256);
                if index % 8 == 0 {
                    message.attachment_name = Some("sample.bin".to_owned());
                    message.attachment_base64 = Some("A".repeat(8192));
                }
                message
            })
            .collect::<Vec<_>>();
        history.rotate_left(9123);
        let legacy_start = std::time::Instant::now();
        for _ in 0..10 {
            let mut messages = history
                .iter()
                .filter(|message| message.conversation_id == "chat")
                .cloned()
                .collect::<Vec<_>>();
            messages.sort_by(|left, right| {
                right
                    .sent_at_ms
                    .cmp(&left.sent_at_ms)
                    .then_with(|| right.id.cmp(&left.id))
            });
            messages.truncate(120);
            messages.reverse();
            std::hint::black_box(messages);
        }
        let legacy = legacy_start.elapsed();
        let optimized_start = std::time::Instant::now();
        for _ in 0..10 {
            std::hint::black_box(select_message_page(&history, "chat", None, None, 120));
        }
        eprintln!(
            "25,000 synthetic messages, 10 page reads: legacy={legacy:?}, optimized={:?}",
            optimized_start.elapsed()
        );
    }

    #[test]
    fn direct_delivery_completes_without_waiting_for_offline_storage() {
        assert!(deliver_with_offline_fallback(
            || Ok(()),
            || panic!("A successful direct send must not wait for the mailbox"),
        ));
        assert!(deliver_with_offline_fallback(
            || Err(CoreError::NetworkAttachFailed),
            || Ok(()),
        ));
        assert!(!deliver_with_offline_fallback(
            || Err(CoreError::NetworkAttachFailed),
            || Err(CoreError::LimitExceeded),
        ));
        assert!(!deliver_with_offline_fallback(
            || Err(CoreError::NetworkAttachFailed),
            || Err(CoreError::FeatureUnavailable),
        ));
    }

    #[cfg(feature = "signal-ratchet")]
    #[test]
    fn group_invitation_with_large_signed_profiles_uses_small_authenticated_pointer() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-group-{}-{}",
            std::process::id(),
            current_time_ms().unwrap(),
        ));
        let make_member = |name: &str| {
            let root = directory.join(name).to_string_lossy().into_owned();
            identity::ensure_identity(&root, "group-test-vault", None, None).unwrap();
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
                        avatar_base64: Some(STANDARD.encode(vec![42; 9000])),
                    },
                    None,
                )
                .unwrap(),
            )
            .unwrap()
        };
        let admin = make_member("Admin");
        let member = make_member("Member");
        let invitation = GroupInvitation {
            version: 1,
            group: StoredGroup {
                id: "group-regression".to_owned(),
                name: "Private group".to_owned(),
                description: String::new(),
                mode: "group".to_owned(),
                admin_id: admin.id.clone(),
                created_at_ms: current_time_ms().unwrap(),
                members: vec![member],
                management: groups::Management::default(),
            },
            admin,
        };
        validate_groups(std::slice::from_ref(&invitation.group)).unwrap();
        let original = serde_json::to_vec(&invitation).unwrap();
        assert!(original.len() > MAX_MESSAGE_BODY_BYTES);
        let mut blob = Vec::new();
        let (control, pointer) = encode_group_invitation(&invitation, |bytes| {
            blob = bytes.to_vec();
            Ok(("test-record".to_owned(), 3))
        })
        .unwrap();
        assert!(control.len() < 1024);
        assert!(!blob.windows(13).any(|part| part == b"Private group"));
        let decoded = decode_group_invitation_with(&control, |record, chunks| {
            assert_eq!(record, "test-record");
            assert_eq!(chunks, 3);
            Ok(blob.clone())
        })
        .unwrap()
        .unwrap();
        assert_eq!(serde_json::to_vec(&decoded).unwrap(), original);
        validate_groups(std::slice::from_ref(&decoded.group)).unwrap();
        // Missing blobs remain retryable; corrupted ciphertext is never accepted.
        assert!(matches!(
            decode_group_invitation_with(&control, |_, _| { Err(CoreError::NetworkAttachFailed) }),
            Err(CoreError::NetworkAttachFailed)
        ));
        let mut corrupted = blob.clone();
        *corrupted.last_mut().unwrap() ^= 1;
        assert!(decode_group_invitation_with(&control, |_, _| Ok(corrupted)).is_err());
        let oversized = GroupInvitationPointer {
            size: MAX_ATTACHMENT_BYTES + 1,
            ..pointer
        };
        let invalid_control = format!(
            "{GROUP_INVITE_BLOB_PREFIX}{}",
            STANDARD_NO_PAD.encode(serde_json::to_vec(&oversized).unwrap())
        );
        assert!(
            decode_group_invitation_with(&invalid_control, |_, _| {
                panic!("Reject invalid pointers before network I/O")
            })
            .is_err()
        );
        // Exercise the real hybrid/Signal packet and receive path, including
        // a missing blob on the first attempt and a retry with the same packet.
        let admin_root = directory.join("Admin").to_string_lossy().into_owned();
        let member_root = directory.join("Member").to_string_lossy().into_owned();
        identity::activate_from_storage(&admin_root, "group-test-vault").unwrap();
        let device = invitation.group.members[0]
            .identity
            .delivery_devices()
            .unwrap()
            .remove(0);
        let (packet, _) = secure_packet::seal_for_test(&device, &control).unwrap();
        assert!(packet.len() <= 32 * 1024);
        identity::activate_from_storage(&member_root, "group-test-vault").unwrap();
        configure_storage(&member_root).unwrap();
        assert!(matches!(
            persist_inbound_payload_with(&packet, |_, _| { Err(CoreError::NetworkAttachFailed) }),
            Err(CoreError::NetworkAttachFailed)
        ));
        assert!(persist_inbound_payload_with(&packet, |_, _| Ok(blob)).unwrap());
        // The recipient keeps the admin as its sole remote member, including
        // after a restart. It must not fan out messages to itself.
        configure_storage(&member_root).unwrap();
        {
            let store = contact_store().lock().unwrap();
            assert_eq!(store.groups.len(), 1);
            assert_eq!(store.groups[0].members.len(), 1);
            assert_eq!(store.groups[0].members[0].id, invitation.admin.id);
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn partial_delivery_retries_survive_restart_and_cancellation() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-queue-{}-{}",
            std::process::id(),
            current_time_ms().unwrap()
        ));
        let root = directory.to_string_lossy().into_owned();
        identity::ensure_identity(&root, "queue-test-vault", None, None).unwrap();
        configure_storage(&root).unwrap();
        let message = StoredMessage {
            id: "message-one".to_owned(),
            conversation_id: "contact-one".to_owned(),
            author_id: "me".to_owned(),
            body: "Durable text".to_owned(),
            sent_at_ms: current_time_ms().unwrap(),
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: "queued".to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
            attachment_pointer: None,
        };
        let path = contact_store()
            .lock()
            .unwrap()
            .message_path
            .clone()
            .unwrap();
        queue_outgoing(
            &path,
            message,
            vec![
                secure_packet::SealedDelivery {
                    payload: vec![7; 32],
                    route_blob: vec![1],
                    offline_keys: None,
                },
                secure_packet::SealedDelivery {
                    payload: vec![8; 32],
                    route_blob: vec![2],
                    offline_keys: None,
                },
            ],
        )
        .unwrap();
        let (generation, pending) = {
            let store = contact_store().lock().unwrap();
            (store.generation, store.outbox.clone())
        };
        let (sender, receiver) = std::sync::mpsc::channel();
        sender.send(vec![(pending[0].clone(), true)]).unwrap();
        *OUTBOX_TRANSPORT.lock().unwrap() = Some((generation, receiver));
        assert!(!flush_outbox(Some("message-one")));
        assert_eq!(contact_store().lock().unwrap().outbox.len(), 1);
        // A late result must use the same receiver, never start a duplicate batch.
        sender.send(vec![(pending[1].clone(), false)]).unwrap();
        assert!(!flush_outbox(Some("message-one")));
        {
            let store = contact_store().lock().unwrap();
            assert_eq!(store.messages[0].delivery_state, "queued");
            assert_eq!(store.outbox.len(), 1);
            assert_eq!(store.outbox[0].attempts, 1);
            assert!(store.outbox[0].next_attempt_ms > current_time_ms().unwrap());
            let bytes = fs::read(store.outbox_path.as_ref().unwrap()).unwrap();
            assert!(!bytes.windows(11).any(|value| value == b"message-one"));
        }
        configure_storage(&root).unwrap();
        let mut store = contact_store().lock().unwrap();
        ensure_messages_loaded(&mut store).unwrap();
        assert_eq!(store.outbox.len(), 1);
        assert_eq!(store.outbox[0].payload, vec![8; 32]);
        assert_eq!(store.messages[0].delivery_state, "queued");
        let generation = store.generation;
        let pending = store.outbox[0].clone();
        drop(store);
        let (sender, receiver) = std::sync::mpsc::channel();
        sender.send(vec![(pending, true)]).unwrap();
        *OUTBOX_TRANSPORT.lock().unwrap() = Some((generation, receiver));
        assert!(flush_outbox(Some("message-one")));
        configure_storage(&root).unwrap();
        let mut store = contact_store().lock().unwrap();
        ensure_messages_loaded(&mut store).unwrap();
        assert!(store.outbox.is_empty());
        assert_eq!(store.messages[0].delivery_state, "sent");
        // Cancelling a queued conversation is durable too.
        store.outbox = vec![pending_delivery("message-one")];
        cancel_pending_conversation(&mut store, "contact-one").unwrap();
        assert!(
            load_outbox(store.outbox_path.as_ref().unwrap())
                .unwrap()
                .is_empty()
        );
        drop(store);
        fs::remove_dir_all(directory).unwrap();
    }

    fn pending_delivery(message_id: &str) -> PendingDelivery {
        PendingDelivery {
            is_control: false,
            id: "delivery-one".to_owned(),
            message_id: message_id.to_owned(),
            route_blob: vec![1],
            payload: vec![2],
            created_at_ms: 1,
            offline_keys: None,
            attempts: 0,
            next_attempt_ms: 0,
        }
    }

    #[test]
    fn retry_backoff_is_bounded_and_legacy_outbox_migrates() {
        assert_eq!(retry_delay_ms(1), 5_000);
        assert_eq!(retry_delay_ms(2), 10_000);
        assert_eq!(retry_delay_ms(u32::MAX), 300_000);
        let entry: PendingDelivery = serde_json::from_value(json!({"id":"old", "message_id":"msg", "route_blob":[1], "payload":[2], "created_at_ms":1})).unwrap();
        assert!(entry.offline_keys.is_none());
        assert_eq!(entry.next_attempt_ms, 0);
        assert_eq!(entry.attempts, 0);
    }
}
