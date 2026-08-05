use std::{
    ffi::{CStr, CString, c_char},
    panic::AssertUnwindSafe,
};

use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    CORE_ABI_VERSION, PROTOCOL_VERSION, bundle::PublicBundle, error::CoreError, hybrid, identity,
    messaging_adapter, ratchet_adapter, vault, veilid_adapter,
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
    ListConversations,
    ListMessages {
        conversation_id: String,
    },
    AddContact {
        display_name: String,
        invitation_code: String,
    },
    SendText {
        conversation_id: String,
        plaintext: String,
    },
    SendAttachment {
        conversation_id: String,
        file_name: String,
        bytes_base64: String,
    },
    MarkConversationRead {
        conversation_id: String,
    },
    DeleteConversation {
        conversation_id: String,
    },
    SetContactVerified {
        conversation_id: String,
        verified: bool,
    },
    EnsureIdentity {
        storage_directory: String,
        vault_password: String,
        #[serde(default)]
        display_name: Option<String>,
        #[serde(default)]
        avatar_base64: Option<String>,
    },
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
        CoreRequest::StartVeilid { storage_directory } => {
            messaging_adapter::configure_storage(&storage_directory)?;
            Ok(CoreResponse {
                ok: true,
                code: "ok",
                data: serde_json::to_value(veilid_adapter::start_node(&storage_directory)?)
                    .map_err(|_| CoreError::Internal)?,
            })
        }
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
        CoreRequest::ListConversations => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::list_conversations()?,
        }),
        CoreRequest::ListMessages { conversation_id } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::list_messages(&conversation_id)?,
        }),
        CoreRequest::AddContact {
            display_name,
            invitation_code,
        } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::add_contact(&display_name, &invitation_code)?,
        }),
        CoreRequest::SendText {
            conversation_id,
            plaintext,
        } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::send_text(&conversation_id, &plaintext)?,
        }),
        CoreRequest::SendAttachment {
            conversation_id,
            file_name,
            bytes_base64,
        } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::send_attachment(&conversation_id, &file_name, &bytes_base64)?,
        }),
        CoreRequest::MarkConversationRead { conversation_id } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::mark_conversation_read(&conversation_id)?,
        }),
        CoreRequest::DeleteConversation { conversation_id } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::delete_conversation(&conversation_id)?,
        }),
        CoreRequest::SetContactVerified {
            conversation_id,
            verified,
        } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: messaging_adapter::set_contact_verified(&conversation_id, verified)?,
        }),
        CoreRequest::EnsureIdentity {
            storage_directory,
            vault_password,
            display_name,
            avatar_base64,
        } => Ok(CoreResponse {
            ok: true,
            code: "ok",
            data: identity::ensure_identity(
                &storage_directory,
                &vault_password,
                display_name,
                avatar_base64,
            )?,
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
        CoreError::PlatformNotInitialized => "platform_not_initialized",
        CoreError::VeilidProtectedStoreFailed => "veilid_protected_store_failed",
        CoreError::VeilidLocalStoreFailed => "veilid_local_store_failed",
        CoreError::VeilidConfigurationFailed => "veilid_configuration_failed",
        CoreError::VeilidRestarting => "veilid_restarting",
        CoreError::NetworkStartupFailed => "network_startup_failed",
        CoreError::NetworkAttachFailed => "network_attach_failed",
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
