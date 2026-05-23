//! V4 migration regression tests. The v4 migration adds the canvas layer
//! (`canvases`, `canvas_nodes`) on top of an existing v3 schema. There is no
//! data to migrate, so the test ensures (a) prior data is intact, (b) the new
//! tables exist with the expected columns + indexes, and (c) the migration is
//! idempotent.

use memex_core::canvas::{add_to_canvas, create_canvas, get_canvas};
use memex_core::notes::{create_note, CreateNote};
use memex_core::schema;
use memex_core::Vault;
use rusqlite::{params, Connection};
use ulid::Ulid;

/// Build a vault DB pinned at schema v3 by running v1..v3 SQL inline,
/// leaving `schema_version` at 3 so v4 has work to do on next `apply()`.
fn make_v3_db_with_notes(titles: &[&str]) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("memex.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
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

         INSERT INTO schema_version(version) VALUES (1);
         INSERT INTO schema_version(version) VALUES (2);
         INSERT INTO schema_version(version) VALUES (3);",
    )
    .unwrap();

    for (i, title) in titles.iter().enumerate() {
        let id = Ulid::new().to_string();
        let now = 1_000 + i as i64;
        conn.execute(
            "INSERT INTO notes (id, title, content_md, version, created_at, updated_at)
             VALUES (?, ?, '', 1, ?, ?)",
            params![id, title, now, now],
        )
        .unwrap();
    }
    drop(conn);
    (dir, db_path)
}

#[test]
fn v4_migration_creates_canvas_tables_and_preserves_prior_data() {
    let (_dir, db_path) = make_v3_db_with_notes(&["First", "Second"]);

    let mut conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();

    schema::apply(&mut conn).expect("v4 migration succeeds");

    // schema_version reaches 4.
    let v: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, 4);

    // Prior notes intact.
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 2);

    // Canvas tables exist.
    let tables: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    assert!(tables.iter().any(|t| t == "canvases"), "{tables:?}");
    assert!(tables.iter().any(|t| t == "canvas_nodes"), "{tables:?}");

    // Expected indexes exist.
    let indexes: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='index' ORDER BY name")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    };
    assert!(
        indexes.iter().any(|i| i == "idx_canvases_title_unique"),
        "{indexes:?}"
    );
    assert!(
        indexes.iter().any(|i| i == "idx_canvases_updated_at"),
        "{indexes:?}"
    );
    assert!(
        indexes.iter().any(|i| i == "idx_canvas_nodes_note"),
        "{indexes:?}"
    );
}

#[test]
fn v4_migration_is_idempotent() {
    let (_dir, db_path) = make_v3_db_with_notes(&["Solo"]);
    let mut conn = Connection::open(&db_path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();

    schema::apply(&mut conn).expect("first apply");
    let v1: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v1, 4);

    schema::apply(&mut conn).expect("second apply must be a no-op");
    let count_v4: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM schema_version WHERE version = 4",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count_v4, 1);
}

#[test]
fn v4_migrated_vault_supports_canvas_round_trip() {
    // Create a v3 vault on disk, then open it via Vault::open (which runs migrations)
    // and confirm the canvas API works end-to-end.
    let (dir, _db_path) = make_v3_db_with_notes(&[]);
    // Write a manifest so Vault::open accepts the directory.
    let manifest = serde_json::json!({
        "vault_id": Ulid::new().to_string(),
        "schema_version": 3,
        "created_at": 1_000i64,
    });
    std::fs::write(
        dir.path().join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    std::fs::create_dir_all(dir.path().join("objects")).unwrap();

    let mut vault = Vault::open(dir.path()).expect("open v3 vault advances to v4");
    assert_eq!(vault.schema_version(), 4);

    let c = create_canvas(&mut vault, "Round Trip").unwrap();
    let n = create_note(
        &mut vault,
        CreateNote {
            title: Some("After Migration".into()),
            content_md: "# After Migration\n".into(),
            ..Default::default()
        },
    )
    .unwrap();
    add_to_canvas(&mut vault, &c.id, n.id.as_str(), 1.0, 2.0).unwrap();
    let detail = get_canvas(&vault, &c.id).unwrap();
    assert_eq!(detail.nodes.len(), 1);
    assert_eq!(detail.nodes[0].x, 1.0);
    assert_eq!(detail.nodes[0].y, 2.0);
}
