use serde::Serialize;

use crate::error::{CoreError, CoreResult};

#[cfg(feature = "veilid")]
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex, OnceLock},
};

#[cfg(feature = "veilid")]
use crate::envelope::MessageEnvelope;

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
    inbound_envelopes: Arc<Mutex<VecDeque<Vec<u8>>>>,
}

#[cfg(feature = "veilid")]
impl VeilidNode {
    pub async fn start(storage_directory: &str) -> Result<Self, veilid_core::VeilidAPIError> {
        let config = veilid_core::VeilidConfig::new(
            "sylphy",
            "kerberus",
            "app",
            Some(storage_directory),
            Some(storage_directory),
        );
        let inbound_envelopes = Arc::new(Mutex::new(VecDeque::new()));
        let callback_inbox = Arc::clone(&inbound_envelopes);
        let api = veilid_core::api_startup(
            Arc::new(move |update| {
                if let veilid_core::VeilidUpdate::AppMessage(message) = update {
                    enqueue_inbound_envelope(&callback_inbox, message.message());
                }
            }),
            config,
        )
        .await?;
        api.attach().await?;
        Ok(Self {
            api,
            inbound_envelopes,
        })
    }

    pub fn from_started_api(api: veilid_core::VeilidAPI) -> Self {
        Self {
            api,
            inbound_envelopes: Arc::new(Mutex::new(VecDeque::new())),
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
        &self,
    ) -> Result<veilid_core::RouteBlob, veilid_core::VeilidAPIError> {
        self.api.new_private_route().await
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

    pub async fn shutdown(self) {
        self.api.shutdown().await;
    }
}

#[cfg(feature = "veilid")]
const MAX_PENDING_INBOUND_ENVELOPES: usize = 256;

#[cfg(feature = "veilid")]
const MAX_INBOUND_ENVELOPE_BYTES: usize = 32_768;

#[cfg(feature = "veilid")]
fn enqueue_inbound_envelope(inbox: &Mutex<VecDeque<Vec<u8>>>, payload: &[u8]) {
    if payload.is_empty() || payload.len() > MAX_INBOUND_ENVELOPE_BYTES {
        return;
    }
    if let Ok(mut inbox) = inbox.lock()
        && inbox.len() < MAX_PENDING_INBOUND_ENVELOPES
    {
        inbox.push_back(payload.to_vec());
    }
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
pub fn start_node(storage_directory: &str) -> CoreResult<VeilidNodeStatus> {
    if storage_directory.trim().is_empty() {
        return Err(CoreError::InvalidInput);
    }
    std::fs::create_dir_all(storage_directory).map_err(|_| CoreError::Internal)?;

    let mut state = lock_runtime()?;
    if state.node.is_none() {
        let node = state
            .runtime
            .block_on(VeilidNode::start(storage_directory))
            .map_err(|_| CoreError::FeatureUnavailable)?;
        state.node = Some(node);
    }
    let node = state.node.as_ref().ok_or(CoreError::Internal)?;
    state
        .runtime
        .block_on(node.status())
        .map_err(|_| CoreError::FeatureUnavailable)
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
        .map_err(|_| CoreError::FeatureUnavailable)
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
