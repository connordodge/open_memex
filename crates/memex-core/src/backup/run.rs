//! One backup of a local vault (Spec #315 req 1-17a; architecture D9).
//! Filler: R1b.
//!
//! The steps run in D9's fixed order. Steps 1-3 (the network-drive guard,
//! the manifest's vault_id, the lock) are never recorded; from step 4 on,
//! every failure is recorded in `backup-state.json` under the destination's
//! [`state::destination_key`], while the lock is held. The clock is read
//! once, at the start, and that one value stamps the file name, backup.json's
//! `created_at` and every time field recorded.

mod archive;

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde_json::Value;
use ulid::Ulid;

use super::{lock, names, snapshot, state, BackupOutcome, BackupRequest, BackupSeams};
use crate::error::MemexError;
use crate::vault::{MANIFEST_FILENAME, OBJECTS_DIR};
use crate::{fs_guard, Result};

/// See [`super::backup_with`].
pub fn backup_with(r: &BackupRequest, s: &BackupSeams) -> Result<BackupOutcome> {
    let now = s.clock.now_ms();
    // (1) The vault, never the destination, goes through the guard (req 13).
    fs_guard::check_with(r.vault, s.probe)?;
    // (2) A missing or unreadable vault folder is `internal` (req 17).
    let manifest = Manifest::read(r.vault)?;
    let vault_dir = fs::canonicalize(r.vault)?;
    // (3)
    let _lock = lock::try_lock(r.vault)?;

    let run = Run {
        request: r,
        seams: s,
        now,
        manifest: &manifest,
        vault_dir: &vault_dir,
    };
    run.locked().inspect_err(|e| {
        if let Err(not_recorded) = state::record_failed(r.vault, r.destination, now, e) {
            tracing::warn!(error = %not_recorded, "backup: could not record the failure");
        }
    })
}

/// `manifest.json`: its bytes go into the zip as read here.
struct Manifest {
    bytes: Vec<u8>,
    vault_id: String,
}

impl Manifest {
    fn read(vault: &Path) -> Result<Self> {
        let path = vault.join(MANIFEST_FILENAME);
        let bytes = fs::read(&path)?;
        let value: Value = serde_json::from_slice(&bytes).map_err(|e| {
            MemexError::BackupFailed(format!("{} is not JSON: {e}", path.display()))
        })?;
        let vault_id = value
            .get("vault_id")
            .and_then(Value::as_str)
            .filter(|id| Ulid::from_string(id).is_ok())
            .ok_or_else(|| {
                MemexError::BackupFailed(format!(
                    "{}: vault_id {} is not a ULID",
                    path.display(),
                    value.get("vault_id").unwrap_or(&Value::Null)
                ))
            })?
            .to_string();
        Ok(Manifest { bytes, vault_id })
    }
}

/// Steps 4-11, run while the lock is held.
struct Run<'a> {
    request: &'a BackupRequest<'a>,
    seams: &'a BackupSeams<'a>,
    now: i64,
    manifest: &'a Manifest,
    /// The vault folder, canonical.
    vault_dir: &'a Path,
}

impl Run<'_> {
    fn locked(&self) -> Result<BackupOutcome> {
        let r = self.request;
        let vault_id = &self.manifest.vault_id;
        // (4)
        let dest = check_destination(r.destination, self.vault_dir)?;
        let final_name = names::file_name(&label(self.vault_dir), self.now, vault_id);
        let partial_name = names::partial_name(&final_name);
        // (5)
        let mut partial = Partial::create(dest.join(&partial_name))?;
        // (6)
        delete_leftover_partials(&dest, vault_id, &partial_name)?;
        // (7)
        let snapshot = snapshot::take_snapshot(r.vault)?;
        let objects_dir = r.vault.join(OBJECTS_DIR);
        let objects = archive::list_objects(&objects_dir)?;
        let content = archive::Content {
            snapshot: &snapshot.path,
            manifest: &self.manifest.bytes,
            objects_dir: &objects_dir,
            objects: &objects,
        };

        // (8)
        if r.if_changed {
            let prior = state::destination_state(r.vault, r.destination);
            if let Some(prior) = prior.filter(|p| p.last_fingerprint.is_some()) {
                let fingerprint = content.fingerprint()?;
                if prior.last_fingerprint.as_deref() == Some(fingerprint.as_str()) {
                    partial.delete();
                    state::record_unchanged(r.vault, r.destination, self.now)
                        .map_err(not_recorded)?;
                    return Ok(BackupOutcome::Unchanged {
                        vault_id: vault_id.clone(),
                        fingerprint,
                        last_file: prior.last_file.map(|name| dest.join(name)),
                    });
                }
            }
        }

        // (9)
        let file = partial.take_file();
        let sync = file
            .try_clone()
            .map_err(|e| failed(&format!("open {}", partial.path.display()), e))?;
        let sink = (self.seams.wrap_archive)(file)
            .map_err(|e| failed(&format!("open {}", partial.path.display()), e))?;
        let info = archive::Info {
            vault_id,
            schema_version: snapshot.schema_version,
            created_at: self.now,
            source: r.source,
        };
        let fingerprint = content.write(sink, &info)?;
        sync.sync_all()
            .map_err(|e| failed(&format!("sync {}", partial.path.display()), e))?;
        let bytes = sync
            .metadata()
            .map_err(|e| failed(&format!("stat {}", partial.path.display()), e))?
            .len();
        drop(sync);
        let final_path = dest.join(&final_name);
        partial.rename_to(&final_path)?;
        sync_folder(&dest);

        // (10)
        let removed = retention(&dest, vault_id, &final_name, r.keep)?;
        // (11)
        state::record_created(
            r.vault,
            r.destination,
            self.now,
            &final_name,
            bytes,
            &fingerprint,
        )
        .map_err(not_recorded)?;
        Ok(BackupOutcome::Created {
            vault_id: vault_id.clone(),
            file: final_path,
            bytes,
            fingerprint,
            removed,
        })
    }
}

/// A `backup_failed` for an I/O step.
fn failed(what: &str, e: impl std::fmt::Display) -> MemexError {
    MemexError::BackupFailed(format!("{what}: {e}"))
}

/// Writing `backup-state.json` failed after the backup itself succeeded.
fn not_recorded(e: MemexError) -> MemexError {
    failed("record backup-state.json", e)
}

/// The label of the vault folder's name (D10).
fn label(vault_dir: &Path) -> String {
    let name = vault_dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    names::label_for(&name)
}

/// Step 4: `destination` is an existing folder outside the vault. Returns
/// its [`state::destination_key`] as a path: every file this run writes,
/// deletes or prints is under it.
fn check_destination(destination: &Path, vault_dir: &Path) -> Result<PathBuf> {
    let unavailable = |why: &dyn std::fmt::Display| {
        MemexError::BackupDestinationUnavailable(format!("{}: {why}", destination.display()))
    };
    match fs::metadata(destination) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => return Err(unavailable(&"not a folder")),
        Err(e) => return Err(unavailable(&e)),
    }
    let dest = PathBuf::from(state::destination_key(destination).map_err(|e| unavailable(&e))?);
    // Component-wise: `<root>/my notes backups` is not inside `<root>/my notes`.
    if dest.starts_with(vault_dir) {
        return Err(MemexError::BackupDestinationInsideVault(format!(
            "{} is inside {}",
            dest.display(),
            vault_dir.display()
        )));
    }
    Ok(dest)
}

/// This run's `.partial` file: deleted on every way out except the rename
/// to the final name (req 5).
struct Partial {
    path: PathBuf,
    file: Option<File>,
    armed: bool,
}

impl Partial {
    /// Step 5: create and truncate, so a leftover with this run's own name
    /// (an interrupted backup in the same second) starts empty.
    fn create(path: PathBuf) -> Result<Self> {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            // Never truncate whatever a symlink with this name points at.
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|e| match e.raw_os_error() {
                Some(libc::EACCES | libc::EPERM | libc::EROFS | libc::ENOENT) => {
                    MemexError::BackupDestinationUnavailable(format!(
                        "cannot write {}: {e}",
                        path.display()
                    ))
                }
                _ => failed(&format!("create {}", path.display()), e),
            })?;
        Ok(Partial {
            path,
            file: Some(file),
            armed: true,
        })
    }

    /// The open file, handed to the archive writer.
    fn take_file(&mut self) -> File {
        self.file.take().expect("the partial's file is taken once")
    }

    /// Deletes the partial now.
    fn delete(&mut self) {
        self.file = None;
        if self.armed {
            self.armed = false;
            if let Err(e) = fs::remove_file(&self.path) {
                tracing::warn!(path = %self.path.display(), error = %e, "backup: could not delete the partial");
            }
        }
    }

    /// Renames the complete partial to `final_path` (replacing a backup of
    /// the same second, req 4).
    fn rename_to(&mut self, final_path: &Path) -> Result<()> {
        fs::rename(&self.path, final_path).map_err(|e| {
            failed(
                &format!("rename {} to {}", self.path.display(), final_path.display()),
                e,
            )
        })?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for Partial {
    fn drop(&mut self) {
        self.delete();
    }
}

/// The names in `dest`. A name that isn't UTF-8 is no backup's and is skipped.
fn names_in(dest: &Path) -> Result<Vec<(String, fs::FileType)>> {
    let read = |e: io::Error| failed(&format!("list {}", dest.display()), e);
    let mut out = Vec::new();
    for entry in fs::read_dir(dest).map_err(read)? {
        let entry = entry.map_err(read)?;
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        out.push((name, entry.file_type().map_err(read)?));
    }
    Ok(out)
}

/// Step 6: deletes leftover `.partial` files of `vault_id` (any label), not
/// this run's own. One that can't be deleted is left for the next run.
fn delete_leftover_partials(dest: &Path, vault_id: &str, own: &str) -> Result<()> {
    for (name, _) in names_in(dest)? {
        if name != own && names::is_partial_for(&name, vault_id) {
            let path = dest.join(&name);
            if let Err(e) = fs::remove_file(&path) {
                tracing::warn!(path = %path.display(), error = %e, "backup: could not delete a leftover partial");
            }
        }
    }
    Ok(())
}

/// Step 10 (req 11): of the files in `dest` that parse as backups of
/// `vault_id`, keeps the one just written plus the newest `keep - 1` others
/// by file-name timestamp, and deletes the rest. Nothing else is read or
/// touched. Returns the deleted paths.
fn retention(dest: &Path, vault_id: &str, written: &str, keep: u16) -> Result<Vec<PathBuf>> {
    let mut others: Vec<(String, String)> = names_in(dest)?
        .into_iter()
        .filter(|(name, kind)| kind.is_file() && name != written)
        .filter_map(|(name, _)| {
            names::parse_file_name(&name)
                .filter(|p| p.vault_id == vault_id)
                .map(|p| (p.timestamp, name))
        })
        .collect();
    // Newest first; equal timestamps in a fixed order.
    others.sort_by(|a, b| b.cmp(a));
    let mut removed = Vec::new();
    for (_, name) in others.into_iter().skip(usize::from(keep).saturating_sub(1)) {
        let path = dest.join(&name);
        match fs::remove_file(&path) {
            Ok(()) => removed.push(path),
            // Someone else removed it first.
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(failed(&format!("retention: delete {}", path.display()), e)),
        }
    }
    Ok(removed)
}

/// Makes the rename durable. Some network filesystems refuse to sync a
/// folder; the file itself is already synced, so that is not a failure.
fn sync_folder(dest: &Path) {
    if let Err(e) = File::open(dest).and_then(|f| f.sync_all()) {
        tracing::debug!(path = %dest.display(), error = %e, "backup: folder sync skipped");
    }
}
