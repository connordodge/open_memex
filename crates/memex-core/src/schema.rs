use rusqlite::Connection;

use crate::Result;

pub const APP_SCHEMA_VERSION: i64 = 2;

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

pub fn apply(conn: &mut Connection) -> Result<()> {
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
