use jni::sys::{jboolean, jint};
use jni::{EnvUnowned, objects::JObject};
use std::sync::atomic::{AtomicBool, Ordering};

static ANDROID_CONTEXT_READY: AtomicBool = AtomicBool::new(false);

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_MainActivity_lockVaultOnBackground(
    _: EnvUnowned<'_>,
    _: JObject<'_>,
) -> jboolean {
    if let Ok(_guard) = crate::ffi::COMMAND_LOCK.lock() {
        if crate::app_security::locks_on_background() {
            let _ = crate::app_security::lock_vault();
            return true;
        }
    }
    false
}

pub fn is_context_ready() -> bool {
    ANDROID_CONTEXT_READY.load(Ordering::Acquire)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_MessagingService_syncInbound(
    _: EnvUnowned<'_>,
    _: JObject<'_>,
) -> jint {
    if !is_context_ready() {
        return -1;
    }
    let Ok(_command_guard) = crate::ffi::COMMAND_LOCK.try_lock() else {
        return 0;
    };
    if crate::app_security::require_unlocked().is_err() {
        return 0;
    }
    crate::messaging_adapter::sync_inbound_messages()
        .ok()
        .and_then(|value| {
            let count = value.get("persisted")?.as_u64()?.min(0x3fffffff) as jint;
            Some(
                count
                    | if value
                        .get("pin_notification")
                        .and_then(serde_json::Value::as_bool)
                        == Some(true)
                    {
                        0x40000000
                    } else {
                        0
                    },
            )
        })
        .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_MainActivity_initializeVeilid<'caller>(
    environment: EnvUnowned<'caller>,
    _: JObject<'caller>,
    context: JObject<'caller>,
) {
    veilid_core::veilid_core_setup_android(environment, context);
    ANDROID_CONTEXT_READY.store(true, Ordering::Release);
}
