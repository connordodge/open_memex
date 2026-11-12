//! V7 migration tests (WI #415, Spec #391 requirements 3, 8 and 10, ruling
//! D2). V7 adds `agent_activity` (and `idx_agent_activity_created`),
//! `learned_words` and the single-row `content_revision` counter, puts
//! `content_revision_<t>_{ai,au,ad}` triggers on every regular table except
//! the exempt ones, and queues every note in `pending_index` (the one-time
//! rechunk), in one transaction.
//!
//! The V6 fixture is built inline (the shipped V6 schema, as
//! `app/test/fixtures/vault_schema_v5.sql` held it before V7, plus the
//! `chunk_fts` virtual table) and pinned at `schema_version` 6 so V7 has work
//! to do on the next `schema::apply()`. A second fixture adds `chunk_vec`
//! (vec0) with a stored vector, so its shadow tables exist when V7 runs.
//!
//! No test here drops `content_revision`: every other table's triggers would
//! then fail on every write.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use memex_core::notes::{create_note, update_note, CreateNote, UpdateNote};
use memex_core::{schema, Vault};
use rusqlite::types::ValueRef;
use rusqlite::{params, Connection};
use serde_json::json;

// ---- fixture ----------------------------------------------------------------------------------

const N_DAILY: &str = "01J9V7000000000000000000D1";
const N_TOPIC: &str = "01J9V7000000000000000000T1";
const N_PLAIN: &str = "01J9V7000000000000000000P1";
const N_GUIDE: &str = "01J9V7000000000000000000G1";
const N_QUEUED: &str = "01J9V7000000000000000000Q1";

/// Every note in the V6 fixture.
const FIXTURE_NOTES: [&str; 5] = [N_DAILY, N_TOPIC, N_PLAIN, N_GUIDE, N_QUEUED];

/// `enqueued_at` of the `pending_index` row the V6 fixture already holds.
const QUEUED_AT: i64 = 1_700_000_000_123;

/// Every regular table of a V6 vault, `sqlite_sequence` and the FTS shadow
/// tables aside.
const V6_REGULAR_TABLES: [&str; 20] = [
    "agent_changes",
    "blocks",
    "canvas_nodes",
    "canvases",
    "chunks",
    "day_review_blocks",
    "day_reviews",
    "feedback",
    "footer_chips",
    "links",
    "notes",
    "notes_dedup_log",
    "pending_index",
    "schema_version",
    "smart_folder_members",
    "smart_folders",
    "tag_corrections",
    "tags",
    "vault_guide_revisions",
    "vault_settings",
];

/// The tables V7 adds.
const V7_TABLES: [&str; 3] = ["agent_activity", "learned_words", "content_revision"];

/// The three revision triggers of each triggered table: (suffix, event).
const TRIGGER_KINDS: [(&str, &str); 3] = [("ai", "INSERT"), ("au", "UPDATE"), ("ad", "DELETE")];

/// The shipped V6 schema (v1..v6), FTS included, pinned at version 6.
const V6_DDL: &str = "CREATE TABLE agent_changes (
         id            TEXT PRIMARY KEY,
         note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         day           TEXT NOT NULL,
         created_at    INTEGER NOT NULL,
         bullets_json  TEXT NOT NULL
     );

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

     CREATE TABLE canvas_nodes (
         canvas_id   TEXT NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
         note_id     TEXT NOT NULL REFERENCES notes(id)    ON DELETE CASCADE,
         x           REAL NOT NULL,
         y           REAL NOT NULL,
         z_order     INTEGER NOT NULL DEFAULT 0,
         placed_at   INTEGER NOT NULL,
         PRIMARY KEY (canvas_id, note_id)
     );

     CREATE TABLE canvases (
         id          TEXT PRIMARY KEY,
         title       TEXT NOT NULL,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL,
         version     INTEGER NOT NULL DEFAULT 1
     );

     CREATE TABLE chunks (
         id                  TEXT PRIMARY KEY,
         note_id             TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         ord                 INTEGER NOT NULL,
         content             TEXT NOT NULL,
         token_count         INTEGER NOT NULL,
         embed_model_version TEXT
     , start_byte INTEGER, end_byte INTEGER);

     CREATE VIRTUAL TABLE chunk_fts USING fts5(
         content,
         chunk_id UNINDEXED,
         note_id UNINDEXED,
         tokenize = 'porter unicode61'
     );

     CREATE TABLE day_review_blocks (
         note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         block_id      TEXT NOT NULL,
         content_hash  TEXT NOT NULL,
         text          TEXT NOT NULL,
         PRIMARY KEY (note_id, block_id)
     );

     CREATE TABLE day_reviews (
         note_id                   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         content_version           INTEGER NOT NULL DEFAULT 0,
         reviewed_content_version  INTEGER NULL,
         reviewed_at               INTEGER NULL
     );

     CREATE TABLE feedback (
         id                 TEXT PRIMARY KEY,
         kind               TEXT NOT NULL CHECK (kind IN ('comment','correction')),
         source             TEXT NOT NULL CHECK (source IN ('person','chat')),
         note_id            TEXT NULL REFERENCES notes(id) ON DELETE SET NULL,
         day                TEXT NULL,
         agent_change_id    TEXT NULL REFERENCES agent_changes(id) ON DELETE SET NULL,
         text               TEXT NULL,
         correction_json    TEXT NULL,
         status             TEXT NOT NULL CHECK (status IN ('open','handled')),
         reply              TEXT NULL,
         tag_correction_id  INTEGER NULL UNIQUE REFERENCES tag_corrections(id) ON DELETE SET NULL,
         created_at         INTEGER NOT NULL,
         updated_at         INTEGER NOT NULL,
         handled_at         INTEGER NULL
     );

     CREATE TABLE footer_chips (
         daily_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         topic_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         origin         TEXT NOT NULL CHECK (origin IN ('excerpt','person')),
         created_at     INTEGER NOT NULL,
         PRIMARY KEY (daily_note_id, topic_note_id)
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

     CREATE TABLE notes (
         id           TEXT PRIMARY KEY,
         title        TEXT NOT NULL,
         content_md   TEXT NOT NULL,
         frontmatter  TEXT NOT NULL DEFAULT '{}',
         version      INTEGER NOT NULL DEFAULT 1,
         created_at   INTEGER NOT NULL,
         updated_at   INTEGER NOT NULL,
         crdt_state   BLOB
     , has_open_questions INTEGER NOT NULL DEFAULT 0, frontmatter_parse_error INTEGER NOT NULL DEFAULT 0);

     CREATE TABLE notes_dedup_log (
         note_id      TEXT PRIMARY KEY,
         old_title    TEXT NOT NULL,
         new_title    TEXT NOT NULL,
         migrated_at  INTEGER NOT NULL
     );

     CREATE TABLE pending_index (
         note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         enqueued_at INTEGER NOT NULL
     );

     CREATE TABLE schema_version (
         version INTEGER PRIMARY KEY
     );

     CREATE TABLE smart_folder_members (
         smart_folder_id  TEXT NOT NULL REFERENCES smart_folders(id) ON DELETE CASCADE,
         note_id          TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         pinned           INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (smart_folder_id, note_id)
     );

     CREATE TABLE smart_folders (
         id          TEXT PRIMARY KEY,
         name        TEXT NOT NULL,
         parent_id   TEXT NULL REFERENCES smart_folders(id),
         pinned      INTEGER NOT NULL DEFAULT 0,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL
     );

     CREATE TABLE tag_corrections (
         id          INTEGER PRIMARY KEY AUTOINCREMENT,
         note_id     TEXT REFERENCES notes(id) ON DELETE SET NULL,
         note_title  TEXT NOT NULL,
         tag         TEXT NOT NULL,
         kind        TEXT NOT NULL CHECK (kind IN ('removed')),
         created_at  INTEGER NOT NULL,
         cleared_at  INTEGER
     );

     CREATE TABLE tags (
         note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         tag     TEXT NOT NULL, origin TEXT NOT NULL DEFAULT 'person' CHECK (origin IN ('body','agent','person')), first_line TEXT,
         PRIMARY KEY (note_id, tag)
     );

     CREATE TABLE vault_guide_revisions (
         id                TEXT PRIMARY KEY,
         note_id           TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         previous_md       TEXT NOT NULL,
         previous_version  INTEGER NOT NULL,
         new_version       INTEGER NOT NULL,
         agent_change_id   TEXT NULL REFERENCES agent_changes(id) ON DELETE SET NULL,
         created_at        INTEGER NOT NULL
     );

     CREATE TABLE vault_settings (
         key    TEXT PRIMARY KEY,
         value  TEXT NOT NULL
     );

     CREATE INDEX idx_agent_changes_note ON agent_changes(note_id, created_at DESC);
     CREATE INDEX idx_blocks_note_ord ON blocks(note_id, ord);
     CREATE INDEX idx_canvas_nodes_note ON canvas_nodes(note_id);
     CREATE UNIQUE INDEX idx_canvases_title_unique ON canvases(title);
     CREATE INDEX idx_canvases_updated_at ON canvases(updated_at DESC);
     CREATE INDEX idx_chunks_note ON chunks(note_id, ord);
     CREATE INDEX idx_feedback_note ON feedback(note_id, created_at);
     CREATE INDEX idx_feedback_status ON feedback(status, created_at);
     CREATE INDEX idx_footer_chips_topic ON footer_chips(topic_note_id);
     CREATE INDEX idx_links_from ON links(from_note_id);
     CREATE INDEX idx_links_kind ON links(link_kind, to_note_id);
     CREATE INDEX idx_links_to   ON links(to_note_id);
     CREATE UNIQUE INDEX idx_notes_daily_title ON notes(title)
         WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'daily';
     CREATE UNIQUE INDEX idx_notes_guide
         ON notes((CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END))
         WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'guide';
     CREATE UNIQUE INDEX idx_notes_title_unique ON notes(title);
     CREATE INDEX idx_notes_updated_at ON notes(updated_at DESC);
     CREATE INDEX idx_smart_folder_members_note ON smart_folder_members(note_id);
     CREATE UNIQUE INDEX idx_smart_folders_sibling_name
         ON smart_folders(COALESCE(parent_id, ''), name COLLATE NOCASE);
     CREATE INDEX idx_tag_corrections_note ON tag_corrections(note_id, tag);
     CREATE INDEX idx_tags_tag ON tags(tag);
     CREATE INDEX idx_vault_guide_revisions_note
         ON vault_guide_revisions(note_id, created_at DESC);

     INSERT INTO schema_version(version) VALUES (1);
     INSERT INTO schema_version(version) VALUES (2);
     INSERT INTO schema_version(version) VALUES (3);
     INSERT INTO schema_version(version) VALUES (4);
     INSERT INTO schema_version(version) VALUES (5);
     INSERT INTO schema_version(version) VALUES (6);
     INSERT INTO vault_settings(key, value) VALUES ('smart_folder_max_depth', '2');";

/// One or more rows in every V6 table, so "keeps every row" covers them all.
fn v6_rows() -> String {
    format!(
        "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES ('{N_DAILY}', '2026-11-02', 'Standup #work.\n', '{{\"role\":\"daily\"}}',
                     3, 1700000100000, 1700000900000);
         INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES ('{N_TOPIC}', 'Games', '# Games\n\nIdeas for #game-feel.\n',
                     '{{\"role\":\"topic\"}}', 2, 1700000200000, 1700000800000);
         INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at,
                            crdt_state, has_open_questions)
             VALUES ('{N_PLAIN}', 'Plain note', 'Reading list #reading\n', '{{}}', 1,
                     1700000300000, 1700000300000, X'00FF10', 1);
         INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES ('{N_GUIDE}', 'Vault Guide', 'Prefer #game-feel.\n', '{{\"role\":\"guide\"}}',
                     1, 1700000400000, 1700000400000);
         INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES ('{N_QUEUED}', 'Queued', 'Already queued.\n', '{{}}', 1,
                     1700000500000, 1700000500000);
         INSERT INTO pending_index (note_id, enqueued_at) VALUES ('{N_QUEUED}', {QUEUED_AT});
         INSERT INTO chunks (id, note_id, ord, content, token_count, embed_model_version,
                             start_byte, end_byte)
             VALUES ('C-DAILY-0', '{N_DAILY}', 0, 'Standup #work.', 3, 'test-model-1', 0, 14);
         INSERT INTO chunks (id, note_id, ord, content, token_count, embed_model_version,
                             start_byte, end_byte)
             VALUES ('C-TOPIC-0', '{N_TOPIC}', 0, 'Ideas for #game-feel.', 4, NULL, 9, 30);
         INSERT INTO chunk_fts (content, chunk_id, note_id)
             VALUES ('Standup #work.', 'C-DAILY-0', '{N_DAILY}');
         INSERT INTO chunk_fts (content, chunk_id, note_id)
             VALUES ('Ideas for #game-feel.', 'C-TOPIC-0', '{N_TOPIC}');
         INSERT INTO tags (note_id, tag, origin, first_line)
             VALUES ('{N_DAILY}', 'work', 'body', 'Standup #work.');
         INSERT INTO tags (note_id, tag, origin, first_line)
             VALUES ('{N_TOPIC}', 'inbox', 'agent', NULL);
         INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, label, position, source)
             VALUES ('L-1', '{N_PLAIN}', '{N_TOPIC}', 'Games', 'wikilink', NULL, 0, 'inline_body');
         INSERT INTO notes_dedup_log (note_id, old_title, new_title, migrated_at)
             VALUES ('{N_PLAIN}', 'Plain', 'Plain note', 1700000300500);
         INSERT INTO canvases (id, title, created_at, updated_at, version)
             VALUES ('CV-1', 'Board', 1700000600000, 1700000600000, 2);
         INSERT INTO canvas_nodes (canvas_id, note_id, x, y, z_order, placed_at)
             VALUES ('CV-1', '{N_TOPIC}', 12.5, -3.25, 1, 1700000600100);
         INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text, content_hash,
                             source, created_version, created_at)
             VALUES ('{N_DAILY}', 'b1', 0, 0, 14, 'Standup #work.', '0123456789abcdef',
                     'person', 1, 1700000500000);
         INSERT INTO day_reviews (note_id, content_version, reviewed_content_version, reviewed_at)
             VALUES ('{N_DAILY}', 3, 3, 1700000950000);
         INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
             VALUES ('{N_DAILY}', 'b1', '0123456789abcdef', 'Standup #work.');
         INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES ('{N_DAILY}', '{N_TOPIC}', 'excerpt', 1700000900000);
         INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES ('AC-1', '{N_DAILY}', '2026-11-02', 1700000900000, '[\"Filed a block\"]');
         INSERT INTO smart_folders (id, name, parent_id, pinned, created_at, updated_at)
             VALUES ('SF-1', 'Design', NULL, 1, 1700000700000, 1700000700000);
         INSERT INTO smart_folder_members (smart_folder_id, note_id, pinned)
             VALUES ('SF-1', '{N_TOPIC}', 0);
         INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at, cleared_at)
             VALUES ('{N_PLAIN}', 'Plain note', 'reading', 'removed', 1700000710000, NULL);
         INSERT INTO feedback (id, kind, source, note_id, day, agent_change_id, text,
                               correction_json, status, reply, tag_correction_id,
                               created_at, updated_at, handled_at)
             VALUES ('FB-1', 'correction', 'person', '{N_PLAIN}', NULL, 'AC-1', NULL, '{{}}',
                     'open', NULL, 1, 1700000720000, 1700000720000, NULL);
         INSERT INTO vault_guide_revisions (id, note_id, previous_md, previous_version,
                                            new_version, agent_change_id, created_at)
             VALUES ('GR-1', '{N_GUIDE}', 'Old guide.\n', 1, 2, 'AC-1', 1700000730000);"
    )
}

fn open(db_path: &Path) -> Connection {
    let conn = Connection::open(db_path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn
}

/// Build a vault DB pinned at schema V6, one row or more in every table.
fn make_v6_db(dir: &Path) -> PathBuf {
    let db_path = dir.join("memex.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn.execute_batch(V6_DDL).unwrap();
    conn.execute_batch(&v6_rows()).unwrap();
    drop(conn);
    db_path
}

/// Registers sqlite-vec for every later connection in this process: the
/// core does it on the first `Vault::create` or `Vault::open`.
fn register_vec0() {
    let dir = tempfile::tempdir().unwrap();
    Vault::create(dir.path().join("vec0")).expect("create a throwaway vault");
}

/// The V6 fixture plus `chunk_vec` (vec0, dimension 4) holding one vector
/// per chunk and one orphan, so every lazily made `chunk_vec_*` shadow table
/// exists before V7 runs.
fn make_v6_db_with_chunk_vec(dir: &Path) -> PathBuf {
    register_vec0();
    let db_path = make_v6_db(dir);
    let conn = open(&db_path);
    schema::ensure_vector_table(&conn, 4).unwrap();
    conn.execute_batch(
        "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-DAILY-0', '[1,0,0,0]');
         INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-TOPIC-0', '[0,1,0,0]');
         INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-ORPHAN', '[0,0,1,0]');",
    )
    .unwrap();
    let shadows = strings(
        &conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'chunk~_vec~_%' ESCAPE '~'",
    );
    assert!(
        !shadows.is_empty(),
        "fixture: chunk_vec has shadow tables before V7"
    );
    drop(conn);
    db_path
}

/// The V6 fixture after one `schema::apply`, asserted to have reached V7.
fn migrated_v6_fixture() -> (tempfile::TempDir, Connection) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v6_db(dir.path());
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V6 -> V7 migration succeeds");
    assert_eq!(
        schema::current_version(&conn).unwrap(),
        7,
        "schema::apply did not advance the V6 fixture to V7"
    );
    (dir, conn)
}

/// The `chunk_vec` V6 fixture after one `schema::apply`, at V7.
fn migrated_v6_fixture_with_chunk_vec() -> (tempfile::TempDir, Connection) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v6_db_with_chunk_vec(dir.path());
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V6 (with chunk_vec) -> V7 migration succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 7);
    (dir, conn)
}

/// A brand-new vault.
fn fresh_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).expect("create a fresh vault");
    (dir, vault)
}

/// A vault folder (manifest at schema 6, objects dir) around the V6
/// fixture, opened through `Vault::open`, which migrates it.
fn opened_v6_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    make_v6_db(dir.path());
    let manifest = json!({
        "vault_id": "01J9V7MANIFEST000000000000",
        "schema_version": 6,
        "created_at": 1_000i64,
    });
    std::fs::write(
        dir.path().join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    std::fs::create_dir_all(dir.path().join("objects")).unwrap();
    let vault = Vault::open(dir.path()).expect("open V6 vault migrates it");
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

/// `content_revision.n`.
fn revision(conn: &Connection) -> i64 {
    conn.query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
        r.get(0)
    })
    .expect("content_revision has its row")
}

/// Every `content_revision` row as (id, n).
fn revision_rows(conn: &Connection) -> Vec<(i64, i64)> {
    let mut stmt = conn
        .prepare("SELECT id, n FROM content_revision ORDER BY id")
        .unwrap();
    let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    rows.map(|r| r.unwrap()).collect()
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

/// The schema plus every row of every table.
fn full_snapshot(conn: &Connection) -> Vec<String> {
    let mut out = strings(
        conn,
        "SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
         ORDER BY type, name",
    );
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

/// A table that carries no revision triggers (requirement 8, ruling D2):
/// `content_revision` itself, SQLite's own tables, virtual tables and the
/// shadow tables of `chunk_fts` and `chunk_vec`.
fn is_exempt(name: &str, sql: &str) -> bool {
    name == "content_revision"
        || name.starts_with("sqlite_")
        || name.starts_with("chunk_fts_")
        || name.starts_with("chunk_vec_")
        || squash(sql).starts_with("createvirtualtable")
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

/// The trigger-coverage check (Spec #391 requirement 10): every regular,
/// non-exempt table that lacks any of its three revision triggers, by name.
fn tables_missing_revision_triggers(conn: &Connection) -> Vec<String> {
    let mut stmt = conn
        .prepare(
            "SELECT name, COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .unwrap();
    let tables: Vec<(String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    tables
        .into_iter()
        .filter(|(name, sql)| !is_exempt(name, sql))
        .filter(|(name, _)| {
            !TRIGGER_KINDS
                .iter()
                .all(|(suffix, event)| has_revision_trigger(conn, name, suffix, event))
        })
        .map(|(name, _)| name)
        .collect()
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

/// The three trigger names a triggered table must carry.
fn expected_trigger_names(table: &str) -> BTreeSet<String> {
    TRIGGER_KINDS
        .iter()
        .map(|(suffix, _)| format!("content_revision_{table}_{suffix}"))
        .collect()
}

/// (name, declared type, notnull, pk) of one column.
type Column = (String, String, bool, bool);

/// (name, declared type, notnull, pk) of each column, in order.
fn columns(conn: &Connection, table: &str) -> Vec<Column> {
    let mut stmt = conn
        .prepare("SELECT name, type, \"notnull\", pk FROM pragma_table_info(?1) ORDER BY cid")
        .unwrap();
    let rows = stmt
        .query_map([table], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)? != 0,
                r.get::<_, i64>(3)? != 0,
            ))
        })
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn col(name: &str, ty: &str, notnull: bool, pk: bool) -> Column {
    (name.to_string(), ty.to_string(), notnull, pk)
}

/// `pending_index` as (note_id, enqueued_at), by note id.
fn pending(conn: &Connection) -> BTreeMap<String, i64> {
    let mut stmt = conn
        .prepare("SELECT note_id, enqueued_at FROM pending_index")
        .unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn now_ms() -> i64 {
    memex_core::now_unix_ms()
}

// ---- AC 1: a fresh vault at V7 ----------------------------------------------------------------

#[test]
fn app_schema_version_is_7() {
    assert_eq!(schema::APP_SCHEMA_VERSION, 7);
}

#[test]
fn fresh_vault_opens_at_v7_with_the_v7_tables_and_index() {
    let (dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    assert_eq!(vault.schema_version(), 7);
    assert_eq!(schema::current_version(conn).unwrap(), 7);
    let versions = strings(
        conn,
        "SELECT CAST(version AS TEXT) FROM schema_version ORDER BY version",
    );
    assert_eq!(versions, ["1", "2", "3", "4", "5", "6", "7"]);
    for t in V7_TABLES {
        assert_eq!(
            count(
                conn,
                &format!(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '{t}'"
                )
            ),
            1,
            "{t} exists in a fresh vault"
        );
    }
    drop(vault);

    // Reopened, it is still V7 and the manifest says so.
    let vault = Vault::open(dir.path().join("vault")).expect("reopen the fresh vault");
    assert_eq!(vault.schema_version(), 7);
    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(dir.path().join("vault").join("manifest.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["schema_version"].as_i64(), Some(7), "{manifest}");
}

#[test]
fn v7_tables_have_exactly_the_d2_columns() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let cases: [(&str, Vec<Column>); 3] = [
        (
            "agent_activity",
            vec![
                col("id", "TEXT", false, true),
                col("session_id", "TEXT", true, false),
                col("client_name", "TEXT", true, false),
                col("tool", "TEXT", true, false),
                col("summary", "TEXT", true, false),
                col("note_id", "TEXT", false, false),
                col("created_at", "INTEGER", true, false),
            ],
        ),
        (
            "learned_words",
            vec![
                col("word_key", "TEXT", false, true),
                col("word", "TEXT", true, false),
                col("created_at", "INTEGER", true, false),
            ],
        ),
        (
            "content_revision",
            vec![
                col("id", "INTEGER", false, true),
                col("n", "INTEGER", true, false),
            ],
        ),
    ];
    for (table, expected) in cases {
        assert_eq!(columns(conn, table), expected, "{table} columns");
    }
}

#[test]
fn agent_activity_note_id_has_no_foreign_key_and_its_index_orders_created_at_desc() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    for t in ["agent_activity", "learned_words", "content_revision"] {
        assert_eq!(
            count(
                conn,
                &format!("SELECT COUNT(*) FROM pragma_foreign_key_list('{t}')")
            ),
            0,
            "{t} has no foreign key"
        );
    }

    // idx_agent_activity_created: on agent_activity, not unique, not
    // partial, exactly (created_at DESC).
    let (tbl, unique, partial): (String, i64, i64) = conn
        .query_row(
            "SELECT m.tbl_name, l.\"unique\", l.partial
             FROM sqlite_master m JOIN pragma_index_list(m.tbl_name) l ON l.name = m.name
             WHERE m.type = 'index' AND m.name = 'idx_agent_activity_created'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .expect("idx_agent_activity_created exists");
    assert_eq!((tbl.as_str(), unique, partial), ("agent_activity", 0, 0));
    let mut stmt = conn
        .prepare(
            "SELECT name, \"desc\" FROM pragma_index_xinfo('idx_agent_activity_created')
             WHERE key = 1 ORDER BY seqno",
        )
        .unwrap();
    let keys: Vec<(String, bool)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(keys, [("created_at".to_string(), true)]);

    // With no foreign key, an activity row may name a note that is gone.
    conn.execute(
        "INSERT INTO agent_activity (id, session_id, client_name, tool, summary, note_id, created_at)
         VALUES ('A-1', 'S-1', 'Claude', 'create_note', 'Made a note', '01J9V7NOSUCHNOTE000000000X', 1)",
        [],
    )
    .expect("note_id is display-only: no foreign key");
}

#[test]
fn content_revision_holds_the_single_row_1_0_before_any_write() {
    let (dir, vault) = fresh_vault();
    assert_eq!(revision_rows(vault.connection_ref()), [(1, 0)]);
    drop(vault);
    // Reopening writes nothing, so the row is still (1, 0).
    let vault = Vault::open(dir.path().join("vault")).unwrap();
    assert_eq!(revision_rows(vault.connection_ref()), [(1, 0)]);
}

#[test]
fn content_revision_check_allows_only_id_1() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let err = conn
        .execute("INSERT INTO content_revision (id, n) VALUES (2, 0)", [])
        .expect_err("CHECK (id = 1) rejects a second row");
    assert!(err.to_string().contains("CHECK"), "{err}");
    let err = conn
        .execute("INSERT INTO content_revision (id, n) VALUES (1, 5)", [])
        .expect_err("id is the primary key");
    assert!(err.to_string().contains("UNIQUE"), "{err}");
    let err = conn
        .execute("UPDATE content_revision SET n = NULL WHERE id = 1", [])
        .expect_err("n is NOT NULL");
    assert!(err.to_string().contains("NOT NULL"), "{err}");
    assert_eq!(revision_rows(conn), [(1, 0)]);
}

// ---- AC 2: V6 -> V7 keeps every row, in one transaction ----------------------------------------

#[test]
fn v6_fixture_migrates_to_v7_and_keeps_every_row_of_every_v6_table() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v6_db(dir.path());
    let before = all_rows(&open(&db_path));
    for t in V6_REGULAR_TABLES {
        assert!(
            !before[t].is_empty(),
            "fixture: {t} holds a row, so keeping it is checked"
        );
    }
    assert!(!before["chunk_fts"].is_empty());
    assert!(!before["sqlite_sequence"].is_empty());

    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V6 -> V7 migration succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 7);

    let after = all_rows(&conn);
    for (table, rows) in &before {
        match table.as_str() {
            // V7 adds its version row and the rechunk queue; both checked below.
            "schema_version" | "pending_index" => {}
            _ => assert_eq!(&after[table], rows, "{table} rows unchanged by V7"),
        }
    }
    let versions = strings(
        &conn,
        "SELECT CAST(version AS TEXT) FROM schema_version ORDER BY version",
    );
    assert_eq!(versions, ["1", "2", "3", "4", "5", "6", "7"]);
    // The row the queue already held is kept as it was.
    assert_eq!(pending(&conn).get(N_QUEUED), Some(&QUEUED_AT));
    // Only V7's own tables are new.
    let new_tables: BTreeSet<&String> = after.keys().filter(|t| !before.contains_key(*t)).collect();
    assert_eq!(
        new_tables,
        V7_TABLES
            .iter()
            .map(|t| t.to_string())
            .collect::<BTreeSet<_>>()
            .iter()
            .collect()
    );
    assert!(after["agent_activity"].is_empty());
    assert!(after["learned_words"].is_empty());
}

#[test]
fn v6_vault_open_migrates_to_v7_and_rewrites_the_manifest() {
    let (dir, vault) = opened_v6_vault();
    assert_eq!(vault.schema_version(), 7);
    assert_eq!(schema::current_version(vault.connection_ref()).unwrap(), 7);
    let on_disk: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("manifest.json")).unwrap()).unwrap();
    assert_eq!(on_disk["schema_version"].as_i64(), Some(7), "{on_disk}");
    assert_eq!(
        on_disk["vault_id"].as_str(),
        Some("01J9V7MANIFEST000000000000")
    );
    assert_eq!(on_disk["created_at"].as_i64(), Some(1_000));
    assert!(tables_missing_revision_triggers(vault.connection_ref()).is_empty());
}

#[test]
fn a_failing_v7_step_rolls_back_and_leaves_the_vault_at_v6_unchanged() {
    // Four ways for V7 to fail part-way, one per step of the V7 transaction:
    // a leftover `agent_activity` without `created_at` (its index cannot be
    // built), a queue that refuses inserts (the rechunk step), a version table
    // that refuses the version-7 row, and a table whose trigger cannot be
    // created (the trigger step). The last two sit outside `apply_v7`: they
    // prove the version row and the triggers commit together with it.
    let cases = [
        (
            "agent_activity without created_at",
            "CREATE TABLE agent_activity (id TEXT PRIMARY KEY);",
        ),
        (
            "pending_index refuses inserts",
            "CREATE TRIGGER zz_refuse_queue BEFORE INSERT ON pending_index
             BEGIN SELECT RAISE(ABORT, 'queue refused'); END;",
        ),
        (
            "schema_version refuses the version 7 row",
            "CREATE TRIGGER zz_refuse_v7 BEFORE INSERT ON schema_version
             WHEN NEW.version = 7
             BEGIN SELECT RAISE(ABORT, 'version 7 refused'); END;",
        ),
        // The revision trigger DDL fails on this name. If the DDL ever quotes
        // table names, swap in another failing trigger step, not a weaker test.
        ("a trigger step that fails", "CREATE TABLE \"zz-bad\" (x);"),
    ];
    for (what, sabotage) in cases {
        let dir = tempfile::tempdir().unwrap();
        let db_path = make_v6_db(dir.path());
        open(&db_path).execute_batch(sabotage).unwrap();
        let before = full_snapshot(&open(&db_path));

        let mut conn = open(&db_path);
        schema::apply(&mut conn).expect_err(&format!("{what}: V7 must fail"));
        drop(conn);

        let conn = open(&db_path);
        assert_eq!(schema::current_version(&conn).unwrap(), 6, "{what}");
        assert_eq!(
            full_snapshot(&conn),
            before,
            "{what}: the V7 transaction rolled back as a whole"
        );
        for t in ["learned_words", "content_revision"] {
            assert_eq!(
                count(
                    &conn,
                    &format!("SELECT COUNT(*) FROM sqlite_master WHERE name = '{t}'")
                ),
                0,
                "{what}: {t} must not exist after the rollback"
            );
        }
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'
                 AND name LIKE 'content~_revision~_%' ESCAPE '~'"
            ),
            0,
            "{what}: no revision trigger survives the rollback"
        );
    }
}

// ---- AC 3: which tables carry triggers ---------------------------------------------------------

#[test]
fn v6_fixture_with_chunk_vec_gets_three_triggers_on_every_regular_table_and_none_on_exempt_ones() {
    let (_dir, conn) = migrated_v6_fixture_with_chunk_vec();

    let tables = strings(
        &conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    // The exemptions are exercised: each kind of exempt table is present.
    for prefix in ["chunk_fts_", "chunk_vec_", "sqlite_"] {
        assert!(
            tables.iter().any(|t| t.starts_with(prefix)),
            "fixture: a {prefix}* table exists: {tables:?}"
        );
    }

    let triggers = triggers_by_table(&conn);
    for t in &tables {
        let exempt = t == "content_revision"
            || t == "chunk_fts"
            || t == "chunk_vec"
            || t.starts_with("chunk_fts_")
            || t.starts_with("chunk_vec_")
            || t.starts_with("sqlite_");
        if exempt {
            assert!(
                !triggers.contains_key(t),
                "{t} is exempt and must carry no trigger: {:?}",
                triggers.get(t)
            );
        } else {
            assert_eq!(
                triggers.get(t),
                Some(&expected_trigger_names(t)),
                "{t} carries exactly _ai, _au and _ad"
            );
            for (suffix, event) in TRIGGER_KINDS {
                assert!(
                    has_revision_trigger(&conn, t, suffix, event),
                    "content_revision_{t}_{suffix} is AFTER {event} ON {t} and adds one to n"
                );
            }
        }
    }

    // Exactly the V6 regular tables, schema_version included, and V7's two
    // new content tables carry triggers: 22 tables, 66 triggers.
    let mut expected: BTreeSet<String> = V6_REGULAR_TABLES.iter().map(|t| t.to_string()).collect();
    expected.insert("agent_activity".into());
    expected.insert("learned_words".into());
    assert_eq!(triggers.keys().cloned().collect::<BTreeSet<_>>(), expected);
    assert!(triggers.contains_key("schema_version"));
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'"
        ),
        66
    );
}

#[test]
fn fresh_vault_triggers_every_regular_table_and_no_exempt_one() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let triggers = triggers_by_table(conn);
    let mut expected: BTreeSet<String> = V6_REGULAR_TABLES.iter().map(|t| t.to_string()).collect();
    expected.insert("agent_activity".into());
    expected.insert("learned_words".into());
    assert_eq!(triggers.keys().cloned().collect::<BTreeSet<_>>(), expected);
    for (t, names) in &triggers {
        assert_eq!(names, &expected_trigger_names(t), "{t}");
    }
}

// ---- AC 4: n moves one per affected row --------------------------------------------------------

#[test]
fn each_insert_update_and_delete_on_notes_moves_n_by_one_per_row() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    assert_eq!(revision(conn), 0);

    conn.execute_batch(
        "INSERT INTO notes (id, title, content_md, created_at, updated_at)
         VALUES ('N-1', 'One', 'a', 1, 1), ('N-2', 'Two', 'b', 1, 1), ('N-3', 'Three', 'c', 1, 1);",
    )
    .unwrap();
    assert_eq!(revision(conn), 3, "a three-row insert moves n by 3");

    let changed = conn
        .execute(
            "UPDATE notes SET content_md = content_md || '!' WHERE id <> 'N-3'",
            [],
        )
        .unwrap();
    assert_eq!(changed, 2);
    assert_eq!(revision(conn), 5, "a two-row update moves n by 2");

    conn.execute("UPDATE notes SET title = 'Nobody' WHERE id = 'N-404'", [])
        .unwrap();
    assert_eq!(revision(conn), 5, "an update of no row leaves n");

    conn.execute("DELETE FROM notes WHERE id = 'N-1'", [])
        .unwrap();
    assert_eq!(revision(conn), 6, "a one-row delete moves n by 1");

    conn.execute("DELETE FROM notes", []).unwrap();
    assert_eq!(revision(conn), 8, "a two-row delete moves n by 2");
}

#[test]
fn each_insert_update_and_delete_on_agent_activity_moves_n_by_one_per_row() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let base = revision(conn);

    conn.execute_batch(
        "INSERT INTO agent_activity (id, session_id, client_name, tool, summary, note_id, created_at)
         VALUES ('A-1', 'S-1', 'Claude', 'create_note', 'Made a note', NULL, 10),
                ('A-2', 'S-1', 'Claude', 'search', 'Searched', NULL, 20);",
    )
    .unwrap();
    assert_eq!(revision(conn) - base, 2);

    conn.execute(
        "UPDATE agent_activity SET summary = 'Made two notes' WHERE id = 'A-1'",
        [],
    )
    .unwrap();
    assert_eq!(revision(conn) - base, 3);

    // A prune of every row older than a cutoff.
    conn.execute("DELETE FROM agent_activity WHERE created_at < 100", [])
        .unwrap();
    assert_eq!(revision(conn) - base, 5);
}

#[test]
fn each_insert_update_and_delete_on_learned_words_moves_n_by_one_per_row() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let base = revision(conn);

    conn.execute(
        "INSERT INTO learned_words (word_key, word, created_at) VALUES ('memex', 'Memex', 1)",
        [],
    )
    .unwrap();
    assert_eq!(revision(conn) - base, 1);

    conn.execute(
        "INSERT INTO learned_words (word_key, word, created_at) VALUES ('zettel', 'Zettel', 2), ('ulid', 'ULID', 3)",
        [],
    )
    .unwrap();
    assert_eq!(revision(conn) - base, 3);

    conn.execute("UPDATE learned_words SET created_at = created_at + 1", [])
        .unwrap();
    assert_eq!(revision(conn) - base, 6);

    conn.execute("DELETE FROM learned_words WHERE word_key = 'memex'", [])
        .unwrap();
    assert_eq!(revision(conn) - base, 7);
}

#[test]
fn a_note_save_through_core_moves_n() {
    let (_dir, mut vault) = fresh_vault();
    assert_eq!(revision(vault.connection_ref()), 0);
    let note = create_note(
        &mut vault,
        CreateNote {
            title: Some("Player Loop".into()),
            content_md: "Fixed the jump arc.\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let after_create = revision(vault.connection_ref());
    assert!(after_create > 0, "creating a note moves n: {after_create}");

    update_note(
        &mut vault,
        &note.id,
        note.version,
        UpdateNote {
            title: None,
            content_md: Some("Fixed the jump arc twice.\n".into()),
            frontmatter: None,
        },
    )
    .unwrap();
    assert!(
        revision(vault.connection_ref()) > after_create,
        "saving the note again moves n"
    );
}

#[test]
fn every_triggered_table_moves_n_on_insert_update_and_delete() {
    // Table-driven over each V7 content table and a sample of V6 tables:
    // one row in, one row changed, one row out, each +1.
    let cases: [(&str, &str, &str, &str); 4] = [
        (
            "vault_settings",
            "INSERT INTO vault_settings (key, value) VALUES ('k', 'v')",
            "UPDATE vault_settings SET value = 'w' WHERE key = 'k'",
            "DELETE FROM vault_settings WHERE key = 'k'",
        ),
        (
            "canvases",
            "INSERT INTO canvases (id, title, created_at, updated_at) VALUES ('CV', 'Board', 1, 1)",
            "UPDATE canvases SET title = 'Map' WHERE id = 'CV'",
            "DELETE FROM canvases WHERE id = 'CV'",
        ),
        (
            "schema_version",
            "INSERT INTO schema_version (version) VALUES (99)",
            "UPDATE schema_version SET version = 98 WHERE version = 99",
            "DELETE FROM schema_version WHERE version = 98",
        ),
        (
            "learned_words",
            "INSERT INTO learned_words (word_key, word, created_at) VALUES ('k', 'K', 1)",
            "UPDATE learned_words SET word = 'k' WHERE word_key = 'k'",
            "DELETE FROM learned_words WHERE word_key = 'k'",
        ),
    ];
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    for (table, insert, update, delete) in cases {
        for (what, sql) in [("insert", insert), ("update", update), ("delete", delete)] {
            let before = revision(conn);
            assert_eq!(conn.execute(sql, []).unwrap(), 1, "{table} {what}");
            assert_eq!(revision(conn), before + 1, "{table} {what} moves n by 1");
        }
    }
}

// ---- AC 5: vector-only writes leave n -----------------------------------------------------------

#[test]
fn chunk_vec_insert_and_orphan_delete_leave_n_unchanged_on_a_migrated_v6_vault() {
    let (_dir, conn) = migrated_v6_fixture_with_chunk_vec();
    let n = revision(&conn);

    conn.execute(
        "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-NEW', '[0,0,0,1]')",
        [],
    )
    .unwrap();
    assert_eq!(revision(&conn), n, "a chunk_vec insert leaves n");

    let gone = conn
        .execute(
            "DELETE FROM chunk_vec WHERE chunk_id NOT IN (SELECT id FROM chunks)",
            [],
        )
        .unwrap();
    assert_eq!(gone, 2, "C-ORPHAN and C-NEW are orphans");
    assert_eq!(revision(&conn), n, "a chunk_vec orphan delete leaves n");

    // Only the two real chunks keep their vectors.
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM chunk_vec"), 2);
}

#[test]
fn chunk_vec_made_after_v7_takes_no_triggers_on_reopen_and_its_writes_leave_n() {
    register_vec0();
    let (dir, vault) = fresh_vault();
    schema::ensure_vector_table(vault.connection_ref(), 4).unwrap();
    vault
        .connection_ref()
        .execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-A', '[1,0,0,0]')",
            [],
        )
        .unwrap();
    drop(vault);

    let vault = Vault::open(dir.path().join("vault")).unwrap();
    let conn = vault.connection_ref();
    let n = revision(conn);
    conn.execute(
        "INSERT INTO chunk_vec (chunk_id, embedding) VALUES ('C-B', '[0,1,0,0]')",
        [],
    )
    .unwrap();
    conn.execute("DELETE FROM chunk_vec WHERE chunk_id = 'C-A'", [])
        .unwrap();
    assert_eq!(revision(conn), n, "vector-only writes never move n");
    let on_vec = count(
        conn,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'
         AND (tbl_name LIKE 'chunk~_vec%' ESCAPE '~' OR tbl_name LIKE 'chunk~_fts%' ESCAPE '~')",
    );
    assert_eq!(on_vec, 0);
    assert!(tables_missing_revision_triggers(conn).is_empty());
}

// ---- AC 6: an existing learned word ------------------------------------------------------------

#[test]
fn learned_words_on_conflict_do_nothing_of_an_existing_word_leaves_n() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let add = "INSERT INTO learned_words (word_key, word, created_at) VALUES (?1, ?2, ?3)
               ON CONFLICT(word_key) DO NOTHING";

    let base = revision(conn);
    assert_eq!(conn.execute(add, params!["memex", "Memex", 1]).unwrap(), 1);
    assert_eq!(revision(conn), base + 1, "a new word moves n by 1");

    assert_eq!(conn.execute(add, params!["memex", "MEMEX", 2]).unwrap(), 0);
    assert_eq!(revision(conn), base + 1, "an existing word leaves n");
    let word: String = conn
        .query_row(
            "SELECT word FROM learned_words WHERE word_key = 'memex'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(word, "Memex", "the existing row is kept");

    // The bare form, without a conflict target, behaves the same.
    let bare = "INSERT INTO learned_words (word_key, word, created_at) VALUES ('memex', 'm', 3)
                ON CONFLICT DO NOTHING";
    assert_eq!(conn.execute(bare, []).unwrap(), 0);
    assert_eq!(revision(conn), base + 1);
}

// ---- AC 7: the rechunk queue -------------------------------------------------------------------

#[test]
fn v6_to_v7_queues_every_note_in_pending_index() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v6_db(dir.path());
    let mut conn = open(&db_path);
    assert_eq!(pending(&conn).len(), 1, "fixture: one note already queued");

    let start = now_ms();
    schema::apply(&mut conn).expect("V6 -> V7 migration succeeds");
    let end = now_ms();

    let queue = pending(&conn);
    assert_eq!(
        queue.keys().map(String::as_str).collect::<BTreeSet<_>>(),
        FIXTURE_NOTES.iter().copied().collect::<BTreeSet<_>>(),
        "every note is queued once"
    );
    for (id, at) in &queue {
        if id == N_QUEUED {
            assert_eq!(*at, QUEUED_AT, "an already queued note keeps its row");
        } else {
            assert!(
                (start..=end).contains(at),
                "{id} is queued at the migration time in unix ms: {at} not in {start}..={end}"
            );
        }
    }
}

#[test]
fn a_fresh_vault_queues_no_note() {
    let (_dir, vault) = fresh_vault();
    assert_eq!(vault.schema_version(), 7, "the fresh vault ran V7");
    assert!(pending(vault.connection_ref()).is_empty());

    // V7's queue step is one-time: a note written after V7 is not queued by
    // a later apply, on a vault `Vault::create` made or on a bare file.
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("bare.db");
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("a bare database reaches V7");
    assert_eq!(schema::current_version(&conn).unwrap(), 7);
    assert!(
        pending(&conn).is_empty(),
        "a bare fresh database queues no note"
    );
    conn.execute(
        "INSERT INTO notes (id, title, content_md, created_at, updated_at)
         VALUES ('N-LATE', 'Late', 'a', 1, 1)",
        [],
    )
    .unwrap();
    schema::apply(&mut conn).unwrap();
    assert!(pending(&conn).is_empty(), "a later apply queues nothing");
}

#[test]
fn a_drained_queue_stays_empty_on_reopen() {
    // The rechunk is one-time: V7 does not run again once applied. (Runs
    // `schema::apply` only: `Vault::open` drains the queue itself, D3.)
    let (_dir, mut conn) = migrated_v6_fixture();
    assert_eq!(
        pending(&conn).len(),
        FIXTURE_NOTES.len(),
        "the V7 step queued every note"
    );
    conn.execute("DELETE FROM pending_index", []).unwrap();
    for _ in 0..2 {
        schema::apply(&mut conn).unwrap();
        assert!(pending(&conn).is_empty(), "nothing is queued again");
    }
}

// ---- AC 8: trigger coverage (requirement 10) ----------------------------------------------------

#[test]
fn trigger_coverage_check_passes_on_migrated_and_fresh_vaults() {
    let (_d1, migrated) = migrated_v6_fixture();
    assert_eq!(
        tables_missing_revision_triggers(&migrated),
        Vec::<String>::new()
    );

    let (_d2, with_vec) = migrated_v6_fixture_with_chunk_vec();
    assert_eq!(
        tables_missing_revision_triggers(&with_vec),
        Vec::<String>::new()
    );

    let (_d3, fresh) = fresh_vault();
    assert_eq!(
        tables_missing_revision_triggers(fresh.connection_ref()),
        Vec::<String>::new()
    );
}

#[test]
fn trigger_coverage_check_fails_on_a_table_without_triggers() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    conn.execute_batch("CREATE TABLE zz_later (id TEXT PRIMARY KEY);")
        .unwrap();
    assert_eq!(tables_missing_revision_triggers(conn), ["zz_later"]);

    // Two of three is not enough.
    conn.execute_batch(
        "CREATE TRIGGER content_revision_zz_later_ai AFTER INSERT ON zz_later
             BEGIN UPDATE content_revision SET n = n + 1 WHERE id = 1; END;
         CREATE TRIGGER content_revision_zz_later_au AFTER UPDATE ON zz_later
             BEGIN UPDATE content_revision SET n = n + 1 WHERE id = 1; END;",
    )
    .unwrap();
    assert_eq!(tables_missing_revision_triggers(conn), ["zz_later"]);

    // A trigger with the right name but the wrong event does not count.
    conn.execute_batch(
        "CREATE TRIGGER content_revision_zz_later_ad AFTER INSERT ON zz_later
             BEGIN UPDATE content_revision SET n = n + 1 WHERE id = 1; END;",
    )
    .unwrap();
    assert_eq!(tables_missing_revision_triggers(conn), ["zz_later"]);

    conn.execute_batch(
        "DROP TRIGGER content_revision_zz_later_ad;
         CREATE TRIGGER content_revision_zz_later_ad AFTER DELETE ON zz_later
             BEGIN UPDATE content_revision SET n = n + 1 WHERE id = 1; END;",
    )
    .unwrap();
    assert_eq!(tables_missing_revision_triggers(conn), Vec::<String>::new());

    // An exempt-looking name is still exempt; a regular one is not.
    conn.execute_batch(
        "CREATE TABLE chunk_vec_extra (x);
         CREATE TABLE chunk_fts_extra (x);
         CREATE TABLE chunkyfts (x);",
    )
    .unwrap();
    assert_eq!(tables_missing_revision_triggers(conn), ["chunkyfts"]);
}

#[test]
fn trigger_coverage_check_lists_a_v6_table_left_without_its_triggers() {
    let (_dir, conn) = migrated_v6_fixture();
    conn.execute_batch("DROP TRIGGER content_revision_tags_au;")
        .unwrap();
    assert_eq!(tables_missing_revision_triggers(&conn), ["tags"]);
}

// ---- AC 9: idempotent --------------------------------------------------------------------------

#[test]
fn a_second_apply_creates_no_duplicate_triggers_and_keeps_n() {
    let (_dir, mut conn) = migrated_v6_fixture();
    conn.execute(
        "INSERT INTO learned_words (word_key, word, created_at) VALUES ('memex', 'Memex', 1)",
        [],
    )
    .unwrap();
    let n = revision(&conn);
    assert!(n > 0);
    let triggers = triggers_by_table(&conn);
    let before = full_snapshot(&conn);

    schema::apply(&mut conn).expect("second apply on a V7 database succeeds");

    assert_eq!(triggers_by_table(&conn), triggers);
    assert_eq!(
        revision(&conn),
        n,
        "a second apply does not reset or move n"
    );
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM schema_version WHERE version = 7"
        ),
        1
    );
    assert_eq!(full_snapshot(&conn), before);
}

#[test]
fn reopening_a_vault_creates_no_duplicate_triggers_and_keeps_n() {
    let (dir, vault) = fresh_vault();
    vault
        .connection_ref()
        .execute(
            "INSERT INTO vault_settings (key, value) VALUES ('k', 'v')",
            [],
        )
        .unwrap();
    let n = revision(vault.connection_ref());
    assert_eq!(n, 1);
    let triggers = triggers_by_table(vault.connection_ref());
    drop(vault);

    for _ in 0..2 {
        let vault = Vault::open(dir.path().join("vault")).unwrap();
        assert_eq!(triggers_by_table(vault.connection_ref()), triggers);
        assert_eq!(revision(vault.connection_ref()), n);
    }
}

#[test]
fn rerunning_v7_after_a_lost_version_row_keeps_n_and_adds_no_trigger() {
    // The V7 step itself is idempotent: IF NOT EXISTS DDL and triggers, and
    // INSERT OR IGNORE for the counter row and the queue.
    let (_dir, mut conn) = migrated_v6_fixture();
    conn.execute(
        "INSERT INTO learned_words (word_key, word, created_at) VALUES ('memex', 'Memex', 1)",
        [],
    )
    .unwrap();
    let triggers = triggers_by_table(&conn);
    let queue = pending(&conn);

    conn.execute("DELETE FROM schema_version WHERE version = 7", [])
        .unwrap();
    let n = revision(&conn);
    assert!(n > 1, "the counter has moved before the re-run: {n}");
    assert_eq!(schema::current_version(&conn).unwrap(), 6);

    schema::apply(&mut conn).expect("re-running V7 over V7 tables succeeds");

    assert_eq!(schema::current_version(&conn).unwrap(), 7);
    assert_eq!(triggers_by_table(&conn), triggers);
    assert_eq!(
        revision(&conn),
        n + 1,
        "the counter row is never reset: the re-run only adds the version row's own bump"
    );
    assert_eq!(revision_rows(&conn).len(), 1);
    assert_eq!(pending(&conn), queue, "queued rows keep their stamps");
    assert_eq!(
        table_rows(&conn, "learned_words"),
        ["text:\"memex\" | text:\"Memex\" | int:1"]
    );
}
