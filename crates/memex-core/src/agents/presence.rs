//! Agent presence records (#390 req 3, 4, 5, 6).
//!
//! One JSON file per MCP session under `<vault>/.memex/agents/`. Every
//! function takes `now_ms` from the caller's `Clock`; none reads the clock.

use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};

/// Interval between presence heartbeats, in ms.
pub const HEARTBEAT_MS: i64 = 5_000;
/// Lifetime of a `stdio` record after its last heartbeat, in ms.
pub const STDIO_TTL_MS: i64 = 15_000;
/// Lifetime of a `bridge` record after its last heartbeat, in ms.
pub const BRIDGE_TTL_MS: i64 = 15_000;
/// Lifetime of an `http` record after its last request, in ms.
pub const HTTP_TTL_MS: i64 = 60_000;
/// Maximum length of `client_name` and `client_version`, in chars.
pub const IDENTITY_MAX_CHARS: usize = 64;

/// How the MCP client reaches the vault. Serialized as `stdio`, `bridge`
/// or `http`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Transport {
    Stdio,
    Bridge,
    Http,
}

/// One agent presence record, stored as `<presence_dir>/<session_id>.json`.
/// Timestamps are ms since the Unix epoch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceRecord {
    pub session_id: String,
    pub client_name: String,
    pub client_version: Option<String>,
    pub transport: Transport,
    pub started_at: i64,
    pub last_seen_at: i64,
    pub last_request_at: i64,
    pub last_tool_at: Option<i64>,
    pub expires_at: i64,
    pub embeddings: bool,
}

const RECORD_EXT: &str = "json";

/// `<vault_root>/.memex/agents`.
pub fn presence_dir(vault_root: &Path) -> PathBuf {
    vault_root.join(".memex").join("agents")
}

fn record_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join(format!("{session_id}.{RECORD_EXT}"))
}

/// Number of locks that `write` stripes its targets over.
const WRITE_LOCK_STRIPES: usize = 16;

/// Serialize `write` calls per target within this process, because they
/// share the fixed `<session_id>.json.tmp` staging path.
static WRITE_LOCKS: [Mutex<()>; WRITE_LOCK_STRIPES] =
    [const { Mutex::new(()) }; WRITE_LOCK_STRIPES];

fn lock_for(target: &Path) -> MutexGuard<'static, ()> {
    let mut hasher = DefaultHasher::new();
    target.hash(&mut hasher);
    let stripe = (hasher.finish() % WRITE_LOCK_STRIPES as u64) as usize;
    // The guarded data is `()`, so a poisoned lock is still safe to use.
    WRITE_LOCKS[stripe]
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Atomically writes `<dir>/<session_id>.json`, creating `dir` if missing:
/// writes `<session_id>.json.tmp`, then renames it over the record, so a
/// reader sees the old record or the new one, never a partial file.
///
/// Concurrent calls for one session in the same process are serialized, so
/// they never share a half-written tmp file. A session's records must be
/// written by one process only (the process that minted its `session_id`).
pub fn write(dir: &Path, record: &PresenceRecord) -> io::Result<()> {
    let bytes = serde_json::to_vec(record).map_err(io::Error::other)?;
    fs::create_dir_all(dir)?;
    let target = record_path(dir, &record.session_id);
    let tmp = dir.join(format!("{}.{RECORD_EXT}.tmp", record.session_id));
    let _guard = lock_for(&target);
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, &target)
}

/// `*.json` record files in `dir`; a missing or unreadable dir has none.
fn record_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == RECORD_EXT))
        .collect()
}

fn read_record(path: &Path) -> Option<PresenceRecord> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Every valid `*.json` record in `dir`, in no particular order. Ignores
/// `*.json.tmp` and other files and skips unreadable or malformed records;
/// a missing dir gives an empty list.
pub fn read_all(dir: &Path) -> Vec<PresenceRecord> {
    record_files(dir)
        .iter()
        .filter_map(|p| read_record(p))
        .collect()
}

/// Deletes `<dir>/<session_id>.json`; a missing file is `Ok`.
pub fn remove(dir: &Path, session_id: &str) -> io::Result<()> {
    match fs::remove_file(record_path(dir, session_id)) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// Deletes every valid `*.json` record in `dir` that `is_expired` at
/// `now_ms` and keeps the rest. Leaves `*.json.tmp`, other files and
/// malformed records alone. A missing dir is `Ok`. A record that is already
/// gone is skipped; any other failed delete does not stop the sweep, and the
/// first such error is returned once every record has been tried.
pub fn sweep(dir: &Path, now_ms: i64) -> io::Result<()> {
    let mut first_err = None;
    for path in record_files(dir) {
        let Some(record) = read_record(&path) else {
            continue;
        };
        if is_expired(&record, now_ms) {
            match fs::remove_file(&path) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => {
                    first_err.get_or_insert(e);
                }
                _ => {}
            }
        }
    }
    first_err.map_or(Ok(()), Err)
}

/// The expiry instant for a record with these timestamps (req 4):
/// `last_seen_at + 15_000` for `stdio` and `bridge`,
/// `last_request_at + 60_000` for `http`.
pub fn expires_at(transport: Transport, last_seen_at: i64, last_request_at: i64) -> i64 {
    match transport {
        Transport::Stdio => last_seen_at + STDIO_TTL_MS,
        Transport::Bridge => last_seen_at + BRIDGE_TTL_MS,
        Transport::Http => last_request_at + HTTP_TTL_MS,
    }
}

/// Whether `record` has expired at `now_ms`: `now_ms >= record.expires_at`,
/// using the stored `expires_at`.
pub fn is_expired(record: &PresenceRecord, now_ms: i64) -> bool {
    now_ms >= record.expires_at
}

/// `s` cut to at most `IDENTITY_MAX_CHARS` chars, on char boundaries.
pub fn truncate_identity(s: &str) -> String {
    s.chars().take(IDENTITY_MAX_CHARS).collect()
}
