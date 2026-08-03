use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};

use crate::{
    PROTOCOL_VERSION,
    error::{CoreError, CoreResult},
};

pub const ED25519_LENGTH: usize = 32;
pub const SIGNATURE_LENGTH: usize = 64;
pub const X25519_PUBLIC_KEY_LENGTH: usize = 32;
pub const ML_KEM_768_PUBLIC_KEY_LENGTH: usize = 1184;
pub const MAX_CAPABILITIES: usize = 16;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicBundle {
    pub version: u16,
    pub identity_ed25519: Vec<u8>,
    pub signed_prekey_x25519: Vec<u8>,
    pub signed_prekey_x25519_signature: Vec<u8>,
    pub signed_prekey_mlkem768: Vec<u8>,
    pub signed_prekey_mlkem768_signature: Vec<u8>,
    pub expires_at_ms: u64,
    pub capabilities: Vec<String>,
}

impl PublicBundle {
    pub fn validate(&self) -> CoreResult<()> {
        if self.version != PROTOCOL_VERSION
            || self.identity_ed25519.len() != ED25519_LENGTH
            || self.signed_prekey_x25519.len() != X25519_PUBLIC_KEY_LENGTH
            || self.signed_prekey_x25519_signature.len() != SIGNATURE_LENGTH
            || self.signed_prekey_mlkem768.len() != ML_KEM_768_PUBLIC_KEY_LENGTH
            || self.signed_prekey_mlkem768_signature.len() != SIGNATURE_LENGTH
            || self.capabilities.is_empty()
            || self.capabilities.len() > MAX_CAPABILITIES
            || !self
                .capabilities
                .iter()
                .any(|item| item == "hybrid-x25519-mlkem768")
            || self
                .capabilities
                .iter()
                .any(|item| item.is_empty() || item.len() > 64)
        {
            return Err(CoreError::InvalidInput);
        }

        let identity_bytes: [u8; ED25519_LENGTH] = self
            .identity_ed25519
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?;
        let verifier =
            VerifyingKey::from_bytes(&identity_bytes).map_err(|_| CoreError::VerificationFailed)?;
        let x_signature = Signature::from_slice(&self.signed_prekey_x25519_signature)
            .map_err(|_| CoreError::VerificationFailed)?;
        let pq_signature = Signature::from_slice(&self.signed_prekey_mlkem768_signature)
            .map_err(|_| CoreError::VerificationFailed)?;
        verifier
            .verify(
                &self.signature_payload(b"sylphy/prekey/x25519/v1", &self.signed_prekey_x25519),
                &x_signature,
            )
            .map_err(|_| CoreError::VerificationFailed)?;
        verifier
            .verify(
                &self.signature_payload(b"sylphy/prekey/mlkem768/v1", &self.signed_prekey_mlkem768),
                &pq_signature,
            )
            .map_err(|_| CoreError::VerificationFailed)?;
        Ok(())
    }

    fn signature_payload(&self, label: &[u8], key: &[u8]) -> Vec<u8> {
        let mut payload = Vec::with_capacity(label.len() + 2 + 8 + key.len());
        payload.extend_from_slice(label);
        payload.extend_from_slice(&self.version.to_be_bytes());
        payload.extend_from_slice(&self.expires_at_ms.to_be_bytes());
        payload.extend_from_slice(key);
        payload
    }
}

pub fn generate_bundle_for_test(expires_at_ms: u64) -> PublicBundle {
    let signing_key = SigningKey::generate(&mut OsRng);
    let mut x25519_prekey = vec![0_u8; X25519_PUBLIC_KEY_LENGTH];
    let mut mlkem_prekey = vec![0_u8; ML_KEM_768_PUBLIC_KEY_LENGTH];
    OsRng.fill_bytes(&mut x25519_prekey);
    OsRng.fill_bytes(&mut mlkem_prekey);
    let version = PROTOCOL_VERSION;
    let sign_payload = |label: &[u8], key: &[u8]| {
        let mut payload = Vec::with_capacity(label.len() + 2 + 8 + key.len());
        payload.extend_from_slice(label);
        payload.extend_from_slice(&version.to_be_bytes());
        payload.extend_from_slice(&expires_at_ms.to_be_bytes());
        payload.extend_from_slice(key);
        payload
    };
    PublicBundle {
        version,
        identity_ed25519: signing_key.verifying_key().to_bytes().to_vec(),
        signed_prekey_x25519_signature: signing_key
            .sign(&sign_payload(b"sylphy/prekey/x25519/v1", &x25519_prekey))
            .to_bytes()
            .to_vec(),
        signed_prekey_x25519: x25519_prekey,
        signed_prekey_mlkem768_signature: signing_key
            .sign(&sign_payload(b"sylphy/prekey/mlkem768/v1", &mlkem_prekey))
            .to_bytes()
            .to_vec(),
        signed_prekey_mlkem768: mlkem_prekey,
        expires_at_ms,
        capabilities: vec!["hybrid-x25519-mlkem768".to_owned()],
    }
}
