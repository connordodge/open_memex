//! V6 migration tests (WI #237, Spec #234 R49-R52, TD1-TD3; #233 TD2;
//! rulings D4, D5, D6, D7a). V6 adds `tags.origin` and `tags.first_line`,
//! the `tag_corrections`, `feedback` and `vault_guide_revisions` tables, the
//! partial unique index `idx_notes_guide`, and backfills body-origin tag rows
//! from every non-guide note's person section, in one transaction.
//!
//! The V5 fixture is built inline (the shipped V5 schema, as
//! `app/test/fixtures/vault_schema_v5.sql` held it before V6) and pinned at
//! `schema_version` 5 so V6 has work to do on the next `schema::apply()`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use memex_core::notes::{self, NoteId};
use memex_core::{schema, tags, Vault};
use rusqlite::types::ValueRef;
use rusqlite::{params, Connection};
use serde_json::json;

// ---- fixture ----------------------------------------------------------------------------------

const N_DAILY: &str = "01J9V6000000000000000000D1";
const N_TOPIC: &str = "01J9V6000000000000000000T1";
const N_PLAIN: &str = "01J9V6000000000000000000P1";
const N_AGENT: &str = "01J9V6000000000000000000A1";
const N_BROKEN: &str = "01J9V6000000000000000000B1";
const N_FENCE: &str = "01J9V6000000000000000000F1";
const N_SYS: &str = "01J9V6000000000000000000S1";
const N_GUIDE: &str = "01J9V6000000000000000000G1";
const N_GUIDE_CASE: &str = "01J9V6000000000000000000G2";
const N_GUIDE_2: &str = "01J9V6000000000000000000G3";

/// Every table V6 adds.
const V6_TABLES: [&str; 3] = ["tag_corrections", "feedback", "vault_guide_revisions"];

/// A daily note: tags in the person section (one in a list item with a task
/// box), one in fenced code, and a footer chip below the marker.
const DAILY_BODY: &str = "Standup #work and the #Q3-plan.\n\n- [ ] call #alice about #work\n\n```sh\necho #notatag\n```\n\n<!-- memex:topics -->\n[[Games~about]]\n";

/// A topic note with a marker: `#belowmarker` is below it.
const TOPIC_BODY: &str =
    "# Games\n\nIdeas for #game-feel.\n> quoted #Pricing note\n\n<!-- memex:topics -->\n#belowmarker\n";

/// A plain note: tags next to text that is never a tag (code span, wikilink,
/// URL fragment, mid-word `#`, digits-only name, heading).
const PLAIN_BODY: &str = "# Plain note\n\nReading list #reading, see (#memex) and `#code`.\nLinks [[Other #notatag]] and https://example.com/#frag and a#b and #123.\n";

/// A non-daily note whose only marker line is inside fenced code, so it has
/// no footer; `#infence` is inside the fence.
const FENCE_BODY: &str =
    "Intro #fenced-ok\n```\n<!-- memex:topics -->\n#infence\n```\nAfter the fence #afterfence\n";

/// A note that writes a system tag in its body.
const SYS_BODY: &str = "Triage #inbox later.\n";

/// The Vault Guide: its `#tags` are never tags (D3).
const GUIDE_BODY: &str = "Prefer #game-feel for design notes.\n";

/// `role: Guide` (other case) is not the guide, so it is scanned.
const GUIDE_CASE_BODY: &str = "Draft #draft\n";

/// The shipped V5 schema (v1..v5), FTS included, pinned at version 5.
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

/// (id, title, content_md, frontmatter, version, created_at, updated_at)
type FixtureNote = (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    i64,
    i64,
    i64,
);

fn fixture_notes() -> Vec<FixtureNote> {
    vec![
        (
            N_DAILY,
            "2026-11-02",
            DAILY_BODY,
            r#"{"role":"daily"}"#,
            4,
            1_700_000_500_000,
            1_700_000_900_000,
        ),
        (
            N_TOPIC,
            "Games",
            TOPIC_BODY,
            r#"{"role":"topic"}"#,
            2,
            1_700_000_600_000,
            1_700_000_650_000,
        ),
        (
            N_PLAIN,
            "Plain note",
            PLAIN_BODY,
            "{}",
            3,
            1_700_000_000_000,
            1_700_000_100_000,
        ),
        (
            N_AGENT,
            "Agent summary",
            "Written by an agent.\n",
            r#"{"source":"agent","agent":"claude-code","created_by":"mcp"}"#,
            1,
            1_700_000_200_000,
            1_700_000_200_000,
        ),
        (
            N_BROKEN,
            "Broken frontmatter",
            "---\nnot: [valid\n---\nbody\n",
            "not json",
            2,
            1_700_000_300_000,
            1_700_000_350_000,
        ),
        (
            N_FENCE,
            "Fenced marker",
            FENCE_BODY,
            "{}",
            1,
            1_700_000_400_000,
            1_700_000_400_000,
        ),
        (
            N_SYS,
            "Triage",
            SYS_BODY,
            "{}",
            1,
            1_700_000_450_000,
            1_700_000_450_000,
        ),
        (
            N_GUIDE,
            "Vault Guide",
            GUIDE_BODY,
            r#"{"role":"guide"}"#,
            5,
            1_700_000_700_000,
            1_700_000_750_000,
        ),
        (
            N_GUIDE_CASE,
            "Guide draft",
            GUIDE_CASE_BODY,
            r#"{"role":"Guide"}"#,
            1,
            1_700_000_800_000,
            1_700_000_800_000,
        ),
    ]
}

/// Build a vault DB pinned at schema V5, with daily, topic, plain, agent,
/// malformed-frontmatter, fenced-marker and guide notes, their chunks (and
/// FTS rows), blocks, a reviewed day, a footer chip, an agent change entry
/// and pre-existing tag rows (system, mixed case, outside the grammar, and one
/// the body also writes).
fn make_v5_db(dir: &Path) -> PathBuf {
    let db_path = dir.join("memex.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn.execute_batch(V5_DDL).unwrap();

    for (id, title, body, fm, version, created, updated) in fixture_notes() {
        insert_note_full(&conn, id, title, body, fm, version, created, updated).unwrap();
    }

    let chunks = [
        (
            "C-DAILY-0",
            N_DAILY,
            0,
            "Standup #work and the #Q3-plan.",
            0,
            31,
        ),
        ("C-TOPIC-0", N_TOPIC, 0, "Ideas for #game-feel.", 9, 30),
        ("C-PLAIN-0", N_PLAIN, 0, "Reading list #reading", 14, 35),
    ];
    for (id, note, ord, content, start, end) in chunks {
        conn.execute(
            "INSERT INTO chunks (id, note_id, ord, content, token_count, embed_model_version,
                                 start_byte, end_byte)
             VALUES (?, ?, ?, ?, 4, 'test-model-1', ?, ?)",
            params![id, note, ord, content, start, end],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chunk_fts (content, chunk_id, note_id) VALUES (?, ?, ?)",
            params![content, id, note],
        )
        .unwrap();
    }

    conn.execute_batch(&format!(
        "INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text, content_hash,
                             source, created_version, created_at)
             VALUES ('{N_DAILY}', 'b1', 0, 0, 31, 'Standup #work and the #Q3-plan.',
                     '0123456789abcdef', 'person', 1, 1700000500000);
         INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text, content_hash,
                             source, created_version, created_at)
             VALUES ('{N_DAILY}', 'b2', 1, 33, 63, '- [ ] call #alice about #work',
                     'fedcba9876543210', 'quick-entry', 2, 1700000600000);
         INSERT INTO day_reviews (note_id, content_version, reviewed_content_version, reviewed_at)
             VALUES ('{N_DAILY}', 3, 3, 1700000950000);
         INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
             VALUES ('{N_DAILY}', 'b1', '0123456789abcdef', 'Standup #work and the #Q3-plan.');
         INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES ('{N_DAILY}', '{N_TOPIC}', 'excerpt', 1700000900000);
         INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES ('AC-1', '{N_DAILY}', '2026-11-02', 1700000900000, '[\"Filed a block\"]');
         INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, label, position, source)
             VALUES ('L-1', '{N_PLAIN}', '{N_AGENT}', 'Agent summary', 'wikilink', NULL, 0, 'inline_body');
         INSERT INTO tags (note_id, tag) VALUES ('{N_DAILY}', 'inbox');
         INSERT INTO tags (note_id, tag) VALUES ('{N_AGENT}', 'agent-authored');
         INSERT INTO tags (note_id, tag) VALUES ('{N_TOPIC}', 'Pricing');
         INSERT INTO tags (note_id, tag) VALUES ('{N_PLAIN}', 'reading');
         INSERT INTO tags (note_id, tag) VALUES ('{N_PLAIN}', 'Work Stuff');
         INSERT INTO tags (note_id, tag) VALUES ('{N_SYS}', 'inbox');"
    ))
    .unwrap();

    drop(conn);
    db_path
}

#[allow(clippy::too_many_arguments)]
fn insert_note_full(
    conn: &Connection,
    id: &str,
    title: &str,
    body: &str,
    fm: &str,
    version: i64,
    created: i64,
    updated: i64,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        params![id, title, body, fm, version, created, updated],
    )
}

fn open(db_path: &Path) -> Connection {
    let conn = Connection::open(db_path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn
}

/// The V5 fixture after one `schema::apply`, asserted to have reached V6.
fn migrated_v5_fixture() -> (tempfile::TempDir, Connection) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v5_db(dir.path());
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V5 -> V6 migration succeeds");
    assert_eq!(
        schema::current_version(&conn).unwrap(),
        6,
        "schema::apply did not advance the V5 fixture to V6"
    );
    (dir, conn)
}

/// A vault folder (manifest at schema 5, objects dir) around the V5 fixture,
/// opened through `Vault::open`, which migrates it.
fn opened_v5_vault() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    make_v5_db(dir.path());
    let manifest = json!({
        "vault_id": "01J9V6MANIFEST000000000000",
        "schema_version": 5,
        "created_at": 1_000i64,
    });
    std::fs::write(
        dir.path().join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    std::fs::create_dir_all(dir.path().join("objects")).unwrap();
    let vault = Vault::open(dir.path()).expect("open V5 vault migrates it");
    assert_eq!(
        schema::current_version(vault.connection_ref()).unwrap(),
        6,
        "Vault::open did not advance the V5 fixture to V6"
    );
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

fn schema_snapshot(conn: &Connection) -> Vec<String> {
    strings(
        conn,
        "SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
         ORDER BY type, name",
    )
}

/// The schema plus every row of every table (FTS shadow tables included).
fn full_snapshot(conn: &Connection) -> Vec<String> {
    let mut out = schema_snapshot(conn);
    let tables = strings(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite%'
         ORDER BY name",
    );
    for t in tables {
        out.push(format!("== {t}"));
        out.extend(table_rows(conn, &t));
    }
    out
}

/// The rows V6 promises not to touch: notes (body, version, updated_at and
/// every other column), day_reviews, day_review_blocks, blocks, chunks and
/// their FTS rows.
fn untouchable_snapshot(conn: &Connection) -> Vec<String> {
    let mut out = Vec::new();
    for t in [
        "notes",
        "day_reviews",
        "day_review_blocks",
        "blocks",
        "chunks",
        "chunk_fts",
        "footer_chips",
        "agent_changes",
        "links",
    ] {
        out.push(format!("== {t}"));
        out.extend(table_rows(conn, t));
    }
    out
}

/// One `tags` row: (note_id, tag, origin, first_line).
type TagRow = (String, String, String, Option<String>);

fn tag_rows(conn: &Connection) -> BTreeSet<TagRow> {
    let mut stmt = conn
        .prepare("SELECT note_id, tag, origin, first_line FROM tags")
        .unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn tag_rows_for(conn: &Connection, note: &str) -> BTreeSet<TagRow> {
    tag_rows(conn)
        .into_iter()
        .filter(|(n, ..)| n == note)
        .collect()
}

fn row(note: &str, tag: &str, origin: &str, first_line: Option<&str>) -> TagRow {
    (
        note.to_string(),
        tag.to_string(),
        origin.to_string(),
        first_line.map(str::to_string),
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
    insert_note_full(conn, id, title, "", fm, 1, 1, 1)
}

fn insert_correction(conn: &Connection, note: Option<&str>, title: &str, tag: &str) -> i64 {
    conn.execute(
        "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at)
         VALUES (?, ?, ?, 'removed', 1700001000000)",
        params![note, title, tag],
    )
    .unwrap();
    conn.last_insert_rowid()
}

#[allow(clippy::too_many_arguments)]
fn insert_feedback(
    conn: &Connection,
    id: &str,
    kind: &str,
    source: &str,
    status: &str,
    note: Option<&str>,
    agent_change: Option<&str>,
    tag_correction: Option<i64>,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO feedback (id, kind, source, note_id, day, agent_change_id, text,
                               correction_json, status, reply, tag_correction_id,
                               created_at, updated_at, handled_at)
         VALUES (?, ?, ?, ?, NULL, ?, 'why', NULL, ?, NULL, ?, 1700001000000, 1700001000000, NULL)",
        params![id, kind, source, note, agent_change, status, tag_correction],
    )
}

fn insert_revision(
    conn: &Connection,
    id: &str,
    note: &str,
    agent_change: Option<&str>,
) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO vault_guide_revisions (id, note_id, previous_md, previous_version,
                                            new_version, agent_change_id, created_at)
         VALUES (?, ?, 'old guide', 1, 2, ?, 1700001000000)",
        params![id, note, agent_change],
    )
}

fn insert_agent_change(conn: &Connection, id: &str, note: &str) {
    conn.execute(
        "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
         VALUES (?, ?, '2026-11-02', 1700001000000, '[]')",
        params![id, note],
    )
    .unwrap();
}

/// (column name, declared type, NOT NULL; None = not pinned by the Spec).
type ColSpec = (&'static str, &'static str, Option<bool>);

fn assert_columns(conn: &Connection, table: &str, expected: &[ColSpec]) {
    let mut stmt = conn
        .prepare("SELECT name, upper(type), \"notnull\" FROM pragma_table_info(?1) ORDER BY name")
        .unwrap();
    let actual: Vec<(String, String, bool)> = stmt
        .query_map([table], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? != 0))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert!(!actual.is_empty(), "table {table} does not exist");
    let mut actual_names: Vec<&str> = actual.iter().map(|c| c.0.as_str()).collect();
    actual_names.sort();
    let mut expected_names: Vec<&str> = expected.iter().map(|c| c.0).collect();
    expected_names.sort();
    assert_eq!(
        actual_names, expected_names,
        "{table}: column set differs from the Spec"
    );
    for (name, ty, notnull) in expected {
        let col = actual.iter().find(|c| c.0 == *name).unwrap();
        assert_eq!(col.1, *ty, "{table}.{name}: declared type");
        if let Some(nn) = notnull {
            assert_eq!(col.2, *nn, "{table}.{name}: NOT NULL");
        }
    }
}

/// (from column, referenced table, referenced column, ON DELETE) for `table`.
fn foreign_keys(conn: &Connection, table: &str) -> BTreeSet<(String, String, String, String)> {
    let mut stmt = conn
        .prepare("SELECT \"from\", \"table\", \"to\", on_delete FROM pragma_foreign_key_list(?1)")
        .unwrap();
    let rows = stmt
        .query_map([table], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                r.get::<_, String>(3)?,
            ))
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

/// (unique, partial, key columns with DESC flag) of the named index.
fn index_shape(conn: &Connection, table: &str, index: &str) -> (bool, bool, Vec<(String, bool)>) {
    let (unique, partial): (i64, i64) = conn
        .query_row(
            "SELECT \"unique\", partial FROM pragma_index_list(?1) WHERE name = ?2",
            [table, index],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or_else(|e| panic!("index {index} on {table} is missing: {e}"));
    let mut stmt = conn
        .prepare(
            "SELECT COALESCE(name, '<expr>'), \"desc\" FROM pragma_index_xinfo(?1)
             WHERE key = 1 ORDER BY seqno",
        )
        .unwrap();
    let cols = stmt
        .query_map([index], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    (unique != 0, partial != 0, cols)
}

fn key(c: &str, desc: bool) -> (String, bool) {
    (c.to_string(), desc)
}

// ---- AC 1: version, columns, tables, indexes --------------------------------------------------

#[test]
fn app_schema_version_is_6() {
    assert_eq!(schema::APP_SCHEMA_VERSION, 6);
}

#[test]
fn v6_apply_advances_v5_database_to_version_6() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v5_db(dir.path());
    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V5 -> V6 migration succeeds");

    let versions = strings(
        &conn,
        "SELECT CAST(version AS TEXT) FROM schema_version ORDER BY version",
    );
    assert_eq!(versions, ["1", "2", "3", "4", "5", "6"]);
}

#[test]
fn v6_vault_open_rewrites_v5_manifest_to_6() {
    let (dir, vault) = opened_v5_vault();
    assert_eq!(vault.schema_version(), 6);
    let on_disk: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("manifest.json")).unwrap()).unwrap();
    assert_eq!(on_disk["schema_version"].as_i64(), Some(6), "{on_disk}");
    assert_eq!(
        on_disk["vault_id"].as_str(),
        Some("01J9V6MANIFEST000000000000"),
        "{on_disk}"
    );
}

#[test]
fn v6_tags_gain_origin_and_first_line_columns() {
    let (_dir, conn) = migrated_v5_fixture();
    assert_columns(
        &conn,
        "tags",
        &[
            ("note_id", "TEXT", Some(true)),
            ("tag", "TEXT", Some(true)),
            ("origin", "TEXT", Some(true)),
            ("first_line", "TEXT", Some(false)),
        ],
    );
    let dflt: Option<String> = conn
        .query_row(
            "SELECT dflt_value FROM pragma_table_info('tags') WHERE name = 'origin'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(dflt.as_deref(), Some("'person'"), "tags.origin default");

    // The primary key is unchanged: still (note_id, tag).
    let pk: Vec<String> = strings(
        &conn,
        "SELECT name FROM pragma_table_info('tags') WHERE pk > 0 ORDER BY pk",
    );
    assert_eq!(pk, ["note_id", "tag"]);

    // A plain insert (today's `tags::add_tag`) is person-origin with no first line.
    conn.execute(
        "INSERT INTO tags (note_id, tag) VALUES (?, 'fresh')",
        [N_AGENT],
    )
    .unwrap();
    let fresh: (String, Option<String>) = conn
        .query_row(
            "SELECT origin, first_line FROM tags WHERE note_id = ? AND tag = 'fresh'",
            [N_AGENT],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(fresh, ("person".to_string(), None));
}

#[test]
fn v6_tags_origin_rejects_values_outside_body_agent_person() {
    let (_dir, conn) = migrated_v5_fixture();
    for (i, ok) in ["body", "agent", "person"].iter().enumerate() {
        expect_ok(
            conn.execute(
                "INSERT INTO tags (note_id, tag, origin) VALUES (?, ?, ?)",
                params![N_AGENT, format!("ok-{i}"), ok],
            ),
            &format!("origin {ok}"),
        );
    }
    for bad in ["Body", "excerpt", ""] {
        expect_err(
            conn.execute(
                "INSERT INTO tags (note_id, tag, origin) VALUES (?, 'bad', ?)",
                params![N_AGENT, bad],
            ),
            "CHECK",
            &format!("origin {bad:?}"),
        );
    }
    expect_err(
        conn.execute(
            "INSERT INTO tags (note_id, tag, origin) VALUES (?, 'null', NULL)",
            [N_AGENT],
        ),
        "NOT NULL",
        "origin NULL",
    );
}

#[test]
fn v6_creates_the_tag_corrections_feedback_and_guide_revision_tables() {
    let (_dir, conn) = migrated_v5_fixture();
    let nn = Some(true);
    let null = Some(false);
    let any = None;

    assert_columns(
        &conn,
        "tag_corrections",
        &[
            ("id", "INTEGER", any),
            ("note_id", "TEXT", null),
            ("note_title", "TEXT", nn),
            ("tag", "TEXT", nn),
            ("kind", "TEXT", nn),
            ("created_at", "INTEGER", nn),
            ("cleared_at", "INTEGER", null),
        ],
    );
    assert_columns(
        &conn,
        "feedback",
        &[
            ("id", "TEXT", any),
            ("kind", "TEXT", any),
            ("source", "TEXT", any),
            ("note_id", "TEXT", null),
            ("day", "TEXT", null),
            ("agent_change_id", "TEXT", null),
            ("text", "TEXT", null),
            ("correction_json", "TEXT", null),
            ("status", "TEXT", any),
            ("reply", "TEXT", null),
            ("tag_correction_id", "INTEGER", null),
            ("created_at", "INTEGER", any),
            ("updated_at", "INTEGER", any),
            ("handled_at", "INTEGER", null),
        ],
    );
    assert_columns(
        &conn,
        "vault_guide_revisions",
        &[
            ("id", "TEXT", any),
            ("note_id", "TEXT", nn),
            ("previous_md", "TEXT", any),
            ("previous_version", "INTEGER", any),
            ("new_version", "INTEGER", any),
            ("agent_change_id", "TEXT", null),
            ("created_at", "INTEGER", any),
        ],
    );

    // Primary keys: tag_corrections.id is the rowid alias; the others are TEXT ids.
    for t in V6_TABLES {
        let pk = strings(
            &conn,
            &format!("SELECT name FROM pragma_table_info('{t}') WHERE pk > 0"),
        );
        assert_eq!(pk, ["id"], "{t} primary key");
    }

    // tag_corrections uses AUTOINCREMENT (D4): SQLite records it in sqlite_sequence.
    let sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tag_corrections'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(sql.to_uppercase().contains("AUTOINCREMENT"), "{sql}");

    assert_eq!(
        foreign_keys(&conn, "tag_corrections"),
        BTreeSet::from([fk("note_id", "notes", "id", "SET NULL")])
    );
    assert_eq!(
        foreign_keys(&conn, "feedback"),
        BTreeSet::from([
            fk("note_id", "notes", "id", "SET NULL"),
            fk("agent_change_id", "agent_changes", "id", "SET NULL"),
            fk("tag_correction_id", "tag_corrections", "id", "SET NULL"),
        ])
    );
    assert_eq!(
        foreign_keys(&conn, "vault_guide_revisions"),
        BTreeSet::from([
            fk("note_id", "notes", "id", "CASCADE"),
            fk("agent_change_id", "agent_changes", "id", "SET NULL"),
        ])
    );
}

#[test]
fn v6_creates_the_specified_indexes() {
    let (_dir, conn) = migrated_v5_fixture();

    assert_eq!(
        index_shape(&conn, "tag_corrections", "idx_tag_corrections_note"),
        (false, false, vec![key("note_id", false), key("tag", false)])
    );
    assert_eq!(
        index_shape(&conn, "feedback", "idx_feedback_status"),
        (
            false,
            false,
            vec![key("status", false), key("created_at", false)]
        )
    );
    assert_eq!(
        index_shape(&conn, "feedback", "idx_feedback_note"),
        (
            false,
            false,
            vec![key("note_id", false), key("created_at", false)]
        )
    );
    assert_eq!(
        index_shape(
            &conn,
            "vault_guide_revisions",
            "idx_vault_guide_revisions_note"
        ),
        (
            false,
            false,
            vec![key("note_id", false), key("created_at", true)]
        )
    );
    // idx_notes_guide: UNIQUE, partial, on one expression.
    assert_eq!(
        index_shape(&conn, "notes", "idx_notes_guide"),
        (true, true, vec![key("<expr>", false)])
    );
    let guide_sql: String = conn
        .query_row(
            "SELECT lower(replace(replace(sql, ' ', ''), char(10), '')) FROM sqlite_master
             WHERE type = 'index' AND name = 'idx_notes_guide'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        guide_sql.contains("json_valid(frontmatter)")
            && guide_sql.contains("json_extract(frontmatter,'$.role')")
            && guide_sql.contains("='guide'"),
        "{guide_sql}"
    );

    // feedback.tag_correction_id is UNIQUE (D4).
    let unique_cols: Vec<String> = strings(
        &conn,
        "SELECT ii.name FROM pragma_index_list('feedback') il
         JOIN pragma_index_info(il.name) ii
         WHERE il.\"unique\" = 1",
    );
    assert!(
        unique_cols.iter().any(|c| c == "tag_correction_id"),
        "feedback.tag_correction_id must be UNIQUE: {unique_cols:?}"
    );
}

#[test]
fn v6_check_constraints_reject_values_outside_the_spec() {
    let (_dir, conn) = migrated_v5_fixture();
    let c = insert_correction(&conn, Some(N_PLAIN), "Plain note", "work");
    expect_err(
        conn.execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at)
             VALUES (?, 'Plain note', 'work', 'added', 1)",
            [N_PLAIN],
        ),
        "CHECK",
        "tag_corrections.kind 'added'",
    );
    expect_err(
        conn.execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at)
             VALUES (?, NULL, 'work', 'removed', 1)",
            [N_PLAIN],
        ),
        "NOT NULL",
        "tag_corrections.note_title NULL",
    );

    let mut n = 0;
    let mut ok = |kind: &str, source: &str, status: &str| {
        n += 1;
        expect_ok(
            insert_feedback(
                &conn,
                &format!("FB-OK-{n}"),
                kind,
                source,
                status,
                Some(N_PLAIN),
                None,
                None,
            ),
            &format!("feedback {kind}/{source}/{status}"),
        );
    };
    ok("comment", "person", "open");
    ok("correction", "person", "handled");
    ok("comment", "chat", "handled");

    for (kind, source, status, what) in [
        ("note", "person", "open", "kind"),
        ("comment", "agent", "open", "source"),
        ("comment", "person", "closed", "status"),
        ("Comment", "person", "open", "kind case"),
    ] {
        expect_err(
            insert_feedback(
                &conn,
                "FB-BAD",
                kind,
                source,
                status,
                Some(N_PLAIN),
                None,
                None,
            ),
            "CHECK",
            &format!("feedback {what}"),
        );
    }

    // One feedback row per tag correction (D4).
    expect_ok(
        insert_feedback(
            &conn,
            "FB-C1",
            "correction",
            "person",
            "open",
            Some(N_PLAIN),
            None,
            Some(c),
        ),
        "first feedback for a correction",
    );
    expect_err(
        insert_feedback(
            &conn,
            "FB-C2",
            "correction",
            "person",
            "open",
            Some(N_PLAIN),
            None,
            Some(c),
        ),
        "UNIQUE",
        "second feedback for the same correction",
    );
}

// ---- AC 2: bodies, versions, review state and chunks byte-identical ---------------------------

#[test]
fn v6_migration_leaves_notes_reviews_blocks_and_chunks_byte_identical() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v5_db(dir.path());
    let before = untouchable_snapshot(&open(&db_path));
    assert!(before.iter().any(|r| r.contains(N_DAILY)));

    let mut conn = open(&db_path);
    schema::apply(&mut conn).expect("V5 -> V6 migration succeeds");
    assert_eq!(schema::current_version(&conn).unwrap(), 6);

    assert_eq!(untouchable_snapshot(&conn), before);

    // Spot-check by value: the reviewed day is still reviewed at its version.
    let review: (i64, Option<i64>) = conn
        .query_row(
            "SELECT content_version, reviewed_content_version FROM day_reviews WHERE note_id = ?",
            [N_DAILY],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(review, (3, Some(3)));
    for (id, _, body, _, version, _, updated) in fixture_notes() {
        let got: (String, i64, i64) = conn
            .query_row(
                "SELECT content_md, version, updated_at FROM notes WHERE id = ?",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(got, (body.to_string(), version, updated), "{id}");
    }
}

#[test]
fn v6_vault_open_leaves_note_bodies_and_review_state_unchanged() {
    // An identical V5 fixture, snapshotted before any migration.
    let dir = tempfile::tempdir().unwrap();
    let before = untouchable_snapshot(&open(&make_v5_db(dir.path())));

    let (_vdir, vault) = opened_v5_vault();
    assert_eq!(untouchable_snapshot(vault.connection_ref()), before);
    let state = memex_core::daily::review_state(vault.connection_ref(), N_DAILY).unwrap();
    assert_eq!(state, memex_core::daily::ReviewState::Reviewed);
}

// ---- AC 3-5: backfill -------------------------------------------------------------------------

#[test]
fn fixture_expectations_match_the_tag_extractor() {
    // Guards the hand-written expectations below against the T1 extractor.
    let names = |text: &str| -> Vec<(String, String)> {
        tags::extract(text)
            .into_iter()
            .map(|t| (t.name, t.first_line))
            .collect()
    };
    let s = |a: &str, b: &str| (a.to_string(), b.to_string());
    assert_eq!(
        names(&memex_core::daily::split_body(DAILY_BODY).person),
        [
            s("alice", "call #alice about #work"),
            s("q3-plan", "Standup #work and the #Q3-plan."),
            s("work", "Standup #work and the #Q3-plan."),
        ]
    );
    assert_eq!(
        names(tags::person_section(TOPIC_BODY)),
        [
            s("game-feel", "Ideas for #game-feel."),
            s("pricing", "quoted #Pricing note"),
        ]
    );
    let plain_line = "Reading list #reading, see (#memex) and `#code`.";
    assert_eq!(
        names(tags::person_section(PLAIN_BODY)),
        [s("memex", plain_line), s("reading", plain_line)]
    );
    assert_eq!(
        names(tags::person_section(FENCE_BODY)),
        [
            s("afterfence", "After the fence #afterfence"),
            s("fenced-ok", "Intro #fenced-ok"),
        ]
    );
}

#[test]
fn v6_backfills_body_tags_from_person_sections_with_first_line() {
    let (_dir, conn) = migrated_v5_fixture();
    let plain_line = "Reading list #reading, see (#memex) and `#code`.";

    // Daily note: from `split_body`'s person section; nothing from the fence.
    assert_eq!(
        tag_rows_for(&conn, N_DAILY),
        BTreeSet::from([
            row(N_DAILY, "inbox", "agent", None),
            row(
                N_DAILY,
                "work",
                "body",
                Some("Standup #work and the #Q3-plan.")
            ),
            row(
                N_DAILY,
                "q3-plan",
                "body",
                Some("Standup #work and the #Q3-plan.")
            ),
            row(N_DAILY, "alice", "body", Some("call #alice about #work")),
        ])
    );
    // Topic note: nothing below the marker; the legacy `Pricing` row is kept
    // beside the lowercase body `pricing`.
    assert_eq!(
        tag_rows_for(&conn, N_TOPIC),
        BTreeSet::from([
            row(N_TOPIC, "Pricing", "person", None),
            row(N_TOPIC, "game-feel", "body", Some("Ideas for #game-feel.")),
            row(N_TOPIC, "pricing", "body", Some("quoted #Pricing note")),
        ])
    );
    // Plain note: no tag from a code span, wikilink, URL, `a#b` or `#123`.
    assert_eq!(
        tag_rows_for(&conn, N_PLAIN),
        BTreeSet::from([
            row(N_PLAIN, "Work Stuff", "person", None),
            row(N_PLAIN, "reading", "body", Some(plain_line)),
            row(N_PLAIN, "memex", "body", Some(plain_line)),
        ])
    );
    // A marker inside fenced code is body text; a tag inside the fence is not a tag.
    assert_eq!(
        tag_rows_for(&conn, N_FENCE),
        BTreeSet::from([
            row(N_FENCE, "fenced-ok", "body", Some("Intro #fenced-ok")),
            row(
                N_FENCE,
                "afterfence",
                "body",
                Some("After the fence #afterfence")
            ),
        ])
    );
    for absent in [
        "belowmarker",
        "infence",
        "notatag",
        "code",
        "frag",
        "b",
        "123",
    ] {
        assert_eq!(
            count(
                &conn,
                &format!("SELECT COUNT(*) FROM tags WHERE lower(tag) = '{absent}'")
            ),
            0,
            "{absent} must not be backfilled"
        );
    }
}

#[test]
fn v6_existing_system_tags_become_agent_and_others_stay_person_as_stored() {
    let (_dir, conn) = migrated_v5_fixture();
    let rows = tag_rows(&conn);
    for expected in [
        row(N_DAILY, "inbox", "agent", None),
        row(N_AGENT, "agent-authored", "agent", None),
        row(N_TOPIC, "Pricing", "person", None),
        row(N_PLAIN, "Work Stuff", "person", None),
    ] {
        assert!(rows.contains(&expected), "missing {expected:?} in {rows:?}");
    }
    // Names are kept exactly as stored: no lowercasing, no grammar filtering.
    assert_eq!(
        count(
            &conn,
            &format!("SELECT COUNT(*) FROM tags WHERE note_id = '{N_TOPIC}' AND tag = 'Pricing'")
        ),
        1
    );
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM tags WHERE tag = 'Work Stuff'"),
        1
    );
    // The agent note's body has no tags, so its only row is the system tag.
    assert_eq!(
        tag_rows_for(&conn, N_AGENT),
        BTreeSet::from([row(N_AGENT, "agent-authored", "agent", None)])
    );
}

#[test]
fn v6_backfilled_name_with_existing_row_becomes_body_without_a_second_row() {
    let (_dir, conn) = migrated_v5_fixture();
    let plain_line = "Reading list #reading, see (#memex) and `#code`.";
    assert_eq!(
        count(
            &conn,
            &format!("SELECT COUNT(*) FROM tags WHERE note_id = '{N_PLAIN}' AND tag = 'reading'")
        ),
        1
    );
    assert!(tag_rows(&conn).contains(&row(N_PLAIN, "reading", "body", Some(plain_line))));

    // A system tag the body also writes: the agent update runs first, then the
    // backfill makes it body-origin (R9, R51).
    assert_eq!(
        tag_rows_for(&conn, N_SYS),
        BTreeSet::from([row(N_SYS, "inbox", "body", Some("Triage #inbox later."))])
    );
    // No (note_id, tag) appears twice anywhere.
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM (SELECT note_id, tag FROM tags GROUP BY note_id, tag HAVING COUNT(*) > 1)"
        ),
        0
    );
}

#[test]
fn v6_body_origin_rows_always_carry_a_first_line_and_others_none() {
    let (_dir, conn) = migrated_v5_fixture();
    assert!(count(&conn, "SELECT COUNT(*) FROM tags WHERE origin = 'body'") >= 10);
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM tags WHERE origin = 'body' AND (first_line IS NULL OR first_line = '')"
        ),
        0
    );
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM tags WHERE origin <> 'body' AND first_line IS NOT NULL"
        ),
        0
    );
}

// ---- AC 6: re-running changes nothing ---------------------------------------------------------

#[test]
fn v6_second_apply_is_a_noop() {
    let (_dir, mut conn) = migrated_v5_fixture();
    // Some V6 data, so "unchanged" covers the new tables and sqlite_sequence too.
    let c = insert_correction(&conn, Some(N_PLAIN), "Plain note", "reading");
    insert_feedback(
        &conn,
        "FB-1",
        "correction",
        "person",
        "open",
        Some(N_PLAIN),
        Some("AC-1"),
        Some(c),
    )
    .unwrap();
    let before = full_snapshot(&conn);

    schema::apply(&mut conn).expect("second apply on a V6 database succeeds");

    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM schema_version WHERE version = 6"
        ),
        1
    );
    assert_eq!(full_snapshot(&conn), before);
}

#[test]
fn v6_rerun_after_a_lost_version_row_changes_nothing() {
    // The V6 step itself is idempotent: has_column guards, IF NOT EXISTS and
    // an upserting backfill, so re-running it over V6 data is a no-op.
    let (_dir, mut conn) = migrated_v5_fixture();
    let before = full_snapshot(&conn);

    conn.execute("DELETE FROM schema_version WHERE version = 6", [])
        .unwrap();
    schema::apply(&mut conn).expect("re-running V6 over V6 tables succeeds");

    assert_eq!(schema::current_version(&conn).unwrap(), 6);
    assert_eq!(full_snapshot(&conn), before);
}

// ---- AC 7-8: role: guide ----------------------------------------------------------------------

#[test]
fn v6_guide_note_gets_no_backfilled_rows() {
    let (_dir, conn) = migrated_v5_fixture();
    assert_eq!(tag_rows_for(&conn, N_GUIDE), BTreeSet::new());
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM tags WHERE tag = 'game-feel'"),
        1,
        "only the topic note's #game-feel is a tag, not the guide's"
    );
    // `role: Guide` is not the guide (exact match), so it is scanned.
    assert_eq!(
        tag_rows_for(&conn, N_GUIDE_CASE),
        BTreeSet::from([row(N_GUIDE_CASE, "draft", "body", Some("Draft #draft"))])
    );
}

#[test]
fn v6_allows_one_guide_note_and_rejects_a_second() {
    let (_dir, conn) = migrated_v5_fixture();
    expect_err(
        insert_note(&conn, N_GUIDE_2, "Second guide", r#"{"role":"guide"}"#),
        "UNIQUE",
        "a second role: guide note",
    );
    // Other roles, other case and malformed frontmatter are not constrained.
    expect_ok(
        insert_note(
            &conn,
            "01J9V6000000000000000000X1",
            "Another Guide-case",
            r#"{"role":"Guide"}"#,
        ),
        "role: Guide (other case)",
    );
    expect_ok(
        insert_note(
            &conn,
            "01J9V6000000000000000000X2",
            "Broken two",
            "not json",
        ),
        "malformed frontmatter",
    );
    expect_ok(
        insert_note(
            &conn,
            "01J9V6000000000000000000X3",
            "Topic two",
            r#"{"role":"topic"}"#,
        ),
        "role: topic",
    );
}

#[test]
fn v6_two_existing_guide_notes_abort_and_leave_the_vault_at_v5_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = make_v5_db(dir.path());
    {
        let conn = open(&db_path);
        insert_note_full(
            &conn,
            N_GUIDE_2,
            "Second guide",
            "Also #game-feel\n",
            r#"{"role":"guide"}"#,
            1,
            1_700_000_710_000,
            1_700_000_710_000,
        )
        .unwrap();
    }
    let before = full_snapshot(&open(&db_path));

    let mut conn = open(&db_path);
    let res = schema::apply(&mut conn);
    let err = res.expect_err("two role: guide notes must abort V6");
    assert_eq!(err.code(), "guide_rule", "{err}");
    drop(conn);

    let conn = open(&db_path);
    assert_eq!(schema::current_version(&conn).unwrap(), 5);
    assert_eq!(
        full_snapshot(&conn),
        before,
        "the V6 transaction rolled back"
    );
    for t in V6_TABLES {
        assert_eq!(
            count(
                &conn,
                &format!("SELECT COUNT(*) FROM sqlite_master WHERE name = '{t}'")
            ),
            0,
            "{t} must not exist after the rollback"
        );
    }
}

// ---- AC 9-11: foreign keys and AUTOINCREMENT --------------------------------------------------

#[test]
fn deleting_a_note_keeps_its_tag_corrections_with_null_note_id_and_title() {
    let (_dir, mut vault) = opened_v5_vault();
    let conn = vault.connection_ref();
    let c = insert_correction(conn, Some(N_PLAIN), "Plain note", "reading");
    let other = insert_correction(conn, Some(N_TOPIC), "Games", "pricing");
    conn.execute(
        "UPDATE tag_corrections SET cleared_at = 1700002000000 WHERE id = ?",
        [c],
    )
    .unwrap();

    notes::delete_note_checked(&mut vault, &NoteId::parse(N_PLAIN).unwrap(), 3, None)
        .expect("deleting a note with a tag correction succeeds");

    let conn = vault.connection_ref();
    let kept: (Option<String>, String, String, String, Option<i64>) = conn
        .query_row(
            "SELECT note_id, note_title, tag, kind, cleared_at FROM tag_corrections WHERE id = ?",
            [c],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        kept,
        (
            None,
            "Plain note".to_string(),
            "reading".to_string(),
            "removed".to_string(),
            Some(1_700_002_000_000)
        )
    );
    let untouched: Option<String> = conn
        .query_row(
            "SELECT note_id FROM tag_corrections WHERE id = ?",
            [other],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(untouched.as_deref(), Some(N_TOPIC));
}

#[test]
fn deleting_a_note_with_feedback_and_agent_changes_nulls_links_and_cascades_revisions() {
    let (_dir, mut vault) = opened_v5_vault();
    let conn = vault.connection_ref();
    insert_agent_change(conn, "AC-PLAIN", N_PLAIN);
    insert_agent_change(conn, "AC-GUIDE", N_GUIDE);
    let c = insert_correction(conn, Some(N_PLAIN), "Plain note", "reading");
    insert_feedback(
        conn,
        "FB-PLAIN",
        "correction",
        "person",
        "open",
        Some(N_PLAIN),
        Some("AC-PLAIN"),
        Some(c),
    )
    .unwrap();
    // Feedback on another note that points at the deleted note's change entry.
    insert_feedback(
        conn,
        "FB-OTHER",
        "comment",
        "person",
        "handled",
        Some(N_TOPIC),
        Some("AC-PLAIN"),
        None,
    )
    .unwrap();
    // A guide revision whose change entry belongs to the deleted note.
    insert_revision(conn, "REV-1", N_GUIDE, Some("AC-PLAIN")).unwrap();
    insert_revision(conn, "REV-2", N_GUIDE, Some("AC-GUIDE")).unwrap();

    notes::delete_note_checked(&mut vault, &NoteId::parse(N_PLAIN).unwrap(), 3, None)
        .expect("deleting a note with feedback and change entries succeeds");

    let conn = vault.connection_ref();
    let fb: Vec<String> = strings(
        conn,
        "SELECT json_array(id, note_id, agent_change_id, tag_correction_id) FROM feedback ORDER BY id",
    );
    assert_eq!(
        fb,
        [
            format!(r#"["FB-OTHER","{N_TOPIC}",null,null]"#),
            format!(r#"["FB-PLAIN",null,null,{c}]"#),
        ]
    );
    let revs: Vec<String> = strings(
        conn,
        "SELECT json_array(id, note_id, agent_change_id) FROM vault_guide_revisions ORDER BY id",
    );
    assert_eq!(
        revs,
        [
            format!(r#"["REV-1","{N_GUIDE}",null]"#),
            format!(r#"["REV-2","{N_GUIDE}","AC-GUIDE"]"#),
        ]
    );

    // Deleting the guide note's row cascades its revisions (#233 forbids the
    // person path from deleting the guide, so this is the storage rule only).
    conn.execute("DELETE FROM notes WHERE id = ?", [N_GUIDE])
        .expect("deleting the guide row succeeds");
    assert_eq!(count(conn, "SELECT COUNT(*) FROM vault_guide_revisions"), 0);
}

#[test]
fn deleting_a_tag_correction_nulls_its_feedback_link() {
    let (_dir, conn) = migrated_v5_fixture();
    let c = insert_correction(&conn, Some(N_PLAIN), "Plain note", "reading");
    insert_feedback(
        &conn,
        "FB-1",
        "correction",
        "person",
        "open",
        Some(N_PLAIN),
        None,
        Some(c),
    )
    .unwrap();
    conn.execute("DELETE FROM tag_corrections WHERE id = ?", [c])
        .unwrap();
    let link: Option<i64> = conn
        .query_row(
            "SELECT tag_correction_id FROM feedback WHERE id = 'FB-1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(link, None);
}

#[test]
fn deleted_highest_tag_correction_id_is_not_reused() {
    let (_dir, conn) = migrated_v5_fixture();
    let a = insert_correction(&conn, Some(N_PLAIN), "Plain note", "a");
    let b = insert_correction(&conn, Some(N_PLAIN), "Plain note", "b");
    let c = insert_correction(&conn, None, "Gone note", "c");
    assert!(a < b && b < c, "{a} {b} {c}");

    conn.execute("DELETE FROM tag_corrections WHERE id = ?", [c])
        .unwrap();
    let d = insert_correction(&conn, Some(N_TOPIC), "Games", "d");
    assert!(d > c, "id {c} was reused as {d}");

    // Also after every row is gone.
    conn.execute("DELETE FROM tag_corrections", []).unwrap();
    let e = insert_correction(&conn, Some(N_TOPIC), "Games", "e");
    assert!(e > d, "id {d} was reused as {e}");
}

// ---- AC 13: notes::is_guide -------------------------------------------------------------------

#[test]
fn is_guide_is_true_only_for_exact_role_guide() {
    let cases = [
        (json!({"role": "guide"}), true),
        (json!({"role": "guide", "title": "Vault Guide"}), true),
        (json!({}), false),
        (json!({"role": null}), false),
        (json!({"role": "Guide"}), false),
        (json!({"role": "GUIDE"}), false),
        (json!({"role": " guide"}), false),
        (json!({"role": "guide "}), false),
        (json!({"role": "daily"}), false),
        (json!({"role": "topic"}), false),
        (json!({"role": ["guide"]}), false),
        (json!({"role": {"name": "guide"}}), false),
        (json!({"role": 1}), false),
        (json!({"role": true}), false),
        (json!({"Role": "guide"}), false),
        (json!("guide"), false),
        (json!(["guide"]), false),
        (serde_json::Value::Null, false),
    ];
    for (fm, expected) in cases {
        assert_eq!(notes::is_guide(&fm), expected, "{fm}");
    }
}
