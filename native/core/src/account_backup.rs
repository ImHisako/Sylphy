use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::{
    error::{CoreError, CoreResult},
    identity, messaging_adapter, ratchet_adapter, vault,
};

const BACKUP_VERSION: u8 = 1;
const MAX_BACKUP_BYTES: usize = 96 * 1024 * 1024;
const MIN_TRANSFER_PASSWORD_CHARS: usize = 10;

#[derive(Deserialize, Serialize)]
struct AccountBackup {
    version: u8,
    created_at_ms: u64,
    display_name: String,
    avatar_base64: Option<String>,
    identity: Value,
    messaging: Value,
    ratchet: Value,
}

pub fn export(
    transfer_password: &str,
    display_name: &str,
    avatar_base64: Option<String>,
) -> CoreResult<Value> {
    validate_password(transfer_password)?;
    let name = display_name.trim();
    if name.is_empty() || name.chars().count() > 64 || name.chars().any(char::is_control) {
        return Err(CoreError::InvalidInput);
    }
    let backup = AccountBackup {
        version: BACKUP_VERSION,
        created_at_ms: current_time_ms()?,
        display_name: name.to_owned(),
        avatar_base64,
        identity: identity::export_account_record()?,
        messaging: messaging_adapter::export_account_backup()?,
        ratchet: ratchet_adapter::export_account_backup()?,
    };
    let plaintext = Zeroizing::new(serde_json::to_vec(&backup).map_err(|_| CoreError::Internal)?);
    if plaintext.len() > MAX_BACKUP_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let encrypted = vault::seal(transfer_password, &plaintext)?;
    Ok(json!({
        "backup_base64": STANDARD_NO_PAD.encode(encrypted),
        "created_at_ms": backup.created_at_ms,
    }))
}

pub fn import(
    transfer_password: &str,
    backup_base64: &str,
    storage_directory: &str,
    vault_password: &str,
) -> CoreResult<Value> {
    validate_password(transfer_password)?;
    let encrypted = STANDARD_NO_PAD
        .decode(backup_base64)
        .map_err(|_| CoreError::InvalidInput)?;
    if encrypted.is_empty() || encrypted.len() > MAX_BACKUP_BYTES + 1024 {
        return Err(CoreError::LimitExceeded);
    }
    let plaintext = Zeroizing::new(vault::open(transfer_password, &encrypted)?);
    let backup: AccountBackup =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::VerificationFailed)?;
    if backup.version != BACKUP_VERSION {
        return Err(CoreError::UnsupportedVersion);
    }
    identity::import_account_record(storage_directory, vault_password, backup.identity)?;
    ratchet_adapter::import_account_backup(backup.ratchet)?;
    messaging_adapter::import_account_backup(backup.messaging)?;
    Ok(json!({
        "display_name": backup.display_name,
        "avatar_base64": backup.avatar_base64,
        "created_at_ms": backup.created_at_ms,
    }))
}

fn validate_password(value: &str) -> CoreResult<()> {
    let count = value.chars().count();
    if !(MIN_TRANSFER_PASSWORD_CHARS..=256).contains(&count) {
        return Err(CoreError::InvalidInput);
    }
    Ok(())
}

fn current_time_ms() -> CoreResult<u64> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CoreError::Internal)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| CoreError::Internal)
}
