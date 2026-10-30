#![forbid(unsafe_op_in_unsafe_fn)]

pub mod account_backup;
mod activity_events;
pub mod app_security;
mod append_log;
mod atomic_file;
mod blob_transport;
pub mod bundle;
mod device_sync;
#[cfg(any(test, feature = "veilid"))]
mod direct_delivery;
pub mod envelope;
pub mod error;
pub mod ffi;
#[cfg(feature = "veilid")]
mod hedged_delivery;
pub mod hybrid;
pub mod identity;
#[cfg(any(test, feature = "veilid"))]
mod identity_publication;
mod invitation;
pub mod messaging_adapter;
#[cfg(any(test, feature = "veilid"))]
mod network_recovery;
mod offline_mailbox;
pub mod peer_identity;
mod performance;
pub mod ratchet_adapter;
pub mod secure_packet;
pub mod vault;
pub mod veilid_adapter;

#[cfg(all(feature = "veilid", target_os = "android"))]
mod android;

pub const CORE_ABI_VERSION: u32 = 21;
pub const PROTOCOL_VERSION: u16 = 1;
