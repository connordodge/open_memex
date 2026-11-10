//! WI #317 (R1a): the consistent `memex.db` snapshot (Spec #315 req 2, 2a,
//! technical decision 2; architecture D6).
//!
//! `snapshot::take_snapshot(vault)` copies `<vault>/memex.db` through a
//! read-only connection and SQLite's online backup API into a temp file in
//! `std::env::temp_dir()`, checks it with `PRAGMA quick_check` and reads its
//! schema version from the snapshot itself. It never opens the vault through
//! `Vault::open` (which migrates and rewrites `manifest.json`).
//!
//! Every check of a snapshot's contents runs on a copy of its bytes alone in
//! another folder: that is what goes into the zip, so it must be
//! self-contained. Writers run on a thread with a stop flag and report through
//! a channel; nothing waits on wall time. The temp-file checks re-exec this
//! binary with a private `TMPDIR` so the folder can be listed.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;

use memex_core::backup::snapshot::{self, Snapshot};
use memex_core::schema::{self, APP_SCHEMA_VERSION};
use memex_core::Vault;
use rusqlite::{params, Connection, OpenFlags};
use serde_json::json;

const VAULT_ID: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAE";

const CHILD_VAULT_ENV: &str = "MEMEX_317_SNAP_CHILD_VAULT";
const CHILD_EXPECT_ENV: &str = "MEMEX_317_SNAP_CHILD_EXPECT";
const CHILD_OK: &str = "MEMEX_317_SNAP_CHILD_OK";

/// The shipped V5 schema (v1..v5), FTS included, pinned at version 5: the
/// same DDL `migration_v6.rs` builds its V5 fixture from.
const V5_DDL: &str = "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);

     CREATE TABLE notes (
         id           TEXT PRIMARY KEY,
         title        TEXT NOT NULL,
         content_md   TEXT NOT NULL,
         frontmatter  TEXT NOT NULL DEFAULT '{}',
         version      INTEGER NOT NULL DEFAULT 1,
         created_at   INTEGER NOT NULL,
         updated_at   INTEGER NOT NULL,
         crdt_state   BLOB,
         has_open_questions      INTEGER NOT NULL DEFAULT 0,
         frontmatter_parse_error INTEGER NOT NULL DEFAULT 0
     );
     CREATE INDEX idx_notes_updated_at ON notes(updated_at DESC);
     CREATE UNIQUE INDEX idx_notes_title_unique ON notes(title);

     CREATE TABLE chunks (
         id                  TEXT PRIMARY KEY,
         note_id             TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         ord                 INTEGER NOT NULL,
         content             TEXT NOT NULL,
         token_count         INTEGER NOT NULL,
         embed_model_version TEXT,
         start_byte          INTEGER,
         end_byte            INTEGER
     );
     CREATE INDEX idx_chunks_note ON chunks(note_id, ord);

     CREATE VIRTUAL TABLE chunk_fts USING fts5(
         content,
         chunk_id UNINDEXED,
         note_id UNINDEXED,
         tokenize = 'porter unicode61'
     );

     CREATE TABLE tags (
         note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         tag     TEXT NOT NULL,
         PRIMARY KEY (note_id, tag)
     );
     CREATE INDEX idx_tags_tag ON tags(tag);

     CREATE TABLE pending_index (
         note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         enqueued_at INTEGER NOT NULL
     );

     CREATE TABLE notes_dedup_log (
         note_id      TEXT PRIMARY KEY,
         old_title    TEXT NOT NULL,
         new_title    TEXT NOT NULL,
         migrated_at  INTEGER NOT NULL
     );

     CREATE TABLE links (
         id            TEXT PRIMARY KEY,
         from_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         to_note_id    TEXT NULL REFERENCES notes(id) ON DELETE SET NULL,
         link_text     TEXT NOT NULL,
         link_kind     TEXT NOT NULL
                       CHECK (link_kind GLOB '[a-z][a-z0-9-]*' AND length(link_kind) <= 64),
         label         TEXT NULL,
         position      INTEGER NOT NULL,
         source        TEXT NOT NULL
                       CHECK (source IN ('inline_body','inline_section','frontmatter','auto_added')),
         UNIQUE (from_note_id, position)
     );
     CREATE INDEX idx_links_from ON links(from_note_id);
     CREATE INDEX idx_links_to   ON links(to_note_id);
     CREATE INDEX idx_links_kind ON links(link_kind, to_note_id);

     CREATE TABLE canvases (
         id          TEXT PRIMARY KEY,
         title       TEXT NOT NULL,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL,
         version     INTEGER NOT NULL DEFAULT 1
     );
     CREATE UNIQUE INDEX idx_canvases_title_unique ON canvases(title);
     CREATE INDEX idx_canvases_updated_at ON canvases(updated_at DESC);

     CREATE TABLE canvas_nodes (
         canvas_id   TEXT NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
         note_id     TEXT NOT NULL REFERENCES notes(id)    ON DELETE CASCADE,
         x           REAL NOT NULL,
         y           REAL NOT NULL,
         z_order     INTEGER NOT NULL DEFAULT 0,
         placed_at   INTEGER NOT NULL,
         PRIMARY KEY (canvas_id, note_id)
     );
     CREATE INDEX idx_canvas_nodes_note ON canvas_nodes(note_id);

     CREATE TABLE blocks (
         note_id          TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         block_id         TEXT NOT NULL,
         ord              INTEGER NOT NULL,
         start_byte       INTEGER NOT NULL,
         end_byte         INTEGER NOT NULL,
         text             TEXT NOT NULL,
         content_hash     TEXT NOT NULL,
         source           TEXT NOT NULL
                          CHECK (source IN ('person','agent','quick-entry')),
         created_version  INTEGER NOT NULL,
         created_at       INTEGER NOT NULL,
         PRIMARY KEY (note_id, block_id)
     );
     CREATE INDEX idx_blocks_note_ord ON blocks(note_id, ord);

     CREATE TABLE day_reviews (
         note_id                   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         content_version           INTEGER NOT NULL DEFAULT 0,
         reviewed_content_version  INTEGER NULL,
         reviewed_at               INTEGER NULL
     );

     CREATE TABLE day_review_blocks (
         note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         block_id      TEXT NOT NULL,
         content_hash  TEXT NOT NULL,
         text          TEXT NOT NULL,
         PRIMARY KEY (note_id, block_id)
     );

     CREATE TABLE footer_chips (
         daily_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         topic_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         origin         TEXT NOT NULL CHECK (origin IN ('excerpt','person')),
         created_at     INTEGER NOT NULL,
         PRIMARY KEY (daily_note_id, topic_note_id)
     );
     CREATE INDEX idx_footer_chips_topic ON footer_chips(topic_note_id);

     CREATE TABLE agent_changes (
         id            TEXT PRIMARY KEY,
         note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         day           TEXT NOT NULL,
         created_at    INTEGER NOT NULL,
         bullets_json  TEXT NOT NULL
     );
     CREATE INDEX idx_agent_changes_note ON agent_changes(note_id, created_at DESC);

     CREATE TABLE smart_folders (
         id          TEXT PRIMARY KEY,
         name        TEXT NOT NULL,
         parent_id   TEXT NULL REFERENCES smart_folders(id),
         pinned      INTEGER NOT NULL DEFAULT 0,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL
     );
     CREATE UNIQUE INDEX idx_smart_folders_sibling_name
         ON smart_folders(COALESCE(parent_id, ''), name COLLATE NOCASE);

     CREATE TABLE smart_folder_members (
         smart_folder_id  TEXT NOT NULL REFERENCES smart_folders(id) ON DELETE CASCADE,
         note_id          TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         pinned           INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (smart_folder_id, note_id)
     );
     CREATE INDEX idx_smart_folder_members_note ON smart_folder_members(note_id);

     CREATE TABLE vault_settings (
         key    TEXT PRIMARY KEY,
         value  TEXT NOT NULL
     );

     CREATE UNIQUE INDEX idx_notes_daily_title ON notes(title)
         WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'daily';

     INSERT INTO vault_settings(key, value) VALUES ('smart_folder_max_depth', '2');
     INSERT INTO schema_version(version) VALUES (1);
     INSERT INTO schema_version(version) VALUES (2);
     INSERT INTO schema_version(version) VALUES (3);
     INSERT INTO schema_version(version) VALUES (4);
     INSERT INTO schema_version(version) VALUES (5);";

// ---- helpers ----------------------------------------------------------------------------------

/// A new current-schema vault at `<tmp>/My Vault` (a path with a space).
fn new_vault() -> (tempfile::TempDir, PathBuf, Vault) {
    let tmp = tempfile::tempdir().expect("temp dir");
    let root = tmp.path().join("My Vault");
    let vault = Vault::create(&root).expect("create vault");
    (tmp, root, vault)
}

fn insert_notes(conn: &Connection, from: usize, n: usize, body: &str) {
    for i in from..from + n {
        conn.execute(
            "INSERT INTO notes (id, title, content_md, created_at, updated_at)
             VALUES (?1, ?2, ?3, 1, 1)",
            params![format!("N{i:025}"), format!("note {i}"), body],
        )
        .expect("insert note");
    }
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0))
        .unwrap_or_else(|e| panic!("{sql}: {e}"))
}

fn quick_check(conn: &Connection) -> String {
    let rows: Vec<String> = conn
        .prepare("PRAGMA quick_check")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    rows.join("\n")
}

/// The snapshot's bytes alone, copied into a fresh folder and opened there.
fn open_copy(snap: &Snapshot) -> (tempfile::TempDir, Connection) {
    let bytes = std::fs::read(&snap.path)
        .unwrap_or_else(|e| panic!("read snapshot {}: {e}", snap.path.display()));
    let dir = tempfile::tempdir().expect("temp dir");
    let copy = dir.path().join("snapshot copy.db");
    std::fs::write(&copy, bytes).expect("write snapshot copy");
    let conn = Connection::open(&copy).expect("open snapshot copy");
    (dir, conn)
}

fn take(vault: &Path) -> Snapshot {
    snapshot::take_snapshot(vault)
        .unwrap_or_else(|e| panic!("take_snapshot({}) failed: {e:?}", vault.display()))
}

fn entries(dir: &Path) -> BTreeSet<String> {
    std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("list {}: {e}", dir.display()))
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

/// Every path under `dir`, recursively.
fn all_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            out.extend(all_files(&p));
        }
        out.push(p);
    }
    out
}

fn write_manifest(root: &Path, schema_version: i64) {
    let manifest = json!({
        "vault_id": VAULT_ID,
        "schema_version": schema_version,
        "created_at": 1_000i64,
    });
    std::fs::write(
        root.join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
}

/// A vault folder on the previous schema (V5), as a user who has not yet
/// opened it with the new `memex` has it: closed, manifest at 5, objects.
fn v5_vault() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().expect("temp dir");
    let root = tmp.path().join("Old Vault");
    std::fs::create_dir_all(root.join("objects").join("ab")).unwrap();
    std::fs::write(
        root.join("objects").join("ab").join("image one.png"),
        b"png",
    )
    .unwrap();
    let conn = Connection::open(root.join("memex.db")).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.execute_batch(V5_DDL).unwrap();
    insert_notes(&conn, 0, 3, "old body");
    drop(conn);
    write_manifest(&root, 5);
    (tmp, root)
}

/// Sets the stop flag when dropped, so a failing assertion never leaves a
/// writer thread running.
struct StopOnDrop(Arc<AtomicBool>);

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

// ---- tests ------------------------------------------------------------------------------------

#[test]
fn snapshot_contains_rows_only_in_the_wal_of_a_second_open_connection_and_passes_quick_check() {
    let (_tmp, root, vault) = new_vault();
    insert_notes(vault.connection_ref(), 0, 5, "checkpointed");
    drop(vault);
    let db = root.join("memex.db");

    // A second connection, still open, whose rows are only in the WAL.
    let writer = Connection::open(&db).unwrap();
    writer.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
    writer.execute_batch("BEGIN").unwrap();
    insert_notes(&writer, 5, 20, "only in the wal");
    writer.execute_batch("COMMIT").unwrap();
    let wal_len = std::fs::metadata(root.join("memex.db-wal")).map(|m| m.len());
    assert!(
        matches!(wal_len, Ok(n) if n > 0),
        "the rows are in memex.db-wal ({wal_len:?})"
    );
    let main_before = std::fs::read(&db).unwrap();
    {
        // The main file alone does not hold them.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("memex.db"), &main_before).unwrap();
        let main_only = Connection::open(dir.path().join("memex.db")).unwrap();
        assert_eq!(count(&main_only, "SELECT COUNT(*) FROM notes"), 5);
    }

    let snap = take(&root);
    assert_eq!(snap.schema_version, APP_SCHEMA_VERSION);
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(quick_check(&copy), "ok");
    assert_eq!(count(&copy, "SELECT COUNT(*) FROM notes"), 25);
    assert_eq!(
        count(
            &copy,
            "SELECT COUNT(*) FROM notes WHERE content_md = 'only in the wal'"
        ),
        20
    );

    // The snapshot neither wrote nor checkpointed the source.
    assert_eq!(
        std::fs::read(&db).unwrap(),
        main_before,
        "memex.db is byte-identical after the snapshot"
    );
    assert_eq!(count(&writer, "SELECT COUNT(*) FROM notes"), 25);
    drop(writer);
}

#[test]
fn snapshot_taken_while_another_connection_inserts_in_a_loop_completes_and_passes_quick_check() {
    let (_tmp, root, vault) = new_vault();
    // Enough pages that the copy is not instant.
    let body = "x".repeat(1024);
    vault.connection_ref().execute_batch("BEGIN").unwrap();
    insert_notes(vault.connection_ref(), 0, 2000, &body);
    vault.connection_ref().execute_batch("COMMIT").unwrap();
    vault
        .connection_ref()
        .execute_batch("CREATE TABLE w317 (i INTEGER PRIMARY KEY, half INTEGER NOT NULL)")
        .unwrap();
    drop(vault);
    let db = root.join("memex.db");

    let stop = Arc::new(AtomicBool::new(false));
    let _stop_guard = StopOnDrop(stop.clone());
    let (warm_tx, warm_rx) = mpsc::channel::<()>();
    const WARM_COMMITS: u64 = 20;
    let writer = {
        let stop = stop.clone();
        let db = db.clone();
        thread::spawn(move || -> (u64, Vec<String>) {
            let conn = Connection::open(&db).unwrap();
            conn.busy_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            let mut commits = 0u64;
            let mut errors = Vec::new();
            let mut warm_tx = Some(warm_tx);
            while !stop.load(Ordering::SeqCst) {
                // Each transaction writes a pair of rows: a consistent
                // snapshot never holds half of one.
                let r = conn.execute_batch(&format!(
                    "BEGIN IMMEDIATE;
                     INSERT INTO w317 (i, half) VALUES ({a}, 0);
                     INSERT INTO w317 (i, half) VALUES ({b}, 1);
                     COMMIT;",
                    a = commits * 2,
                    b = commits * 2 + 1
                ));
                match r {
                    Ok(()) => commits += 1,
                    Err(e) => {
                        errors.push(e.to_string());
                        let _ = conn.execute_batch("ROLLBACK");
                        break;
                    }
                }
                if commits == WARM_COMMITS {
                    if let Some(tx) = warm_tx.take() {
                        let _ = tx.send(());
                    }
                }
            }
            (commits, errors)
        })
    };
    warm_rx
        .recv()
        .expect("the writer commits before the snapshot starts");

    let result = snapshot::take_snapshot(&root);
    stop.store(true, Ordering::SeqCst);
    let (commits, errors) = writer.join().expect("writer thread");
    let snap = result.unwrap_or_else(|e| panic!("take_snapshot under a writer: {e:?}"));

    assert!(
        errors.is_empty(),
        "the snapshot never blocked the writer: {errors:?}"
    );
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(quick_check(&copy), "ok");
    let rows = count(&copy, "SELECT COUNT(*) FROM w317");
    assert_eq!(rows % 2, 0, "whole transactions only ({rows} rows)");
    assert_eq!(
        count(&copy, "SELECT COUNT(*) FROM w317 WHERE half = 0"),
        count(&copy, "SELECT COUNT(*) FROM w317 WHERE half = 1")
    );
    let pairs = (rows / 2) as u64;
    assert!(
        (WARM_COMMITS..=commits).contains(&pairs),
        "the snapshot holds {pairs} commits: at least the {WARM_COMMITS} made before it, at most \
         the {commits} made in all"
    );
    assert_eq!(count(&copy, "SELECT COUNT(*) FROM notes"), 2000);
}

#[test]
fn snapshot_of_a_v5_vault_reports_schema_version_5_and_leaves_memex_db_and_manifest_byte_identical()
{
    let (_tmp, root) = v5_vault();
    let db_before = std::fs::read(root.join("memex.db")).unwrap();
    let manifest_before = std::fs::read(root.join("manifest.json")).unwrap();
    let object_before = std::fs::read(root.join("objects/ab/image one.png")).unwrap();

    let snap = take(&root);
    assert_eq!(
        snap.schema_version, 5,
        "schema_version is read from the snapshot"
    );
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(quick_check(&copy), "ok");
    assert_eq!(schema::current_version(&copy).unwrap(), 5);
    assert_eq!(count(&copy, "SELECT COUNT(*) FROM notes"), 3);
    assert_eq!(
        count(
            &copy,
            "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'tag_corrections'"
        ),
        0,
        "the snapshot is of the V5 schema, not a migrated one"
    );
    drop(copy);
    drop(snap);

    assert_eq!(std::fs::read(root.join("memex.db")).unwrap(), db_before);
    assert_eq!(
        std::fs::read(root.join("manifest.json")).unwrap(),
        manifest_before
    );
    assert_eq!(
        std::fs::read(root.join("objects/ab/image one.png")).unwrap(),
        object_before
    );
    // Not migrated in the WAL either.
    let ro = Connection::open_with_flags(root.join("memex.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap();
    assert_eq!(schema::current_version(&ro).unwrap(), 5);
    assert_eq!(
        count(
            &ro,
            "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'tag_corrections'"
        ),
        0
    );
    drop(ro);
    // Only SQLite's own -wal/-shm may appear beside the vault's files.
    let allowed: BTreeSet<String> = [
        "memex.db",
        "manifest.json",
        "objects",
        "memex.db-wal",
        "memex.db-shm",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    let found = entries(&root);
    assert!(
        found.is_subset(&allowed),
        "unexpected vault entries: {:?}",
        found.difference(&allowed).collect::<Vec<_>>()
    );
}

#[test]
fn snapshot_schema_version_comes_from_the_snapshot_not_manifest_json() {
    let (_tmp, root, vault) = new_vault();
    drop(vault);
    write_manifest(&root, 4);
    let snap = take(&root);
    assert_eq!(snap.schema_version, APP_SCHEMA_VERSION);
}

#[test]
fn snapshot_of_a_vault_with_vec0_tables_passes_quick_check_and_keeps_vec_rows() {
    let (_tmp, root, vault) = new_vault();
    schema::ensure_vector_table(vault.connection_ref(), 4).unwrap();
    vault
        .connection_ref()
        .execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('c1', '[1,0,0,0]'), \
             ('c2', '[0,1,0,0]')",
            [],
        )
        .unwrap();
    insert_notes(vault.connection_ref(), 0, 3, "body");
    drop(vault);

    let snap = take(&root);
    assert_eq!(snap.schema_version, APP_SCHEMA_VERSION);
    // `Vault::create` registered sqlite-vec in this process, so the copy
    // can read the vec0 table.
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(quick_check(&copy), "ok");
    let nearest: String = copy
        .query_row(
            "SELECT chunk_id FROM chunk_vec WHERE embedding MATCH '[0,1,0,0]' AND k = 1",
            [],
            |r| r.get(0),
        )
        .expect("query the vec0 table in the snapshot");
    assert_eq!(nearest, "c2");
    assert_eq!(count(&copy, "SELECT COUNT(*) FROM chunk_vec"), 2);
}

/// Overwrites the root page of `notes` in a closed vault's `memex.db`.
fn damage_notes_page(root: &Path, vault: Vault) {
    let conn = vault.connection_ref();
    let page: i64 = conn
        .query_row(
            "SELECT rootpage FROM sqlite_schema WHERE name = 'notes'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let page_size: i64 = conn
        .query_row("PRAGMA page_size", [], |r| r.get(0))
        .unwrap();
    drop(vault);
    let db = root.join("memex.db");
    assert!(
        !root.join("memex.db-wal").exists()
            || std::fs::metadata(root.join("memex.db-wal")).unwrap().len() == 0,
        "the closed vault's pages are all in memex.db"
    );
    let mut bytes = std::fs::read(&db).unwrap();
    let start = ((page - 1) * page_size) as usize;
    let end = start + page_size as usize;
    assert!(
        page > 1 && end <= bytes.len(),
        "page {page} is inside memex.db"
    );
    bytes[start..end].fill(0xFF);
    std::fs::write(&db, bytes).unwrap();
}

#[test]
fn snapshot_of_a_corrupt_source_fails_with_backup_failed() {
    let (_tmp, root, vault) = new_vault();
    insert_notes(vault.connection_ref(), 0, 50, "body");
    // The same vault snapshots fine before the damage.
    drop(take(&root));
    damage_notes_page(&root, vault);
    let damaged = std::fs::read(root.join("memex.db")).unwrap();

    match snapshot::take_snapshot(&root) {
        Ok(snap) => panic!("a damaged page snapshotted: {snap:?}"),
        Err(e) => assert_eq!(e.code(), "backup_failed", "{e:?}"),
    }
    assert_eq!(
        std::fs::read(root.join("memex.db")).unwrap(),
        damaged,
        "a failed snapshot leaves memex.db as it was"
    );
}

#[test]
fn snapshot_is_a_temp_file_in_the_temp_dir_and_is_deleted_on_drop() {
    let (_tmp, root, vault) = new_vault();
    insert_notes(vault.connection_ref(), 0, 3, "body");
    drop(vault);
    let temp_dir = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    let canonical_root = std::fs::canonicalize(&root).unwrap();

    let snap = take(&root);
    let path = std::fs::canonicalize(&snap.path)
        .unwrap_or_else(|e| panic!("snapshot {} exists while held: {e}", snap.path.display()));
    assert!(path.is_file(), "{} is a file", path.display());
    assert!(
        path.starts_with(&temp_dir),
        "{} is in std::env::temp_dir() {}",
        path.display(),
        temp_dir.display()
    );
    assert!(
        !path.starts_with(&canonical_root),
        "the snapshot is never in the vault"
    );
    let second = take(&root);
    assert_ne!(
        second.path, snap.path,
        "each snapshot has its own temp file"
    );
    drop(snap);
    assert!(!path.exists(), "{} is deleted on drop", path.display());
    assert!(
        second.path.exists(),
        "dropping one snapshot keeps the other"
    );
    let second_path = second.path.clone();
    drop(second);
    assert!(!second_path.exists());
}

#[test]
fn snapshot_of_a_vault_without_memex_db_fails_and_never_creates_it() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("Empty Vault");
    std::fs::create_dir_all(root.join("objects")).unwrap();
    write_manifest(&root, APP_SCHEMA_VERSION);
    assert!(snapshot::take_snapshot(&root).is_err());
    assert!(
        !root.join("memex.db").exists(),
        "a read-only open never creates memex.db"
    );
}

#[test]
fn snapshot_failures_that_never_reach_a_copy_are_backup_failed() {
    let tmp = tempfile::tempdir().unwrap();
    // No vault folder at all.
    let missing = tmp.path().join("No Such Vault");
    let err = snapshot::take_snapshot(&missing).expect_err("no vault folder");
    assert_eq!(err.code(), "backup_failed", "{err:?}");
    assert!(!missing.exists(), "a snapshot never creates the vault");
    // A memex.db that is not a database.
    let root = tmp.path().join("Junk Vault");
    std::fs::create_dir_all(&root).unwrap();
    let junk = vec![b'x'; 4096];
    std::fs::write(root.join("memex.db"), &junk).unwrap();
    let err = snapshot::take_snapshot(&root).expect_err("not a database");
    assert_eq!(err.code(), "backup_failed", "{err:?}");
    assert_eq!(
        std::fs::read(root.join("memex.db")).unwrap(),
        junk,
        "a failed snapshot leaves memex.db as it was"
    );
}

#[test]
fn snapshot_as_the_last_connection_on_a_non_empty_wal_never_writes_the_source() {
    // A vault whose last writer died: memex.db plus a hot -wal and no other
    // connection. If the snapshot's own connection checkpointed on close, it
    // would rewrite memex.db and remove the -wal.
    let (_tmp, root, vault) = new_vault();
    insert_notes(vault.connection_ref(), 0, 5, "checkpointed");
    drop(vault);
    let writer = Connection::open(root.join("memex.db")).unwrap();
    writer.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
    insert_notes(&writer, 5, 20, "only in the wal");
    let wal = std::fs::read(root.join("memex.db-wal")).unwrap();
    assert!(!wal.is_empty(), "the rows are in memex.db-wal");

    let dead = tempfile::tempdir().unwrap();
    let dead_root = dead.path().join("Dead Writer Vault");
    std::fs::create_dir_all(&dead_root).unwrap();
    std::fs::write(
        dead_root.join("memex.db"),
        std::fs::read(root.join("memex.db")).unwrap(),
    )
    .unwrap();
    std::fs::write(dead_root.join("memex.db-wal"), &wal).unwrap();
    drop(writer);
    let main_before = std::fs::read(dead_root.join("memex.db")).unwrap();

    let snap = take(&dead_root);
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(quick_check(&copy), "ok");
    assert_eq!(
        count(&copy, "SELECT COUNT(*) FROM notes"),
        25,
        "the snapshot holds the rows that are only in the -wal"
    );
    drop(copy);
    drop(snap);

    assert_eq!(
        std::fs::read(dead_root.join("memex.db")).unwrap(),
        main_before,
        "memex.db is byte-identical: closing the snapshot connection did not checkpoint"
    );
    assert_eq!(
        std::fs::read(dead_root.join("memex.db-wal")).unwrap(),
        wal,
        "the -wal is untouched"
    );
}

#[test]
fn snapshot_waits_for_a_transient_exclusive_holder_instead_of_failing() {
    let (_tmp, root, vault) = new_vault();
    insert_notes(vault.connection_ref(), 0, 10, "body");
    drop(vault);
    let holder = Connection::open(root.join("memex.db")).unwrap();
    holder
        .pragma_update(None, "locking_mode", "EXCLUSIVE")
        .unwrap();
    holder
        .execute(
            "UPDATE notes SET content_md = 'held' WHERE title = 'note 0'",
            [],
        )
        .unwrap();

    let (started_tx, started_rx) = mpsc::channel::<()>();
    let worker = {
        let root = root.clone();
        thread::spawn(move || {
            started_tx.send(()).unwrap();
            snapshot::take_snapshot(&root)
        })
    };
    started_rx.recv().unwrap();
    // The snapshot has no way to read while the holder has the file, and it
    // waits (it does not fail at once). This only ever fails if it gives up
    // early, never because the machine is slow.
    for _ in 0..30 {
        thread::sleep(std::time::Duration::from_millis(10));
        assert!(
            !worker.is_finished(),
            "the snapshot finished while the exclusive holder still had the file"
        );
    }
    drop(holder);
    let snap = worker
        .join()
        .expect("snapshot thread")
        .unwrap_or_else(|e| panic!("the snapshot after the holder let go: {e:?}"));
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(quick_check(&copy), "ok");
    assert_eq!(
        count(
            &copy,
            "SELECT COUNT(*) FROM notes WHERE content_md = 'held'"
        ),
        1
    );
}

/// Child half of the temp-file test: one `take_snapshot` in a process whose
/// `TMPDIR` is a private folder, then that folder must be empty. Run by its
/// parent, not directly.
#[test]
#[ignore = "child process of no_snapshot_temp_file_remains_after_success_failure_or_drop"]
fn snapshot_317_child_in_private_tmpdir() {
    let Some(vault) = std::env::var_os(CHILD_VAULT_ENV) else {
        return;
    };
    let expect = std::env::var(CHILD_EXPECT_ENV).expect("expected outcome");
    let tmp = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    match (snapshot::take_snapshot(Path::new(&vault)), expect.as_str()) {
        (Ok(snap), "ok") => {
            let path = std::fs::canonicalize(&snap.path).expect("snapshot exists while held");
            assert!(
                path.starts_with(&tmp),
                "{} is in TMPDIR {}",
                path.display(),
                tmp.display()
            );
            drop(snap);
            assert!(!path.exists(), "{} is deleted on drop", path.display());
        }
        (Err(e), "backup_failed") => assert_eq!(e.code(), "backup_failed", "{e:?}"),
        (got, want) => panic!("expected {want}, got {got:?}"),
    }
    let left = all_files(&tmp);
    assert!(left.is_empty(), "left in TMPDIR: {left:?}");
    println!("{CHILD_OK}");
}

fn run_child_with_private_tmpdir(vault: &Path, expect: &str) {
    let tmp = tempfile::tempdir().unwrap();
    let private = tmp.path().join("private tmp");
    std::fs::create_dir(&private).unwrap();
    let out = Command::new(std::env::current_exe().expect("test binary path"))
        .args([
            "--ignored",
            "--exact",
            "snapshot_317_child_in_private_tmpdir",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_VAULT_ENV, vault)
        .env(CHILD_EXPECT_ENV, expect)
        .env("TMPDIR", &private)
        .output()
        .expect("re-exec the test binary");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success() && stdout.contains(CHILD_OK),
        "{expect} snapshot of {}: child failed ({:?})\nstdout:\n{stdout}\nstderr:\n{stderr}",
        vault.display(),
        out.status
    );
    let left = all_files(&private);
    assert!(left.is_empty(), "{expect}: left in TMPDIR: {left:?}");
}

#[test]
fn no_snapshot_temp_file_remains_after_success_failure_or_drop() {
    // Success, then drop.
    let (_ok_tmp, ok_root, ok_vault) = new_vault();
    insert_notes(ok_vault.connection_ref(), 0, 10, "body");
    drop(ok_vault);
    run_child_with_private_tmpdir(&ok_root, "ok");

    // Failure: a damaged page.
    let (_bad_tmp, bad_root, bad_vault) = new_vault();
    insert_notes(bad_vault.connection_ref(), 0, 50, "body");
    damage_notes_page(&bad_root, bad_vault);
    run_child_with_private_tmpdir(&bad_root, "backup_failed");

    // Failure: the source stays locked past the retries.
    let (_busy_tmp, busy_root, busy_vault) = new_vault();
    insert_notes(busy_vault.connection_ref(), 0, 10, "body");
    drop(busy_vault);
    let holder = Connection::open(busy_root.join("memex.db")).unwrap();
    holder
        .pragma_update(None, "locking_mode", "EXCLUSIVE")
        .unwrap();
    holder
        .execute(
            "UPDATE notes SET content_md = 'held' WHERE title = 'note 0'",
            [],
        )
        .unwrap();
    run_child_with_private_tmpdir(&busy_root, "backup_failed");
    drop(holder);
}

/// A vault folder at `<tmp>/<name>` whose `memex.db` is prepared by `seed`
/// (which may leave it absent). Returns the folder and the bytes it ended up
/// with, if any.
fn vault_with_db(
    tmp: &tempfile::TempDir,
    name: &str,
    seed: impl FnOnce(&Path),
) -> (PathBuf, Option<Vec<u8>>) {
    let root = tmp.path().join(name);
    std::fs::create_dir_all(&root).unwrap();
    let db = root.join("memex.db");
    seed(&db);
    let bytes = std::fs::read(&db).ok();
    (root, bytes)
}

#[test]
fn snapshot_of_a_memex_db_with_no_memex_schema_fails_with_backup_failed_and_leaves_no_temp_file() {
    let tmp = tempfile::tempdir().unwrap();
    // An empty file (a truncation or a disk-full incident).
    let (empty, empty_bytes) = vault_with_db(&tmp, "Empty File", |db| {
        std::fs::write(db, b"").unwrap();
    });
    // A valid SQLite file with other tables but no schema_version table.
    let (no_table, no_table_bytes) = vault_with_db(&tmp, "No Version Table", |db| {
        let conn = Connection::open(db).unwrap();
        conn.execute_batch(
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT);
             INSERT INTO notes(title) VALUES ('a');",
        )
        .unwrap();
    });
    // A schema_version table with no rows.
    let (empty_table, empty_table_bytes) = vault_with_db(&tmp, "Empty Version Table", |db| {
        let conn = Connection::open(db).unwrap();
        conn.execute_batch("CREATE TABLE schema_version (version INTEGER PRIMARY KEY);")
            .unwrap();
    });
    // A schema_version table holding only version 0.
    let (zero_row, zero_row_bytes) = vault_with_db(&tmp, "Version Zero Row", |db| {
        let conn = Connection::open(db).unwrap();
        conn.execute_batch(
            "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);
             INSERT INTO schema_version(version) VALUES (0);",
        )
        .unwrap();
    });
    let cases = [
        ("0-byte memex.db", empty, empty_bytes),
        ("no schema_version table", no_table, no_table_bytes),
        ("empty schema_version table", empty_table, empty_table_bytes),
        ("schema_version of 0", zero_row, zero_row_bytes),
    ];

    for (what, root, before) in &cases {
        let err = snapshot::take_snapshot(root).expect_err(what);
        assert_eq!(err.code(), "backup_failed", "{what}: {err:?}");
        assert!(
            err.to_string().contains("schema version"),
            "{what}: the message names the missing schema: {err}"
        );
        assert_eq!(
            &std::fs::read(root.join("memex.db")).ok(),
            before,
            "{what}: a failed snapshot leaves memex.db as it was"
        );
        // No snapshot temp file remains (checked in a private TMPDIR).
        run_child_with_private_tmpdir(root, "backup_failed");
    }
}

#[test]
fn snapshot_of_a_memex_db_at_exactly_schema_version_1_succeeds_with_schema_version_1() {
    // The lowest valid memex schema: a `schema_version` table whose highest
    // row is 1. Only 0 and "no table" mean "no memex schema".
    let tmp = tempfile::tempdir().unwrap();
    let (root, _) = vault_with_db(&tmp, "Version One", |db| {
        let conn = Connection::open(db).unwrap();
        conn.execute_batch(
            "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);
             INSERT INTO schema_version(version) VALUES (1);",
        )
        .unwrap();
    });
    let snap = take(&root);
    assert_eq!(snap.schema_version, 1);
    let (_copy_dir, copy) = open_copy(&snap);
    assert_eq!(
        count(&copy, "SELECT MAX(version) FROM schema_version"),
        1,
        "the snapshot is the version-1 database"
    );
}
