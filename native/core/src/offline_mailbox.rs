//! Pair-scoped transport capabilities. These do not replace the hybrid E2EE
//! packet: the extra XChaCha layer hides its identities from DHT observers.
#![cfg_attr(not(feature = "veilid"), allow(dead_code))]
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

use crate::{
    error::{CoreError, CoreResult},
    vault,
};

pub(crate) const RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;
pub(crate) const SLOT_COUNT: u32 = 32;
pub(crate) const CHUNK_BYTES: usize = 24 * 1024;
const MAX_PACKET_BYTES: usize = 32 * 1024;
const HEADER_BYTES: usize = 48;
const MAX_FRAME_BYTES: usize = MAX_PACKET_BYTES + 41;

pub(crate) fn acknowledgement(payload: &[u8]) -> Vec<u8> {
    let mut value = b"SOA1".to_vec();
    value.extend_from_slice(&Sha256::digest(payload));
    value
}

pub(crate) fn acknowledges(value: &[u8], payload: &[u8]) -> bool {
    value == acknowledgement(payload)
}

// Serialized only inside the encrypted local outbox. Never put this in a
// public bundle, FFI response, diagnostics, or account contact invitation.
#[derive(Clone, Deserialize, Serialize)]
pub(crate) struct MailboxKeys {
    owner_seed: [u8; 32],
    wrapping_key: [u8; 32],
}

impl std::fmt::Debug for MailboxKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MailboxKeys([REDACTED])")
    }
}

impl Drop for MailboxKeys {
    fn drop(&mut self) {
        self.owner_seed.zeroize();
        self.wrapping_key.zeroize();
    }
}

impl MailboxKeys {
    pub(crate) fn derive(
        secret: &StaticSecret,
        remote_public: &[u8],
        sender_identity: &[u8],
        recipient_identity: &[u8],
        sender_device: u8,
        recipient_device: u8,
    ) -> CoreResult<Self> {
        let remote: [u8; 32] = remote_public
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?;
        if sender_identity.len() != 32
            || recipient_identity.len() != 32
            || sender_device == 0
            || recipient_device == 0
        {
            return Err(CoreError::InvalidInput);
        }
        let shared = secret.diffie_hellman(&PublicKey::from(remote));
        if !shared.was_contributory() {
            return Err(CoreError::VerificationFailed);
        }
        let mut context = Sha256::new();
        context.update(b"sylphy/offline-mailbox/v1");
        context.update(sender_identity);
        context.update(recipient_identity);
        context.update([sender_device, recipient_device]);
        let salt = context.finalize();
        let kdf = Hkdf::<Sha256>::new(Some(&salt), shared.as_bytes());
        let mut keys = Self {
            owner_seed: [0; 32],
            wrapping_key: [0; 32],
        };
        kdf.expand(b"dht-owner", &mut keys.owner_seed)
            .map_err(|_| CoreError::Internal)?;
        kdf.expand(b"packet-wrapper", &mut keys.wrapping_key)
            .map_err(|_| CoreError::Internal)?;
        Ok(keys)
    }

    #[cfg(feature = "veilid")]
    pub(crate) fn owner(&self) -> veilid_core::KeyPair {
        use veilid_core::{BareKeyPair, BarePublicKey, BareSecretKey, CRYPTO_KIND_VLD0, KeyPair};
        let signing = ed25519_dalek::SigningKey::from_bytes(&self.owner_seed);
        KeyPair::new(
            CRYPTO_KIND_VLD0,
            BareKeyPair::new(
                BarePublicKey::new(&signing.verifying_key().to_bytes()),
                BareSecretKey::new(&self.owner_seed),
            ),
        )
    }

    pub(crate) fn id(&self) -> [u8; 32] {
        Sha256::digest(self.owner_seed).into()
    }

    pub(crate) fn seal(&self, payload: &[u8], now_ms: u64) -> CoreResult<(Vec<u8>, Vec<u8>)> {
        if payload.is_empty() || payload.len() > MAX_PACKET_BYTES {
            return Err(CoreError::LimitExceeded);
        }
        let encrypted = vault::seal_with_key(&self.wrapping_key, payload)?;
        let mut first = Vec::with_capacity(HEADER_BYTES + CHUNK_BYTES);
        first.extend_from_slice(b"SOM1");
        first.extend_from_slice(&now_ms.to_be_bytes());
        first.extend_from_slice(&(encrypted.len() as u32).to_be_bytes());
        first.extend_from_slice(&Sha256::digest(&encrypted));
        first.extend_from_slice(&encrypted[..encrypted.len().min(CHUNK_BYTES)]);
        let second = encrypted.get(CHUNK_BYTES..).unwrap_or_default().to_vec();
        Ok((first, second))
    }

    pub(crate) fn open(
        &self,
        first: &[u8],
        second: &[u8],
        now_ms: u64,
    ) -> CoreResult<Zeroizing<Vec<u8>>> {
        let length = frame_length(first, now_ms)?;
        if second.len() != length.saturating_sub(CHUNK_BYTES) {
            return Err(CoreError::VerificationFailed);
        }
        let mut encrypted = first[HEADER_BYTES..].to_vec();
        encrypted.extend_from_slice(second);
        if Sha256::digest(&encrypted).as_slice() != &first[16..48] {
            return Err(CoreError::VerificationFailed);
        }
        vault::open_with_key(&self.wrapping_key, &encrypted)
    }
}

pub(crate) fn frame_length(first: &[u8], now_ms: u64) -> CoreResult<usize> {
    if first.len() < HEADER_BYTES || &first[..4] != b"SOM1" {
        return Err(CoreError::InvalidInput);
    }
    let created = u64::from_be_bytes(
        first[4..12]
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?,
    );
    let length = u32::from_be_bytes(
        first[12..16]
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?,
    ) as usize;
    if created > now_ms.saturating_add(5 * 60 * 1000)
        || now_ms >= created.saturating_add(RETENTION_MS)
        || !(42..=MAX_FRAME_BYTES).contains(&length)
        || first.len() != HEADER_BYTES + length.min(CHUNK_BYTES)
    {
        return Err(CoreError::VerificationFailed);
    }
    Ok(length)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (MailboxKeys, MailboxKeys) {
        let a = StaticSecret::from([7; 32]);
        let b = StaticSecret::from([9; 32]);
        (
            MailboxKeys::derive(&a, PublicKey::from(&b).as_bytes(), &[1; 32], &[2; 32], 1, 2)
                .unwrap(),
            MailboxKeys::derive(&b, PublicKey::from(&a).as_bytes(), &[1; 32], &[2; 32], 1, 2)
                .unwrap(),
        )
    }

    #[test]
    fn offline_round_trip_including_maximum_packet_and_restart() {
        let (sender, receiver) = pair();
        let restored: MailboxKeys =
            serde_json::from_slice(&serde_json::to_vec(&sender).unwrap()).unwrap();
        assert_eq!(restored.id(), receiver.id());
        for size in [1, CHUNK_BYTES, MAX_PACKET_BYTES] {
            let payload = vec![23; size];
            let (first, second) = restored.seal(&payload, 1000).unwrap();
            assert!(first.len() <= 32768 && second.len() <= 32768);
            assert_eq!(
                &*receiver
                    .open(&first, &second, 1000 + RETENTION_MS - 1)
                    .unwrap(),
                &payload
            );
            assert!(receiver.open(&first, &second, 1000 + RETENTION_MS).is_err());
        }
    }

    #[test]
    fn rejects_tampering_partial_writes_and_wrong_peer() {
        let (sender, receiver) = pair();
        let (first, mut second) = sender.seal(&vec![4; MAX_PACKET_BYTES], 1000).unwrap();
        assert!(receiver.open(&first, &[], 1000).is_err());
        second[0] ^= 1;
        assert!(receiver.open(&first, &second, 1000).is_err());
        let other = MailboxKeys::derive(
            &StaticSecret::from([10; 32]),
            &[11; 32],
            &[1; 32],
            &[3; 32],
            1,
            2,
        )
        .unwrap();
        assert_ne!(other.id(), sender.id());
        let (first, second) = sender.seal(b"private", 1000).unwrap();
        assert!(other.open(&first, &second, 1000).is_err());
        assert!(!first.windows(7).any(|part| part == b"private"));
    }

    #[test]
    fn separates_directions_devices_and_rejects_low_order_keys() {
        let secret = StaticSecret::from([7; 32]);
        let remote = PublicKey::from(&StaticSecret::from([9; 32]));
        let keys =
            MailboxKeys::derive(&secret, remote.as_bytes(), &[1; 32], &[2; 32], 1, 2).unwrap();
        for (sender, recipient, device) in [([2; 32], [1; 32], 1), ([1; 32], [2; 32], 3)] {
            assert_ne!(
                keys.id(),
                MailboxKeys::derive(&secret, remote.as_bytes(), &sender, &recipient, device, 2)
                    .unwrap()
                    .id()
            );
        }
        assert!(MailboxKeys::derive(&secret, &[0; 32], &[1; 32], &[2; 32], 1, 2).is_err());
        assert!(frame_length(&[0; 47], 1000).is_err());
    }

    #[test]
    fn acknowledgement_cannot_free_a_reused_slot() {
        let (sender, _) = pair();
        let (first, _) = sender.seal(b"old message", 1000).unwrap();
        let receipt = acknowledgement(&first);
        assert!(acknowledges(&receipt, &first));
        let (replacement, _) = sender.seal(b"next message", 1001).unwrap();
        assert!(!acknowledges(&receipt, &replacement));
        assert!(frame_length(&receipt, 1001).is_err());
    }
}
