use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{
    bundle::PublicBundle,
    error::{CoreError, CoreResult},
};

const MAX_CONVERSATION_ID_BYTES: usize = 128;
const MAX_DISPLAY_NAME_CHARS: usize = 64;
const MAX_INVITATION_TEXT_BYTES: usize = 64 * 1024;
const MAX_CONTACT_STORE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_CONTACTS: usize = 1024;
const CONTACT_STORE_FILE: &str = "contacts-v1.json";

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredContact {
    id: String,
    display_name: String,
    fingerprint: String,
    added_at_ms: u64,
    bundle: PublicBundle,
}

#[derive(Default)]
struct ContactStore {
    path: Option<PathBuf>,
    contacts: Vec<StoredContact>,
}

static CONTACT_STORE: OnceLock<Mutex<ContactStore>> = OnceLock::new();

fn contact_store() -> &'static Mutex<ContactStore> {
    CONTACT_STORE.get_or_init(|| Mutex::new(ContactStore::default()))
}

/// Configures the native contact directory before Veilid startup.
///
/// Invitation bundles are public cryptographic material, but the contact graph
/// remains device-local and is never published to Veilid by this adapter.
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
    store.contacts = contacts;
    Ok(())
}

/// Returns only records accepted by the native invitation parser.
pub fn list_conversations() -> CoreResult<Value> {
    let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let conversations = store
        .contacts
        .iter()
        .map(|contact| {
            json!({
                "id": contact.id,
                "name": contact.display_name,
                "initials": initials(&contact.display_name),
                "accent_value": accent_value(&contact.bundle.identity_ed25519),
                "last_message": "Contatto aggiunto · verifica necessaria",
                "last_activity_ms": contact.added_at_ms,
                "unread_count": 0,
                "is_online": false,
                "is_group": false,
                "safety": "pending",
                "fingerprint": contact.fingerprint,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "state": if store.path.is_some() { "contacts_pending_verification" } else { "storage_unconfigured" },
        "can_send": false,
        "conversations": conversations,
    }))
}

pub fn list_messages(conversation_id: &str) -> CoreResult<Value> {
    validate_conversation_id(conversation_id)?;
    Ok(json!({
        "conversation_id": conversation_id,
        "messages": [],
    }))
}

pub fn add_contact(display_name: &str, invitation_code: &str) -> CoreResult<Value> {
    let normalized_name = validate_display_name(display_name)?;
    let bundle = decode_invitation(invitation_code)?;
    let now_ms = current_time_ms()?;
    if bundle.expires_at_ms <= now_ms {
        return Err(CoreError::VerificationFailed);
    }

    let fingerprint_digest = Sha256::digest(&bundle.identity_ed25519);
    let id = format!("contact-{}", compact_hex(&fingerprint_digest[..16]));
    let fingerprint = grouped_hex(&fingerprint_digest);
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
    };
    let mut updated = store.contacts.clone();
    updated.push(contact);
    persist_contacts(
        store.path.as_deref().ok_or(CoreError::FeatureUnavailable)?,
        &updated,
    )?;
    store.contacts = updated;
    Ok(json!({"contact_id": id, "fingerprint": fingerprint, "safety": "pending"}))
}

fn decode_invitation(invitation_code: &str) -> CoreResult<PublicBundle> {
    let normalized = invitation_code.trim();
    if normalized.is_empty() || normalized.len() > MAX_INVITATION_TEXT_BYTES {
        return Err(CoreError::InvalidInput);
    }
    let bytes = STANDARD_NO_PAD
        .decode(normalized)
        .map_err(|_| CoreError::InvalidInput)?;
    let bundle: PublicBundle =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidInput)?;
    bundle.validate()?;
    Ok(bundle)
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
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|_| CoreError::Internal)?;
    file.write_all(&encoded).map_err(|_| CoreError::Internal)?;
    file.sync_all().map_err(|_| CoreError::Internal)
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
    use crate::bundle::generate_bundle_for_test;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn reset_store() {
        let mut store = contact_store().lock().expect("contact store");
        store.path = None;
        store.contacts.clear();
    }

    #[test]
    fn starts_without_demo_conversations() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        reset_store();
        let overview = list_conversations().expect("conversation overview");
        assert_eq!(overview["can_send"], false);
        assert_eq!(overview["conversations"].as_array().map(Vec::len), Some(0));
    }

    #[test]
    fn validates_conversation_ids_before_native_lookup() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        assert!(list_messages("").is_err());
        assert!(list_messages(&"x".repeat(MAX_CONVERSATION_ID_BYTES + 1)).is_err());
        assert!(list_messages("contact-1").is_ok());
    }

    #[test]
    fn accepts_only_signed_public_bundle_invitations() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        let bundle = generate_bundle_for_test(u64::MAX);
        let encoded =
            STANDARD_NO_PAD.encode(serde_json::to_vec(&bundle).expect("serialize bundle"));
        assert!(decode_invitation(&encoded).is_ok());
        assert!(decode_invitation("not-an-invitation").is_err());
    }

    #[test]
    fn persists_a_verified_contact_and_rejects_the_duplicate() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        reset_store();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-contact-test-{}-{unique}",
            std::process::id()
        ));
        let directory_text = directory.to_string_lossy().into_owned();
        configure_storage(&directory_text).expect("configure contact storage");
        let bundle = generate_bundle_for_test(u64::MAX);
        let invitation =
            STANDARD_NO_PAD.encode(serde_json::to_vec(&bundle).expect("serialize bundle"));

        let imported = add_contact("Ada Lovelace", &invitation).expect("import contact");
        assert!(imported["contact_id"].as_str().is_some());
        assert_eq!(
            list_conversations().expect("list contacts")["conversations"]
                .as_array()
                .map(Vec::len),
            Some(1)
        );
        assert!(add_contact("Ada Again", &invitation).is_err());

        reset_store();
        configure_storage(&directory_text).expect("reload contact storage");
        assert_eq!(
            list_conversations().expect("list restored contacts")["conversations"]
                .as_array()
                .map(Vec::len),
            Some(1)
        );
        reset_store();
        fs::remove_dir_all(&directory).expect("remove isolated test directory");
    }
}
