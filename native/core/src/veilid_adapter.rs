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
        Ok(Self {
            api,
            inbound_envelopes,
            seen_mailbox_slots,
            private_route: None,
            mailbox_task: None,
        })
    }

    pub fn from_started_api(api: veilid_core::VeilidAPI) -> Self {
        Self {
            api,
            inbound_envelopes: Arc::new(Mutex::new(VecDeque::new())),
            seen_mailbox_slots: Arc::new(Mutex::new(HashMap::new())),
            private_route: None,
            mailbox_task: None,
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
                .ok_or(CoreError::VerificationFailed)?;
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

/// Remote mailbox write capabilities are deliberately not accepted here: a
/// capability embedded in a public profile lets any contact overwrite every
/// recipient slot. Offline delivery will be re-enabled only with peer-specific
/// capabilities; the current path fails closed when the private route is down.
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
    Ok(())
}

#[cfg(not(feature = "veilid"))]
pub(crate) fn acknowledge_inbound_payload(_payload: InboundPayload) -> CoreResult<()> {
    Ok(())
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
