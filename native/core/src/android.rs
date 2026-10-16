use jni::sys::{jboolean, jint, jlong};
use jni::{EnvUnowned, objects::JObject};
use std::sync::atomic::{AtomicBool, Ordering};

static ANDROID_CONTEXT_READY: AtomicBool = AtomicBool::new(false);

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_MessagingService_waitForInboxEvent(
    _: EnvUnowned<'_>,
    _: JObject<'_>,
    after: jlong,
) -> jlong {
    crate::activity_events::wait(after as u64, 30_000) as jlong
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_MessagingService_wakeEventWaiters(
    _: EnvUnowned<'_>,
    _: JObject<'_>,
) {
    crate::activity_events::notify();
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_SecurityLifecycle_applyEvent(
    _: EnvUnowned<'_>,
    _: JObject<'_>,
    event: jint,
) -> jint {
    std::panic::catch_unwind(|| {
        let Ok(_guard) = crate::ffi::COMMAND_LOCK.lock() else {
            return -1;
        };
        let should_lock = match event {
            0 => {
                return if crate::app_security::close_vault().is_ok() {
                    1
                } else {
                    -1
                };
            }
            1 => crate::app_security::locks_on_background(),
            2 => crate::app_security::locks_on_screen_off(),
            _ => return -1,
        };
        if should_lock {
            return if crate::app_security::lock_vault().is_ok() {
                1
            } else {
                -1
            };
        }
        0
    })
    .unwrap_or(-1)
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
        return -2; // Busy, retry promptly instead of waiting a full background interval.
    };
    if crate::app_security::require_unlocked().is_err() {
        return -3; // Respect the user's background/screen-off locking policy.
    }
    if crate::veilid_adapter::network_available() {
        let _ = crate::veilid_adapter::recover_existing_connection();
        if crate::veilid_adapter::node_status().is_ok_and(|status| {
            status.route_needs_publish
                && status.attachment_state != "detached"
                && status.attachment_state != "attaching"
        }) {
            if let Ok(_account_guard) = crate::ffi::ACCOUNT_STATE_LOCK.try_write() {
                let _ = crate::identity::republish_active_identity();
            }
        }
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

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sylphy_NetworkRecovery_networkChanged(
    _: EnvUnowned<'_>,
    _: JObject<'_>,
    available: jboolean,
) -> jint {
    std::panic::catch_unwind(|| {
        if !available {
            return if crate::veilid_adapter::platform_network_changed(false).is_ok() {
                0
            } else {
                -1
            };
        }
        let Ok(_guard) = crate::ffi::COMMAND_LOCK.try_lock() else {
            return 2;
        };
        if crate::veilid_adapter::platform_network_changed(available).is_err() {
            return -1;
        }
        if available && crate::app_security::require_unlocked().is_ok() {
            let _ = crate::messaging_adapter::network_recovered();
        }
        0
    })
    .unwrap_or(-1)
}
