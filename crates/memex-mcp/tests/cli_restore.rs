//! WI #319 (R2): `memex restore --from <file> --to <folder>` through the
//! built binary (Spec #315 req 32, 33, 34; architecture D13, D14).
//!
//! The backup → restore → open round trips use `memex backup` (R1b's) to
//! make real backups. Every other test restores an archive built here by a
//! small stored-zip writer (memex-mcp has no `zip` dependency), so it needs
//! nothing from R1b. The archive-validation cases live in memex-core's
//! `tests/backup_restore.rs`. Every path carries a space.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::notes::{create_note, CreateNote};
use memex_core::schema::{self, APP_SCHEMA_VERSION};
use memex_core::Vault;
use regex::Regex;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use tempfile::TempDir;

/// backup.json `created_at` in the hand-built archives.
const CREATED_AT: i64 = 1_794_214_800_123;
const FINGERPRINT: &str = "4f2a9c0e8b7d6a5f4e3d2c1b0a99887766554433221100ffeeddccbbaa998877";

fn fixture(rel: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/backup/cli")
        .join(rel);
    serde_json::from_slice(&fs::read(&path).unwrap_or_else(|e| panic!("{path:?}: {e}"))).unwrap()
}

// ---------------------------------------------------------------------------
// Running memex
// ---------------------------------------------------------------------------

fn run_in(cwd: Option<&Path>, args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let mut child = cmd.spawn().expect("spawn memex");
    if let Some(body) = stdin_body {
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(body.as_bytes())
            .unwrap();
    }
    drop(child.stdin.take());
    child.wait_with_output().expect("wait")
}

fn run(args: &[&str]) -> Output {
    run_in(None, args, None)
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn ok_stdout(out: &Output) -> String {
    assert_eq!(out.status.code(), Some(0), "{}", describe(out));
    String::from_utf8(out.stdout.clone()).expect("utf8 stdout")
}

/// Exactly one JSON line on stdout, exit 0.
fn ok_json(out: &Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout
        .strip_suffix('\n')
        .unwrap_or_else(|| panic!("stdout ends with a newline: {stdout:?}"));
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

/// Exit 1, nothing on stdout, one C1 line on stderr.
fn error_json(out: &Output) -> Value {
    assert_eq!(out.status.code(), Some(1), "{}", describe(out));
    assert!(
        out.stdout.is_empty(),
        "nothing on stdout: {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be one line; {}",
        describe(out)
    );
    serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)))
}

fn restore(from: &Path, to: &Path) -> Output {
    run(&[
        "restore",
        "--from",
        from.to_str().unwrap(),
        "--to",
        to.to_str().unwrap(),
    ])
}

fn listing(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn manifest_of(vault: &Path) -> Value {
    serde_json::from_slice(&fs::read(vault.join("manifest.json")).unwrap()).unwrap()
}

/// An object's keys, sorted.
fn keys(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v.as_object().expect("an object").keys().cloned().collect();
    k.sort();
    k
}

fn same_place(a: &Path, b: &Path) -> bool {
    fs::canonicalize(a).unwrap() == fs::canonicalize(b).unwrap()
}

// ---------------------------------------------------------------------------
// A minimal stored (uncompressed) zip writer, with unix modes
// ---------------------------------------------------------------------------

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFF_u32;
    for &b in bytes {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

/// `(name, bytes, unix mode)`; a folder is a name ending in `/`, no bytes,
/// mode `0o40755`.
type Entry = (String, Vec<u8>, u32);

fn stored_zip(entries: &[Entry]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    for (name, bytes, mode) in entries {
        let offset = out.len() as u32;
        let crc = crc32(bytes);
        let size = bytes.len() as u32;
        let name_len = name.len() as u16;
        // Local file header.
        out.extend(0x0403_4b50_u32.to_le_bytes());
        out.extend(20_u16.to_le_bytes()); // version needed
        out.extend(0x0800_u16.to_le_bytes()); // UTF-8 names
        out.extend(0_u16.to_le_bytes()); // stored
        out.extend(0_u16.to_le_bytes()); // time
        out.extend(0x0021_u16.to_le_bytes()); // date 1980-01-01
        out.extend(crc.to_le_bytes());
        out.extend(size.to_le_bytes());
        out.extend(size.to_le_bytes());
        out.extend(name_len.to_le_bytes());
        out.extend(0_u16.to_le_bytes()); // extra
        out.extend(name.as_bytes());
        out.extend(bytes);
        // Central directory header.
        central.extend(0x0201_4b50_u32.to_le_bytes());
        central.extend(((3_u16 << 8) | 20).to_le_bytes()); // made by: unix
        central.extend(20_u16.to_le_bytes());
        central.extend(0x0800_u16.to_le_bytes());
        central.extend(0_u16.to_le_bytes());
        central.extend(0_u16.to_le_bytes());
        central.extend(0x0021_u16.to_le_bytes());
        central.extend(crc.to_le_bytes());
        central.extend(size.to_le_bytes());
        central.extend(size.to_le_bytes());
        central.extend(name_len.to_le_bytes());
        central.extend(0_u16.to_le_bytes()); // extra
        central.extend(0_u16.to_le_bytes()); // comment
        central.extend(0_u16.to_le_bytes()); // disk
        central.extend(0_u16.to_le_bytes()); // internal attributes
        central.extend((mode << 16).to_le_bytes()); // external: unix mode
        central.extend(offset.to_le_bytes());
        central.extend(name.as_bytes());
    }
    let cd_offset = out.len() as u32;
    let cd_size = central.len() as u32;
    out.extend(&central);
    let n = entries.len() as u16;
    out.extend(0x0605_4b50_u32.to_le_bytes());
    out.extend(0_u16.to_le_bytes());
    out.extend(0_u16.to_le_bytes());
    out.extend(n.to_le_bytes());
    out.extend(n.to_le_bytes());
    out.extend(cd_size.to_le_bytes());
    out.extend(cd_offset.to_le_bytes());
    out.extend(0_u16.to_le_bytes());
    out
}

fn entry_file(name: &str, bytes: &[u8]) -> Entry {
    (name.into(), bytes.to_vec(), 0o100644)
}

fn entry_dir(name: &str) -> Entry {
    (name.into(), Vec::new(), 0o40755)
}

// ---------------------------------------------------------------------------
// A source vault, snapshotted by hand, and the backup it makes
// ---------------------------------------------------------------------------

/// A vault made in-process, with notes and a vec0 table, and its parts.
struct HandBackup {
    _tmp: TempDir,
    vault_id: String,
    db: Vec<u8>,
    manifest: Vec<u8>,
}

fn hand_source() -> HandBackup {
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("source vault");
    let mut vault = Vault::create(&root).unwrap();
    let vault_id = vault.vault_id().to_string();
    for (title, body) in [
        ("Garden plan", "Tomatoes by the #garden wall.\n"),
        ("Reading list", "Books for the winter.\n"),
    ] {
        create_note(
            &mut vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                ..Default::default()
            },
        )
        .unwrap();
    }
    schema::ensure_vector_table(vault.connection_ref(), 4).unwrap();
    drop(vault);
    let src = Connection::open_with_flags(root.join("memex.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap();
    let snap = tmp.path().join("snapshot copy.db");
    src.backup(rusqlite::MAIN_DB, &snap, None).unwrap();
    drop(src);
    HandBackup {
        vault_id,
        db: fs::read(&snap).unwrap(),
        manifest: fs::read(root.join("manifest.json")).unwrap(),
        _tmp: tmp,
    }
}

impl HandBackup {
    fn backup_json(&self) -> Value {
        json!({
            "format": 1,
            "vault_id": self.vault_id,
            "schema_version": APP_SCHEMA_VERSION,
            "created_at": CREATED_AT,
            "memex_version": "0.1.0",
            "fingerprint": FINGERPRINT,
            "source": "local",
        })
    }

    /// D7 member order, with one object.
    fn zip(&self, db: &[u8], manifest: &[u8], backup_json: &Value) -> Vec<u8> {
        stored_zip(&[
            entry_file("memex.db", db),
            entry_file("manifest.json", manifest),
            entry_dir("objects/"),
            entry_file("objects/photo 1.png", b"\x89PNG fake image"),
            entry_file("backup.json", &serde_json::to_vec(backup_json).unwrap()),
        ])
    }

    fn valid_zip(&self) -> Vec<u8> {
        self.zip(&self.db, &self.manifest, &self.backup_json())
    }
}

/// `db` with a `schema_version` row for `version` added.
fn with_schema_row(db: &[u8], version: i64) -> Vec<u8> {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("edit me.db");
    fs::write(&path, db).unwrap();
    let conn = Connection::open(&path).unwrap();
    conn.pragma_update(None, "journal_mode", "DELETE").unwrap();
    conn.execute("INSERT INTO schema_version(version) VALUES (?1)", [version])
        .unwrap();
    drop(conn);
    fs::read(&path).unwrap()
}

/// A temp folder holding a backups folder and a parent for `--to`.
struct Fx {
    _tmp: TempDir,
    backups: PathBuf,
    parent: PathBuf,
}

impl Fx {
    fn new() -> Fx {
        let tmp = TempDir::new().unwrap();
        let backups = tmp.path().join("My Drive backups");
        let parent = tmp.path().join("restore parent");
        fs::create_dir(&backups).unwrap();
        fs::create_dir(&parent).unwrap();
        Fx {
            _tmp: tmp,
            backups,
            parent,
        }
    }

    fn write_backup(&self, bytes: &[u8]) -> PathBuf {
        let path = self
            .backups
            .join("notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip");
        fs::write(&path, bytes).unwrap();
        path
    }

    fn to(&self) -> PathBuf {
        self.parent.join("notes restored")
    }
}

// ---------------------------------------------------------------------------
// Real backups through `memex backup` (R1b)
// ---------------------------------------------------------------------------

fn add_note(vault: &str, title: &str, body: &str) -> String {
    let out = run_in(
        None,
        &["add", "--vault", vault, "--title", title],
        Some(body),
    );
    let stdout = ok_stdout(&out);
    let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(&stdout)
        .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))[1]
        .to_string()
}

fn get_note(vault: &str, id: &str) -> Value {
    ok_json(&run(&["get", "--vault", vault, "--note-id", id]))
}

/// `memex backup --vault V --dest D`; returns the new backup file.
fn memex_backup(vault: &Path, dest: &Path) -> (Value, PathBuf) {
    let out = ok_json(&run(&[
        "backup",
        "--vault",
        vault.to_str().unwrap(),
        "--dest",
        dest.to_str().unwrap(),
    ]));
    assert_eq!(out["result"], "created", "{out}");
    let file = PathBuf::from(out["file"].as_str().expect("file"));
    assert!(file.is_file(), "{file:?}");
    (out, file)
}

/// The source vault pinned at V5: V7's triggers and tables (#415), then
/// V6's tables, index and columns dropped and their version rows deleted,
/// manifest at 5.
fn pin_at_v5(vault: &Path) {
    let conn = Connection::open(vault.join("memex.db")).unwrap();
    conn.pragma_update(None, "journal_mode", "DELETE").unwrap();
    let triggers: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type = 'trigger'
                 AND name LIKE 'content~_revision~_%' ESCAPE '~'",
            )
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    for name in triggers {
        conn.execute_batch(&format!("DROP TRIGGER \"{name}\";"))
            .unwrap();
    }
    conn.execute_batch(
        "DROP TABLE IF EXISTS agent_activity;
         DROP TABLE IF EXISTS learned_words;
         DROP TABLE IF EXISTS content_revision;
         DROP INDEX idx_notes_guide;
         DROP TABLE vault_guide_revisions;
         DROP TABLE feedback;
         DROP TABLE tag_corrections;
         ALTER TABLE tags DROP COLUMN first_line;
         ALTER TABLE tags DROP COLUMN origin;
         DELETE FROM schema_version WHERE version >= 6;",
    )
    .unwrap();
    assert_eq!(schema::current_version(&conn).unwrap(), 5, "fixture: V5");
    drop(conn);
    let mut m = manifest_of(vault);
    m["schema_version"] = json!(5);
    fs::write(
        vault.join("manifest.json"),
        serde_json::to_vec_pretty(&m).unwrap(),
    )
    .unwrap();
}

// ---------------------------------------------------------------------------
// AC: round trip through the CLI
// ---------------------------------------------------------------------------

#[test]
fn memex_backup_then_restore_then_open_keeps_notes_objects_and_the_vault_id() {
    let tmp = TempDir::new().unwrap();
    let source = tmp.path().join("my notes");
    let s = source.to_str().unwrap().to_string();
    ok_stdout(&run(&["init", &s]));
    let a = add_note(&s, "Garden plan", "Tomatoes by the #garden wall.\n");
    let b = add_note(&s, "Reading list", "Books for the winter.\n");
    fs::create_dir_all(source.join("objects/ab/cd ef")).unwrap();
    fs::write(source.join("objects/ab/cd ef/photo 1.png"), b"\x89PNG one").unwrap();
    fs::write(source.join("objects/top level.txt"), b"an attachment").unwrap();
    let want: Vec<Value> = [&a, &b].iter().map(|id| get_note(&s, id)).collect();
    let source_id = manifest_of(&source)["vault_id"].clone();
    let dest = tmp.path().join("My Drive");
    fs::create_dir(&dest).unwrap();
    let (backed_up, file) = memex_backup(&source, &dest);
    let to = tmp.path().join("restored notes");

    let restored = ok_json(&restore(&file, &to));

    assert_eq!(restored["vault_id"], source_id, "{restored}");
    assert_eq!(backed_up["vault_id"], source_id);
    assert_eq!(manifest_of(&to)["vault_id"], source_id, "L8: vault_id kept");
    let t = to.to_str().unwrap();
    for (id, before) in [&a, &b].iter().zip(&want) {
        let after = get_note(t, id);
        for key in ["note_id", "title", "content_md", "version", "tags"] {
            assert_eq!(after[key], before[key], "{id} {key}");
        }
    }
    let ls = ok_stdout(&run(&["ls", "--vault", t]));
    assert!(ls.contains(&a) && ls.contains(&b), "{ls}");
    assert_eq!(
        fs::read(to.join("objects/ab/cd ef/photo 1.png")).unwrap(),
        b"\x89PNG one"
    );
    assert_eq!(
        fs::read(to.join("objects/top level.txt")).unwrap(),
        b"an attachment"
    );
    assert!(!to.join("backup.json").exists());
}

#[test]
fn memex_backup_of_a_v5_vault_restores_at_v5_and_the_first_open_migrates_it() {
    let tmp = TempDir::new().unwrap();
    let source = tmp.path().join("old notes");
    let mut vault = Vault::create(&source).unwrap();
    let note = create_note(
        &mut vault,
        CreateNote {
            title: Some("From V5".into()),
            content_md: "Written before V6.\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    drop(vault);
    pin_at_v5(&source);
    let dest = tmp.path().join("My Drive");
    fs::create_dir(&dest).unwrap();
    let (_, file) = memex_backup(&source, &dest);
    let to = tmp.path().join("restored old notes");

    ok_json(&restore(&file, &to));

    assert_eq!(
        manifest_of(&to)["schema_version"],
        5,
        "the restored manifest still says 5"
    );
    let t = to.to_str().unwrap();
    let got = get_note(t, &note.id.to_string());
    assert_eq!(got["content_md"], "Written before V6.\n");
    assert_eq!(
        manifest_of(&to)["schema_version"],
        APP_SCHEMA_VERSION,
        "the first open migrated it"
    );
}

// ---------------------------------------------------------------------------
// AC: the req 34 line; a missing --from is internal
// ---------------------------------------------------------------------------

#[test]
fn memex_restore_prints_exactly_the_req_34_json_line() {
    let hand = hand_source();
    let fx = Fx::new();
    let from = fx.write_backup(&hand.valid_zip());
    let to = fx.to();

    let out = ok_json(&restore(&from, &to));

    let shape = fixture("restore_ok.json");
    assert_eq!(keys(&out), keys(&shape), "restore_ok.json's keys exactly");
    assert_eq!(out["vault_id"], hand.vault_id.as_str());
    assert_eq!(out["created_at"], CREATED_AT, "backup.json's created_at");
    let path = PathBuf::from(out["path"].as_str().expect("path is a string"));
    assert!(path.is_absolute(), "{path:?}");
    assert!(same_place(&path, &to), "{path:?} is --to");
    assert_eq!(
        listing(&fx.parent),
        vec!["notes restored".to_string()],
        "no temp folder left"
    );
    assert_eq!(manifest_of(&to)["vault_id"], hand.vault_id.as_str());
}

#[test]
fn memex_restore_prints_an_absolute_path_for_a_relative_to() {
    let hand = hand_source();
    let fx = Fx::new();
    let from = fx.write_backup(&hand.valid_zip());

    let out = ok_json(&run_in(
        Some(&fx.parent),
        &[
            "restore",
            "--from",
            from.to_str().unwrap(),
            "--to",
            "notes restored",
        ],
        None,
    ));

    let path = PathBuf::from(out["path"].as_str().expect("path"));
    assert!(path.is_absolute(), "{path:?}");
    assert!(same_place(&path, &fx.to()), "{path:?}");
}

#[test]
fn memex_restore_then_memex_opens_the_restored_vault() {
    // The archive holds a vec0 table; a fresh `memex` process restores it
    // and then opens it.
    let hand = hand_source();
    let fx = Fx::new();
    let from = fx.write_backup(&hand.valid_zip());
    let to = fx.to();

    ok_json(&restore(&from, &to));

    let ls = ok_stdout(&run(&["ls", "--vault", to.to_str().unwrap()]));
    assert!(
        ls.contains("Garden plan") && ls.contains("Reading list"),
        "{ls}"
    );
    assert_eq!(
        fs::read(to.join("objects/photo 1.png")).unwrap(),
        b"\x89PNG fake image"
    );
}

#[test]
fn memex_restore_with_a_missing_from_fails_with_internal() {
    let fx = Fx::new();
    let from = fx.backups.join("no such backup.memex.zip");
    let to = fx.to();

    let err = error_json(&restore(&from, &to));

    assert_eq!(err["error"]["code"], "internal", "{err}");
    assert!(!to.exists(), "--to is not created");
    assert_eq!(listing(&fx.parent), Vec::<String>::new());
}

// ---------------------------------------------------------------------------
// AC: refusals through the CLI
// ---------------------------------------------------------------------------

#[test]
fn memex_restore_of_a_backup_too_new_prints_both_versions_in_c1() {
    let hand = hand_source();
    let newer = APP_SCHEMA_VERSION + 1;
    let mut backup_json = hand.backup_json();
    backup_json["schema_version"] = json!(newer);
    let mut manifest: Value = serde_json::from_slice(&hand.manifest).unwrap();
    manifest["schema_version"] = json!(newer);
    let db = with_schema_row(&hand.db, newer);
    let fx = Fx::new();
    let from =
        fx.write_backup(&hand.zip(&db, &serde_json::to_vec(&manifest).unwrap(), &backup_json));
    let to = fx.to();

    let err = error_json(&restore(&from, &to));

    let shape = fixture("errors/backup_too_new.json");
    assert_eq!(
        keys(&err["error"]),
        keys(&shape["error"]),
        "backup_too_new.json's keys: {err}"
    );
    assert_eq!(err["error"]["code"], "backup_too_new");
    assert_eq!(err["error"]["schema_version"], newer, "{err}");
    assert_eq!(
        err["error"]["supported_schema_version"], APP_SCHEMA_VERSION,
        "{err}"
    );
    assert!(!to.exists());
    assert_eq!(listing(&fx.parent), Vec::<String>::new(), "no temp left");
}

#[test]
fn memex_restore_of_a_file_that_is_not_a_zip_fails_with_backup_invalid() {
    let fx = Fx::new();
    let from = fx.write_backup(b"these are my notes, not a zip\n");
    let to = fx.to();

    let err = error_json(&restore(&from, &to));

    assert_eq!(err["error"]["code"], "backup_invalid", "{err}");
    assert!(!to.exists());
    assert_eq!(listing(&fx.parent), Vec::<String>::new());
}

#[test]
fn memex_restore_of_a_hostile_member_fails_with_backup_invalid_and_writes_nothing() {
    let hand = hand_source();
    let fx = Fx::new();
    let bytes = stored_zip(&[
        entry_file("memex.db", &hand.db),
        entry_file("manifest.json", &hand.manifest),
        entry_dir("objects/"),
        entry_file("objects/../../escaped.txt", b"escaped"),
        entry_file(
            "backup.json",
            &serde_json::to_vec(&hand.backup_json()).unwrap(),
        ),
    ]);
    let from = fx.write_backup(&bytes);
    let to = fx.to();

    let err = error_json(&restore(&from, &to));

    assert_eq!(err["error"]["code"], "backup_invalid", "{err}");
    assert!(!to.exists());
    assert_eq!(listing(&fx.parent), Vec::<String>::new());
    assert!(!fx.parent.join("../escaped.txt").exists());
}

#[test]
fn memex_restore_into_a_non_empty_folder_fails_with_restore_target_not_empty() {
    let hand = hand_source();
    let fx = Fx::new();
    let from = fx.write_backup(&hand.valid_zip());
    let to = fx.to();
    fs::create_dir(&to).unwrap();
    fs::write(to.join("keep me.md"), "mine").unwrap();

    let err = error_json(&restore(&from, &to));

    assert_eq!(err["error"]["code"], "restore_target_not_empty", "{err}");
    assert_eq!(listing(&to), vec!["keep me.md".to_string()]);
    assert_eq!(fs::read(to.join("keep me.md")).unwrap(), b"mine");
    assert_eq!(listing(&fx.parent), vec!["notes restored".to_string()]);
}
