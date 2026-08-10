use std::{
    fs,
    path::{Path, PathBuf},
};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::{
    error::{CoreError, CoreResult},
    identity, messaging_adapter, ratchet_adapter, vault,
};

const BACKUP_VERSION: u8 = 2;
const MAX_BACKUP_BYTES: usize = 96 * 1024 * 1024;
const MIN_TRANSFER_PASSWORD_CHARS: usize = 10;
const MAX_AVATAR_BYTES: usize = 5 * 1024 * 1024;
const MAX_CLOCK_SKEW_MS: u64 = 5 * 60 * 1000;

#[derive(Deserialize, Serialize)]
struct AccountBackup {
    version: u8,
    created_at_ms: u64,
    display_name: String,
    avatar_base64: Option<String>,
    identity: Value,
    messaging: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ratchet: Option<Value>,
}

struct AccountRollback {
    directory: PathBuf,
    had_identity: bool,
    had_messaging: bool,
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
        // Ratchet/session state is intentionally device-local. A linked device
        // gets a fresh libsignal identity and device id instead of cloning a
        // live sending chain from the source device.
        ratchet: None,
    };
    validate_profile(&backup)?;
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
    if backup.version != 1 && backup.version != BACKUP_VERSION {
        return Err(CoreError::UnsupportedVersion);
    }
    validate_profile(&backup)?;
    identity::validate_account_record(&backup.identity)?;
    if backup.version == 1 {
        // Validate legacy data before accepting the document, but never install
        // it: importing live sessions onto two devices forks the Signal chain.
        ratchet_adapter::validate_account_backup(
            backup
                .ratchet
                .as_ref()
                .ok_or(CoreError::VerificationFailed)?,
        )?;
    }
    messaging_adapter::validate_account_backup(&backup.messaging)?;

    let root = PathBuf::from(storage_directory);
    fs::create_dir_all(&root).map_err(|_| CoreError::Internal)?;
    let suffix = current_time_ms()?;
    let staging = root.join(format!(".account-import-{suffix}"));
    if staging.exists() {
        return Err(CoreError::Internal);
    }
    fs::create_dir(&staging).map_err(|_| CoreError::Internal)?;
    let staging_text = staging.to_str().ok_or(CoreError::InvalidInput)?;
    let prepared = (|| {
        identity::import_account_record(staging_text, vault_password, backup.identity.clone())?;
        messaging_adapter::configure_storage(staging_text)?;
        messaging_adapter::import_account_backup(backup.messaging.clone())
    })();
    if let Err(error) = prepared {
        let _ = fs::remove_dir_all(&staging);
        reactivate_existing_account(storage_directory, vault_password);
        return Err(error);
    }

    let rollback = match install_staged_account(&root, &staging, suffix) {
        Ok(value) => value,
        Err(error) => {
            let _ = fs::remove_dir_all(&staging);
            reactivate_existing_account(storage_directory, vault_password);
            return Err(error);
        }
    };
    let activated = (|| {
        identity::activate_from_storage(storage_directory, vault_password)?;
        messaging_adapter::configure_storage(storage_directory)
    })();
    if let Err(error) = activated {
        let restore_result = restore_account(&root, &rollback);
        reactivate_existing_account(storage_directory, vault_password);
        restore_result?;
        return Err(error);
    }
    // The imported account is already active at this point. Cleanup failure
    // must not make the caller believe that the import itself failed.
    let _ = fs::remove_dir_all(&rollback.directory);
    let _ = fs::remove_dir_all(&staging);
    Ok(json!({
        "display_name": backup.display_name,
        "avatar_base64": backup.avatar_base64,
        "created_at_ms": backup.created_at_ms,
    }))
}

fn validate_profile(backup: &AccountBackup) -> CoreResult<()> {
    let name = backup.display_name.trim();
    if name.is_empty()
        || name.chars().count() > 64
        || name.chars().any(char::is_control)
        || backup.created_at_ms > current_time_ms()?.saturating_add(MAX_CLOCK_SKEW_MS)
    {
        return Err(CoreError::VerificationFailed);
    }
    if let Some(encoded) = &backup.avatar_base64 {
        if encoded.len() > (MAX_AVATAR_BYTES * 4 / 3) + 8 {
            return Err(CoreError::LimitExceeded);
        }
        let avatar = STANDARD
            .decode(encoded)
            .map_err(|_| CoreError::VerificationFailed)?;
        if avatar.is_empty() || avatar.len() > MAX_AVATAR_BYTES {
            return Err(CoreError::LimitExceeded);
        }
    }
    Ok(())
}

fn install_staged_account(root: &Path, staging: &Path, suffix: u64) -> CoreResult<AccountRollback> {
    for name in ["identity", "messaging"] {
        if !staging.join(name).is_dir() {
            return Err(CoreError::VerificationFailed);
        }
    }

    let rollback_directory = root.join(format!(".account-rollback-{suffix}"));
    fs::create_dir(&rollback_directory).map_err(|_| CoreError::Internal)?;
    let mut rollback = AccountRollback {
        directory: rollback_directory,
        had_identity: false,
        had_messaging: false,
    };

    // Move the complete previous account aside before installing any part of
    // the new one. This prevents a mixed identity/messaging state.
    for name in ["identity", "messaging"] {
        let current = root.join(name);
        if current.exists() {
            if fs::rename(&current, rollback.directory.join(name)).is_err() {
                restore_moved_previous(root, &rollback)?;
                return Err(CoreError::Internal);
            }
            match name {
                "identity" => rollback.had_identity = true,
                "messaging" => rollback.had_messaging = true,
                _ => unreachable!(),
            }
        }
    }

    for name in ["identity", "messaging"] {
        if fs::rename(staging.join(name), root.join(name)).is_err() {
            restore_account(root, &rollback)?;
            return Err(CoreError::Internal);
        }
    }
    Ok(rollback)
}

fn restore_moved_previous(root: &Path, rollback: &AccountRollback) -> CoreResult<()> {
    for (name, was_moved) in [
        ("identity", rollback.had_identity),
        ("messaging", rollback.had_messaging),
    ] {
        if was_moved {
            fs::rename(rollback.directory.join(name), root.join(name))
                .map_err(|_| CoreError::Internal)?;
        }
    }
    if rollback.directory.exists() {
        fs::remove_dir_all(&rollback.directory).map_err(|_| CoreError::Internal)?;
    }
    Ok(())
}

fn restore_account(root: &Path, rollback: &AccountRollback) -> CoreResult<()> {
    for name in ["identity", "messaging"] {
        let current = root.join(name);
        if current.exists() {
            fs::remove_dir_all(&current).map_err(|_| CoreError::Internal)?;
        }
        let had_previous = match name {
            "identity" => rollback.had_identity,
            "messaging" => rollback.had_messaging,
            _ => unreachable!(),
        };
        let previous = rollback.directory.join(name);
        if had_previous {
            fs::rename(previous, current).map_err(|_| CoreError::Internal)?;
        }
    }
    if rollback.directory.exists() {
        fs::remove_dir_all(&rollback.directory).map_err(|_| CoreError::Internal)?;
    }
    Ok(())
}

fn reactivate_existing_account(storage_directory: &str, vault_password: &str) {
    let _ = identity::activate_from_storage(storage_directory, vault_password);
    let _ = messaging_adapter::configure_storage(storage_directory);
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
