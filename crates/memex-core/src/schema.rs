use rusqlite::Connection;

use crate::error::MemexError;
use crate::Result;

pub const APP_SCHEMA_VERSION: i64 = 3;

pub const MAX_DEDUP_COLLISIONS: i64 = 1000;

const V1: &str = r#"
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS notes (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    content_md   TEXT NOT NULL,
    frontmatter  TEXT NOT NULL DEFAULT '{}',
    version      INTEGER NOT NULL DEFAULT 1,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    crdt_state   BLOB
);

CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC);
"#;

// V2 adds chunking + FTS5 + tags + pending_index. Vector table is created lazily
// once an embedding model is initialized (so we know the dimension at runtime).
const V2: &str = r#"
CREATE TABLE IF NOT EXISTS chunks (
    id                  TEXT PRIMARY KEY,
    note_id             TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    ord                 INTEGER NOT NULL,
    content             TEXT NOT NULL,
    token_count         INTEGER NOT NULL,
    embed_model_version TEXT
);

CREATE INDEX IF NOT EXISTS idx_chunks_note ON chunks(note_id, ord);

CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
    content,
    chunk_id UNINDEXED,
    note_id UNINDEXED,
    tokenize = 'porter unicode61'
);

CREATE TABLE IF NOT EXISTS tags (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    tag     TEXT NOT NULL,
    PRIMARY KEY (note_id, tag)
);

CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);

CREATE TABLE IF NOT EXISTS pending_index (
    note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    enqueued_at INTEGER NOT NULL
);
"#;

// V3 adds wikilinks: links table, dedup log, has_open_questions / frontmatter_parse_error
// columns on notes, and a UNIQUE constraint on note titles. The UNIQUE constraint is
// applied via dedup-rename pre-pass (see apply_v3 below) because adding it directly
// would fail on duplicate-title vaults.
const V3_PRE: &str = r#"
ALTER TABLE notes ADD COLUMN has_open_questions INTEGER NOT NULL DEFAULT 0;
ALTER TABLE notes ADD COLUMN frontmatter_parse_error INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS notes_dedup_log (
    note_id      TEXT PRIMARY KEY,
    old_title    TEXT NOT NULL,
    new_title    TEXT NOT NULL,
    migrated_at  INTEGER NOT NULL
);
"#;

const V3_POST: &str = r#"
CREATE UNIQUE INDEX IF NOT EXISTS idx_notes_title_unique ON notes(title);

CREATE TABLE IF NOT EXISTS links (
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

CREATE INDEX IF NOT EXISTS idx_links_from ON links(from_note_id);
CREATE INDEX IF NOT EXISTS idx_links_to   ON links(to_note_id);
CREATE INDEX IF NOT EXISTS idx_links_kind ON links(link_kind, to_note_id);
"#;

pub fn apply(conn: &mut Connection) -> Result<()> {
    // v1, v2: each in its own transaction so partial migrations are durable.
    {
        let tx = conn.transaction()?;
        let current: i64 = tx
            .query_row("SELECT COALESCE(MAX(version), 0) FROM schema_version", [], |r| r.get(0))
            .unwrap_or(0);
        if current < 1 {
            tx.execute_batch(V1)?;
            tx.execute("INSERT INTO schema_version(version) VALUES (1)", [])?;
        }
        if current < 2 {
            tx.execute_batch(V2)?;
            tx.execute("INSERT INTO schema_version(version) VALUES (2)", [])?;
        }
        tx.commit()?;
    }

    // v3: pre-flight collision count, dedup-rename, then UNIQUE index.
    let current: i64 = conn
        .query_row("SELECT COALESCE(MAX(version), 0) FROM schema_version", [], |r| r.get(0))
        .unwrap_or(0);
    if current < 3 {
        apply_v3(conn)?;
    }
    Ok(())
}

fn apply_v3(conn: &mut Connection) -> Result<()> {
    // Count duplicate-title groups before doing anything.
    let dup_groups: i64 = conn.query_row(
        "SELECT COUNT(*) FROM (SELECT title FROM notes GROUP BY title HAVING COUNT(*) > 1)",
        [],
        |r| r.get(0),
    )?;
    if dup_groups > MAX_DEDUP_COLLISIONS {
        return Err(MemexError::TooManyDedupCollisions { count: dup_groups });
    }

    let tx = conn.transaction()?;
    tx.execute_batch(V3_PRE)?;

    // Dedup pre-pass: for each duplicate-title group, keep the oldest (lowest
    // created_at, then ULID-sorted id as tiebreaker) and rename the rest to
    // "<title> (2)", "<title> (3)", ... (skipping any suffixed name that's
    // already taken). Record each rename in notes_dedup_log.
    let dup_titles: Vec<String> = {
        let mut stmt = tx.prepare(
            "SELECT title FROM notes GROUP BY title HAVING COUNT(*) > 1 ORDER BY title",
        )?;
        let mut rows = stmt.query([])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(r.get::<_, String>(0)?);
        }
        out
    };

    let now = crate::vault::now_unix_ms();
    for old_title in dup_titles {
        let group: Vec<(String, i64)> = {
            let mut stmt = tx.prepare(
                "SELECT id, created_at FROM notes WHERE title = ? ORDER BY created_at ASC, id ASC",
            )?;
            let mut rows = stmt.query([&old_title])?;
            let mut out = Vec::new();
            while let Some(r) = rows.next()? {
                out.push((r.get::<_, String>(0)?, r.get::<_, i64>(1)?));
            }
            out
        };
        // First note keeps the title; rename the rest.
        for (note_id, _) in group.into_iter().skip(1) {
            // Find the next available "<title> (N)" suffix.
            let mut n: i64 = 2;
            let new_title = loop {
                let candidate = format!("{old_title} ({n})");
                let taken: i64 = tx.query_row(
                    "SELECT COUNT(*) FROM notes WHERE title = ?",
                    [&candidate],
                    |r| r.get(0),
                )?;
                if taken == 0 {
                    break candidate;
                }
                n += 1;
            };
            tx.execute(
                "UPDATE notes SET title = ? WHERE id = ?",
                [&new_title as &dyn rusqlite::ToSql, &note_id],
            )?;
            tx.execute(
                "INSERT OR REPLACE INTO notes_dedup_log
                    (note_id, old_title, new_title, migrated_at) VALUES (?, ?, ?, ?)",
                rusqlite::params![note_id, old_title, new_title, now],
            )?;
            tracing::warn!(
                note_id = %note_id,
                old = %old_title,
                new = %new_title,
                "renamed duplicate-title note during v3 migration"
            );
        }
    }

    tx.execute_batch(V3_POST)?;
    tx.execute("INSERT INTO schema_version(version) VALUES (3)", [])?;
    tx.commit()?;
    Ok(())
}

pub fn current_version(conn: &Connection) -> Result<i64> {
    let v: i64 = conn
        .query_row("SELECT COALESCE(MAX(version), 0) FROM schema_version", [], |r| r.get(0))
        .unwrap_or(0);
    Ok(v)
}

/// Create the per-vault `chunk_vec` virtual table for the given embedding
/// dimension if it does not already exist. Idempotent.
pub fn ensure_vector_table(conn: &Connection, dim: usize) -> Result<()> {
    let sql = format!(
        "CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec USING vec0(\n    chunk_id TEXT PRIMARY KEY,\n    embedding float[{dim}] distance_metric=cosine\n);"
    );
    conn.execute_batch(&sql)?;
    Ok(())
}
