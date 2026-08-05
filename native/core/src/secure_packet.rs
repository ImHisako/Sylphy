use std::time::{SystemTime, UNIX_EPOCH};

use ed25519_dalek::{Signature, Signer, Verifier, VerifyingKey};
use ml_kem::{
    MlKem768,
    kem::{Decapsulate, Encapsulate, Kem, Key},
    ml_kem_768::{Ciphertext, EncapsulationKey},
};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::{
    PROTOCOL_VERSION,
    envelope::{self, EnvelopeMetadata, EnvelopeType, MessageEnvelope},
    error::{CoreError, CoreResult},
    hybrid, identity,
    peer_identity::PublishedIdentity,
};

const MAX_PACKET_BYTES: usize = 32 * 1024;
const MAX_MESSAGE_BYTES: usize = 16 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SecurePacket {
    version: u16,
    message_id: Vec<u8>,
    sender: PublishedIdentity,
    recipient_identity: Vec<u8>,
    ephemeral_x25519: Vec<u8>,
    mlkem_ciphertext: Vec<u8>,
    envelope: MessageEnvelope,
    signature: Vec<u8>,
}

pub struct OpenedPacket {
    pub message_id: String,
    pub sender: PublishedIdentity,
    pub plaintext: String,
    pub sent_at_ms: u64,
}

pub fn seal_for(recipient: &PublishedIdentity, plaintext: &str) -> CoreResult<(Vec<u8>, String)> {
    recipient.validate()?;
    let plaintext = plaintext.trim();
    if plaintext.is_empty() || plaintext.len() > MAX_MESSAGE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let local = identity::active_identity()?;
    let signing_key = local.signing_key()?;
    let local_bundle = local.public_bundle()?;
    let route_blob = crate::veilid_adapter::local_route_blob()?;
    let sender = PublishedIdentity::new(&signing_key, local_bundle.clone(), route_blob)?;

    let remote_x: [u8; 32] = recipient
        .bundle
        .signed_prekey_x25519
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::VerificationFailed)?;
    let ephemeral_secret = StaticSecret::random_from_rng(OsRng);
    let ephemeral_public = PublicKey::from(&ephemeral_secret);
    let classical = ephemeral_secret.diffie_hellman(&PublicKey::from(remote_x));

    let encoded_key =
        Key::<EncapsulationKey>::try_from(recipient.bundle.signed_prekey_mlkem768.as_slice())
            .map_err(|_| CoreError::VerificationFailed)?;
    let remote_pq =
        EncapsulationKey::new(&encoded_key).map_err(|_| CoreError::VerificationFailed)?;
    let (pq_ciphertext, pq_shared) = remote_pq.encapsulate();

    let mut message_id = vec![0_u8; 16];
    OsRng.fill_bytes(&mut message_id);
    let transcript = transcript_hash(
        &sender.bundle.identity_ed25519,
        &recipient.bundle.identity_ed25519,
        ephemeral_public.as_bytes(),
        pq_ciphertext.as_slice(),
        &message_id,
    );
    let root_key = hybrid::derive_root_key(
        classical.as_bytes(),
        pq_shared.as_slice(),
        transcript.as_slice(),
    )?;
    let sent_at_ms = current_time_ms()?;
    let conversation_id = conversation_bytes(
        &sender.bundle.identity_ed25519,
        &recipient.bundle.identity_ed25519,
    );
    let envelope = envelope::seal(
        &root_key,
        EnvelopeMetadata {
            version: PROTOCOL_VERSION,
            message_type: EnvelopeType::Message,
            conversation_id,
            sender_identity_key_id: identity_prefix(&sender.bundle.identity_ed25519),
            recipient_identity_key_id: identity_prefix(&recipient.bundle.identity_ed25519),
            session_id: transcript[..16].to_vec(),
            timestamp_logical: sent_at_ms,
            ratchet_header: b"hybrid-one-shot-v1".to_vec(),
            attachment_refs: Vec::new(),
        },
        plaintext.as_bytes(),
    )?;
    let mut packet = SecurePacket {
        version: PROTOCOL_VERSION,
        message_id,
        sender,
        recipient_identity: recipient.bundle.identity_ed25519.clone(),
        ephemeral_x25519: ephemeral_public.as_bytes().to_vec(),
        mlkem_ciphertext: pq_ciphertext.to_vec(),
        envelope,
        signature: Vec::new(),
    };
    packet.signature = signing_key
        .sign(&packet.signing_payload()?)
        .to_bytes()
        .to_vec();
    let bytes = serde_json::to_vec(&packet).map_err(|_| CoreError::Internal)?;
    if bytes.len() > MAX_PACKET_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let id = compact_hex(&packet.message_id);
    Ok((bytes, id))
}

pub fn open(payload: &[u8]) -> CoreResult<OpenedPacket> {
    if payload.is_empty() || payload.len() > MAX_PACKET_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let packet: SecurePacket =
        serde_json::from_slice(payload).map_err(|_| CoreError::InvalidInput)?;
    packet.validate()?;
    let local = identity::active_identity()?;
    let local_bundle = local.public_bundle()?;
    if packet.recipient_identity != local_bundle.identity_ed25519 {
        return Err(CoreError::AuthenticationFailed);
    }
    let ephemeral: [u8; 32] = packet
        .ephemeral_x25519
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidInput)?;
    let classical = local
        .x25519_secret()?
        .diffie_hellman(&PublicKey::from(ephemeral));
    let ciphertext = Ciphertext::try_from(packet.mlkem_ciphertext.as_slice())
        .map_err(|_| CoreError::InvalidInput)?;
    let decapsulation_key = <MlKem768 as Kem>::DecapsulationKey::from_seed(local.mlkem_seed()?);
    let pq_shared = decapsulation_key.decapsulate(&ciphertext);
    let transcript = transcript_hash(
        &packet.sender.bundle.identity_ed25519,
        &packet.recipient_identity,
        &packet.ephemeral_x25519,
        &packet.mlkem_ciphertext,
        &packet.message_id,
    );
    let root_key = hybrid::derive_root_key(
        classical.as_bytes(),
        pq_shared.as_slice(),
        transcript.as_slice(),
    )?;
    let plaintext = envelope::open(&root_key, &packet.envelope)?;
    let text = String::from_utf8(plaintext.to_vec()).map_err(|_| CoreError::InvalidInput)?;
    if text.is_empty() || text.len() > MAX_MESSAGE_BYTES {
        return Err(CoreError::InvalidInput);
    }
    Ok(OpenedPacket {
        message_id: compact_hex(&packet.message_id),
        sender: packet.sender,
        plaintext: text,
        sent_at_ms: packet.envelope.metadata.timestamp_logical,
    })
}

impl SecurePacket {
    fn validate(&self) -> CoreResult<()> {
        if self.version != PROTOCOL_VERSION
            || self.message_id.len() != 16
            || self.recipient_identity.len() != 32
            || self.ephemeral_x25519.len() != 32
            || self.signature.len() != 64
        {
            return Err(CoreError::InvalidInput);
        }
        self.sender.validate()?;
        if self.envelope.metadata.sender_identity_key_id
            != identity_prefix(&self.sender.bundle.identity_ed25519)
            || self.envelope.metadata.recipient_identity_key_id
                != identity_prefix(&self.recipient_identity)
        {
            return Err(CoreError::AuthenticationFailed);
        }
        let identity: [u8; 32] = self
            .sender
            .bundle
            .identity_ed25519
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?;
        let verifier =
            VerifyingKey::from_bytes(&identity).map_err(|_| CoreError::VerificationFailed)?;
        let signature =
            Signature::from_slice(&self.signature).map_err(|_| CoreError::VerificationFailed)?;
        verifier
            .verify(&self.signing_payload()?, &signature)
            .map_err(|_| CoreError::AuthenticationFailed)
    }

    fn signing_payload(&self) -> CoreResult<Vec<u8>> {
        #[derive(Serialize)]
        struct SignedFields<'a> {
            version: u16,
            message_id: &'a [u8],
            sender: &'a PublishedIdentity,
            recipient_identity: &'a [u8],
            ephemeral_x25519: &'a [u8],
            mlkem_ciphertext: &'a [u8],
            envelope: &'a MessageEnvelope,
        }
        serde_json::to_vec(&SignedFields {
            version: self.version,
            message_id: &self.message_id,
            sender: &self.sender,
            recipient_identity: &self.recipient_identity,
            ephemeral_x25519: &self.ephemeral_x25519,
            mlkem_ciphertext: &self.mlkem_ciphertext,
            envelope: &self.envelope,
        })
        .map_err(|_| CoreError::Internal)
    }
}

fn transcript_hash(
    sender: &[u8],
    recipient: &[u8],
    ephemeral: &[u8],
    pq_ciphertext: &[u8],
    message_id: &[u8],
) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"sylphy/hybrid-message/v1");
    hasher.update(sender);
    hasher.update(recipient);
    hasher.update(ephemeral);
    hasher.update(pq_ciphertext);
    hasher.update(message_id);
    hasher.finalize().to_vec()
}

fn conversation_bytes(first: &[u8], second: &[u8]) -> Vec<u8> {
    let (left, right) = if first <= second {
        (first, second)
    } else {
        (second, first)
    };
    let mut hasher = Sha256::new();
    hasher.update(b"sylphy/conversation/v1");
    hasher.update(left);
    hasher.update(right);
    hasher.finalize()[..16].to_vec()
}

fn identity_prefix(identity: &[u8]) -> Vec<u8> {
    Sha256::digest(identity)[..16].to_vec()
}

fn compact_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02X}")).collect()
}

fn current_time_ms() -> CoreResult<u64> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::Internal)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| CoreError::Internal)
}
