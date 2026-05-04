//! Schema v3 migration regression tests. The v3 migration applies a UNIQUE
//! constraint on `notes.title` after deduplicating any pre-existing duplicate
//! titles deterministically. Above a hard threshold the migration aborts.

use memex_core::error::MemexError;
use memex_core::schema::{self, MAX_DEDUP_COLLISIONS};
use rusqlite::{params, Connection};
use ulid::Ulid;

/// Build a vault DB pinned at schema v2 by applying only V1+V2 schema, leaving
/// `schema_version` at 2 so v3 has work to do on next `apply()`.
fn make_v2_db_with_titles(titles: &[(&str, i64)]) -> (tempfile::TempDir, Connection) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("memex.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    // Manually apply v1 + v2 only by tweaking version → 2 between calls.
    // Simpler path: call schema::apply (which goes to v3) then DROP the v3
    // additions and step the version back to 2 — but we'd lose the v3 columns
    // we don't want. So we replicate v1+v2 SQL inline.
    conn.execute_batch(
        "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);

         CREATE TABLE notes (
             id           TEXT PRIMARY KEY,
             title        TEXT NOT NULL,
             content_md   TEXT NOT NULL,
             frontmatter  TEXT NOT NULL DEFAULT '{}',
             version      INTEGER NOT NULL DEFAULT 1,
             created_at   INTEGER NOT NULL,
             updated_at   INTEGER NOT NULL,
             crdt_state   BLOB
         );
         CREATE INDEX idx_notes_updated_at ON notes(updated_at DESC);

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

         INSERT INTO schema_version(version) VALUES (1);
         INSERT INTO schema_version(version) VALUES (2);",
    )
    .unwrap();

    for (title, created_at) in titles {
        let id = Ulid::new().to_string();
        conn.execute(
            "INSERT INTO notes (id, title, content_md, version, created_at, updated_at)
             VALUES (?, ?, '', 1, ?, ?)",
            params![id, title, *created_at, *created_at],
        )
        .unwrap();
    }
    (dir, conn)
}

#[test]
fn v3_migration_dedups_duplicate_titles_deterministically() {
    let (_dir, mut conn) = make_v2_db_with_titles(&[
        ("Foo", 100),
        ("Foo", 200),
        ("Foo", 300),
        ("Bar", 400),
        ("Bar", 500),
        ("Unique", 600),
    ]);

    schema::apply(&mut conn).expect("v3 migration");

    // Three Foos collapse to "Foo", "Foo (2)", "Foo (3)" by created_at order.
    let titles: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT title FROM notes ORDER BY created_at ASC")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    assert_eq!(titles, vec!["Foo", "Foo (2)", "Foo (3)", "Bar", "Bar (2)", "Unique"]);

    // dedup log records every renamed row (3 of them: 2 Foos + 1 Bar).
    let dedup_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM notes_dedup_log", [], |r| r.get(0))
        .unwrap();
    assert_eq!(dedup_count, 3);

    // schema_version reaches 3.
    let v: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, 3);
}

#[test]
fn v3_migration_is_idempotent_on_already_v3_db() {
    let (_dir, mut conn) = make_v2_db_with_titles(&[("Solo", 100)]);
    schema::apply(&mut conn).expect("first apply");
    let v_before: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v_before, 3);

    // Apply again — must not error and must not advance the version further.
    schema::apply(&mut conn).expect("second apply");
    let count_v3: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM schema_version WHERE version = 3",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count_v3, 1);
}

#[test]
fn v3_migration_aborts_when_collision_count_exceeds_cap() {
    // Construct a v2 vault with > MAX_DEDUP_COLLISIONS distinct duplicate-title groups.
    // Each group has 2 rows with the same title, so we add 2 * (MAX + 1) rows.
    let groups = (MAX_DEDUP_COLLISIONS + 1) as usize;
    let mut titles: Vec<(String, i64)> = Vec::with_capacity(groups * 2);
    for i in 0..groups {
        titles.push((format!("dup-{i}"), i as i64));
        titles.push((format!("dup-{i}"), (i + groups) as i64));
    }
    let title_refs: Vec<(&str, i64)> = titles.iter().map(|(t, c)| (t.as_str(), *c)).collect();
    let (_dir, mut conn) = make_v2_db_with_titles(&title_refs);

    let err = schema::apply(&mut conn).expect_err("must abort with TooManyDedupCollisions");
    match err {
        MemexError::TooManyDedupCollisions { count } => {
            assert!(count > MAX_DEDUP_COLLISIONS, "abort count: {count}");
        }
        other => panic!("expected TooManyDedupCollisions, got {other:?}"),
    }

    // schema_version should still be 2 — no v3 changes were applied.
    let v: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, 2);
}
