use serde::{Deserialize, Serialize};

use crate::error::{CoreError, CoreResult};

#[derive(Debug, Clone, Serialize)]
pub struct RatchetCapabilityStatus {
    pub compiled: bool,
    pub provider: &'static str,
    pub algorithm: &'static str,
    pub persistence: &'static str,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RatchetMessageKind {
    Signal,
    PreKey,
}

/// Network-safe representation of a libsignal ciphertext.
///
/// Only these opaque bytes may be handed to the Veilid adapter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RatchetWireMessage {
    pub kind: RatchetMessageKind,
    pub body_base64: String,
}

pub fn capability_status() -> RatchetCapabilityStatus {
    RatchetCapabilityStatus {
        compiled: cfg!(feature = "signal-ratchet"),
        provider: if cfg!(feature = "signal-ratchet") {
            "signalapp/libsignal@v0.99.3"
        } else {
            "not-compiled"
        },
        algorithm: "double-ratchet-with-pq-ratchet",
        persistence: "vault-required-before-ui-send",
    }
}

#[cfg(feature = "signal-ratchet")]
mod signal {
    use std::time::SystemTime;

    use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
    use libsignal_protocol::{
        CiphertextMessage, DeviceId, GenericSignedPreKey, IdentityKeyPair,
        InMemSignalProtocolStore, KeyPair, KyberPreKeyRecord, PreKeyBundle, PreKeyRecord,
        PreKeySignalMessage, ProtocolAddress, ProtocolStore, SignalMessage, SignedPreKeyRecord,
        Timestamp, kem, message_decrypt, message_encrypt, process_prekey_bundle,
    };
    use rand::rngs::OsRng;
    use rand::{CryptoRng, Rng, TryRngCore as _};

    use super::{CoreError, CoreResult, RatchetMessageKind, RatchetWireMessage};

    const MAX_RATCHET_MESSAGE_BYTES: usize = 32 * 1024;

    impl RatchetWireMessage {
        pub fn from_ciphertext(message: &CiphertextMessage) -> CoreResult<Self> {
            if message.serialize().len() > MAX_RATCHET_MESSAGE_BYTES {
                return Err(CoreError::LimitExceeded);
            }
            let kind = match message {
                CiphertextMessage::SignalMessage(_) => RatchetMessageKind::Signal,
                CiphertextMessage::PreKeySignalMessage(_) => RatchetMessageKind::PreKey,
                _ => return Err(CoreError::InvalidInput),
            };
            Ok(Self {
                kind,
                body_base64: STANDARD_NO_PAD.encode(message.serialize()),
            })
        }

        pub fn to_ciphertext(&self) -> CoreResult<CiphertextMessage> {
            if self.body_base64.len() > (MAX_RATCHET_MESSAGE_BYTES * 4 / 3) + 4 {
                return Err(CoreError::LimitExceeded);
            }
            let body = STANDARD_NO_PAD
                .decode(&self.body_base64)
                .map_err(|_| CoreError::InvalidInput)?;
            if body.len() > MAX_RATCHET_MESSAGE_BYTES {
                return Err(CoreError::LimitExceeded);
            }
            match self.kind {
                RatchetMessageKind::Signal => protocol_error(
                    SignalMessage::try_from(body.as_slice()).map(CiphertextMessage::SignalMessage),
                ),
                RatchetMessageKind::PreKey => protocol_error(
                    PreKeySignalMessage::try_from(body.as_slice())
                        .map(CiphertextMessage::PreKeySignalMessage),
                ),
            }
        }
    }

    fn protocol_error<T>(
        result: Result<T, libsignal_protocol::SignalProtocolError>,
    ) -> CoreResult<T> {
        result.map_err(|_| CoreError::VerificationFailed)
    }

    /// Owns all mutable Signal protocol stores for one local device.
    ///
    /// This type intentionally remains in the native boundary: plaintext, chain keys and
    /// skipped-message keys must never be exposed to Dart or Veilid.
    pub struct SignalRatchetAccount {
        address: ProtocolAddress,
        store: InMemSignalProtocolStore,
    }

    impl SignalRatchetAccount {
        pub fn new(profile_id: &str, device_id: DeviceId) -> CoreResult<Self> {
            if profile_id.is_empty() || profile_id.len() > 128 {
                return Err(CoreError::InvalidInput);
            }

            let mut csprng = OsRng.unwrap_err();
            let identity_key = IdentityKeyPair::generate(&mut csprng);
            let registration_id: u8 = csprng.random();
            let store = protocol_error(InMemSignalProtocolStore::new(
                identity_key,
                u32::from(registration_id),
            ))?;

            Ok(Self {
                address: ProtocolAddress::new(profile_id.to_owned(), device_id),
                store,
            })
        }

        pub fn address(&self) -> &ProtocolAddress {
            &self.address
        }

        pub async fn create_pre_key_bundle(&mut self) -> CoreResult<PreKeyBundle> {
            let mut csprng = OsRng.unwrap_err();
            protocol_error(
                create_pre_key_bundle(&mut self.store, self.address.device_id(), &mut csprng).await,
            )
        }

        pub async fn establish_outbound_session(
            &mut self,
            remote_address: &ProtocolAddress,
            bundle: &PreKeyBundle,
        ) -> CoreResult<()> {
            let mut csprng = OsRng.unwrap_err();
            protocol_error(
                process_prekey_bundle(
                    remote_address,
                    &self.address,
                    &mut self.store.session_store,
                    &mut self.store.identity_store,
                    bundle,
                    SystemTime::now(),
                    &mut csprng,
                )
                .await,
            )
        }

        pub async fn encrypt(
            &mut self,
            remote_address: &ProtocolAddress,
            plaintext: &[u8],
        ) -> CoreResult<CiphertextMessage> {
            let mut csprng = OsRng.unwrap_err();
            protocol_error(
                message_encrypt(
                    plaintext,
                    remote_address,
                    &self.address,
                    &mut self.store.session_store,
                    &mut self.store.identity_store,
                    SystemTime::now(),
                    &mut csprng,
                )
                .await,
            )
        }

        pub async fn decrypt(
            &mut self,
            remote_address: &ProtocolAddress,
            ciphertext: &CiphertextMessage,
        ) -> CoreResult<Vec<u8>> {
            let mut csprng = OsRng.unwrap_err();
            protocol_error(
                message_decrypt(
                    ciphertext,
                    remote_address,
                    &self.address,
                    &mut self.store.session_store,
                    &mut self.store.identity_store,
                    &mut self.store.pre_key_store,
                    &self.store.signed_pre_key_store,
                    &mut self.store.kyber_pre_key_store,
                    &mut csprng,
                )
                .await,
            )
        }
    }

    async fn create_pre_key_bundle<R: Rng + CryptoRng>(
        store: &mut dyn ProtocolStore,
        device_id: DeviceId,
        mut csprng: &mut R,
    ) -> Result<PreKeyBundle, libsignal_protocol::SignalProtocolError> {
        let pre_key_pair = KeyPair::generate(&mut csprng);
        let signed_pre_key_pair = KeyPair::generate(&mut csprng);
        let kyber_pre_key_pair = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut csprng);

        let signed_pre_key_public = signed_pre_key_pair.public_key.serialize();
        let signed_pre_key_signature = store
            .get_identity_key_pair()
            .await?
            .private_key()
            .calculate_signature(&signed_pre_key_public, &mut csprng)?;

        let kyber_pre_key_public = kyber_pre_key_pair.public_key.serialize();
        let kyber_pre_key_signature = store
            .get_identity_key_pair()
            .await?
            .private_key()
            .calculate_signature(&kyber_pre_key_public, &mut csprng)?;

        let pre_key_id: u32 = csprng.random();
        let signed_pre_key_id: u32 = csprng.random();
        let kyber_pre_key_id: u32 = csprng.random();

        let bundle = PreKeyBundle::new(
            store.get_local_registration_id().await?,
            device_id,
            Some((pre_key_id.into(), pre_key_pair.public_key)),
            signed_pre_key_id.into(),
            signed_pre_key_pair.public_key,
            signed_pre_key_signature.to_vec(),
            kyber_pre_key_id.into(),
            kyber_pre_key_pair.public_key.clone(),
            kyber_pre_key_signature.to_vec(),
            *store.get_identity_key_pair().await?.identity_key(),
        )?;

        store
            .save_pre_key(
                pre_key_id.into(),
                &PreKeyRecord::new(pre_key_id.into(), &pre_key_pair),
            )
            .await?;
        store
            .save_signed_pre_key(
                signed_pre_key_id.into(),
                &SignedPreKeyRecord::new(
                    signed_pre_key_id.into(),
                    Timestamp::from_epoch_millis(csprng.random()),
                    &signed_pre_key_pair,
                    &signed_pre_key_signature,
                ),
            )
            .await?;
        store
            .save_kyber_pre_key(
                kyber_pre_key_id.into(),
                &KyberPreKeyRecord::new(
                    kyber_pre_key_id.into(),
                    Timestamp::from_epoch_millis(csprng.random()),
                    &kyber_pre_key_pair,
                    &kyber_pre_key_signature,
                ),
            )
            .await?;

        Ok(bundle)
    }

    pub fn self_test() -> CoreResult<()> {
        futures_executor::block_on(async {
            let alice_device = DeviceId::new(1).expect("non-zero static device id");
            let bob_device = DeviceId::new(1).expect("non-zero static device id");
            let mut alice = SignalRatchetAccount::new("alice", alice_device)?;
            let mut bob = SignalRatchetAccount::new("bob", bob_device)?;

            let bob_bundle = bob.create_pre_key_bundle().await?;
            alice
                .establish_outbound_session(bob.address(), &bob_bundle)
                .await?;

            let first = alice.encrypt(bob.address(), b"bootstrap").await?;
            let first_wire = RatchetWireMessage::from_ciphertext(&first)?;
            let first_from_network = first_wire.to_ciphertext()?;
            let first_plaintext = bob.decrypt(alice.address(), &first_from_network).await?;
            if first_plaintext != b"bootstrap" {
                return Err(CoreError::VerificationFailed);
            }
            if bob
                .decrypt(alice.address(), &first_from_network)
                .await
                .is_ok()
            {
                return Err(CoreError::VerificationFailed);
            }

            // Bob's response acknowledges the pre-key session and exercises the DH ratchet.
            let acknowledgement = bob.encrypt(alice.address(), b"ack").await?;
            let acknowledgement_plaintext = alice.decrypt(bob.address(), &acknowledgement).await?;
            if acknowledgement_plaintext != b"ack" {
                return Err(CoreError::VerificationFailed);
            }

            let mut messages = Vec::new();
            for plaintext in [b"one".as_slice(), b"two".as_slice(), b"three".as_slice()] {
                messages.push(Some(alice.encrypt(bob.address(), plaintext).await?));
            }

            // Delivery 3, 1, 2 validates skipped-message key handling.
            for (index, expected) in [(2_usize, b"three".as_slice()), (0, b"one"), (1, b"two")] {
                let message = messages[index]
                    .take()
                    .ok_or(CoreError::VerificationFailed)?;
                let plaintext = bob.decrypt(alice.address(), &message).await?;
                if plaintext != expected {
                    return Err(CoreError::VerificationFailed);
                }
            }

            Ok(())
        })
    }
}

#[cfg(feature = "signal-ratchet")]
pub use signal::SignalRatchetAccount;

#[cfg(feature = "signal-ratchet")]
pub fn self_test() -> CoreResult<()> {
    signal::self_test()
}

#[cfg(not(feature = "signal-ratchet"))]
pub fn self_test() -> CoreResult<()> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_matches_feature() {
        assert_eq!(
            capability_status().compiled,
            cfg!(feature = "signal-ratchet")
        );
    }

    #[cfg(feature = "signal-ratchet")]
    #[test]
    fn ratchet_round_trip_and_out_of_order_delivery() {
        self_test().expect("Signal Double Ratchet self-test");
    }
}
