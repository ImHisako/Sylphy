use thiserror::Error;

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("invalid input")]
    InvalidInput,
    #[error("unsupported protocol version")]
    UnsupportedVersion,
    #[error("authentication failed")]
    AuthenticationFailed,
    #[error("group permission denied")]
    GroupPermissionDenied,
    #[error("group slow mode active")]
    SlowModeActive,
    #[error("group spam filter rejected message")]
    SpamRejected,
    #[error("group is closed or membership revoked")]
    GroupClosed,
    #[error("verification failed")]
    VerificationFailed,
    #[error("message limit exceeded")]
    LimitExceeded,
    #[error("local storage capacity exhausted")]
    StorageFull,
    #[error("feature unavailable")]
    FeatureUnavailable,
    #[error("platform initialization incomplete")]
    PlatformNotInitialized,
    #[error("Veilid protected store initialization failed")]
    VeilidProtectedStoreFailed,
    #[error("Veilid local store initialization failed")]
    VeilidLocalStoreFailed,
    #[error("Veilid configuration rejected")]
    VeilidConfigurationFailed,
    #[error("Veilid is still restarting")]
    VeilidRestarting,
    #[error("network startup failed")]
    NetworkStartupFailed,
    #[error("network attach failed")]
    NetworkAttachFailed,
    #[error("internal operation failed")]
    Internal,
}
