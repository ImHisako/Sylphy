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
    #[error("verification failed")]
    VerificationFailed,
    #[error("message limit exceeded")]
    LimitExceeded,
    #[error("feature unavailable")]
    FeatureUnavailable,
    #[error("platform initialization incomplete")]
    PlatformNotInitialized,
    #[error("network startup failed")]
    NetworkStartupFailed,
    #[error("internal operation failed")]
    Internal,
}
