#![forbid(unsafe_op_in_unsafe_fn)]

pub mod bundle;
pub mod envelope;
pub mod error;
pub mod ffi;
pub mod hybrid;
pub mod vault;
pub mod veilid_adapter;

pub const CORE_ABI_VERSION: u32 = 1;
pub const PROTOCOL_VERSION: u16 = 1;
