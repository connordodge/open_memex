//! The consistent `memex.db` snapshot (Spec #315 req 2, 2a; architecture
//! D6). Filler: R1a. Never through `Vault::open`.

use std::path::{Path, PathBuf};

use crate::error::MemexError;
use crate::Result;

/// A snapshot of `memex.db` in a temp file, deleted on drop.
#[derive(Debug)]
pub struct Snapshot {
    pub path: PathBuf,
    /// Read from the snapshot itself, not from `manifest.json`.
    pub schema_version: i64,
}

/// Takes the snapshot of `<vault>/memex.db`.
pub fn take_snapshot(_vault: &Path) -> Result<Snapshot> {
    Err(MemexError::BackupFailed(
        "snapshot: not implemented yet".into(),
    ))
}
