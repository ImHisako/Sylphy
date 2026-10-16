use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use ed25519_dalek::SigningKey;
use ml_kem::{
    MlKem768, Seed,
    kem::{Kem, KeyExport},
};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

use crate::{
    atomic_file,
    bundle::{ED25519_LENGTH, ML_KEM_768_PUBLIC_KEY_LENGTH, PublicBundle, SignalPreKeyBundle},
    error::{CoreError, CoreResult},
    ratchet_adapter, vault,
};

const IDENTITY_FILE_NAME: &str = "identity-v1.vault";
const IDENTITY_RECORD_VERSION: u8 = 1;
const X25519_SECRET_LENGTH: usize = 32;
const ML_KEM_SEED_LENGTH: usize = 64;
const INVITATION_LIFETIME_MS: u64 = 30 * 24 * 60 * 60 * 1000;
const MAX_STORAGE_PATH_BYTES: usize = 4096;
const MAX_VAULT_PASSWORD_BYTES: usize = 512;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct IdentityRecord {
    version: u8,
    signing_secret: Vec<u8>,
    x25519_secret: Vec<u8>,
    mlkem_seed: Vec<u8>,
    expires_at_ms: u64,
    #[serde(default)]
    message_storage_secret: Vec<u8>,
    #[serde(default)]
    dht_descriptor_json: Option<String>,
    #[serde(default)]
    mailbox_descriptor_json: Option<String>,
    #[serde(default)]
    retired_prekeys: Vec<RetiredPrekeys>,
    #[serde(default)]
    invitation: crate::invitation::InvitationState,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RetiredPrekeys {
    x25519_secret: Vec<u8>,
    mlkem_seed: Vec<u8>,
    retain_until_ms: u64,
}

impl Drop for RetiredPrekeys {
    fn drop(&mut self) {
        self.x25519_secret.zeroize();
        self.mlkem_seed.zeroize();
    }
}

impl Drop for IdentityRecord {
    fn drop(&mut self) {
        self.signing_secret.zeroize();
        self.x25519_secret.zeroize();
        self.mlkem_seed.zeroize();
        self.message_storage_secret.zeroize();
        self.dht_descriptor_json.zeroize();
        self.mailbox_descriptor_json.zeroize();
    }
}

impl IdentityRecord {
    fn generate(expires_at_ms: u64) -> Self {
        let signing_key = SigningKey::generate(&mut OsRng);
        let x25519_secret = StaticSecret::random_from_rng(OsRng);
        let mut mlkem_seed = vec![0_u8; ML_KEM_SEED_LENGTH];
        OsRng.fill_bytes(&mut mlkem_seed);
        let mut message_storage_secret = vec![0_u8; 32];
        OsRng.fill_bytes(&mut message_storage_secret);
        Self {
            version: IDENTITY_RECORD_VERSION,
            signing_secret: signing_key.to_bytes().to_vec(),
            x25519_secret: x25519_secret.to_bytes().to_vec(),
            mlkem_seed,
            expires_at_ms,
            message_storage_secret,
            dht_descriptor_json: None,
            mailbox_descriptor_json: None,
            retired_prekeys: Vec::new(),
            invitation: Default::default(),
        }
    }

    fn rotate_prekeys(&mut self, expires_at_ms: u64) {
        self.retired_prekeys.push(RetiredPrekeys {
            x25519_secret: self.x25519_secret.clone(),
            mlkem_seed: self.mlkem_seed.clone(),
            retain_until_ms: self
                .expires_at_ms
                .saturating_add(crate::offline_mailbox::RETENTION_MS),
        });
        let x25519_secret = StaticSecret::random_from_rng(OsRng);
        self.x25519_secret.zeroize();
        self.x25519_secret = x25519_secret.to_bytes().to_vec();
        self.mlkem_seed.zeroize();
        self.mlkem_seed.resize(ML_KEM_SEED_LENGTH, 0);
        OsRng.fill_bytes(&mut self.mlkem_seed);
        self.expires_at_ms = expires_at_ms;
    }

    fn validate(&self) -> CoreResult<()> {
        self.invitation.validate()?;
        if self.version != IDENTITY_RECORD_VERSION
            || self.signing_secret.len() != ED25519_LENGTH
            || self.x25519_secret.len() != X25519_SECRET_LENGTH
            || self.mlkem_seed.len() != ML_KEM_SEED_LENGTH
            || self.message_storage_secret.len() != 32
            || self.retired_prekeys.len() > 2
            || self
                .retired_prekeys
                .iter()
                .any(|keys| keys.x25519_secret.len() != 32 || keys.mlkem_seed.len() != 64)
        {
            return Err(CoreError::VerificationFailed);
        }
        Ok(())
    }

    pub(crate) fn public_bundle(
        &self,
        signal_pre_key: Option<SignalPreKeyBundle>,
    ) -> CoreResult<PublicBundle> {
        self.validate()?;
        let signing_secret: [u8; ED25519_LENGTH] = self
            .signing_secret
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::VerificationFailed)?;
        let x25519_secret: [u8; X25519_SECRET_LENGTH] = self
            .x25519_secret
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::VerificationFailed)?;
        let mlkem_seed = Seed::try_from(self.mlkem_seed.as_slice())
            .map_err(|_| CoreError::VerificationFailed)?;
        let signing_key = SigningKey::from_bytes(&signing_secret);
        let x25519_public = PublicKey::from(&StaticSecret::from(x25519_secret));
        let mlkem_private = <MlKem768 as Kem>::DecapsulationKey::from_seed(mlkem_seed);
        let mlkem_public = mlkem_private.encapsulation_key().to_bytes();
        if mlkem_public.len() != ML_KEM_768_PUBLIC_KEY_LENGTH {
            return Err(CoreError::Internal);
        }
        PublicBundle::new_signed(
            &signing_key,
            x25519_public.as_bytes(),
            mlkem_public.as_slice(),
            self.expires_at_ms,
            signal_pre_key,
        )
    }
}

#[derive(Clone)]
struct UnlockedIdentity {
    path: PathBuf,
    password: Zeroizing<String>,
    record: IdentityRecord,
}

static ACTIVE_IDENTITY: OnceLock<Mutex<Option<UnlockedIdentity>>> = OnceLock::new();
#[cfg(test)]
pub(crate) static TEST_IDENTITY_LOCK: Mutex<()> = Mutex::new(());

fn active_identity_store() -> &'static Mutex<Option<UnlockedIdentity>> {
    ACTIVE_IDENTITY.get_or_init(|| Mutex::new(None))
}

pub(crate) fn wipe_memory() -> CoreResult<()> {
    *active_identity_store()
        .lock()
        .map_err(|_| CoreError::Internal)? = None;
    Ok(())
}

pub(crate) fn active_identity() -> CoreResult<IdentityRecord> {
    active_identity_store()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .as_ref()
        .map(|active| active.record.clone())
        .ok_or(CoreError::FeatureUnavailable)
}

fn activate_record(path: PathBuf, password: &str, record: IdentityRecord) -> CoreResult<()> {
    *active_identity_store()
        .lock()
        .map_err(|_| CoreError::Internal)? = Some(UnlockedIdentity {
        path,
        password: Zeroizing::new(password.to_owned()),
        record,
    });
    Ok(())
}

fn cached_record(path: &Path, password: &str) -> CoreResult<Option<IdentityRecord>> {
    use subtle::ConstantTimeEq;
    let active = active_identity_store()
        .lock()
        .map_err(|_| CoreError::Internal)?;
    Ok(active
        .as_ref()
        .filter(|active| {
            active.path == path && bool::from(active.password.as_bytes().ct_eq(password.as_bytes()))
        })
        .map(|active| active.record.clone()))
}

/// Background recovery reuses the already-unlocked session and public profile.
/// Caller holds the command and exclusive account gates; this never opens a vault.
#[cfg(all(feature = "veilid", target_os = "android"))]
pub(crate) fn republish_active_identity() -> CoreResult<()> {
    let active = active_identity_store()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .as_ref()
        .cloned()
        .ok_or(CoreError::VaultLocked)?;
    let directory = active
        .path
        .parent()
        .and_then(Path::parent)
        .and_then(Path::to_str)
        .ok_or(CoreError::InvalidInput)?;
    let profile = crate::peer_identity::current_public_profile();
    ensure_identity(
        directory,
        &active.password,
        profile.display_name,
        profile.avatar_base64,
    )?;
    Ok(())
}

pub(crate) fn active_dht_descriptor() -> CoreResult<Option<String>> {
    Ok(active_identity()?.dht_descriptor_json.clone())
}

pub(crate) fn export_account_record() -> CoreResult<serde_json::Value> {
    serde_json::to_value(active_identity()?).map_err(|_| CoreError::Internal)
}

pub(crate) fn import_account_record(
    storage_directory: &str,
    vault_password: &str,
    value: serde_json::Value,
) -> CoreResult<()> {
    validate_inputs(storage_directory, vault_password)?;
    crate::account_backup::recover_pending_import(Path::new(storage_directory))?;
    let mut record: IdentityRecord =
        serde_json::from_value(value).map_err(|_| CoreError::VerificationFailed)?;
    record.validate()?;
    // A linked/restored installation gets its own share record. It must never
    // reactivate or revoke the source device's invitation after a rotation.
    record.invitation = Default::default();
    let directory = PathBuf::from(storage_directory).join("identity");
    fs::create_dir_all(&directory).map_err(|_| CoreError::Internal)?;
    persist_record(&directory.join(IDENTITY_FILE_NAME), vault_password, &record)?;
    activate_record(directory.join(IDENTITY_FILE_NAME), vault_password, record)?;
    ratchet_adapter::configure_storage(storage_directory)
}

pub(crate) fn validate_account_record(value: &serde_json::Value) -> CoreResult<()> {
    let record: IdentityRecord =
        serde_json::from_value(value.clone()).map_err(|_| CoreError::VerificationFailed)?;
    record.validate()
}

pub(crate) fn activate_from_storage(
    storage_directory: &str,
    vault_password: &str,
) -> CoreResult<()> {
    validate_inputs(storage_directory, vault_password)?;
    let path = PathBuf::from(storage_directory)
        .join("identity")
        .join(IDENTITY_FILE_NAME);
    let record = load_record(&path, vault_password)?;
    record.validate()?;
    activate_record(path, vault_password, record)?;
    ratchet_adapter::configure_storage(storage_directory)
}

impl IdentityRecord {
    pub(crate) fn receiving_key_pairs(&self) -> CoreResult<Vec<(StaticSecret, Seed)>> {
        let mut pairs = vec![(self.x25519_secret()?, self.mlkem_seed()?)];
        let now = current_time_ms()?;
        for keys in &self.retired_prekeys {
            if keys.retain_until_ms <= now {
                continue;
            }
            let secret: [u8; 32] = keys
                .x25519_secret
                .as_slice()
                .try_into()
                .map_err(|_| CoreError::VerificationFailed)?;
            let seed = Seed::try_from(keys.mlkem_seed.as_slice())
                .map_err(|_| CoreError::VerificationFailed)?;
            pairs.push((StaticSecret::from(secret), seed));
        }
        Ok(pairs)
    }

    pub(crate) fn receiving_x25519_secrets(&self) -> CoreResult<Vec<StaticSecret>> {
        Ok(self
            .receiving_key_pairs()?
            .into_iter()
            .map(|(secret, _)| secret)
            .collect())
    }

    pub(crate) fn signing_key(&self) -> CoreResult<SigningKey> {
        let bytes: [u8; ED25519_LENGTH] = self
            .signing_secret
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::VerificationFailed)?;
        Ok(SigningKey::from_bytes(&bytes))
    }

    pub(crate) fn x25519_secret(&self) -> CoreResult<StaticSecret> {
        let bytes: [u8; X25519_SECRET_LENGTH] = self
            .x25519_secret
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::VerificationFailed)?;
        Ok(StaticSecret::from(bytes))
    }

    pub(crate) fn mlkem_seed(&self) -> CoreResult<Seed> {
        Seed::try_from(self.mlkem_seed.as_slice()).map_err(|_| CoreError::VerificationFailed)
    }

    pub(crate) fn storage_password(&self) -> CoreResult<String> {
        if self.message_storage_secret.len() != 32 {
            return Err(CoreError::VerificationFailed);
        }
        Ok(STANDARD_NO_PAD.encode(&self.message_storage_secret))
    }

    pub(crate) fn storage_key(&self) -> CoreResult<[u8; 32]> {
        self.message_storage_secret
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::VerificationFailed)
    }

    pub(crate) fn identity_public_key(&self) -> CoreResult<Vec<u8>> {
        Ok(self.signing_key()?.verifying_key().to_bytes().to_vec())
    }
}

pub fn ensure_identity(
    storage_directory: &str,
    vault_password: &str,
    display_name: Option<String>,
    avatar_base64: Option<String>,
) -> CoreResult<Value> {
    ensure_identity_with_rotation(
        storage_directory,
        vault_password,
        display_name,
        avatar_base64,
        None,
        false,
    )
}

pub fn ensure_identity_with_rotation(
    storage_directory: &str,
    vault_password: &str,
    display_name: Option<String>,
    avatar_base64: Option<String>,
    rotation_interval_seconds: Option<u64>,
    rotate_invitation: bool,
) -> CoreResult<Value> {
    if let Some(seconds) = rotation_interval_seconds {
        crate::invitation::validate_interval(seconds)?;
    }
    validate_inputs(storage_directory, vault_password)?;
    let directory = PathBuf::from(storage_directory).join("identity");
    fs::create_dir_all(&directory).map_err(|_| CoreError::Internal)?;
    let path = directory.join(IDENTITY_FILE_NAME);
    let now_ms = current_time_ms()?;
    let next_expiration = now_ms
        .checked_add(INVITATION_LIFETIME_MS)
        .ok_or(CoreError::Internal)?;

    let exists = path.exists();
    let cached = if exists {
        cached_record(&path, vault_password)?
    } else {
        None
    };
    let reused = cached.is_some();
    let mut record = match cached {
        Some(record) => record,
        None if exists => load_record(&path, vault_password)?,
        None => IdentityRecord::generate(next_expiration),
    };
    let mut should_persist = !path.exists() || record.expires_at_ms <= now_ms;
    if record.message_storage_secret.len() != 32 {
        record.message_storage_secret.resize(32, 0);
        OsRng.fill_bytes(&mut record.message_storage_secret);
        should_persist = true;
    }
    if record.expires_at_ms <= now_ms {
        record.rotate_prekeys(next_expiration);
    }
    let previous_count = record.retired_prekeys.len();
    record
        .retired_prekeys
        .retain(|keys| keys.retain_until_ms > now_ms);
    should_persist |= previous_count != record.retired_prekeys.len();
    record.validate()?;
    // Private key material must be durable before a matching public bundle is
    // made observable through Veilid. Descriptor changes are persisted again
    // after publication below.
    if should_persist {
        persist_record(&path, vault_password, &record)?;
        should_persist = false;
    }
    activate_record(path.clone(), vault_password, record.clone())?;
    if !reused {
        ratchet_adapter::configure_storage(storage_directory)?;
    }
    let mut signal_pre_key = ratchet_adapter::public_pre_key_bundle()?;
    let mut bundle = record.public_bundle(signal_pre_key.clone())?;
    bundle.validate()?;
    let identity_hash = Sha256::digest(&bundle.identity_ed25519);
    let identity_id = grouped_hex(&identity_hash[..8]);
    let serialized_bundle = serde_json::to_vec(&bundle).map_err(|_| CoreError::Internal)?;
    let mut invitation_code = format!("sylphy:{}", STANDARD_NO_PAD.encode(serialized_bundle));
    let public_profile = crate::peer_identity::PublicProfile {
        display_name,
        avatar_base64,
    };
    crate::peer_identity::set_public_profile(public_profile.clone())?;
    if let Ok((mailbox, descriptor)) =
        crate::veilid_adapter::ensure_mailbox(record.mailbox_descriptor_json.as_deref())
    {
        crate::peer_identity::set_public_mailbox(Some(mailbox))?;
        if record.mailbox_descriptor_json.as_deref() != Some(descriptor.as_str()) {
            record.mailbox_descriptor_json = Some(descriptor);
            should_persist = true;
        }
    } else {
        crate::peer_identity::set_public_mailbox(None)?;
    }
    let route = crate::veilid_adapter::local_route_blob();
    if (rotate_invitation || rotation_interval_seconds.is_some_and(|s| s != 0)) && route.is_err() {
        return Err(CoreError::NetworkStartupFailed);
    }
    if let Ok(route_blob) = route {
        let previous = record
            .dht_descriptor_json
            .as_deref()
            .and_then(|descriptor| crate::veilid_adapter::resolve_owned_identity(descriptor).ok());
        if let Some(previous) = &previous {
            let reserved = previous
                .delivery_devices()?
                .into_iter()
                .filter_map(|device| {
                    device
                        .bundle
                        .signal_pre_key
                        .map(|pre_key| (pre_key.device_id, pre_key.identity_key))
                })
                .collect::<Vec<_>>();
            if ratchet_adapter::avoid_device_id_collisions(&reserved)? {
                signal_pre_key = ratchet_adapter::public_pre_key_bundle()?;
                bundle = record.public_bundle(signal_pre_key.clone())?;
                let serialized_bundle =
                    serde_json::to_vec(&bundle).map_err(|_| CoreError::Internal)?;
                invitation_code = format!("sylphy:{}", STANDARD_NO_PAD.encode(serialized_bundle));
            }
        }
        let published = crate::peer_identity::PublishedIdentity::merged_for_current_device(
            &record.signing_key()?,
            previous.as_ref(),
            bundle.clone(),
            route_blob,
            public_profile,
            None,
        )?;
        let publication = crate::veilid_adapter::publish_identity(
            record.dht_descriptor_json.as_deref(),
            &published,
        );
        if (rotate_invitation
            || record.invitation.descriptor_json.is_some()
            || rotation_interval_seconds.is_some_and(|s| s != 0))
            && publication.is_err()
        {
            return Err(CoreError::NetworkStartupFailed);
        }
        if let Ok((short_code, descriptor)) = publication {
            let discovery_changed =
                record.dht_descriptor_json.as_deref() != Some(descriptor.as_str());
            record.dht_descriptor_json = Some(descriptor);
            let saved_invitation = record.invitation.clone();
            let signing_key = record.signing_key()?;
            let revoked =
                crate::invitation::ShareInvitation::new(&signing_key, short_code.clone(), 1)?;
            record.invitation.pending_revocations.retain(|descriptor| {
                crate::veilid_adapter::publish_invitation(Some(descriptor), &revoked).is_err()
            });
            let rotate =
                record
                    .invitation
                    .update(now_ms, rotation_interval_seconds, rotate_invitation)?;
            if rotate
                && record.invitation.pending_revocations.len()
                    >= crate::invitation::MAX_PENDING_REVOCATIONS
            {
                return Err(CoreError::LimitExceeded);
            }
            let share = crate::invitation::ShareInvitation::new(
                &signing_key,
                short_code,
                record.invitation.next_rotation_ms().unwrap_or(0),
            )?;
            let previous = record.invitation.descriptor_json.clone();
            let (code, descriptor) = crate::veilid_adapter::publish_invitation(
                if rotate { None } else { previous.as_deref() },
                &share,
            )?;
            record.invitation.descriptor_json = Some(descriptor);
            if rotate {
                if let Some(previous) = previous {
                    record.invitation.pending_revocations.push(previous);
                }
            }
            // Persist the new record and pending revocation before replacing the
            // old DHT value. An interrupted rotation is resumed on next publish.
            if should_persist || discovery_changed || record.invitation != saved_invitation {
                persist_record(&path, vault_password, &record)?;
                activate_record(path.clone(), vault_password, record.clone())?;
            }
            record.invitation.pending_revocations.retain(|descriptor| {
                crate::veilid_adapter::publish_invitation(Some(descriptor), &revoked).is_err()
            });
            invitation_code = code;
            // The durable retry list can safely contain already revoked records.
            // Avoid a second commit whose failure would hide a successful change.
            should_persist = false;
        }
    }
    // Do not replace an existing share ID with an inline fallback after a network failure.
    if record.invitation.descriptor_json.is_some() && !invitation_code.starts_with("sylphy:VLD") {
        return Err(CoreError::NetworkStartupFailed);
    }
    if should_persist {
        persist_record(&path, vault_password, &record)?;
    }
    let changed_at_ms = record.invitation.changed_at_ms;
    let next_rotation_at_ms = record.invitation.next_rotation_ms();
    let invitation_expires_at_ms = next_rotation_at_ms
        .map(|next| next.min(bundle.expires_at_ms))
        .unwrap_or(bundle.expires_at_ms);
    let revocation_pending = !record.invitation.pending_revocations.is_empty();
    activate_record(path, vault_password, record)?;
    Ok(json!({
        "identity_id": identity_id,
        "invitation_code": invitation_code,
        "expires_at_ms": invitation_expires_at_ms,
        "revocation_pending": revocation_pending,
        "invitation_changed_at_ms": changed_at_ms,
        "next_rotation_at_ms": next_rotation_at_ms,
    }))
}

fn validate_inputs(storage_directory: &str, vault_password: &str) -> CoreResult<()> {
    if storage_directory.trim().is_empty()
        || storage_directory.len() > MAX_STORAGE_PATH_BYTES
        || vault_password.is_empty()
        || vault_password.len() > MAX_VAULT_PASSWORD_BYTES
    {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}

fn load_record(path: &Path, vault_password: &str) -> CoreResult<IdentityRecord> {
    let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
    let plaintext = vault::open(vault_password, &encrypted)?;
    let record: IdentityRecord =
        serde_json::from_slice(plaintext.as_slice()).map_err(|_| CoreError::VerificationFailed)?;
    Ok(record)
}

fn persist_record(path: &Path, vault_password: &str, record: &IdentityRecord) -> CoreResult<()> {
    let serialized = Zeroizing::new(serde_json::to_vec(record).map_err(|_| CoreError::Internal)?);
    let encrypted = vault::seal(vault_password, &serialized)?;
    atomic_file::replace(path, &encrypted)
}

fn current_time_ms() -> CoreResult<u64> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::Internal)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| CoreError::Internal)
}

fn grouped_hex(bytes: &[u8]) -> String {
    bytes
        .chunks(4)
        .map(|chunk| {
            chunk
                .iter()
                .map(|byte| format!("{byte:02X}"))
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(not(feature = "veilid"))]
    #[test]
    fn offline_rotation_preserves_identity_and_import_creates_a_device_local_share_id() {
        let _guard = TEST_IDENTITY_LOCK.lock().unwrap();
        let root =
            std::env::temp_dir().join(format!("sylphy-offline-rotation-{}", std::process::id()));
        let target = root.join("linked");
        let root_text = root.to_string_lossy();
        let before = ensure_identity(&root_text, "test-device-secret", None, None).unwrap();
        let path = root.join("identity").join(IDENTITY_FILE_NAME);
        let encrypted_before = fs::read(&path).unwrap();
        assert!(
            ensure_identity_with_rotation(
                &root_text,
                "test-device-secret",
                None,
                None,
                Some(3600),
                true
            )
            .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), encrypted_before);
        let after = ensure_identity(&root_text, "test-device-secret", None, None).unwrap();
        assert_eq!(before["identity_id"], after["identity_id"]);
        assert_eq!(before["invitation_code"], after["invitation_code"]);
        let mut backup = export_account_record().unwrap();
        backup["invitation"]["descriptor_json"] = json!("source-device-owned-descriptor");
        backup["invitation"]["pending_revocations"] = json!(["source-device-retired-descriptor"]);
        import_account_record(&target.to_string_lossy(), "linked-device-secret", backup).unwrap();
        let linked = active_identity().unwrap();
        assert!(linked.invitation.descriptor_json.is_none());
        assert!(linked.invitation.pending_revocations.is_empty());
        assert_eq!(
            linked.signing_key().unwrap().verifying_key().to_bytes(),
            load_record(&path, "test-device-secret")
                .unwrap()
                .signing_key()
                .unwrap()
                .verifying_key()
                .to_bytes()
        );
        wipe_memory().unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn warm_identity_reuses_memory_and_wiping_requires_disk_authentication_again() {
        let _guard = TEST_IDENTITY_LOCK.lock().unwrap();
        let root =
            std::env::temp_dir().join(format!("sylphy-warm-identity-{}", std::process::id()));
        let root_text = root.to_string_lossy();
        let path = root.join("identity").join(IDENTITY_FILE_NAME);
        let first = ensure_identity(&root_text, "warm-test-secret", None, None).unwrap();
        let encrypted = fs::read(&path).unwrap();
        fs::write(&path, b"temporarily unreadable on disk").unwrap();
        let warm = ensure_identity(
            &root_text,
            "warm-test-secret",
            Some("Updated profile".into()),
            None,
        )
        .unwrap();
        assert_eq!(warm["identity_id"], first["identity_id"]);
        assert!(ensure_identity(&root_text, "wrong secret", None, None).is_err());
        wipe_memory().unwrap();
        assert!(ensure_identity(&root_text, "warm-test-secret", None, None).is_err());
        fs::write(&path, encrypted).unwrap();
        assert!(ensure_identity(&root_text, "wrong secret", None, None).is_err());
        let reopened = ensure_identity(&root_text, "warm-test-secret", None, None).unwrap();
        assert_eq!(reopened["identity_id"], first["identity_id"]);
        wipe_memory().unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn identity_is_stable_and_the_private_record_is_encrypted() {
        let _guard = TEST_IDENTITY_LOCK.lock().unwrap();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-identity-test-{}-{unique}",
            std::process::id()
        ));
        let directory_text = directory.to_string_lossy().into_owned();

        let first =
            ensure_identity(&directory_text, "test-device-secret", None, None).expect("identity");
        let second =
            ensure_identity(&directory_text, "test-device-secret", None, None).expect("identity");
        assert_eq!(first["identity_id"], second["identity_id"]);
        assert_eq!(first["invitation_code"], second["invitation_code"]);
        let invitation = first["invitation_code"]
            .as_str()
            .expect("invitation")
            .trim_start_matches("sylphy:");
        let decoded = STANDARD_NO_PAD
            .decode(invitation)
            .expect("base64 invitation");
        let bundle: PublicBundle = serde_json::from_slice(&decoded).expect("public bundle");
        bundle.validate().expect("signed bundle");

        let vault_path = directory.join("identity").join(IDENTITY_FILE_NAME);
        let vault_bytes = fs::read(&vault_path).expect("vault file");
        assert!(!vault_bytes.windows(9).any(|value| value == b"identity_"));
        assert!(matches!(
            ensure_identity(&directory_text, "wrong-device-secret", None, None),
            Err(CoreError::AuthenticationFailed)
        ));
        fs::remove_dir_all(&directory).expect("remove isolated test directory");
    }

    #[test]
    fn rotation_keeps_receiving_keys_for_offline_retention_only() {
        let now = current_time_ms().unwrap();
        let mut record = IdentityRecord::generate(now + 1000);
        let before = record.x25519_secret().unwrap().to_bytes();
        record.rotate_prekeys(now + INVITATION_LIFETIME_MS);
        record.validate().unwrap();
        let encoded = serde_json::to_vec(&record).unwrap();
        let restored: IdentityRecord = serde_json::from_slice(&encoded).unwrap();
        let keys = restored.receiving_x25519_secrets().unwrap();
        assert_eq!(keys.len(), 2);
        assert_ne!(keys[0].to_bytes(), before);
        assert_eq!(keys[1].to_bytes(), before);
        record.retired_prekeys[0].retain_until_ms = now - 1;
        assert_eq!(record.receiving_x25519_secrets().unwrap().len(), 1);
    }
}
