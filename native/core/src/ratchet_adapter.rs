use serde::Serialize;

use crate::{
    bundle::SignalPreKeyBundle,
    error::{CoreError, CoreResult},
};

#[derive(Debug, Clone, Serialize)]
pub struct RatchetCapabilityStatus {
    pub compiled: bool,
    pub provider: &'static str,
    pub algorithm: &'static str,
    pub persistence: &'static str,
}

pub fn capability_status() -> RatchetCapabilityStatus {
    RatchetCapabilityStatus {
        compiled: cfg!(feature = "signal-ratchet"),
        provider: if cfg!(feature = "signal-ratchet") {
            "signalapp/libsignal@v0.106.0"
        } else {
            "not-compiled"
        },
        algorithm: "signal-double-ratchet-with-pq-prekeys",
        persistence: "encrypted-per-session-v2",
    }
}

#[cfg(feature = "signal-ratchet")]
mod signal {
    use std::{
        collections::{HashMap, HashSet},
        fs,
        path::PathBuf,
        sync::{Mutex, OnceLock},
        time::{SystemTime, UNIX_EPOCH},
    };

    use async_trait::async_trait;
    use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
    use libsignal_protocol::{
        CiphertextMessage, DeviceId, Direction, GenericSignedPreKey, IdentityChange, IdentityKey,
        IdentityKeyPair, IdentityKeyStore, KeyPair, KyberPreKeyId, KyberPreKeyRecord,
        KyberPreKeyStore, PreKeyBundle, PreKeyId, PreKeyRecord, PreKeySignalMessage, PreKeyStore,
        ProtocolAddress, PublicKey, SessionStore, SessionUsabilityRequirements, SignalMessage,
        SignalProtocolError, SignedPreKeyId, SignedPreKeyRecord, SignedPreKeyStore, Timestamp, kem,
        message_decrypt, message_encrypt, process_prekey_bundle,
    };
    use rand::{Rng as _, TryRngCore as _, rngs::OsRng};
    use serde::{Deserialize, Serialize};
    use sha2::{Digest, Sha256};
    use zeroize::{Zeroize, Zeroizing};

    use super::{CoreError, CoreResult, SignalPreKeyBundle};
    use crate::{atomic_file, bundle::MAX_SIGNAL_DEVICE_ID, identity, vault};

    const STORE_VERSION: u8 = 2;
    const STORE_FILE: &str = "signal-account-v2.vault";
    const SESSION_DIRECTORY: &str = "signal-sessions-v2";
    const LEGACY_DEVICE_ID: u8 = 1;

    const fn legacy_device_id() -> u8 {
        LEGACY_DEVICE_ID
    }
    const SIGNED_PRE_KEY_ID: u32 = 1;
    const KYBER_PRE_KEY_ID: u32 = 1;
    const MAX_WIRE_BYTES: usize = 32 * 1024;
    const MAX_SESSIONS: usize = 2_048;
    const MAX_GLOBAL_STORE_BYTES: usize = 8 * 1024 * 1024;
    const MAX_SESSION_STORE_BYTES: usize = 1024 * 1024;
    const TRANSACTION_FILE: &str = "signal-transaction-v1.vault";
    const MAX_TRANSACTION_BYTES: usize =
        4 * (MAX_GLOBAL_STORE_BYTES + MAX_SESSION_STORE_BYTES) + 1024;

    #[derive(Deserialize, Serialize)]
    #[serde(deny_unknown_fields)]
    struct StoreTransaction {
        version: u8,
        session_file: String,
        session: Vec<u8>,
        global: Option<Vec<u8>>,
    }

    #[derive(Debug, Clone, Copy, Deserialize, Serialize)]
    #[serde(rename_all = "snake_case")]
    enum WireKind {
        Signal,
        PreKey,
    }

    #[derive(Clone, Debug, Deserialize, Serialize)]
    struct WireMessage {
        version: u8,
        kind: WireKind,
        body_base64: String,
    }

    impl WireMessage {
        fn from_ciphertext(message: &CiphertextMessage) -> CoreResult<Self> {
            let body = message.serialize();
            if body.is_empty() || body.len() > MAX_WIRE_BYTES {
                return Err(CoreError::LimitExceeded);
            }
            let kind = match message {
                CiphertextMessage::SignalMessage(_) => WireKind::Signal,
                CiphertextMessage::PreKeySignalMessage(_) => WireKind::PreKey,
                _ => return Err(CoreError::InvalidInput),
            };
            Ok(Self {
                version: 1,
                kind,
                body_base64: STANDARD_NO_PAD.encode(body),
            })
        }

        fn into_ciphertext(self) -> CoreResult<CiphertextMessage> {
            if self.version != 1 || self.body_base64.len() > (MAX_WIRE_BYTES * 4 / 3) + 8 {
                return Err(CoreError::InvalidInput);
            }
            let body = STANDARD_NO_PAD
                .decode(self.body_base64)
                .map_err(|_| CoreError::InvalidInput)?;
            if body.is_empty() || body.len() > MAX_WIRE_BYTES {
                return Err(CoreError::LimitExceeded);
            }
            protocol(match self.kind {
                WireKind::Signal => {
                    SignalMessage::try_from(body.as_slice()).map(CiphertextMessage::SignalMessage)
                }
                WireKind::PreKey => PreKeySignalMessage::try_from(body.as_slice())
                    .map(CiphertextMessage::PreKeySignalMessage),
            })
        }
    }

    #[derive(Clone, Default, Deserialize, Serialize)]
    struct PersistentIdentityStore {
        key_pair: Vec<u8>,
        registration_id: u32,
        known_keys: HashMap<String, Vec<u8>>,
    }

    #[async_trait(?Send)]
    impl IdentityKeyStore for PersistentIdentityStore {
        async fn get_identity_key_pair(&self) -> Result<IdentityKeyPair, SignalProtocolError> {
            IdentityKeyPair::try_from(self.key_pair.as_slice())
        }

        async fn get_local_registration_id(&self) -> Result<u32, SignalProtocolError> {
            Ok(self.registration_id)
        }

        async fn save_identity(
            &mut self,
            address: &ProtocolAddress,
            identity: &IdentityKey,
        ) -> Result<IdentityChange, SignalProtocolError> {
            let key = address_key(address);
            let encoded = identity.serialize().to_vec();
            let changed = self
                .known_keys
                .insert(key, encoded.clone())
                .is_some_and(|previous| previous != encoded);
            Ok(IdentityChange::from_changed(changed))
        }

        async fn is_trusted_identity(
            &self,
            address: &ProtocolAddress,
            identity: &IdentityKey,
            _direction: Direction,
        ) -> Result<bool, SignalProtocolError> {
            Ok(self
                .known_keys
                .get(&address_key(address))
                .is_none_or(|known| known.as_slice() == identity.serialize().as_ref()))
        }

        async fn get_identity(
            &self,
            address: &ProtocolAddress,
        ) -> Result<Option<IdentityKey>, SignalProtocolError> {
            self.known_keys
                .get(&address_key(address))
                .map(|encoded| IdentityKey::decode(encoded))
                .transpose()
        }
    }

    #[derive(Clone, Default, Deserialize, Serialize)]
    struct PersistentPreKeyStore {
        records: HashMap<u32, Vec<u8>>,
    }

    #[async_trait(?Send)]
    impl PreKeyStore for PersistentPreKeyStore {
        async fn get_pre_key(&self, id: PreKeyId) -> Result<PreKeyRecord, SignalProtocolError> {
            PreKeyRecord::deserialize(
                self.records
                    .get(&u32::from(id))
                    .ok_or(SignalProtocolError::InvalidPreKeyId)?,
            )
        }

        async fn save_pre_key(
            &mut self,
            id: PreKeyId,
            record: &PreKeyRecord,
        ) -> Result<(), SignalProtocolError> {
            self.records.insert(u32::from(id), record.serialize()?);
            Ok(())
        }

        async fn remove_pre_key(&mut self, id: PreKeyId) -> Result<(), SignalProtocolError> {
            self.records.remove(&u32::from(id));
            Ok(())
        }
    }

    #[derive(Clone, Default, Deserialize, Serialize)]
    struct PersistentSignedPreKeyStore {
        records: HashMap<u32, Vec<u8>>,
    }

    #[async_trait(?Send)]
    impl SignedPreKeyStore for PersistentSignedPreKeyStore {
        async fn get_signed_pre_key(
            &self,
            id: SignedPreKeyId,
        ) -> Result<SignedPreKeyRecord, SignalProtocolError> {
            SignedPreKeyRecord::deserialize(
                self.records
                    .get(&u32::from(id))
                    .ok_or(SignalProtocolError::InvalidSignedPreKeyId)?,
            )
        }

        async fn save_signed_pre_key(
            &mut self,
            id: SignedPreKeyId,
            record: &SignedPreKeyRecord,
        ) -> Result<(), SignalProtocolError> {
            self.records.insert(u32::from(id), record.serialize()?);
            Ok(())
        }
    }

    #[derive(Clone, Default, Deserialize, Serialize)]
    struct PersistentKyberPreKeyStore {
        records: HashMap<u32, Vec<u8>>,
        used_base_keys: HashMap<String, Vec<Vec<u8>>>,
    }

    #[async_trait(?Send)]
    impl KyberPreKeyStore for PersistentKyberPreKeyStore {
        async fn get_kyber_pre_key(
            &self,
            id: KyberPreKeyId,
        ) -> Result<KyberPreKeyRecord, SignalProtocolError> {
            KyberPreKeyRecord::deserialize(
                self.records
                    .get(&u32::from(id))
                    .ok_or(SignalProtocolError::InvalidKyberPreKeyId)?,
            )
        }

        async fn save_kyber_pre_key(
            &mut self,
            id: KyberPreKeyId,
            record: &KyberPreKeyRecord,
        ) -> Result<(), SignalProtocolError> {
            self.records.insert(u32::from(id), record.serialize()?);
            Ok(())
        }

        async fn mark_kyber_pre_key_used(
            &mut self,
            kyber_id: KyberPreKeyId,
            signed_id: SignedPreKeyId,
            base_key: &PublicKey,
        ) -> Result<(), SignalProtocolError> {
            let key = format!("{}:{}", u32::from(kyber_id), u32::from(signed_id));
            let encoded = base_key.serialize().to_vec();
            let seen = self.used_base_keys.entry(key).or_default();
            if seen.contains(&encoded) {
                return Err(SignalProtocolError::InvalidMessage(
                    libsignal_protocol::CiphertextMessageType::PreKey,
                    "reused base key".to_owned(),
                ));
            }
            if seen.len() >= MAX_SESSIONS {
                return Err(SignalProtocolError::InvalidMessage(
                    libsignal_protocol::CiphertextMessageType::PreKey,
                    "too many pre-key sessions".to_owned(),
                ));
            }
            seen.push(encoded);
            Ok(())
        }
    }

    #[derive(Clone, Default)]
    struct PersistentSessionStore {
        records: HashMap<String, Vec<u8>>,
    }

    #[async_trait(?Send)]
    impl SessionStore for PersistentSessionStore {
        async fn load_session(
            &self,
            address: &ProtocolAddress,
        ) -> Result<Option<libsignal_protocol::SessionRecord>, SignalProtocolError> {
            self.records
                .get(&address_key(address))
                .map(|encoded| libsignal_protocol::SessionRecord::deserialize(encoded))
                .transpose()
        }

        async fn store_session(
            &mut self,
            address: &ProtocolAddress,
            record: &libsignal_protocol::SessionRecord,
        ) -> Result<(), SignalProtocolError> {
            self.records
                .insert(address_key(address), record.serialize()?);
            Ok(())
        }
    }

    #[derive(Clone, Deserialize, Serialize)]
    struct GlobalStore {
        version: u8,
        #[serde(default = "legacy_device_id")]
        device_id: u8,
        identity: PersistentIdentityStore,
        pre_keys: PersistentPreKeyStore,
        signed_pre_keys: PersistentSignedPreKeyStore,
        kyber_pre_keys: PersistentKyberPreKeyStore,
    }

    #[derive(Clone, Default)]
    struct RuntimeStore {
        root: Option<PathBuf>,
        loaded: bool,
        global: Option<GlobalStore>,
        sessions: PersistentSessionStore,
        loaded_sessions: HashSet<String>,
        session_file_count: usize,
    }

    pub struct PendingDecrypt {
        before: Option<RuntimeStore>,
        address: ProtocolAddress,
        is_pre_key: bool,
    }

    impl PendingDecrypt {
        pub fn commit(mut self) -> CoreResult<()> {
            let mut runtime = store().lock().map_err(|_| CoreError::Internal)?;
            let identity_changed = self
                .before
                .as_ref()
                .and_then(|before| before.global.as_ref())
                .map(|global| &global.identity.known_keys)
                != runtime
                    .global
                    .as_ref()
                    .map(|global| &global.identity.known_keys);
            let result = persist_transaction(
                &mut runtime,
                &self.address,
                self.is_pre_key || identity_changed,
            );
            if result.is_ok() {
                self.before = None;
            }
            result
        }
    }

    impl Drop for PendingDecrypt {
        fn drop(&mut self) {
            let Some(before) = self.before.take() else {
                return;
            };
            if let Ok(mut runtime) = store().lock() {
                *runtime = before;
            }
        }
    }

    static STORE: OnceLock<Mutex<RuntimeStore>> = OnceLock::new();

    fn store() -> &'static Mutex<RuntimeStore> {
        STORE.get_or_init(|| Mutex::new(RuntimeStore::default()))
    }

    pub fn wipe_memory() -> CoreResult<()> {
        let mut runtime = store().lock().map_err(|_| CoreError::Internal)?;
        if let Some(global) = &mut runtime.global {
            global.identity.key_pair.zeroize();
            for value in global.identity.known_keys.values_mut() {
                value.zeroize();
            }
            for value in global.pre_keys.records.values_mut() {
                value.zeroize();
            }
            for value in global.signed_pre_keys.records.values_mut() {
                value.zeroize();
            }
            for value in global.kyber_pre_keys.records.values_mut() {
                value.zeroize();
            }
            for values in global.kyber_pre_keys.used_base_keys.values_mut() {
                for value in values {
                    value.zeroize();
                }
            }
        }
        for value in runtime.sessions.records.values_mut() {
            value.zeroize();
        }
        *runtime = RuntimeStore::default();
        Ok(())
    }

    pub fn configure(storage_directory: &str) -> CoreResult<()> {
        if storage_directory.trim().is_empty() || storage_directory.len() > 4096 {
            return Err(CoreError::InvalidInput);
        }
        let root = PathBuf::from(storage_directory).join("messaging");
        let session_directory = root.join(SESSION_DIRECTORY);
        fs::create_dir_all(&session_directory).map_err(|_| CoreError::Internal)?;
        let session_file_count = fs::read_dir(&session_directory)
            .map_err(|_| CoreError::Internal)?
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .path()
                    .extension()
                    .is_some_and(|value| value == "vault")
            })
            .take(MAX_SESSIONS + 1)
            .count();
        if session_file_count > MAX_SESSIONS {
            return Err(CoreError::LimitExceeded);
        }
        let mut value = store().lock().map_err(|_| CoreError::Internal)?;
        value.root = Some(root);
        value.loaded = false;
        value.global = None;
        value.sessions = PersistentSessionStore::default();
        value.loaded_sessions.clear();
        value.session_file_count = session_file_count;
        Ok(())
    }

    pub fn validate_account_backup(value: &serde_json::Value) -> CoreResult<()> {
        let version = value.get("version").and_then(serde_json::Value::as_u64);
        let global = value.get("global").and_then(serde_json::Value::as_str);
        let sessions = value.get("sessions").and_then(serde_json::Value::as_object);
        if version != Some(1) || global.is_none() || sessions.is_none() {
            return Err(CoreError::VerificationFailed);
        }
        let global_bytes = STANDARD_NO_PAD
            .decode(global.unwrap_or_default())
            .map_err(|_| CoreError::VerificationFailed)?;
        if global_bytes.len() > MAX_GLOBAL_STORE_BYTES {
            return Err(CoreError::LimitExceeded);
        }
        let sessions = sessions.ok_or(CoreError::VerificationFailed)?;
        if sessions.len() > MAX_SESSIONS {
            return Err(CoreError::LimitExceeded);
        }
        for (name, encoded) in sessions {
            if name.len() != 70
                || !name.ends_with(".vault")
                || !name[..64].chars().all(|value| value.is_ascii_hexdigit())
            {
                return Err(CoreError::VerificationFailed);
            }
            let bytes = STANDARD_NO_PAD
                .decode(encoded.as_str().ok_or(CoreError::VerificationFailed)?)
                .map_err(|_| CoreError::VerificationFailed)?;
            if bytes.is_empty() || bytes.len() > MAX_SESSION_STORE_BYTES {
                return Err(CoreError::LimitExceeded);
            }
        }
        Ok(())
    }

    pub fn public_pre_key_bundle() -> CoreResult<SignalPreKeyBundle> {
        let mut runtime = store().lock().map_err(|_| CoreError::Internal)?;
        ensure_loaded(&mut runtime)?;
        public_bundle(runtime.global.as_ref().ok_or(CoreError::Internal)?)
    }

    pub fn avoid_device_id_collisions(reserved: &[(u8, Vec<u8>)]) -> CoreResult<bool> {
        let mut runtime = store().lock().map_err(|_| CoreError::Internal)?;
        ensure_loaded(&mut runtime)?;
        let global = runtime.global.as_ref().ok_or(CoreError::Internal)?;
        let current = public_bundle(global)?;
        let collision = reserved.iter().any(|(device_id, identity_key)| {
            *device_id == current.device_id && *identity_key != current.identity_key
        });
        if !collision {
            return Ok(false);
        }
        if runtime.session_file_count != 0 || !runtime.sessions.records.is_empty() {
            return Err(CoreError::VerificationFailed);
        }
        let used = reserved
            .iter()
            .map(|(device_id, _)| *device_id)
            .collect::<HashSet<_>>();
        let replacement = (1..=MAX_SIGNAL_DEVICE_ID)
            .find(|candidate| !used.contains(candidate))
            .ok_or(CoreError::LimitExceeded)?;
        runtime
            .global
            .as_mut()
            .ok_or(CoreError::Internal)?
            .device_id = replacement;
        persist_global(&runtime)?;
        Ok(true)
    }

    pub fn encrypt(
        peer_identity: &[u8],
        remote: &SignalPreKeyBundle,
        plaintext: &[u8],
    ) -> CoreResult<Vec<u8>> {
        if peer_identity.len() != 32 || plaintext.is_empty() || plaintext.len() > 16 * 1024 {
            return Err(CoreError::LimitExceeded);
        }
        remote.validate()?;
        let address = peer_address(peer_identity, remote.device_id)?;
        let local_address = local_address()?;
        let mut runtime = store().lock().map_err(|_| CoreError::Internal)?;
        ensure_loaded(&mut runtime)?;
        ensure_session_loaded(&mut runtime, &address)?;
        let before = runtime.clone();
        let result = (|| {
            // Tahini can retain archived sessions without an active sender
            // chain (for example after breaking a session deadlock). Reusing
            // the record alone would leave every subsequent send failing.
            let usable_session = runtime
                .sessions
                .records
                .get(&address_key(&address))
                .map(|encoded| {
                    let record = protocol(libsignal_protocol::SessionRecord::deserialize(encoded))?;
                    protocol(record.has_usable_sender_chain(
                        SystemTime::now(),
                        SessionUsabilityRequirements::NotStale
                            | SessionUsabilityRequirements::EstablishedWithPqxdh
                            | SessionUsabilityRequirements::Spqr,
                    ))
                })
                .transpose()?
                .unwrap_or(false);
            let RuntimeStore {
                global, sessions, ..
            } = &mut *runtime;
            let global = global.as_mut().ok_or(CoreError::Internal)?;
            if !usable_session {
                let bundle = decode_public_bundle(remote)?;
                protocol(futures_executor::block_on(process_prekey_bundle(
                    &address,
                    &local_address,
                    sessions,
                    &mut global.identity,
                    &bundle,
                    SystemTime::now(),
                    &mut OsRng.unwrap_err(),
                )))?;
            }
            let ciphertext = protocol(futures_executor::block_on(message_encrypt(
                plaintext,
                &address,
                &local_address,
                sessions,
                &mut global.identity,
                SystemTime::now(),
                &mut OsRng.unwrap_err(),
            )))?;
            let wire = WireMessage::from_ciphertext(&ciphertext)?;
            let encoded = serde_json::to_vec(&wire).map_err(|_| CoreError::Internal)?;
            let identity_changed = before
                .global
                .as_ref()
                .map(|global| &global.identity.known_keys)
                != runtime
                    .global
                    .as_ref()
                    .map(|global| &global.identity.known_keys);
            persist_transaction(&mut runtime, &address, !usable_session || identity_changed)?;
            Ok(encoded)
        })();
        if result.is_err() {
            *runtime = before;
        }
        result
    }

    pub fn decrypt(
        peer_identity: &[u8],
        sender_device_id: u8,
        encoded: &[u8],
    ) -> CoreResult<(Vec<u8>, PendingDecrypt)> {
        if peer_identity.len() != 32 || encoded.is_empty() || encoded.len() > MAX_WIRE_BYTES * 2 {
            return Err(CoreError::LimitExceeded);
        }
        let wire: WireMessage =
            serde_json::from_slice(encoded).map_err(|_| CoreError::InvalidInput)?;
        let is_pre_key = matches!(wire.kind, WireKind::PreKey);
        let ciphertext = wire.into_ciphertext()?;
        let address = peer_address(peer_identity, sender_device_id)?;
        let local_address = local_address()?;
        let mut runtime = store().lock().map_err(|_| CoreError::Internal)?;
        ensure_loaded(&mut runtime)?;
        ensure_session_loaded(&mut runtime, &address)?;
        let before = runtime.clone();
        let RuntimeStore {
            global, sessions, ..
        } = &mut *runtime;
        let global = global.as_mut().ok_or(CoreError::Internal)?;
        let decrypted = protocol(futures_executor::block_on(message_decrypt(
            &ciphertext,
            &address,
            &local_address,
            sessions,
            &mut global.identity,
            &mut global.pre_keys,
            &global.signed_pre_keys,
            &mut global.kyber_pre_keys,
            &mut OsRng.unwrap_err(),
        )));
        let plaintext = match decrypted {
            Ok(plaintext) => plaintext,
            Err(error) => {
                *runtime = before;
                return Err(error);
            }
        };
        Ok((
            plaintext,
            PendingDecrypt {
                before: Some(before),
                address,
                is_pre_key,
            },
        ))
    }

    fn ensure_loaded(runtime: &mut RuntimeStore) -> CoreResult<()> {
        let recovering_new_session = !runtime.loaded
            && runtime
                .root
                .as_ref()
                .is_some_and(|root| root.join(TRANSACTION_FILE).exists());
        // A damaged local journal is a storage failure, never evidence that
        // the incoming network packet is invalid and should be discarded.
        recover_transaction(runtime).map_err(|_| CoreError::Internal)?;
        if recovering_new_session {
            runtime.session_file_count = fs::read_dir(
                runtime
                    .root
                    .as_ref()
                    .ok_or(CoreError::Internal)?
                    .join(SESSION_DIRECTORY),
            )
            .map_err(|_| CoreError::Internal)?
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .path()
                    .extension()
                    .is_some_and(|extension| extension == "vault")
            })
            .take(MAX_SESSIONS + 1)
            .count();
            if runtime.session_file_count > MAX_SESSIONS {
                return Err(CoreError::LimitExceeded);
            }
        }
        if runtime.loaded {
            return Ok(());
        }
        let root = runtime.root.as_ref().ok_or(CoreError::FeatureUnavailable)?;
        let path = root.join(STORE_FILE);
        runtime.global = Some(if path.exists() {
            let encrypted = fs::read(&path).map_err(|_| CoreError::Internal)?;
            let plaintext = vault::open_with_key(&storage_key()?, &encrypted)?;
            let value: GlobalStore =
                serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
            if value.version != STORE_VERSION {
                return Err(CoreError::UnsupportedVersion);
            }
            value
        } else {
            generate_global_store()?
        });
        runtime.loaded = true;
        if !path.exists() {
            persist_global(runtime)?;
        }
        Ok(())
    }

    fn generate_global_store() -> CoreResult<GlobalStore> {
        let mut rng = OsRng.unwrap_err();
        let identity_pair = IdentityKeyPair::generate(&mut rng);
        let registration_id = u32::from(rng.random::<u16>()).saturating_add(1);
        let signed_pair = KeyPair::generate(&mut rng);
        let signed_public = signed_pair.public_key.serialize();
        let signed_signature = identity_pair
            .private_key()
            .calculate_signature(&signed_public, &mut rng)
            .map_err(|_| CoreError::VerificationFailed)?;
        let signed_record = SignedPreKeyRecord::new(
            SIGNED_PRE_KEY_ID.into(),
            Timestamp::from_epoch_millis(current_time_ms()?),
            &signed_pair,
            &signed_signature,
        );
        let kyber_pair = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
        let kyber_public = kyber_pair.public_key.serialize();
        let kyber_signature = identity_pair
            .private_key()
            .calculate_signature(&kyber_public, &mut rng)
            .map_err(|_| CoreError::VerificationFailed)?;
        let kyber_record = KyberPreKeyRecord::new(
            KYBER_PRE_KEY_ID.into(),
            Timestamp::from_epoch_millis(current_time_ms()?),
            &kyber_pair,
            &kyber_signature,
        );
        Ok(GlobalStore {
            version: STORE_VERSION,
            device_id: rng.random_range(1..=MAX_SIGNAL_DEVICE_ID),
            identity: PersistentIdentityStore {
                key_pair: identity_pair.serialize().to_vec(),
                registration_id,
                known_keys: HashMap::new(),
            },
            pre_keys: PersistentPreKeyStore::default(),
            signed_pre_keys: PersistentSignedPreKeyStore {
                records: HashMap::from([(SIGNED_PRE_KEY_ID, protocol(signed_record.serialize())?)]),
            },
            kyber_pre_keys: PersistentKyberPreKeyStore {
                records: HashMap::from([(KYBER_PRE_KEY_ID, protocol(kyber_record.serialize())?)]),
                used_base_keys: HashMap::new(),
            },
        })
    }

    fn public_bundle(global: &GlobalStore) -> CoreResult<SignalPreKeyBundle> {
        let identity = protocol(IdentityKeyPair::try_from(
            global.identity.key_pair.as_slice(),
        ))?;
        let signed = protocol(SignedPreKeyRecord::deserialize(
            global
                .signed_pre_keys
                .records
                .get(&SIGNED_PRE_KEY_ID)
                .ok_or(CoreError::VerificationFailed)?,
        ))?;
        let kyber = protocol(KyberPreKeyRecord::deserialize(
            global
                .kyber_pre_keys
                .records
                .get(&KYBER_PRE_KEY_ID)
                .ok_or(CoreError::VerificationFailed)?,
        ))?;
        Ok(SignalPreKeyBundle {
            registration_id: global.identity.registration_id,
            device_id: global.device_id,
            signed_pre_key_id: SIGNED_PRE_KEY_ID,
            signed_pre_key_public: protocol(signed.public_key())?.serialize().to_vec(),
            signed_pre_key_signature: protocol(signed.signature())?,
            kyber_pre_key_id: KYBER_PRE_KEY_ID,
            kyber_pre_key_public: protocol(kyber.public_key())?.serialize().to_vec(),
            kyber_pre_key_signature: protocol(kyber.signature())?,
            identity_key: identity.identity_key().serialize().to_vec(),
        })
    }

    fn decode_public_bundle(value: &SignalPreKeyBundle) -> CoreResult<PreKeyBundle> {
        let device = DeviceId::new(value.device_id).map_err(|_| CoreError::InvalidInput)?;
        protocol(PreKeyBundle::new(
            value.registration_id,
            device,
            None,
            value.signed_pre_key_id.into(),
            PublicKey::deserialize(&value.signed_pre_key_public)
                .map_err(|_| CoreError::VerificationFailed)?,
            value.signed_pre_key_signature.clone(),
            value.kyber_pre_key_id.into(),
            protocol(kem::PublicKey::deserialize(&value.kyber_pre_key_public))?,
            value.kyber_pre_key_signature.clone(),
            protocol(IdentityKey::decode(&value.identity_key))?,
        ))
    }

    fn ensure_session_loaded(
        runtime: &mut RuntimeStore,
        address: &ProtocolAddress,
    ) -> CoreResult<()> {
        let key = address_key(address);
        if runtime.loaded_sessions.contains(&key) {
            return Ok(());
        }
        let path = session_path(runtime, &key)?;
        if !path.exists() && runtime.session_file_count >= MAX_SESSIONS {
            return Err(CoreError::LimitExceeded);
        }
        if path.exists() {
            let encrypted = fs::read(path).map_err(|_| CoreError::Internal)?;
            let plaintext = vault::open_with_key(&storage_key()?, &encrypted)?;
            let encoded: Vec<u8> =
                serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
            protocol(libsignal_protocol::SessionRecord::deserialize(&encoded))?;
            runtime.sessions.records.insert(key.clone(), encoded);
        }
        runtime.loaded_sessions.insert(key);
        Ok(())
    }

    fn persist_global(runtime: &RuntimeStore) -> CoreResult<()> {
        let root = runtime.root.as_ref().ok_or(CoreError::FeatureUnavailable)?;
        let encoded = Zeroizing::new(
            serde_json::to_vec(runtime.global.as_ref().ok_or(CoreError::Internal)?)
                .map_err(|_| CoreError::Internal)?,
        );
        let encrypted = vault::seal_with_key(&storage_key()?, &encoded)?;
        atomic_file::replace(&root.join(STORE_FILE), &encrypted)
    }

    // The encrypted journal is the commit point for the session and pre-key
    // stores. Once durable, a failed materialization must not roll back the
    // message or the in-memory ratchet. Recovery completes it before any later
    // ratchet operation, including after process restart.
    fn persist_transaction(
        runtime: &mut RuntimeStore,
        address: &ProtocolAddress,
        include_global: bool,
    ) -> CoreResult<()> {
        recover_transaction(runtime).map_err(|_| CoreError::Internal)?;
        let key = address_key(address);
        let record = runtime
            .sessions
            .records
            .get(&key)
            .ok_or(CoreError::VerificationFailed)?;
        let encoded = Zeroizing::new(serde_json::to_vec(record).map_err(|_| CoreError::Internal)?);
        let encrypted = vault::seal_with_key(&storage_key()?, &encoded)?;
        let path = session_path(runtime, &key)?;
        let is_new = !path.exists();
        let global = if include_global {
            let encoded = Zeroizing::new(
                serde_json::to_vec(runtime.global.as_ref().ok_or(CoreError::Internal)?)
                    .map_err(|_| CoreError::Internal)?,
            );
            if encoded.len() > MAX_GLOBAL_STORE_BYTES {
                return Err(CoreError::StorageFull);
            }
            Some(vault::seal_with_key(&storage_key()?, &encoded)?)
        } else {
            None
        };
        if encoded.len() > MAX_SESSION_STORE_BYTES {
            return Err(CoreError::StorageFull);
        }
        let transaction = StoreTransaction {
            version: 1,
            session_file: path
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or(CoreError::Internal)?
                .to_owned(),
            session: encrypted,
            global,
        };
        let journal = vault::seal_with_key(
            &storage_key()?,
            &Zeroizing::new(serde_json::to_vec(&transaction).map_err(|_| CoreError::Internal)?),
        )?;
        if journal.len() > MAX_TRANSACTION_BYTES {
            return Err(CoreError::StorageFull);
        }
        let journal_path = runtime
            .root
            .as_ref()
            .ok_or(CoreError::FeatureUnavailable)?
            .join(TRANSACTION_FILE);
        if let Err(error) = atomic_file::replace(&journal_path, &journal) {
            // A directory-sync error can occur after the atomic replacement.
            if fs::read(&journal_path).ok().as_deref() != Some(journal.as_slice()) {
                return Err(error);
            }
        }
        if is_new {
            runtime.session_file_count += 1;
        }
        let _ = recover_transaction(runtime);
        Ok(())
    }

    fn recover_transaction(runtime: &RuntimeStore) -> CoreResult<()> {
        let root = runtime.root.as_ref().ok_or(CoreError::FeatureUnavailable)?;
        let path = root.join(TRANSACTION_FILE);
        let metadata = match fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(_) => return Err(CoreError::Internal),
        };
        if metadata.len() > MAX_TRANSACTION_BYTES as u64 {
            return Err(CoreError::LimitExceeded);
        }
        let plaintext = vault::open_with_key(
            &storage_key()?,
            &fs::read(&path).map_err(|_| CoreError::Internal)?,
        )?;
        let transaction: StoreTransaction =
            serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
        if transaction.version != 1 {
            return Err(CoreError::UnsupportedVersion);
        }
        let name = &transaction.session_file;
        if name.len() != 70
            || !name.ends_with(".vault")
            || !name.as_bytes()[..64].iter().all(u8::is_ascii_hexdigit)
            || transaction.session.is_empty()
            || transaction.session.len() > MAX_SESSION_STORE_BYTES + 64
            || transaction
                .global
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > MAX_GLOBAL_STORE_BYTES + 64)
        {
            return Err(CoreError::VerificationFailed);
        }
        atomic_file::replace(
            &root.join(SESSION_DIRECTORY).join(name),
            &transaction.session,
        )?;
        if let Some(global) = transaction.global {
            atomic_file::replace(&root.join(STORE_FILE), &global)?;
        }
        fs::remove_file(path).map_err(|_| CoreError::Internal)
    }

    fn session_path(runtime: &RuntimeStore, address_key: &str) -> CoreResult<PathBuf> {
        let root = runtime.root.as_ref().ok_or(CoreError::FeatureUnavailable)?;
        let digest = Sha256::digest(address_key.as_bytes());
        Ok(root.join(SESSION_DIRECTORY).join(format!(
            "{}.vault",
            digest
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
        )))
    }

    fn storage_key() -> CoreResult<[u8; 32]> {
        identity::active_identity()?.storage_key()
    }

    fn local_address() -> CoreResult<ProtocolAddress> {
        let identity = identity::active_identity()?.identity_public_key()?;
        peer_address(&identity, LEGACY_DEVICE_ID)
    }

    fn peer_address(identity: &[u8], device: u8) -> CoreResult<ProtocolAddress> {
        if identity.len() != 32 {
            return Err(CoreError::InvalidInput);
        }
        let name = identity
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let device = DeviceId::new(device).map_err(|_| CoreError::InvalidInput)?;
        Ok(ProtocolAddress::new(name, device))
    }

    fn address_key(address: &ProtocolAddress) -> String {
        format!("{}:{}", address.name(), u32::from(address.device_id()))
    }

    fn current_time_ms() -> CoreResult<u64> {
        let elapsed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| CoreError::Internal)?;
        u64::try_from(elapsed.as_millis()).map_err(|_| CoreError::Internal)
    }

    fn protocol<T>(result: Result<T, SignalProtocolError>) -> CoreResult<T> {
        result.map_err(|_| CoreError::VerificationFailed)
    }

    #[cfg(test)]
    mod upgrade_tests {
        use super::*;

        #[test]
        fn tahini_reestablishes_archived_sender_and_persists_learned_identity() {
            let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
            let directory = std::env::temp_dir().join(format!(
                "sylphy-tahini-{}-{}",
                std::process::id(),
                current_time_ms().unwrap()
            ));
            let alice_root = directory.join("alice").to_string_lossy().into_owned();
            let bob_root = directory.join("bob").to_string_lossy().into_owned();
            const PASSWORD: &str = "tahini-test-vault";
            identity::ensure_identity(&bob_root, PASSWORD, None, None).unwrap();
            let bob_identity = identity::active_identity()
                .unwrap()
                .identity_public_key()
                .unwrap();
            let bob_bundle = public_pre_key_bundle().unwrap();
            identity::ensure_identity(&alice_root, PASSWORD, None, None).unwrap();
            let alice_identity = identity::active_identity()
                .unwrap()
                .identity_public_key()
                .unwrap();
            let alice_bundle = public_pre_key_bundle().unwrap();
            let first = encrypt(&bob_identity, &bob_bundle, b"before archive").unwrap();
            let address = peer_address(&bob_identity, bob_bundle.device_id).unwrap();
            let key = address_key(&address);
            let old_session_id = {
                let mut runtime = store().lock().unwrap();
                let mut record =
                    libsignal_protocol::SessionRecord::deserialize(&runtime.sessions.records[&key])
                        .unwrap();
                let id = record.alice_base_key().unwrap().to_vec();
                record.archive_current_state().unwrap();
                runtime
                    .sessions
                    .records
                    .insert(key.clone(), record.serialize().unwrap());
                persist_transaction(&mut runtime, &address, false).unwrap();
                id
            };
            identity::activate_from_storage(&bob_root, PASSWORD).unwrap();
            let (body, pending) = decrypt(&alice_identity, alice_bundle.device_id, &first).unwrap();
            assert_eq!(body, b"before archive");
            pending.commit().unwrap();
            identity::activate_from_storage(&alice_root, PASSWORD).unwrap();
            // This record still exists on disk, but its only session is archived.
            let second = encrypt(&bob_identity, &bob_bundle, b"after archive").unwrap();
            {
                let runtime = store().lock().unwrap();
                let record =
                    libsignal_protocol::SessionRecord::deserialize(&runtime.sessions.records[&key])
                        .unwrap();
                assert_eq!(record.archived_session_count(), 1);
                assert_ne!(record.alice_base_key().unwrap(), old_session_id);
            }
            identity::activate_from_storage(&bob_root, PASSWORD).unwrap();
            let (body, pending) =
                decrypt(&alice_identity, alice_bundle.device_id, &second).unwrap();
            assert_eq!(body, b"after archive");
            pending.commit().unwrap();
            let reply = encrypt(&alice_identity, &alice_bundle, b"reply").unwrap();
            identity::activate_from_storage(&alice_root, PASSWORD).unwrap();
            let (body, pending) = decrypt(&bob_identity, bob_bundle.device_id, &reply).unwrap();
            assert_eq!(body, b"reply");
            pending.commit().unwrap();
            {
                let mut runtime = store().lock().unwrap();
                runtime.global.as_mut().unwrap().identity.known_keys.clear();
                persist_global(&runtime).unwrap();
            }
            // v0.106.0 saves the peer identity on every encryption, including
            // when no new session is needed. That trust state must be durable.
            encrypt(&bob_identity, &bob_bundle, b"existing active session").unwrap();
            identity::activate_from_storage(&alice_root, PASSWORD).unwrap();
            public_pre_key_bundle().unwrap();
            assert!(
                store()
                    .lock()
                    .unwrap()
                    .global
                    .as_ref()
                    .unwrap()
                    .identity
                    .known_keys
                    .contains_key(&key)
            );
            fs::remove_dir_all(directory).unwrap();
        }
    }

    pub fn self_test() -> CoreResult<()> {
        use libsignal_protocol::InMemSignalProtocolStore;

        futures_executor::block_on(async {
            let mut rng = OsRng.unwrap_err();
            let alice_device = DeviceId::new(1).map_err(|_| CoreError::Internal)?;
            let bob_device = DeviceId::new(1).map_err(|_| CoreError::Internal)?;
            let alice_address = ProtocolAddress::new("alice".to_owned(), alice_device);
            let bob_address = ProtocolAddress::new("bob".to_owned(), bob_device);
            let alice_identity = IdentityKeyPair::generate(&mut rng);
            let bob_identity = IdentityKeyPair::generate(&mut rng);
            let mut alice = protocol(InMemSignalProtocolStore::new(alice_identity, 1))?;
            let mut bob = protocol(InMemSignalProtocolStore::new(bob_identity, 2))?;
            let signed_pair = KeyPair::generate(&mut rng);
            let signed_public = signed_pair.public_key.serialize();
            let signed_signature = bob_identity
                .private_key()
                .calculate_signature(&signed_public, &mut rng)
                .map_err(|_| CoreError::VerificationFailed)?;
            let signed_record = SignedPreKeyRecord::new(
                1_u32.into(),
                Timestamp::from_epoch_millis(current_time_ms()?),
                &signed_pair,
                &signed_signature,
            );
            protocol(
                bob.signed_pre_key_store
                    .save_signed_pre_key(1_u32.into(), &signed_record)
                    .await,
            )?;
            let kyber_pair = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
            let kyber_public = kyber_pair.public_key.serialize();
            let kyber_signature = bob_identity
                .private_key()
                .calculate_signature(&kyber_public, &mut rng)
                .map_err(|_| CoreError::VerificationFailed)?;
            let kyber_record = KyberPreKeyRecord::new(
                1_u32.into(),
                Timestamp::from_epoch_millis(current_time_ms()?),
                &kyber_pair,
                &kyber_signature,
            );
            protocol(
                bob.kyber_pre_key_store
                    .save_kyber_pre_key(1_u32.into(), &kyber_record)
                    .await,
            )?;
            let bundle = protocol(PreKeyBundle::new(
                2,
                bob_device,
                None,
                1_u32.into(),
                signed_pair.public_key,
                signed_signature.to_vec(),
                1_u32.into(),
                kyber_pair.public_key,
                kyber_signature.to_vec(),
                *bob_identity.identity_key(),
            ))?;
            protocol(
                process_prekey_bundle(
                    &bob_address,
                    &alice_address,
                    &mut alice.session_store,
                    &mut alice.identity_store,
                    &bundle,
                    SystemTime::now(),
                    &mut rng,
                )
                .await,
            )?;
            let encrypted = protocol(
                message_encrypt(
                    b"libsignal-production-path",
                    &bob_address,
                    &alice_address,
                    &mut alice.session_store,
                    &mut alice.identity_store,
                    SystemTime::now(),
                    &mut rng,
                )
                .await,
            )?;
            let plaintext = protocol(
                message_decrypt(
                    &encrypted,
                    &alice_address,
                    &bob_address,
                    &mut bob.session_store,
                    &mut bob.identity_store,
                    &mut bob.pre_key_store,
                    &bob.signed_pre_key_store,
                    &mut bob.kyber_pre_key_store,
                    &mut rng,
                )
                .await,
            )?;
            if plaintext != b"libsignal-production-path" {
                return Err(CoreError::VerificationFailed);
            }
            Ok(())
        })
    }
}

#[cfg(feature = "signal-ratchet")]
pub(crate) fn wipe_memory() -> CoreResult<()> {
    signal::wipe_memory()
}

#[cfg(not(feature = "signal-ratchet"))]
pub(crate) fn wipe_memory() -> CoreResult<()> {
    Ok(())
}

#[cfg(feature = "signal-ratchet")]
pub fn configure_storage(storage_directory: &str) -> CoreResult<()> {
    signal::configure(storage_directory)
}

#[cfg(not(feature = "signal-ratchet"))]
pub fn configure_storage(_storage_directory: &str) -> CoreResult<()> {
    Ok(())
}

#[cfg(feature = "signal-ratchet")]
pub(crate) fn validate_account_backup(value: &serde_json::Value) -> CoreResult<()> {
    signal::validate_account_backup(value)
}

#[cfg(not(feature = "signal-ratchet"))]
pub(crate) fn validate_account_backup(value: &serde_json::Value) -> CoreResult<()> {
    if value.get("version").and_then(serde_json::Value::as_u64) == Some(1) {
        Ok(())
    } else {
        Err(CoreError::VerificationFailed)
    }
}

#[cfg(feature = "signal-ratchet")]
pub fn public_pre_key_bundle() -> CoreResult<Option<SignalPreKeyBundle>> {
    signal::public_pre_key_bundle().map(Some)
}

#[cfg(feature = "signal-ratchet")]
pub(crate) fn avoid_device_id_collisions(reserved: &[(u8, Vec<u8>)]) -> CoreResult<bool> {
    signal::avoid_device_id_collisions(reserved)
}

#[cfg(not(feature = "signal-ratchet"))]
pub(crate) fn avoid_device_id_collisions(_reserved: &[(u8, Vec<u8>)]) -> CoreResult<bool> {
    Ok(false)
}

#[cfg(not(feature = "signal-ratchet"))]
pub fn public_pre_key_bundle() -> CoreResult<Option<SignalPreKeyBundle>> {
    Ok(None)
}

#[cfg(feature = "signal-ratchet")]
pub fn encrypt_message(
    peer_identity: &[u8],
    remote: &SignalPreKeyBundle,
    plaintext: &[u8],
) -> CoreResult<Vec<u8>> {
    signal::encrypt(peer_identity, remote, plaintext)
}

#[cfg(not(feature = "signal-ratchet"))]
pub fn encrypt_message(
    _peer_identity: &[u8],
    _remote: &SignalPreKeyBundle,
    _plaintext: &[u8],
) -> CoreResult<Vec<u8>> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "signal-ratchet")]
pub(crate) use signal::PendingDecrypt;

#[cfg(not(feature = "signal-ratchet"))]
pub(crate) struct PendingDecrypt;

#[cfg(not(feature = "signal-ratchet"))]
impl PendingDecrypt {
    pub(crate) fn commit(self) -> CoreResult<()> {
        Err(CoreError::FeatureUnavailable)
    }
}

#[cfg(feature = "signal-ratchet")]
pub(crate) fn decrypt_message(
    peer_identity: &[u8],
    sender_device_id: u8,
    ciphertext: &[u8],
) -> CoreResult<(Vec<u8>, PendingDecrypt)> {
    signal::decrypt(peer_identity, sender_device_id, ciphertext)
}

#[cfg(not(feature = "signal-ratchet"))]
pub(crate) fn decrypt_message(
    _peer_identity: &[u8],
    _sender_device_id: u8,
    _ciphertext: &[u8],
) -> CoreResult<(Vec<u8>, PendingDecrypt)> {
    Err(CoreError::FeatureUnavailable)
}

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
    fn official_libsignal_round_trip() {
        self_test().expect("official libsignal round trip");
    }
}
