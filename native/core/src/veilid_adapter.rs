use serde::Serialize;

#[cfg(feature = "veilid")]
use std::sync::Arc;

#[cfg(feature = "veilid")]
use crate::{envelope::MessageEnvelope, error::CoreError};

#[derive(Debug, Serialize)]
pub struct VeilidCapabilityStatus {
    pub compiled: bool,
    pub transport_contract: &'static str,
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
}

#[cfg(feature = "veilid")]
impl VeilidNode {
    pub async fn start(
        storage_directory: &str,
    ) -> Result<Self, veilid_core::VeilidAPIError> {
        let config = veilid_core::VeilidConfig::new(
            "sylphy",
            "kerberus",
            "app",
            Some(storage_directory),
            Some(storage_directory),
        );
        let api = veilid_core::api_startup(Arc::new(|_| {}), config).await?;
        api.attach().await?;
        Ok(Self { api })
    }

    pub fn from_started_api(api: veilid_core::VeilidAPI) -> Self {
        Self { api }
    }

    pub async fn attach(&self) -> Result<(), veilid_core::VeilidAPIError> {
        self.api.attach().await
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
        self.api.import_remote_private_route(route_blob).await
    }

    pub async fn send_envelope(
        &self,
        route_id: veilid_core::RouteId,
        envelope: &MessageEnvelope,
    ) -> Result<(), veilid_core::VeilidAPIError> {
        let payload = serde_json::to_vec(envelope)
            .map_err(|_| veilid_core::VeilidAPIError::generic(CoreError::Internal))?;
        if payload.len() > 32_768 {
            return Err(veilid_core::VeilidAPIError::generic(CoreError::LimitExceeded));
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
