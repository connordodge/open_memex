use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use ulid::Ulid;

use crate::caller::Caller;
use crate::canvas::{Clock, SystemClock};
use crate::daily;
use crate::error::MemexError;
use crate::tags;
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

/// Creates a note on behalf of `caller` (architect ruling D3), reading the
/// time from the system clock. See [`create_or_adopt_note`].
pub fn create_note_as(vault: &mut Vault, input: CreateNote, caller: Caller) -> Result<Note> {
    create_or_adopt_note(vault, input, caller, &SystemClock).map(|outcome| outcome.note)
}

/// What [`create_or_adopt_note`] did.
#[derive(Debug, Clone)]
pub struct CreateOutcome {
    /// The created or adopted note, as stored.
    pub note: Note,
    /// `true` when a person-path daily create adopted an existing role-less
    /// note titled with the date (Q2) instead of creating one.
    pub adopted: bool,
}

/// Creates a note on behalf of `caller` (architect ruling D3).
///
/// A title that is already taken fails with `TitleConflict` naming the
/// existing note. A `role: daily` note (D15) defaults its title to today in
/// local time (D14), needs an ISO `YYYY-MM-DD` title (`InvalidDate`), and fails
/// with `DailyNoteExists` when that date already has a daily note. On the
/// person path it adopts a role-less note titled with the date (Q2): that note
/// gains `role: daily`, keeps its id and content, and gets `content_md`
/// appended with the C3.1 separator. Its body is stored in the canonical daily
/// layout with its blocks and `day_reviews` row, in one transaction (D9).
/// A person's body, unless the note is `role: guide`, gets its body tags in that
/// transaction; an agent's isn't scanned (Spec #234 R3).
pub fn create_or_adopt_note(
    vault: &mut Vault,
    input: CreateNote,
    caller: Caller,
    clock: &dyn Clock,
) -> Result<CreateOutcome> {
    let frontmatter = input.frontmatter.unwrap_or_else(|| serde_json::json!({}));
    let is_daily = daily::is_daily(&frontmatter);
    let title = match input.title {
        Some(title) => title,
        None if is_daily => daily::today_with_clock(clock).to_string(),
        None => derive_title(&input.content_md),
    };
    if is_daily {
        daily::parse_iso_date(&title)?;
    }
    if let Some((existing_id, existing_fm)) = note_titled(vault.connection_ref(), &title, None)? {
        if is_daily && daily::is_daily(&existing_fm) {
            return Err(MemexError::DailyNoteExists {
                date: title,
                existing_id,
            });
        }
        if is_daily && caller == Caller::Person && is_role_less(&existing_fm) {
            let note = adopt_as_daily(vault, &existing_id, existing_fm, &input.content_md)?;
            return Ok(CreateOutcome {
                note,
                adopted: true,
            });
        }
        return Err(MemexError::TitleConflict {
            existing_id,
            attempted_title: title,
        });
    }

    let now = clock.now_ms();
    let id = NoteId::new();
    let tx = vault.conn_mut().transaction()?;
    tx.execute(
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
    if caller == Caller::Person && !is_guide(&frontmatter) {
        tags::reconcile_body_tags(&tx, id.as_str(), &input.content_md, is_daily, now)?;
    }
    let content_md = if is_daily {
        let source = daily::block_source(caller);
        let body =
            daily::sync_daily_note(&tx, id.as_str(), "", &input.content_md, source, 1, now)?;
        tx.execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            params![body, id.as_str()],
        )?;
        body
    } else {
        input.content_md
    };
    tx.commit()?;
    let note = Note {
        id,
        title,
        content_md,
        frontmatter,
        version: 1,
        created_at: now,
        updated_at: now,
    };
    Ok(CreateOutcome {
        note,
        adopted: false,
    })
}

/// Q2: turns the role-less note `existing_id` into the daily note for its
/// title. Its frontmatter gains `role: daily`; non-empty `content` (trailing
/// whitespace trimmed) is appended to its person section with the C3.1
/// separator; the save runs the daily write hook like any person update.
fn adopt_as_daily(
    vault: &mut Vault,
    existing_id: &str,
    mut frontmatter: serde_json::Value,
    content: &str,
) -> Result<Note> {
    let id = NoteId::parse(existing_id)?;
    let current = get_note(vault, &id)?;
    let mut person = daily::split_body(&current.content_md).person;
    let text = content.trim_end();
    if !text.trim_start().is_empty() {
        person = daily::append_to_person(&person, text);
    }
    frontmatter["role"] = "daily".into();
    let patch = UpdateNote {
        title: None,
        content_md: Some(person),
        frontmatter: Some(frontmatter),
    };
    update_note_as(
        vault,
        &id,
        current.version,
        patch,
        RenameOptions::default(),
        Caller::Person,
    )
}

/// The note titled `title` (other than `excluding`), as `(id, frontmatter)`.
/// Frontmatter that is not valid JSON reads as `null`.
fn note_titled(
    conn: &rusqlite::Connection,
    title: &str,
    excluding: Option<&str>,
) -> Result<Option<(String, serde_json::Value)>> {
    let found = conn.query_row(
        "SELECT id, frontmatter FROM notes WHERE title = ? AND id IS NOT ?",
        params![title, excluding],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
    );
    match found {
        Ok((id, fm)) => Ok(Some((id, lenient_frontmatter(&fm)))),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Parses stored frontmatter, reading malformed JSON as `null`.
pub(crate) fn lenient_frontmatter(stored: &str) -> serde_json::Value {
    serde_json::from_str(stored).unwrap_or(serde_json::Value::Null)
}

/// A note Q2 may adopt: a frontmatter object without a `role`.
fn is_role_less(frontmatter: &serde_json::Value) -> bool {
    frontmatter
        .as_object()
        .is_some_and(|fm| fm.get("role").is_none_or(serde_json::Value::is_null))
}

/// Whether `frontmatter` marks the Vault Guide: `role` is exactly `guide`
/// (#233, ruling D6).
pub fn is_guide(frontmatter: &serde_json::Value) -> bool {
    frontmatter.get("role").and_then(|r| r.as_str()) == Some("guide")
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

/// The marker guard (Req 16 / Req 75, D3): an agent may not write a note that
/// is `role: daily` (`current_frontmatter`), nor make a note `role: daily`
/// (`new_frontmatter`, the frontmatter the write would store). Either is
/// `MarkerRule`; person writes always pass. `update_note_as` runs it on every
/// save, and an agent path that answers without saving (MCP `add_link` on an
/// existing link) runs it on the source note first.
pub fn check_agent_write(
    caller: Caller,
    current_frontmatter: &serde_json::Value,
    new_frontmatter: Option<&serde_json::Value>,
) -> Result<()> {
    if caller != Caller::Agent {
        return Ok(());
    }
    if daily::is_daily(current_frontmatter) {
        return Err(MemexError::MarkerRule(
            "agents may not edit a daily note".into(),
        ));
    }
    if new_frontmatter.is_some_and(daily::is_daily) {
        return Err(MemexError::MarkerRule(
            "agents may not make a note a daily note (role: daily)".into(),
        ));
    }
    Ok(())
}

/// Updates a note on behalf of `caller` (architect ruling D3). Every save
/// path (including `links::update_link_as`) goes through here, so a rule
/// added for agent writes guards them all.
///
/// A note that is (or becomes) `role: daily` keeps an ISO title (`InvalidDate`,
/// and `DailyNoteExists` when retitled onto another day's daily note) and runs
/// the daily write hook (D9) in the save transaction: its body is stored
/// normalized, its blocks are re-synced (new ones stamped with the caller's
/// source) and its content version is bumped when the person text changed.
/// Any other note but a `role: guide` one stores its person section with the
/// Note footer rendered from its rows (Spec #234 R14); a guide's body is
/// stored as given. A person's patch with a body re-derives the note's body
/// tags in the save transaction, unless the note is a guide (R3); no other
/// save scans. A note becoming a guide loses its tag rows, chips and footer in
/// that save, whoever writes it (R53). Daily notes rewritten by the rename pass are re-synced
/// the same way and also get a new `version`; other linkers get their footer
/// re-rendered. Callers reindex from the returned note (D8).
pub fn update_note_as(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    patch: UpdateNote,
    options: RenameOptions,
    caller: Caller,
) -> Result<Note> {
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
    // The marker guard wins over a stale version: an agent retry can't help.
    check_agent_write(
        caller,
        &lenient_frontmatter(&current_fm),
        patch.frontmatter.as_ref(),
    )?;
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
    let is_daily = daily::is_daily(&new_fm);
    let becomes_daily = is_daily && !daily::is_daily(&lenient_frontmatter(&current_fm));
    let guide = is_guide(&new_fm);
    let becomes_guide = guide && !is_guide(&lenient_frontmatter(&current_fm));
    let derives_tags = caller == Caller::Person && patch.content_md.is_some() && !guide;

    if title_changed {
        validate_title(&new_title)?;
    }
    if is_daily && (title_changed || becomes_daily) {
        daily::parse_iso_date(&new_title)?;
    }
    if title_changed {
        let collision = note_titled(vault.connection_ref(), &new_title, Some(id.as_str()))?;
        if let Some((existing_id, existing_fm)) = collision {
            if is_daily && daily::is_daily(&existing_fm) {
                return Err(MemexError::DailyNoteExists {
                    date: new_title,
                    existing_id,
                });
            }
            return Err(MemexError::TitleConflict {
                existing_id,
                attempted_title: new_title,
            });
        }
    }

    let now = now_unix_ms();
    let new_version = current_version + 1;
    let source = daily::block_source(caller);
    // (linker_id, new_content) — populated in the rewrite pass and reindexed
    // after the transaction commits.
    let mut linker_rewrites: Vec<(String, String)> = Vec::new();

    {
        let tx = vault.conn_mut().transaction()?;

        // Tag rows first: the footer below renders from them.
        if derives_tags {
            tags::reconcile_body_tags(&tx, id.as_str(), &new_content, is_daily, now)?;
        }
        if becomes_guide {
            tags::clear_guide_rows(&tx, id.as_str())?;
        }

        // The note itself first, so a linker's footer below renders the new
        // title. Every note but a guide keeps the footer rendered from its
        // rows (Spec #234 R14, D3).
        let saved_content = if is_daily {
            daily::sync_daily_note(
                &tx,
                id.as_str(),
                &current_content,
                &new_content,
                source,
                new_version,
                now,
            )?
        } else if becomes_guide {
            daily::split_note_body(&new_content).person
        } else if guide {
            new_content
        } else {
            daily::sync_note_footer(&tx, id.as_str(), &new_content)?
        };
        tx.execute(
            "UPDATE notes SET title = ?, content_md = ?, frontmatter = ?, version = ?, updated_at = ?
             WHERE id = ?",
            params![
                new_title,
                saved_content,
                serde_json::to_string(&new_fm)?,
                new_version,
                now,
                id.as_str(),
            ],
        )?;

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
                let (linker_content, linker_version, linker_fm): (String, i64, String) = tx
                    .query_row(
                        "SELECT content_md, version, frontmatter FROM notes WHERE id = ?",
                        params![linker_id],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                    )?;
                let rewritten = rewriter
                    .replace_all(&linker_content, replacement.as_str())
                    .to_string();
                if rewritten == linker_content {
                    continue;
                }
                let linker_fm = lenient_frontmatter(&linker_fm);
                if daily::is_daily(&linker_fm) {
                    // A daily linker is re-synced and gets a new version, so
                    // an open editor sees a conflict and merges (D9).
                    let version = linker_version + 1;
                    let body = daily::sync_daily_note(
                        &tx,
                        &linker_id,
                        &linker_content,
                        &rewritten,
                        source,
                        version,
                        now,
                    )?;
                    tx.execute(
                        "UPDATE notes SET content_md = ?, version = ?, updated_at = ? WHERE id = ?",
                        params![body, version, now, linker_id],
                    )?;
                    linker_rewrites.push((linker_id.clone(), body));
                } else {
                    // A non-guide linker keeps its body text above the marker
                    // and the footer re-rendered from rows below it (R15).
                    let body = if is_guide(&linker_fm) {
                        rewritten
                    } else {
                        daily::sync_note_footer(&tx, &linker_id, &rewritten)?
                    };
                    tx.execute(
                        "UPDATE notes SET content_md = ?, updated_at = ? WHERE id = ?",
                        params![body, now, linker_id],
                    )?;
                    linker_rewrites.push((linker_id.clone(), body));
                }
            }
        }

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

/// The only bypass of the agent guards on a daily note's body (architect
/// ruling D9): append (#12) and footer writes (#8). Runs the same
/// normalization and block sync as `update_note_as`, stamping new blocks with
/// `block_source` (`person`, `agent` or `quick-entry`), and fails with
/// `VersionConflict` on a stale `expected_version` so callers can retry.
/// A note that is not `role: daily` fails with `RoleRule`. The caller
/// reindexes from the returned note (D8). It leaves body tags alone; see
/// [`append_daily_internal`].
pub(crate) fn write_daily_internal(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    new_body: &str,
    block_source: &str,
) -> Result<Note> {
    write_daily(vault, id, expected_version, new_body, block_source, false)
}

/// [`write_daily_internal`] for an append, which also re-derives the note's
/// body tags in the write transaction: an append is the person's verbatim
/// words, whichever surface carries them (Spec #234 R3).
pub(crate) fn append_daily_internal(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    new_body: &str,
    block_source: &str,
) -> Result<Note> {
    write_daily(vault, id, expected_version, new_body, block_source, true)
}

fn write_daily(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    new_body: &str,
    block_source: &str,
    derives_tags: bool,
) -> Result<Note> {
    let current = get_note(vault, id)?;
    if current.version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current.version,
        });
    }
    if !daily::is_daily(&current.frontmatter) {
        return Err(MemexError::RoleRule(format!(
            "note {id} is not a daily note (role: daily)"
        )));
    }
    let now = now_unix_ms();
    let new_version = current.version + 1;
    let tx = vault.conn_mut().transaction()?;
    if derives_tags {
        tags::reconcile_body_tags(&tx, id.as_str(), new_body, true, now)?;
    }
    let body = daily::sync_daily_note(
        &tx,
        id.as_str(),
        &current.content_md,
        new_body,
        block_source,
        new_version,
        now,
    )?;
    tx.execute(
        "UPDATE notes SET content_md = ?, version = ?, updated_at = ? WHERE id = ?",
        params![body, new_version, now, id.as_str()],
    )?;
    tx.commit()?;
    get_note(vault, id)
}

/// The non-daily counterpart of [`write_daily_internal`] for footer writes
/// (Spec #234 TD5): re-renders the Note footer of `id` from its rows below
/// its current person section, adding the marker with the first footer item
/// and removing it with the last (R11). The note gets a new `version` and
/// `updated_at` even when the body is unchanged. Fails with `VersionConflict`
/// on a stale `expected_version`, `RoleRule` on a daily note and `GuideRule`
/// on a guide (D3). The caller reindexes from the returned note (D8).
pub(crate) fn write_note_footer_internal(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
) -> Result<Note> {
    let current = get_note(vault, id)?;
    if current.version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current.version,
        });
    }
    if daily::is_daily(&current.frontmatter) {
        return Err(MemexError::RoleRule(format!(
            "note {id} is a daily note: its footer is written by write_daily_internal"
        )));
    }
    if is_guide(&current.frontmatter) {
        return Err(MemexError::GuideRule(format!(
            "note {id} is the Vault Guide (role: guide), which has no Note footer"
        )));
    }
    let tx = vault.conn_mut().transaction()?;
    let body = daily::sync_note_footer(&tx, id.as_str(), &current.content_md)?;
    tx.execute(
        "UPDATE notes SET content_md = ?, version = ?, updated_at = ? WHERE id = ?",
        params![body, current.version + 1, now_unix_ms(), id.as_str()],
    )?;
    tx.commit()?;
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

/// Deletes a note on the person path (`memex rm`, architect ruling D24):
/// checks `expected_version` (`VersionConflict`), purges the note's search
/// indexes before the delete, deletes it (its blocks, review rows, chips,
/// change entries and memberships cascade) and re-renders, then reindexes
/// with `embedder`, the footer of every note that held a chip for it, daily
/// or not (Spec #234 TD5); a guide is left as it is (D3). An unknown id is
/// `NotFound`.
pub fn delete_note_checked(
    vault: &mut Vault,
    id: &NoteId,
    expected_version: i64,
    embedder: Option<&dyn crate::embedder::Embedder>,
) -> Result<()> {
    let current = get_note(vault, id)?;
    if current.version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current.version,
        });
    }
    // Collected before the delete: the chips cascade away with the note.
    let hosts: Vec<String> = {
        let mut stmt = vault.connection_ref().prepare(
            "SELECT daily_note_id FROM footer_chips WHERE topic_note_id = ? ORDER BY rowid",
        )?;
        let rows = stmt.query_map([id.as_str()], |r| r.get(0))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    // The purge reads the note's `chunks`, which the delete cascades away.
    crate::indexer::purge_note_indexes(vault.conn_mut(), id.as_str())?;
    delete_note(vault, id)?;
    for host_id in hosts {
        crate::footer::rerender_footer(vault, &NoteId(host_id), embedder)?;
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
