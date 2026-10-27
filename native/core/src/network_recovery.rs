//! Rebuild a stale attachment only after its asynchronous shutdown completes.
use crate::error::{CoreError, CoreResult};

pub(crate) async fn reconnect_attachment_with<D, S, A, W>(
    detach: impl FnOnce() -> D,
    mut is_detached: impl FnMut() -> S,
    attach: impl FnOnce() -> A,
    mut wait: impl FnMut() -> W,
    available: impl Fn() -> bool,
) -> CoreResult<()>
where
    D: std::future::Future<Output = ()>,
    S: std::future::Future<Output = CoreResult<bool>>,
    A: std::future::Future<Output = CoreResult<()>>,
    W: std::future::Future<Output = ()>,
{
    if !is_detached().await? {
        detach().await;
        while !is_detached().await? {
            if !available() {
                return Err(CoreError::NetworkAttachFailed);
            }
            wait().await;
        }
    }
    if !available() {
        return Err(CoreError::NetworkAttachFailed);
    }
    attach().await
}

#[cfg(all(test, feature = "signal-ratchet"))]
mod tests {
    use super::*;

    #[test]
    fn coverage_recovery_waits_for_transport_shutdown_before_attaching() {
        use std::{cell::RefCell, future::ready};
        let events = RefCell::new(Vec::new());
        // Veilid's detach is asynchronous: two ticks still expose the old
        // attachment. An immediate attach would cancel its pending shutdown.
        let states = RefCell::new([false, false, false, true].into_iter());
        futures_executor::block_on(reconnect_attachment_with(
            || {
                events.borrow_mut().push("detach");
                ready(())
            },
            || {
                events.borrow_mut().push("state");
                ready(Ok(states.borrow_mut().next().unwrap()))
            },
            || {
                events.borrow_mut().push("attach");
                ready(Ok(()))
            },
            || {
                events.borrow_mut().push("wait");
                ready(())
            },
            || true,
        ))
        .unwrap();
        assert_eq!(
            *events.borrow(),
            [
                "state", "detach", "state", "wait", "state", "wait", "state", "attach"
            ]
        );
    }

    #[test]
    fn coverage_recovery_does_not_reattach_offline_and_handles_an_already_detached_node() {
        use std::{cell::Cell, future::ready};
        assert!(matches!(
            futures_executor::block_on(reconnect_attachment_with(
                || ready(()),
                || ready(Ok(false)),
                || -> std::future::Ready<CoreResult<()>> {
                    panic!("must not attach after losing coverage again")
                },
                || -> std::future::Ready<()> { panic!("must not keep waiting offline") },
                || false,
            )),
            Err(CoreError::NetworkAttachFailed)
        ));
        let attached = Cell::new(false);
        futures_executor::block_on(reconnect_attachment_with(
            || -> std::future::Ready<()> { panic!("already detached") },
            || ready(Ok(true)),
            || {
                attached.set(true);
                ready(Ok(()))
            },
            || -> std::future::Ready<()> { panic!("already detached") },
            || true,
        ))
        .unwrap();
        assert!(attached.get());
    }
}
