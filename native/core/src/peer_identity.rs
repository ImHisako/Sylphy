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
const MAX_LINKED_DEVICES: usize = 4;

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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PublishedDevice {
    pub bundle: PublicBundle,
    pub route_blob: Vec<u8>,
}

impl PublishedDevice {
    fn validate(&self, account_identity: &[u8]) -> CoreResult<()> {
        self.bundle.validate()?;
        if self.bundle.identity_ed25519 != account_identity
            || self.route_blob.is_empty()
            || self.route_blob.len() > MAX_ROUTE_BLOB_BYTES
            || self.bundle.signal_pre_key.is_none()
        {
            return Err(CoreError::VerificationFailed);
        }
        Ok(())
    }

    fn device_id(&self) -> CoreResult<u8> {
        self.bundle
            .signal_pre_key
            .as_ref()
            .map(|value| value.device_id)
            .ok_or(CoreError::UnsupportedVersion)
    }
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
    /// Additional endpoints belonging to the same signed account identity.
    /// Each endpoint owns an independent libsignal identity and device id.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub devices: Vec<PublishedDevice>,
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
            devices: Vec::new(),
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

    pub fn merged_for_current_device(
        signing_key: &SigningKey,
        previous: Option<&Self>,
        bundle: PublicBundle,
        route_blob: Vec<u8>,
        profile: PublicProfile,
        mailbox: Option<MailboxAddress>,
    ) -> CoreResult<Self> {
        let current = PublishedDevice {
            bundle: bundle.clone(),
            route_blob: route_blob.clone(),
        };
        let current_id = current.device_id()?;
        let mut devices = Vec::new();
        if let Some(previous) = previous {
            previous.validate()?;
            let previous_primary = PublishedDevice {
                bundle: previous.bundle.clone(),
                route_blob: previous.route_blob.clone(),
            };
            for candidate in std::iter::once(previous_primary).chain(previous.devices.clone()) {
                if candidate.device_id()? != current_id
                    && !devices.iter().any(|known: &PublishedDevice| {
                        known.device_id().ok() == candidate.device_id().ok()
                    })
                {
                    devices.push(candidate);
                }
            }
        }
        devices.truncate(MAX_LINKED_DEVICES.saturating_sub(1));
        let mut value = Self {
            version: PROTOCOL_VERSION,
            bundle,
            route_blob,
            profile,
            mailbox,
            devices,
            signature: Vec::new(),
        };
        value.signature = signing_key
            .sign(&value.signing_payload()?)
            .to_bytes()
            .to_vec();
        value.validate()?;
        Ok(value)
    }

    pub fn delivery_devices(&self) -> CoreResult<Vec<PublishedDevice>> {
        self.validate()?;
        let mut result = Vec::with_capacity(1 + self.devices.len());
        result.push(PublishedDevice {
            bundle: self.bundle.clone(),
            route_blob: self.route_blob.clone(),
        });
        result.extend(self.devices.clone());
        Ok(result)
    }

    pub fn validate(&self) -> CoreResult<()> {
        if self.version != PROTOCOL_VERSION
            || self.route_blob.is_empty()
            || self.route_blob.len() > MAX_ROUTE_BLOB_BYTES
            || self.signature.len() != SIGNATURE_LENGTH
            || self.devices.len() >= MAX_LINKED_DEVICES
        {
            return Err(CoreError::InvalidInput);
        }
        self.bundle.validate()?;
        self.profile.validate()?;
        if let Some(mailbox) = &self.mailbox {
            mailbox.validate()?;
        }
        let mut device_ids = std::collections::HashSet::new();
        let primary_id = self
            .bundle
            .signal_pre_key
            .as_ref()
            .map(|value| value.device_id)
            .ok_or(CoreError::UnsupportedVersion)?;
        device_ids.insert(primary_id);
        for device in &self.devices {
            device.validate(&self.bundle.identity_ed25519)?;
            if !device_ids.insert(device.device_id()?) {
                return Err(CoreError::VerificationFailed);
            }
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
        if !self.devices.is_empty() {
            let devices = serde_json::to_vec(&self.devices).map_err(|_| CoreError::Internal)?;
            payload.extend_from_slice(&(devices.len() as u32).to_be_bytes());
            payload.extend_from_slice(&devices);
        }
        Ok(payload)
    }
}
