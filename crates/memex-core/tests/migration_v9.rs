//! V9 migration tests (WI #135, Spec #123 R50, R5; Ledger L12; rulings D15
//! and the run's migration order). V9 adds the derived attachment index as
//! add-only tables:
//!
//! - `attachments(path PK, name, type, size, extract_state, extract_error,
//!   extracted_at)`, `extract_state` one of `pending`, `done`, `empty`,
//!   `failed`;
//! - `attachment_chunks(id PK, path → attachments ON DELETE CASCADE, ord,
//!   content, token_count, embed_model_version)`;
//! - `attachment_chunk_fts`: FTS5 over `content`, `chunk_id` and `path`
//!   UNINDEXED, `porter unicode61`;
//! - `attachment_chunk_vec`: vec0, made lazily like `chunk_vec`
//!   ([`schema::ensure_attachment_vector_table`]);
//! - `note_attachments(note_id → notes ON DELETE CASCADE, path,
//!   line_start_byte, PRIMARY KEY (note_id, path, line_start_byte))`.
//!
//! No existing table, column, index or trigger changes. The new regular
//! tables carry the `content_revision` triggers; the FTS5 and vec0 shadow
//! tables don't, as `chunk_fts_*` and `chunk_vec_*` don't.
//!
//! The V8 fixture is the shipped V8 schema (`fixtures/vault_schema_v8.sql`,
//! frozen from the app fixture at V8), plus `chunk_fts` and a lazily made
//! `chunk_vec`, plus rows in notes, links, blocks, chunks and the tables
//! around them. It is pinned at `schema_version` 8, so V9 has work to do on
//! the next `schema::apply()`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use memex_core::{schema, Vault};
use rusqlite::types::ValueRef;
use rusqlite::{params, Connection};
use serde_json::json;

// ---- fixture ----------------------------------------------------------------------------------

const N_DAILY: &str = "01JAV9000000000000000000D1";
const N_TOPIC: &str = "01JAV9000000000000000000T1";
const N_PLAIN: &str = "01JAV9000000000000000000P1";

/// The shipped V8 schema of a fresh vault, with its `schema_version` rows
/// 1..8, its `vault_settings` row and the `content_revision` row (1, 0).
const V8_DDL: &str = include_str!("fixtures/vault_schema_v8.sql");

/// `chunk_fts`, which the schema dump leaves out (FTS5).
const V8_FTS: &str = "CREATE VIRTUAL TABLE chunk_fts USING fts5(
         content,
         chunk_id UNINDEXED,
         note_id UNINDEXED,
         tokenize = 'porter unicode61'
     );";

/// The five R50 tables. `attachment_chunk_vec` is made lazily, so a
/// migration alone makes the other four.
const V9_TABLES: [&str; 4] = [
    "attachments",
    "attachment_chunks",
    "attachment_chunk_fts",
    "note_attachments",
];

/// The V9 tables that carry the revision triggers (the regular ones).
const V9_TRIGGERED: [&str; 3] = ["attachments", "attachment_chunks", "note_attachments"];

/// The three revision triggers of each triggered table: (suffix, event).
const TRIGGER_KINDS: [(&str, &str); 3] = [("ai", "INSERT"), ("au", "UPDATE"), ("ad", "DELETE")];

/// A 64-hex content hash whose first two characters are `h2`.
fn hash(h2: &str) -> String {
    h2.repeat(32)
}

/// The decoded vault-relative path of an attachment `name` with hash `h2…`.
fn object_path(h2: &str, name: &str) -> String {
    format!("objects/{h2}/{}/{name}", hash(h2))
}

/// One row or more in notes, links, blocks, chunks (with FTS and vector
/// rows) and the tables around them.
fn v8_rows() -> String {
    format!(
        "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at,
                            agent_read_only)
             VALUES ('{N_DAILY}', '2026-11-18', 'Standup #work.\n\nShipped the store.\n',
                     '{{\"role\":\"daily\"}}', 3, 1700000100000, 1700000900000, 0);
         INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at,
                            agent_read_only)
             VALUES ('{N_TOPIC}', 'Attachments', '# Attachments\n\nSee [[Pricing notes]].\n',
                     '{{\"role\":\"topic\"}}', 2, 1700000200000, 1700000800000, 1);
         INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at,
                            crdt_state, has_open_questions)
             VALUES ('{N_PLAIN}', 'Pricing notes', 'Tiers and #pricing\n', '{{}}', 4,
                     1700000300000, 1700000350000, X'00FF10', 1);
         INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text, content_hash,
                             source, created_version, created_at)
             VALUES ('{N_DAILY}', 'b1', 0, 0, 14, 'Standup #work.', 'h-1', 'person', 1,
                     1700000100000);
         INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text, content_hash,
                             source, created_version, created_at)
             VALUES ('{N_DAILY}', 'b2', 1, 16, 34, 'Shipped the store.', 'h-2', 'agent', 2,
                     1700000500000);
         INSERT INTO chunks (id, note_id, ord, content, token_count, embed_model_version,
                             start_byte, end_byte)
             VALUES ('C-PLAIN-0', '{N_PLAIN}', 0, 'Tiers and #pricing', 4, 'test-model-1', 0, 18);
         INSERT INTO chunks (id, note_id, ord, content, token_count, embed_model_version,
                             start_byte, end_byte)
             VALUES ('C-TOPIC-0', '{N_TOPIC}', 0, 'See [[Pricing notes]].', 5, NULL, 15, 37);
         INSERT INTO chunk_fts (content, chunk_id, note_id)
             VALUES ('Tiers and #pricing', 'C-PLAIN-0', '{N_PLAIN}');
         INSERT INTO chunk_fts (content, chunk_id, note_id)
             VALUES ('See [[Pricing notes]].', 'C-TOPIC-0', '{N_TOPIC}');
         INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-PLAIN-0', '[1,0,0,0]');
         INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-TOPIC-0', '[0,1,0,0]');
         INSERT INTO tags (note_id, tag, origin, first_line)
             VALUES ('{N_PLAIN}', 'pricing', 'body', 'Tiers and #pricing');
         INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, label, position,
                            source)
             VALUES ('L-1', '{N_TOPIC}', '{N_PLAIN}', 'Pricing notes', 'wikilink', NULL, 0,
                     'inline_body');
         INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES ('AC-1', '{N_PLAIN}', '2026-11-18', 1700000900000, '[\"Updated the tiers\"]');
         INSERT INTO note_revisions (id, note_id, previous_md, previous_version, new_version,
                                     agent_change_id, created_at)
             VALUES ('NR-1', '{N_PLAIN}', 'Tiers\n', 3, 4, 'AC-1', 1700000900001);
         INSERT INTO agent_activity (id, session_id, client_name, tool, summary, note_id,
                                     created_at)
             VALUES ('AA-1', 'S-1', 'Claude', 'edit_note', 'Edited a note', '{N_PLAIN}', 10);
         INSERT INTO learned_words (word_key, word, created_at) VALUES ('memex', 'Memex', 1);
         UPDATE content_revision SET n = 41 WHERE id = 1;"
    )
}

fn open(db_path: &Path) -> Connection {
    let conn = Connection::open(db_path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn
}

/// Registers sqlite-vec for every later connection in this process: the
/// core does it on the first `Vault::create` or `Vault::open`.
fn register_vec0() {
    let dir = tempfile::tempdir().unwrap();
    Vault::create(dir.path().join("vec0")).expect("create a throwaway vault");
}

/// Builds a vault DB pinned at schema V8, with `chunk_vec` and rows in it.
fn make_v8_db(dir: &Path) -> PathBuf {
    register_vec0();
    let db_path = dir.join("memex.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn.execute_batch(V8_DDL).unwrap();
    conn.execute_batch(V8_FTS).unwrap();
    schema::ensure_vector_table(&conn, 4).unwrap();
    conn.execute_batch(&v8_rows()).unwrap();
    assert_eq!(
        schema::current_version(&conn).unwrap(),
        8,
        "fixture: pinned at V8"
    );
    for t in V9_TABLES {
        assert!(!has_table(&conn, t), "fixture: a V8 vault has no {t}");
    }
    drop(conn);
    db_path
}

/// The V8 fixture after one `schema::apply`, asserted to have reached V9.
fn migrated_v8_fixture() -> (tempfile::TempDir, Connection) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v8_db(dir.path());
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V8 -> V9 migration succeeds");
    assert_eq!(
        schema::current_version(&conn).unwrap(),
        9,
        "schema::apply did not advance the V8 fixture to V9"
    );
    (dir, conn)
}

/// A brand-new vault.
fn fresh_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).expect("create a fresh vault");
    (dir, vault)
}

/// A vault folder (manifest at schema 8, objects dir) around the V8
/// fixture, opened through `Vault::open`, which migrates it.
fn opened_v8_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    make_v8_db(dir.path());
    let manifest = json!({
        "vault_id": "01JAV9MANIFEST000000000000",
        "schema_version": 8,
        "created_at": 1_000i64,
    });
    std::fs::write(
        dir.path().join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    std::fs::create_dir_all(dir.path().join("objects")).unwrap();
    let vault = Vault::open(dir.path()).expect("open V8 vault migrates it");
    (dir, vault)
}

// ---- small helpers ----------------------------------------------------------------------------

fn strings(conn: &Connection, sql: &str) -> Vec<String> {
    let mut stmt = conn.prepare(sql).unwrap();
    let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

fn has_table(conn: &Connection, table: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table],
        |r| r.get::<_, i64>(0),
    )
    .unwrap()
        > 0
}

/// Asserts the V9 tables a migration makes exist, naming the missing one.
fn assert_v9_tables(conn: &Connection, what: &str) {
    for t in V9_TABLES {
        assert!(has_table(conn, t), "{what}: V9 makes the {t} table");
    }
}

/// `content_revision.n`.
fn revision(conn: &Connection) -> i64 {
    conn.query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
        r.get(0)
    })
    .expect("content_revision has its row")
}

/// One SQLite value, typed and exact: text verbatim (quoted), blobs in hex.
fn cell(v: ValueRef<'_>) -> String {
    match v {
        ValueRef::Null => "NULL".to_string(),
        ValueRef::Integer(i) => format!("int:{i}"),
        ValueRef::Real(f) => format!("real:{f:?}"),
        ValueRef::Text(t) => format!("text:{:?}", String::from_utf8_lossy(t)),
        ValueRef::Blob(b) => format!(
            "blob:{}",
            b.iter().map(|x| format!("{x:02x}")).collect::<String>()
        ),
    }
}

/// Every row of `table`, each rendered value by value, sorted.
fn table_rows(conn: &Connection, table: &str) -> Vec<String> {
    let mut stmt = conn.prepare(&format!("SELECT * FROM \"{table}\"")).unwrap();
    let n = stmt.column_count();
    let mut rows = stmt.query([]).unwrap();
    let mut out = Vec::new();
    while let Some(r) = rows.next().unwrap() {
        let cells: Vec<String> = (0..n).map(|i| cell(r.get_ref(i).unwrap())).collect();
        out.push(cells.join(" | "));
    }
    out.sort();
    out
}

/// Every table in `sqlite_master` (virtual and shadow tables included),
/// each with all of its rows.
fn all_rows(conn: &Connection) -> BTreeMap<String, Vec<String>> {
    strings(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    )
    .into_iter()
    .map(|t| {
        let rows = table_rows(conn, &t);
        (t, rows)
    })
    .collect()
}

/// Every `sqlite_master` entry: (type, name) → (tbl_name, sql).
fn master(conn: &Connection) -> BTreeMap<(String, String), (String, String)> {
    let mut stmt = conn
        .prepare("SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master")
        .unwrap();
    let rows = stmt
        .query_map([], |r| Ok(((r.get(0)?, r.get(1)?), (r.get(2)?, r.get(3)?))))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// The schema plus every row of every table.
fn full_snapshot(conn: &Connection) -> Vec<String> {
    let mut out: Vec<String> = master(conn)
        .into_iter()
        .map(|((ty, name), (tbl, sql))| format!("{ty} {name} {tbl} {sql}"))
        .collect();
    for (t, rows) in all_rows(conn) {
        out.push(format!("== {t}"));
        out.extend(rows);
    }
    out
}

/// `sql` lower-cased with every whitespace run removed.
fn squash(sql: &str) -> String {
    sql.split_whitespace().collect::<String>().to_lowercase()
}

/// Whether `conn` holds the `content_revision_<table>_<suffix>` trigger:
/// `AFTER <event> ON <table>`, adding one to `content_revision.n`.
fn has_revision_trigger(conn: &Connection, table: &str, suffix: &str, event: &str) -> bool {
    let name = format!("content_revision_{table}_{suffix}");
    let sql: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1 AND tbl_name = ?2",
            params![name, table],
            |r| r.get(0),
        )
        .ok();
    let Some(sql) = sql else { return false };
    let sql = squash(&sql);
    sql.contains(&format!("after{}on", event.to_lowercase()))
        && sql.contains("updatecontent_revisionsetn=n+1whereid=1")
}

/// Every trigger in the database, by the table it is on.
fn triggers_by_table(conn: &Connection) -> BTreeMap<String, BTreeSet<String>> {
    let mut stmt = conn
        .prepare("SELECT tbl_name, name FROM sqlite_master WHERE type = 'trigger'")
        .unwrap();
    let rows: Vec<(String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    let mut out: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (table, name) in rows {
        out.entry(table).or_default().insert(name);
    }
    out
}

/// (name, declared type, position in the primary key, 0 when not in it).
type Column = (String, String, i64);

fn columns(conn: &Connection, table: &str) -> Vec<Column> {
    let mut stmt = conn
        .prepare("SELECT name, type, pk FROM pragma_table_info(?1) ORDER BY cid")
        .unwrap();
    let rows = stmt
        .query_map([table], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn col(name: &str, ty: &str, pk: i64) -> Column {
    (name.to_string(), ty.to_string(), pk)
}

/// (from, table, to, on_delete) of each foreign key of `table`, by `from`.
fn foreign_keys(conn: &Connection, table: &str) -> Vec<(String, String, String, String)> {
    let mut stmt = conn
        .prepare(
            "SELECT \"from\", \"table\", \"to\", on_delete FROM pragma_foreign_key_list(?1)
             ORDER BY \"from\"",
        )
        .unwrap();
    let rows = stmt
        .query_map([table], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn fk(from: &str, table: &str, to: &str, on_delete: &str) -> (String, String, String, String) {
    (
        from.to_string(),
        table.to_string(),
        to.to_string(),
        on_delete.to_string(),
    )
}

/// One `attachments` row for `path` (built from run-time values).
fn insert_attachment(conn: &Connection, path: &str, state: &str) {
    let name = path.rsplit('/').next().unwrap().to_string();
    conn.execute(
        "INSERT INTO attachments (path, name, type, size, extract_state, extract_error, extracted_at)
         VALUES (?1, ?2, 'application/pdf', ?3, ?4, NULL, NULL)",
        params![path, name, name.len() as i64 * 1000, state],
    )
    .unwrap_or_else(|e| panic!("insert attachment {path}: {e}"));
}

/// The fresh vault and the migrated V8 fixture, each labelled, for tests
/// that hold on both.
fn both_v9_connections() -> [(&'static str, MakeV9); 2] {
    [
        ("fresh vault", || {
            let (dir, vault) = fresh_vault();
            (dir, Holder::Vault(vault))
        }),
        ("migrated V8 fixture", || {
            let (dir, conn) = migrated_v8_fixture();
            (dir, Holder::Conn(conn))
        }),
    ]
}

/// Makes one V9 database, kept alive by its temp dir.
type MakeV9 = fn() -> (tempfile::TempDir, Holder);

enum Holder {
    Vault(Vault),
    Conn(Connection),
}

impl Holder {
    fn conn(&self) -> &Connection {
        match self {
            Holder::Vault(v) => v.connection_ref(),
            Holder::Conn(c) => c,
        }
    }
}

// ---- AC 1: version, the five R50 tables, nothing else changes ---------------------------------

#[test]
fn app_schema_version_is_9() {
    assert_eq!(schema::APP_SCHEMA_VERSION, 9);
}

#[test]
fn fresh_vault_opens_at_v9_with_the_v9_tables_and_reopening_runs_no_further_migration() {
    let (dir, vault) = fresh_vault();
    assert_eq!(vault.schema_version(), 9);
    let conn = vault.connection_ref();
    assert_eq!(schema::current_version(conn).unwrap(), 9);
    assert_eq!(
        strings(
            conn,
            "SELECT CAST(version AS TEXT) FROM schema_version ORDER BY version"
        ),
        ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
    );
    assert_v9_tables(conn, "fresh vault");
    assert!(
        !has_table(conn, "attachment_chunk_vec"),
        "attachment_chunk_vec is made lazily, not by the migration"
    );
    let before = full_snapshot(conn);
    drop(vault);

    for round in 0..2 {
        let vault = Vault::open(dir.path().join("vault")).expect("reopen the V9 vault");
        assert_eq!(vault.schema_version(), 9, "round {round}");
        assert_eq!(
            full_snapshot(vault.connection_ref()),
            before,
            "round {round}: opening a V9 vault migrates nothing"
        );
        let manifest: serde_json::Value = serde_json::from_slice(
            &std::fs::read(dir.path().join("vault").join("manifest.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(manifest["schema_version"].as_i64(), Some(9), "{manifest}");
    }
}

#[test]
fn v8_vault_open_migrates_to_v9_and_rewrites_the_manifest() {
    let (dir, vault) = opened_v8_vault();
    assert_eq!(vault.schema_version(), 9);
    assert_eq!(schema::current_version(vault.connection_ref()).unwrap(), 9);
    let on_disk: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("manifest.json")).unwrap()).unwrap();
    assert_eq!(on_disk["schema_version"].as_i64(), Some(9), "{on_disk}");
    assert_eq!(
        on_disk["vault_id"].as_str(),
        Some("01JAV9MANIFEST000000000000")
    );
    assert_eq!(on_disk["created_at"].as_i64(), Some(1_000));
    let conn = vault.connection_ref();
    assert_v9_tables(conn, "opened V8 vault");
    // No backfill (R50): no vault holds attachments before this release.
    for t in V9_TABLES {
        assert_eq!(
            count(conn, &format!("SELECT COUNT(*) FROM {t}")),
            0,
            "{t} starts empty"
        );
    }
}

#[test]
fn v9_attachments_has_exactly_the_r50_columns_and_extract_state_is_one_of_four() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        assert_eq!(
            columns(conn, "attachments"),
            [
                col("path", "TEXT", 1),
                col("name", "TEXT", 0),
                col("type", "TEXT", 0),
                col("size", "INTEGER", 0),
                col("extract_state", "TEXT", 0),
                col("extract_error", "TEXT", 0),
                col("extracted_at", "INTEGER", 0),
            ],
            "{what}"
        );
        assert!(foreign_keys(conn, "attachments").is_empty(), "{what}");

        // Every R44 state is accepted, built from run-time values.
        for (i, state) in ["pending", "done", "empty", "failed"].iter().enumerate() {
            let path = object_path(&format!("{:x}{:x}", i + 10, i + 10), &format!("f{i}.pdf"));
            insert_attachment(conn, &path, state);
        }
        assert_eq!(
            strings(
                conn,
                "SELECT extract_state FROM attachments ORDER BY extract_state"
            ),
            ["done", "empty", "failed", "pending"],
            "{what}"
        );
        // Anything else is refused.
        for bad in ["bogus", "Pending", ""] {
            let err = conn
                .execute(
                    "INSERT INTO attachments (path, name, type, size, extract_state)
                     VALUES (?1, 'x.pdf', 'application/pdf', 1, ?2)",
                    params![object_path("ee", "x.pdf"), bad],
                )
                .expect_err(&format!("{what}: extract_state {bad:?} is refused"));
            assert!(err.to_string().contains("CHECK"), "{what}: {err}");
        }
        // A path is one row.
        let dup = conn.execute(
            "INSERT INTO attachments (path, name, type, size, extract_state)
             VALUES (?1, 'f0.pdf', 'application/pdf', 1, 'pending')",
            params![object_path("aa", "f0.pdf")],
        );
        assert!(dup.is_err(), "{what}: path is the primary key");
    }
}

#[test]
fn v9_attachment_chunks_has_exactly_the_r50_columns_and_cascades_from_attachments() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        assert_eq!(
            columns(conn, "attachment_chunks"),
            [
                col("id", "TEXT", 1),
                col("path", "TEXT", 0),
                col("ord", "INTEGER", 0),
                col("content", "TEXT", 0),
                col("token_count", "INTEGER", 0),
                col("embed_model_version", "TEXT", 0),
            ],
            "{what}"
        );
        assert_eq!(
            foreign_keys(conn, "attachment_chunks"),
            [fk("path", "attachments", "path", "CASCADE")],
            "{what}"
        );

        // The key works: a chunk of a missing attachment is refused, and
        // deleting an attachment takes only its own chunks with it.
        let kept = object_path("1a", "kept.pdf");
        let gone = object_path("2b", "gone.pdf");
        insert_attachment(conn, &kept, "done");
        insert_attachment(conn, &gone, "done");
        let err = conn
            .execute(
                "INSERT INTO attachment_chunks (id, path, ord, content, token_count)
                 VALUES ('AC-X', ?1, 0, 'x', 1)",
                params![object_path("3c", "missing.pdf")],
            )
            .expect_err("path references attachments(path)");
        assert!(err.to_string().contains("FOREIGN KEY"), "{what}: {err}");
        for (id, path, ord) in [
            ("AC-K0", &kept, 0),
            ("AC-G0", &gone, 0),
            ("AC-G1", &gone, 1),
        ] {
            conn.execute(
                "INSERT INTO attachment_chunks (id, path, ord, content, token_count,
                                                embed_model_version)
                 VALUES (?1, ?2, ?3, 'Quarterly revenue', 2, NULL)",
                params![id, path, ord],
            )
            .unwrap();
        }
        conn.execute("DELETE FROM attachments WHERE path = ?1", [&gone])
            .unwrap();
        assert_eq!(
            strings(conn, "SELECT id FROM attachment_chunks ORDER BY id"),
            ["AC-K0"],
            "{what}: ON DELETE CASCADE removes only the deleted attachment's chunks"
        );
    }
}

#[test]
fn v9_note_attachments_has_exactly_the_r50_columns_its_primary_key_and_only_the_note_cascade() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        assert_eq!(
            columns(conn, "note_attachments"),
            [
                col("note_id", "TEXT", 1),
                col("path", "TEXT", 2),
                col("line_start_byte", "INTEGER", 3),
            ],
            "{what}"
        );
        // `path` has no key to `attachments` (R50): a note may reference a
        // file the index holds no row for.
        assert_eq!(
            foreign_keys(conn, "note_attachments"),
            [fk("note_id", "notes", "id", "CASCADE")],
            "{what}"
        );

        conn.execute_batch(
            "INSERT INTO notes (id, title, content_md, created_at, updated_at)
                 VALUES ('01JAV9NOTEA00000000000000A', 'Note A', 'a', 1, 1);
             INSERT INTO notes (id, title, content_md, created_at, updated_at)
                 VALUES ('01JAV9NOTEB00000000000000B', 'Note B', 'b', 1, 1);",
        )
        .unwrap();
        let path = object_path("4d", "Q3 report.pdf");
        assert_eq!(count(conn, "SELECT COUNT(*) FROM attachments"), 0);
        for (note, line) in [
            ("01JAV9NOTEA00000000000000A", 0i64),
            ("01JAV9NOTEA00000000000000A", 42),
            ("01JAV9NOTEB00000000000000B", 0),
        ] {
            conn.execute(
                "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?1, ?2, ?3)",
                params![note, path, line],
            )
            .unwrap_or_else(|e| panic!("{what}: a reference row needs no attachments row: {e}"));
        }
        // The same (note, path, line) is one row.
        let dup = conn.execute(
            "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?1, ?2, 42)",
            params!["01JAV9NOTEA00000000000000A", path],
        );
        assert!(
            dup.is_err(),
            "{what}: (note_id, path, line_start_byte) is the key"
        );
        // A reference of a missing note is refused.
        let err = conn
            .execute(
                "INSERT INTO note_attachments (note_id, path, line_start_byte)
                 VALUES ('01JAV9NOSUCHNOTE000000000X', ?1, 0)",
                params![path],
            )
            .expect_err("note_id references notes(id)");
        assert!(err.to_string().contains("FOREIGN KEY"), "{what}: {err}");
        // Deleting a note takes only its own rows.
        conn.execute(
            "DELETE FROM notes WHERE id = '01JAV9NOTEA00000000000000A'",
            [],
        )
        .unwrap();
        assert_eq!(
            strings(conn, "SELECT note_id FROM note_attachments"),
            ["01JAV9NOTEB00000000000000B"],
            "{what}"
        );
    }
}

#[test]
fn v9_attachment_chunk_fts_is_fts5_over_content_with_chunk_id_and_path_unindexed_porter_unicode61()
{
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        let sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE name = 'attachment_chunk_fts'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let sql = squash(&sql);
        assert!(sql.starts_with("createvirtualtable"), "{what}: {sql}");
        assert!(sql.contains("usingfts5("), "{what}: {sql}");
        assert!(sql.contains("porterunicode61"), "{what}: {sql}");
        let names: BTreeSet<String> = columns(conn, "attachment_chunk_fts")
            .into_iter()
            .map(|c| c.0)
            .collect();
        assert_eq!(
            names,
            ["chunk_id", "content", "path"]
                .into_iter()
                .map(String::from)
                .collect(),
            "{what}"
        );

        let path = object_path("5e", "zebrafile.txt");
        conn.execute(
            "INSERT INTO attachment_chunk_fts (content, chunk_id, path)
             VALUES ('The runners kept running past the Café', 'zebrachunk', ?1)",
            params![path],
        )
        .unwrap();
        let hits = |q: &str| -> Vec<(String, String)> {
            let mut stmt = conn
                .prepare(
                    "SELECT chunk_id, path FROM attachment_chunk_fts
                     WHERE attachment_chunk_fts MATCH ?1",
                )
                .unwrap();
            let rows = stmt.query_map([q], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
            rows.map(|r| r.unwrap()).collect()
        };
        let one = vec![("zebrachunk".to_string(), path.clone())];
        // porter: "run" finds "runners"/"running"; unicode61: "cafe" finds "Café".
        assert_eq!(hits("run"), one, "{what}: porter stems content");
        assert_eq!(hits("cafe"), one, "{what}: unicode61 folds diacritics");
        // chunk_id and path are stored, not indexed.
        assert!(
            hits("zebrachunk").is_empty(),
            "{what}: chunk_id is UNINDEXED"
        );
        assert!(hits("zebrafile").is_empty(), "{what}: path is UNINDEXED");
    }
}

#[test]
fn attachment_chunk_vec_is_made_lazily_as_vec0_like_chunk_vec_and_ensure_vector_table_still_makes_only_chunk_vec(
) {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    assert_v9_tables(conn, "fresh vault");
    assert!(!has_table(conn, "attachment_chunk_vec"));

    // The note-chunk table's maker, signature unchanged, makes chunk_vec only.
    schema::ensure_vector_table(conn, 4).unwrap();
    assert!(has_table(conn, "chunk_vec"));
    assert!(
        !has_table(conn, "attachment_chunk_vec"),
        "ensure_vector_table makes only chunk_vec"
    );

    // Made on demand, idempotently, with chunk_vec's shape.
    schema::ensure_attachment_vector_table(conn, 4).unwrap();
    schema::ensure_attachment_vector_table(conn, 4).unwrap();
    assert!(
        has_table(conn, "attachment_chunk_vec"),
        "ensure_attachment_vector_table makes attachment_chunk_vec"
    );
    let sql_of = |name: &str| -> String {
        conn.query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [name],
            |r| r.get::<_, String>(0),
        )
        .unwrap()
    };
    assert_eq!(
        squash(&sql_of("attachment_chunk_vec")).replace("attachment_chunk_vec", "chunk_vec"),
        squash(&sql_of("chunk_vec")),
        "attachment_chunk_vec is declared like chunk_vec: vec0, chunk_id key, cosine"
    );
    assert_eq!(
        count(
            conn,
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'attachment_chunk_vec'"
        ),
        1
    );

    // It holds vectors keyed by chunk id and answers a nearest-neighbour query.
    for (id, v) in [("AC-0", "[1,0,0,0]"), ("AC-1", "[0,1,0,0]")] {
        conn.execute(
            "INSERT INTO attachment_chunk_vec (chunk_id, embedding) VALUES (?1, ?2)",
            params![id, v],
        )
        .unwrap();
    }
    let nearest: String = conn
        .query_row(
            "SELECT chunk_id FROM attachment_chunk_vec
             WHERE embedding MATCH '[0.1,0.9,0,0]' AND k = 1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(nearest, "AC-1");
    // A second dimension on an existing table changes nothing.
    schema::ensure_attachment_vector_table(conn, 8).unwrap();
    assert_eq!(count(conn, "SELECT COUNT(*) FROM attachment_chunk_vec"), 2);
}

#[test]
fn v8_fixture_migration_changes_no_existing_table_index_trigger_or_column() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v8_db(dir.path());
    let before = master(&open(&db_path));
    let old_columns: BTreeMap<String, Vec<Column>> = {
        let old = open(&db_path);
        before
            .keys()
            .filter(|(ty, _)| ty == "table")
            .map(|(_, name)| (name.clone(), columns(&old, name)))
            .collect()
    };

    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V8 -> V9 migration succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 9);
    assert_v9_tables(&conn, "migrated V8 fixture");
    let after = master(&conn);

    // Every existing table, index and trigger is kept with the same SQL, so
    // no column was added, dropped or changed.
    for (key, value) in &before {
        assert_eq!(
            after.get(key),
            Some(value),
            "{key:?} is unchanged by V9 (add-only DDL)"
        );
    }
    // Everything new belongs to a V9 table (its shadow tables, indexes and
    // triggers included).
    let is_v9 = |tbl: &str| V9_TABLES.contains(&tbl) || tbl.starts_with("attachment_chunk_fts_");
    for ((ty, name), (tbl, _)) in after.iter().filter(|(k, _)| !before.contains_key(*k)) {
        assert!(
            is_v9(tbl),
            "V9 adds only V9 objects: {ty} {name} is on {tbl}"
        );
    }
    // The columns of every pre-existing table are exactly as before.
    for (t, cols) in &old_columns {
        assert_eq!(&columns(&conn, t), cols, "{t} columns unchanged");
    }
}

// ---- AC 2: every row kept, a second open is a no-op -------------------------------------------

#[test]
fn v8_fixture_with_notes_links_blocks_and_chunks_keeps_every_row_after_migration() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v8_db(dir.path());
    let before = all_rows(&open(&db_path));
    assert_eq!(before["notes"].len(), 3);
    assert_eq!(before["links"].len(), 1);
    assert_eq!(before["blocks"].len(), 2);
    assert_eq!(before["chunks"].len(), 2);
    assert_eq!(before["chunk_vec"].len(), 2);

    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V8 -> V9 migration succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 9);
    assert_v9_tables(&conn, "migrated V8 fixture");

    let after = all_rows(&conn);
    for (table, rows) in &before {
        if table == "schema_version" {
            continue;
        }
        assert_eq!(&after[table], rows, "{table} rows unchanged by V9");
    }
    assert_eq!(
        strings(
            &conn,
            "SELECT CAST(version AS TEXT) FROM schema_version ORDER BY version"
        ),
        ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
    );
    // V9 adds only empty tables (FTS5 shadow tables hold their own
    // bookkeeping rows, not content).
    for t in ["attachments", "attachment_chunks", "note_attachments"] {
        assert!(after[t].is_empty(), "{t} starts empty");
    }
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM attachment_chunk_fts"), 0);
    // The FTS rows still answer.
    assert_eq!(
        strings(
            &conn,
            "SELECT chunk_id FROM chunk_fts WHERE chunk_fts MATCH 'pricing' ORDER BY chunk_id"
        ),
        ["C-PLAIN-0", "C-TOPIC-0"]
    );
}

#[test]
fn v9_migration_moves_no_content_revision_n() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v8_db(dir.path());
    assert_eq!(revision(&open(&db_path)), 41);
    let mut conn = open(&db_path);
    schema::apply(&mut conn).unwrap();
    assert_eq!(schema::current_version(&conn).unwrap(), 9);
    assert_eq!(revision(&conn), 41, "the V9 step writes no content");

    let (_fresh_dir, fresh) = fresh_vault();
    assert_eq!(
        revision(fresh.connection_ref()),
        0,
        "a fresh vault's counter still reads 0"
    );
}

#[test]
fn a_second_apply_on_a_migrated_v9_vault_changes_nothing() {
    let (_dir, mut conn) = migrated_v8_fixture();
    // Some V9 content, so a re-run that recreated or cleared a table shows.
    let path = object_path("6f", "kept.pdf");
    insert_attachment(&conn, &path, "done");
    conn.execute(
        "INSERT INTO attachment_chunks (id, path, ord, content, token_count)
         VALUES ('AC-0', ?1, 0, 'Kept text', 2)",
        params![path],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO attachment_chunk_fts (content, chunk_id, path) VALUES ('Kept text', 'AC-0', ?1)",
        params![path],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?1, ?2, 0)",
        params![N_PLAIN, path],
    )
    .unwrap();
    let before = full_snapshot(&conn);
    schema::apply(&mut conn).expect("second apply succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 9);
    assert_eq!(full_snapshot(&conn), before, "a second apply is a no-op");
}

#[test]
fn reopening_a_migrated_v8_vault_twice_migrates_nothing() {
    let (dir, vault) = opened_v8_vault();
    let before = full_snapshot(vault.connection_ref());
    drop(vault);
    for round in 0..2 {
        let vault = Vault::open(dir.path()).expect("reopen the migrated vault");
        assert_eq!(vault.schema_version(), 9, "round {round}");
        assert_eq!(
            full_snapshot(vault.connection_ref()),
            before,
            "round {round}: a second open is a no-op"
        );
    }
}

#[test]
fn rerunning_the_v9_step_after_a_lost_version_row_keeps_every_row() {
    let (_dir, mut conn) = migrated_v8_fixture();
    let path = object_path("7a", "kept.pdf");
    insert_attachment(&conn, &path, "failed");
    conn.execute(
        "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?1, ?2, 7)",
        params![N_TOPIC, path],
    )
    .unwrap();
    let rows_before = all_rows(&conn);
    conn.execute("DELETE FROM schema_version WHERE version = 9", [])
        .unwrap();
    assert_eq!(schema::current_version(&conn).unwrap(), 8);

    schema::apply(&mut conn).expect("re-running the V9 step succeeds (IF NOT EXISTS)");
    assert_eq!(schema::current_version(&conn).unwrap(), 9);
    let rows_after = all_rows(&conn);
    for (table, rows) in &rows_before {
        if table == "schema_version" || table == "content_revision" {
            continue;
        }
        assert_eq!(&rows_after[table], rows, "{table} rows kept by the re-run");
    }
}

// ---- AC 3: content_revision -------------------------------------------------------------------

#[test]
fn the_three_regular_v9_tables_carry_the_revision_triggers_and_no_attachment_fts_shadow_table_does()
{
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        for t in V9_TRIGGERED {
            for (suffix, event) in TRIGGER_KINDS {
                assert!(
                    has_revision_trigger(conn, t, suffix, event),
                    "{what}: content_revision_{t}_{suffix} AFTER {event}"
                );
            }
        }
        let fts_shadows = strings(
            conn,
            "SELECT name FROM sqlite_master
             WHERE type = 'table' AND name LIKE 'attachment~_chunk~_fts~_%' ESCAPE '~'",
        );
        assert!(
            !fts_shadows.is_empty(),
            "{what}: attachment_chunk_fts has its FTS5 shadow tables"
        );
        let triggers = triggers_by_table(conn);
        for t in fts_shadows
            .iter()
            .map(String::as_str)
            .chain(["attachment_chunk_fts"])
        {
            assert!(
                !triggers.contains_key(t),
                "{what}: {t} carries no trigger, found {:?}",
                triggers.get(t)
            );
        }
    }
}

#[test]
fn writes_to_attachment_chunk_fts_do_not_change_content_revision() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        let path = object_path("8b", "notes.txt");
        let n = revision(conn);
        conn.execute(
            "INSERT INTO attachment_chunk_fts (content, chunk_id, path) VALUES ('alpha', 'AC-0', ?1)",
            params![path],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO attachment_chunk_fts (content, chunk_id, path) VALUES ('beta', 'AC-1', ?1)",
            params![path],
        )
        .unwrap();
        conn.execute(
            "UPDATE attachment_chunk_fts SET content = 'gamma' WHERE chunk_id = 'AC-0'",
            [],
        )
        .unwrap();
        conn.execute(
            "DELETE FROM attachment_chunk_fts WHERE chunk_id = 'AC-1'",
            [],
        )
        .unwrap();
        assert_eq!(
            revision(conn),
            n,
            "{what}: attachment_chunk_fts writes move no content_revision"
        );
        assert_eq!(count(conn, "SELECT COUNT(*) FROM attachment_chunk_fts"), 1);
    }
}

#[test]
fn writes_to_attachment_chunk_vec_once_created_do_not_change_content_revision() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        schema::ensure_attachment_vector_table(conn, 4).unwrap();
        assert!(has_table(conn, "attachment_chunk_vec"), "{what}");
        let n = revision(conn);
        conn.execute_batch(
            "INSERT INTO attachment_chunk_vec (chunk_id, embedding) VALUES ('AC-0', '[1,0,0,0]');
             INSERT INTO attachment_chunk_vec (chunk_id, embedding) VALUES ('AC-1', '[0,1,0,0]');
             DELETE FROM attachment_chunk_vec WHERE chunk_id = 'AC-1';",
        )
        .unwrap();
        assert_eq!(
            revision(conn),
            n,
            "{what}: attachment_chunk_vec writes move no content_revision"
        );
    }
}

#[test]
fn attachment_chunk_vec_shadow_tables_stay_exempt_when_the_revision_triggers_are_put_again() {
    // The revision triggers are put on every non-exempt table each time a
    // migration step runs. Re-running the V9 step once attachment_chunk_vec
    // exists (as any later migration would) must leave its vec0 shadow
    // tables, and attachment_chunk_fts's, without triggers.
    let (_dir, mut conn) = migrated_v8_fixture();
    schema::ensure_attachment_vector_table(&conn, 4).unwrap();
    conn.execute(
        "INSERT INTO attachment_chunk_vec (chunk_id, embedding) VALUES ('AC-0', '[1,0,0,0]')",
        [],
    )
    .unwrap();
    let vec_shadows = strings(
        &conn,
        "SELECT name FROM sqlite_master
         WHERE type = 'table' AND name LIKE 'attachment~_chunk~_vec~_%' ESCAPE '~'",
    );
    assert!(
        !vec_shadows.is_empty(),
        "attachment_chunk_vec has its vec0 shadow tables"
    );
    conn.execute("DELETE FROM schema_version WHERE version = 9", [])
        .unwrap();
    schema::apply(&mut conn).expect("re-running the V9 step succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 9);

    let fts_shadows = strings(
        &conn,
        "SELECT name FROM sqlite_master
         WHERE type = 'table' AND name LIKE 'attachment~_chunk~_fts~_%' ESCAPE '~'",
    );
    let triggers = triggers_by_table(&conn);
    for t in vec_shadows.iter().chain(&fts_shadows) {
        assert!(
            !triggers.contains_key(t),
            "{t} carries no trigger, found {:?}",
            triggers.get(t)
        );
    }
    let n = revision(&conn);
    conn.execute_batch(
        "INSERT INTO attachment_chunk_vec (chunk_id, embedding) VALUES ('AC-1', '[0,1,0,0]');
         DELETE FROM attachment_chunk_vec WHERE chunk_id = 'AC-0';
         INSERT INTO attachment_chunk_fts (content, chunk_id, path) VALUES ('alpha', 'AC-1', 'p');
         DELETE FROM attachment_chunk_fts WHERE chunk_id = 'AC-1';",
    )
    .unwrap();
    assert_eq!(
        revision(&conn),
        n,
        "shadow-table writes move no content_revision"
    );
}

#[test]
fn each_insert_update_and_delete_on_attachments_moves_content_revision_by_one() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        let path = object_path("9c", "report.pdf");
        let n0 = revision(conn);
        insert_attachment(conn, &path, "pending");
        assert_eq!(revision(conn), n0 + 1, "{what}: INSERT on attachments");
        conn.execute(
            "UPDATE attachments SET extract_state = 'done', extracted_at = 5 WHERE path = ?1",
            [&path],
        )
        .unwrap();
        assert_eq!(revision(conn), n0 + 2, "{what}: UPDATE on attachments");
        conn.execute("DELETE FROM attachments WHERE path = ?1", [&path])
            .unwrap();
        assert_eq!(revision(conn), n0 + 3, "{what}: DELETE on attachments");
    }
}

#[test]
fn writes_to_attachment_chunks_and_note_attachments_move_content_revision() {
    for (what, make) in both_v9_connections() {
        let (_dir, h) = make();
        let conn = h.conn();
        assert_v9_tables(conn, what);
        conn.execute(
            "INSERT OR IGNORE INTO notes (id, title, content_md, created_at, updated_at)
             VALUES (?1, 'Pricing notes', 'x', 1, 1)",
            [N_PLAIN],
        )
        .unwrap();
        let path = object_path("0d", "deck.pdf");
        insert_attachment(conn, &path, "done");

        let n = revision(conn);
        conn.execute(
            "INSERT INTO attachment_chunks (id, path, ord, content, token_count)
             VALUES ('AC-0', ?1, 0, 'Slide one', 2)",
            [&path],
        )
        .unwrap();
        assert_eq!(revision(conn), n + 1, "{what}: INSERT on attachment_chunks");
        conn.execute(
            "UPDATE attachment_chunks SET embed_model_version = 'm1' WHERE id = 'AC-0'",
            [],
        )
        .unwrap();
        assert_eq!(revision(conn), n + 2, "{what}: UPDATE on attachment_chunks");
        conn.execute("DELETE FROM attachment_chunks WHERE id = 'AC-0'", [])
            .unwrap();
        assert_eq!(revision(conn), n + 3, "{what}: DELETE on attachment_chunks");

        conn.execute(
            "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?1, ?2, 0)",
            params![N_PLAIN, path],
        )
        .unwrap();
        assert_eq!(revision(conn), n + 4, "{what}: INSERT on note_attachments");
        conn.execute(
            "UPDATE note_attachments SET line_start_byte = 9 WHERE note_id = ?1",
            [N_PLAIN],
        )
        .unwrap();
        assert_eq!(revision(conn), n + 5, "{what}: UPDATE on note_attachments");
        conn.execute("DELETE FROM note_attachments WHERE note_id = ?1", [N_PLAIN])
            .unwrap();
        assert_eq!(revision(conn), n + 6, "{what}: DELETE on note_attachments");
    }
}
