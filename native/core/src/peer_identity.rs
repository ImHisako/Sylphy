use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};

use crate::{
    PROTOCOL_VERSION,
    bundle::{ED25519_LENGTH, PublicBundle, SIGNATURE_LENGTH},
    error::{CoreError, CoreResult},
};

const MAX_ROUTE_BLOB_BYTES: usize = 16 * 1024;

/// Signed public identity published in Veilid's DHT and attached to the first
/// message from a previously unknown sender.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PublishedIdentity {
    pub version: u16,
    pub bundle: PublicBundle,
    pub route_blob: Vec<u8>,
    pub signature: Vec<u8>,
}

impl PublishedIdentity {
    pub fn new(
        signing_key: &SigningKey,
        bundle: PublicBundle,
        route_blob: Vec<u8>,
    ) -> CoreResult<Self> {
        if route_blob.is_empty() || route_blob.len() > MAX_ROUTE_BLOB_BYTES {
            return Err(CoreError::InvalidInput);
        }
        let mut value = Self {
            version: PROTOCOL_VERSION,
            bundle,
            route_blob,
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
        Ok(payload)
    }
}
