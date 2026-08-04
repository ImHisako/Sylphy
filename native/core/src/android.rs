use jni::{EnvUnowned, objects::JObject};
use std::sync::atomic::{AtomicBool, Ordering};

static ANDROID_CONTEXT_READY: AtomicBool = AtomicBool::new(false);

pub fn is_context_ready() -> bool {
    ANDROID_CONTEXT_READY.load(Ordering::Acquire)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_example_sylphy_MainActivity_initializeVeilid<'caller>(
    environment: EnvUnowned<'caller>,
    _: JObject<'caller>,
    context: JObject<'caller>,
) {
    veilid_core::veilid_core_setup_android(environment, context);
    ANDROID_CONTEXT_READY.store(true, Ordering::Release);
}
