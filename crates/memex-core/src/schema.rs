use rusqlite::Connection;

use crate::error::MemexError;
use crate::Result;

pub const APP_SCHEMA_VERSION: i64 = 6;

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

// V4 adds the canvas layer: named user-curated boards (`canvases`) and per-board
// note placements (`canvas_nodes`). Canvases never own edges — lines on a canvas
// are computed at read time from the `links` table, filtered to wikilinks whose
// from_note_id and to_note_id are both placed on the same canvas.
const V4: &str = r#"
CREATE TABLE IF NOT EXISTS canvases (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    version     INTEGER NOT NULL DEFAULT 1
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_canvases_title_unique ON canvases(title);
CREATE INDEX IF NOT EXISTS idx_canvases_updated_at ON canvases(updated_at DESC);

CREATE TABLE IF NOT EXISTS canvas_nodes (
    canvas_id   TEXT NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
    note_id     TEXT NOT NULL REFERENCES notes(id)    ON DELETE CASCADE,
    x           REAL NOT NULL,
    y           REAL NOT NULL,
    z_order     INTEGER NOT NULL DEFAULT 0,
    placed_at   INTEGER NOT NULL,
    PRIMARY KEY (canvas_id, note_id)
);

CREATE INDEX IF NOT EXISTS idx_canvas_nodes_note ON canvas_nodes(note_id);
"#;

// V5 adds daily notes, day review and Smart Folders (Spec #1): stable block
// identities (`blocks`), review state and its snapshot (`day_reviews`,
// `day_review_blocks`), footer chips linking a daily note to topics, the agent
// change log, Smart Folders with their memberships, and vault-wide settings.
// Every note-owned row cascades on note delete. `smart_folders.parent_id` has
// no ON DELETE action on purpose: callers re-parent children before deleting a
// folder, so deleting one that still has children fails. `footer_chips` stays a
// rowid table because the footer renders in rowid (insertion) order.
//
// `idx_notes_daily_title` allows one `role: daily` note per title. The CASE
// guard keeps a note with malformed frontmatter from raising a JSON error, both
// while the index is built over existing rows and on later writes.
//
// The `chunks` byte-range columns are added by `apply_v5` (ALTER TABLE ADD
// COLUMN is not idempotent); existing rows stay NULL until the next reindex.
const V5: &str = r#"
CREATE TABLE IF NOT EXISTS blocks (
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

CREATE INDEX IF NOT EXISTS idx_blocks_note_ord ON blocks(note_id, ord);

CREATE TABLE IF NOT EXISTS day_reviews (
    note_id                   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    content_version           INTEGER NOT NULL DEFAULT 0,
    reviewed_content_version  INTEGER NULL,
    reviewed_at               INTEGER NULL
);

CREATE TABLE IF NOT EXISTS day_review_blocks (
    note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    block_id      TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    text          TEXT NOT NULL,
    PRIMARY KEY (note_id, block_id)
);

CREATE TABLE IF NOT EXISTS footer_chips (
    daily_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    topic_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    origin         TEXT NOT NULL CHECK (origin IN ('excerpt','person')),
    created_at     INTEGER NOT NULL,
    PRIMARY KEY (daily_note_id, topic_note_id)
);

CREATE INDEX IF NOT EXISTS idx_footer_chips_topic ON footer_chips(topic_note_id);

CREATE TABLE IF NOT EXISTS agent_changes (
    id            TEXT PRIMARY KEY,
    note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    day           TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    bullets_json  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_changes_note ON agent_changes(note_id, created_at DESC);

CREATE TABLE IF NOT EXISTS smart_folders (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    parent_id   TEXT NULL REFERENCES smart_folders(id),
    pinned      INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_smart_folders_sibling_name
    ON smart_folders(COALESCE(parent_id, ''), name COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS smart_folder_members (
    smart_folder_id  TEXT NOT NULL REFERENCES smart_folders(id) ON DELETE CASCADE,
    note_id          TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    pinned           INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (smart_folder_id, note_id)
);

CREATE INDEX IF NOT EXISTS idx_smart_folder_members_note ON smart_folder_members(note_id);

CREATE TABLE IF NOT EXISTS vault_settings (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
);

INSERT OR IGNORE INTO vault_settings(key, value) VALUES ('smart_folder_max_depth', '2');

CREATE UNIQUE INDEX IF NOT EXISTS idx_notes_daily_title ON notes(title)
    WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'daily';
"#;

/// Nullable columns V5 adds to existing tables: (table, column, declaration).
const V5_COLUMNS: [(&str, &str, &str); 2] = [
    ("chunks", "start_byte", "INTEGER"),
    ("chunks", "end_byte", "INTEGER"),
];

// V6 adds tag origins and tag Corrections (Spec #234), Feedback and Vault
// Guide revisions (#233). The `tags` columns are added by `apply_v6` (ALTER
// TABLE ADD COLUMN is not idempotent). `tag_corrections` is created before
// `feedback`, which references it.
//
// A Correction outlives its note (ruling D7a): `tag_corrections.note_id` and
// the `feedback` links are ON DELETE SET NULL. Both `agent_change_id` columns
// are SET NULL too, never the default NO ACTION, because `agent_changes`
// cascades on note delete and a NO ACTION link would block the delete.
// `tag_corrections` uses AUTOINCREMENT so a deleted highest id is never
// reused (D4).
//
// `idx_notes_guide` allows one `role: guide` note per vault, with the same
// CASE guard as `idx_notes_daily_title`. Every statement is `IF NOT EXISTS`,
// so the V6 step can re-run over V6 tables.
const V6: &str = r#"
CREATE TABLE IF NOT EXISTS tag_corrections (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id     TEXT REFERENCES notes(id) ON DELETE SET NULL,
    note_title  TEXT NOT NULL,
    tag         TEXT NOT NULL,
    kind        TEXT NOT NULL CHECK (kind IN ('removed')),
    created_at  INTEGER NOT NULL,
    cleared_at  INTEGER
);

CREATE INDEX IF NOT EXISTS idx_tag_corrections_note ON tag_corrections(note_id, tag);

CREATE TABLE IF NOT EXISTS feedback (
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

CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status, created_at);
CREATE INDEX IF NOT EXISTS idx_feedback_note ON feedback(note_id, created_at);

CREATE TABLE IF NOT EXISTS vault_guide_revisions (
    id                TEXT PRIMARY KEY,
    note_id           TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    previous_md       TEXT NOT NULL,
    previous_version  INTEGER NOT NULL,
    new_version       INTEGER NOT NULL,
    agent_change_id   TEXT NULL REFERENCES agent_changes(id) ON DELETE SET NULL,
    created_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vault_guide_revisions_note
    ON vault_guide_revisions(note_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_notes_guide
    ON notes((CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END))
    WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'guide';
"#;

/// Columns V6 adds to existing tables: (table, column, declaration).
const V6_COLUMNS: [(&str, &str, &str); 2] = [
    (
        "tags",
        "origin",
        "TEXT NOT NULL DEFAULT 'person' CHECK (origin IN ('body','agent','person'))",
    ),
    ("tags", "first_line", "TEXT"),
];

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

    // v4: canvas layer (canvases, canvas_nodes). No data migration needed.
    {
        let tx = conn.transaction()?;
        let current: i64 = tx
            .query_row("SELECT COALESCE(MAX(version), 0) FROM schema_version", [], |r| r.get(0))
            .unwrap_or(0);
        if current < 4 {
            tx.execute_batch(V4)?;
            tx.execute("INSERT INTO schema_version(version) VALUES (4)", [])?;
        }
        tx.commit()?;
    }

    // v5: daily notes, review, Smart Folders. One transaction, guarded by the
    // version so a second apply() is a no-op. No data backfill.
    {
        let tx = conn.transaction()?;
        if current_version(&tx)? < 5 {
            apply_v5(&tx)?;
            tx.execute("INSERT INTO schema_version(version) VALUES (5)", [])?;
        }
        tx.commit()?;
    }

    // v6: tag origins, tag Corrections, Feedback, Vault Guide. One
    // transaction with the body-tag backfill, so any failure (two
    // `role: guide` notes, say) leaves the vault at V5 unchanged.
    {
        let tx = conn.transaction()?;
        if current_version(&tx)? < 6 {
            apply_v6(&tx)?;
            tx.execute("INSERT INTO schema_version(version) VALUES (6)", [])?;
        }
        tx.commit()?;
    }
    Ok(())
}

fn apply_v5(conn: &Connection) -> Result<()> {
    for (table, column, decl) in V5_COLUMNS {
        if !has_column(conn, table, column)? {
            conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {decl};"))?;
        }
    }
    conn.execute_batch(V5)?;
    Ok(())
}

fn apply_v6(conn: &Connection) -> Result<()> {
    // `idx_notes_guide` would fail on these anyway; name the problem first.
    let guides: i64 = conn.query_row(
        "SELECT COUNT(*) FROM notes
         WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'guide'",
        [],
        |r| r.get(0),
    )?;
    if guides > 1 {
        return Err(MemexError::GuideRule(format!(
            "schema V6 allows one role: guide note and this vault has {guides}; \
             keep one and delete the others with the previous memex, then open the vault again"
        )));
    }
    for (table, column, decl) in V6_COLUMNS {
        if !has_column(conn, table, column)? {
            conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {decl};"))?;
        }
    }
    // System tags become agent-origin before the backfill, so a system tag
    // the body also writes ends up body-origin (R9, R51).
    conn.execute(
        "UPDATE tags SET origin = 'agent' WHERE tag IN ('inbox', 'agent-authored')",
        [],
    )?;
    conn.execute_batch(V6)?;
    backfill_body_tags(conn)
}

/// Upserts a `body`-origin `tags` row, with its first line, for each `#name`
/// in the person section of every note except the Vault Guide (R50, R51).
/// Reads `notes` only: it never writes `notes`, `day_reviews` or `chunks`, and
/// needs no embedder. Re-running it over its own output changes nothing.
fn backfill_body_tags(conn: &Connection) -> Result<()> {
    let mut notes = conn.prepare("SELECT id, content_md, frontmatter FROM notes ORDER BY id")?;
    let mut upsert = conn.prepare(
        "INSERT INTO tags (note_id, tag, origin, first_line) VALUES (?1, ?2, 'body', ?3)
         ON CONFLICT(note_id, tag) DO UPDATE SET origin = 'body', first_line = excluded.first_line",
    )?;
    let mut rows = notes.query([])?;
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let body: String = row.get(1)?;
        let frontmatter: String = row.get(2)?;
        let frontmatter: serde_json::Value =
            serde_json::from_str(&frontmatter).unwrap_or(serde_json::Value::Null);
        if crate::notes::is_guide(&frontmatter) {
            continue;
        }
        let found = if crate::daily::is_daily(&frontmatter) {
            crate::tags::extract(&crate::daily::split_body(&body).person)
        } else {
            crate::tags::extract(crate::tags::person_section(&body))
        };
        for tag in found {
            upsert.execute(rusqlite::params![id, tag.name, tag.first_line])?;
        }
    }
    Ok(())
}

fn has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table, column],
        |r| r.get(0),
    )?;
    Ok(n > 0)
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
