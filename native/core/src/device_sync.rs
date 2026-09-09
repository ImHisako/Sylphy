//! Bounded replication transport. The worker owns an account snapshot and
//! never reads or mutates the active account while doing network I/O.
use crate::{
    error::{CoreError, CoreResult},
    peer_identity::MailboxAddress,
    vault, veilid_adapter,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::{
    Mutex,
    mpsc::{self, Receiver, TryRecvError},
};
use zeroize::Zeroizing;

pub(crate) const PREFIX: &[u8] = b"SYLPHY-DEVICE-SYNC-V2\0";
const LEGACY_PREFIX: &[u8] = b"SYLPHY-DEVICE-SYNC-V1\0";
const MAX_BLOB: usize = 3 * 1024 * 1024;
const RETENTION: u64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct BlobPointer {
    pub(crate) version: u8,
    pub(crate) record_key: String,
    pub(crate) chunk_count: u16,
    pub(crate) size: usize,
    pub(crate) digest: Vec<u8>,
    pub(crate) created_at_ms: u64,
}

pub(crate) struct Context {
    pub(crate) key: Zeroizing<[u8; 32]>,
    pub(crate) descriptor: String,
    pub(crate) device_id: u8,
    pub(crate) mailbox: Option<MailboxAddress>,
}

pub(crate) struct Pending {
    pub(crate) id: String,
    pub(crate) encoded: Zeroizing<Vec<u8>>,
    pub(crate) blob: Option<BlobPointer>,
}

pub(crate) struct ResultItem {
    pub(crate) id: String,
    pub(crate) delivered: bool,
    pub(crate) blob: Option<BlobPointer>,
}

type Active = (u64, Receiver<Vec<ResultItem>>);
static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);

pub(crate) fn poll(
    generation: u64,
    prepare: impl FnOnce() -> CoreResult<(Vec<Pending>, Context)>,
) -> Option<Vec<ResultItem>> {
    let mut active = ACTIVE.lock().ok()?;
    if let Some((previous, receiver)) = active.as_ref() {
        if *previous == generation {
            match receiver.try_recv() {
                Ok(results) => {
                    *active = None;
                    return Some(results);
                }
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {}
            }
        }
        *active = None;
    }
    let (pending, context) = prepare().ok()?;
    if pending.is_empty() {
        return None;
    }
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name("sylphy-device-sync".to_owned())
        .spawn(move || {
            let targets = veilid_adapter::resolve_owned_identity(&context.descriptor)
                .and_then(|identity| identity.delivery_devices());
            let results = pending
                .into_iter()
                .map(|mut item| {
                    let delivered = (|| -> CoreResult<()> {
                        let targets = targets
                            .as_ref()
                            .map_err(|_| CoreError::NetworkAttachFailed)?;
                        let targets = targets
                            .iter()
                            .filter(|device| {
                                device
                                    .bundle
                                    .signal_pre_key
                                    .as_ref()
                                    .is_some_and(|key| key.device_id != context.device_id)
                            })
                            .collect::<Vec<_>>();
                        if targets.is_empty() {
                            return Ok(());
                        }
                        let encrypted = vault::seal_with_key(&context.key, &item.encoded)?;
                        let needs_blob = encrypted.len() + LEGACY_PREFIX.len() > 12 * 1024;
                        if needs_blob
                            && targets.iter().any(|device| {
                                !device
                                    .bundle
                                    .capabilities
                                    .iter()
                                    .any(|v| v == "device-sync-blob-v2")
                            })
                        {
                            return Err(CoreError::UnsupportedVersion);
                        }
                        let payload = if needs_blob {
                            let now = now_ms();
                            if item.blob.as_ref().is_none_or(|blob| {
                                blob.created_at_ms.saturating_add(RETENTION) <= now
                            }) {
                                item.blob = Some(publish_reference(
                                    &encrypted,
                                    now,
                                    veilid_adapter::publish_sync_blob,
                                )?);
                            }
                            let encoded =
                                serde_json::to_vec(item.blob.as_ref().ok_or(CoreError::Internal)?)
                                    .map_err(|_| CoreError::Internal)?;
                            let mut payload = PREFIX.to_vec();
                            payload.extend(vault::seal_with_key(&context.key, &encoded)?);
                            payload
                        } else {
                            let mut payload = LEGACY_PREFIX.to_vec();
                            payload.extend(encrypted);
                            payload
                        };
                        let mut failed = false;
                        for target in targets {
                            failed |= veilid_adapter::deliver_payload(
                                &target.route_blob,
                                None,
                                payload.clone(),
                            )
                            .is_err();
                        }
                        if failed {
                            veilid_adapter::store_mailbox_payload(
                                context
                                    .mailbox
                                    .as_ref()
                                    .ok_or(CoreError::FeatureUnavailable)?,
                                &payload,
                            )?;
                        }
                        Ok(())
                    })()
                    .is_ok();
                    ResultItem {
                        id: item.id,
                        delivered,
                        blob: item.blob,
                    }
                })
                .collect();
            let _ = sender.send(results);
        })
        .ok()?;
    *active = Some((generation, receiver));
    None
}

fn publish_reference(
    encrypted: &[u8],
    now: u64,
    publish: impl FnOnce(&[u8]) -> CoreResult<(String, u16)>,
) -> CoreResult<BlobPointer> {
    if encrypted.is_empty() || encrypted.len() > MAX_BLOB {
        return Err(CoreError::LimitExceeded);
    }
    let (record_key, chunk_count) = publish(encrypted)?;
    Ok(BlobPointer {
        version: 2,
        record_key,
        chunk_count,
        size: encrypted.len(),
        digest: Sha256::digest(encrypted).to_vec(),
        created_at_ms: now,
    })
}

pub(crate) fn open_reference(
    key: &[u8; 32],
    encrypted: &[u8],
    fetch: impl FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
) -> CoreResult<Zeroizing<Vec<u8>>> {
    if encrypted.len() > 4096 {
        return Err(CoreError::LimitExceeded);
    }
    let decoded = vault::open_with_key(key, encrypted)?;
    let pointer: BlobPointer =
        serde_json::from_slice(&decoded).map_err(|_| CoreError::InvalidInput)?;
    if pointer.version != 2
        || pointer.record_key.is_empty()
        || pointer.record_key.len() > 1024
        || pointer.chunk_count == 0
        || pointer.chunk_count > 128
        || pointer.size > MAX_BLOB
        || pointer.digest.len() != 32
    {
        return Err(CoreError::InvalidInput);
    }
    let blob = fetch(&pointer.record_key, pointer.chunk_count)?;
    if blob.len() != pointer.size || Sha256::digest(&blob).as_slice() != pointer.digest {
        return Err(CoreError::AuthenticationFailed);
    }
    vault::open_with_key(key, &blob)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|v| v.as_millis() as u64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pending_network_work_does_not_rebuild_the_replication_batch() {
        let _guard = crate::identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let (sender, receiver) = mpsc::channel();
        *ACTIVE.lock().unwrap() = Some((42, receiver));
        assert!(poll(42, || panic!("must not copy or encrypt while busy")).is_none());
        sender
            .send(vec![ResultItem {
                id: "done".to_owned(),
                delivered: true,
                blob: None,
            }])
            .unwrap();
        let result = poll(42, || panic!("collect results before preparing more work")).unwrap();
        assert_eq!(result[0].id, "done");
        assert!(result[0].delivered);
        assert!(ACTIVE.lock().unwrap().is_none());
    }

    #[test]
    fn replicates_large_content_by_authenticated_small_reference() {
        let key = [42; 32];
        let content = vec![123; 1024 * 1024];
        let encrypted = vault::seal_with_key(&key, &content).unwrap();
        let pointer = publish_reference(&encrypted, 1, |bytes| {
            assert_eq!(bytes, encrypted);
            Ok(("test-record".to_owned(), 44))
        })
        .unwrap();
        let packet = vault::seal_with_key(&key, &serde_json::to_vec(&pointer).unwrap()).unwrap();
        assert!(packet.len() + PREFIX.len() < 4096);
        assert_eq!(
            &*open_reference(&key, &packet, |_, _| Ok(encrypted.clone())).unwrap(),
            &content
        );
        assert!(
            open_reference(&key, &packet, |_, _| {
                let mut changed = encrypted.clone();
                changed[50] ^= 1;
                Ok(changed)
            })
            .is_err()
        );
        assert!(
            open_reference(&[43; 32], &packet, |_, _| panic!(
                "must authenticate before fetch"
            ))
            .is_err()
        );
    }
}
