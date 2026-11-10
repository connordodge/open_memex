//! Vault-server backups (Spec #315 req 28, 29; architecture D15, D16).
//!
//! `memex serve --root <dir> --backup-dir <dir>` backs up every served vault
//! into `<backup-dir>/<vault folder name>/`: at start-up and every hour
//! (through [`BackupService::run_due_checks`]), and on `POST …/backup`.

use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use memex_core::backup::ArchiveSink;

/// `--backup-dir` and `--backup-keep`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupConfig {
    /// The folder each vault's backup folder is created in.
    pub dir: PathBuf,
    /// The backups of each vault kept (1..=365).
    pub keep: u16,
}

/// A test seam around the `.partial` file of one backup: called with the
/// vault folder being backed up and the open file, on the backup's own
/// thread, so a test can hold a backup mid-run.
#[doc(hidden)]
pub type BackupArchiveHook =
    Arc<dyn Fn(&Path, File) -> io::Result<Box<dyn ArchiveSink>> + Send + Sync>;

/// The server's backups: one in-flight set and one runner shared by the
/// scheduler and `POST …/backup`.
pub struct BackupService {
    _config: Option<BackupConfig>,
    _hook: Option<BackupArchiveHook>,
}

impl BackupService {
    /// The service for `config` (`None`: no `--backup-dir`).
    pub(crate) fn new(config: Option<BackupConfig>, hook: Option<BackupArchiveHook>) -> Self {
        Self {
            _config: config,
            _hook: hook,
        }
    }

    /// Runs the due check for every served vault now, one vault at a time,
    /// and resolves once every backup this call started has finished.
    pub async fn run_due_checks(&self) {}
}
