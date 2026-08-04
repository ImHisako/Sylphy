use jni::{
    EnvUnowned,
    objects::{JClass, JObject},
};

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_example_sylphy_MainActivity_initializeVeilid<'caller>(
    environment: EnvUnowned<'caller>,
    _: JClass<'caller>,
    context: JObject<'caller>,
) {
    veilid_core::veilid_core_setup_android(environment, context);
}
