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
    journal: ImportJournal,
}

const IMPORT_JOURNAL: &str = ".account-transaction.json";

#[derive(Deserialize, Serialize)]
struct ImportJournal {
    version: u8,
    suffix: u64,
    committed: bool,
    had_identity: bool,
    had_messaging: bool,
}

fn save_journal(root: &Path, journal: &ImportJournal) -> CoreResult<()> {
    crate::atomic_file::replace(
        &root.join(IMPORT_JOURNAL),
        &serde_json::to_vec(journal).map_err(|_| CoreError::Internal)?,
    )
}

/// Runs before opening or creating an identity. Recovery is idempotent even
/// if the process stops during rollback itself. The journal stores no secrets
/// and no caller-controlled paths.
pub(crate) fn recover_pending_import(root: &Path) -> CoreResult<()> {
    let path = root.join(IMPORT_JOURNAL);
    if !path.exists() {
        return Ok(());
    }
    if fs::metadata(&path).map_err(|_| CoreError::Internal)?.len() > 1024 {
        return Err(CoreError::VerificationFailed);
    }
    let journal: ImportJournal =
        serde_json::from_slice(&fs::read(&path).map_err(|_| CoreError::Internal)?)
            .map_err(|_| CoreError::VerificationFailed)?;
    if journal.version != 1 {
        return Err(CoreError::UnsupportedVersion);
    }
    let rollback = root.join(format!(".account-rollback-{}", journal.suffix));
    let staging = root.join(format!(".account-import-{}", journal.suffix));
    for (name, had_previous) in [
        ("identity", journal.had_identity),
        ("messaging", journal.had_messaging),
    ] {
        let current = root.join(name);
        let previous = rollback.join(name);
        if journal.committed {
            if !current.is_dir() {
                return Err(CoreError::VerificationFailed);
            }
        } else if previous.exists() {
            if current.exists() {
                fs::remove_dir_all(&current).map_err(|_| CoreError::Internal)?;
            }
            durable_rename(&previous, &current)?;
        } else if had_previous {
            // Still in place, or already restored by an interrupted recovery.
            if !current.is_dir() {
                return Err(CoreError::VerificationFailed);
            }
        } else if current.exists() {
            fs::remove_dir_all(&current).map_err(|_| CoreError::Internal)?;
        }
    }
    for directory in [rollback, staging] {
        if directory.exists() {
            fs::remove_dir_all(directory).map_err(|_| CoreError::Internal)?;
        }
    }
    fs::remove_file(path).map_err(|_| CoreError::Internal)?;
    crate::atomic_file::sync_parent(root)
}

fn durable_rename(source: &Path, destination: &Path) -> CoreResult<()> {
    fs::rename(source, destination).map_err(|_| CoreError::Internal)?;
    crate::atomic_file::sync_parent(source.parent().ok_or(CoreError::Internal)?)?;
    crate::atomic_file::sync_parent(destination.parent().ok_or(CoreError::Internal)?)
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
    recover_pending_import(&root)?;
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

    let mut rollback = match install_staged_account(&root, &staging, suffix) {
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
        let restore_result = recover_pending_import(&root);
        reactivate_existing_account(storage_directory, vault_password);
        restore_result?;
        return Err(error);
    }
    rollback.journal.committed = true;
    if let Err(error) = save_journal(&root, &rollback.journal) {
        recover_pending_import(&root)?;
        reactivate_existing_account(storage_directory, vault_password);
        return Err(error);
    }
    // The imported account is already active at this point. Cleanup failure
    // must not make the caller believe that the import itself failed.
    let _ = recover_pending_import(&root);
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
    let rollback = AccountRollback {
        directory: rollback_directory,
        journal: ImportJournal {
            version: 1,
            suffix,
            committed: false,
            had_identity: root.join("identity").exists(),
            had_messaging: root.join("messaging").exists(),
        },
    };
    save_journal(root, &rollback.journal)?;

    // Move the complete previous account aside before installing any part of
    // the new one. This prevents a mixed identity/messaging state.
    for name in ["identity", "messaging"] {
        let current = root.join(name);
        if current.exists() {
            if durable_rename(&current, &rollback.directory.join(name)).is_err() {
                recover_pending_import(root)?;
                return Err(CoreError::Internal);
            }
        }
    }

    for name in ["identity", "messaging"] {
        if durable_rename(&staging.join(name), &root.join(name)).is_err() {
            recover_pending_import(root)?;
            return Err(CoreError::Internal);
        }
    }
    Ok(rollback)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_handles_every_install_boundary_and_repeated_startup() {
        for existing in [false, true] {
            for boundary in 0..=4 {
                let root = std::env::temp_dir().join(format!(
                    "sylphy-import-recovery-{}-{existing}-{boundary}",
                    std::process::id()
                ));
                fs::create_dir_all(&root).unwrap();
                let staging = root.join(".account-import-1");
                let rollback = root.join(".account-rollback-1");
                fs::create_dir_all(&rollback).unwrap();
                for name in ["identity", "messaging"] {
                    fs::create_dir_all(staging.join(name)).unwrap();
                    fs::write(staging.join(name).join("marker"), b"new").unwrap();
                    if existing {
                        fs::create_dir_all(root.join(name)).unwrap();
                        fs::write(root.join(name).join("marker"), b"old").unwrap();
                    }
                }
                save_journal(
                    &root,
                    &ImportJournal {
                        version: 1,
                        suffix: 1,
                        committed: false,
                        had_identity: existing,
                        had_messaging: existing,
                    },
                )
                .unwrap();
                for (step, name) in ["identity", "messaging"].iter().enumerate() {
                    if existing && boundary > step {
                        durable_rename(&root.join(name), &rollback.join(name)).unwrap();
                    }
                    if boundary > step + 2 {
                        durable_rename(&staging.join(name), &root.join(name)).unwrap();
                    }
                }
                recover_pending_import(&root).unwrap();
                recover_pending_import(&root).unwrap();
                for name in ["identity", "messaging"] {
                    if existing {
                        assert_eq!(fs::read(root.join(name).join("marker")).unwrap(), b"old");
                    } else {
                        assert!(!root.join(name).exists());
                    }
                }
                assert!(!root.join(IMPORT_JOURNAL).exists());
                fs::remove_dir_all(&root).unwrap();
            }
        }
    }

    #[test]
    fn committed_import_keeps_new_account_and_interrupted_rollback_keeps_old() {
        for committed in [false, true] {
            let root = std::env::temp_dir().join(format!(
                "sylphy-import-commit-{}-{committed}",
                std::process::id()
            ));
            let staging = root.join(".account-import-2");
            for name in ["identity", "messaging"] {
                fs::create_dir_all(root.join(name)).unwrap();
                fs::write(root.join(name).join("marker"), b"old").unwrap();
                fs::create_dir_all(staging.join(name)).unwrap();
                fs::write(staging.join(name).join("marker"), b"new").unwrap();
            }
            let mut transaction = install_staged_account(&root, &staging, 2).unwrap();
            if committed {
                transaction.journal.committed = true;
                save_journal(&root, &transaction.journal).unwrap();
            } else {
                // Simulate termination after restoring the first directory.
                fs::remove_dir_all(root.join("identity")).unwrap();
                durable_rename(
                    &transaction.directory.join("identity"),
                    &root.join("identity"),
                )
                .unwrap();
            }
            recover_pending_import(&root).unwrap();
            recover_pending_import(&root).unwrap();
            for name in ["identity", "messaging"] {
                assert_eq!(
                    fs::read(root.join(name).join("marker")).unwrap(),
                    if committed { b"new" } else { b"old" }
                );
            }
            fs::remove_dir_all(root).unwrap();
        }
    }
}
