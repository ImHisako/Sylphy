//! Split encrypted blobs across bounded DHT records (Veilid caps each at 1 MiB).
use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};

use crate::error::{CoreError, CoreResult};

pub(crate) const MAX_ATTACHMENT_BYTES: usize = 2 * 1024 * 1024;
pub(crate) const CHUNK_BYTES: usize = 24 * 1024;
const RECORD_CHUNKS: u16 = 32;
#[cfg(any(feature = "veilid", test))]
const RECORD_BYTES: usize = CHUNK_BYTES * RECORD_CHUNKS as usize;
const PREFIX: &str = "sylphy-blob-v2:";
pub(crate) const MAX_CHUNKS: u16 = 128;

#[cfg(any(feature = "veilid", test))]
pub(crate) fn publish(
    data: &[u8],
    max_bytes: usize,
    mut put: impl FnMut(&[u8]) -> CoreResult<String>,
    mut remove: impl FnMut(&str),
) -> CoreResult<(String, u16)> {
    if data.is_empty() || data.len() > max_bytes || data.len() > CHUNK_BYTES * MAX_CHUNKS as usize {
        return Err(CoreError::LimitExceeded);
    }
    let count = data.len().div_ceil(CHUNK_BYTES) as u16;
    let mut keys = Vec::new();
    for part in data.chunks(RECORD_BYTES) {
        match put(part) {
            Ok(key) => keys.push(key),
            Err(error) => {
                for key in &keys {
                    remove(key);
                }
                return Err(error);
            }
        }
    }
    if keys.len() == 1 {
        return Ok((keys.remove(0), count));
    }
    let encoded = serde_json::to_vec(&keys).map_err(|_| CoreError::Internal)?;
    Ok((
        format!("{PREFIX}{}", STANDARD_NO_PAD.encode(encoded)),
        count,
    ))
}

pub(crate) fn records(reference: &str, count: u16) -> CoreResult<Vec<(String, u16)>> {
    if reference.is_empty() || reference.len() > 1024 || count == 0 || count > MAX_CHUNKS {
        return Err(CoreError::InvalidInput);
    }
    let Some(encoded) = reference.strip_prefix(PREFIX) else {
        // Legacy single-record references remain readable.
        return Ok(vec![(reference.to_owned(), count)]);
    };
    let keys: Vec<String> = serde_json::from_slice(
        &STANDARD_NO_PAD
            .decode(encoded)
            .map_err(|_| CoreError::InvalidInput)?,
    )
    .map_err(|_| CoreError::InvalidInput)?;
    if keys.len() < 2
        || keys.len() != usize::from(count.div_ceil(RECORD_CHUNKS))
        || keys
            .iter()
            .any(|key| key.is_empty() || key.len() > 128 || key.starts_with(PREFIX))
        || keys
            .iter()
            .enumerate()
            .any(|(i, key)| keys[..i].contains(key))
    {
        return Err(CoreError::InvalidInput);
    }
    Ok(keys
        .into_iter()
        .enumerate()
        .map(|(i, key)| (key, (count - i as u16 * RECORD_CHUNKS).min(RECORD_CHUNKS)))
        .collect())
}

#[cfg(any(feature = "veilid", test))]
pub(crate) fn fetch(
    reference: &str,
    count: u16,
    max_bytes: usize,
    mut get: impl FnMut(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<Vec<u8>> {
    if count == 0 || usize::from(count) > max_bytes.div_ceil(CHUNK_BYTES) {
        return Err(CoreError::InvalidInput);
    }
    let records = records(reference, count)?;
    let mut data = Vec::new();
    for (index, (key, chunks)) in records.iter().enumerate() {
        let part = get(key, *chunks)?;
        if part.is_empty()
            || part.len() > usize::from(*chunks) * CHUNK_BYTES
            || data.len() + part.len() > max_bytes
            || (index + 1 < records.len() && part.len() != RECORD_BYTES)
        {
            return Err(CoreError::LimitExceeded);
        }
        data.extend_from_slice(&part);
    }
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn large_blobs_round_trip_with_bounded_records() {
        for size in [
            700 * 1024,
            1024 * 1024,
            MAX_ATTACHMENT_BYTES + 16,
            3 * 1024 * 1024,
        ] {
            let data = vec![42; size];
            let mut parts = Vec::new();
            let (key, count) = publish(
                &data,
                3 * 1024 * 1024,
                |part| {
                    assert!(part.len() <= RECORD_BYTES);
                    parts.push(part.to_vec());
                    Ok(format!("record-{}", parts.len() - 1))
                },
                |_| panic!("unexpected cleanup"),
            )
            .unwrap();
            let restored = fetch(&key, count, 3 * 1024 * 1024, |key, chunks| {
                let index: usize = key.strip_prefix("record-").unwrap().parse().unwrap();
                assert_eq!(
                    parts[index].len().div_ceil(CHUNK_BYTES),
                    usize::from(chunks)
                );
                Ok(parts[index].clone())
            })
            .unwrap();
            assert_eq!(restored, data);
        }
    }

    #[test]
    fn partial_publish_is_cleaned_up() {
        let mut removed = Vec::new();
        let mut calls = 0;
        assert!(
            publish(
                &vec![0; MAX_ATTACHMENT_BYTES],
                MAX_ATTACHMENT_BYTES,
                |_| {
                    calls += 1;
                    if calls == 2 {
                        return Err(CoreError::NetworkAttachFailed);
                    }
                    Ok("first".to_owned())
                },
                |key| removed.push(key.to_owned())
            )
            .is_err()
        );
        assert_eq!(removed, ["first"]);
    }

    #[test]
    fn malformed_manifests_fail_before_network_io() {
        for keys in [
            vec!["a"],
            vec!["a", "a"],
            vec!["a", "b", "c"],
            vec!["", "b"],
        ] {
            let reference = format!(
                "{PREFIX}{}",
                STANDARD_NO_PAD.encode(serde_json::to_vec(&keys).unwrap())
            );
            assert!(
                fetch(&reference, 33, 3 * 1024 * 1024, |_, _| panic!(
                    "invalid manifest"
                ))
                .is_err()
            );
        }
        assert!(
            fetch("legacy", 129, 3 * 1024 * 1024, |_, _| panic!(
                "invalid count"
            ))
            .is_err()
        );
    }
}
