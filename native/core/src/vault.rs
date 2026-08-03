use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit},
};
use rand_core::{OsRng, RngCore};
use zeroize::Zeroizing;

use crate::error::{CoreError, CoreResult};

const VAULT_VERSION: u8 = 1;
const SALT_LENGTH: usize = 16;
const NONCE_LENGTH: usize = 24;
const KEY_LENGTH: usize = 32;
const MIN_CIPHERTEXT_LENGTH: usize = 16;
const MAX_VAULT_PAYLOAD_LENGTH: usize = 32 * 1024 * 1024;

pub fn seal(password: &str, plaintext: &[u8]) -> CoreResult<Vec<u8>> {
    if password.is_empty() || plaintext.len() > MAX_VAULT_PAYLOAD_LENGTH {
        return Err(CoreError::InvalidInput);
    }

    let mut salt = [0_u8; SALT_LENGTH];
    let mut nonce = [0_u8; NONCE_LENGTH];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);

    let key = derive_key(password, &salt)?;
    let cipher =
        XChaCha20Poly1305::new_from_slice(key.as_ref()).map_err(|_| CoreError::Internal)?;
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext)
        .map_err(|_| CoreError::Internal)?;

    let mut record = Vec::with_capacity(1 + SALT_LENGTH + NONCE_LENGTH + ciphertext.len());
    record.push(VAULT_VERSION);
    record.extend_from_slice(&salt);
    record.extend_from_slice(&nonce);
    record.extend_from_slice(&ciphertext);
    Ok(record)
}

pub fn open(password: &str, record: &[u8]) -> CoreResult<Zeroizing<Vec<u8>>> {
    if password.is_empty()
        || record.len() < 1 + SALT_LENGTH + NONCE_LENGTH + MIN_CIPHERTEXT_LENGTH
        || record.len()
            > MAX_VAULT_PAYLOAD_LENGTH + 1 + SALT_LENGTH + NONCE_LENGTH + MIN_CIPHERTEXT_LENGTH
    {
        return Err(CoreError::InvalidInput);
    }
    if record[0] != VAULT_VERSION {
        return Err(CoreError::UnsupportedVersion);
    }

    let salt_start = 1;
    let nonce_start = salt_start + SALT_LENGTH;
    let ciphertext_start = nonce_start + NONCE_LENGTH;
    let key = derive_key(password, &record[salt_start..nonce_start])?;
    let cipher =
        XChaCha20Poly1305::new_from_slice(key.as_ref()).map_err(|_| CoreError::Internal)?;
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&record[nonce_start..ciphertext_start]),
            &record[ciphertext_start..],
        )
        .map_err(|_| CoreError::AuthenticationFailed)?;
    Ok(Zeroizing::new(plaintext))
}

fn derive_key(password: &str, salt: &[u8]) -> CoreResult<Zeroizing<[u8; KEY_LENGTH]>> {
    let params = Params::new(64 * 1024, 3, 4, Some(KEY_LENGTH)).map_err(|_| CoreError::Internal)?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0_u8; KEY_LENGTH]);
    argon2
        .hash_password_into(password.as_bytes(), salt, key.as_mut())
        .map_err(|_| CoreError::Internal)?;
    Ok(key)
}
