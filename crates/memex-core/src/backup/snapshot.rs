//! The consistent `memex.db` snapshot (Spec #315 req 2, 2a; architecture
//! D6). Filler: R1a. Never through `Vault::open`.
//!
//! The source is opened read-only with no `configure_connection`, so the
//! vault is never migrated or written, and copied with SQLite's online
//! backup API in one `step(-1)`: one read transaction, so the copy holds
//! whole transactions only and writers in WAL mode are never blocked.

use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use rusqlite::backup::{Backup, StepResult};
use rusqlite::config::DbConfig;
use rusqlite::{Connection, OpenFlags};
use tempfile::TempPath;

use crate::error::MemexError;
use crate::vault::{ensure_sqlite_vec_registered, DB_FILENAME};
use crate::Result;

/// How long a writer may hold the source before the snapshot fails.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);
/// How long `step` is retried while the source is busy or locked.
const RETRY_FOR: Duration = Duration::from_secs(5);
const RETRY_PAUSE: Duration = Duration::from_millis(50);

/// A snapshot of `memex.db` in a temp file, deleted on drop.
#[derive(Debug)]
pub struct Snapshot {
    pub path: PathBuf,
    /// Read from the snapshot itself, not from `manifest.json`.
    pub schema_version: i64,
    /// Deletes the temp file when the snapshot is dropped.
    _temp: TempPath,
}

fn failed(what: &str, e: impl std::fmt::Display) -> MemexError {
    MemexError::BackupFailed(format!("snapshot: {what}: {e}"))
}

/// Takes the snapshot of `<vault>/memex.db`.
pub fn take_snapshot(vault: &Path) -> Result<Snapshot> {
    // Registered before any connection opens, as the vault itself is, so
    // vec0 tables are readable on both sides (D6).
    ensure_sqlite_vec_registered();

    let src_path = vault.join(DB_FILENAME);
    let src = Connection::open_with_flags(
        &src_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| failed(&format!("open {}", src_path.display()), e))?;
    src.busy_timeout(BUSY_TIMEOUT)
        .map_err(|e| failed("busy timeout", e))?;
    // Closing this connection must never write the vault's memex.db.
    src.set_db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true)
        .map_err(|e| failed("no checkpoint on close", e))?;

    // The temp file is deleted when `temp` drops, on every error path below.
    let temp = tempfile::Builder::new()
        .prefix("memex-snapshot-")
        .suffix(".db")
        .tempfile_in(std::env::temp_dir())
        .map_err(|e| failed("create temp file", e))?
        .into_temp_path();
    let mut dst = Connection::open(&temp).map_err(|e| failed("open temp file", e))?;

    copy(&src, &mut dst)?;
    drop(src);

    let check = quick_check(&dst)?;
    if check != "ok" {
        return Err(failed("quick_check", check));
    }
    let schema_version = schema_version(&dst)?;
    // Closing checkpoints and removes any -wal/-shm beside the temp file, so
    // its bytes alone are the whole snapshot.
    dst.close().map_err(|(_, e)| failed("close", e))?;

    Ok(Snapshot {
        path: temp.to_path_buf(),
        schema_version,
        _temp: temp,
    })
}

/// One `step(-1)`, retried while the source is busy or locked.
fn copy(src: &Connection, dst: &mut Connection) -> Result<()> {
    let backup = Backup::new(src, dst).map_err(|e| failed("start backup", e))?;
    let deadline = Instant::now() + RETRY_FOR;
    loop {
        match backup.step(-1).map_err(|e| failed("copy", e))? {
            StepResult::Done => return Ok(()),
            StepResult::Busy | StepResult::Locked if Instant::now() < deadline => {
                thread::sleep(RETRY_PAUSE);
            }
            StepResult::Busy | StepResult::Locked => {
                return Err(failed("copy", "memex.db stayed busy or locked"));
            }
            // `step(-1)` copies every page or none; anything else is a
            // result this SQLite never returns for it.
            other => return Err(failed("copy", format!("unexpected step result {other:?}"))),
        }
    }
}

/// The snapshot's memex schema version. Unlike `schema::current_version`,
/// which reads a missing `schema_version` table as 0, a copy with no memex
/// schema (an empty or truncated memex.db) is backup_failed, never a
/// backup of an empty database.
fn schema_version(conn: &Connection) -> Result<i64> {
    let version: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_version",
            [],
            |r| r.get(0),
        )
        .map_err(|e| failed("schema version", e))?;
    if version < 1 {
        return Err(failed("schema version", "memex.db has no memex schema"));
    }
    Ok(version)
}

fn quick_check(conn: &Connection) -> Result<String> {
    let mut stmt = conn
        .prepare("PRAGMA quick_check")
        .map_err(|e| failed("quick_check", e))?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| failed("quick_check", e))?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| failed("quick_check", e))?;
    Ok(rows.join("\n"))
}
