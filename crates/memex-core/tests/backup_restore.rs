//! WI #319 (R2): one restore of a backup into a new vault folder (Spec #315
//! req 32, 33, 33a, 34; architecture D14).
//!
//! D14 order: (1) the network-drive guard on `--to` (through the probe);
//! (2) `--to` absent or an empty folder, else `restore_target_not_empty`;
//! (3) the central directory and `backup.json` validated before any write;
//! (4) extract to `<parent>/.<name>.restoring-<ulid>`; (5) sqlite-vec,
//! `quick_check`, the snapshot's own schema version; (6) rename onto `--to`.
//! Any failure deletes the temp folder and leaves `--to` untouched.
//!
//! Archives are built here with the `zip` crate directly, hostile ones
//! included (names the crate's writer would refuse are byte-patched in), so
//! nothing depends on R1b's writer. Every path carries a space.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Cursor, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use memex_core::backup::{restore_with, RestoreOutcome, RestoreRequest};
use memex_core::fs_guard::FsInfo;
use memex_core::notes::{create_note, list_notes, CreateNote};
use memex_core::schema::{self, APP_SCHEMA_VERSION};
use memex_core::{MemexError, Vault};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use tempfile::TempDir;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

/// backup.json `created_at` in every fixture: distinct from any clock.
const CREATED_AT: i64 = 1_794_214_800_123;
/// A fingerprint-shaped hex string (restore never checks it).
const FINGERPRINT: &str = "4f2a9c0e8b7d6a5f4e3d2c1b0a99887766554433221100ffeeddccbbaa998877";
/// A vault_id that is not the source vault's.
const OTHER_VAULT_ID: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAE";

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

fn local_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(FsInfo::MacOs {
        fstypename: "apfs".into(),
        local: true,
    })
}

fn network_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(FsInfo::MacOs {
        fstypename: "smbfs".into(),
        local: false,
    })
}

fn failing_probe(_: &Path) -> io::Result<FsInfo> {
    Err(io::Error::other("statfs failed"))
}

// ---------------------------------------------------------------------------
// A source vault and its snapshot
// ---------------------------------------------------------------------------

/// A real vault with notes, snapshotted the way a backup does it.
struct Source {
    _tmp: TempDir,
    vault_id: String,
    db: Vec<u8>,
    manifest: Vec<u8>,
    /// (id, title, content_md) of every note.
    notes: Vec<(String, String, String)>,
}

fn source_vault(notes: &[(&str, &str)]) -> Source {
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("source vault");
    let mut vault = Vault::create(&root).unwrap();
    let vault_id = vault.vault_id().to_string();
    let mut made = Vec::new();
    for (title, body) in notes {
        let note = create_note(
            &mut vault,
            CreateNote {
                title: Some((*title).into()),
                content_md: (*body).into(),
                ..Default::default()
            },
        )
        .unwrap();
        made.push((note.id.to_string(), note.title, note.content_md));
    }
    // A vec0 table, as a vault with embeddings has: restore must register
    // sqlite-vec before it reads the snapshot.
    schema::ensure_vector_table(vault.connection_ref(), 4).unwrap();
    drop(vault);
    let db = snapshot_of(&root.join("memex.db"), tmp.path());
    let manifest = fs::read(root.join("manifest.json")).unwrap();
    Source {
        _tmp: tmp,
        vault_id,
        db,
        manifest,
        notes: made,
    }
}

/// One online-backup copy of `db` (D6), as bytes.
fn snapshot_of(db: &Path, scratch: &Path) -> Vec<u8> {
    let src = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let out = scratch.join(format!("snapshot {}.db", ulid::Ulid::new()));
    src.backup(rusqlite::MAIN_DB, &out, None).unwrap();
    drop(src);
    let bytes = fs::read(&out).unwrap();
    fs::remove_file(&out).unwrap();
    bytes
}

/// `db` with `sql` run over it (rollback journal, so the file is whole).
fn with_sql(db: &[u8], sql: &str) -> Vec<u8> {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("edit me.db");
    fs::write(&path, db).unwrap();
    let conn = Connection::open(&path).unwrap();
    conn.pragma_update(None, "journal_mode", "DELETE").unwrap();
    conn.execute_batch(sql).unwrap();
    drop(conn);
    fs::read(&path).unwrap()
}

/// `MAX(version)` of a snapshot's `schema_version` table.
fn db_schema_version(db: &[u8]) -> i64 {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("read me.db");
    fs::write(&path, db).unwrap();
    let conn = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    schema::current_version(&conn).unwrap()
}

/// The source snapshot pinned at V5: V6's tables, index and columns are
/// dropped and its version row deleted, so the first open has V6 to apply.
fn v5_db(db: &[u8]) -> Vec<u8> {
    let out = with_sql(
        db,
        "DROP INDEX idx_notes_guide;
         DROP TABLE vault_guide_revisions;
         DROP TABLE feedback;
         DROP TABLE tag_corrections;
         ALTER TABLE tags DROP COLUMN first_line;
         ALTER TABLE tags DROP COLUMN origin;
         DELETE FROM schema_version WHERE version = 6;",
    );
    assert_eq!(db_schema_version(&out), 5, "fixture: the V5 snapshot");
    out
}

/// A manifest.json with `schema_version` replaced.
fn manifest_at(manifest: &[u8], version: i64) -> Vec<u8> {
    let mut m: Value = serde_json::from_slice(manifest).unwrap();
    m["schema_version"] = json!(version);
    serde_json::to_vec_pretty(&m).unwrap()
}

// ---------------------------------------------------------------------------
// Archives
// ---------------------------------------------------------------------------

enum Member {
    File(String, Vec<u8>),
    Dir(String),
    Symlink(String, String),
}

fn file(name: &str, bytes: &[u8]) -> Member {
    Member::File(name.into(), bytes.to_vec())
}

fn dir(name: &str) -> Member {
    Member::Dir(name.into())
}

/// A zip of `members`, in order, deflated, with unix modes.
fn zip_of(members: &[Member]) -> Vec<u8> {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    let opts = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .unix_permissions(0o644);
    for m in members {
        match m {
            Member::File(name, bytes) => {
                w.start_file(name.as_str(), opts).unwrap();
                w.write_all(bytes).unwrap();
            }
            Member::Dir(name) => {
                w.add_directory(name.as_str(), opts.unix_permissions(0o755))
                    .unwrap();
            }
            Member::Symlink(name, target) => {
                w.add_symlink(name.as_str(), target.as_str(), opts).unwrap();
            }
        }
    }
    w.finish().unwrap().into_inner()
}

/// Replaces the member name `from` with `to` (same length) in the local
/// header and the central directory: exactly two occurrences.
fn rename_member(archive: &[u8], from: &str, to: &str) -> Vec<u8> {
    assert_eq!(from.len(), to.len(), "fixture: same-length rename");
    let needle = from.as_bytes();
    let hits: Vec<usize> = archive
        .windows(needle.len())
        .enumerate()
        .filter(|(_, w)| *w == needle)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(hits.len(), 2, "fixture: {from:?} in local + central header");
    let mut out = archive.to_vec();
    for i in hits {
        out[i..i + needle.len()].copy_from_slice(to.as_bytes());
    }
    out
}

/// Sets the unix mode (file type bits included) of the member `name` in the
/// central directory, where readers take it from.
fn set_unix_mode(archive: &[u8], name: &str, mode: u32) -> Vec<u8> {
    let mut out = archive.to_vec();
    let mut hits = 0;
    let mut i = 0;
    while i + 46 <= out.len() {
        if out[i..i + 4] == [0x50, 0x4b, 0x01, 0x02] {
            let name_len = u16::from_le_bytes([out[i + 28], out[i + 29]]) as usize;
            if out.get(i + 46..i + 46 + name_len) == Some(name.as_bytes()) {
                let attrs = (mode << 16) | (out[i + 38] as u32 & 0xFF);
                out[i + 38..i + 42].copy_from_slice(&attrs.to_le_bytes());
                // "made by" unix, so the high half is read as a unix mode.
                out[i + 5] = 3;
                hits += 1;
            }
        }
        i += 1;
    }
    assert_eq!(hits, 1, "fixture: one central entry named {name:?}");
    let mode_read = zip::ZipArchive::new(Cursor::new(&out))
        .unwrap()
        .by_name(name)
        .unwrap()
        .unix_mode();
    assert_eq!(mode_read, Some(mode), "fixture: the reader sees the mode");
    out
}

/// The parts of one backup, before they become a zip.
#[derive(Clone)]
struct Parts {
    db: Vec<u8>,
    manifest: Vec<u8>,
    backup_json: Value,
    /// Directory entries under objects/ (e.g. "objects/", "objects/ab/").
    dirs: Vec<String>,
    /// File entries under objects/.
    objects: Vec<(String, Vec<u8>)>,
}

impl Parts {
    /// A valid backup of `source`, with two objects in nested folders.
    fn of(source: &Source) -> Parts {
        Parts {
            db: source.db.clone(),
            manifest: source.manifest.clone(),
            backup_json: json!({
                "format": 1,
                "vault_id": source.vault_id,
                "schema_version": APP_SCHEMA_VERSION,
                "created_at": CREATED_AT,
                "memex_version": "0.1.0",
                "fingerprint": FINGERPRINT,
                "source": "local",
            }),
            dirs: vec![
                "objects/".into(),
                "objects/ab/".into(),
                "objects/ab/cd ef/".into(),
            ],
            objects: vec![
                (
                    "objects/ab/cd ef/photo 1.png".into(),
                    b"\x89PNG fake image".to_vec(),
                ),
                ("objects/top level.txt".into(), b"an attachment".to_vec()),
            ],
        }
    }

    /// D7 member order: memex.db, manifest.json, objects/…, backup.json.
    fn members(&self) -> Vec<Member> {
        let mut out = vec![
            file("memex.db", &self.db),
            file("manifest.json", &self.manifest),
        ];
        out.extend(self.dirs.iter().map(|d| dir(d)));
        out.extend(self.objects.iter().map(|(n, b)| file(n, b)));
        out.push(file(
            "backup.json",
            &serde_json::to_vec(&self.backup_json).unwrap(),
        ));
        out
    }

    fn zip(&self) -> Vec<u8> {
        zip_of(&self.members())
    }

    /// The archive with one extra member inserted before backup.json.
    fn zip_with(&self, extra: Member) -> Vec<u8> {
        let mut members = self.members();
        let last = members.len() - 1;
        members.insert(last, extra);
        zip_of(&members)
    }

    /// The archive without the member named `name`.
    fn zip_without(&self, name: &str) -> Vec<u8> {
        let members: Vec<Member> = self
            .members()
            .into_iter()
            .filter(|m| !matches!(m, Member::File(n, _) if n == name))
            .collect();
        zip_of(&members)
    }
}

// ---------------------------------------------------------------------------
// The restore fixture: a parent folder, a target in it, a backups folder
// ---------------------------------------------------------------------------

struct Fx {
    tmp: TempDir,
    parent: PathBuf,
    to: PathBuf,
    backups: PathBuf,
}

impl Fx {
    fn new() -> Fx {
        let tmp = TempDir::new().unwrap();
        let parent = tmp.path().join("restore parent");
        let backups = tmp.path().join("My Drive backups");
        fs::create_dir(&parent).unwrap();
        fs::create_dir(&backups).unwrap();
        let to = parent.join("notes restored");
        Fx {
            tmp,
            parent,
            to,
            backups,
        }
    }

    /// Writes `bytes` as a backup file in the backups folder.
    fn backup_file(&self, bytes: &[u8]) -> PathBuf {
        let path = self.backups.join(format!(
            "notes-20261109T090000Z-{}.memex.zip",
            ulid::Ulid::new()
        ));
        fs::write(&path, bytes).unwrap();
        path
    }

    fn restore(&self, from: &Path) -> memex_core::Result<RestoreOutcome> {
        self.restore_to(from, &self.to)
    }

    fn restore_to(&self, from: &Path, to: &Path) -> memex_core::Result<RestoreOutcome> {
        restore_with(&RestoreRequest { from, to }, &local_probe)
    }

    /// What a failure must leave as it was.
    fn before(&self) -> Before {
        Before {
            parent_listing: listing(&self.parent),
            parent_mtime: mtime(&self.parent),
            to: tree(&self.to),
        }
    }
}

/// The parent's listing and mtime, and `--to`'s whole tree, before a call.
struct Before {
    parent_listing: Vec<String>,
    parent_mtime: SystemTime,
    to: Option<BTreeMap<String, Option<Vec<u8>>>>,
}

impl Before {
    /// The parent's listing is unchanged (no `.restoring-` temp left) and
    /// `--to` is absent or unchanged.
    fn assert_untouched(&self, fx: &Fx, case: &str) {
        assert_eq!(
            listing(&fx.parent),
            self.parent_listing,
            "{case}: the parent folder's listing changed"
        );
        assert!(
            !listing(&fx.parent)
                .iter()
                .any(|n| n.contains(".restoring-")),
            "{case}: a .restoring- temp folder was left"
        );
        assert_eq!(tree(&fx.to), self.to, "{case}: --to changed");
    }

    /// Nothing at all was written in the parent: the failure came from the
    /// central-directory checks, before any write (req 33a).
    fn assert_nothing_written(&self, fx: &Fx, case: &str) {
        self.assert_untouched(fx, case);
        assert_eq!(
            mtime(&fx.parent),
            self.parent_mtime,
            "{case}: the parent folder was written to before the archive was validated"
        );
    }
}

fn listing(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn mtime(path: &Path) -> SystemTime {
    fs::metadata(path).unwrap().modified().unwrap()
}

/// Every entry under `root` by relative path: `Some(bytes)` for files,
/// `None` for folders. `None` overall when `root` doesn't exist; a file at
/// `root` itself is the entry "".
fn tree(root: &Path) -> Option<BTreeMap<String, Option<Vec<u8>>>> {
    let meta = fs::symlink_metadata(root).ok()?;
    let mut out = BTreeMap::new();
    if meta.is_file() {
        out.insert(String::new(), Some(fs::read(root).unwrap()));
        return Some(out);
    }
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, Option<Vec<u8>>>) {
        for e in fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let path = e.path();
            let rel = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            let ft = e.file_type().unwrap();
            if ft.is_dir() {
                out.insert(rel, None);
                walk(root, &path, out);
            } else {
                out.insert(rel, Some(fs::read(&path).unwrap()));
            }
        }
    }
    walk(root, root, &mut out);
    Some(out)
}

/// The error's C1 code; panics on success.
fn code_of(result: memex_core::Result<RestoreOutcome>) -> String {
    match result {
        Ok(outcome) => panic!("expected a refusal, got {outcome:?}"),
        Err(e) => e.code().to_string(),
    }
}

fn error_of(result: memex_core::Result<RestoreOutcome>) -> MemexError {
    match result {
        Ok(outcome) => panic!("expected a refusal, got {outcome:?}"),
        Err(e) => e,
    }
}

fn notes_source() -> Source {
    source_vault(&[
        (
            "Garden plan",
            "# Garden plan\n\nTomatoes by the #garden wall.\n",
        ),
        ("Reading list", "Books for the winter.\n"),
    ])
}

/// Runs each `(case, archive bytes)` against a fresh fixture and asserts
/// `backup_invalid` with nothing written before validation.
fn assert_each_invalid_before_any_write(cases: Vec<(&str, Vec<u8>)>) {
    for (case, bytes) in cases {
        let fx = Fx::new();
        let from = fx.backup_file(&bytes);
        let before = fx.before();
        assert_eq!(code_of(fx.restore(&from)), "backup_invalid", "{case}");
        before.assert_nothing_written(&fx, case);
    }
}

// ---------------------------------------------------------------------------
// AC: round trip (hand-built archive; the CLI round trip is cli_restore.rs)
// ---------------------------------------------------------------------------

#[test]
fn restore_round_trip_keeps_notes_objects_and_the_backup_vault_id() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    let outcome = fx.restore(&from).expect("restore");

    assert_eq!(outcome.vault_id, source.vault_id, "the backup's vault_id");
    let vault = Vault::open(&fx.to).expect("the restored folder opens as a vault");
    assert_eq!(vault.vault_id(), source.vault_id, "L8: vault_id kept");
    let mut got: Vec<(String, String, String)> = list_notes(&vault, 100)
        .unwrap()
        .into_iter()
        .map(|n| (n.id.to_string(), n.title, n.content_md))
        .collect();
    got.sort();
    let mut want = source.notes.clone();
    want.sort();
    assert_eq!(got, want, "the same notes");
    for (name, bytes) in &parts.objects {
        assert_eq!(
            fs::read(fx.to.join(name)).unwrap_or_else(|e| panic!("{name}: {e}")),
            *bytes,
            "{name}"
        );
    }
    assert!(fx.to.join("objects/ab/cd ef").is_dir());
    let n: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM chunk_vec", [], |r| r.get(0))
        .expect("the vec0 table still works");
    assert_eq!(n, 0);
}

#[test]
fn restore_writes_the_snapshot_and_manifest_byte_for_byte() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    fx.restore(&from).expect("restore");

    assert_eq!(
        fs::read(fx.to.join("manifest.json")).unwrap(),
        parts.manifest,
        "manifest.json as the backup holds it"
    );
    assert_eq!(
        fs::read(fx.to.join("memex.db")).unwrap(),
        parts.db,
        "memex.db as the backup holds it: restore never migrates or rewrites it"
    );
}

#[test]
fn object_files_without_directory_entries_restore_into_their_folders() {
    let source = notes_source();
    let mut parts = Parts::of(&source);
    parts.dirs.clear();
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    fx.restore(&from).expect("restore");

    for (name, bytes) in &parts.objects {
        assert_eq!(fs::read(fx.to.join(name)).unwrap(), *bytes, "{name}");
    }
}

// ---------------------------------------------------------------------------
// AC: a V5 backup restores at V5 and migrates on first open
// ---------------------------------------------------------------------------

#[test]
fn a_v5_backup_restores_at_v5_and_the_first_open_migrates_it() {
    let source = notes_source();
    let mut parts = Parts::of(&source);
    parts.db = v5_db(&source.db);
    parts.manifest = manifest_at(&source.manifest, 5);
    parts.backup_json["schema_version"] = json!(5);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    fx.restore(&from).expect("a V5 backup restores");

    let manifest: Value =
        serde_json::from_slice(&fs::read(fx.to.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(
        manifest["schema_version"], 5,
        "the restored manifest still says 5"
    );
    assert_eq!(
        db_schema_version(&fs::read(fx.to.join("memex.db")).unwrap()),
        5,
        "restore never migrates"
    );

    let vault = Vault::open(&fx.to).expect("the first open migrates");
    assert_eq!(vault.schema_version(), APP_SCHEMA_VERSION);
    assert_eq!(vault.vault_id(), source.vault_id);
    let manifest: Value =
        serde_json::from_slice(&fs::read(fx.to.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["schema_version"], APP_SCHEMA_VERSION);
    let feedback: i64 = vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM feedback", [], |r| r.get(0))
        .expect("V6's feedback table exists after the first open");
    assert_eq!(feedback, 0);
    assert_eq!(list_notes(&vault, 100).unwrap().len(), source.notes.len());
}

// ---------------------------------------------------------------------------
// AC: --to must be absent or an empty folder
// ---------------------------------------------------------------------------

#[test]
fn a_non_empty_to_folder_fails_with_restore_target_not_empty_and_is_unchanged() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    fs::create_dir(&fx.to).unwrap();
    fs::write(fx.to.join("keep me.md"), "mine").unwrap();
    fs::create_dir(fx.to.join("sub folder")).unwrap();
    fs::write(fx.to.join("sub folder/also mine.txt"), "also mine").unwrap();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "restore_target_not_empty");
    before.assert_untouched(&fx, "non-empty --to");
}

#[test]
fn a_to_folder_holding_only_a_hidden_file_is_not_empty() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    fs::create_dir(&fx.to).unwrap();
    fs::write(fx.to.join(".hidden"), "x").unwrap();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "restore_target_not_empty");
    before.assert_untouched(&fx, "--to with a hidden file");
}

#[test]
fn a_to_that_is_a_file_fails_with_restore_target_not_empty_and_is_unchanged() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    fs::write(&fx.to, "a file, not a folder").unwrap();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "restore_target_not_empty");
    before.assert_untouched(&fx, "--to is a file");
}

#[test]
fn the_target_check_runs_before_the_archive_is_read() {
    let fx = Fx::new();
    fs::create_dir(&fx.to).unwrap();
    fs::write(fx.to.join("keep me.md"), "mine").unwrap();
    let from = fx.backup_file(b"not a zip at all");
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "restore_target_not_empty");
    before.assert_nothing_written(&fx, "non-empty --to, non-zip --from");
}

#[test]
fn restoring_twice_to_the_same_folder_fails_the_second_time() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());
    fx.restore(&from).expect("first restore");
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "restore_target_not_empty");
    before.assert_untouched(&fx, "second restore");
}

#[test]
fn an_existing_empty_to_folder_restores_into_it() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let fx = Fx::new();
    fs::create_dir(&fx.to).unwrap();
    let from = fx.backup_file(&parts.zip());

    let outcome = fx.restore(&from).expect("an empty --to is fine");

    assert_eq!(outcome.vault_id, source.vault_id);
    assert_eq!(listing(&fx.parent), vec!["notes restored".to_string()]);
    let vault = Vault::open(&fx.to).unwrap();
    assert_eq!(list_notes(&vault, 100).unwrap().len(), source.notes.len());
}

#[test]
fn missing_parents_of_to_are_created() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let fx = Fx::new();
    let to = fx
        .parent
        .join("new folder")
        .join("deeper one")
        .join("notes restored");
    let from = fx.backup_file(&parts.zip());

    let outcome = fx
        .restore_to(&from, &to)
        .expect("parents created as memex init does");

    assert_eq!(outcome.vault_id, source.vault_id);
    assert!(to.join("manifest.json").is_file());
    assert_eq!(
        listing(to.parent().unwrap()),
        vec!["notes restored".to_string()]
    );
}

// ---------------------------------------------------------------------------
// AC: the network-drive guard on --to
// ---------------------------------------------------------------------------

#[test]
fn a_to_on_a_network_filesystem_fails_with_network_filesystem_and_creates_nothing() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    let to = fx.parent.join("new folder").join("notes restored");
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    let result = restore_with(
        &RestoreRequest {
            from: &from,
            to: &to,
        },
        &network_probe,
    );

    assert_eq!(code_of(result), "network_filesystem");
    before.assert_nothing_written(&fx, "network --to");
    assert!(!fx.parent.join("new folder").exists());
}

#[test]
fn the_network_guard_runs_before_the_target_check() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    fs::create_dir(&fx.to).unwrap();
    fs::write(fx.to.join("keep me.md"), "mine").unwrap();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    let result = restore_with(
        &RestoreRequest {
            from: &from,
            to: &fx.to,
        },
        &network_probe,
    );

    assert_eq!(code_of(result), "network_filesystem");
    before.assert_untouched(&fx, "network, non-empty --to");
}

#[test]
fn a_backup_file_on_a_network_share_restores_to_a_local_folder() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());
    let share = fx.backups.clone();
    let probe = move |p: &Path| -> io::Result<FsInfo> {
        if p.starts_with(&share) {
            network_probe(p)
        } else {
            local_probe(p)
        }
    };

    let outcome = restore_with(
        &RestoreRequest {
            from: &from,
            to: &fx.to,
        },
        &probe,
    )
    .expect("the guard applies to --to, not to the backup file");

    assert_eq!(outcome.vault_id, source.vault_id);
}

#[test]
fn a_failing_probe_refuses_the_restore_and_creates_nothing() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    let result = restore_with(
        &RestoreRequest {
            from: &from,
            to: &fx.to,
        },
        &failing_probe,
    );

    assert_eq!(code_of(result), "internal", "never treated as safe");
    before.assert_nothing_written(&fx, "failing probe");
}

// ---------------------------------------------------------------------------
// AC: each of these fails with backup_invalid
// ---------------------------------------------------------------------------

#[test]
fn a_non_zip_or_corrupt_zip_fails_with_backup_invalid_and_writes_nothing() {
    let parts = Parts::of(&notes_source());
    let good = parts.zip();
    let mut truncated = good.clone();
    truncated.truncate(good.len() - 30);
    let mut garbled_directory = good.clone();
    let len = garbled_directory.len();
    garbled_directory[len - 200..len - 22].fill(0xA5);
    assert_each_invalid_before_any_write(vec![
        ("a text file", b"these are my notes, not a zip\n".to_vec()),
        ("an empty file", Vec::new()),
        ("a zip cut short", truncated),
        ("a zip with a garbled central directory", garbled_directory),
    ]);
}

#[test]
fn a_member_whose_data_fails_its_crc_fails_with_backup_invalid_and_leaves_no_temp() {
    // The central directory is fine; memex.db's stored bytes are not. Found
    // only while extracting, so the temp folder must be cleaned up.
    let source = notes_source();
    let parts = Parts::of(&source);
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    let stored = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Stored)
        .unix_permissions(0o644);
    for m in parts.members() {
        if let Member::File(name, bytes) = m {
            w.start_file(name.as_str(), stored).unwrap();
            w.write_all(&bytes).unwrap();
        }
    }
    let mut bytes = w.finish().unwrap().into_inner();
    // memex.db is the first member: its data starts after a 30-byte local
    // header and the 8-byte name; flip bytes well inside it.
    for b in &mut bytes[30 + 8 + 5000..30 + 8 + 5100] {
        *b ^= 0xFF;
    }
    let fx = Fx::new();
    let from = fx.backup_file(&bytes);
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "backup_invalid");
    before.assert_untouched(&fx, "crc mismatch");
}

#[test]
fn a_missing_memex_db_manifest_or_backup_json_fails_with_backup_invalid() {
    let parts = Parts::of(&notes_source());
    assert_each_invalid_before_any_write(vec![
        ("no memex.db", parts.zip_without("memex.db")),
        ("no manifest.json", parts.zip_without("manifest.json")),
        ("no backup.json", parts.zip_without("backup.json")),
    ]);
}

#[test]
fn backup_json_format_2_fails_with_backup_invalid() {
    let source = notes_source();
    let mut format_2 = Parts::of(&source);
    format_2.backup_json["format"] = json!(2);
    let mut format_0 = Parts::of(&source);
    format_0.backup_json["format"] = json!(0);
    let mut no_format = Parts::of(&source);
    no_format
        .backup_json
        .as_object_mut()
        .unwrap()
        .remove("format");
    let mut format_text = Parts::of(&source);
    format_text.backup_json["format"] = json!("1");
    assert_each_invalid_before_any_write(vec![
        ("format 2", format_2.zip()),
        ("format 0", format_0.zip()),
        ("no format", no_format.zip()),
        ("format \"1\"", format_text.zip()),
    ]);
}

#[test]
fn unreadable_backup_json_or_manifest_json_fails_with_backup_invalid() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let mut bad_backup_json = parts.members();
    let last = bad_backup_json.len() - 1;
    bad_backup_json[last] = file("backup.json", b"{\"format\":1,");
    let mut bad_manifest = parts.clone();
    bad_manifest.manifest = b"not json".to_vec();
    assert_each_invalid_before_any_write(vec![
        ("backup.json not JSON", zip_of(&bad_backup_json)),
        ("manifest.json not JSON", bad_manifest.zip()),
    ]);
}

#[test]
fn mismatched_vault_ids_fail_with_backup_invalid() {
    let source = notes_source();
    let mut other_in_backup_json = Parts::of(&source);
    other_in_backup_json.backup_json["vault_id"] = json!(OTHER_VAULT_ID);
    let mut lowercase = Parts::of(&source);
    lowercase.backup_json["vault_id"] = json!(source.vault_id.to_lowercase());
    let mut other_in_manifest = Parts::of(&source);
    let mut m: Value = serde_json::from_slice(&source.manifest).unwrap();
    m["vault_id"] = json!(OTHER_VAULT_ID);
    other_in_manifest.manifest = serde_json::to_vec_pretty(&m).unwrap();
    let mut missing = Parts::of(&source);
    missing
        .backup_json
        .as_object_mut()
        .unwrap()
        .remove("vault_id");
    assert_each_invalid_before_any_write(vec![
        (
            "backup.json names another vault",
            other_in_backup_json.zip(),
        ),
        ("backup.json vault_id in another case", lowercase.zip()),
        ("manifest.json names another vault", other_in_manifest.zip()),
        ("backup.json without vault_id", missing.zip()),
    ]);
}

#[test]
fn unsafe_member_names_fail_with_backup_invalid_before_any_write() {
    let parts = Parts::of(&notes_source());
    let x = b"escaped".as_slice();
    assert_each_invalid_before_any_write(vec![
        ("../x", parts.zip_with(file("../x", x))),
        ("/abs", parts.zip_with(file("/abs", x))),
        ("/abs under objects", parts.zip_with(file("/objects/x", x))),
        ("objects/../x", parts.zip_with(file("objects/../x", x))),
        (
            "objects/ab/../../x",
            parts.zip_with(file("objects/ab/../../x", x)),
        ),
        ("objects\\x", parts.zip_with(file("objects\\x", x))),
        (
            "objects/ab\\..\\..\\x",
            parts.zip_with(file("objects/ab\\..\\..\\x", x)),
        ),
        ("objects/./x", parts.zip_with(file("objects/./x", x))),
        ("objects//x", parts.zip_with(file("objects//x", x))),
        ("objects/..", parts.zip_with(dir("objects/../"))),
        (
            "./manifest.json",
            parts.zip_with(file("./manifest.json", x)),
        ),
    ]);
}

#[test]
fn a_duplicate_member_name_fails_with_backup_invalid() {
    let parts = Parts::of(&notes_source());
    let other_db = b"SQLite format 3\0 second copy".as_slice();
    let dup_db = rename_member(
        &parts.zip_with(file("memex.dX", other_db)),
        "memex.dX",
        "memex.db",
    );
    let dup_object = rename_member(
        &parts.zip_with(file("objects/top level.tx_", b"second")),
        "objects/top level.tx_",
        "objects/top level.txt",
    );
    let mut dup_backup_json = parts.members();
    dup_backup_json.push(file(
        "backup.jsoX",
        &serde_json::to_vec(&json!({"format": 1})).unwrap(),
    ));
    let dup_backup_json = rename_member(&zip_of(&dup_backup_json), "backup.jsoX", "backup.json");
    assert_each_invalid_before_any_write(vec![
        ("memex.db twice", dup_db),
        ("an object twice", dup_object),
        ("backup.json twice", dup_backup_json),
    ]);
}

#[test]
fn a_symlink_member_fails_with_backup_invalid() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let link = |name: &str, target: &str| Member::Symlink(name.into(), target.into());
    // A symlink folder followed by a file written through it.
    let mut through = parts.members();
    let last = through.len() - 1;
    through.insert(last, link("objects/escape", "/tmp"));
    through.insert(last + 1, file("objects/escape/planted.txt", b"planted"));
    // manifest.json itself as a symlink.
    let mut manifest_link: Vec<Member> = parts
        .members()
        .into_iter()
        .filter(|m| !matches!(m, Member::File(n, _) if n == "manifest.json"))
        .collect();
    manifest_link.insert(1, link("manifest.json", "/etc/hosts"));
    assert_each_invalid_before_any_write(vec![
        (
            "a symlink object",
            parts.zip_with(link("objects/link", "/etc/passwd")),
        ),
        (
            "a relative symlink object",
            parts.zip_with(link("objects/up", "../..")),
        ),
        ("a symlink folder, then a file through it", zip_of(&through)),
        ("manifest.json as a symlink", zip_of(&manifest_link)),
    ]);
}

#[test]
fn a_member_of_another_unix_entry_type_fails_with_backup_invalid() {
    // Only plain files and folders: a FIFO, a device or a socket, whether
    // an object or a vault file, is refused (req 33a).
    let parts = Parts::of(&notes_source());
    let good = parts.zip();
    let object = "objects/top level.txt";
    assert_each_invalid_before_any_write(vec![
        ("a FIFO object", set_unix_mode(&good, object, 0o010644)),
        (
            "a character device object",
            set_unix_mode(&good, object, 0o020644),
        ),
        (
            "a block device object",
            set_unix_mode(&good, object, 0o060644),
        ),
        ("a socket object", set_unix_mode(&good, object, 0o140644)),
        (
            "manifest.json as a FIFO",
            set_unix_mode(&good, "manifest.json", 0o010644),
        ),
        (
            "memex.db as a symlink by mode",
            set_unix_mode(&good, "memex.db", 0o120644),
        ),
        (
            "an objects folder entry as a FIFO",
            set_unix_mode(&good, "objects/ab/", 0o010755),
        ),
    ]);
}

#[test]
fn backup_json_without_schema_version_or_created_at_fails_with_backup_invalid() {
    let source = notes_source();
    let without = |key: &str| {
        let mut parts = Parts::of(&source);
        parts.backup_json.as_object_mut().unwrap().remove(key);
        parts.zip()
    };
    let mut text_version = Parts::of(&source);
    text_version.backup_json["schema_version"] = json!("6");
    let mut text_created = Parts::of(&source);
    text_created.backup_json["created_at"] = json!("yesterday");
    let mut not_an_object = Parts::of(&source).members();
    let last = not_an_object.len() - 1;
    not_an_object[last] = file("backup.json", b"[1]");
    assert_each_invalid_before_any_write(vec![
        ("no schema_version", without("schema_version")),
        ("no created_at", without("created_at")),
        ("schema_version as text", text_version.zip()),
        ("created_at as text", text_created.zip()),
        ("backup.json not an object", zip_of(&not_an_object)),
    ]);
}

#[test]
fn manifest_json_without_a_vault_id_fails_with_backup_invalid() {
    let source = notes_source();
    let mut parts = Parts::of(&source);
    let mut m: Value = serde_json::from_slice(&source.manifest).unwrap();
    m.as_object_mut().unwrap().remove("vault_id");
    parts.manifest = serde_json::to_vec_pretty(&m).unwrap();
    assert_each_invalid_before_any_write(vec![("manifest without vault_id", parts.zip())]);
}

#[test]
fn an_unknown_member_name_fails_with_backup_invalid() {
    let parts = Parts::of(&notes_source());
    let x = b"x".as_slice();
    assert_each_invalid_before_any_write(vec![
        ("notes.txt", parts.zip_with(file("notes.txt", x))),
        ("memex.db-wal", parts.zip_with(file("memex.db-wal", x))),
        (
            "backup-state.json",
            parts.zip_with(file("backup-state.json", x)),
        ),
        ("backup.lock", parts.zip_with(file("backup.lock", x))),
        (".memex/ui.json", parts.zip_with(file(".memex/ui.json", x))),
        ("Manifest.json", parts.zip_with(file("Manifest.json", x))),
        ("objects as a file", parts.zip_with(file("objects", x))),
        ("memex.db/ as a folder", parts.zip_with(dir("memex.db/"))),
        ("objectsx/y", parts.zip_with(file("objectsx/y", x))),
        ("an empty name", parts.zip_with(file("", x))),
    ]);
}

#[test]
fn a_snapshot_that_fails_quick_check_fails_with_backup_invalid_and_leaves_no_temp() {
    let source = notes_source();
    // Page 2 zeroed: the header still says SQLite, the b-trees don't hold.
    let mut corrupt = source.db.clone();
    let page_size = u16::from_be_bytes([corrupt[16], corrupt[17]]) as usize;
    assert!(
        corrupt.len() >= 3 * page_size,
        "fixture: at least three pages"
    );
    corrupt[page_size..2 * page_size].fill(0);
    assert_quick_check_fails(&corrupt);
    let mut not_a_db = b"SQLite format 3\0".to_vec();
    not_a_db.extend(vec![0x5A_u8; 8192]);
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("a zeroed b-tree page", corrupt),
        ("not a database", not_a_db),
        ("an empty memex.db", Vec::new()),
    ];
    for (case, db) in cases {
        let mut parts = Parts::of(&source);
        parts.db = db;
        let fx = Fx::new();
        let from = fx.backup_file(&parts.zip());
        let before = fx.before();

        assert_eq!(code_of(fx.restore(&from)), "backup_invalid", "{case}");
        before.assert_untouched(&fx, case);
    }
}

/// Fixture guard: `PRAGMA quick_check` on `db` reports a problem or errors.
fn assert_quick_check_fails(db: &[u8]) {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("corrupt.db");
    fs::write(&path, db).unwrap();
    let conn = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let result: rusqlite::Result<String> = conn.query_row("PRAGMA quick_check", [], |r| r.get(0));
    assert!(
        !matches!(result.as_deref(), Ok("ok")),
        "fixture: quick_check must fail, got {result:?}"
    );
}

#[test]
fn a_snapshot_schema_that_disagrees_with_backup_json_fails_with_backup_invalid() {
    let source = notes_source();
    // Snapshot at V5, backup.json says V6.
    let mut older_snapshot = Parts::of(&source);
    older_snapshot.db = v5_db(&source.db);
    // Snapshot at V6, backup.json says V5.
    let mut newer_snapshot = Parts::of(&source);
    newer_snapshot.backup_json["schema_version"] = json!(5);
    for (case, parts) in [
        ("snapshot V5, backup.json V6", older_snapshot),
        ("snapshot V6, backup.json V5", newer_snapshot),
    ] {
        let fx = Fx::new();
        let from = fx.backup_file(&parts.zip());
        let before = fx.before();

        assert_eq!(code_of(fx.restore(&from)), "backup_invalid", "{case}");
        before.assert_untouched(&fx, case);
    }
}

#[test]
fn a_failure_leaves_an_existing_empty_to_folder_in_place_and_empty() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let mut mismatch = Parts::of(&source);
    mismatch.backup_json["schema_version"] = json!(5);
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("an unknown member", parts.zip_with(file("notes.txt", b"x"))),
        ("a schema mismatch found after extracting", mismatch.zip()),
    ];
    for (case, bytes) in cases {
        let fx = Fx::new();
        fs::create_dir(&fx.to).unwrap();
        let from = fx.backup_file(&bytes);
        let before = fx.before();

        assert_eq!(code_of(fx.restore(&from)), "backup_invalid", "{case}");
        before.assert_untouched(&fx, case);
        assert!(
            fx.to.is_dir(),
            "{case}: the empty --to folder is still there"
        );
    }
}

// ---------------------------------------------------------------------------
// AC: a newer schema fails with backup_too_new naming both versions
// ---------------------------------------------------------------------------

#[test]
fn a_newer_backup_json_schema_fails_with_backup_too_new_naming_both_versions() {
    let source = notes_source();
    let newer = APP_SCHEMA_VERSION + 1;
    let mut parts = Parts::of(&source);
    parts.db = with_sql(
        &source.db,
        &format!("INSERT INTO schema_version(version) VALUES ({newer});"),
    );
    parts.manifest = manifest_at(&source.manifest, newer);
    parts.backup_json["schema_version"] = json!(newer);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    let err = error_of(fx.restore(&from));

    assert_eq!(err.code(), "backup_too_new");
    let c1 = err.to_error_json();
    assert_eq!(c1["error"]["code"], "backup_too_new");
    assert_eq!(c1["error"]["schema_version"], newer, "{c1}");
    assert_eq!(
        c1["error"]["supported_schema_version"], APP_SCHEMA_VERSION,
        "{c1}"
    );
    before.assert_nothing_written(&fx, "backup.json too new");
}

#[test]
fn a_newer_snapshot_schema_fails_with_backup_too_new_and_leaves_no_temp() {
    // backup.json claims the current schema; the snapshot itself is newer.
    // D14 step 5 checks "too new" before "disagrees".
    let source = notes_source();
    let newer = APP_SCHEMA_VERSION + 1;
    let mut parts = Parts::of(&source);
    parts.db = with_sql(
        &source.db,
        &format!("INSERT INTO schema_version(version) VALUES ({newer});"),
    );
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());
    let before = fx.before();

    let err = error_of(fx.restore(&from));

    assert_eq!(err.code(), "backup_too_new");
    let c1 = err.to_error_json();
    assert_eq!(c1["error"]["schema_version"], newer, "{c1}");
    assert_eq!(
        c1["error"]["supported_schema_version"], APP_SCHEMA_VERSION,
        "{c1}"
    );
    before.assert_untouched(&fx, "snapshot too new");
}

#[test]
fn a_backup_at_exactly_the_supported_schema_restores() {
    // Boundary: schema_version == APP_SCHEMA_VERSION is not too new.
    let source = notes_source();
    let parts = Parts::of(&source);
    assert_eq!(parts.backup_json["schema_version"], APP_SCHEMA_VERSION);
    assert_eq!(db_schema_version(&parts.db), APP_SCHEMA_VERSION);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    let outcome = fx.restore(&from).expect("the current schema restores");

    assert_eq!(outcome.vault_id, source.vault_id);
}

// ---------------------------------------------------------------------------
// AC: no backup.json in the vault; objects/ always created
// ---------------------------------------------------------------------------

#[test]
fn the_restored_folder_holds_only_vault_files_and_no_backup_json() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    fx.restore(&from).expect("restore");

    assert!(
        !fx.to.join("backup.json").exists(),
        "backup.json is never written"
    );
    let allowed = [
        "manifest.json",
        "memex.db",
        "memex.db-shm",
        "memex.db-wal",
        "objects",
    ];
    for name in listing(&fx.to) {
        assert!(
            allowed.contains(&name.as_str()),
            "unexpected {name:?} in the vault"
        );
    }
    assert!(fx.to.join("manifest.json").is_file());
    assert!(fx.to.join("memex.db").is_file());
    assert!(fx.to.join("objects").is_dir());
}

#[test]
fn objects_folder_is_created_when_the_backup_has_no_objects() {
    let source = notes_source();
    let mut only_dir_entry = Parts::of(&source);
    only_dir_entry.objects.clear();
    only_dir_entry.dirs = vec!["objects/".into()];
    let mut nothing = Parts::of(&source);
    nothing.objects.clear();
    nothing.dirs.clear();
    for (case, parts) in [
        ("an objects/ entry and no files", only_dir_entry),
        ("no objects member at all", nothing),
    ] {
        let fx = Fx::new();
        let from = fx.backup_file(&parts.zip());

        fx.restore(&from).unwrap_or_else(|e| panic!("{case}: {e}"));

        assert!(fx.to.join("objects").is_dir(), "{case}: objects/ exists");
        assert_eq!(
            listing(&fx.to.join("objects")),
            Vec::<String>::new(),
            "{case}"
        );
        assert!(!fx.to.join("backup.json").exists(), "{case}");
    }
}

// ---------------------------------------------------------------------------
// AC: the req 34 outcome; a missing --from fails with internal
// ---------------------------------------------------------------------------

#[test]
fn the_outcome_carries_backup_json_created_at_and_the_absolute_path() {
    let source = notes_source();
    let parts = Parts::of(&source);
    let fx = Fx::new();
    let from = fx.backup_file(&parts.zip());

    let outcome = fx.restore(&from).expect("restore");

    assert_eq!(outcome.created_at, CREATED_AT, "backup.json's created_at");
    assert_eq!(outcome.vault_id, source.vault_id);
    assert!(outcome.path.is_absolute(), "{:?}", outcome.path);
    assert_eq!(
        fs::canonicalize(&outcome.path).unwrap(),
        fs::canonicalize(&fx.to).unwrap(),
        "path is the restored folder"
    );
    let json = outcome.to_json();
    assert_eq!(json["created_at"], CREATED_AT);
    assert_eq!(json["vault_id"], source.vault_id.as_str());
}

#[test]
fn success_leaves_only_the_restored_folder_in_the_parent() {
    let parts = Parts::of(&notes_source());
    let fx = Fx::new();
    fs::write(fx.parent.join("neighbour.txt"), "left alone").unwrap();
    let from = fx.backup_file(&parts.zip());

    fx.restore(&from).expect("restore");

    assert_eq!(
        listing(&fx.parent),
        vec!["neighbour.txt".to_string(), "notes restored".to_string()],
        "no .restoring- temp folder is left"
    );
    assert_eq!(
        fs::read(fx.parent.join("neighbour.txt")).unwrap(),
        b"left alone"
    );
    assert!(from.is_file(), "the backup file is kept");
}

#[test]
fn a_missing_from_file_fails_with_internal_and_creates_nothing() {
    let fx = Fx::new();
    let from = fx.backups.join("no such backup.memex.zip");
    let before = fx.before();

    assert_eq!(code_of(fx.restore(&from)), "internal");
    before.assert_nothing_written(&fx, "missing --from");
    assert!(fx.tmp.path().join("My Drive backups").is_dir());
}
