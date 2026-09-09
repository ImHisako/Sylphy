use sylphy_core::{
    bundle::{SignalPreKeyBundle, generate_bundle_for_test},
    envelope::{EnvelopeMetadata, EnvelopeType, open, seal},
    hybrid, vault,
};

fn metadata() -> EnvelopeMetadata {
    EnvelopeMetadata {
        version: 1,
        message_type: EnvelopeType::Message,
        conversation_id: vec![7_u8; 16],
        sender_identity_key_id: vec![1_u8; 16],
        recipient_identity_key_id: vec![2_u8; 16],
        session_id: vec![3_u8; 16],
        timestamp_logical: 1,
        ratchet_header: vec![4_u8; 12],
        attachment_refs: vec![],
    }
}

#[test]
fn vault_rejects_wrong_password() {
    let record = vault::seal("correct horse battery staple", b"private data").expect("vault seal");
    assert_eq!(
        vault::open("correct horse battery staple", &record)
            .expect("vault open")
            .as_slice(),
        b"private data"
    );
    assert!(vault::open("wrong password", &record).is_err());
}

#[test]
fn public_bundle_detects_tampering() {
    let bundle = generate_bundle_for_test(2_000_000_000_000);
    bundle.validate().expect("valid signed bundle");
    let mut modified = bundle;
    modified.signed_prekey_x25519[0] ^= 1;
    assert!(modified.validate().is_err());
}

#[test]
fn signal_bundle_rejects_device_ids_outside_libsignal_range() {
    let mut bundle = SignalPreKeyBundle {
        registration_id: 1,
        device_id: 1,
        signed_pre_key_id: 1,
        signed_pre_key_public: vec![1; 33],
        signed_pre_key_signature: vec![2; 64],
        kyber_pre_key_id: 1,
        kyber_pre_key_public: vec![3; 1569],
        kyber_pre_key_signature: vec![4; 64],
        identity_key: vec![5; 33],
    };
    for device_id in 0..=u8::MAX {
        bundle.device_id = device_id;
        let valid = bundle.validate().is_ok();
        assert_eq!(valid, (1..=127).contains(&device_id), "device {device_id}");
        #[cfg(feature = "signal-ratchet")]
        assert_eq!(
            valid,
            libsignal_protocol::DeviceId::new(device_id).is_ok(),
            "libsignal device {device_id}"
        );
    }
}

#[test]
fn hybrid_key_agreement_matches() {
    hybrid::self_test().expect("hybrid shared secret agreement");
}

#[test]
fn envelope_binds_metadata_as_aad() {
    let key = [8_u8; 32];
    let envelope = seal(&key, metadata(), b"message").expect("seal envelope");
    assert_eq!(
        open(&key, &envelope).expect("open envelope").as_slice(),
        b"message"
    );
    let mut altered = envelope;
    altered.metadata.timestamp_logical = 2;
    assert!(open(&key, &altered).is_err());
}
