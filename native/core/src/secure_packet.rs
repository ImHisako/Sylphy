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
    peer_identity::{PublicProfile, PublishedDevice, PublishedIdentity},
    ratchet_adapter,
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
    pending_ratchet: Option<ratchet_adapter::PendingDecrypt>,
}

impl OpenedPacket {
    pub fn commit_ratchet(&mut self) -> CoreResult<()> {
        self.pending_ratchet
            .take()
            .ok_or(CoreError::Internal)?
            .commit()
    }
}

pub struct InspectedPacket {
    pub message_id: String,
    pub sender: PublishedIdentity,
    pub sent_at_ms: u64,
}

pub struct SealedDelivery {
    pub payload: Vec<u8>,
    pub route_blob: Vec<u8>,
    pub(crate) offline_keys: Option<crate::offline_mailbox::MailboxKeys>,
}

pub fn seal_for_all(
    recipient: &PublishedIdentity,
    plaintext: &str,
) -> CoreResult<(Vec<SealedDelivery>, String)> {
    recipient.validate()?;
    let mut message_id = vec![0_u8; 16];
    OsRng.fill_bytes(&mut message_id);
    let id = compact_hex(&message_id);
    let mut deliveries = Vec::new();
    for device in recipient.delivery_devices()? {
        let (payload, _) = seal_for_device(&device, plaintext, message_id.clone())?;
        deliveries.push(SealedDelivery {
            payload,
            offline_keys: outgoing_mailbox_keys(&device)?,
            route_blob: device.route_blob,
        });
    }
    Ok((deliveries, id))
}

fn outgoing_mailbox_keys(
    recipient: &PublishedDevice,
) -> CoreResult<Option<crate::offline_mailbox::MailboxKeys>> {
    if !recipient
        .bundle
        .capabilities
        .iter()
        .any(|value| value == "offline-mailbox-v1")
    {
        return Ok(None);
    }
    let local = identity::active_identity()?;
    let device = ratchet_adapter::public_pre_key_bundle()?.ok_or(CoreError::FeatureUnavailable)?;
    let remote = recipient
        .bundle
        .signal_pre_key
        .as_ref()
        .ok_or(CoreError::UnsupportedVersion)?;
    crate::offline_mailbox::MailboxKeys::derive(
        &local.x25519_secret()?,
        &recipient.bundle.signed_prekey_x25519,
        &local.identity_public_key()?,
        &recipient.bundle.identity_ed25519,
        device.device_id,
        remote.device_id,
    )
    .map(Some)
}

pub fn seal_for(recipient: &PublishedIdentity, plaintext: &str) -> CoreResult<(Vec<u8>, String)> {
    let (mut deliveries, id) = seal_for_all(recipient, plaintext)?;
    let first = deliveries
        .drain(..)
        .next()
        .ok_or(CoreError::VerificationFailed)?;
    Ok((first.payload, id))
}

fn seal_for_device(
    recipient: &PublishedDevice,
    plaintext: &str,
    message_id: Vec<u8>,
) -> CoreResult<(Vec<u8>, String)> {
    seal_for_device_with_route(
        recipient,
        plaintext,
        message_id,
        crate::veilid_adapter::local_route_blob()?,
    )
}

fn seal_for_device_with_route(
    recipient: &PublishedDevice,
    plaintext: &str,
    message_id: Vec<u8>,
    route_blob: Vec<u8>,
) -> CoreResult<(Vec<u8>, String)> {
    recipient.bundle.validate()?;
    let plaintext = plaintext.trim();
    if plaintext.is_empty() || plaintext.len() > MAX_MESSAGE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let local = identity::active_identity()?;
    let signing_key = local.signing_key()?;
    let local_bundle = local.public_bundle(ratchet_adapter::public_pre_key_bundle()?)?;
    // Never disclose the owner/member write capability in a public identity.
    // Offline capabilities are derived per pair inside the native core and
    // must never be embedded in this publicly authenticated sender profile.
    let mailbox = None;
    let sender = PublishedIdentity::new(
        &signing_key,
        local_bundle.clone(),
        route_blob,
        crate::peer_identity::current_public_profile(),
        mailbox.clone(),
    )?;

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
    let signal_pre_key = recipient
        .bundle
        .signal_pre_key
        .as_ref()
        .ok_or(CoreError::UnsupportedVersion)?;
    let protected_plaintext = ratchet_adapter::encrypt_message(
        &recipient.bundle.identity_ed25519,
        signal_pre_key,
        plaintext.as_bytes(),
    )?;
    let ratchet_header = b"signal-libsignal-v1".to_vec();
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
            ratchet_header,
            attachment_refs: Vec::new(),
        },
        &protected_plaintext,
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
    let mut bytes = serde_json::to_vec(&packet).map_err(|_| CoreError::Internal)?;
    if bytes.len() > MAX_PACKET_BYTES && packet.sender.profile.avatar_base64.is_some() {
        // Prefer propagating the current avatar to existing contacts, but keep
        // message delivery available when route/envelope overhead is unusually
        // large and would cross Veilid's application-message ceiling.
        packet.sender = PublishedIdentity::new(
            &signing_key,
            local_bundle,
            packet.sender.route_blob.clone(),
            compact_sender_profile(packet.sender.profile.clone()),
            mailbox,
        )?;
        packet.signature.clear();
        packet.signature = signing_key
            .sign(&packet.signing_payload()?)
            .to_bytes()
            .to_vec();
        bytes = serde_json::to_vec(&packet).map_err(|_| CoreError::Internal)?;
    }
    if bytes.len() > MAX_PACKET_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let id = compact_hex(&packet.message_id);
    Ok((bytes, id))
}

fn compact_sender_profile(mut profile: PublicProfile) -> PublicProfile {
    // Fallback for packets whose route/envelope overhead leaves no room for the
    // compact avatar under Veilid's 32 KiB application-message ceiling.
    profile.avatar_base64 = None;
    profile
}

pub fn open(payload: &[u8]) -> CoreResult<OpenedPacket> {
    if payload.is_empty() || payload.len() > MAX_PACKET_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let packet: SecurePacket =
        serde_json::from_slice(payload).map_err(|_| CoreError::InvalidInput)?;
    packet.validate()?;
    let local = identity::active_identity()?;
    if packet.recipient_identity != local.identity_public_key()? {
        return Err(CoreError::AuthenticationFailed);
    }
    let ephemeral: [u8; 32] = packet
        .ephemeral_x25519
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidInput)?;
    let ciphertext = Ciphertext::try_from(packet.mlkem_ciphertext.as_slice())
        .map_err(|_| CoreError::InvalidInput)?;
    let transcript = transcript_hash(
        &packet.sender.bundle.identity_ed25519,
        &packet.recipient_identity,
        &packet.ephemeral_x25519,
        &packet.mlkem_ciphertext,
        &packet.message_id,
    );
    let mut protected_plaintext = None;
    for (secret, seed) in local.receiving_key_pairs()? {
        let classical = secret.diffie_hellman(&PublicKey::from(ephemeral));
        if !classical.was_contributory() {
            return Err(CoreError::VerificationFailed);
        }
        let decapsulation_key = <MlKem768 as Kem>::DecapsulationKey::from_seed(seed);
        let pq_shared = decapsulation_key.decapsulate(&ciphertext);
        let root_key = hybrid::derive_root_key(
            classical.as_bytes(),
            pq_shared.as_slice(),
            transcript.as_slice(),
        )?;
        if let Ok(plaintext) = envelope::open(&root_key, &packet.envelope) {
            protected_plaintext = Some(plaintext);
            break;
        }
    }
    let protected_plaintext = protected_plaintext.ok_or(CoreError::AuthenticationFailed)?;
    let (plaintext, pending_ratchet) = match packet.envelope.metadata.ratchet_header.as_slice() {
        b"signal-libsignal-v1" => ratchet_adapter::decrypt_message(
            &packet.sender.bundle.identity_ed25519,
            packet
                .sender
                .bundle
                .signal_pre_key
                .as_ref()
                .ok_or(CoreError::UnsupportedVersion)?
                .device_id,
            &protected_plaintext,
        )?,
        _ => return Err(CoreError::UnsupportedVersion),
    };
    let text = String::from_utf8(plaintext.to_vec()).map_err(|_| CoreError::InvalidInput)?;
    if text.is_empty() || text.len() > MAX_MESSAGE_BYTES {
        return Err(CoreError::InvalidInput);
    }
    Ok(OpenedPacket {
        message_id: compact_hex(&packet.message_id),
        sender: packet.sender,
        plaintext: text,
        sent_at_ms: packet.envelope.metadata.timestamp_logical,
        pending_ratchet: Some(pending_ratchet),
    })
}

pub fn inspect(payload: &[u8]) -> CoreResult<InspectedPacket> {
    if payload.is_empty() || payload.len() > MAX_PACKET_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let packet: SecurePacket =
        serde_json::from_slice(payload).map_err(|_| CoreError::InvalidInput)?;
    packet.validate()?;
    if packet.recipient_identity != identity::active_identity()?.identity_public_key()? {
        return Err(CoreError::AuthenticationFailed);
    }
    Ok(InspectedPacket {
        message_id: compact_hex(&packet.message_id),
        sender: packet.sender,
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

#[cfg(test)]
mod tests {
    use super::compact_sender_profile;
    use crate::peer_identity::PublicProfile;

    #[test]
    fn compact_sender_profile_keeps_name_but_omits_avatar() {
        let compact = compact_sender_profile(PublicProfile {
            display_name: Some("Sylphy User".to_owned()),
            avatar_base64: Some("aGVsbG8=".to_owned()),
        });

        assert_eq!(compact.display_name.as_deref(), Some("Sylphy User"));
        assert!(compact.avatar_base64.is_none());
    }

    #[cfg(feature = "signal-ratchet")]
    #[test]
    fn hybrid_offline_message_survives_restart_and_duplicate_delivery() {
        use super::*;
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "sylphy-offline-{}-{}",
            std::process::id(),
            current_time_ms().unwrap()
        ));
        let alice = directory.join("alice").to_string_lossy().into_owned();
        let bob = directory.join("bob").to_string_lossy().into_owned();
        identity::ensure_identity(&bob, "test-bob-vault", None, None).unwrap();
        let bob_record = identity::active_identity().unwrap();
        let bob_bundle = bob_record
            .public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
            .unwrap();
        let device = PublishedDevice {
            bundle: bob_bundle.clone(),
            route_blob: vec![1],
        };
        identity::ensure_identity(&alice, "test-alice-vault", None, None).unwrap();
        let alice_record = identity::active_identity().unwrap();
        let alice_bundle = alice_record
            .public_bundle(ratchet_adapter::public_pre_key_bundle().unwrap())
            .unwrap();
        let (packet, _) = seal_for_device_with_route(
            &device,
            "Messaggio mentre sei offline",
            vec![17; 16],
            vec![2],
        )
        .unwrap();
        let sender_keys = outgoing_mailbox_keys(&device).unwrap().unwrap();
        let (first, second) = sender_keys
            .seal(&packet, current_time_ms().unwrap())
            .unwrap();
        // Simulate an app restart: restore Bob's vault and libsignal state.
        identity::activate_from_storage(&bob, "test-bob-vault").unwrap();
        crate::messaging_adapter::configure_storage(&bob).unwrap();
        let receiver_keys = crate::offline_mailbox::MailboxKeys::derive(
            &bob_record.x25519_secret().unwrap(),
            &alice_bundle.signed_prekey_x25519,
            &alice_bundle.identity_ed25519,
            &bob_bundle.identity_ed25519,
            alice_bundle.signal_pre_key.as_ref().unwrap().device_id,
            bob_bundle.signal_pre_key.as_ref().unwrap().device_id,
        )
        .unwrap();
        let recovered = receiver_keys
            .open(&first, &second, current_time_ms().unwrap())
            .unwrap();
        crate::messaging_adapter::receive_for_test(&recovered).unwrap();
        crate::messaging_adapter::receive_for_test(&recovered).unwrap();
        let conversations = crate::messaging_adapter::list_conversations().unwrap();
        let id = conversations["conversations"][0]["id"].as_str().unwrap();
        let messages = crate::messaging_adapter::list_messages(id, None, None, None).unwrap();
        assert_eq!(messages["messages"].as_array().unwrap().len(), 1);
        assert_eq!(
            messages["messages"][0]["body"],
            "Messaggio mentre sei offline"
        );
        // Reload the log and ratchet, then replay the same network deposit.
        identity::activate_from_storage(&bob, "test-bob-vault").unwrap();
        crate::messaging_adapter::configure_storage(&bob).unwrap();
        crate::messaging_adapter::receive_for_test(&recovered).unwrap();
        assert_eq!(
            crate::messaging_adapter::list_messages(id, None, None, None).unwrap()["messages"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        std::fs::remove_dir_all(directory).unwrap();
    }
}
