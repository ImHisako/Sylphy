use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
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
    bundle::{ED25519_LENGTH, ML_KEM_768_PUBLIC_KEY_LENGTH, PublicBundle},
    error::{CoreError, CoreResult},
    vault,
};

const IDENTITY_FILE_NAME: &str = "identity-v1.vault";
const IDENTITY_RECORD_VERSION: u8 = 1;
const X25519_SECRET_LENGTH: usize = 32;
const ML_KEM_SEED_LENGTH: usize = 64;
const INVITATION_LIFETIME_MS: u64 = 30 * 24 * 60 * 60 * 1000;
const MAX_STORAGE_PATH_BYTES: usize = 4096;
const MAX_VAULT_PASSWORD_BYTES: usize = 512;

#[derive(Debug, Deserialize, Serialize)]
struct IdentityRecord {
    version: u8,
    signing_secret: Vec<u8>,
    x25519_secret: Vec<u8>,
    mlkem_seed: Vec<u8>,
    expires_at_ms: u64,
}

impl Drop for IdentityRecord {
    fn drop(&mut self) {
        self.signing_secret.zeroize();
        self.x25519_secret.zeroize();
        self.mlkem_seed.zeroize();
    }
}

impl IdentityRecord {
    fn generate(expires_at_ms: u64) -> Self {
        let signing_key = SigningKey::generate(&mut OsRng);
        let x25519_secret = StaticSecret::random_from_rng(OsRng);
        let mut mlkem_seed = vec![0_u8; ML_KEM_SEED_LENGTH];
        OsRng.fill_bytes(&mut mlkem_seed);
        Self {
            version: IDENTITY_RECORD_VERSION,
            signing_secret: signing_key.to_bytes().to_vec(),
            x25519_secret: x25519_secret.to_bytes().to_vec(),
            mlkem_seed,
            expires_at_ms,
        }
    }

    fn rotate_prekeys(&mut self, expires_at_ms: u64) {
        let x25519_secret = StaticSecret::random_from_rng(OsRng);
        self.x25519_secret.zeroize();
        self.x25519_secret = x25519_secret.to_bytes().to_vec();
        self.mlkem_seed.zeroize();
        self.mlkem_seed.resize(ML_KEM_SEED_LENGTH, 0);
        OsRng.fill_bytes(&mut self.mlkem_seed);
        self.expires_at_ms = expires_at_ms;
    }

    fn validate(&self) -> CoreResult<()> {
        if self.version != IDENTITY_RECORD_VERSION
            || self.signing_secret.len() != ED25519_LENGTH
            || self.x25519_secret.len() != X25519_SECRET_LENGTH
            || self.mlkem_seed.len() != ML_KEM_SEED_LENGTH
        {
            return Err(CoreError::VerificationFailed);
        }
        Ok(())
    }

    fn public_bundle(&self) -> CoreResult<PublicBundle> {
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
        )
    }
}

pub fn ensure_identity(storage_directory: &str, vault_password: &str) -> CoreResult<Value> {
    validate_inputs(storage_directory, vault_password)?;
    let directory = PathBuf::from(storage_directory).join("identity");
    fs::create_dir_all(&directory).map_err(|_| CoreError::Internal)?;
    let path = directory.join(IDENTITY_FILE_NAME);
    let now_ms = current_time_ms()?;
    let next_expiration = now_ms
        .checked_add(INVITATION_LIFETIME_MS)
        .ok_or(CoreError::Internal)?;

    let mut record = if path.exists() {
        load_record(&path, vault_password)?
    } else {
        IdentityRecord::generate(next_expiration)
    };
    let should_persist = !path.exists() || record.expires_at_ms <= now_ms;
    if record.expires_at_ms <= now_ms {
        record.rotate_prekeys(next_expiration);
    }
    record.validate()?;
    if should_persist {
        persist_record(&path, vault_password, &record)?;
    }

    let bundle = record.public_bundle()?;
    bundle.validate()?;
    let identity_hash = Sha256::digest(&bundle.identity_ed25519);
    let identity_id = grouped_hex(&identity_hash);
    let serialized_bundle = serde_json::to_vec(&bundle).map_err(|_| CoreError::Internal)?;
    let invitation_code = format!("sylphy:{}", STANDARD_NO_PAD.encode(serialized_bundle));
    Ok(json!({
        "identity_id": identity_id,
        "invitation_code": invitation_code,
        "expires_at_ms": bundle.expires_at_ms,
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
    record.validate()?;
    Ok(record)
}

fn persist_record(path: &Path, vault_password: &str, record: &IdentityRecord) -> CoreResult<()> {
    let serialized = Zeroizing::new(serde_json::to_vec(record).map_err(|_| CoreError::Internal)?);
    let encrypted = vault::seal(vault_password, &serialized)?;
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|_| CoreError::Internal)?;
    file.write_all(&encrypted)
        .map_err(|_| CoreError::Internal)?;
    file.sync_all().map_err(|_| CoreError::Internal)
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

    #[test]
    fn identity_is_stable_and_the_private_record_is_encrypted() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-identity-test-{}-{unique}",
            std::process::id()
        ));
        let directory_text = directory.to_string_lossy().into_owned();

        let first = ensure_identity(&directory_text, "test-device-secret").expect("identity");
        let second = ensure_identity(&directory_text, "test-device-secret").expect("identity");
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
            ensure_identity(&directory_text, "wrong-device-secret"),
            Err(CoreError::AuthenticationFailed)
        ));
        fs::remove_dir_all(&directory).expect("remove isolated test directory");
    }
}
