//! Vault backups and restore (Spec #315; architecture D4, D5).
//!
//! This file holds the frozen core API and only delegates: `state.rs` is
//! the backup-state file, `names.rs`, `lock.rs`, `snapshot.rs` and
//! `fingerprint.rs` are the primitives, `run.rs` is one backup and
//! `restore.rs` one restore. Fillers own their files and never edit this one.

use std::fs::File;
use std::io::{self, Seek, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fs_guard::FsInfo;
use crate::{Clock, Result};

pub mod fingerprint;
pub mod lock;
pub mod names;
pub mod restore;
pub mod run;
pub mod snapshot;
pub mod state;

/// `backup.json` and `backup-state.json` format.
pub const FORMAT: i64 = 1;
/// The backup history file in the vault folder (req 10, 10a).
pub const STATE_FILE: &str = "backup-state.json";
/// The per-vault advisory lock file in the vault folder (req 5a).
pub const LOCK_FILE: &str = "backup.lock";
/// `--keep` when not given (req 12).
pub const KEEP_DEFAULT: u16 = 30;
/// The largest `--keep` (req 12).
pub const KEEP_MAX: u16 = 365;
/// A backup is due this long after the last success (req 23).
pub const DUE_AFTER_MS: i64 = 86_400_000;

/// Who made a backup: `memex backup` or the vault server (req 3).
// TODO(#316): serde names are "local" | "hosted".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BackupSource {
    Local,
    Hosted,
}

/// One backup of `vault` into `destination`.
#[derive(Debug, Clone, Copy)]
pub struct BackupRequest<'a> {
    pub vault: &'a Path,
    pub destination: &'a Path,
    pub keep: u16,
    pub if_changed: bool,
    pub source: BackupSource,
}

/// Where the backup zip is written: the `.partial` file, possibly wrapped by
/// a test seam that fails part-way.
pub trait ArchiveSink: Write + Seek {}

impl<T: Write + Seek> ArchiveSink for T {}

/// The seams a backup reads the world through (Spec technical decision 13).
pub struct BackupSeams<'a> {
    pub clock: &'a dyn Clock,
    pub probe: &'a dyn Fn(&Path) -> io::Result<FsInfo>,
    pub wrap_archive: &'a dyn Fn(File) -> io::Result<Box<dyn ArchiveSink>>,
}

impl BackupSeams<'static> {
    /// The system clock, the real `fs_guard` probe and the plain file.
    pub fn system() -> Self {
        // TODO(#316): stub.
        BackupSeams {
            clock: &StubClock,
            probe: &stub_probe,
            wrap_archive: &stub_wrap,
        }
    }
}

// TODO(#316): stub seams; the implementer replaces them.
struct StubClock;

impl Clock for StubClock {
    fn now_ms(&self) -> i64 {
        0
    }
}

fn stub_probe(_path: &Path) -> io::Result<FsInfo> {
    Err(io::Error::other("not implemented"))
}

fn stub_wrap(_file: File) -> io::Result<Box<dyn ArchiveSink>> {
    Err(io::Error::other("not implemented"))
}

/// The result of a backup that succeeded (req 17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackupOutcome {
    Created {
        vault_id: String,
        file: PathBuf,
        bytes: u64,
        fingerprint: String,
        removed: Vec<PathBuf>,
    },
    Unchanged {
        vault_id: String,
        fingerprint: String,
        last_file: Option<PathBuf>,
    },
}

impl BackupOutcome {
    /// The line `memex backup` prints (req 17), exactly.
    pub fn to_json(&self) -> Value {
        // TODO(#316): stub.
        Value::Null
    }
}

/// One backup of a local vault, through the system seams.
pub fn backup(r: &BackupRequest) -> Result<BackupOutcome> {
    backup_with(r, &BackupSeams::system())
}

/// One backup through `s` (run.rs).
pub fn backup_with(r: &BackupRequest, s: &BackupSeams) -> Result<BackupOutcome> {
    run::backup_with(r, s)
}

/// One restore of the backup file `from` into the new vault folder `to`.
#[derive(Debug, Clone, Copy)]
pub struct RestoreRequest<'a> {
    pub from: &'a Path,
    pub to: &'a Path,
}

/// The result of a restore that succeeded (req 34).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreOutcome {
    pub vault_id: String,
    pub path: PathBuf,
    pub created_at: i64,
}

impl RestoreOutcome {
    /// The line `memex restore` prints (req 34), exactly.
    pub fn to_json(&self) -> Value {
        // TODO(#316): stub.
        Value::Null
    }
}

/// One restore, with the real `fs_guard` probe.
pub fn restore(r: &RestoreRequest) -> Result<RestoreOutcome> {
    restore_with(r, &crate::fs_guard::probe)
}

/// One restore, with the network-drive guard asking `probe` (restore.rs).
pub fn restore_with(
    r: &RestoreRequest,
    probe: &dyn Fn(&Path) -> io::Result<FsInfo>,
) -> Result<RestoreOutcome> {
    restore::restore_with(r, probe)
}
