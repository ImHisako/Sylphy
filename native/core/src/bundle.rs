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
pub struct SignalPreKeyBundle {
    pub registration_id: u32,
    pub device_id: u8,
    pub signed_pre_key_id: u32,
    pub signed_pre_key_public: Vec<u8>,
    pub signed_pre_key_signature: Vec<u8>,
    pub kyber_pre_key_id: u32,
    pub kyber_pre_key_public: Vec<u8>,
    pub kyber_pre_key_signature: Vec<u8>,
    pub identity_key: Vec<u8>,
}

impl SignalPreKeyBundle {
    pub fn validate(&self) -> CoreResult<()> {
        if self.registration_id == 0
            || self.device_id == 0
            || self.signed_pre_key_public.is_empty()
            || self.signed_pre_key_public.len() > 128
            || self.signed_pre_key_signature.is_empty()
            || self.signed_pre_key_signature.len() > 256
            || self.kyber_pre_key_public.is_empty()
            || self.kyber_pre_key_public.len() > 4096
            || self.kyber_pre_key_signature.is_empty()
            || self.kyber_pre_key_signature.len() > 256
            || self.identity_key.is_empty()
            || self.identity_key.len() > 128
        {
            return Err(CoreError::InvalidInput);
        }
        Ok(())
    }
}

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal_pre_key: Option<SignalPreKeyBundle>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signal_pre_key_signature: Vec<u8>,
}

impl PublicBundle {
    pub fn new_signed(
        signing_key: &SigningKey,
        x25519_prekey: &[u8],
        mlkem_prekey: &[u8],
        expires_at_ms: u64,
        signal_pre_key: Option<SignalPreKeyBundle>,
    ) -> CoreResult<Self> {
        if x25519_prekey.len() != X25519_PUBLIC_KEY_LENGTH
            || mlkem_prekey.len() != ML_KEM_768_PUBLIC_KEY_LENGTH
        {
            return Err(CoreError::InvalidInput);
        }
        let version = PROTOCOL_VERSION;
        let sign_payload = |label: &[u8], key: &[u8]| {
            let mut payload = Vec::with_capacity(label.len() + 2 + 8 + key.len());
            payload.extend_from_slice(label);
            payload.extend_from_slice(&version.to_be_bytes());
            payload.extend_from_slice(&expires_at_ms.to_be_bytes());
            payload.extend_from_slice(key);
            payload
        };
        let signal_pre_key_signature = signal_pre_key
            .as_ref()
            .map(|value| {
                serde_json::to_vec(value)
                    .map(|encoded| {
                        signing_key
                            .sign(&sign_payload(b"sylphy/prekey/libsignal/v1", &encoded))
                            .to_bytes()
                            .to_vec()
                    })
                    .map_err(|_| CoreError::Internal)
            })
            .transpose()?
            .unwrap_or_default();
        let mut capabilities = vec!["hybrid-x25519-mlkem768".to_owned()];
        if signal_pre_key.is_some() {
            capabilities.push("signal-libsignal-v1".to_owned());
        }
        let bundle = Self {
            version,
            identity_ed25519: signing_key.verifying_key().to_bytes().to_vec(),
            signed_prekey_x25519_signature: signing_key
                .sign(&sign_payload(b"sylphy/prekey/x25519/v1", x25519_prekey))
                .to_bytes()
                .to_vec(),
            signed_prekey_x25519: x25519_prekey.to_vec(),
            signed_prekey_mlkem768_signature: signing_key
                .sign(&sign_payload(b"sylphy/prekey/mlkem768/v1", mlkem_prekey))
                .to_bytes()
                .to_vec(),
            signed_prekey_mlkem768: mlkem_prekey.to_vec(),
            expires_at_ms,
            capabilities,
            signal_pre_key,
            signal_pre_key_signature,
        };
        bundle.validate()?;
        Ok(bundle)
    }

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
        match &self.signal_pre_key {
            Some(signal) => {
                signal.validate()?;
                if self.signal_pre_key_signature.len() != SIGNATURE_LENGTH
                    || !self
                        .capabilities
                        .iter()
                        .any(|item| item == "signal-libsignal-v1")
                {
                    return Err(CoreError::InvalidInput);
                }
                let encoded = serde_json::to_vec(signal).map_err(|_| CoreError::Internal)?;
                let signature = Signature::from_slice(&self.signal_pre_key_signature)
                    .map_err(|_| CoreError::VerificationFailed)?;
                verifier
                    .verify(
                        &self.signature_payload(b"sylphy/prekey/libsignal/v1", &encoded),
                        &signature,
                    )
                    .map_err(|_| CoreError::VerificationFailed)?;
            }
            None => {
                if !self.signal_pre_key_signature.is_empty()
                    || self
                        .capabilities
                        .iter()
                        .any(|item| item == "signal-libsignal-v1")
                {
                    return Err(CoreError::InvalidInput);
                }
            }
        }
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
    PublicBundle::new_signed(
        &signing_key,
        &x25519_prekey,
        &mlkem_prekey,
        expires_at_ms,
        None,
    )
    .expect("valid generated test bundle")
}
