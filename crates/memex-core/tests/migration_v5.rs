//! V5 migration tests (WI #3, Spec #1). V5 adds the daily-note, review and
//! Smart Folder storage (`blocks`, `day_reviews`, `day_review_blocks`,
//! `footer_chips`, `agent_changes`, `smart_folders`, `smart_folder_members`,
//! `vault_settings`), byte-range columns on `chunks`, and the partial unique
//! index `idx_notes_daily_title`.
//!
//! The V4 fixture is built inline (same pattern as `migration_v4.rs`) and pinned
//! at `schema_version` 4 so V5 has work to do on the next `schema::apply()`.

use memex_core::schema;
use memex_core::Vault;
use rusqlite::{params, Connection};

// ---- fixture ----------------------------------------------------------------------------------

const N_PLAIN: &str = "01J9V5PLAIN000000000000000";
const N_AGENT: &str = "01J9V5AGENT000000000000000";
const N_BROKEN: &str = "01J9V5BROKEN00000000000000";
const N_ISO: &str = "01J9V5ISO00000000000000000";
const N_DAILY: &str = "01J9V5DAILY000000000000000";
const N_TOPIC: &str = "01J9V5TOPIC000000000000000";

/// Every V5 table and nothing else.
const V5_TABLES: [&str; 8] = [
    "agent_changes",
    "blocks",
    "day_review_blocks",
    "day_reviews",
    "footer_chips",
    "smart_folder_members",
    "smart_folders",
    "vault_settings",
];

/// The complete V4 schema (v1..v4 as shipped), pinned at version 4.
const V4_DDL: &str = "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);

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
         embed_model_version TEXT
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

     INSERT INTO schema_version(version) VALUES (1);
     INSERT INTO schema_version(version) VALUES (2);
     INSERT INTO schema_version(version) VALUES (3);
     INSERT INTO schema_version(version) VALUES (4);";

/// (id, title, content_md, frontmatter, version, created_at, updated_at,
///  has_open_questions, frontmatter_parse_error)
type FixtureNote = (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    i64,
    i64,
    i64,
    i64,
    i64,
);

/// One key column of an index: (column name, or None for an expression; DESC).
type IndexKey = (Option<String>, bool);

/// Build a vault DB pinned at schema V4 with representative notes:
/// `{}` frontmatter, agent frontmatter, malformed `not json` frontmatter,
/// a role-less ISO-titled note, a `role: daily` note, a topic, chunks
/// (with FTS rows), tags, a link and a canvas placement.
fn make_v4_db() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("memex.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn.execute_batch(V4_DDL).unwrap();

    let notes: [FixtureNote; 6] = [
        (
            N_PLAIN,
            "Plain note",
            "# Plain note\n\nFirst paragraph.\n\nSecond paragraph.\n",
            "{}",
            3,
            1_700_000_000_000,
            1_700_000_100_000,
            0,
            0,
        ),
        (
            N_AGENT,
            "Agent summary",
            "Written by an agent.\n",
            r#"{"source":"agent","agent":"claude-code","created_by":"mcp"}"#,
            1,
            1_700_000_200_000,
            1_700_000_200_000,
            0,
            0,
        ),
        (
            N_BROKEN,
            "Broken frontmatter",
            "---\nnot: [valid\n---\nbody\n",
            "not json",
            2,
            1_700_000_300_000,
            1_700_000_350_000,
            0,
            1,
        ),
        (
            N_ISO,
            "2026-09-05",
            "Role-less page with an ISO date title.\n",
            "{}",
            1,
            1_700_000_400_000,
            1_700_000_400_000,
            0,
            0,
        ),
        (
            N_DAILY,
            "2026-09-04",
            "Daily page.\n",
            r#"{"role":"daily"}"#,
            4,
            1_700_000_500_000,
            1_700_000_900_000,
            1,
            0,
        ),
        (
            N_TOPIC,
            "Games",
            "A topic.\n",
            r#"{"role":"topic"}"#,
            1,
            1_700_000_600_000,
            1_700_000_600_000,
            0,
            0,
        ),
    ];
    for (id, title, body, fm, version, created, updated, hoq, fpe) in notes {
        conn.execute(
            "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at,
                                updated_at, has_open_questions, frontmatter_parse_error)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![id, title, body, fm, version, created, updated, hoq, fpe],
        )
        .unwrap();
    }

    let chunks = [
        ("C-PLAIN-0", N_PLAIN, 0, "# Plain note First paragraph.", 5),
        ("C-PLAIN-1", N_PLAIN, 1, "Second paragraph.", 2),
        ("C-AGENT-0", N_AGENT, 0, "Written by an agent.", 4),
        ("C-DAILY-0", N_DAILY, 0, "Daily page.", 2),
    ];
    for (id, note, ord, content, tokens) in chunks {
        conn.execute(
            "INSERT INTO chunks (id, note_id, ord, content, token_count, embed_model_version)
             VALUES (?, ?, ?, ?, ?, 'test-model-1')",
            params![id, note, ord, content, tokens],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chunk_fts (content, chunk_id, note_id) VALUES (?, ?, ?)",
            params![content, id, note],
        )
        .unwrap();
    }

    conn.execute_batch(&format!(
        "INSERT INTO tags (note_id, tag) VALUES ('{N_PLAIN}', 'reading');
         INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, label, position, source)
             VALUES ('L-1', '{N_PLAIN}', '{N_AGENT}', 'Agent summary', 'wikilink', NULL, 0, 'inline_body');
         INSERT INTO canvases (id, title, created_at, updated_at, version)
             VALUES ('CV-1', 'Board', 1700000000000, 1700000000000, 1);
         INSERT INTO canvas_nodes (canvas_id, note_id, x, y, z_order, placed_at)
             VALUES ('CV-1', '{N_PLAIN}', 1.5, 2.5, 0, 1700000000000);"
    ))
    .unwrap();

    drop(conn);
    (dir, db_path)
}

fn open(db_path: &std::path::Path) -> Connection {
    let conn = Connection::open(db_path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn
}

/// The V4 fixture after one `schema::apply`, asserted to have reached V5.
fn migrated_v4_fixture() -> (tempfile::TempDir, Connection) {
    let (dir, db_path) = make_v4_db();
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V4 -> V5 migration succeeds");
    assert_eq!(
        schema::current_version(&conn).unwrap(),
        5,
        "schema::apply did not advance the V4 fixture to V5"
    );
    (dir, conn)
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

/// Full rows of the pre-existing data, serialised so before/after can be compared.
fn notes_snapshot(conn: &Connection) -> Vec<String> {
    strings(
        conn,
        "SELECT json_array(id, title, content_md, frontmatter, version, created_at, updated_at,
                           has_open_questions, frontmatter_parse_error)
         FROM notes ORDER BY id",
    )
}

fn chunks_snapshot(conn: &Connection) -> Vec<String> {
    strings(
        conn,
        "SELECT json_array(id, note_id, ord, content, token_count, embed_model_version)
         FROM chunks ORDER BY id",
    )
}

fn other_v4_data_snapshot(conn: &Connection) -> Vec<String> {
    let mut out = strings(
        conn,
        "SELECT json_array(chunk_id, note_id, content) FROM chunk_fts ORDER BY chunk_id",
    );
    out.extend(strings(
        conn,
        "SELECT json_array(note_id, tag) FROM tags ORDER BY note_id, tag",
    ));
    out.extend(strings(
        conn,
        "SELECT json_array(id, from_note_id, to_note_id, link_text, link_kind, position, source)
         FROM links ORDER BY id",
    ));
    out.extend(strings(
        conn,
        "SELECT json_array(canvas_id, note_id, x, y, z_order, placed_at)
         FROM canvas_nodes ORDER BY canvas_id, note_id",
    ));
    out
}

/// Row count of every table in the database (including FTS and its shadow tables).
fn table_counts(conn: &Connection) -> Vec<(String, i64)> {
    let tables = strings(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite%'
         ORDER BY name",
    );
    tables
        .into_iter()
        .map(|t| {
            let n = count(conn, &format!("SELECT COUNT(*) FROM \"{t}\""));
            (t, n)
        })
        .collect()
}

fn schema_snapshot(conn: &Connection) -> Vec<String> {
    strings(
        conn,
        "SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
         ORDER BY type, name",
    )
}

fn expect_err(res: rusqlite::Result<usize>, needle: &str, what: &str) {
    match res {
        Ok(_) => panic!("{what}: expected an error containing {needle:?}, but the write succeeded"),
        Err(e) => assert!(
            e.to_string().contains(needle),
            "{what}: expected an error containing {needle:?}, got: {e}"
        ),
    }
}

fn expect_ok(res: rusqlite::Result<usize>, what: &str) {
    if let Err(e) = res {
        panic!("{what}: expected the write to succeed, got: {e}");
    }
}

fn insert_note(conn: &Connection, id: &str, title: &str, fm: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO notes (id, title, content_md, frontmatter, created_at, updated_at)
         VALUES (?, ?, '', ?, 1, 1)",
        params![id, title, fm],
    )
}

fn insert_block(
    conn: &Connection,
    note: &str,
    block_id: &str,
    ord: i64,
    source: &str,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text, content_hash,
                             source, created_version, created_at)
         VALUES (?, ?, ?, 0, 5, 'hello', '0123456789abcdef', ?, 1, 1700000000000)",
        params![note, block_id, ord, source],
    )
}

fn insert_chip(
    conn: &Connection,
    daily: &str,
    topic: &str,
    origin: &str,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
         VALUES (?, ?, ?, 1700000000000)",
        params![daily, topic, origin],
    )
}

fn insert_folder(
    conn: &Connection,
    id: &str,
    name: &str,
    parent: Option<&str>,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO smart_folders (id, name, parent_id, created_at, updated_at)
         VALUES (?, ?, ?, 1700000000000, 1700000000000)",
        params![id, name, parent],
    )
}

fn insert_member(conn: &Connection, folder: &str, note: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO smart_folder_members (smart_folder_id, note_id) VALUES (?, ?)",
        params![folder, note],
    )
}

// ---- column expectations ----------------------------------------------------------------------

/// Expected column: name, declared type, NOT NULL (None = either is acceptable,
/// used only for single-column TEXT primary keys), default value, pk ordinal.
type ColSpec = (
    &'static str,
    &'static str,
    Option<bool>,
    Option<&'static str>,
    i64,
);

#[derive(Debug)]
struct ActualCol {
    name: String,
    ty: String,
    notnull: bool,
    dflt: Option<String>,
    pk: i64,
}

fn actual_columns(conn: &Connection, table: &str) -> Vec<ActualCol> {
    let mut stmt = conn
        .prepare(
            "SELECT name, upper(type), \"notnull\", dflt_value, pk
             FROM pragma_table_info(?1) ORDER BY name",
        )
        .unwrap();
    let rows = stmt
        .query_map([table], |r| {
            Ok(ActualCol {
                name: r.get(0)?,
                ty: r.get(1)?,
                notnull: r.get::<_, i64>(2)? != 0,
                dflt: r.get(3)?,
                pk: r.get(4)?,
            })
        })
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn assert_columns(conn: &Connection, table: &str, expected: &[ColSpec]) {
    let actual = actual_columns(conn, table);
    assert!(!actual.is_empty(), "table {table} does not exist");
    let mut actual_names: Vec<&str> = actual.iter().map(|c| c.name.as_str()).collect();
    actual_names.sort();
    let mut expected_names: Vec<&str> = expected.iter().map(|c| c.0).collect();
    expected_names.sort();
    assert_eq!(
        actual_names, expected_names,
        "{table}: column set differs from the Spec"
    );
    for (name, ty, notnull, dflt, pk) in expected {
        let col = actual.iter().find(|c| c.name == *name).unwrap();
        assert_eq!(col.ty, *ty, "{table}.{name}: declared type");
        if let Some(nn) = notnull {
            assert_eq!(col.notnull, *nn, "{table}.{name}: NOT NULL");
        }
        assert_eq!(col.dflt.as_deref(), *dflt, "{table}.{name}: default value");
        assert_eq!(col.pk, *pk, "{table}.{name}: primary-key position");
    }
}

// ---- AC 1: version ----------------------------------------------------------------------------

#[test]
fn app_schema_version_is_5() {
    assert_eq!(schema::APP_SCHEMA_VERSION, 5);
}

#[test]
fn v5_apply_advances_v4_database_to_version_5() {
    let (_dir, db_path) = make_v4_db();
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V4 -> V5 migration succeeds");

    let max: i64 = count(&conn, "SELECT MAX(version) FROM schema_version");
    assert_eq!(max, 5);
    let versions = strings(
        &conn,
        "SELECT CAST(version AS TEXT) FROM schema_version ORDER BY version",
    );
    assert_eq!(versions, ["1", "2", "3", "4", "5"]);
}

#[test]
fn v5_vault_open_rewrites_v4_manifest_to_5() {
    let (dir, _db_path) = make_v4_db();
    let vault_id = "01J9V5MANIFEST000000000000";
    let manifest = serde_json::json!({
        "vault_id": vault_id,
        "schema_version": 4,
        "created_at": 1_000i64,
    });
    let manifest_path = dir.path().join("manifest.json");
    std::fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    std::fs::create_dir_all(dir.path().join("objects")).unwrap();

    let vault = Vault::open(dir.path()).expect("open V4 vault advances to V5");
    assert_eq!(vault.schema_version(), 5);
    assert_eq!(schema::current_version(vault.connection_ref()).unwrap(), 5);

    let on_disk: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    assert_eq!(on_disk["schema_version"].as_i64(), Some(5), "{on_disk}");
    assert_eq!(on_disk["vault_id"].as_str(), Some(vault_id), "{on_disk}");
    assert_eq!(on_disk["created_at"].as_i64(), Some(1_000), "{on_disk}");
}

// ---- AC 2: pre-existing data intact -----------------------------------------------------------

#[test]
fn v5_migration_preserves_existing_notes_chunks_and_links() {
    let (_dir, db_path) = make_v4_db();
    let (notes_before, chunks_before, other_before) = {
        let conn = open(&db_path);
        (
            notes_snapshot(&conn),
            chunks_snapshot(&conn),
            other_v4_data_snapshot(&conn),
        )
    };
    assert_eq!(notes_before.len(), 6);
    assert_eq!(chunks_before.len(), 4);

    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V4 -> V5 migration succeeds despite `not json` frontmatter");
    assert_eq!(schema::current_version(&conn).unwrap(), 5);

    assert_eq!(notes_snapshot(&conn), notes_before, "notes rows changed");
    assert_eq!(chunks_snapshot(&conn), chunks_before, "chunks rows changed");
    assert_eq!(
        other_v4_data_snapshot(&conn),
        other_before,
        "fts/tags/links/canvas rows changed"
    );

    // Spot-check the edge-case notes by value, not just by snapshot equality.
    let broken_fm: String = conn
        .query_row(
            "SELECT frontmatter FROM notes WHERE id = ?",
            [N_BROKEN],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(broken_fm, "not json");
    let iso: (String, String) = conn
        .query_row(
            "SELECT title, frontmatter FROM notes WHERE id = ?",
            [N_ISO],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(iso, ("2026-09-05".to_string(), "{}".to_string()));
    let agent_fm: String = conn
        .query_row(
            "SELECT frontmatter FROM notes WHERE id = ?",
            [N_AGENT],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        agent_fm,
        r#"{"source":"agent","agent":"claude-code","created_by":"mcp"}"#
    );
    let daily_version: (i64, i64, i64) = conn
        .query_row(
            "SELECT version, created_at, updated_at FROM notes WHERE id = ?",
            [N_DAILY],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(daily_version, (4, 1_700_000_500_000, 1_700_000_900_000));
}

#[test]
fn v5_migration_does_not_backfill_blocks_or_day_reviews() {
    let (_dir, conn) = migrated_v4_fixture();
    for table in V5_TABLES {
        let n = count(&conn, &format!("SELECT COUNT(*) FROM {table}"));
        let expected = if table == "vault_settings" { 1 } else { 0 };
        assert_eq!(n, expected, "{table} row count right after migration");
    }
}

// ---- AC 3: tables, columns, CHECK constraints -------------------------------------------------

#[test]
fn v5_creates_exactly_the_specified_tables() {
    let (_dir, conn) = migrated_v4_fixture();
    let tables = strings(
        &conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    for t in V5_TABLES {
        assert!(
            tables.iter().any(|x| x == t),
            "missing table {t}: {tables:?}"
        );
    }
}

#[test]
fn v5_tables_have_exactly_the_specified_columns() {
    let (_dir, conn) = migrated_v4_fixture();
    let nn = Some(true);
    let null = Some(false);
    let any = None;

    assert_columns(
        &conn,
        "blocks",
        &[
            ("note_id", "TEXT", nn, None, 1),
            ("block_id", "TEXT", nn, None, 2),
            ("ord", "INTEGER", nn, None, 0),
            ("start_byte", "INTEGER", nn, None, 0),
            ("end_byte", "INTEGER", nn, None, 0),
            ("text", "TEXT", nn, None, 0),
            ("content_hash", "TEXT", nn, None, 0),
            ("source", "TEXT", nn, None, 0),
            ("created_version", "INTEGER", nn, None, 0),
            ("created_at", "INTEGER", nn, None, 0),
        ],
    );
    assert_columns(
        &conn,
        "day_reviews",
        &[
            ("note_id", "TEXT", any, None, 1),
            ("content_version", "INTEGER", nn, Some("0"), 0),
            ("reviewed_content_version", "INTEGER", null, None, 0),
            ("reviewed_at", "INTEGER", null, None, 0),
        ],
    );
    assert_columns(
        &conn,
        "day_review_blocks",
        &[
            ("note_id", "TEXT", nn, None, 1),
            ("block_id", "TEXT", nn, None, 2),
            ("content_hash", "TEXT", nn, None, 0),
            ("text", "TEXT", nn, None, 0),
        ],
    );
    assert_columns(
        &conn,
        "footer_chips",
        &[
            ("daily_note_id", "TEXT", nn, None, 1),
            ("topic_note_id", "TEXT", nn, None, 2),
            ("origin", "TEXT", nn, None, 0),
            ("created_at", "INTEGER", nn, None, 0),
        ],
    );
    assert_columns(
        &conn,
        "agent_changes",
        &[
            ("id", "TEXT", any, None, 1),
            ("note_id", "TEXT", nn, None, 0),
            ("day", "TEXT", nn, None, 0),
            ("created_at", "INTEGER", nn, None, 0),
            ("bullets_json", "TEXT", nn, None, 0),
        ],
    );
    assert_columns(
        &conn,
        "smart_folders",
        &[
            ("id", "TEXT", any, None, 1),
            ("name", "TEXT", nn, None, 0),
            ("parent_id", "TEXT", null, None, 0),
            ("pinned", "INTEGER", nn, Some("0"), 0),
            ("created_at", "INTEGER", nn, None, 0),
            ("updated_at", "INTEGER", nn, None, 0),
        ],
    );
    assert_columns(
        &conn,
        "smart_folder_members",
        &[
            ("smart_folder_id", "TEXT", nn, None, 1),
            ("note_id", "TEXT", nn, None, 2),
            ("pinned", "INTEGER", nn, Some("0"), 0),
        ],
    );
    assert_columns(
        &conn,
        "vault_settings",
        &[
            ("key", "TEXT", any, None, 1),
            ("value", "TEXT", nn, None, 0),
        ],
    );
}

#[test]
fn v5_creates_the_specified_secondary_indexes() {
    let (_dir, conn) = migrated_v4_fixture();

    // (table, unique, [(column, desc)]) for every explicitly created (origin 'c') index.
    let explicit = |table: &str| -> Vec<(bool, Vec<IndexKey>)> {
        let names = {
            let mut stmt = conn
                .prepare("SELECT name, \"unique\" FROM pragma_index_list(?1) WHERE origin = 'c'")
                .unwrap();
            let rows = stmt
                .query_map([table], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                })
                .unwrap();
            rows.map(|r| r.unwrap()).collect::<Vec<_>>()
        };
        names
            .into_iter()
            .map(|(name, unique)| {
                let mut stmt = conn
                    .prepare(
                        "SELECT name, \"desc\" FROM pragma_index_xinfo(?1)
                         WHERE key = 1 ORDER BY seqno",
                    )
                    .unwrap();
                let cols = stmt
                    .query_map([&name], |r| {
                        Ok((r.get::<_, Option<String>>(0)?, r.get::<_, i64>(1)? != 0))
                    })
                    .unwrap()
                    .map(|r| r.unwrap())
                    .collect();
                (unique != 0, cols)
            })
            .collect()
    };
    let col = |c: &str, desc: bool| (Some(c.to_string()), desc);

    let blocks = explicit("blocks");
    assert!(
        blocks
            .iter()
            .any(|(_, cols)| *cols == vec![col("note_id", false), col("ord", false)]),
        "blocks needs an index on (note_id, ord): {blocks:?}"
    );

    let chips = explicit("footer_chips");
    assert!(
        chips
            .iter()
            .any(|(_, cols)| *cols == vec![col("topic_note_id", false)]),
        "footer_chips needs an index on topic_note_id: {chips:?}"
    );

    let changes = explicit("agent_changes");
    assert!(
        changes
            .iter()
            .any(|(_, cols)| *cols == vec![col("note_id", false), col("created_at", true)]),
        "agent_changes needs an index on (note_id, created_at DESC): {changes:?}"
    );

    let members = explicit("smart_folder_members");
    assert!(
        members
            .iter()
            .any(|(_, cols)| *cols == vec![col("note_id", false)]),
        "smart_folder_members needs an index on note_id: {members:?}"
    );

    // smart_folders: a UNIQUE expression index on (COALESCE(parent_id,''), name COLLATE NOCASE).
    let folder_index_sql: Vec<String> = strings(
        &conn,
        "SELECT lower(replace(replace(replace(sql, ' ', ''), char(10), ''), '\"', ''))
         FROM sqlite_master WHERE type = 'index' AND tbl_name = 'smart_folders'
           AND sql IS NOT NULL",
    );
    assert!(
        folder_index_sql.iter().any(|s| s.starts_with("createuniqueindex")
            && s.contains("coalesce(parent_id,'')")
            && s.contains("namecollatenocase")),
        "smart_folders needs UNIQUE (COALESCE(parent_id,''), name COLLATE NOCASE): {folder_index_sql:?}"
    );
}

#[test]
fn blocks_source_rejects_values_outside_person_agent_quick_entry() {
    let (_dir, conn) = migrated_v4_fixture();
    for (i, ok) in ["person", "agent", "quick-entry"].iter().enumerate() {
        expect_ok(
            insert_block(&conn, N_DAILY, &format!("ok{i}"), i as i64, ok),
            &format!("blocks.source = {ok:?}"),
        );
    }
    for (i, bad) in ["system", "Person", "quick_entry", "quickentry", ""]
        .iter()
        .enumerate()
    {
        expect_err(
            insert_block(&conn, N_DAILY, &format!("bad{i}"), 10 + i as i64, bad),
            "CHECK constraint failed",
            &format!("blocks.source = {bad:?}"),
        );
    }
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM blocks"), 3);
}

#[test]
fn footer_chips_origin_rejects_values_outside_excerpt_person() {
    let (_dir, conn) = migrated_v4_fixture();
    expect_ok(
        insert_chip(&conn, N_DAILY, N_TOPIC, "excerpt"),
        "origin = excerpt",
    );
    expect_ok(
        insert_chip(&conn, N_ISO, N_TOPIC, "person"),
        "origin = person",
    );
    for (bad, topic) in [("agent", N_PLAIN), ("Excerpt", N_AGENT), ("", N_BROKEN)] {
        expect_err(
            insert_chip(&conn, N_DAILY, topic, bad),
            "CHECK constraint failed",
            &format!("footer_chips.origin = {bad:?}"),
        );
    }
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM footer_chips"), 2);
}

// ---- AC 4: chunks byte range ------------------------------------------------------------------

#[test]
fn v5_chunks_gain_nullable_byte_range_columns() {
    let (_dir, conn) = migrated_v4_fixture();
    assert_columns(
        &conn,
        "chunks",
        &[
            ("id", "TEXT", None, None, 1),
            ("note_id", "TEXT", Some(true), None, 0),
            ("ord", "INTEGER", Some(true), None, 0),
            ("content", "TEXT", Some(true), None, 0),
            ("token_count", "INTEGER", Some(true), None, 0),
            ("embed_model_version", "TEXT", Some(false), None, 0),
            ("start_byte", "INTEGER", Some(false), None, 0),
            ("end_byte", "INTEGER", Some(false), None, 0),
        ],
    );

    // Existing rows are not backfilled.
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM chunks"), 4);
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM chunks WHERE start_byte IS NULL AND end_byte IS NULL"
        ),
        4
    );

    // New rows can carry a range, or leave it NULL.
    conn.execute(
        "INSERT INTO chunks (id, note_id, ord, content, token_count, start_byte, end_byte)
         VALUES ('C-NEW-0', ?, 2, 'x', 1, 14, 31)",
        [N_PLAIN],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO chunks (id, note_id, ord, content, token_count)
         VALUES ('C-NEW-1', ?, 3, 'y', 1)",
        [N_PLAIN],
    )
    .unwrap();
    let range: (Option<i64>, Option<i64>) = conn
        .query_row(
            "SELECT start_byte, end_byte FROM chunks WHERE id = 'C-NEW-0'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(range, (Some(14), Some(31)));
    let empty: (Option<i64>, Option<i64>) = conn
        .query_row(
            "SELECT start_byte, end_byte FROM chunks WHERE id = 'C-NEW-1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(empty, (None, None));
}

// ---- AC 5: vault_settings seed ----------------------------------------------------------------

fn max_depth(conn: &Connection) -> Vec<String> {
    strings(
        conn,
        "SELECT value FROM vault_settings WHERE key = 'smart_folder_max_depth'",
    )
}

#[test]
fn v5_seeds_smart_folder_max_depth_on_migration() {
    let (_dir, conn) = migrated_v4_fixture();
    assert_eq!(max_depth(&conn), ["2"]);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM vault_settings"), 1);
}

#[test]
fn v5_seeds_smart_folder_max_depth_on_fresh_vault() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).expect("create fresh vault");
    assert_eq!(vault.schema_version(), 5);
    let conn = vault.connection_ref();
    assert_eq!(schema::current_version(conn).unwrap(), 5);
    assert_eq!(max_depth(conn), ["2"]);
    assert_eq!(count(conn, "SELECT COUNT(*) FROM vault_settings"), 1);
}

#[test]
fn v5_reapply_keeps_changed_smart_folder_max_depth() {
    let (_dir, mut conn) = migrated_v4_fixture();
    conn.execute(
        "UPDATE vault_settings SET value = '3' WHERE key = 'smart_folder_max_depth'",
        [],
    )
    .unwrap();

    schema::apply(&mut conn).expect("second apply succeeds");
    assert_eq!(
        max_depth(&conn),
        ["3"],
        "re-apply overwrote a changed setting"
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM vault_settings"), 1);
}

#[test]
fn v5_vault_reopen_keeps_changed_smart_folder_max_depth() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("vault");
    {
        let vault = Vault::create(&root).expect("create fresh vault");
        assert_eq!(vault.schema_version(), 5);
        vault
            .connection_ref()
            .execute(
                "UPDATE vault_settings SET value = '3' WHERE key = 'smart_folder_max_depth'",
                [],
            )
            .unwrap();
    }
    let vault = Vault::open(&root).expect("reopen vault");
    assert_eq!(max_depth(vault.connection_ref()), ["3"]);
    assert_eq!(
        count(
            vault.connection_ref(),
            "SELECT COUNT(*) FROM vault_settings"
        ),
        1
    );
}

// ---- AC 6: idempotent -------------------------------------------------------------------------

#[test]
fn v5_second_apply_is_a_noop() {
    let (_dir, mut conn) = migrated_v4_fixture();
    // Some V5 data, so "unchanged" covers the new tables too.
    insert_block(&conn, N_DAILY, "b1", 0, "person").unwrap();
    insert_chip(&conn, N_DAILY, N_TOPIC, "person").unwrap();
    insert_folder(&conn, "F-1", "Games", None).unwrap();
    insert_member(&conn, "F-1", N_TOPIC).unwrap();

    let counts_before = table_counts(&conn);
    let schema_before = schema_snapshot(&conn);
    let notes_before = notes_snapshot(&conn);

    schema::apply(&mut conn).expect("second apply on a V5 database succeeds");

    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM schema_version WHERE version = 5"
        ),
        1,
        "second apply inserted another schema_version row 5"
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM schema_version"), 5);
    assert_eq!(schema::current_version(&conn).unwrap(), 5);
    assert_eq!(table_counts(&conn), counts_before, "row counts changed");
    assert_eq!(schema_snapshot(&conn), schema_before, "schema changed");
    assert_eq!(notes_snapshot(&conn), notes_before, "notes changed");
}

// ---- AC 7: partial unique index on daily titles -----------------------------------------------

#[test]
fn v5_daily_title_index_is_partial_unique_and_guards_json_valid() {
    let (_dir, conn) = migrated_v4_fixture();

    let (tbl, sql): (String, String) = conn
        .query_row(
            "SELECT tbl_name, sql FROM sqlite_master
             WHERE type = 'index' AND name = 'idx_notes_daily_title'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .expect("index idx_notes_daily_title exists");
    assert_eq!(tbl, "notes");
    let norm: String = sql
        .to_lowercase()
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    assert!(norm.starts_with("createuniqueindex"), "{sql}");
    assert!(norm.contains("where"), "{sql}");
    assert!(norm.contains("json_valid(frontmatter)"), "{sql}");
    assert!(norm.contains("'$.role'"), "{sql}");
    assert!(norm.contains("'daily'"), "{sql}");

    let (unique, partial): (i64, i64) = conn
        .query_row(
            "SELECT \"unique\", partial FROM pragma_index_list('notes')
             WHERE name = 'idx_notes_daily_title'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((unique, partial), (1, 1));
    let cols = strings(
        &conn,
        "SELECT name FROM pragma_index_info('idx_notes_daily_title') ORDER BY seqno",
    );
    assert_eq!(cols, ["title"]);
}

#[test]
fn v5_daily_title_index_allows_one_daily_note_per_title() {
    let (_dir, conn) = migrated_v4_fixture();
    // Isolate the partial index from the global title index (test-only).
    conn.execute_batch("DROP INDEX idx_notes_title_unique;")
        .unwrap();

    // A second `role: daily` note for 2026-09-04 collides with N_DAILY.
    expect_err(
        insert_note(&conn, "X-1", "2026-09-04", r#"{"role":"daily"}"#),
        "UNIQUE constraint failed",
        "second daily note for 2026-09-04",
    );
    // Same title without the daily role is not covered by the partial index.
    expect_ok(
        insert_note(&conn, "X-2", "2026-09-04", "{}"),
        "role-less 2026-09-04",
    );
    expect_ok(
        insert_note(&conn, "X-3", "2026-09-04", r#"{"role":"topic"}"#),
        "topic 2026-09-04",
    );
    // Malformed frontmatter is ignored by the guard instead of raising a JSON error.
    expect_ok(
        insert_note(&conn, "X-4", "2026-09-04", "not json"),
        "malformed frontmatter 2026-09-04",
    );
    // The role-less ISO note does not block the first daily note for its date...
    expect_ok(
        insert_note(&conn, "X-5", "2026-09-05", r#"{"role":"daily","x":1}"#),
        "first daily note for 2026-09-05",
    );
    // ...but a second daily note for that date is rejected.
    expect_err(
        insert_note(&conn, "X-6", "2026-09-05", r#"{"role":"daily"}"#),
        "UNIQUE constraint failed",
        "second daily note for 2026-09-05",
    );
}

#[test]
fn v5_migration_succeeds_with_malformed_frontmatter_row() {
    let (_dir, db_path) = make_v4_db();
    let mut conn = open(&db_path);
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM notes WHERE json_valid(frontmatter) = 0"
        ),
        1,
        "fixture must hold exactly one malformed-frontmatter note"
    );
    schema::apply(&mut conn).expect("migration tolerates `not json` frontmatter");
    assert_eq!(schema::current_version(&conn).unwrap(), 5);
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_notes_daily_title'"
        ),
        1
    );
}

// ---- AC 8: note delete cascades ---------------------------------------------------------------

#[test]
fn v5_foreign_keys_cascade_from_notes_and_smart_folders() {
    let (_dir, conn) = migrated_v4_fixture();
    let fks = strings(
        &conn,
        "SELECT m.name || '.' || f.\"from\" || ' -> ' || f.\"table\" || '.' ||
                COALESCE(f.\"to\", 'id') || ' ON DELETE ' || f.on_delete
         FROM sqlite_master m, pragma_foreign_key_list(m.name) f
         WHERE m.type = 'table' AND m.name IN ('blocks','day_reviews','day_review_blocks',
               'footer_chips','agent_changes','smart_folders','smart_folder_members',
               'vault_settings')
         ORDER BY 1",
    );
    assert_eq!(
        fks,
        [
            "agent_changes.note_id -> notes.id ON DELETE CASCADE",
            "blocks.note_id -> notes.id ON DELETE CASCADE",
            "day_review_blocks.note_id -> notes.id ON DELETE CASCADE",
            "day_reviews.note_id -> notes.id ON DELETE CASCADE",
            "footer_chips.daily_note_id -> notes.id ON DELETE CASCADE",
            "footer_chips.topic_note_id -> notes.id ON DELETE CASCADE",
            "smart_folder_members.note_id -> notes.id ON DELETE CASCADE",
            "smart_folder_members.smart_folder_id -> smart_folders.id ON DELETE CASCADE",
            "smart_folders.parent_id -> smart_folders.id ON DELETE NO ACTION",
        ]
    );
}

#[test]
fn deleting_a_note_cascades_to_its_v5_rows() {
    let (_dir, conn) = migrated_v4_fixture();

    insert_block(&conn, N_DAILY, "b1", 0, "person").unwrap();
    insert_block(&conn, N_DAILY, "b2", 1, "agent").unwrap();
    insert_block(&conn, N_PLAIN, "b1", 0, "person").unwrap();
    conn.execute_batch(&format!(
        "INSERT INTO day_reviews (note_id, content_version) VALUES ('{N_DAILY}', 3);
         INSERT INTO day_reviews (note_id) VALUES ('{N_ISO}');
         INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
             VALUES ('{N_DAILY}', 'b1', '0123456789abcdef', 'hello');
         INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
             VALUES ('{N_ISO}', 'b1', '0123456789abcdef', 'hi');
         INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES ('AC-1', '{N_DAILY}', '2026-09-04', 1, '[\"a\"]');
         INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES ('AC-2', '{N_PLAIN}', '2026-09-04', 2, '[\"b\"]');"
    ))
    .unwrap();
    insert_folder(&conn, "F-1", "Games", None).unwrap();
    insert_member(&conn, "F-1", N_DAILY).unwrap();
    insert_member(&conn, "F-1", N_TOPIC).unwrap();
    // N_DAILY appears as the daily side of one chip and the topic side of another.
    insert_chip(&conn, N_DAILY, N_TOPIC, "excerpt").unwrap();
    insert_chip(&conn, N_ISO, N_DAILY, "person").unwrap();
    insert_chip(&conn, N_ISO, N_TOPIC, "person").unwrap();

    let n = conn
        .execute("DELETE FROM notes WHERE id = ?", [N_DAILY])
        .expect("deleting a note with V5 rows succeeds");
    assert_eq!(n, 1);

    let ids = |sql: &str| strings(&conn, sql);
    assert_eq!(
        ids("SELECT note_id || '/' || block_id FROM blocks ORDER BY 1"),
        [format!("{N_PLAIN}/b1")]
    );
    assert_eq!(
        ids("SELECT note_id FROM day_reviews ORDER BY 1"),
        [N_ISO.to_string()]
    );
    assert_eq!(
        ids("SELECT note_id FROM day_review_blocks ORDER BY 1"),
        [N_ISO.to_string()]
    );
    assert_eq!(ids("SELECT id FROM agent_changes ORDER BY 1"), ["AC-2"]);
    assert_eq!(
        ids("SELECT note_id FROM smart_folder_members ORDER BY 1"),
        [N_TOPIC.to_string()]
    );
    assert_eq!(
        ids("SELECT daily_note_id || '>' || topic_note_id FROM footer_chips ORDER BY 1"),
        [format!("{N_ISO}>{N_TOPIC}")]
    );
    // The folder itself survives a member's deletion.
    assert_eq!(ids("SELECT id FROM smart_folders"), ["F-1"]);
}

// ---- AC 9: Smart Folder delete ----------------------------------------------------------------

#[test]
fn deleting_a_smart_folder_cascades_to_its_members() {
    let (_dir, conn) = migrated_v4_fixture();
    insert_folder(&conn, "F-1", "Games", None).unwrap();
    insert_folder(&conn, "F-2", "Reading", None).unwrap();
    insert_member(&conn, "F-1", N_TOPIC).unwrap();
    insert_member(&conn, "F-1", N_PLAIN).unwrap();
    insert_member(&conn, "F-2", N_PLAIN).unwrap();

    conn.execute("DELETE FROM smart_folders WHERE id = 'F-1'", [])
        .expect("deleting a leaf folder succeeds");

    assert_eq!(
        strings(
            &conn,
            "SELECT smart_folder_id || '/' || note_id FROM smart_folder_members ORDER BY 1"
        ),
        [format!("F-2/{N_PLAIN}")]
    );
    // Notes are untouched by a folder delete.
    assert_eq!(
        count(
            &conn,
            &format!("SELECT COUNT(*) FROM notes WHERE id IN ('{N_TOPIC}', '{N_PLAIN}')")
        ),
        2
    );
}

#[test]
fn deleting_a_smart_folder_with_children_fails_with_foreign_key_error() {
    let (_dir, conn) = migrated_v4_fixture();
    insert_folder(&conn, "F-P", "Hobbies", None).unwrap();
    insert_folder(&conn, "F-C", "Games", Some("F-P")).unwrap();
    insert_member(&conn, "F-P", N_TOPIC).unwrap();

    expect_err(
        conn.execute("DELETE FROM smart_folders WHERE id = 'F-P'", []),
        "FOREIGN KEY constraint failed",
        "deleting a folder that still has a child",
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM smart_folders"), 2);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM smart_folder_members"), 1);

    // Re-parenting the child first (what #13 does) makes the delete legal.
    conn.execute(
        "UPDATE smart_folders SET parent_id = NULL WHERE id = 'F-C'",
        [],
    )
    .unwrap();
    conn.execute("DELETE FROM smart_folders WHERE id = 'F-P'", [])
        .expect("delete succeeds once the folder has no children");
    assert_eq!(strings(&conn, "SELECT id FROM smart_folders"), ["F-C"]);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM smart_folder_members"), 0);
}

#[test]
fn smart_folder_parent_must_exist() {
    let (_dir, conn) = migrated_v4_fixture();
    expect_err(
        insert_folder(&conn, "F-X", "Orphan", Some("F-MISSING")),
        "FOREIGN KEY constraint failed",
        "parent_id pointing at a missing folder",
    );
}

// ---- AC 10: sibling names unique ignoring ASCII case ------------------------------------------

#[test]
fn smart_folder_sibling_names_are_unique_ignoring_ascii_case() {
    let (_dir, conn) = migrated_v4_fixture();
    insert_folder(&conn, "F-P", "Hobbies", None).unwrap();
    insert_folder(&conn, "F-1", "Games", Some("F-P")).unwrap();

    expect_err(
        insert_folder(&conn, "F-2", "games", Some("F-P")),
        "UNIQUE constraint failed",
        "`games` next to `Games` under the same parent",
    );
    expect_err(
        insert_folder(&conn, "F-3", "Games", Some("F-P")),
        "UNIQUE constraint failed",
        "exact duplicate under the same parent",
    );

    insert_folder(&conn, "F-R1", "Games", None).unwrap();
    expect_err(
        insert_folder(&conn, "F-R2", "games", None),
        "UNIQUE constraint failed",
        "`games` next to `Games` at root",
    );
    expect_err(
        insert_folder(&conn, "F-R3", "GAMES", None),
        "UNIQUE constraint failed",
        "`GAMES` next to `Games` at root",
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM smart_folders"), 3);
}

#[test]
fn smart_folder_same_name_under_different_parents_is_allowed() {
    let (_dir, conn) = migrated_v4_fixture();
    insert_folder(&conn, "F-A", "Work", None).unwrap();
    insert_folder(&conn, "F-B", "Home", None).unwrap();
    expect_ok(
        insert_folder(&conn, "F-A1", "Games", Some("F-A")),
        "Games under Work",
    );
    expect_ok(
        insert_folder(&conn, "F-B1", "games", Some("F-B")),
        "games under Home",
    );
    expect_ok(
        insert_folder(&conn, "F-R", "Games", None),
        "Games at root next to child folders named Games",
    );
    // A distinct name under the same parent is fine.
    expect_ok(
        insert_folder(&conn, "F-A2", "Gamez", Some("F-A")),
        "Gamez under Work",
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM smart_folders"), 6);
}

// ---- AC 11: footer_chips is a rowid table -----------------------------------------------------

#[test]
fn footer_chips_is_a_rowid_table() {
    let (_dir, conn) = migrated_v4_fixture();
    insert_chip(&conn, N_DAILY, N_TOPIC, "person").unwrap();
    insert_chip(&conn, N_DAILY, N_PLAIN, "excerpt").unwrap();
    insert_chip(&conn, N_DAILY, N_AGENT, "person").unwrap();

    let sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'footer_chips'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        !sql.to_uppercase().contains("WITHOUT ROWID"),
        "footer_chips must keep its rowid: {sql}"
    );

    // rowid order is insertion order, which is the footer's render order (D11),
    // even though it differs from the primary-key order here.
    let mut stmt = conn
        .prepare("SELECT rowid, topic_note_id FROM footer_chips ORDER BY rowid")
        .expect("SELECT rowid FROM footer_chips succeeds");
    let rows: Vec<(i64, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    let topics: Vec<&str> = rows.iter().map(|(_, t)| t.as_str()).collect();
    assert_eq!(topics, [N_TOPIC, N_PLAIN, N_AGENT]);
    assert!(rows.windows(2).all(|w| w[0].0 < w[1].0), "{rows:?}");
}

// ---- implementer: byte-range columns already present ------------------------------------------

/// A V4 database whose `chunks` already carries a byte-range column (for
/// example from a pre-release build) still migrates: V5 adds a column only when
/// it is missing, so `ALTER TABLE ADD COLUMN` never fails on a duplicate.
#[test]
fn v5_migration_skips_chunk_byte_range_columns_that_already_exist() {
    let (_dir, db_path) = make_v4_db();
    {
        let conn = open(&db_path);
        conn.execute_batch(
            "ALTER TABLE chunks ADD COLUMN start_byte INTEGER;
             UPDATE chunks SET start_byte = 7 WHERE id = 'C-PLAIN-0';",
        )
        .unwrap();
    }
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V5 tolerates a pre-existing chunks.start_byte");
    assert_eq!(schema::current_version(&conn).unwrap(), 5);

    let cols = strings(
        &conn,
        "SELECT name FROM pragma_table_info('chunks')
         WHERE name IN ('start_byte', 'end_byte') ORDER BY name",
    );
    assert_eq!(cols, ["end_byte", "start_byte"]);
    let kept: Option<i64> = conn
        .query_row(
            "SELECT start_byte FROM chunks WHERE id = 'C-PLAIN-0'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(kept, Some(7), "an existing start_byte value was lost");
}
