use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::{
    PROTOCOL_VERSION,
    error::{CoreError, CoreResult},
};

const NONCE_LENGTH: usize = 24;
const COMMITMENT_LENGTH: usize = 32;
const MAX_CIPHERTEXT_LENGTH: usize = 4 * 1024 * 1024;
const MAX_ATTACHMENTS: usize = 32;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnvelopeType {
    Handshake,
    Message,
    Acknowledgement,
    Retry,
    PrekeyRefresh,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachmentReference {
    pub encrypted_pointer: Vec<u8>,
    pub ciphertext_hash: Vec<u8>,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvelopeMetadata {
    pub version: u16,
    pub message_type: EnvelopeType,
    pub conversation_id: Vec<u8>,
    pub sender_identity_key_id: Vec<u8>,
    pub recipient_identity_key_id: Vec<u8>,
    pub session_id: Vec<u8>,
    pub timestamp_logical: u64,
    pub ratchet_header: Vec<u8>,
    pub attachment_refs: Vec<AttachmentReference>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageEnvelope {
    pub metadata: EnvelopeMetadata,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub aad_commitment: Vec<u8>,
}

impl EnvelopeMetadata {
    pub fn validate(&self) -> CoreResult<()> {
        if self.version != PROTOCOL_VERSION
            || !(16..=64).contains(&self.conversation_id.len())
            || !(8..=64).contains(&self.sender_identity_key_id.len())
            || !(8..=64).contains(&self.recipient_identity_key_id.len())
            || !(16..=64).contains(&self.session_id.len())
            || self.ratchet_header.len() > 4096
            || self.attachment_refs.len() > MAX_ATTACHMENTS
            || self.attachment_refs.iter().any(|attachment| {
                attachment.encrypted_pointer.is_empty()
                    || attachment.encrypted_pointer.len() > 4096
                    || attachment.ciphertext_hash.len() != 32
                    || attachment.size == 0
            })
        {
            return Err(CoreError::InvalidInput);
        }
        Ok(())
    }

    fn aad(&self) -> CoreResult<Vec<u8>> {
        self.validate()?;
        serde_json::to_vec(self).map_err(|_| CoreError::Internal)
    }
}

pub fn seal(
    session_key: &[u8; 32],
    metadata: EnvelopeMetadata,
    plaintext: &[u8],
) -> CoreResult<MessageEnvelope> {
    if plaintext.is_empty() || plaintext.len() > MAX_CIPHERTEXT_LENGTH {
        return Err(CoreError::LimitExceeded);
    }
    let aad = metadata.aad()?;
    let mut nonce = [0_u8; NONCE_LENGTH];
    OsRng.fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new_from_slice(session_key).map_err(|_| CoreError::Internal)?;
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| CoreError::Internal)?;
    Ok(MessageEnvelope {
        metadata,
        nonce: nonce.to_vec(),
        ciphertext,
        aad_commitment: Sha256::digest(aad).to_vec(),
    })
}

pub fn open(session_key: &[u8; 32], envelope: &MessageEnvelope) -> CoreResult<Zeroizing<Vec<u8>>> {
    if envelope.nonce.len() != NONCE_LENGTH
        || envelope.ciphertext.len() < 16
        || envelope.ciphertext.len() > MAX_CIPHERTEXT_LENGTH + 16
        || envelope.aad_commitment.len() != COMMITMENT_LENGTH
    {
        return Err(CoreError::InvalidInput);
    }
    let aad = envelope.metadata.aad()?;
    let actual_commitment = Sha256::digest(&aad);
    if actual_commitment
        .as_slice()
        .ct_eq(envelope.aad_commitment.as_slice())
        .unwrap_u8()
        != 1
    {
        return Err(CoreError::AuthenticationFailed);
    }
    let cipher = XChaCha20Poly1305::new_from_slice(session_key).map_err(|_| CoreError::Internal)?;
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&envelope.nonce),
            Payload {
                msg: &envelope.ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| CoreError::AuthenticationFailed)?;
    Ok(Zeroizing::new(plaintext))
}
