use rusqlite::Connection;

use crate::Result;

pub const APP_SCHEMA_VERSION: i64 = 1;

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

pub fn apply(conn: &mut Connection) -> Result<()> {
    let tx = conn.transaction()?;
    let current: i64 = tx
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM (SELECT version FROM schema_version UNION ALL SELECT 0)",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if current < 1 {
        tx.execute_batch(V1)?;
        tx.execute("INSERT INTO schema_version(version) VALUES (1)", [])?;
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
