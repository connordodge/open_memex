//! `backup-state.json` (Spec #315 req 10, 10a; architecture D11, D12).
//!
//! One file in the vault folder, keyed by [`destination_key`]. Writers are
//! called only under the vault's backup lock and write atomically (a temp
//! file in the vault folder, then a rename).

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::MemexError;
use crate::Result;

/// The whole file: `{"format":1,"destinations":{…}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupState {
    pub format: i64,
    pub destinations: BTreeMap<String, DestinationState>,
}

/// One destination's history (req 10a), in the file's key order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DestinationState {
    pub last_attempt_at: i64,
    pub last_success_at: Option<i64>,
    pub last_result: String,
    pub last_error: Option<String>,
    pub last_file: Option<String>,
    pub last_file_created_at: Option<i64>,
    pub last_bytes: Option<u64>,
    pub last_fingerprint: Option<String>,
}

/// The key a destination is recorded and looked up under: its canonical
/// path, or for a missing path the canonical nearest existing ancestor plus
/// the remaining components. One function for the CLI, the server, start-up
/// validation and lookups.
pub fn destination_key(_destination: &Path) -> Result<String> {
    // TODO(#316): stub.
    Ok(String::new())
}

/// The vault's backup history. A missing file, bad JSON or a `format` other
/// than 1 is no history: `{"format":1,"destinations":{}}`.
pub fn read_state(_vault: &Path) -> BackupState {
    // TODO(#316): stub.
    BackupState {
        format: 0,
        destinations: BTreeMap::new(),
    }
}

/// The history recorded for `destination` (looked up by [`destination_key`]).
pub fn destination_state(_vault: &Path, _destination: &Path) -> Option<DestinationState> {
    // TODO(#316): stub.
    None
}

/// The due rule (req 23, D12): no success yet, a clock that went backwards
/// (`last_success_at > now`), or at least [`super::DUE_AFTER_MS`] since.
pub fn is_due(_last_success_at: Option<i64>, _now: i64) -> bool {
    // TODO(#316): stub.
    false
}

/// Records a backup that wrote `file_name` (`created`).
pub fn record_created(
    _vault: &Path,
    _destination: &Path,
    _at_ms: i64,
    _file_name: &str,
    _bytes: u64,
    _fingerprint: &str,
) -> Result<()> {
    // TODO(#316): stub.
    Ok(())
}

/// Records a skipped backup (`unchanged`): the file fields and the
/// fingerprint stay as they were.
pub fn record_unchanged(_vault: &Path, _destination: &Path, _at_ms: i64) -> Result<()> {
    // TODO(#316): stub.
    Ok(())
}

/// Records a failed attempt: `last_attempt_at`, `last_result` (the error's
/// code) and `last_error` (its message) change; nothing else does.
pub fn record_failed(
    _vault: &Path,
    _destination: &Path,
    _at_ms: i64,
    _error: &MemexError,
) -> Result<()> {
    // TODO(#316): stub.
    Ok(())
}
