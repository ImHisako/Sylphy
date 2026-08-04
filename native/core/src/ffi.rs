use std::{
    ffi::{CStr, CString, c_char},
    panic::AssertUnwindSafe,
};

use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    CORE_ABI_VERSION, PROTOCOL_VERSION, bundle::PublicBundle, error::CoreError, hybrid,
    ratchet_adapter, vault, veilid_adapter,
};

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum CoreRequest {
    Status,
    StartVeilid {
        storage_directory: String,
    },
    VeilidStatus,
    StopVeilid,
    ValidatePublicBundle {
        bundle: PublicBundle,
    },
    VaultRoundTrip {
        password: String,
        value_base64: String,
    },
    HybridSelfTest,
    RatchetSelfTest,
}

#[derive(Debug, Serialize)]
struct CoreResponse {
    ok: bool,
    code: &'static str,
    data: Value,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sylphy_core_abi_version() -> u32 {
    CORE_ABI_VERSION
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sylphy_core_call(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let request_text = if request.is_null() {
            Err(CoreError::InvalidInput)
        } else {
            unsafe { CStr::from_ptr(request) }
                .to_str()
                .map(str::to_owned)
                .map_err(|_| CoreError::InvalidInput)
        };
        match request_text.and_then(|body| dispatch(&body)) {
            Ok(response) => serialize_response(response),
            Err(error) => serialize_response(error_response(error)),
        }
    }));
    match result {
        Ok(response) => response,
        Err(_) => serialize_response(error_response(CoreError::Internal)),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sylphy_core_free_string(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

fn dispatch(body: &str) -> Result<CoreResponse, CoreError> {
    let request: CoreRequest = serde_json::from_str(body).map_err(|_| CoreError::InvalidInput)?;
    match request {
        CoreRequest::Status => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: json!({
                "abi_version": CORE_ABI_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                "veilid": veilid_adapter::capability_status(),
                "veilid_node": veilid_adapter::node_status()?,
                "security_profile": "argon2id+xchacha20poly1305+ed25519+x25519+mlkem768",
                "ratchet": ratchet_adapter::capability_status(),
            }),
        }),
        CoreRequest::StartVeilid { storage_directory } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: serde_json::to_value(veilid_adapter::start_node(&storage_directory)?)
                .map_err(|_| CoreError::Internal)?,
        }),
        CoreRequest::VeilidStatus => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: serde_json::to_value(veilid_adapter::node_status()?)
                .map_err(|_| CoreError::Internal)?,
        }),
        CoreRequest::StopVeilid => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: serde_json::to_value(veilid_adapter::stop_node()?)
                .map_err(|_| CoreError::Internal)?,
        }),
        CoreRequest::ValidatePublicBundle { bundle } => {
            bundle.validate()?;
            Ok(CoreResponse {
                ok: true,
                code: "ok",
                data: json!({"validated": true}),
            })
        }
        CoreRequest::VaultRoundTrip {
            password,
            value_base64,
        } => {
            let plaintext = STANDARD_NO_PAD
                .decode(value_base64)
                .map_err(|_| CoreError::InvalidInput)?;
            let record = vault::seal(&password, &plaintext)?;
            let restored = vault::open(&password, &record)?;
            if restored.as_slice() != plaintext.as_slice() {
                return Err(CoreError::VerificationFailed);
            }
            Ok(CoreResponse {
                ok: true,
                code: "ok",
                data: json!({"record_bytes": record.len()}),
            })
        }
        CoreRequest::HybridSelfTest => {
            hybrid::self_test()?;
            Ok(CoreResponse {
                ok: true,
                code: "ok",
                data: json!({"hybrid_handshake": "verified"}),
            })
        }
        CoreRequest::RatchetSelfTest => {
            ratchet_adapter::self_test()?;
            Ok(CoreResponse {
                ok: true,
                code: "ok",
                data: json!({
                    "double_ratchet": "verified",
                    "out_of_order_delivery": "verified",
                    "provider": ratchet_adapter::capability_status().provider,
                }),
            })
        }
    }
}

fn error_response(error: CoreError) -> CoreResponse {
    let code = match error {
        CoreError::InvalidInput => "invalid_input",
        CoreError::UnsupportedVersion => "unsupported_version",
        CoreError::AuthenticationFailed => "authentication_failed",
        CoreError::VerificationFailed => "verification_failed",
        CoreError::LimitExceeded => "limit_exceeded",
        CoreError::FeatureUnavailable => "feature_unavailable",
        CoreError::Internal => "internal_error",
    };
    CoreResponse {
        ok: false,
        code,
        data: Value::Null,
    }
}

fn serialize_response(response: CoreResponse) -> *mut c_char {
    let serialized = serde_json::to_string(&response)
        .unwrap_or_else(|_| "{\"ok\":false,\"code\":\"internal_error\",\"data\":null}".to_owned());
    CString::new(serialized)
        .unwrap_or_else(|_| {
            CString::new("{\"ok\":false,\"code\":\"internal_error\",\"data\":null}")
                .expect("static JSON")
        })
        .into_raw()
}
