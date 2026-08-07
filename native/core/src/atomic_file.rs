use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
};

use rand_core::{OsRng, RngCore};

use crate::error::{CoreError, CoreResult};

pub(crate) fn replace(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    let parent = path.parent().ok_or(CoreError::Internal)?;
    fs::create_dir_all(parent).map_err(|_| CoreError::Internal)?;
    let mut suffix = [0_u8; 8];
    OsRng.fill_bytes(&mut suffix);
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or(CoreError::Internal)?;
    let temporary = parent.join(format!(
        ".{file_name}.{:016x}.tmp",
        u64::from_be_bytes(suffix)
    ));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(|_| CoreError::Internal)?;
        file.write_all(bytes).map_err(|_| CoreError::Internal)?;
        file.sync_all().map_err(|_| CoreError::Internal)?;
        replace_file(&temporary, path)?;
        sync_parent(parent)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> CoreResult<()> {
    fs::rename(source, destination).map_err(|_| CoreError::Internal)
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> CoreResult<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(CoreError::Internal);
    }
    Ok(())
}

#[cfg(unix)]
fn sync_parent(parent: &Path) -> CoreResult<()> {
    std::fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| CoreError::Internal)
}

#[cfg(not(unix))]
fn sync_parent(_parent: &Path) -> CoreResult<()> {
    Ok(())
}
