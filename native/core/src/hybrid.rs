use hkdf::Hkdf;
use ml_kem::{
    MlKem768,
    kem::{Decapsulate, Encapsulate, Kem},
};
use rand_core::OsRng;
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::error::{CoreError, CoreResult};

pub fn derive_root_key(
    classical_shared_secret: &[u8],
    post_quantum_shared_secret: &[u8],
    transcript_hash: &[u8],
) -> CoreResult<Zeroizing<[u8; 32]>> {
    if classical_shared_secret.len() != 32
        || post_quantum_shared_secret.len() != 32
        || transcript_hash.len() != 32
    {
        return Err(CoreError::InvalidInput);
    }
    let mut input_key_material = Zeroizing::new(Vec::with_capacity(64));
    input_key_material.extend_from_slice(classical_shared_secret);
    input_key_material.extend_from_slice(post_quantum_shared_secret);
    let hkdf = Hkdf::<Sha256>::new(Some(transcript_hash), input_key_material.as_ref());
    let mut root_key = Zeroizing::new([0_u8; 32]);
    hkdf.expand(b"sylphy/hybrid-root/v1", root_key.as_mut())
        .map_err(|_| CoreError::Internal)?;
    Ok(root_key)
}

pub fn self_test() -> CoreResult<()> {
    let sender_x25519 = StaticSecret::random_from_rng(OsRng);
    let recipient_x25519 = StaticSecret::random_from_rng(OsRng);
    let sender_classical = sender_x25519.diffie_hellman(&PublicKey::from(&recipient_x25519));
    let recipient_classical = recipient_x25519.diffie_hellman(&PublicKey::from(&sender_x25519));
    if sender_classical.as_bytes() != recipient_classical.as_bytes() {
        return Err(CoreError::VerificationFailed);
    }

    let (decapsulation_key, encapsulation_key) = MlKem768::generate_keypair();
    let (ciphertext, sender_post_quantum) = encapsulation_key.encapsulate();
    let recipient_post_quantum = decapsulation_key.decapsulate(&ciphertext);
    if sender_post_quantum != recipient_post_quantum {
        return Err(CoreError::VerificationFailed);
    }

    let transcript_hash = Sha256::digest(b"sylphy/hybrid-self-test/v1");
    let sender_root = derive_root_key(
        sender_classical.as_bytes(),
        sender_post_quantum.as_ref(),
        transcript_hash.as_ref(),
    )?;
    let recipient_root = derive_root_key(
        recipient_classical.as_bytes(),
        recipient_post_quantum.as_ref(),
        transcript_hash.as_ref(),
    )?;
    if sender_root.as_ref() != recipient_root.as_ref() {
        return Err(CoreError::VerificationFailed);
    }
    Ok(())
}
