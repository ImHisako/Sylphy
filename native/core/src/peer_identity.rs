use base64::{Engine as _, engine::general_purpose::STANDARD};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock};

use crate::{
    PROTOCOL_VERSION,
    bundle::{ED25519_LENGTH, PublicBundle, SIGNATURE_LENGTH},
    error::{CoreError, CoreResult},
};

const MAX_ROUTE_BLOB_BYTES: usize = 16 * 1024;
const MAX_PUBLIC_NAME_CHARS: usize = 64;
// The complete PublishedIdentity must fit Veilid's 32 KiB subkey limit.
const MAX_AVATAR_BASE64_BYTES: usize = 12 * 1024;
const MAX_MAILBOX_FIELD_BYTES: usize = 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct MailboxAddress {
    pub record_key: String,
    pub writer_keypair_json: String,
}

impl MailboxAddress {
    pub fn validate(&self) -> CoreResult<()> {
        if self.record_key.is_empty()
            || self.record_key.len() > MAX_MAILBOX_FIELD_BYTES
            || self.writer_keypair_json.is_empty()
            || self.writer_keypair_json.len() > MAX_MAILBOX_FIELD_BYTES
        {
            return Err(CoreError::InvalidInput);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct PublicProfile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_base64: Option<String>,
}

impl PublicProfile {
    fn validate(&self) -> CoreResult<()> {
        if let Some(name) = &self.display_name {
            let normalized = name.trim();
            if normalized.is_empty()
                || normalized.chars().count() > MAX_PUBLIC_NAME_CHARS
                || normalized.chars().any(char::is_control)
            {
                return Err(CoreError::InvalidInput);
            }
        }
        if let Some(avatar) = &self.avatar_base64
            && (avatar.is_empty()
                || avatar.len() > MAX_AVATAR_BASE64_BYTES
                || STANDARD.decode(avatar).is_err())
        {
            return Err(CoreError::InvalidInput);
        }
        Ok(())
    }
}

static PUBLIC_PROFILE: OnceLock<Mutex<PublicProfile>> = OnceLock::new();
static PUBLIC_MAILBOX: OnceLock<Mutex<Option<MailboxAddress>>> = OnceLock::new();

pub(crate) fn set_public_profile(profile: PublicProfile) -> CoreResult<()> {
    profile.validate()?;
    *PUBLIC_PROFILE
        .get_or_init(|| Mutex::new(PublicProfile::default()))
        .lock()
        .map_err(|_| CoreError::Internal)? = profile;
    Ok(())
}

pub(crate) fn current_public_profile() -> PublicProfile {
    PUBLIC_PROFILE
        .get_or_init(|| Mutex::new(PublicProfile::default()))
        .lock()
        .map(|profile| profile.clone())
        .unwrap_or_default()
}

pub(crate) fn set_public_mailbox(mailbox: Option<MailboxAddress>) -> CoreResult<()> {
    if let Some(address) = &mailbox {
        address.validate()?;
    }
    *PUBLIC_MAILBOX
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| CoreError::Internal)? = mailbox;
    Ok(())
}

pub(crate) fn current_public_mailbox() -> Option<MailboxAddress> {
    PUBLIC_MAILBOX
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map(|mailbox| mailbox.clone())
        .unwrap_or_default()
}

/// Signed public identity published in Veilid's DHT and attached to the first
/// message from a previously unknown sender.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PublishedIdentity {
    pub version: u16,
    pub bundle: PublicBundle,
    pub route_blob: Vec<u8>,
    #[serde(default)]
    pub profile: PublicProfile,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mailbox: Option<MailboxAddress>,
    pub signature: Vec<u8>,
}

impl PublishedIdentity {
    pub fn new(
        signing_key: &SigningKey,
        bundle: PublicBundle,
        route_blob: Vec<u8>,
        profile: PublicProfile,
        mailbox: Option<MailboxAddress>,
    ) -> CoreResult<Self> {
        if route_blob.is_empty() || route_blob.len() > MAX_ROUTE_BLOB_BYTES {
            return Err(CoreError::InvalidInput);
        }
        let mut value = Self {
            version: PROTOCOL_VERSION,
            bundle,
            route_blob,
            profile,
            mailbox,
            signature: Vec::new(),
        };
        value.bundle.validate()?;
        value.signature = signing_key
            .sign(&value.signing_payload()?)
            .to_bytes()
            .to_vec();
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> CoreResult<()> {
        if self.version != PROTOCOL_VERSION
            || self.route_blob.is_empty()
            || self.route_blob.len() > MAX_ROUTE_BLOB_BYTES
            || self.signature.len() != SIGNATURE_LENGTH
        {
            return Err(CoreError::InvalidInput);
        }
        self.bundle.validate()?;
        self.profile.validate()?;
        if let Some(mailbox) = &self.mailbox {
            mailbox.validate()?;
        }
        let identity: [u8; ED25519_LENGTH] = self
            .bundle
            .identity_ed25519
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?;
        let verifying_key =
            VerifyingKey::from_bytes(&identity).map_err(|_| CoreError::VerificationFailed)?;
        let signature =
            Signature::from_slice(&self.signature).map_err(|_| CoreError::VerificationFailed)?;
        verifying_key
            .verify(&self.signing_payload()?, &signature)
            .map_err(|_| CoreError::VerificationFailed)
    }

    fn signing_payload(&self) -> CoreResult<Vec<u8>> {
        let bundle = serde_json::to_vec(&self.bundle).map_err(|_| CoreError::Internal)?;
        let mut payload = Vec::with_capacity(32 + bundle.len() + self.route_blob.len());
        payload.extend_from_slice(b"sylphy/published-identity/v1");
        payload.extend_from_slice(&self.version.to_be_bytes());
        payload.extend_from_slice(&(bundle.len() as u32).to_be_bytes());
        payload.extend_from_slice(&bundle);
        payload.extend_from_slice(&(self.route_blob.len() as u32).to_be_bytes());
        payload.extend_from_slice(&self.route_blob);
        if self.profile.display_name.is_some() || self.profile.avatar_base64.is_some() {
            let profile = serde_json::to_vec(&self.profile).map_err(|_| CoreError::Internal)?;
            payload.extend_from_slice(&(profile.len() as u32).to_be_bytes());
            payload.extend_from_slice(&profile);
        }
        if let Some(mailbox) = &self.mailbox {
            let mailbox = serde_json::to_vec(mailbox).map_err(|_| CoreError::Internal)?;
            payload.extend_from_slice(&(mailbox.len() as u32).to_be_bytes());
            payload.extend_from_slice(&mailbox);
        }
        Ok(payload)
    }
}
