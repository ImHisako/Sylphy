//! Roll back failed appends before any subsequent access to the message log.
//! Only failed rollback handles are retained; successful appends need no sidecar
//! writes. After a process restart the log parser recovers incomplete tail frames.
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io::{self, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

use crate::{
    atomic_file,
    error::{CoreError, CoreResult},
};

struct PendingAppend {
    file: File,
    offset: u64,
}

static PENDING: OnceLock<Mutex<HashMap<PathBuf, PendingAppend>>> = OnceLock::new();

fn pending() -> &'static Mutex<HashMap<PathBuf, PendingAppend>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

trait AppendFile: Write {
    fn position_at_end(&mut self) -> io::Result<u64>;
    fn truncate(&mut self, length: u64) -> io::Result<()>;
    fn sync(&mut self) -> io::Result<()>;
}

impl AppendFile for File {
    fn position_at_end(&mut self) -> io::Result<u64> {
        self.seek(SeekFrom::End(0))
    }
    fn truncate(&mut self, length: u64) -> io::Result<()> {
        self.set_len(length)
    }
    fn sync(&mut self) -> io::Result<()> {
        self.sync_data()
    }
}

fn recover_with(file: &mut impl AppendFile, offset: &mut Option<u64>) -> io::Result<()> {
    if let Some(length) = *offset {
        file.truncate(length)?;
        file.sync()?;
        *offset = None;
    }
    Ok(())
}

fn append_with(
    file: &mut impl AppendFile,
    offset: &mut Option<u64>,
    frame: &[u8],
) -> io::Result<()> {
    recover_with(file, offset)?;
    *offset = Some(file.position_at_end()?);
    if let Err(error) = file.write_all(frame).and_then(|_| file.sync()) {
        // Keep the offset if either truncate or its flush fails. A later call
        // must finish that recovery before it is allowed to append anything.
        let _ = recover_with(file, offset);
        return Err(error);
    }
    *offset = None;
    Ok(())
}

fn recover_pending(pending: &mut HashMap<PathBuf, PendingAppend>, path: &Path) -> CoreResult<()> {
    if let Some(entry) = pending.get_mut(path) {
        // Keep the actual handle: an account import can install another file
        // at the same path. Never truncate that new account with an old offset.
        recover_with(&mut entry.file, &mut Some(entry.offset)).map_err(|_| CoreError::Internal)?;
        pending.remove(path);
    }
    Ok(())
}

pub(crate) fn recover(path: &Path) -> CoreResult<()> {
    let mut pending = pending().lock().map_err(|_| CoreError::Internal)?;
    recover_pending(&mut pending, path)
}

pub(crate) fn append(path: &Path, frame: &[u8]) -> CoreResult<()> {
    let mut pending = pending().lock().map_err(|_| CoreError::Internal)?;
    recover_pending(&mut pending, path)?;
    // Append-only Windows handles cannot truncate. Use a writable handle and
    // seek to EOF under the same lock that serializes appends and snapshots.
    let mut file = OpenOptions::new()
        .write(true)
        .open(path)
        .map_err(|_| CoreError::Internal)?;
    let mut offset = None;
    let result = append_with(&mut file, &mut offset, frame);
    if let Some(offset) = offset {
        pending.insert(path.to_owned(), PendingAppend { file, offset });
    }
    result.map_err(|_| CoreError::Internal)
}

pub(crate) fn replace(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    let mut pending = pending().lock().map_err(|_| CoreError::Internal)?;
    recover_pending(&mut pending, path)?;
    // Clear old offsets before replacement: a rename can succeed even when
    // the subsequent directory flush reports an error.
    atomic_file::replace(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FaultyFile {
        file: File,
        remaining: Option<usize>,
        sync_failures: usize,
        truncate_failures: usize,
    }

    impl Write for FaultyFile {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            if self.remaining == Some(0) {
                return Err(io::Error::other("injected write failure"));
            }
            let count = self
                .file
                .write(&bytes[..self.remaining.unwrap_or(bytes.len()).min(bytes.len())])?;
            if let Some(remaining) = &mut self.remaining {
                *remaining -= count;
            }
            Ok(count)
        }
        fn flush(&mut self) -> io::Result<()> {
            self.file.flush()
        }
    }

    impl AppendFile for FaultyFile {
        fn position_at_end(&mut self) -> io::Result<u64> {
            self.file.position_at_end()
        }
        fn truncate(&mut self, length: u64) -> io::Result<()> {
            if self.truncate_failures > 0 {
                self.truncate_failures -= 1;
                return Err(io::Error::other("injected truncate failure"));
            }
            self.file.set_len(length)
        }
        fn sync(&mut self) -> io::Result<()> {
            if self.sync_failures > 0 {
                self.sync_failures -= 1;
                return Err(io::Error::other("injected flush failure"));
            }
            self.file.sync_data()
        }
    }

    #[test]
    fn failed_writes_and_flushes_recover_before_retry_and_restart() {
        let root = std::env::temp_dir().join(format!("sylphy-append-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("events.log");
        let frame = b"\0\0\0\x08abcdefgh";
        // Every byte boundary: partial header, complete header, partial body;
        // plus a fully written frame whose data flush fails.
        for cutoff in 0..=frame.len() {
            std::fs::write(&path, b"previous").unwrap();
            let mut file = FaultyFile {
                file: OpenOptions::new().write(true).open(&path).unwrap(),
                remaining: Some(cutoff),
                sync_failures: usize::from(cutoff == frame.len()),
                truncate_failures: 0,
            };
            let mut offset = None;
            assert!(append_with(&mut file, &mut offset, frame).is_err());
            assert_eq!(offset, None);
            assert_eq!(std::fs::read(&path).unwrap(), b"previous");
            file.remaining = None;
            append_with(&mut file, &mut offset, frame).unwrap();
            drop(file);
            assert_eq!(
                std::fs::read(&path).unwrap(),
                [b"previous".as_slice(), frame].concat()
            );
        }
        // A failed rollback, and a failed rollback flush, must both block retry.
        let mut file = FaultyFile {
            file: OpenOptions::new().write(true).open(&path).unwrap(),
            remaining: Some(2),
            sync_failures: 0,
            truncate_failures: 2,
        };
        let before = std::fs::read(&path).unwrap();
        let mut offset = None;
        assert!(append_with(&mut file, &mut offset, frame).is_err());
        file.remaining = None;
        let partial = std::fs::read(&path).unwrap();
        assert!(append_with(&mut file, &mut offset, frame).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), partial);
        file.sync_failures = 1;
        assert!(append_with(&mut file, &mut offset, frame).is_err());
        assert!(offset.is_some());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        append_with(&mut file, &mut offset, frame).unwrap();
        drop(file);
        assert_eq!(
            std::fs::read(&path).unwrap(),
            [before.as_slice(), frame].concat()
        );

        pending().lock().unwrap().insert(
            path.clone(),
            PendingAppend {
                file: OpenOptions::new().write(true).open(&path).unwrap(),
                offset: 2,
            },
        );
        replace(&path, b"new snapshot").unwrap();
        append(&path, frame).unwrap();
        assert_eq!(
            std::fs::read(&path).unwrap(),
            [b"new snapshot".as_slice(), frame].concat()
        );
        // Account replacement must not apply an old file's rollback offset to
        // the new log installed at the same path.
        pending().lock().unwrap().insert(
            path.clone(),
            PendingAppend {
                file: OpenOptions::new().write(true).open(&path).unwrap(),
                offset: 2,
            },
        );
        let previous = root.join("previous.log");
        std::fs::rename(&path, &previous).unwrap();
        std::fs::write(&path, b"another account").unwrap();
        append(&path, frame).unwrap();
        assert_eq!(
            std::fs::read(&path).unwrap(),
            [b"another account".as_slice(), frame].concat()
        );
        assert_eq!(std::fs::metadata(&previous).unwrap().len(), 2);
        std::fs::remove_file(&previous).unwrap();
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(&root).unwrap();
    }
}
