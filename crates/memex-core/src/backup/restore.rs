//! One restore of a backup into a new vault folder (Spec #315 req 32-34;
//! architecture D14). Filler: R2.
//!
//! The order is fixed:
//! 1. the network-drive guard on `--to`;
//! 2. `--to` must be absent or an empty folder;
//! 3. the archive's central directory, `manifest.json` and `backup.json` are
//!    validated in memory, before anything is written;
//! 4. the members are extracted to `<parent>/.<name>.restoring-<ulid>`;
//! 5. the extracted `memex.db` passes `quick_check` and its own schema
//!    version is checked;
//! 6. the temp folder is renamed onto `--to`.
//!
//! Any failure from step 4 on deletes the temp folder (and any parent
//! folder this restore created), so `--to` is left absent or as it was. The
//! vault is never migrated, its `vault_id` is the backup's, and
//! `backup.json` is never written into it.

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, BufReader, Read, Write};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use zip::ZipArchive;

use super::{RestoreOutcome, RestoreRequest, FORMAT};
use crate::error::MemexError;
use crate::fs_guard::{self, FsInfo};
use crate::schema::APP_SCHEMA_VERSION;
use crate::vault::{
    ensure_sqlite_vec_registered, VaultManifest, DB_FILENAME, MANIFEST_FILENAME, OBJECTS_DIR,
};
use crate::Result;

/// The member that describes the backup; read, never extracted.
const BACKUP_JSON: &str = "backup.json";
/// The largest `manifest.json` or `backup.json` read into memory.
const JSON_LIMIT: u64 = 1 << 20;

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;

/// See [`super::restore_with`].
pub fn restore_with(
    r: &RestoreRequest,
    probe: &dyn Fn(&Path) -> io::Result<FsInfo>,
) -> Result<RestoreOutcome> {
    let to = std::path::absolute(r.to)?;

    // (1) The network-drive guard, on the new vault folder only.
    fs_guard::check_with(&to, probe)?;
    // (2) Absent or an empty folder.
    check_target(&to)?;
    let (parent, name) = match (to.parent(), to.file_name()) {
        (Some(parent), Some(name)) => (parent.to_path_buf(), name.to_string_lossy().into_owned()),
        _ => {
            return Err(MemexError::InvalidPath(format!(
                "cannot restore into {}",
                to.display()
            )))
        }
    };

    // (3) Everything that can be checked without writing.
    let file = File::open(r.from)?;
    let mut archive =
        ZipArchive::new(BufReader::new(file)).map_err(|e| invalid(format!("not a zip: {e}")))?;
    let plan = validate(&mut archive)?;

    // (4)-(6) Writes, undone on any failure.
    let created = create_parents(&parent)?;
    let temp = parent.join(format!(".{name}.restoring-{}", ulid::Ulid::new()));
    let result = extract_check_and_rename(&mut archive, &plan, &temp, &to);
    if result.is_err() {
        let _ = fs::remove_dir_all(&temp);
        for dir in created.iter().rev() {
            let _ = fs::remove_dir(dir);
        }
    }
    result?;

    Ok(RestoreOutcome {
        vault_id: plan.vault_id,
        path: to,
        created_at: plan.created_at,
    })
}

fn invalid(message: impl Into<String>) -> MemexError {
    MemexError::BackupInvalid(message.into())
}

/// `--to` must not exist, or be a folder with nothing in it (hidden files
/// count). A file, a symlink or anything else is "not empty".
fn check_target(to: &Path) -> Result<()> {
    let meta = match fs::symlink_metadata(to) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    if meta.is_dir() && fs::read_dir(to)?.next().is_none() {
        return Ok(());
    }
    Err(not_empty(to))
}

fn not_empty(to: &Path) -> MemexError {
    MemexError::RestoreTargetNotEmpty(to.display().to_string())
}

/// What one member of the archive becomes in the vault folder.
enum Member {
    Db,
    Manifest,
    BackupJson,
    /// A folder under `objects/`; the path is relative to the vault.
    Dir(String),
    /// A file under `objects/`; the path is relative to the vault.
    Object(String),
}

/// The validated archive: one entry per member, by index.
struct Plan {
    members: Vec<(usize, Member)>,
    vault_id: String,
    created_at: i64,
    schema_version: i64,
}

/// Step 3: the central directory, `manifest.json` and `backup.json`,
/// all read into memory. Nothing is written.
fn validate<R: Read + io::Seek>(archive: &mut ZipArchive<R>) -> Result<Plan> {
    // Duplicate names (which `ZipArchive` would otherwise drop silently),
    // local headers that disagree with the central directory, overlapping
    // or hidden entries.
    archive
        .validate_header_consistency()
        .map_err(|e| invalid(format!("inconsistent zip: {e}")))?;

    let mut members = Vec::with_capacity(archive.len());
    let mut seen = BTreeSet::new();
    let mut files = BTreeSet::new();
    let mut dirs = BTreeSet::new();
    for index in 0..archive.len() {
        let entry = archive
            .by_index_data(index)
            .map_err(|e| invalid(format!("member {index}: {e}")))?;
        let name = entry
            .name()
            .map_err(|e| invalid(format!("member {index}: {e}")))?
            .into_owned();
        if entry.encrypted() {
            return Err(invalid(format!("{name:?} is encrypted")));
        }
        let member = classify(&name)?;
        let is_dir = matches!(member, Member::Dir(_));
        check_mode(&name, entry.unix_mode(), is_dir)?;
        if !seen.insert(name.clone()) {
            return Err(invalid(format!("{name:?} appears twice")));
        }
        match &member {
            Member::Dir(rel) => {
                dirs.insert(rel.clone());
            }
            Member::Object(rel) => {
                files.insert(rel.clone());
            }
            Member::Db | Member::Manifest | Member::BackupJson => {}
        }
        members.push((index, member));
    }
    // A file and a folder must never share a path: "objects/a" with
    // "objects/a/" or "objects/a/b".
    for rel in &files {
        let mut ancestor = Path::new(rel).parent();
        while let Some(dir) = ancestor {
            if files.contains(dir.to_string_lossy().as_ref()) {
                return Err(invalid(format!("{rel:?} is inside the file {dir:?}")));
            }
            ancestor = dir.parent();
        }
        if dirs.contains(rel) {
            return Err(invalid(format!("{rel:?} is both a file and a folder")));
        }
    }
    for required in [DB_FILENAME, MANIFEST_FILENAME, BACKUP_JSON] {
        if !seen.contains(required) {
            return Err(invalid(format!("{required} is missing")));
        }
    }

    let backup_json = read_json(archive, BACKUP_JSON)?;
    let manifest = read_json(archive, MANIFEST_FILENAME)?;
    let format = backup_json.get("format").and_then(Value::as_i64);
    if format != Some(FORMAT) {
        return Err(invalid(format!(
            "backup.json format is {}, not {FORMAT}",
            backup_json.get("format").unwrap_or(&Value::Null)
        )));
    }
    let vault_id = string_field(&backup_json, BACKUP_JSON, "vault_id")?;
    let manifest_vault_id = string_field(&manifest, MANIFEST_FILENAME, "vault_id")?;
    if vault_id != manifest_vault_id {
        return Err(invalid(format!(
            "backup.json names vault {vault_id}, manifest.json names {manifest_vault_id}"
        )));
    }
    // The restored vault must be one `Vault::open` reads and `memex backup`
    // backs up: the whole manifest, and a ULID vault_id.
    let manifest: VaultManifest = serde_json::from_value(manifest)
        .map_err(|e| invalid(format!("{MANIFEST_FILENAME}: {e}")))?;
    if ulid::Ulid::from_string(&vault_id).is_err() {
        return Err(invalid(format!("vault_id {vault_id:?} is not a ULID")));
    }
    let schema_version = int_field(&backup_json, "schema_version")?;
    let created_at = int_field(&backup_json, "created_at")?;
    if schema_version < 1 {
        return Err(invalid(format!(
            "backup.json schema_version {schema_version} is not a memex schema"
        )));
    }
    for version in [schema_version, manifest.schema_version] {
        if version > APP_SCHEMA_VERSION {
            return Err(MemexError::BackupTooNew {
                backup: version,
                supported: APP_SCHEMA_VERSION,
            });
        }
    }

    Ok(Plan {
        members,
        vault_id,
        created_at,
        schema_version,
    })
}

/// The member whitelist: exactly `memex.db`, `manifest.json`,
/// `backup.json`, `objects/` and `objects/<normal components>[/]`.
fn classify(name: &str) -> Result<Member> {
    match name {
        DB_FILENAME => return Ok(Member::Db),
        MANIFEST_FILENAME => return Ok(Member::Manifest),
        BACKUP_JSON => return Ok(Member::BackupJson),
        _ => {}
    }
    let unknown = || invalid(format!("{name:?} is not a member of a backup"));
    let rest = name
        .strip_prefix(OBJECTS_DIR)
        .and_then(|r| r.strip_prefix('/'))
        .ok_or_else(unknown)?;
    if rest.is_empty() {
        return Ok(Member::Dir(OBJECTS_DIR.to_string()));
    }
    let (rest, is_dir) = match rest.strip_suffix('/') {
        Some(dir) => (dir, true),
        None => (rest, false),
    };
    let safe = rest
        .split('/')
        .all(|c| !c.is_empty() && c != "." && c != ".." && !c.contains('\\') && !c.contains('\0'));
    if !safe {
        return Err(invalid(format!("{name:?} is not a safe path")));
    }
    let rel = format!("{OBJECTS_DIR}/{rest}");
    Ok(if is_dir {
        Member::Dir(rel)
    } else {
        Member::Object(rel)
    })
}

/// Only plain files and folders: a unix mode naming a symlink, FIFO,
/// device or socket, or a type that disagrees with the name, is refused.
/// No mode, or no type bits, means the name decides.
fn check_mode(name: &str, mode: Option<u32>, is_dir: bool) -> Result<()> {
    let kind = mode.unwrap_or(0) & S_IFMT;
    let want = if is_dir { S_IFDIR } else { S_IFREG };
    if kind == 0 || kind == want {
        Ok(())
    } else {
        Err(invalid(format!(
            "{name:?} is not a plain {} (mode {:o})",
            if is_dir { "folder" } else { "file" },
            mode.unwrap_or(0)
        )))
    }
}

/// A JSON member, read whole into memory (at most [`JSON_LIMIT`] bytes).
fn read_json<R: Read + io::Seek>(archive: &mut ZipArchive<R>, name: &str) -> Result<Value> {
    let entry = archive
        .by_name(name)
        .map_err(|e| invalid(format!("{name}: {e}")))?;
    let mut bytes = Vec::new();
    entry
        .take(JSON_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| invalid(format!("{name}: {e}")))?;
    if bytes.len() as u64 > JSON_LIMIT {
        return Err(invalid(format!("{name} is too large")));
    }
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|e| invalid(format!("{name}: {e}")))?;
    if !value.is_object() {
        return Err(invalid(format!("{name} is not a JSON object")));
    }
    Ok(value)
}

fn string_field(value: &Value, file: &str, key: &str) -> Result<String> {
    match value.get(key).and_then(Value::as_str) {
        Some(s) if !s.is_empty() => Ok(s.to_string()),
        _ => Err(invalid(format!("{file} has no {key}"))),
    }
}

fn int_field(value: &Value, key: &str) -> Result<i64> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| invalid(format!("backup.json has no integer {key}")))
}

/// Creates the missing ancestors of `parent`, as `memex init` does, and
/// returns the ones it created, outermost first, so a failure can remove
/// them again.
fn create_parents(parent: &Path) -> Result<Vec<PathBuf>> {
    let mut missing = Vec::new();
    let mut current = Some(parent);
    while let Some(dir) = current {
        if dir.as_os_str().is_empty() || fs::symlink_metadata(dir).is_ok() {
            break;
        }
        missing.push(dir.to_path_buf());
        current = dir.parent();
    }
    missing.reverse();
    if let Err(e) = fs::create_dir_all(parent) {
        for dir in missing.iter().rev() {
            let _ = fs::remove_dir(dir);
        }
        return Err(e.into());
    }
    Ok(missing)
}

/// Steps 4-6.
fn extract_check_and_rename<R: Read + io::Seek>(
    archive: &mut ZipArchive<R>,
    plan: &Plan,
    temp: &Path,
    to: &Path,
) -> Result<()> {
    fs::create_dir(temp)?;
    fs::create_dir(temp.join(OBJECTS_DIR))?;
    for (index, member) in &plan.members {
        let rel = match member {
            Member::BackupJson => continue,
            Member::Db => DB_FILENAME,
            Member::Manifest => MANIFEST_FILENAME,
            Member::Dir(rel) => {
                fs::create_dir_all(temp.join(rel)).map_err(clash)?;
                continue;
            }
            Member::Object(rel) => rel.as_str(),
        };
        let path = temp.join(rel);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(clash)?;
        }
        let entry = archive
            .by_index(*index)
            .map_err(|e| invalid(format!("{rel}: {e}")))?;
        extract_file(entry, &path, rel)?;
    }

    check_snapshot(&temp.join(DB_FILENAME), plan.schema_version)?;

    match fs::rename(temp, to) {
        Ok(()) => {}
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::DirectoryNotEmpty
                    | io::ErrorKind::AlreadyExists
                    | io::ErrorKind::NotADirectory
            ) =>
        {
            return Err(not_empty(to));
        }
        Err(e) => return Err(e.into()),
    }
    if let Some(parent) = to.parent() {
        // Best effort: the rename itself is already durable enough to use.
        if let Ok(dir) = File::open(parent) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

/// Two members landing on one path on this disk (a case-insensitive or
/// normalizing filesystem) make the backup unrestorable here.
fn clash(e: io::Error) -> MemexError {
    match e.kind() {
        io::ErrorKind::AlreadyExists | io::ErrorKind::NotADirectory => {
            invalid(format!("two members name the same path: {e}"))
        }
        _ => e.into(),
    }
}

/// Copies one member to a new file. A read failure (a bad CRC, cut-short
/// data) is `backup_invalid`; a write failure is the disk's.
fn extract_file(mut entry: impl Read, path: &Path, rel: &str) -> Result<()> {
    let mut out = File::options()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(clash)?;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = match entry.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(invalid(format!("{rel}: {e}"))),
        };
        out.write_all(&buf[..n])?;
    }
    out.sync_all()?;
    Ok(())
}

/// Step 5: the extracted snapshot is a whole database at a schema this
/// memex supports, and the one `backup.json` names. Read-only: the file is
/// restored exactly as the backup holds it.
fn check_snapshot(db: &Path, claimed: i64) -> Result<()> {
    // vec0 tables must be readable, as they are when the vault opens.
    ensure_sqlite_vec_registered();
    let bad = |e: rusqlite::Error| invalid(format!("memex.db: {e}"));
    let conn = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(bad)?;
    let check = {
        let mut stmt = conn.prepare("PRAGMA quick_check").map_err(bad)?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(bad)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(bad)?;
        rows.join("\n")
    };
    if check != "ok" {
        return Err(invalid(format!("memex.db fails quick_check: {check}")));
    }
    // Not `schema::current_version`, which reads a missing table as V0: a
    // database with no memex schema is not a snapshot.
    let version = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| {
            r.get::<_, Option<i64>>(0)
        })
        .map_err(bad)?
        .ok_or_else(|| invalid("memex.db has no schema version"))?;
    drop(conn);
    remove_read_side_files(db);
    if version > APP_SCHEMA_VERSION {
        return Err(MemexError::BackupTooNew {
            backup: version,
            supported: APP_SCHEMA_VERSION,
        });
    }
    if version != claimed {
        return Err(invalid(format!(
            "memex.db is at schema V{version}, backup.json says V{claimed}"
        )));
    }
    Ok(())
}

/// A read-only connection to a WAL-mode database leaves an empty `-wal`
/// and a `-shm` beside it; the restored vault starts without them. A
/// non-empty `-wal` (never written by a read-only connection) is kept.
fn remove_read_side_files(db: &Path) {
    let side = |suffix: &str| {
        let mut name = db.as_os_str().to_owned();
        name.push(suffix);
        PathBuf::from(name)
    };
    let wal = side("-wal");
    if fs::metadata(&wal).is_ok_and(|m| m.len() == 0) {
        let _ = fs::remove_file(&wal);
    }
    let _ = fs::remove_file(side("-shm"));
}
