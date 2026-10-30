//! Race the same durable ciphertext over direct delivery and an offline mailbox.
//! Both operations run inside the existing bounded outbox slot. Dropping the
//! losing future never means rolling back a remote delivery; receiver dedup applies.
use crate::error::CoreResult;
use std::{future::Future, time::Duration};

pub(crate) async fn deliver(
    direct: impl Future<Output = CoreResult<()>>,
    offline: impl Future<Output = CoreResult<()>>,
    grace: Duration,
) -> CoreResult<()> {
    tokio::pin!(direct, offline);
    tokio::select! {
        result = &mut direct => {
            if result.is_ok() { return result; }
            return offline.await;
        }
        _ = tokio::time::sleep(grace) => {}
    }
    tokio::select! {
        result = &mut direct => if result.is_ok() { result } else { offline.await },
        result = &mut offline => if result.is_ok() { result } else { direct.await },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::CoreError;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
    }
    #[test]
    fn fast_direct_does_not_start_offline_and_fast_failure_does_not_wait_for_grace() {
        runtime().block_on(async {
            let called = AtomicBool::new(false);
            deliver(
                async { Ok(()) },
                async {
                    called.store(true, Ordering::Relaxed);
                    Ok(())
                },
                Duration::from_secs(1),
            )
            .await
            .unwrap();
            assert!(!called.load(Ordering::Relaxed));
            deliver(
                async { Err(CoreError::NetworkAttachFailed) },
                async {
                    called.store(true, Ordering::Relaxed);
                    Ok(())
                },
                Duration::from_secs(1),
            )
            .await
            .unwrap();
            assert!(called.load(Ordering::Relaxed));
        });
    }
    #[test]
    fn slow_direct_uses_offline_and_a_failed_hedge_keeps_direct_alive() {
        runtime().block_on(async {
            deliver(
                std::future::pending(),
                async { Ok(()) },
                Duration::from_millis(1),
            )
            .await
            .unwrap();
            let completed = Arc::new(AtomicBool::new(false));
            let flag = completed.clone();
            deliver(
                async move {
                    tokio::time::sleep(Duration::from_millis(4)).await;
                    flag.store(true, Ordering::Relaxed);
                    Ok(())
                },
                async { Err(CoreError::NetworkAttachFailed) },
                Duration::from_millis(1),
            )
            .await
            .unwrap();
            assert!(completed.load(Ordering::Relaxed));
            assert!(
                deliver(
                    async { Err(CoreError::NetworkAttachFailed) },
                    async { Err(CoreError::NetworkAttachFailed) },
                    Duration::from_secs(1)
                )
                .await
                .is_err()
            );
        });
    }
}
