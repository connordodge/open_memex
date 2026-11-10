//! `backup-state.json` (Spec #315 req 10, 10a; architecture D11, D12).
//!
//! One file in the vault folder, keyed by [`destination_key`]. Writers are
//! called only under the vault's backup lock and write atomically (a temp
//! file in the vault folder, then a rename).

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write};
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
/// the remaining components. A path that cannot be resolved because a folder
/// on it refuses access (a permission or macOS privacy refusal) is walked up
/// the same way, so its failure can be recorded under a key; any other I/O
/// error is returned. A `..` after a missing component cancels it
/// lexically (a missing folder cannot be a symlink); a `..` left over once an
/// existing ancestor is reached steps up from that canonical ancestor. One
/// function for the CLI, the server, start-up validation and lookups.
pub fn destination_key(destination: &Path) -> Result<String> {
    let absolute = std::path::absolute(destination)?;
    let mut missing: Vec<&OsStr> = Vec::new();
    // `..` components seen while walking up, not yet matched with a name.
    let mut pending_up = 0usize;
    let mut existing = absolute.as_path();
    let mut key = loop {
        match fs::canonicalize(existing) {
            Ok(canonical) => break canonical,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::NotFound
                        | io::ErrorKind::NotADirectory
                        | io::ErrorKind::PermissionDenied
                ) =>
            {
                match (existing.parent(), existing.file_name()) {
                    (Some(parent), Some(name)) => {
                        if pending_up > 0 {
                            pending_up -= 1;
                        } else {
                            missing.push(name);
                        }
                        existing = parent;
                    }
                    // The path ends in `..`.
                    (Some(parent), None) => {
                        pending_up += 1;
                        existing = parent;
                    }
                    // The root itself.
                    (None, _) => return Err(e.into()),
                }
            }
            Err(e) => return Err(e.into()),
        }
    };
    for _ in 0..pending_up {
        key.pop();
    }
    for name in missing.into_iter().rev() {
        key.push(name);
    }
    key.to_str()
        .map(str::to_string)
        .ok_or_else(|| MemexError::InvalidPath(format!("{} is not UTF-8", key.display())))
}

/// The vault's backup history. A missing file, bad JSON or a `format` other
/// than 1 is no history: `{"format":1,"destinations":{}}`.
pub fn read_state(vault: &Path) -> BackupState {
    fs::read(vault.join(super::STATE_FILE))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<BackupState>(&bytes).ok())
        .filter(|state| state.format == super::FORMAT)
        .unwrap_or_else(empty)
}

fn empty() -> BackupState {
    BackupState {
        format: super::FORMAT,
        destinations: BTreeMap::new(),
    }
}

/// The history recorded for `destination` (looked up by [`destination_key`]).
pub fn destination_state(vault: &Path, destination: &Path) -> Option<DestinationState> {
    let key = destination_key(destination).ok()?;
    read_state(vault).destinations.remove(&key)
}

/// The due rule (req 23, D12): no success yet, a clock that went backwards
/// (`last_success_at > now`), or at least [`super::DUE_AFTER_MS`] since.
pub fn is_due(last_success_at: Option<i64>, now: i64) -> bool {
    match last_success_at {
        None => true,
        Some(last) if last > now => true,
        Some(last) => now.saturating_sub(last) >= super::DUE_AFTER_MS,
    }
}

/// Records a backup that wrote `file_name` (`created`).
pub fn record_created(
    vault: &Path,
    destination: &Path,
    at_ms: i64,
    file_name: &str,
    bytes: u64,
    fingerprint: &str,
) -> Result<()> {
    update(vault, destination, |_| DestinationState {
        last_attempt_at: at_ms,
        last_success_at: Some(at_ms),
        last_result: "created".to_string(),
        last_error: None,
        last_file: Some(file_name.to_string()),
        last_file_created_at: Some(at_ms),
        last_bytes: Some(bytes),
        last_fingerprint: Some(fingerprint.to_string()),
    })
}

/// Records a skipped backup (`unchanged`): the file fields and the
/// fingerprint stay as they were.
pub fn record_unchanged(vault: &Path, destination: &Path, at_ms: i64) -> Result<()> {
    update(vault, destination, |old| DestinationState {
        last_attempt_at: at_ms,
        last_success_at: Some(at_ms),
        last_result: "unchanged".to_string(),
        last_error: None,
        ..old.unwrap_or_else(no_history)
    })
}

/// Records a failed attempt: `last_attempt_at`, `last_result` (the error's
/// code) and `last_error` (its message) change; nothing else does.
pub fn record_failed(
    vault: &Path,
    destination: &Path,
    at_ms: i64,
    error: &MemexError,
) -> Result<()> {
    update(vault, destination, |old| DestinationState {
        last_attempt_at: at_ms,
        last_result: error.code().to_string(),
        last_error: Some(error.to_string()),
        ..old.unwrap_or_else(no_history)
    })
}

/// A destination never recorded before: every success and file field null.
fn no_history() -> DestinationState {
    DestinationState {
        last_attempt_at: 0,
        last_success_at: None,
        last_result: String::new(),
        last_error: None,
        last_file: None,
        last_file_created_at: None,
        last_bytes: None,
        last_fingerprint: None,
    }
}

/// Replaces `destination`'s entry with `next(old entry)` and writes the file.
fn update(
    vault: &Path,
    destination: &Path,
    next: impl FnOnce(Option<DestinationState>) -> DestinationState,
) -> Result<()> {
    let key = destination_key(destination)?;
    let mut state = read_state(vault);
    let old = state.destinations.remove(&key);
    state.destinations.insert(key, next(old));
    write_state(vault, &state)
}

/// Writes `state` atomically: pretty JSON plus a newline into a temp file in
/// the vault folder, synced, then renamed over `backup-state.json`.
fn write_state(vault: &Path, state: &BackupState) -> Result<()> {
    let mut text = serde_json::to_string_pretty(state)?;
    text.push('\n');
    let mut temp = tempfile::Builder::new()
        .prefix(".backup-state.")
        .suffix(".tmp")
        .tempfile_in(vault)?;
    temp.write_all(text.as_bytes())?;
    temp.as_file().sync_all()?;
    temp.persist(vault.join(super::STATE_FILE))
        .map_err(|e| MemexError::Io(e.error))?;
    Ok(())
}
