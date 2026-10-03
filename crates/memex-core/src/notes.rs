use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use ulid::Ulid;

use crate::caller::Caller;
use crate::error::MemexError;
use crate::vault::{now_unix_ms, Vault};
use crate::Result;

/// Stable, sortable note identifier (ULID, string-encoded as 26 chars Crockford base32).
#[derive(Debug, Clone, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct NoteId(String);

impl NoteId {
    pub fn new() -> Self {
        Self(Ulid::new().to_string())
    }

    pub fn parse(s: &str) -> Result<Self> {
        Ulid::from_str(s)
            .map_err(|_| MemexError::InvalidId(s.to_string()))?;
        Ok(Self(s.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for NoteId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for NoteId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Note {
    pub id: NoteId,
    pub title: String,
    pub content_md: String,
    pub frontmatter: serde_json::Value,
    pub version: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Default)]
pub struct CreateNote {
    pub title: Option<String>,
    pub content_md: String,
    pub frontmatter: Option<serde_json::Value>,
}

pub fn create_note(vault: &mut Vault, input: CreateNote) -> Result<Note> {
    create_note_as(vault, input, Caller::Person)
}

/// Creates a note on behalf of `caller` (architect ruling D3). Rules that
/// guard agent writes hang off `caller`; today both callers behave the same.
pub fn create_note_as(vault: &mut Vault, input: CreateNote, caller: Caller) -> Result<Note> {
    let _ = caller;
    let now = now_unix_ms();
    let id = NoteId::new();
    let frontmatter = input
        .frontmatter
        .unwrap_or_else(|| serde_json::json!({}));
    let title = input
        .title
        .unwrap_or_else(|| derive_title(&input.content_md));
    vault.conn().execute(
        "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)",
        params![
            id.as_str(),
            title,
            input.content_md,
            serde_json::to_string(&frontmatter)?,
            now,
            now,
        ],
    )?;
    Ok(Note {
        id,
        title,
        content_md: input.content_md,
        frontmatter,
        version: 1,
        created_at: now,
        updated_at: now,
    })
}

pub fn get_note(vault: &Vault, id: &NoteId) -> Result<Note> {
    let mut stmt = vault
        .conn()
        .prepare(
            "SELECT id, title, content_md, frontmatter, version, created_at, updated_at
             FROM notes WHERE id = ?",
        )?;
    let mut rows = stmt.query(params![id.as_str()])?;
    let row = rows
        .next()?
        .ok_or_else(|| MemexError::NotFound(format!("note {}", id.as_str())))?;
    Ok(row_to_note(row)?)
}

pub fn list_notes(vault: &Vault, limit: i64) -> Result<Vec<Note>> {
    let mut stmt = vault.conn().prepare(
        "SELECT id, title, content_md, frontmatter, version, created_at, updated_at
         FROM notes ORDER BY updated_at DESC LIMIT ?",
    )?;
    let mut rows = stmt.query(params![limit])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        out.push(row_to_note(r)?);
    }
    Ok(out)
}

#[derive(Debug, Clone, Default)]
pub struct UpdateNote {
    pub title: Option<String>,
    pub content_md: Option<String>,
    pub frontmatter: Option<serde_json::Value>,
}

#[derive(Debug, Clone)]
pub struct RenameOptions {
    /// When `true` (default), a title change rewrites every linker's
    /// `[[OldTitle]]` / `[[OldTitle~kind]]` / `[[OldTitle|alias]]` /
    /// `[[OldTitle~kind|alias]]` to use the new title, transactionally.
    pub rename_links: bool,
}

impl Default for RenameOptions {
    fn default() -> Self {
        Self { rename_links: true }
    }
}

const MAX_TITLE_LEN: usize = 200;

pub fn update_note(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    patch: UpdateNote,
) -> Result<Note> {
    update_note_with_options(vault, id, expected_version, patch, RenameOptions::default())
}

pub fn update_note_with_options(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    patch: UpdateNote,
    options: RenameOptions,
) -> Result<Note> {
    update_note_as(vault, id, expected_version, patch, options, Caller::Person)
}

/// Updates a note on behalf of `caller` (architect ruling D3). Every save
/// path (including `links::update_link_as`) goes through here, so a rule
/// added for agent writes guards them all; today both callers behave the same.
pub fn update_note_as(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    patch: UpdateNote,
    options: RenameOptions,
    caller: Caller,
) -> Result<Note> {
    let _ = caller;
    // Read current state up front so we can validate before opening a tx.
    let current_row: Option<(i64, String, String, String)> = vault
        .connection_ref()
        .query_row(
            "SELECT version, title, content_md, frontmatter FROM notes WHERE id = ?",
            params![id.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other),
        })?;
    let (current_version, current_title, current_content, current_fm) = current_row
        .ok_or_else(|| MemexError::NotFound(format!("note {}", id.as_str())))?;
    if current_version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current_version,
        });
    }

    let new_title = patch.title.clone().unwrap_or(current_title.clone());
    let new_content = patch.content_md.clone().unwrap_or(current_content.clone());
    let new_fm: serde_json::Value = match patch.frontmatter {
        Some(v) => v,
        None => serde_json::from_str(&current_fm)?,
    };
    let title_changed = new_title != current_title;

    if title_changed {
        validate_title(&new_title)?;
        let collision: Option<String> = vault
            .connection_ref()
            .query_row(
                "SELECT id FROM notes WHERE title = ? AND id != ?",
                params![new_title, id.as_str()],
                |r| r.get(0),
            )
            .ok();
        if let Some(existing) = collision {
            return Err(MemexError::TitleConflict {
                existing_id: existing,
                attempted_title: new_title,
            });
        }
    }

    let now = now_unix_ms();
    let new_version = current_version + 1;
    // (linker_id, new_content) — populated in the rewrite pass and reindexed
    // after the transaction commits.
    let mut linker_rewrites: Vec<(String, String)> = Vec::new();

    {
        let tx = vault.conn_mut().transaction()?;

        if title_changed && options.rename_links {
            let linker_ids: Vec<String> = {
                let mut stmt = tx.prepare(
                    "SELECT DISTINCT from_note_id FROM links WHERE to_note_id = ?",
                )?;
                let rows = stmt
                    .query_map(params![id.as_str()], |r| r.get::<_, String>(0))?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            };

            // Match `[[OldTitle]]`, `[[OldTitle~kind]]`, `[[OldTitle|alias]]`,
            // `[[OldTitle~kind|alias]]`. Capture the optional suffix so we can
            // preserve kind + alias.
            let escaped_old = regex::escape(&current_title);
            let pattern = format!(
                r"\[\[{escaped}(?P<rest>(?:~[^\[\]\n|]+)?(?:\|[^\[\]\n]+)?)\]\]",
                escaped = escaped_old
            );
            let rewriter = regex::Regex::new(&pattern).expect("compile rename regex");
            let replacement = format!("[[{new_title}${{rest}}]]");

            for linker_id in linker_ids {
                if linker_id == id.as_str() {
                    continue;
                }
                let linker_content: String = tx.query_row(
                    "SELECT content_md FROM notes WHERE id = ?",
                    params![linker_id],
                    |r| r.get(0),
                )?;
                let rewritten = rewriter
                    .replace_all(&linker_content, replacement.as_str())
                    .to_string();
                if rewritten != linker_content {
                    tx.execute(
                        "UPDATE notes SET content_md = ?, updated_at = ? WHERE id = ?",
                        params![rewritten, now, linker_id],
                    )?;
                    linker_rewrites.push((linker_id.clone(), rewritten));
                }
            }
        }

        tx.execute(
            "UPDATE notes SET title = ?, content_md = ?, frontmatter = ?, version = ?, updated_at = ?
             WHERE id = ?",
            params![
                new_title,
                new_content,
                serde_json::to_string(&new_fm)?,
                new_version,
                now,
                id.as_str(),
            ],
        )?;
        tx.commit()?;
    }

    // After commit: reindex each rewritten linker so their `links` rows reflect
    // the new content. The source note itself is reindexed by the caller (the
    // existing convention in this codebase).
    for (linker_id, linker_content) in &linker_rewrites {
        crate::indexer::reindex_note(vault.conn_mut(), linker_id, linker_content, None)?;
    }

    get_note(vault, id)
}

fn validate_title(t: &str) -> Result<()> {
    let trimmed = t.trim();
    if trimmed.is_empty() {
        return Err(MemexError::TitleInvalid("title cannot be empty".into()));
    }
    if trimmed.len() != t.len() {
        return Err(MemexError::TitleInvalid(
            "title cannot have leading or trailing whitespace".into(),
        ));
    }
    if t.chars().count() > MAX_TITLE_LEN {
        return Err(MemexError::TitleInvalid(format!(
            "title too long ({} chars, max {})",
            t.chars().count(),
            MAX_TITLE_LEN
        )));
    }
    if t.contains('|') || t.contains('~') || t.contains(']') || t.contains('\n') {
        return Err(MemexError::TitleInvalid(format!(
            "title contains a forbidden character (|, ~, ], or newline): {t}"
        )));
    }
    Ok(())
}

pub fn delete_note(vault: &mut Vault, id: &NoteId) -> Result<()> {
    let n = vault
        .conn()
        .execute("DELETE FROM notes WHERE id = ?", params![id.as_str()])?;
    if n == 0 {
        return Err(MemexError::NotFound(format!("note {}", id.as_str())));
    }
    Ok(())
}

fn row_to_note(r: &rusqlite::Row<'_>) -> rusqlite::Result<Note> {
    let id_s: String = r.get(0)?;
    let title: String = r.get(1)?;
    let content_md: String = r.get(2)?;
    let fm_s: String = r.get(3)?;
    let version: i64 = r.get(4)?;
    let created_at: i64 = r.get(5)?;
    let updated_at: i64 = r.get(6)?;
    let frontmatter: serde_json::Value =
        serde_json::from_str(&fm_s).map_err(|e| rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e)))?;
    Ok(Note {
        id: NoteId(id_s),
        title,
        content_md,
        frontmatter,
        version,
        created_at,
        updated_at,
    })
}

fn derive_title(content: &str) -> String {
    let first_line = content.lines().next().unwrap_or("Untitled").trim();
    let stripped = first_line.trim_start_matches('#').trim();
    if stripped.is_empty() {
        "Untitled".to_string()
    } else {
        stripped.chars().take(120).collect()
    }
}
