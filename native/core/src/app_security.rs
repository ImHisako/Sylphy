//! Passphrase wrapping of the existing random vault secret. No database rewrite
//! is needed: identity, ratchet, history, profile and preferences keep their keys.
use crate::{
    atomic_file,
    error::{CoreError, CoreResult},
    identity, messaging_adapter, ratchet_adapter, vault,
};
use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct LockPolicy {
    pub inactivity_seconds: u64,
    pub lock_on_background: bool,
}
impl Default for LockPolicy {
    fn default() -> Self {
        Self {
            inactivity_seconds: 300,
            lock_on_background: true,
        }
    }
}
impl LockPolicy {
    fn validate(&self) -> CoreResult<()> {
        if ![0, 30, 60, 300, 900].contains(&self.inactivity_seconds) {
            return Err(CoreError::InvalidInput);
        }
        Ok(())
    }
}
#[derive(Clone, Deserialize, Serialize)]
struct ProtectedSecret {
    version: u8,
    wrapped_secret: String,
    policy: LockPolicy,
}
#[derive(Default)]
struct Session {
    path: Option<PathBuf>,
    protected: Option<ProtectedSecret>,
    secret: Option<Zeroizing<String>>,
    last_activity: Option<Instant>,
    // A failed configuration must never enable the legacy password path.
    configuration_failed: bool,
}
static SESSION: OnceLock<Mutex<Session>> = OnceLock::new();
fn session() -> &'static Mutex<Session> {
    SESSION.get_or_init(|| Mutex::new(Session::default()))
}

pub fn configure(storage_directory: &str) -> CoreResult<Value> {
    if storage_directory.trim().is_empty() || storage_directory.len() > 4096 {
        return Err(CoreError::InvalidInput);
    }
    let path = PathBuf::from(storage_directory).join("app-security-v1.json");
    let mut state = session().lock().map_err(|_| CoreError::Internal)?;
    if state
        .path
        .as_ref()
        .is_some_and(|configured| configured != &path)
    {
        return Err(CoreError::InvalidInput);
    }
    if state.path.as_ref() == Some(&path) && !state.configuration_failed {
        drop(state);
        return status();
    }
    state.configuration_failed = true;
    state.path = Some(path.clone());
    state.secret = None;
    let protected = match fs::read(&path) {
        Ok(bytes) => {
            if bytes.len() > 4096 {
                return Err(CoreError::InvalidInput);
            }
            let value: ProtectedSecret =
                serde_json::from_slice(&bytes).map_err(|_| CoreError::VerificationFailed)?;
            if value.version != 1 || value.wrapped_secret.len() > 2048 {
                return Err(CoreError::UnsupportedVersion);
            }
            value.policy.validate()?;
            Some(value)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(CoreError::Internal),
    };
    state.path = Some(path);
    state.protected = protected;
    state.configuration_failed = false;
    if state.protected.is_some() {
        start_watchdog()?;
    }
    drop(state);
    status()
}
pub fn status() -> CoreResult<Value> {
    let state = session().lock().map_err(|_| CoreError::Internal)?;
    if state.configuration_failed {
        return Err(CoreError::VaultLocked);
    }
    Ok(
        json!({"enabled": state.protected.is_some(), "locked": locked(&state),
        "policy": state.protected.as_ref().map(|v| v.policy.clone()).unwrap_or_default()}),
    )
}
fn locked(state: &Session) -> bool {
    state.configuration_failed
        || state.protected.as_ref().is_some_and(|value| {
            state.secret.is_none()
                || (value.policy.inactivity_seconds > 0
                    && state.last_activity.is_none_or(|last| {
                        last.elapsed() >= Duration::from_secs(value.policy.inactivity_seconds)
                    }))
        })
}
pub fn is_locked() -> bool {
    session().lock().map(|state| locked(&state)).unwrap_or(true)
}

pub fn locks_on_background() -> bool {
    session()
        .lock()
        .map(|state| {
            state
                .protected
                .as_ref()
                .is_some_and(|value| value.policy.lock_on_background)
        })
        .unwrap_or(true)
}

pub fn enable(passphrase: &str, device_secret: &str) -> CoreResult<Value> {
    validate_passphrase(passphrase)?;
    if device_secret.len() < 43 || device_secret.len() > 512 {
        return Err(CoreError::InvalidInput);
    }
    let mut state = session().lock().map_err(|_| CoreError::Internal)?;
    if state.configuration_failed || state.protected.is_some() {
        return Err(CoreError::InvalidInput);
    }
    let path = state.path.as_ref().ok_or(CoreError::InvalidInput)?;
    let encrypted = vault::seal(passphrase, device_secret.as_bytes())?;
    // Verify before committing and before the platform deletes its old secret.
    if vault::open(passphrase, &encrypted)?.as_slice() != device_secret.as_bytes() {
        return Err(CoreError::VerificationFailed);
    }
    let protected = ProtectedSecret {
        version: 1,
        wrapped_secret: STANDARD_NO_PAD.encode(encrypted),
        policy: LockPolicy::default(),
    };
    // No fallible setup may remain after the envelope has been committed.
    start_watchdog()?;
    atomic_file::replace(
        path,
        &serde_json::to_vec(&protected).map_err(|_| CoreError::Internal)?,
    )?;
    state.protected = Some(protected);
    state.secret = Some(Zeroizing::new(device_secret.to_owned()));
    state.last_activity = Some(Instant::now());
    drop(state);
    status()
}
pub fn unlock(passphrase: &str) -> CoreResult<Value> {
    if passphrase.is_empty() || passphrase.len() > 512 {
        return Err(CoreError::InvalidInput);
    }
    let mut state = session().lock().map_err(|_| CoreError::Internal)?;
    if state.configuration_failed {
        return Err(CoreError::VaultLocked);
    }
    let protected = state.protected.as_ref().ok_or(CoreError::InvalidInput)?;
    let record = STANDARD_NO_PAD
        .decode(&protected.wrapped_secret)
        .map_err(|_| CoreError::VerificationFailed)?;
    let bytes = vault::open(passphrase, &record)?;
    let secret = Zeroizing::new(
        String::from_utf8(bytes.to_vec()).map_err(|_| CoreError::VerificationFailed)?,
    );
    if secret.len() < 43 || secret.len() > 512 {
        return Err(CoreError::VerificationFailed);
    }
    state.secret = Some(secret);
    state.last_activity = Some(Instant::now());
    drop(state);
    status()
}
pub fn touch() -> CoreResult<Value> {
    let mut state = session().lock().map_err(|_| CoreError::Internal)?;
    if locked(&state) {
        return Err(CoreError::VaultLocked);
    }
    state.last_activity = Some(Instant::now());
    Ok(json!({}))
}
pub fn update_policy(policy: LockPolicy) -> CoreResult<Value> {
    policy.validate()?;
    let mut state = session().lock().map_err(|_| CoreError::Internal)?;
    if locked(&state) {
        return Err(CoreError::VaultLocked);
    }
    let mut protected = state.protected.clone().ok_or(CoreError::InvalidInput)?;
    protected.policy = policy;
    atomic_file::replace(
        state.path.as_ref().ok_or(CoreError::InvalidInput)?,
        &serde_json::to_vec(&protected).map_err(|_| CoreError::Internal)?,
    )?;
    state.protected = Some(protected);
    state.last_activity = Some(Instant::now());
    drop(state);
    status()
}
pub fn lock_vault() -> CoreResult<Value> {
    {
        let mut state = session().lock().map_err(|_| CoreError::Internal)?;
        state.secret = None; // Zeroizing clears the allocation before freeing it.
        state.last_activity = None;
    }
    // Called under the FFI command lock, after any earlier storage transaction.
    let messaging = messaging_adapter::wipe_memory();
    let ratchet = ratchet_adapter::wipe_memory();
    let identity = identity::wipe_memory();
    messaging?;
    ratchet?;
    identity?;
    status()
}
pub fn require_unlocked() -> CoreResult<()> {
    if is_locked() {
        lock_vault()?;
        return Err(CoreError::VaultLocked);
    }
    Ok(())
}
pub fn vault_password(legacy: &str) -> CoreResult<Zeroizing<String>> {
    let state = session().lock().map_err(|_| CoreError::Internal)?;
    if locked(&state) {
        return Err(CoreError::VaultLocked);
    }
    if state.protected.is_some() {
        return state.secret.clone().ok_or(CoreError::VaultLocked);
    }
    Ok(Zeroizing::new(legacy.to_owned()))
}
fn validate_passphrase(passphrase: &str) -> CoreResult<()> {
    if passphrase.chars().count() < 12 || passphrase.len() > 512 || passphrase.trim().is_empty() {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}

fn start_watchdog() -> CoreResult<()> {
    static WATCHDOG: OnceLock<Result<(), ()>> = OnceLock::new();
    WATCHDOG
        .get_or_init(|| {
            std::thread::Builder::new()
                .name("sylphy-vault-expiry".into())
                .spawn(|| {
                    loop {
                        std::thread::sleep(Duration::from_secs(1));
                        let expired = || {
                            session()
                                .lock()
                                .map(|state| state.secret.is_some() && locked(&state))
                                .unwrap_or(false)
                        };
                        if expired() {
                            if let Ok(_guard) = crate::ffi::COMMAND_LOCK.lock() {
                                if expired() {
                                    let _ = lock_vault();
                                }
                            }
                        }
                    }
                })
                .map(|_| ())
                .map_err(|_| ())
        })
        .as_ref()
        .map(|_| ())
        .map_err(|_| CoreError::Internal)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passphrase_preserves_existing_keys_and_blocks_legacy_bypass() {
        let _guard = identity::TEST_IDENTITY_LOCK.lock().unwrap();
        let directory =
            std::env::temp_dir().join(format!("sylphy-security-{}", std::process::id()));
        let root = directory.to_string_lossy();
        *session().lock().unwrap() = Session::default();
        configure(&root).unwrap();
        let secret = "a".repeat(43);
        let original = identity::ensure_identity(&root, &secret, None, None).unwrap();
        let old_data = vault::seal(&secret, b"existing encrypted history").unwrap();
        enable("a long test passphrase", &secret).unwrap();
        let bytes = fs::read(directory.join("app-security-v1.json")).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains(&secret));
        assert!(!String::from_utf8_lossy(&bytes).contains("test passphrase"));
        lock_vault().unwrap();
        assert!(identity::active_identity().is_err());
        #[cfg(feature = "signal-ratchet")]
        assert!(ratchet_adapter::public_pre_key_bundle().is_err());
        assert!(vault_password(&secret).is_err());
        assert!(configure(&directory.join("other").to_string_lossy()).is_err());
        let request = std::ffi::CString::new(serde_json::to_string(&json!({"command": "ensure_identity", "storage_directory": root, "vault_password": secret})).unwrap()).unwrap();
        let response = unsafe { crate::ffi::sylphy_core_call(request.as_ptr()) };
        let response_value: Value = serde_json::from_str(
            unsafe { std::ffi::CStr::from_ptr(response) }
                .to_str()
                .unwrap(),
        )
        .unwrap();
        unsafe {
            crate::ffi::sylphy_core_free_string(response);
        }
        assert_eq!(response_value["code"], "vault_locked");
        assert!(unlock("wrong password").is_err());
        assert!(is_locked());
        unlock("a long test passphrase").unwrap();
        let restored =
            identity::ensure_identity(&root, &vault_password("").unwrap(), None, None).unwrap();
        assert_eq!(original["identity_id"], restored["identity_id"]);
        assert_eq!(&**vault_password("").unwrap(), &secret);
        assert_eq!(
            &**vault::open(&vault_password("").unwrap(), &old_data).unwrap(),
            b"existing encrypted history"
        );
        update_policy(LockPolicy {
            inactivity_seconds: 30,
            lock_on_background: false,
        })
        .unwrap();
        session().lock().unwrap().last_activity = Some(Instant::now() - Duration::from_secs(31));
        assert!(require_unlocked().is_err());
        assert!(session().lock().unwrap().secret.is_none());
        *session().lock().unwrap() = Session::default();
        assert_eq!(configure(&root).unwrap()["locked"], true);
        unlock("a long test passphrase").unwrap();
        assert_eq!(status().unwrap()["policy"]["inactivity_seconds"], 30);
        fs::write(directory.join("app-security-v1.json"), b"corrupt").unwrap();
        *session().lock().unwrap() = Session::default();
        assert!(configure(&root).is_err());
        assert!(vault_password(&secret).is_err());
        fs::remove_dir_all(directory).unwrap();
        *session().lock().unwrap() = Session::default();
    }
}
