#[cfg(feature = "veilid")]
use serde::Deserialize;
use serde::Serialize;
#[cfg(feature = "veilid")]
use sha2::{Digest, Sha256};

use crate::error::{CoreError, CoreResult};

use crate::peer_identity::{MailboxAddress, PublishedIdentity};

#[cfg(feature = "veilid")]
use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
};

#[cfg(feature = "veilid")]
use crate::envelope::MessageEnvelope;

pub(crate) struct InboundPayload {
    pub(crate) payload: Vec<u8>,
    #[cfg_attr(not(feature = "veilid"), allow(dead_code))]
    mailbox_subkey: Option<u32>,
    #[cfg_attr(not(feature = "veilid"), allow(dead_code))]
    offline_digest: Option<[u8; 32]>,
    #[cfg(feature = "veilid")]
    offline_receipt: Option<OfflineReceipt>,
}

#[cfg(feature = "veilid")]
struct OfflineReceipt {
    keys: crate::offline_mailbox::MailboxKeys,
    record: veilid_core::RecordKey,
    slot: u32,
    first_hash: [u8; 32],
    acknowledgement: Vec<u8>,
}

#[derive(Debug, Serialize)]
pub struct VeilidCapabilityStatus {
    pub compiled: bool,
    pub transport_contract: &'static str,
}

#[derive(Clone, Debug, Serialize)]
pub struct VeilidNodeStatus {
    pub compiled: bool,
    pub running: bool,
    pub attachment_state: String,
    pub public_internet_ready: bool,
    pub live_peer_count: String,
    pub pending_inbound_envelopes: usize,
}

impl VeilidNodeStatus {
    #[cfg(not(feature = "veilid"))]
    fn unavailable() -> Self {
        Self {
            compiled: false,
            running: false,
            attachment_state: "unavailable".to_owned(),
            public_internet_ready: false,
            live_peer_count: "0".to_owned(),
            pending_inbound_envelopes: 0,
        }
    }

    #[cfg(feature = "veilid")]
    fn stopped() -> Self {
        Self {
            compiled: true,
            running: false,
            attachment_state: "detached".to_owned(),
            public_internet_ready: false,
            live_peer_count: "0".to_owned(),
            pending_inbound_envelopes: 0,
        }
    }
}

pub fn capability_status() -> VeilidCapabilityStatus {
    VeilidCapabilityStatus {
        compiled: cfg!(feature = "veilid"),
        transport_contract: "Veilid accepts authenticated application envelopes only",
    }
}

#[cfg(feature = "veilid")]
pub struct VeilidNode {
    api: veilid_core::VeilidAPI,
    inbound_envelopes: Arc<Mutex<VecDeque<InboundPayload>>>,
    seen_mailbox_slots: Arc<Mutex<HashMap<u32, Vec<u8>>>>,
    private_route: Option<veilid_core::RouteBlob>,
    mailbox_task: Option<tokio::task::JoinHandle<()>>,
    offline_task: Option<tokio::task::JoinHandle<()>>,
    offline_targets: Arc<Mutex<Vec<crate::offline_mailbox::MailboxKeys>>>,
    offline_seen: Arc<Mutex<HashMap<[u8; 32], bool>>>,
}

#[cfg(feature = "veilid")]
impl VeilidNode {
    pub async fn start(storage_directory: &str) -> CoreResult<Self> {
        let config = mobile_config(storage_directory);
        let inbound_envelopes = Arc::new(Mutex::new(VecDeque::new()));
        let seen_mailbox_slots = Arc::new(Mutex::new(HashMap::new()));
        let callback_inbox = Arc::clone(&inbound_envelopes);
        let api = veilid_core::api_startup(
            Arc::new(move |update| {
                if let veilid_core::VeilidUpdate::AppMessage(message) = update {
                    enqueue_inbound_envelope(&callback_inbox, message.message(), None);
                }
            }),
            config,
        )
        .await
        .map_err(|error| classify_startup_error(&error))?;
        if let Err(error) = api.attach().await {
            api.shutdown().await;
            return Err(classify_attach_error(&error));
        }
        let offline_targets = Arc::new(Mutex::new(Vec::new()));
        let offline_seen = Arc::new(Mutex::new(HashMap::new()));
        let offline_task = tokio::spawn(poll_offline_mailboxes(
            api.clone(),
            Arc::clone(&inbound_envelopes),
            Arc::clone(&offline_targets),
            Arc::clone(&offline_seen),
        ));
        Ok(Self {
            api,
            inbound_envelopes,
            seen_mailbox_slots,
            private_route: None,
            mailbox_task: None,
            offline_task: Some(offline_task),
            offline_targets,
            offline_seen,
        })
    }

    pub fn from_started_api(api: veilid_core::VeilidAPI) -> Self {
        Self {
            api,
            inbound_envelopes: Arc::new(Mutex::new(VecDeque::new())),
            seen_mailbox_slots: Arc::new(Mutex::new(HashMap::new())),
            private_route: None,
            mailbox_task: None,
            offline_task: None,
            offline_targets: Arc::new(Mutex::new(Vec::new())),
            offline_seen: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn attach(&self) -> Result<(), veilid_core::VeilidAPIError> {
        self.api.attach().await
    }

    pub async fn status(&self) -> Result<VeilidNodeStatus, veilid_core::VeilidAPIError> {
        let state = self.api.get_state().await?;
        Ok(VeilidNodeStatus {
            compiled: true,
            running: true,
            attachment_state: state.attachment.state.to_string(),
            public_internet_ready: state.attachment.public_internet_ready,
            live_peer_count: state.attachment.live_peer_count.to_string(),
            pending_inbound_envelopes: self
                .inbound_envelopes
                .lock()
                .map(|inbox| inbox.len())
                .unwrap_or(0),
        })
    }

    pub fn routing_context(
        &self,
    ) -> Result<veilid_core::RoutingContext, veilid_core::VeilidAPIError> {
        self.api.routing_context()
    }

    pub async fn create_private_route(
        &mut self,
    ) -> Result<veilid_core::RouteBlob, veilid_core::VeilidAPIError> {
        if let Some(route) = &self.private_route {
            return Ok(route.clone());
        }
        let route = self.api.new_private_route().await?;
        self.private_route = Some(route.clone());
        Ok(route)
    }

    pub async fn import_private_route(
        &self,
        route_blob: veilid_core::RouteBlob,
    ) -> Result<veilid_core::RouteId, veilid_core::VeilidAPIError> {
        self.api.import_remote_private_route(route_blob.blob)
    }

    pub async fn send_envelope(
        &self,
        route_id: veilid_core::RouteId,
        envelope: &MessageEnvelope,
    ) -> Result<(), veilid_core::VeilidAPIError> {
        let payload = serde_json::to_vec(envelope)
            .map_err(|_| veilid_core::VeilidAPIError::generic("envelope serialization failed"))?;
        if payload.len() > 32_768 {
            return Err(veilid_core::VeilidAPIError::generic(
                "envelope exceeds Veilid application-message limit",
            ));
        }
        self.api
            .routing_context()?
            .with_default_safety()?
            .app_message(veilid_core::Target::RouteId(route_id), payload)
            .await
    }

    pub async fn shutdown(mut self) {
        if let Some(task) = self.offline_task.take() {
            task.abort();
            let _ = task.await;
        }
        if let Some(task) = self.mailbox_task.take() {
            task.abort();
            let _ = task.await;
        }
        self.api.shutdown().await;
    }
}

#[cfg(feature = "veilid")]
pub fn local_route_blob() -> CoreResult<Vec<u8>> {
    let mut state = lock_runtime()?;
    let VeilidRuntime { runtime, node } = &mut *state;
    let node = node.as_mut().ok_or(CoreError::NetworkStartupFailed)?;
    runtime
        .block_on(node.create_private_route())
        .map(|route| route.blob)
        .map_err(|_| CoreError::NetworkStartupFailed)
}

#[cfg(not(feature = "veilid"))]
pub fn local_route_blob() -> CoreResult<Vec<u8>> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn publish_identity(
    descriptor_json: Option<&str>,
    identity: &PublishedIdentity,
) -> CoreResult<(String, String)> {
    use veilid_core::{CRYPTO_KIND_VLD0, DHTRecordDescriptor, DHTSchema};

    identity.validate()?;
    let bytes = serde_json::to_vec(identity).map_err(|_| CoreError::Internal)?;
    let (runtime, api) = network_executor()?;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let descriptor = if let Some(encoded) = descriptor_json {
        let stored: DHTRecordDescriptor =
            serde_json::from_str(encoded).map_err(|_| CoreError::VerificationFailed)?;
        let _ = runtime
            .block_on(routing.open_dht_record(stored.key(), stored.owner_keypair()))
            .map_err(|_| CoreError::NetworkStartupFailed)?;
        stored
    } else {
        runtime
            .block_on(routing.create_dht_record(
                CRYPTO_KIND_VLD0,
                DHTSchema::dflt(1).map_err(|_| CoreError::Internal)?,
                None,
            ))
            .map_err(|_| CoreError::NetworkStartupFailed)?
    };
    let key = descriptor.key();
    let written = runtime
        .block_on(routing.set_dht_value(key.clone(), 0, bytes, None))
        .map_err(|_| CoreError::NetworkStartupFailed);
    let closed = runtime
        .block_on(routing.close_dht_record(key.clone()))
        .map_err(|_| CoreError::NetworkStartupFailed);
    written.and(closed)?;
    let persisted = serde_json::to_string(&descriptor).map_err(|_| CoreError::Internal)?;
    Ok((format!("sylphy:{key}"), persisted))
}

#[cfg(not(feature = "veilid"))]
pub fn publish_identity(
    _descriptor_json: Option<&str>,
    _identity: &PublishedIdentity,
) -> CoreResult<(String, String)> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn resolve_identity(code: &str) -> CoreResult<PublishedIdentity> {
    use std::str::FromStr as _;

    use veilid_core::RecordKey;

    let normalized = code.trim().strip_prefix("sylphy:").unwrap_or(code.trim());
    let key = RecordKey::from_str(normalized).map_err(|_| CoreError::InvalidInput)?;
    let (runtime, api) = network_executor()?;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let _ = runtime
        .block_on(routing.open_dht_record(key.clone(), None))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let value = runtime
        .block_on(routing.get_dht_value(key.clone(), 0, true))
        .map_err(|_| CoreError::NetworkStartupFailed)
        .and_then(|value| value.ok_or(CoreError::VerificationFailed));
    let closed = runtime
        .block_on(routing.close_dht_record(key))
        .map_err(|_| CoreError::NetworkStartupFailed);
    let value = value.and_then(|value| closed.map(|()| value))?;
    let identity: PublishedIdentity =
        serde_json::from_slice(value.data()).map_err(|_| CoreError::VerificationFailed)?;
    identity.validate()?;
    Ok(identity)
}

#[cfg(feature = "veilid")]
pub fn resolve_owned_identity(descriptor_json: &str) -> CoreResult<PublishedIdentity> {
    use veilid_core::DHTRecordDescriptor;

    let descriptor: DHTRecordDescriptor =
        serde_json::from_str(descriptor_json).map_err(|_| CoreError::VerificationFailed)?;
    resolve_identity(&descriptor.key().to_string())
}

#[cfg(not(feature = "veilid"))]
pub fn resolve_owned_identity(_descriptor_json: &str) -> CoreResult<PublishedIdentity> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(not(feature = "veilid"))]
pub fn resolve_identity(_code: &str) -> CoreResult<PublishedIdentity> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn ensure_mailbox(descriptor_json: Option<&str>) -> CoreResult<(MailboxAddress, String)> {
    use veilid_core::{CRYPTO_KIND_VLD0, DHTRecordDescriptor, DHTSchema, DHTSchemaSMPLMember};

    let mut state = lock_runtime()?;
    let VeilidRuntime { runtime, node } = &mut *state;
    let node = node.as_mut().ok_or(CoreError::NetworkStartupFailed)?;
    let routing = node
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let mailbox = if let Some(encoded) = descriptor_json {
        let mailbox: PersistedMailbox =
            serde_json::from_str(encoded).map_err(|_| CoreError::VerificationFailed)?;
        let _ = runtime
            .block_on(
                routing
                    .open_dht_record(mailbox.descriptor.key(), mailbox.descriptor.owner_keypair()),
            )
            .map_err(|_| CoreError::NetworkStartupFailed)?;
        mailbox
    } else {
        let crypto = node.api.crypto().map_err(|_| CoreError::Internal)?;
        let system = crypto
            .get(CRYPTO_KIND_VLD0)
            .ok_or(CoreError::FeatureUnavailable)?;
        let writer = system.generate_keypair();
        let member = node
            .api
            .generate_member_id(&writer.key())
            .map_err(|_| CoreError::Internal)?;
        let schema = DHTSchema::smpl(
            1,
            vec![DHTSchemaSMPLMember {
                m_key: member.value().clone(),
                m_cnt: MAILBOX_SLOT_COUNT as u16,
            }],
        )
        .map_err(|_| CoreError::Internal)?;
        let descriptor: DHTRecordDescriptor = runtime
            .block_on(routing.create_dht_record(CRYPTO_KIND_VLD0, schema, None))
            .map_err(|_| CoreError::NetworkStartupFailed)?;
        PersistedMailbox { descriptor, writer }
    };
    let address = MailboxAddress {
        record_key: mailbox.descriptor.key().to_string(),
        writer_keypair_json: serde_json::to_string(&mailbox.writer)
            .map_err(|_| CoreError::Internal)?,
    };
    address.validate()?;
    let persisted = serde_json::to_string(&mailbox).map_err(|_| CoreError::Internal)?;
    runtime
        .block_on(routing.close_dht_record(mailbox.descriptor.key()))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    if let Some(task) = node.mailbox_task.take() {
        task.abort();
    }
    node.mailbox_task = Some(runtime.spawn(poll_mailbox(
        node.api.clone(),
        Arc::clone(&node.inbound_envelopes),
        Arc::clone(&node.seen_mailbox_slots),
        mailbox,
    )));
    Ok((address, persisted))
}

#[cfg(not(feature = "veilid"))]
pub fn ensure_mailbox(_descriptor_json: Option<&str>) -> CoreResult<(MailboxAddress, String)> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn store_mailbox_payload(address: &MailboxAddress, payload: &[u8]) -> CoreResult<()> {
    use std::str::FromStr as _;
    use veilid_core::{AllowOffline, KeyPair, RecordKey, SetDHTValueOptions};

    address.validate()?;
    if payload.is_empty() || payload.len() > MAX_INBOUND_ENVELOPE_BYTES / 2 {
        return Err(CoreError::LimitExceeded);
    }
    let frame = serde_json::to_vec(&MailboxFrame {
        version: 1,
        created_at_ms: unix_time_ms()?,
        payload: payload.to_vec(),
    })
    .map_err(|_| CoreError::Internal)?;
    if frame.len() > MAX_INBOUND_ENVELOPE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let key = RecordKey::from_str(&address.record_key).map_err(|_| CoreError::InvalidInput)?;
    let writer: KeyPair =
        serde_json::from_str(&address.writer_keypair_json).map_err(|_| CoreError::InvalidInput)?;
    let (runtime, api) = network_executor()?;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let _ = runtime
        .block_on(routing.open_dht_record(key.clone(), Some(writer.clone())))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let result = (|| {
        let digest = Sha256::digest(&frame);
        let start = u32::from(digest[0]) % MAILBOX_SLOT_COUNT;
        for offset in 0..MAILBOX_SLOT_COUNT {
            let subkey = ((start + offset) % MAILBOX_SLOT_COUNT) + 1;
            let current = runtime
                .block_on(routing.get_dht_value(key.clone(), subkey, true))
                .map_err(|_| CoreError::NetworkStartupFailed)?;
            let available = current.as_ref().is_none_or(|value| {
                value.data() == EMPTY_MAILBOX_SLOT || mailbox_frame_expired(value.data())
            });
            if !available {
                continue;
            }
            runtime
                .block_on(routing.set_dht_value(
                    key.clone(),
                    subkey,
                    frame.clone(),
                    Some(SetDHTValueOptions {
                        writer: Some(writer.clone()),
                        allow_offline: Some(AllowOffline(true)),
                    }),
                ))
                .map_err(|_| CoreError::NetworkAttachFailed)?;
            let confirmed = runtime
                .block_on(routing.get_dht_value(key.clone(), subkey, true))
                .map_err(|_| CoreError::NetworkStartupFailed)?;
            if confirmed
                .as_ref()
                .is_some_and(|value| value.data() == frame)
            {
                return Ok(());
            }
        }
        Err(CoreError::LimitExceeded)
    })();
    let closed = runtime
        .block_on(routing.close_dht_record(key))
        .map_err(|_| CoreError::NetworkStartupFailed);
    result.and(closed)
}

#[cfg(not(feature = "veilid"))]
pub fn store_mailbox_payload(_address: &MailboxAddress, _payload: &[u8]) -> CoreResult<()> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
async fn poll_mailbox(
    api: veilid_core::VeilidAPI,
    inbox: Arc<Mutex<VecDeque<InboundPayload>>>,
    seen_slots: Arc<Mutex<HashMap<u32, Vec<u8>>>>,
    mailbox: PersistedMailbox,
) {
    loop {
        let _ = poll_mailbox_once(&api, &inbox, &seen_slots, &mailbox).await;
        tokio::time::sleep(std::time::Duration::from_secs(
            MAILBOX_POLL_INTERVAL_SECONDS,
        ))
        .await;
    }
}

#[cfg(feature = "veilid")]
async fn poll_mailbox_once(
    api: &veilid_core::VeilidAPI,
    inbox: &Mutex<VecDeque<InboundPayload>>,
    seen_slots: &Mutex<HashMap<u32, Vec<u8>>>,
    mailbox: &PersistedMailbox,
) -> CoreResult<()> {
    use veilid_core::{AllowOffline, SetDHTValueOptions};

    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let key = mailbox.descriptor.key();
    let _ = routing
        .open_dht_record(key.clone(), mailbox.descriptor.owner_keypair())
        .await
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let result = async {
        for subkey in 1..=MAILBOX_SLOT_COUNT {
            let value = routing
                .get_dht_value(key.clone(), subkey, true)
                .await
                .map_err(|_| CoreError::NetworkStartupFailed)?;
            let Some(value) = value else { continue };
            if value.data() == EMPTY_MAILBOX_SLOT || value.data().is_empty() {
                seen_slots
                    .lock()
                    .map_err(|_| CoreError::Internal)?
                    .remove(&subkey);
                continue;
            }
            let digest = Sha256::digest(value.data()).to_vec();
            if seen_slots
                .lock()
                .map_err(|_| CoreError::Internal)?
                .get(&subkey)
                .is_some_and(|known| known == &digest)
            {
                continue;
            }
            let frame = serde_json::from_slice::<MailboxFrame>(value.data()).ok();
            let is_valid = frame.as_ref().is_some_and(|frame| {
                frame.version == 1
                    && !frame.payload.is_empty()
                    && frame.payload.len() <= MAX_INBOUND_ENVELOPE_BYTES / 2
                    && !mailbox_frame_expired(value.data())
            });
            if is_valid
                && !enqueue_inbound_envelope(
                    inbox,
                    &frame.as_ref().expect("validated frame").payload,
                    Some(subkey),
                )
            {
                // Preserve the slot when the bounded in-memory queue is full so it
                // can be retried on the next pass instead of dropping a message.
                continue;
            }
            if !is_valid {
                routing
                    .set_dht_value(
                        key.clone(),
                        subkey,
                        EMPTY_MAILBOX_SLOT.to_vec(),
                        Some(SetDHTValueOptions {
                            writer: Some(mailbox.writer.clone()),
                            allow_offline: Some(AllowOffline(true)),
                        }),
                    )
                    .await
                    .map_err(|_| CoreError::NetworkAttachFailed)?;
                seen_slots
                    .lock()
                    .map_err(|_| CoreError::Internal)?
                    .remove(&subkey);
            } else {
                seen_slots
                    .lock()
                    .map_err(|_| CoreError::Internal)?
                    .insert(subkey, digest);
            }
        }
        Ok(())
    }
    .await;
    let _ = routing.close_dht_record(key).await;
    result
}

#[cfg(feature = "veilid")]
pub fn publish_attachment_blob(data: &[u8]) -> CoreResult<(String, u16)> {
    use veilid_core::{CRYPTO_KIND_VLD0, DHTSchema};

    if data.is_empty() || data.len() > MAX_ATTACHMENT_BLOB_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let chunk_count = data.len().div_ceil(ATTACHMENT_CHUNK_BYTES);
    let chunk_count = u16::try_from(chunk_count).map_err(|_| CoreError::LimitExceeded)?;
    let (runtime, api) = network_executor()?;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let descriptor = runtime
        .block_on(routing.create_dht_record(
            CRYPTO_KIND_VLD0,
            DHTSchema::dflt(chunk_count).map_err(|_| CoreError::LimitExceeded)?,
            None,
        ))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let key = descriptor.key();
    let published = (|| {
        for (index, chunk) in data.chunks(ATTACHMENT_CHUNK_BYTES).enumerate() {
            runtime
                .block_on(routing.set_dht_value(key.clone(), index as u32, chunk.to_vec(), None))
                .map_err(|_| CoreError::NetworkAttachFailed)?;
        }
        Ok(())
    })();
    let closed = runtime
        .block_on(routing.close_dht_record(key.clone()))
        .map_err(|_| CoreError::NetworkStartupFailed);
    if let Err(error) = published.and(closed) {
        let _ = runtime.block_on(routing.delete_dht_record(key.clone()));
        return Err(error);
    }
    Ok((key.to_string(), chunk_count))
}

#[cfg(not(feature = "veilid"))]
pub fn publish_attachment_blob(_data: &[u8]) -> CoreResult<(String, u16)> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn delete_attachment_blob(record_key: &str, chunk_count: u16) -> CoreResult<()> {
    use std::str::FromStr as _;
    use veilid_core::RecordKey;

    if chunk_count == 0 || chunk_count > MAX_ATTACHMENT_CHUNKS {
        return Err(CoreError::InvalidInput);
    }
    let key = RecordKey::from_str(record_key).map_err(|_| CoreError::InvalidInput)?;
    let (runtime, api) = network_executor()?;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    runtime
        .block_on(routing.delete_dht_record(key))
        .map_err(|_| CoreError::NetworkAttachFailed)
}

#[cfg(not(feature = "veilid"))]
pub fn delete_attachment_blob(_record_key: &str, _chunk_count: u16) -> CoreResult<()> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn fetch_attachment_blob(record_key: &str, chunk_count: u16) -> CoreResult<Vec<u8>> {
    use std::str::FromStr as _;
    use veilid_core::RecordKey;

    if chunk_count == 0 || chunk_count > MAX_ATTACHMENT_CHUNKS {
        return Err(CoreError::InvalidInput);
    }
    let key = RecordKey::from_str(record_key).map_err(|_| CoreError::InvalidInput)?;
    let (runtime, api) = network_executor()?;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let _ = runtime
        .block_on(routing.open_dht_record(key.clone(), None))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let result = (|| {
        let mut data = Vec::new();
        for subkey in 0..u32::from(chunk_count) {
            let value = runtime
                .block_on(routing.get_dht_value(key.clone(), subkey, true))
                .map_err(|_| CoreError::NetworkStartupFailed)?
                .ok_or(CoreError::NetworkAttachFailed)?;
            data.extend_from_slice(value.data());
            if data.len() > MAX_ATTACHMENT_BLOB_BYTES {
                return Err(CoreError::LimitExceeded);
            }
        }
        Ok(data)
    })();
    let closed = runtime
        .block_on(routing.close_dht_record(key))
        .map_err(|_| CoreError::NetworkStartupFailed);
    result.and_then(|data| closed.map(|()| data))
}

#[cfg(not(feature = "veilid"))]
pub fn fetch_attachment_blob(_record_key: &str, _chunk_count: u16) -> CoreResult<Vec<u8>> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn send_payload(route_blob: &[u8], payload: Vec<u8>) -> CoreResult<()> {
    if route_blob.is_empty() || payload.is_empty() || payload.len() > MAX_INBOUND_ENVELOPE_BYTES {
        return Err(CoreError::InvalidInput);
    }
    let (runtime, api) = network_executor()?;
    let route_id = api
        .import_remote_private_route(route_blob.to_vec())
        .map_err(|_| CoreError::NetworkAttachFailed)?;
    let result = runtime.block_on(async {
        let routing = api.routing_context()?.with_default_safety()?;
        routing
            .app_message(veilid_core::Target::RouteId(route_id.clone()), payload)
            .await
    });
    let _ = api.release_private_route(route_id);
    result.map_err(|_| CoreError::NetworkAttachFailed)
}

#[cfg(not(feature = "veilid"))]
pub fn send_payload(_route_blob: &[u8], _payload: Vec<u8>) -> CoreResult<()> {
    Err(CoreError::FeatureUnavailable)
}

/// Legacy public mailbox capabilities remain forbidden. Pair-scoped offline
/// delivery is handled separately and never reads a public writer key.
pub fn deliver_payload(
    route_blob: &[u8],
    _mailbox: Option<&MailboxAddress>,
    payload: Vec<u8>,
) -> CoreResult<()> {
    send_payload(route_blob, payload)
}

#[cfg(feature = "veilid")]
pub(crate) fn take_inbound_payloads() -> CoreResult<Vec<InboundPayload>> {
    let state = lock_runtime()?;
    let node = state.node.as_ref().ok_or(CoreError::NetworkStartupFailed)?;
    let mut inbox = node
        .inbound_envelopes
        .lock()
        .map_err(|_| CoreError::Internal)?;
    Ok(inbox.drain(..).collect())
}

#[cfg(not(feature = "veilid"))]
pub(crate) fn take_inbound_payloads() -> CoreResult<Vec<InboundPayload>> {
    Ok(Vec::new())
}

#[cfg(feature = "veilid")]
pub(crate) fn acknowledge_inbound_payload(payload: InboundPayload) -> CoreResult<()> {
    // Mailbox slots form a short-lived journal shared by every linked device.
    // A consumer must not erase an entry before the other devices have seen it.
    let _ = payload.mailbox_subkey;
    if let Some(digest) = payload.offline_digest {
        let state = lock_runtime()?;
        if let Some(node) = &state.node {
            let mut seen = node.offline_seen.lock().map_err(|_| CoreError::Internal)?;
            if seen.len() >= 8192 {
                seen.retain(|_, acknowledged| !*acknowledged);
            }
            seen.insert(digest, true);
            if let Some(receipt) = payload.offline_receipt {
                let api = node.api.clone();
                let seen = Arc::clone(&node.offline_seen);
                state.runtime.spawn(async move {
                    if acknowledge_offline_slot(&api, receipt).await.is_err() {
                        // Retry by re-reading and deduplicating the saved packet.
                        if let Ok(mut seen) = seen.lock() {
                            seen.remove(&digest);
                        }
                    }
                });
            }
        }
    }
    Ok(())
}

#[cfg(not(feature = "veilid"))]
pub(crate) fn acknowledge_inbound_payload(_payload: InboundPayload) -> CoreResult<()> {
    Ok(())
}

/// A fetch is not an acknowledgement. On transient failures release its
/// in-flight marker so a subsequent poll can fetch the same ciphertext again.
#[cfg(feature = "veilid")]
pub(crate) fn retry_inbound_payload(payload: InboundPayload) {
    let Ok(state) = lock_runtime() else { return };
    let Some(node) = &state.node else { return };
    if let Some(digest) = payload.offline_digest {
        if let Ok(mut seen) = node.offline_seen.lock() {
            seen.remove(&digest);
        }
    } else if let Some(subkey) = payload.mailbox_subkey {
        if let Ok(mut seen) = node.seen_mailbox_slots.lock() {
            seen.remove(&subkey);
        }
    } else if let Ok(mut inbox) = node.inbound_envelopes.lock() {
        if inbox.len() < MAX_PENDING_INBOUND_ENVELOPES {
            inbox.push_back(payload);
        }
    }
}

#[cfg(not(feature = "veilid"))]
pub(crate) fn retry_inbound_payload(_payload: InboundPayload) {}

#[cfg(feature = "veilid")]
pub(crate) fn set_offline_targets(
    targets: Vec<crate::offline_mailbox::MailboxKeys>,
) -> CoreResult<()> {
    let state = lock_runtime()?;
    let node = state.node.as_ref().ok_or(CoreError::NetworkStartupFailed)?;
    *node
        .offline_targets
        .lock()
        .map_err(|_| CoreError::Internal)? = targets;
    Ok(())
}

#[cfg(not(feature = "veilid"))]
pub(crate) fn set_offline_targets(
    _targets: Vec<crate::offline_mailbox::MailboxKeys>,
) -> CoreResult<()> {
    Ok(())
}

#[cfg(feature = "veilid")]
pub(crate) fn store_offline_payload(
    keys: &crate::offline_mailbox::MailboxKeys,
    payload: &[u8],
) -> CoreResult<()> {
    let (runtime, api) = network_executor()?;
    runtime.block_on(store_offline_payload_async(&api, keys, payload))
}

#[cfg(feature = "veilid")]
type OfflineRecordLocks = HashMap<[u8; 32], std::sync::Weak<tokio::sync::Mutex<()>>>;
#[cfg(feature = "veilid")]
static OFFLINE_RECORD_LOCKS: OnceLock<Mutex<OfflineRecordLocks>> = OnceLock::new();

#[cfg(feature = "veilid")]
fn offline_record_lock(id: [u8; 32]) -> CoreResult<Arc<tokio::sync::Mutex<()>>> {
    let mut locks = OFFLINE_RECORD_LOCKS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| CoreError::Internal)?;
    if let Some(lock) = locks.get(&id).and_then(std::sync::Weak::upgrade) {
        return Ok(lock);
    }
    locks.retain(|_, value| value.strong_count() != 0);
    let lock = Arc::new(tokio::sync::Mutex::new(()));
    locks.insert(id, Arc::downgrade(&lock));
    Ok(lock)
}

#[cfg(not(feature = "veilid"))]
pub(crate) fn store_offline_payload(
    _keys: &crate::offline_mailbox::MailboxKeys,
    _payload: &[u8],
) -> CoreResult<()> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
async fn store_offline_payload_async(
    api: &veilid_core::VeilidAPI,
    keys: &crate::offline_mailbox::MailboxKeys,
    payload: &[u8],
) -> CoreResult<()> {
    let record_lock = offline_record_lock(keys.id())?;
    let _guard = record_lock.lock().await;
    use crate::offline_mailbox::{SLOT_COUNT, frame_length};
    use veilid_core::{AllowOffline, CRYPTO_KIND_VLD0, DHTSchema, SetDHTValueOptions};
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let schema = DHTSchema::dflt((SLOT_COUNT * 3) as u16).map_err(|_| CoreError::Internal)?;
    let owner = keys.owner();
    let key = api
        .get_dht_record_key(schema.clone(), owner.key(), None)
        .await
        .map_err(|_| CoreError::Internal)?;
    // Deterministic creation is local. If this record already exists, reopen
    // it; never create a different mailbox on a transient network error.
    let _ = routing
        .create_dht_record(CRYPTO_KIND_VLD0, schema, Some(owner.clone()))
        .await;
    // Veilid 0.5.7 creates a random record encryption key even with a
    // deterministic owner. Reopen with the derived opaque key on both peers;
    // our application-level wrapper already encrypts the complete packet.
    let _ = routing
        .open_dht_record(key.clone(), Some(owner.clone()))
        .await
        .map_err(|_| CoreError::NetworkAttachFailed)?;
    let result = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        let now = unix_time_ms()?;
        let (first, second) = keys.seal(payload, now)?;
        let start = u32::from(Sha256::digest(payload)[0]) % SLOT_COUNT;
        for offset in 0..SLOT_COUNT {
            let slot = (start + offset) % SLOT_COUNT;
            let current = routing
                .get_dht_value(key.clone(), slot * 3, true)
                .await
                .map_err(|_| CoreError::NetworkAttachFailed)?;
            if let Some(value) = current.as_ref() {
                if frame_length(value.data(), now).is_ok() {
                    if let Ok(existing) =
                        read_offline_frame(&routing, &key, keys, slot, value.data(), now).await
                    {
                        if existing.as_slice() == payload {
                            return Ok(());
                        }
                    }
                    let ack = routing
                        .get_dht_value(key.clone(), slot * 3 + 2, true)
                        .await
                        .map_err(|_| CoreError::NetworkAttachFailed)?;
                    if !ack.as_ref().is_some_and(|ack| {
                        crate::offline_mailbox::acknowledges(ack.data(), value.data())
                    }) {
                        continue; // Never overwrite an unacknowledged, unexpired entry.
                    }
                }
            }
            let options = || {
                Some(SetDHTValueOptions {
                    writer: Some(owner.clone()),
                    allow_offline: Some(AllowOffline(false)),
                })
            };
            // Publish the continuation first and the authenticated commit last.
            if !second.is_empty() {
                routing
                    .set_dht_value(key.clone(), slot * 3 + 1, second.clone(), options())
                    .await
                    .map_err(|_| CoreError::NetworkAttachFailed)?;
            }
            routing
                .set_dht_value(key.clone(), slot * 3, first.clone(), options())
                .await
                .map_err(|_| CoreError::NetworkAttachFailed)?;
            let confirmed = routing
                .get_dht_value(key.clone(), slot * 3, true)
                .await
                .map_err(|_| CoreError::NetworkAttachFailed)?
                .ok_or(CoreError::NetworkAttachFailed)?;
            if read_offline_frame(&routing, &key, keys, slot, confirmed.data(), now)
                .await?
                .as_slice()
                == payload
            {
                return Ok(());
            }
        }
        Err(CoreError::LimitExceeded)
    })
    .await
    .unwrap_or(Err(CoreError::NetworkAttachFailed));
    let _ = routing.close_dht_record(key).await;
    result
}

#[cfg(feature = "veilid")]
async fn read_offline_frame(
    routing: &veilid_core::RoutingContext,
    key: &veilid_core::RecordKey,
    keys: &crate::offline_mailbox::MailboxKeys,
    slot: u32,
    first: &[u8],
    now: u64,
) -> CoreResult<zeroize::Zeroizing<Vec<u8>>> {
    let length = crate::offline_mailbox::frame_length(first, now)?;
    let second = if length > crate::offline_mailbox::CHUNK_BYTES {
        routing
            .get_dht_value(key.clone(), slot * 3 + 1, true)
            .await
            .map_err(|_| CoreError::NetworkAttachFailed)?
            .ok_or(CoreError::NetworkAttachFailed)?
            .data()
            .to_vec()
    } else {
        Vec::new()
    };
    keys.open(first, &second, now)
}

#[cfg(feature = "veilid")]
async fn poll_offline_mailboxes(
    api: veilid_core::VeilidAPI,
    inbox: Arc<Mutex<VecDeque<InboundPayload>>>,
    targets: Arc<Mutex<Vec<crate::offline_mailbox::MailboxKeys>>>,
    seen: Arc<Mutex<HashMap<[u8; 32], bool>>>,
) {
    loop {
        let snapshot = targets
            .lock()
            .map(|targets| targets.clone())
            .unwrap_or_default();
        for keys in snapshot {
            let _ = poll_offline_mailbox_once(&api, &inbox, &seen, &keys).await;
        }
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
    }
}

#[cfg(feature = "veilid")]
async fn poll_offline_mailbox_once(
    api: &veilid_core::VeilidAPI,
    inbox: &Mutex<VecDeque<InboundPayload>>,
    seen: &Mutex<HashMap<[u8; 32], bool>>,
    keys: &crate::offline_mailbox::MailboxKeys,
) -> CoreResult<()> {
    let record_lock = offline_record_lock(keys.id())?;
    let _guard = record_lock.lock().await;
    use crate::offline_mailbox::{SLOT_COUNT, frame_length};
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let schema =
        veilid_core::DHTSchema::dflt((SLOT_COUNT * 3) as u16).map_err(|_| CoreError::Internal)?;
    let key = api
        .get_dht_record_key(schema, keys.owner().key(), None)
        .await
        .map_err(|_| CoreError::Internal)?;
    let _ = routing
        .open_dht_record(key.clone(), None)
        .await
        .map_err(|_| CoreError::NetworkAttachFailed)?;
    let result = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        let start = ((unix_time_ms()? / 10_000) % u64::from(SLOT_COUNT)) as u32;
        // One sequence report replaces a network lookup for every empty or
        // unchanged slot. Retryable local failures still use the cached frame.
        let report = routing
            .inspect_dht_record(key.clone(), None, veilid_core::DHTReportScope::SyncGet)
            .await
            .map_err(|_| CoreError::NetworkAttachFailed)?;
        let newer = report.newer_online_subkeys();
        for offset in 0..SLOT_COUNT {
            let slot = (start + offset) % SLOT_COUNT;
            let subkey = slot * 3;
            let exists = report
                .local_seqs()
                .get(subkey as usize)
                .is_some_and(|seq| !seq.is_none())
                || report
                    .network_seqs()
                    .get(subkey as usize)
                    .is_some_and(|seq| !seq.is_none());
            if !exists {
                continue;
            }
            if inbox.lock().map_err(|_| CoreError::Internal)?.len() >= MAX_PENDING_INBOUND_ENVELOPES
            {
                break;
            }
            let Some(first) = routing
                .get_dht_value(key.clone(), subkey, newer.contains(subkey))
                .await
                .map_err(|_| CoreError::NetworkAttachFailed)?
            else {
                continue;
            };
            let now = unix_time_ms()?;
            if frame_length(first.data(), now).is_err() {
                continue;
            }
            let mut hash = Sha256::new();
            hash.update(keys.id());
            hash.update(first.data());
            let digest: [u8; 32] = hash.finalize().into();
            if seen
                .lock()
                .map_err(|_| CoreError::Internal)?
                .contains_key(&digest)
            {
                continue;
            }
            let Ok(payload) =
                read_offline_frame(&routing, &key, keys, slot, first.data(), now).await
            else {
                continue;
            };
            // Mark in-flight while holding the inbox lock. A consumer can only
            // acknowledge after this insertion has completed.
            let mut queue = inbox.lock().map_err(|_| CoreError::Internal)?;
            if queue.len() >= MAX_PENDING_INBOUND_ENVELOPES {
                break;
            }
            seen.lock()
                .map_err(|_| CoreError::Internal)?
                .insert(digest, false);
            let receipt = OfflineReceipt {
                keys: keys.clone(),
                record: key.clone(),
                slot,
                first_hash: Sha256::digest(first.data()).into(),
                acknowledgement: crate::offline_mailbox::acknowledgement(first.data()),
            };
            queue.push_back(InboundPayload {
                payload: payload.to_vec(),
                mailbox_subkey: None,
                offline_digest: Some(digest),
                offline_receipt: Some(receipt),
            });
        }
        Ok(())
    })
    .await
    .unwrap_or(Err(CoreError::NetworkAttachFailed));
    let _ = routing.close_dht_record(key).await;
    result
}

#[cfg(feature = "veilid")]
async fn acknowledge_offline_slot(
    api: &veilid_core::VeilidAPI,
    receipt: OfflineReceipt,
) -> CoreResult<()> {
    let record_lock = offline_record_lock(receipt.keys.id())?;
    let _guard = record_lock.lock().await;
    let routing = api
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let owner = receipt.keys.owner();
    let _ = routing
        .open_dht_record(receipt.record.clone(), Some(owner.clone()))
        .await
        .map_err(|_| CoreError::NetworkAttachFailed)?;
    let result = async {
        let current = routing
            .get_dht_value(receipt.record.clone(), receipt.slot * 3, true)
            .await
            .map_err(|_| CoreError::NetworkAttachFailed)?;
        if let Some(value) = current {
            let hash: [u8; 32] = Sha256::digest(value.data()).into();
            if hash == receipt.first_hash {
                let result = routing
                    .set_dht_value(
                        receipt.record.clone(),
                        receipt.slot * 3 + 2,
                        receipt.acknowledgement.clone(),
                        Some(veilid_core::SetDHTValueOptions {
                            writer: Some(owner),
                            allow_offline: Some(veilid_core::AllowOffline(false)),
                        }),
                    )
                    .await
                    .map_err(|_| CoreError::NetworkAttachFailed)?;
                if result.is_some_and(|value| value.data() != receipt.acknowledgement) {
                    return Err(CoreError::NetworkAttachFailed);
                }
            }
        }
        Ok(())
    }
    .await;
    let _ = routing.close_dht_record(receipt.record).await;
    result
}

#[cfg(feature = "veilid")]
fn mobile_config(storage_directory: &str) -> veilid_core::VeilidConfig {
    // Match Veilid's official Flutter helper: override only the three
    // stores and keep TLS/network defaults untouched.
    let storage = PathBuf::from(storage_directory);
    let mut config = veilid_core::VeilidConfig {
        program_name: "sylphy".to_owned(),
        ..Default::default()
    };
    config.protected_store.directory = storage
        .join("protected_store")
        .to_string_lossy()
        .into_owned();
    config.table_store.directory = storage.join("table_store").to_string_lossy().into_owned();
    config.block_store.directory = storage.join("block_store").to_string_lossy().into_owned();
    config
}

#[cfg(feature = "veilid")]
fn classify_startup_error(error: &veilid_core::VeilidAPIError) -> CoreError {
    use veilid_core::VeilidAPIError;

    match error {
        VeilidAPIError::AlreadyInitialized => CoreError::VeilidRestarting,
        VeilidAPIError::InvalidArgument { .. }
        | VeilidAPIError::MissingArgument { .. }
        | VeilidAPIError::ParseError { .. } => CoreError::VeilidConfigurationFailed,
        VeilidAPIError::Generic { message } | VeilidAPIError::Internal { message } => {
            classify_startup_message(message)
        }
        VeilidAPIError::NotInitialized => CoreError::PlatformNotInitialized,
        _ => CoreError::NetworkStartupFailed,
    }
}

#[cfg(feature = "veilid")]
fn classify_startup_message(message: &str) -> CoreError {
    let normalized = message.to_ascii_lowercase();
    if normalized.contains("protected store")
        || normalized.contains("keyring")
        || normalized.contains("key storage")
    {
        CoreError::VeilidProtectedStoreFailed
    } else if normalized.contains("table store")
        || normalized.contains("block store")
        || normalized.contains("database")
    {
        CoreError::VeilidLocalStoreFailed
    } else if normalized.contains("config") || normalized.contains("argument") {
        CoreError::VeilidConfigurationFailed
    } else {
        CoreError::NetworkStartupFailed
    }
}

#[cfg(feature = "veilid")]
fn classify_attach_error(error: &veilid_core::VeilidAPIError) -> CoreError {
    match error {
        veilid_core::VeilidAPIError::NotInitialized => CoreError::PlatformNotInitialized,
        veilid_core::VeilidAPIError::AlreadyInitialized => CoreError::VeilidRestarting,
        _ => CoreError::NetworkAttachFailed,
    }
}

#[cfg(feature = "veilid")]
const MAX_PENDING_INBOUND_ENVELOPES: usize = 256;

#[cfg(feature = "veilid")]
const MAX_INBOUND_ENVELOPE_BYTES: usize = 32_768;

#[cfg(feature = "veilid")]
const MAILBOX_SLOT_COUNT: u32 = 31;

#[cfg(feature = "veilid")]
const MAILBOX_POLL_INTERVAL_SECONDS: u64 = 10;

#[cfg(feature = "veilid")]
const MAILBOX_RETENTION_MS: u64 = 24 * 60 * 60 * 1000;

#[cfg(feature = "veilid")]
const EMPTY_MAILBOX_SLOT: &[u8] = b"[]";

#[cfg(feature = "veilid")]
const ATTACHMENT_CHUNK_BYTES: usize = 24 * 1024;
#[cfg(feature = "veilid")]
const MAX_ATTACHMENT_CHUNKS: u16 = 32;
#[cfg(feature = "veilid")]
const MAX_ATTACHMENT_BLOB_BYTES: usize = ATTACHMENT_CHUNK_BYTES * MAX_ATTACHMENT_CHUNKS as usize;

#[cfg(feature = "veilid")]
#[derive(Clone, Debug, Deserialize, Serialize)]
struct PersistedMailbox {
    descriptor: veilid_core::DHTRecordDescriptor,
    writer: veilid_core::KeyPair,
}

#[cfg(feature = "veilid")]
#[derive(Debug, Deserialize, Serialize)]
struct MailboxFrame {
    version: u8,
    created_at_ms: u64,
    payload: Vec<u8>,
}

#[cfg(feature = "veilid")]
fn unix_time_ms() -> CoreResult<u64> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::Internal)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| CoreError::Internal)
}

#[cfg(feature = "veilid")]
fn mailbox_frame_expired(value: &[u8]) -> bool {
    let Ok(frame) = serde_json::from_slice::<MailboxFrame>(value) else {
        return true;
    };
    frame.version != 1
        || frame.created_at_ms.saturating_add(MAILBOX_RETENTION_MS)
            <= unix_time_ms().unwrap_or(u64::MAX)
}

#[cfg(feature = "veilid")]
fn enqueue_inbound_envelope(
    inbox: &Mutex<VecDeque<InboundPayload>>,
    payload: &[u8],
    mailbox_subkey: Option<u32>,
) -> bool {
    if payload.is_empty() || payload.len() > MAX_INBOUND_ENVELOPE_BYTES {
        return false;
    }
    if let Ok(mut inbox) = inbox.lock()
        && inbox.len() < MAX_PENDING_INBOUND_ENVELOPES
        && mailbox_subkey
            .is_none_or(|subkey| !inbox.iter().any(|item| item.mailbox_subkey == Some(subkey)))
    {
        inbox.push_back(InboundPayload {
            payload: payload.to_vec(),
            mailbox_subkey,
            offline_digest: None,
            offline_receipt: None,
        });
        return true;
    }
    false
}

#[cfg(feature = "veilid")]
struct VeilidRuntime {
    runtime: tokio::runtime::Runtime,
    node: Option<VeilidNode>,
}

#[cfg(feature = "veilid")]
impl VeilidRuntime {
    fn new() -> Result<Self, ()> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("sylphy-veilid")
            .build()
            .map_err(|_| ())?;
        Ok(Self {
            runtime,
            node: None,
        })
    }
}

#[cfg(feature = "veilid")]
static VEILID_RUNTIME: OnceLock<Result<Mutex<VeilidRuntime>, ()>> = OnceLock::new();

#[cfg(feature = "veilid")]
fn runtime() -> CoreResult<&'static Mutex<VeilidRuntime>> {
    VEILID_RUNTIME
        .get_or_init(|| VeilidRuntime::new().map(Mutex::new))
        .as_ref()
        .map_err(|_| CoreError::Internal)
}

#[cfg(feature = "veilid")]
fn lock_runtime() -> CoreResult<std::sync::MutexGuard<'static, VeilidRuntime>> {
    runtime()?.lock().map_err(|_| CoreError::Internal)
}

#[cfg(feature = "veilid")]
fn network_executor() -> CoreResult<(tokio::runtime::Handle, veilid_core::VeilidAPI)> {
    let state = lock_runtime()?;
    let handle = state.runtime.handle().clone();
    let api = state
        .node
        .as_ref()
        .ok_or(CoreError::NetworkStartupFailed)?
        .api
        .clone();
    Ok((handle, api))
}

#[cfg(feature = "veilid")]
pub fn start_node(storage_directory: &str) -> CoreResult<VeilidNodeStatus> {
    if storage_directory.trim().is_empty() {
        return Err(CoreError::InvalidInput);
    }
    std::fs::create_dir_all(storage_directory).map_err(|_| CoreError::Internal)?;

    #[cfg(target_os = "android")]
    if !crate::android::is_context_ready() {
        return Err(CoreError::PlatformNotInitialized);
    }

    let mut state = lock_runtime()?;
    if state.node.is_none() {
        let node = state
            .runtime
            .block_on(VeilidNode::start(storage_directory))?;
        state.node = Some(node);
    }
    let node = state.node.as_ref().ok_or(CoreError::Internal)?;
    state
        .runtime
        .block_on(node.status())
        .map_err(|_| CoreError::NetworkStartupFailed)
}

#[cfg(not(feature = "veilid"))]
pub fn start_node(_storage_directory: &str) -> CoreResult<VeilidNodeStatus> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn node_status() -> CoreResult<VeilidNodeStatus> {
    let state = lock_runtime()?;
    let Some(node) = state.node.as_ref() else {
        return Ok(VeilidNodeStatus::stopped());
    };
    state
        .runtime
        .block_on(node.status())
        .map_err(|_| CoreError::NetworkStartupFailed)
}

#[cfg(not(feature = "veilid"))]
pub fn node_status() -> CoreResult<VeilidNodeStatus> {
    Ok(VeilidNodeStatus::unavailable())
}

#[cfg(feature = "veilid")]
pub fn stop_node() -> CoreResult<VeilidNodeStatus> {
    let mut state = lock_runtime()?;
    if let Some(node) = state.node.take() {
        state.runtime.block_on(node.shutdown());
    }
    Ok(VeilidNodeStatus::stopped())
}

#[cfg(not(feature = "veilid"))]
pub fn stop_node() -> CoreResult<VeilidNodeStatus> {
    Ok(VeilidNodeStatus::unavailable())
}

#[cfg(all(test, not(feature = "veilid")))]
mod tests {
    use super::*;

    #[test]
    fn reports_an_unavailable_node_without_the_feature() {
        let status = node_status().expect("status without Veilid feature");
        assert!(!status.compiled);
        assert!(!status.running);
        assert_eq!(status.attachment_state, "unavailable");
    }

    #[test]
    fn refuses_start_without_the_feature() {
        assert!(matches!(
            start_node("ignored"),
            Err(CoreError::FeatureUnavailable)
        ));
    }
}

#[cfg(all(test, feature = "veilid"))]
mod feature_tests {
    use super::*;

    #[test]
    fn mobile_config_overrides_only_local_store_directories() {
        let config = mobile_config("/data/user/0/com.example.sylphy/files/veilid");

        assert_eq!(config.program_name, "sylphy");
        assert!(
            config
                .protected_store
                .directory
                .ends_with("protected_store")
        );
        assert!(config.table_store.directory.ends_with("table_store"));
        assert!(config.block_store.directory.ends_with("block_store"));
        assert!(config.network.protocol.ws.url.is_none());
    }

    #[test]
    fn classifies_protected_store_without_exposing_native_details() {
        let error = veilid_core::VeilidAPIError::Generic {
            message: "Could not initialize the protected store.".to_owned(),
        };

        assert!(matches!(
            classify_startup_error(&error),
            CoreError::VeilidProtectedStoreFailed
        ));
    }

    #[test]
    fn classifies_rejected_configuration() {
        let error = veilid_core::VeilidAPIError::MissingArgument {
            context: "startup".to_owned(),
            argument: "program_name".to_owned(),
        };

        assert!(matches!(
            classify_startup_error(&error),
            CoreError::VeilidConfigurationFailed
        ));
    }
}
