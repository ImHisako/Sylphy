#![forbid(unsafe_op_in_unsafe_fn)]

pub mod bundle;
pub mod envelope;
pub mod error;
pub mod ffi;
pub mod hybrid;
pub mod messaging_adapter;
pub mod ratchet_adapter;
pub mod vault;
pub mod veilid_adapter;

#[cfg(all(feature = "veilid", target_os = "android"))]
mod android;

pub const CORE_ABI_VERSION: u32 = 3;
pub const PROTOCOL_VERSION: u16 = 1;
