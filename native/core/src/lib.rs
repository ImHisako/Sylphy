#![forbid(unsafe_op_in_unsafe_fn)]

pub mod account_backup;
mod append_log;
mod atomic_file;
pub mod bundle;
mod device_sync;
pub mod envelope;
pub mod error;
pub mod ffi;
pub mod hybrid;
pub mod identity;
pub mod messaging_adapter;
mod offline_mailbox;
pub mod peer_identity;
pub mod ratchet_adapter;
pub mod secure_packet;
pub mod vault;
pub mod veilid_adapter;

#[cfg(all(feature = "veilid", target_os = "android"))]
mod android;

pub const CORE_ABI_VERSION: u32 = 13;
pub const PROTOCOL_VERSION: u16 = 1;
