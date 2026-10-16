//! Rotating, signed share records point to stable account discovery records.
use crate::error::{CoreError, CoreResult};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

pub const MIN_INTERVAL_SECONDS: u64 = 3600;
pub const MAX_INTERVAL_SECONDS: u64 = 365 * 24 * 3600;
const MAX_DESCRIPTOR_BYTES: usize = 16 * 1024;
pub const MAX_PENDING_REVOCATIONS: usize = 16;

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct InvitationState {
    pub descriptor_json: Option<String>,
    pub pending_revocations: Vec<String>,
    pub interval_seconds: u64,
    pub changed_at_ms: u64,
}
impl Drop for InvitationState {
    fn drop(&mut self) {
        self.descriptor_json.zeroize();
        self.pending_revocations.zeroize();
    }
}
pub fn validate_interval(seconds: u64) -> CoreResult<()> {
    if seconds != 0 && !(MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(&seconds) {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}
impl InvitationState {
    pub fn validate(&self) -> CoreResult<()> {
        validate_interval(self.interval_seconds)?;
        if self.pending_revocations.len() > MAX_PENDING_REVOCATIONS
            || self
                .descriptor_json
                .iter()
                .chain(self.pending_revocations.iter())
                .any(|value| value.is_empty() || value.len() > MAX_DESCRIPTOR_BYTES)
        {
            return Err(CoreError::VerificationFailed);
        }
        Ok(())
    }
    pub fn next_rotation_ms(&self) -> Option<u64> {
        (self.interval_seconds != 0).then(|| {
            self.changed_at_ms
                .saturating_add(self.interval_seconds * 1000)
        })
    }
    pub fn update(&mut self, now_ms: u64, interval: Option<u64>, force: bool) -> CoreResult<bool> {
        self.validate()?;
        if let Some(seconds) = interval {
            validate_interval(seconds)?;
            self.interval_seconds = seconds;
        }
        let rotate = force
            || self.descriptor_json.is_none()
            || self
                .next_rotation_ms()
                .is_some_and(|deadline| now_ms >= deadline);
        if rotate {
            self.changed_at_ms = now_ms;
        }
        Ok(rotate)
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct ShareInvitation {
    pub kind: String,
    version: u16,
    pub discovery_code: String,
    identity_ed25519: Vec<u8>,
    expires_at_ms: u64,
    signature: Vec<u8>,
}
impl ShareInvitation {
    pub fn new(
        signing_key: &SigningKey,
        discovery_code: String,
        expires_at_ms: u64,
    ) -> CoreResult<Self> {
        let mut value = Self {
            kind: "sylphy-invitation-v1".to_owned(),
            version: 1,
            discovery_code,
            identity_ed25519: signing_key.verifying_key().to_bytes().to_vec(),
            expires_at_ms,
            signature: Vec::new(),
        };
        value.signature = signing_key.sign(&value.payload()?).to_bytes().to_vec();
        Ok(value)
    }
    fn payload(&self) -> CoreResult<Vec<u8>> {
        if self.kind != "sylphy-invitation-v1"
            || self.version != 1
            || self.discovery_code.len() > 100
            || !self.discovery_code.starts_with("sylphy:VLD")
            || self.discovery_code.contains('#')
            || self.identity_ed25519.len() != 32
        {
            return Err(CoreError::InvalidInput);
        }
        let mut bytes = b"sylphy/share-invitation/v1".to_vec();
        bytes.extend_from_slice(&self.version.to_be_bytes());
        bytes.extend_from_slice(&(self.discovery_code.len() as u32).to_be_bytes());
        bytes.extend_from_slice(self.discovery_code.as_bytes());
        bytes.extend_from_slice(&self.identity_ed25519);
        bytes.extend_from_slice(&self.expires_at_ms.to_be_bytes());
        Ok(bytes)
    }
    pub fn verify_signature(&self, now_ms: u64) -> CoreResult<()> {
        self.validate(now_ms, &self.identity_ed25519)
    }

    pub fn validate(&self, now_ms: u64, expected_identity: &[u8]) -> CoreResult<()> {
        if expected_identity != self.identity_ed25519
            || (self.expires_at_ms != 0 && now_ms >= self.expires_at_ms)
        {
            return Err(CoreError::VerificationFailed);
        }
        let payload = self.payload()?;
        let key_bytes: [u8; 32] = self
            .identity_ed25519
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::InvalidInput)?;
        let key = VerifyingKey::from_bytes(&key_bytes).map_err(|_| CoreError::InvalidInput)?;
        let signature =
            Signature::from_slice(&self.signature).map_err(|_| CoreError::InvalidInput)?;
        key.verify(&payload, &signature)
            .map_err(|_| CoreError::VerificationFailed)
    }
}
/// Resolve one signed share record, or a legacy discovery record. The supplied
/// resolver reads only PublishedIdentity, so chains and cycles are rejected.
#[cfg(any(test, feature = "veilid"))]
pub(crate) fn resolve_record(
    code: &str,
    bytes: &[u8],
    now_ms: u64,
    resolve_discovery: impl FnOnce(&str) -> CoreResult<crate::peer_identity::PublishedIdentity>,
) -> CoreResult<(crate::peer_identity::PublishedIdentity, String)> {
    use crate::peer_identity::PublishedIdentity;
    if bytes.len() > 32 * 1024 {
        return Err(CoreError::LimitExceeded);
    }
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| CoreError::VerificationFailed)?;
    if value.get("kind").is_some() {
        let invitation: ShareInvitation =
            serde_json::from_value(value).map_err(|_| CoreError::VerificationFailed)?;
        invitation.verify_signature(now_ms)?;
        let identity = resolve_discovery(&invitation.discovery_code)?;
        identity.validate()?;
        invitation.validate(now_ms, &identity.bundle.identity_ed25519)?;
        Ok((identity, invitation.discovery_code))
    } else {
        let identity: PublishedIdentity =
            serde_json::from_value(value).map_err(|_| CoreError::VerificationFailed)?;
        identity.validate()?;
        Ok((identity, code.trim().to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_core::OsRng;
    fn published(key: &SigningKey) -> crate::peer_identity::PublishedIdentity {
        use crate::bundle::{PublicBundle, SignalPreKeyBundle};
        let prekey = SignalPreKeyBundle {
            registration_id: 1,
            device_id: 1,
            signed_pre_key_id: 1,
            signed_pre_key_public: vec![1; 33],
            signed_pre_key_signature: vec![2; 64],
            kyber_pre_key_id: 1,
            kyber_pre_key_public: vec![3; 1184],
            kyber_pre_key_signature: vec![4; 64],
            identity_key: vec![5; 33],
        };
        let bundle =
            PublicBundle::new_signed(key, &[1; 32], &[2; 1184], 99999, Some(prekey)).unwrap();
        crate::peer_identity::PublishedIdentity::new(key, bundle, vec![1], Default::default(), None)
            .unwrap()
    }

    #[test]
    fn imports_use_stable_discovery_and_reject_expired_or_substituted_records() {
        let key = SigningKey::generate(&mut OsRng);
        let identity = published(&key);
        let invite = ShareInvitation::new(&key, "sylphy:VLD0:stable".into(), 5000).unwrap();
        let bytes = serde_json::to_vec(&invite).unwrap();
        let (resolved, discovery) = resolve_record("sylphy:VLD0:rotating", &bytes, 4999, |code| {
            assert_eq!(code, "sylphy:VLD0:stable");
            Ok(identity.clone())
        })
        .unwrap();
        assert_eq!(discovery, "sylphy:VLD0:stable");
        assert_eq!(
            resolved.bundle.identity_ed25519,
            identity.bundle.identity_ed25519
        );
        assert!(
            resolve_record("ignored", &bytes, 5000, |_| panic!(
                "expired records must fail before discovery"
            ))
            .is_err()
        );
        let other = published(&SigningKey::generate(&mut OsRng));
        assert!(resolve_record("ignored", &bytes, 4999, |_| Ok(other)).is_err());
        let legacy = serde_json::to_vec(&identity).unwrap();
        let (_, discovery) = resolve_record("sylphy:VLD0:legacy", &legacy, 4999, |_| {
            panic!("legacy records are direct")
        })
        .unwrap();
        assert_eq!(discovery, "sylphy:VLD0:legacy");
        assert!(resolve_record("ignored", &vec![0; 32769], 4999, |_| unreachable!()).is_err());
    }

    #[test]
    fn invitation_is_signed_expiring_and_bound_to_the_account() {
        let key = SigningKey::generate(&mut OsRng);
        let identity = key.verifying_key().to_bytes();
        let invite = ShareInvitation::new(&key, "sylphy:VLD0:example".into(), 5000).unwrap();
        invite.validate(4999, &identity).unwrap();
        assert!(invite.validate(5000, &identity).is_err());
        assert!(invite.validate(4999, &[0; 32]).is_err());
        let mut tampered = invite.clone();
        tampered.discovery_code.push('x');
        assert!(tampered.validate(4999, &identity).is_err());
        tampered = invite.clone();
        tampered.expires_at_ms = 0;
        assert!(tampered.validate(5001, &identity).is_err());
        tampered = invite;
        tampered.version = 2;
        assert!(tampered.validate(4999, &identity).is_err());
        let revoked = ShareInvitation::new(&key, "sylphy:VLD0:example".into(), 1).unwrap();
        assert!(revoked.validate(2, &identity).is_err());
        let manual = ShareInvitation::new(&key, "sylphy:VLD0:example".into(), 0).unwrap();
        manual.validate(u64::MAX, &identity).unwrap();
    }
    #[test]
    fn rotation_deadlines_persist_and_manual_changes_reset_the_timer() {
        let mut state = InvitationState::default();
        assert!(state.update(1000, Some(3600), false).unwrap());
        state.descriptor_json = Some("encrypted-descriptor".into());
        assert!(!state.update(2000, None, false).unwrap());
        assert_eq!(state.next_rotation_ms(), Some(3_601_000));
        assert!(state.update(3_601_000, None, false).unwrap());
        assert!(state.update(3_601_002, None, true).unwrap());
        assert_eq!(state.next_rotation_ms(), Some(7_201_002));
        assert!(!state.update(3_601_003, Some(0), false).unwrap());
        assert_eq!(state.next_rotation_ms(), None);
        let restored: InvitationState =
            serde_json::from_slice(&serde_json::to_vec(&state).unwrap()).unwrap();
        assert_eq!(restored.changed_at_ms, state.changed_at_ms);
        assert!(state.update(4_000_000, Some(1), false).is_err());
        assert!(
            state
                .update(4_000_000, Some(MAX_INTERVAL_SECONDS + 1), false)
                .is_err()
        );
        state.pending_revocations = vec!["x".into(); MAX_PENDING_REVOCATIONS + 1];
        assert!(state.validate().is_err());
    }
}
