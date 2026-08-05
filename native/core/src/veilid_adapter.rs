use serde::Serialize;

use crate::error::{CoreError, CoreResult};

use crate::peer_identity::PublishedIdentity;

#[cfg(feature = "veilid")]
use std::{
    collections::VecDeque,
    path::PathBuf,
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
    private_route: Option<veilid_core::RouteBlob>,
}

#[cfg(feature = "veilid")]
impl VeilidNode {
    pub async fn start(storage_directory: &str) -> CoreResult<Self> {
        let config = mobile_config(storage_directory);
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
        .await
        .map_err(|error| classify_startup_error(&error))?;
        if let Err(error) = api.attach().await {
            api.shutdown().await;
            return Err(classify_attach_error(&error));
        }
        Ok(Self {
            api,
            inbound_envelopes,
            private_route: None,
        })
    }

    pub fn from_started_api(api: veilid_core::VeilidAPI) -> Self {
        Self {
            api,
            inbound_envelopes: Arc::new(Mutex::new(VecDeque::new())),
            private_route: None,
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

    pub async fn shutdown(self) {
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
    let state = lock_runtime()?;
    let node = state.node.as_ref().ok_or(CoreError::NetworkStartupFailed)?;
    let routing = node
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let descriptor = if let Some(encoded) = descriptor_json {
        let stored: DHTRecordDescriptor =
            serde_json::from_str(encoded).map_err(|_| CoreError::VerificationFailed)?;
        let _ = state
            .runtime
            .block_on(routing.open_dht_record(stored.key(), stored.owner_keypair()))
            .map_err(|_| CoreError::NetworkStartupFailed)?;
        stored
    } else {
        state
            .runtime
            .block_on(routing.create_dht_record(
                CRYPTO_KIND_VLD0,
                DHTSchema::dflt(1).map_err(|_| CoreError::Internal)?,
                None,
            ))
            .map_err(|_| CoreError::NetworkStartupFailed)?
    };
    let key = descriptor.key();
    state
        .runtime
        .block_on(routing.set_dht_value(key.clone(), 0, bytes, None))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    state
        .runtime
        .block_on(routing.close_dht_record(key.clone()))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
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
    let state = lock_runtime()?;
    let node = state.node.as_ref().ok_or(CoreError::NetworkStartupFailed)?;
    let routing = node
        .routing_context()
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let _ = state
        .runtime
        .block_on(routing.open_dht_record(key.clone(), None))
        .map_err(|_| CoreError::NetworkStartupFailed)?;
    let value = state
        .runtime
        .block_on(routing.get_dht_value(key.clone(), 0, true))
        .map_err(|_| CoreError::NetworkStartupFailed)?
        .ok_or(CoreError::VerificationFailed)?;
    let _ = state.runtime.block_on(routing.close_dht_record(key));
    let identity: PublishedIdentity =
        serde_json::from_slice(value.data()).map_err(|_| CoreError::VerificationFailed)?;
    identity.validate()?;
    Ok(identity)
}

#[cfg(not(feature = "veilid"))]
pub fn resolve_identity(_code: &str) -> CoreResult<PublishedIdentity> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn send_payload(route_blob: &[u8], payload: Vec<u8>) -> CoreResult<()> {
    if route_blob.is_empty() || payload.is_empty() || payload.len() > MAX_INBOUND_ENVELOPE_BYTES {
        return Err(CoreError::InvalidInput);
    }
    let state = lock_runtime()?;
    let node = state.node.as_ref().ok_or(CoreError::NetworkStartupFailed)?;
    let route_id = node
        .api
        .import_remote_private_route(route_blob.to_vec())
        .map_err(|_| CoreError::NetworkAttachFailed)?;
    let result = state.runtime.block_on(async {
        let routing = node.routing_context()?.with_default_safety()?;
        routing
            .app_message(veilid_core::Target::RouteId(route_id.clone()), payload)
            .await
    });
    let _ = node.api.release_private_route(route_id);
    result.map_err(|_| CoreError::NetworkAttachFailed)
}

#[cfg(not(feature = "veilid"))]
pub fn send_payload(_route_blob: &[u8], _payload: Vec<u8>) -> CoreResult<()> {
    Err(CoreError::FeatureUnavailable)
}

#[cfg(feature = "veilid")]
pub fn take_inbound_payloads() -> CoreResult<Vec<Vec<u8>>> {
    let state = lock_runtime()?;
    let node = state.node.as_ref().ok_or(CoreError::NetworkStartupFailed)?;
    let mut inbox = node
        .inbound_envelopes
        .lock()
        .map_err(|_| CoreError::Internal)?;
    Ok(inbox.drain(..).collect())
}

#[cfg(not(feature = "veilid"))]
pub fn take_inbound_payloads() -> CoreResult<Vec<Vec<u8>>> {
    Ok(Vec::new())
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
        assert!(config.network.protocol.wss.url.is_none());
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
