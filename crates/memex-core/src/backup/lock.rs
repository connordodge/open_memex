//! The per-vault backup lock (Spec #315 req 5a; architecture D8). Filler: R1a.
//!
//! `flock(LOCK_EX | LOCK_NB)` on `<vault>/backup.lock`; released on drop or
//! process death. Only `run.rs` calls it.

use std::path::Path;

use crate::error::MemexError;
use crate::Result;

/// A held backup lock; dropping it releases the lock.
#[derive(Debug)]
pub struct BackupLock {
    _private: (),
}

/// Takes the vault's backup lock, or fails with `backup_in_progress`.
pub fn try_lock(_vault: &Path) -> Result<BackupLock> {
    Err(MemexError::BackupFailed(
        "backup lock: not implemented yet".into(),
    ))
}
