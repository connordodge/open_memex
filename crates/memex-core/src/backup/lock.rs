//! The per-vault backup lock (Spec #315 req 5a; architecture D8). Filler: R1a.
//!
//! `flock(LOCK_EX | LOCK_NB)` on `<vault>/backup.lock`; released on drop or
//! process death. Only `run.rs` calls it.
//!
//! The lock belongs to the open file description, so a child process forked
//! while a `BackupLock` is held shares it until that child execs (std opens
//! files close-on-exec) or exits. A `try_lock` in that window sees
//! `backup_in_progress`.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::Path;

use crate::error::MemexError;
use crate::Result;

use super::LOCK_FILE;

/// A held backup lock; dropping it releases the lock.
#[derive(Debug)]
pub struct BackupLock {
    /// Closing the file releases the `flock`.
    _file: File,
}

/// Takes the vault's backup lock, or fails with `backup_in_progress`.
pub fn try_lock(vault: &Path) -> Result<BackupLock> {
    let path = vault.join(LOCK_FILE);
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(|e| MemexError::BackupFailed(format!("open {}: {e}", path.display())))?;
    loop {
        // SAFETY: `file` owns a valid open descriptor for this whole call.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            return Ok(BackupLock { _file: file });
        }
        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::EWOULDBLOCK) => {
                return Err(MemexError::BackupInProgress(path.display().to_string()));
            }
            _ => {
                return Err(MemexError::BackupFailed(format!(
                    "lock {}: {err}",
                    path.display()
                )))
            }
        }
    }
}
