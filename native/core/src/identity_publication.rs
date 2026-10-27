//! Keep the signed identity format independent of Veilid's 32 KiB value cap.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    blob_transport::CHUNK_BYTES,
    error::{CoreError, CoreResult},
};

pub(crate) const VALUE_BYTES: usize = 32 * 1024;
pub(crate) const MAX_IDENTITY_BYTES: usize = 512 * 1024;
const KIND: &str = "sylphy-identity-blob-v1";
pub(crate) const CACHE_FIELD: &str = "sylphy_identity_blob";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Reference {
    kind: String,
    version: u8,
    size: usize,
    record_key: String,
    chunk_count: u16,
    sha256: [u8; 32],
}

pub(crate) fn encode(
    identity: Vec<u8>,
    put: impl FnOnce(&[u8]) -> CoreResult<(String, u16)>,
) -> CoreResult<Vec<u8>> {
    if identity.is_empty() || identity.len() > MAX_IDENTITY_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    if identity.len() <= VALUE_BYTES {
        return Ok(identity);
    }
    let (record_key, chunk_count) = put(&identity)?;
    let reference = Reference {
        kind: KIND.to_owned(),
        version: 1,
        size: identity.len(),
        record_key,
        chunk_count,
        sha256: Sha256::digest(&identity).into(),
    };
    validate(&reference)?;
    serde_json::to_vec(&reference).map_err(|_| CoreError::Internal)
}

pub(crate) fn decode(
    value: &[u8],
    get: impl FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<Vec<u8>> {
    if value.is_empty() || value.len() > VALUE_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let document: serde_json::Value =
        serde_json::from_slice(value).map_err(|_| CoreError::VerificationFailed)?;
    if document.get("kind").and_then(serde_json::Value::as_str) != Some(KIND) {
        // Original inline identities and share invitations remain unchanged.
        return Ok(value.to_vec());
    }
    let reference: Reference =
        serde_json::from_value(document).map_err(|_| CoreError::VerificationFailed)?;
    validate(&reference)?;
    let identity = get(&reference.record_key, reference.chunk_count)?;
    if identity.len() != reference.size
        || <[u8; 32]>::from(Sha256::digest(&identity)) != reference.sha256
    {
        return Err(CoreError::VerificationFailed);
    }
    // The caller still verifies the original identity signature; references
    // cannot recursively trigger arbitrary further downloads.
    Ok(identity)
}

fn validate(reference: &Reference) -> CoreResult<()> {
    if reference.version != 1 {
        return Err(CoreError::UnsupportedVersion);
    }
    if reference.kind != KIND
        || reference.size <= VALUE_BYTES
        || reference.size > MAX_IDENTITY_BYTES
        || usize::from(reference.chunk_count) != reference.size.div_ceil(CHUNK_BYTES)
        || reference.record_key.is_empty()
        || reference.record_key.len() > 128
    {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}

// The cached reference lives only in the private DHT descriptor, never in the
// signed identity. Repeated publication of identical bytes reuses the blob.
pub(crate) fn cached_value(descriptor: Option<&str>) -> Option<Vec<u8>> {
    let descriptor: serde_json::Value = serde_json::from_str(descriptor?).ok()?;
    let value = descriptor.get(CACHE_FIELD)?.as_str()?;
    if value.len() > VALUE_BYTES {
        return None;
    }
    let reference: Reference = serde_json::from_str(value).ok()?;
    validate(&reference).ok()?;
    Some(value.as_bytes().to_vec())
}

pub(crate) fn matches(value: &[u8], identity: &[u8]) -> bool {
    let Ok(reference) = serde_json::from_slice::<Reference>(value) else {
        return false;
    };
    validate(&reference).is_ok()
        && reference.size == identity.len()
        && reference.sha256 == <[u8; 32]>::from(Sha256::digest(identity))
}

pub(crate) fn blob_reference(value: &[u8]) -> Option<(String, u16)> {
    let reference: Reference = serde_json::from_slice(value).ok()?;
    validate(&reference).ok()?;
    Some((reference.record_key, reference.chunk_count))
}

pub(crate) fn cache_value(descriptor: &str, value: &[u8]) -> CoreResult<String> {
    let mut descriptor: serde_json::Value =
        serde_json::from_str(descriptor).map_err(|_| CoreError::Internal)?;
    let object = descriptor.as_object_mut().ok_or(CoreError::Internal)?;
    if blob_reference(value).is_some() {
        object.insert(
            CACHE_FIELD.to_owned(),
            serde_json::Value::String(
                String::from_utf8(value.to_vec()).map_err(|_| CoreError::Internal)?,
            ),
        );
    } else {
        object.remove(CACHE_FIELD);
    }
    serde_json::to_string(&descriptor).map_err(|_| CoreError::Internal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_identity_round_trips_without_changing_signed_bytes() {
        for size in [VALUE_BYTES + 1, 64 * 1024, MAX_IDENTITY_BYTES] {
            let bytes = vec![42; size];
            let value = encode(bytes.clone(), |data| {
                Ok(("record".into(), data.len().div_ceil(CHUNK_BYTES) as u16))
            })
            .unwrap();
            assert!(value.len() <= VALUE_BYTES);
            assert_eq!(decode(&value, |_, _| Ok(bytes.clone())).unwrap(), bytes);
            assert!(decode(&value, |_, _| Ok(vec![43; size])).is_err());
        }
        let inline = br#"{"version":1}"#.to_vec();
        let value = encode(inline.clone(), |_| {
            panic!("inline publication needs no blob")
        })
        .unwrap();
        assert_eq!(
            decode(&value, |_, _| panic!("inline resolution needs no blob")).unwrap(),
            inline
        );
    }

    #[test]
    fn invalid_reference_is_rejected_before_fetch() {
        let bytes = vec![42; 64 * 1024];
        let value = encode(bytes, |data| {
            Ok(("record".into(), data.len().div_ceil(CHUNK_BYTES) as u16))
        })
        .unwrap();
        for (field, replacement) in [
            ("version", serde_json::json!(2)),
            ("size", serde_json::json!(MAX_IDENTITY_BYTES + 1)),
            ("chunk_count", serde_json::json!(128)),
            ("record_key", serde_json::json!("")),
        ] {
            let mut value: serde_json::Value = serde_json::from_slice(&value).unwrap();
            value[field] = replacement;
            assert!(
                decode(&serde_json::to_vec(&value).unwrap(), |_, _| panic!(
                    "invalid reference fetched"
                ))
                .is_err()
            );
        }
        assert!(
            encode(vec![0; MAX_IDENTITY_BYTES + 1], |_| panic!(
                "oversized identity published"
            ))
            .is_err()
        );
    }

    #[test]
    fn unchanged_identity_reuses_private_blob_reference() {
        let identity = vec![42; 64 * 1024];
        let value = encode(identity.clone(), |data| {
            Ok(("record".into(), data.len().div_ceil(CHUNK_BYTES) as u16))
        })
        .unwrap();
        let descriptor =
            cache_value(r#"{"key":"primary","owner_secret":"private"}"#, &value).unwrap();
        let cached = cached_value(Some(&descriptor)).unwrap();
        assert!(matches(&cached, &identity));
        assert!(!matches(&cached, &vec![43; identity.len()]));
        assert_eq!(blob_reference(&cached).unwrap().0, "record");
        let cleared = cache_value(&descriptor, br#"{"version":1}"#).unwrap();
        assert!(cached_value(Some(&cleared)).is_none());
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&cleared).unwrap()["key"],
            "primary"
        );
    }
}
