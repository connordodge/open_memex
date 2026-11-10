//! Vault-server backups (Spec #315 req 28, 29; architecture D15, D16).
//!
//! `memex serve --root <dir> --backup-dir <dir>` backs up every served vault
//! into `<backup-dir>/<vault folder name>/`: at start-up and every hour
//! (through [`BackupService::run_due_checks`]), and on `POST …/backup`.
//!
//! Concurrency (D16): one in-flight set of lower-cased vault names (an entry
//! is held from the moment a backup is claimed until it has ended), and one
//! runner shared by the scheduler and `POST`, so at most one backup runs at a
//! time. Each backup runs on its own `std::thread`, which owns the in-flight
//! entry and the runner permit: a panic releases both, and shutdown never
//! waits for it. The server never opens a vault to back it up, never flocks
//! and never writes `backup-state.json` itself; the core does both.

use std::collections::HashSet;
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use memex_core::backup::{
    self as core_backup, state, ArchiveSink, BackupOutcome, BackupRequest, BackupSeams,
    BackupSource,
};
use memex_core::{fs_guard, MemexError};
use serde_json::{json, Value};
use tokio::sync::{oneshot, Semaphore};

use super::error::ApiError;
use super::registry::Registry;
use super::request_clock::SharedClock;
use crate::cli::InvalidArgument;

/// Folders in the vault root that are never a backup dir: the server's own
/// state and the import folder.
const RESERVED_DOT_FOLDERS: [&str; 2] = [".memex", ".incoming"];

/// The answer to `POST …/backup` on a server without `--backup-dir`.
const NOT_CONFIGURED: &str =
    "backups are not configured on this vault server; start it with --backup-dir";

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

/// `--backup-dir` checked against the canonical vault root `root` before
/// the server binds (D15). The folder is resolved as the core resolves a
/// destination ([`state::destination_key`]: symlinks followed, a missing
/// tail kept). Inside the root only exactly `<root>/<.name>` is allowed, and
/// never `.memex` or `.incoming`; anything else there is `invalid_argument`.
/// Returns the folder as an absolute path (relative to the working
/// directory). A folder that doesn't exist is accepted: each backup then
/// records `backup_destination_unavailable`.
pub(crate) fn check_dir(dir: &Path, root: &Path) -> anyhow::Result<PathBuf> {
    let shown = dir.display();
    let absolute = std::path::absolute(dir)
        .map_err(|e| InvalidArgument(format!("--backup-dir {shown}: {e}")))?;
    let resolved = PathBuf::from(
        state::destination_key(&absolute)
            .map_err(|e| InvalidArgument(format!("--backup-dir {shown}: {e}")))?,
    );
    if !resolved.starts_with(root) {
        return Ok(absolute);
    }
    let top_level_name = resolved
        .parent()
        .filter(|parent| *parent == root)
        .and_then(|_| resolved.file_name())
        .and_then(|name| name.to_str());
    match top_level_name {
        Some(name)
            if RESERVED_DOT_FOLDERS
                .iter()
                .any(|r| name.eq_ignore_ascii_case(r)) =>
        {
            Err(InvalidArgument(format!(
                "--backup-dir {shown} is the vault root's own {name} folder; use another folder"
            ))
            .into())
        }
        Some(name) if name.starts_with('.') => Ok(absolute),
        _ => Err(InvalidArgument(format!(
            "--backup-dir {shown} is inside the vault root {}; use a folder outside it or a \
             top-level dot folder such as <root>/.backups",
            root.display()
        ))
        .into()),
    }
}

/// The server's backups: one in-flight set and one runner shared by the
/// scheduler and `POST …/backup`.
pub struct BackupService {
    config: Option<BackupConfig>,
    hook: Option<BackupArchiveHook>,
    registry: Arc<Registry>,
    clock: SharedClock,
    /// Lower-cased names of the vaults claimed for a backup.
    in_flight: Arc<Mutex<HashSet<String>>>,
    /// The one runner (D16).
    runner: Arc<Semaphore>,
}

/// A vault's entry in the in-flight set, removed on drop (also while a
/// panicking backup thread unwinds).
struct InFlight {
    set: Arc<Mutex<HashSet<String>>>,
    key: String,
}

impl Drop for InFlight {
    fn drop(&mut self) {
        lock(&self.set).remove(&self.key);
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The in-flight key of a vault folder name.
fn key_of(folder: &str) -> String {
    folder.to_ascii_lowercase()
}

/// The folder name of a vault folder path, as on disk.
fn folder_name(vault: &Path) -> String {
    vault
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Why one backup runs.
#[derive(Clone, Copy)]
enum Trigger {
    /// The hourly check: only when due, and skipped when unchanged.
    Scheduled,
    /// `POST …/backup` ("Back up now"): always writes a new file.
    Requested,
}

/// One backup, as handed to its thread.
struct Job {
    config: BackupConfig,
    hook: Option<BackupArchiveHook>,
    clock: SharedClock,
    vault: PathBuf,
    folder: String,
    trigger: Trigger,
}

impl BackupService {
    /// The service for `config` (`None`: no `--backup-dir`) over the vaults
    /// of `registry`, on the server's base `clock`.
    pub(crate) fn new(
        config: Option<BackupConfig>,
        hook: Option<BackupArchiveHook>,
        registry: Arc<Registry>,
        clock: SharedClock,
    ) -> Self {
        Self {
            config,
            hook,
            registry,
            clock,
            in_flight: Arc::new(Mutex::new(HashSet::new())),
            runner: Arc::new(Semaphore::new(1)),
        }
    }

    /// Runs the due check for every served vault now, one vault at a time,
    /// and resolves once every backup this call started has finished and
    /// been recorded. A vault already being backed up is skipped. Without
    /// `--backup-dir` it does nothing.
    pub async fn run_due_checks(&self) {
        let Some(config) = &self.config else {
            return;
        };
        let vaults = match self.registry.list().await {
            Ok(vaults) => vaults,
            Err(e) => {
                tracing::warn!(error = ?e, "backup: could not list the served vaults");
                return;
            }
        };
        for listed in vaults {
            let vault = self.registry.root().join(&listed.name);
            let dest = config.dir.join(&listed.name);
            let now = self.clock.now_ms();
            let due = {
                let (vault, dest) = (vault.clone(), dest.clone());
                tokio::task::spawn_blocking(move || is_due(&vault, &dest, now))
                    .await
                    .unwrap_or(true)
            };
            if !due {
                continue;
            }
            let Some(claim) = self.claim(&listed.name) else {
                tracing::info!(vault = %listed.name, "backup: skipped, a backup of this vault is running");
                continue;
            };
            self.run(claim, vault, listed.name, Trigger::Scheduled)
                .await;
        }
    }

    /// `GET …/backup` of the vault folder `vault` (D17).
    pub(crate) async fn status(&self, vault: PathBuf) -> Value {
        let folder = folder_name(&vault);
        let in_progress = lock(&self.in_flight).contains(&key_of(&folder));
        self.body(vault, folder, in_progress).await
    }

    /// `POST …/backup` of the vault folder `vault` (D17): claims the vault,
    /// starts its backup without awaiting it and returns the GET body with
    /// `in_progress` true. 409 `backups_not_configured` without
    /// `--backup-dir`; 409 `backup_in_progress` while that vault is being
    /// backed up.
    pub(crate) async fn start(self: &Arc<Self>, vault: PathBuf) -> Result<Value, ApiError> {
        if self.config.is_none() {
            return Err(ApiError::new("backups_not_configured", NOT_CONFIGURED));
        }
        let folder = folder_name(&vault);
        let Some(claim) = self.claim(&folder) else {
            return Err(MemexError::BackupInProgress(folder).into());
        };
        let body = self.body(vault.clone(), folder.clone(), true).await;
        let service = self.clone();
        tokio::spawn(async move {
            service.run(claim, vault, folder, Trigger::Requested).await;
        });
        Ok(body)
    }

    /// The vault's entry in the in-flight set, unless it is already there.
    fn claim(&self, folder: &str) -> Option<InFlight> {
        let key = key_of(folder);
        lock(&self.in_flight).insert(key.clone()).then(|| InFlight {
            set: self.in_flight.clone(),
            key,
        })
    }

    /// Waits for the runner, then backs up `vault` on its own thread and
    /// resolves once that backup has ended. The thread owns `claim` and the
    /// runner permit.
    async fn run(&self, claim: InFlight, vault: PathBuf, folder: String, trigger: Trigger) {
        let Some(config) = self.config.clone() else {
            return;
        };
        let permit = self
            .runner
            .clone()
            .acquire_owned()
            .await
            .expect("the backup runner is never closed");
        let job = Job {
            config,
            hook: self.hook.clone(),
            clock: self.clock.clone(),
            vault,
            folder: folder.clone(),
            trigger,
        };
        let (done, ended) = oneshot::channel();
        let spawned = std::thread::Builder::new()
            .name(format!("backup {folder}"))
            .spawn(move || {
                job.run();
                drop(claim);
                drop(permit);
                let _ = done.send(());
            });
        match spawned {
            Ok(_) => {
                if ended.await.is_err() {
                    tracing::error!(vault = %folder, "backup: the backup thread panicked");
                }
            }
            Err(e) => {
                tracing::error!(vault = %folder, error = %e, "backup: could not start the backup thread");
            }
        }
    }

    /// The D17 body of the vault folder `vault` named `folder`; the one
    /// builder for GET and POST.
    async fn body(&self, vault: PathBuf, folder: String, in_progress: bool) -> Value {
        let Some(config) = &self.config else {
            return json!({
                "enabled": false,
                "keep": null,
                "in_progress": false,
                "last_attempt_at": null,
                "last_success_at": null,
                "last_result": null,
                "last_error": null,
                "last_file": null,
                "last_file_created_at": null,
                "last_bytes": null,
            });
        };
        let dest = config.dir.join(&folder);
        let recorded = tokio::task::spawn_blocking(move || state::destination_state(&vault, &dest))
            .await
            .ok()
            .flatten();
        let s = recorded.as_ref();
        json!({
            "enabled": true,
            "keep": config.keep,
            "in_progress": in_progress,
            "last_attempt_at": s.map(|s| s.last_attempt_at),
            "last_success_at": s.and_then(|s| s.last_success_at),
            "last_result": s.map(|s| s.last_result.as_str()),
            "last_error": s.and_then(|s| s.last_error.as_deref()),
            "last_file": s.and_then(|s| s.last_file.as_deref()),
            "last_file_created_at": s.and_then(|s| s.last_file_created_at),
            "last_bytes": s.and_then(|s| s.last_bytes),
        })
    }
}

/// The due rule (req 23) for the backups of `vault` into `dest` at `now`.
fn is_due(vault: &Path, dest: &Path, now: i64) -> bool {
    let last_success = state::destination_state(vault, dest).and_then(|s| s.last_success_at);
    state::is_due(last_success, now)
}

impl Job {
    /// One backup, on its own thread: logged, and recorded by the core.
    fn run(self) {
        let dest = self.config.dir.join(&self.folder);
        if let Trigger::Scheduled = self.trigger {
            // A backup that ended while this one waited for the runner.
            if !is_due(&self.vault, &dest, self.clock.now_ms()) {
                return;
            }
        }
        // The server creates `<dir>/<folder>`, never `<dir>`. When that
        // fails the backup still runs, so the core records why.
        if let Err(e) = std::fs::create_dir(&dest) {
            if e.kind() != io::ErrorKind::AlreadyExists {
                tracing::debug!(path = %dest.display(), error = %e, "backup: could not create the vault's backup folder");
            }
        }
        let vault = self.vault.as_path();
        let hook = self.hook.as_deref();
        let wrap_archive = |file: File| -> io::Result<Box<dyn ArchiveSink>> {
            match hook {
                Some(hook) => hook(vault, file),
                None => Ok(Box::new(file)),
            }
        };
        let seams = BackupSeams {
            clock: &*self.clock,
            probe: &fs_guard::probe,
            wrap_archive: &wrap_archive,
        };
        let request = BackupRequest {
            vault,
            destination: &dest,
            keep: self.config.keep,
            if_changed: matches!(self.trigger, Trigger::Scheduled),
            source: BackupSource::Hosted,
        };
        match core_backup::backup_with(&request, &seams) {
            Ok(BackupOutcome::Created { file, bytes, .. }) => tracing::info!(
                vault = %self.folder,
                result = "created",
                file = %file.display(),
                bytes,
                "backup"
            ),
            Ok(BackupOutcome::Unchanged { .. }) => {
                tracing::info!(vault = %self.folder, result = "unchanged", "backup")
            }
            Err(e) => tracing::warn!(
                vault = %self.folder,
                code = e.code(),
                error = %e,
                "backup failed"
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::key_of;

    #[test]
    fn the_in_flight_key_ignores_the_case_of_a_folder_name() {
        assert_eq!(key_of("Notes"), "notes");
        assert_eq!(key_of("Notes"), key_of("nOTES"));
        assert_ne!(key_of("notes"), key_of("notes2"));
    }
}
