//! One backup of a local vault (Spec #315 req 1-17a; architecture D9).
//! Filler: R1b.

use super::{BackupOutcome, BackupRequest, BackupSeams};
use crate::error::MemexError;
use crate::Result;

/// See [`super::backup_with`].
pub fn backup_with(_r: &BackupRequest, _s: &BackupSeams) -> Result<BackupOutcome> {
    Err(MemexError::BackupFailed(
        "memex backup: not implemented yet".into(),
    ))
}
