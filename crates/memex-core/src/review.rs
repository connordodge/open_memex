//! Review.
//!
//! The agent's review workflow over daily notes (Req 19, 21, 22, 24, 25, 26):
//! which days still need a review, what changed in a day since its review
//! snapshot (through `blocks::diff`, D12), and recording a review with its
//! change entries in one transaction. The review state itself always comes
//! from `daily::review_state`; nothing here recomputes it.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use ulid::Ulid;

use crate::blocks::{self, Block, SnapshotBlock};
use crate::canvas::Clock;
use crate::daily::{self, ReviewState};
use crate::error::MemexError;
use crate::notes::Note;
use crate::vault::Vault;
use crate::Result;

/// Most bullets one change entry may carry (Req 21).
const MAX_BULLETS: usize = 3;
/// Most characters (Unicode scalar values) one bullet may have (Req 21).
const MAX_BULLET_CHARS: usize = 200;
/// The markdown list prefix a bullet must not start with (Req 21).
const LIST_PREFIX: &str = "- ";

/// The SQL condition selecting daily notes: the expression of the partial
/// unique index `idx_notes_daily_title`, which matches `daily::is_daily`
/// (`role` is exactly `daily`).
const DAILY_NOTE: &str =
    "CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'daily'";

/// A daily note whose state is not `Reviewed` (Req 25).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreviewedDay {
    /// The daily note's date (its title), `YYYY-MM-DD`.
    pub date: String,
    pub note_id: String,
    /// `Unreviewed` or `ChangedSinceReview`, from `daily::review_state`.
    pub state: ReviewState,
    pub content_version: i64,
    /// `None` when the day was never reviewed.
    pub reviewed_content_version: Option<i64>,
}

/// The blocks of a daily note that changed since its review snapshot (Req 26),
/// computed by `blocks::diff` (D12).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DailyNoteChanges {
    pub date: String,
    pub note_id: String,
    /// The current content version: the `version` to pass to
    /// [`mark_day_reviewed`].
    pub content_version: i64,
    pub added: Vec<Block>,
    pub changed: Vec<Block>,
    /// Snapshot blocks gone from the note, with their snapshot text.
    pub removed: Vec<SnapshotBlock>,
}

/// One change entry of [`mark_day_reviewed`] (Req 21): the note touched and
/// 1 to 3 one-line bullets saying what the agent did there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChangeEntry {
    pub note_id: String,
    pub bullets: Vec<String>,
}

/// A daily note's review record after [`mark_day_reviewed`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayReview {
    pub date: String,
    pub note_id: String,
    pub state: ReviewState,
    pub content_version: i64,
    pub reviewed_content_version: Option<i64>,
    pub reviewed_at: Option<i64>,
}

/// Every daily note whose state is `Unreviewed` or `Changed since review` and
/// whose person section is not empty or whitespace only, oldest date first
/// (Req 25).
pub fn list_unreviewed_days(vault: &Vault) -> Result<Vec<UnreviewedDay>> {
    let conn = vault.connection_ref();
    let mut stmt = conn.prepare(&format!(
        "SELECT id, title, content_md FROM notes WHERE {DAILY_NOTE} ORDER BY title"
    ))?;
    let notes = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<rusqlite::Result<Vec<(String, String, String)>>>()?;
    let mut days = Vec::new();
    for (note_id, date, content_md) in notes {
        if daily::split_body(&content_md).person.trim().is_empty() {
            continue;
        }
        let state = daily::review_state(conn, &note_id)?;
        if state == ReviewState::Reviewed {
            continue;
        }
        let (content_version, reviewed_content_version, _) = review_row(conn, &note_id)?;
        days.push(UnreviewedDay {
            date,
            note_id,
            state,
            content_version,
            reviewed_content_version,
        });
    }
    Ok(days)
}

/// The day's current content version and its blocks diffed against the review
/// snapshot (Req 26). `InvalidDate` for a malformed date, `NotFound` when the
/// date has no daily note.
pub fn get_daily_note_changes(vault: &Vault, date: &str) -> Result<DailyNoteChanges> {
    let conn = vault.connection_ref();
    let note_id = daily_note_id(conn, date)?;
    let (content_version, _, _) = review_row(conn, &note_id)?;
    let diff = blocks::diff(
        &snapshot_blocks(conn, &note_id)?,
        &daily::stored_blocks(conn, &note_id)?.0,
    );
    Ok(DailyNoteChanges {
        date: date.to_string(),
        note_id,
        content_version,
        added: diff.added,
        changed: diff.changed,
        removed: diff.removed,
    })
}

/// Records a review of the day (Req 21, 22): strict content version check
/// (`ReviewStale`), change-entry validation (`ChangeEntriesInvalid`), then in
/// one transaction replaces the snapshot, updates `day_reviews` and appends
/// one `agent_changes` row per entry, with times from `clock` (D14).
///
/// `version` must equal the current content version: an older or a newer one
/// is stale. Every check runs inside the transaction before its first write,
/// so a rejected call writes nothing.
pub fn mark_day_reviewed(
    vault: &mut Vault,
    date: &str,
    version: i64,
    changes: &[ChangeEntry],
    clock: &dyn Clock,
) -> Result<DayReview> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let note_id = daily_note_id(&tx, date)?;
    let (current, _, _) = review_row(&tx, &note_id)?;
    if version != current {
        return Err(MemexError::ReviewStale { version, current });
    }
    validate_entries(&tx, &note_id, changes)?;

    let now = clock.now_ms();
    tx.execute(
        "INSERT INTO day_reviews (note_id, content_version, reviewed_content_version, reviewed_at)
         VALUES (?1, ?2, ?2, ?3)
         ON CONFLICT (note_id) DO UPDATE
         SET reviewed_content_version = excluded.reviewed_content_version,
             reviewed_at = excluded.reviewed_at",
        params![note_id, version, now],
    )?;
    tx.execute(
        "DELETE FROM day_review_blocks WHERE note_id = ?",
        [&note_id],
    )?;
    tx.execute(
        "INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
         SELECT note_id, block_id, content_hash, text FROM blocks
         WHERE note_id = ? ORDER BY ord",
        [&note_id],
    )?;
    for entry in changes {
        insert_agent_change(&tx, &entry.note_id, date, now, &entry.bullets)?;
    }
    tx.commit()?;

    let conn = vault.connection_ref();
    let (content_version, reviewed_content_version, reviewed_at) = review_row(conn, &note_id)?;
    Ok(DayReview {
        date: date.to_string(),
        state: daily::review_state(conn, &note_id)?,
        note_id,
        content_version,
        reviewed_content_version,
        reviewed_at,
    })
}

/// Review fields merged into the top level of MCP `get_note` and CLI
/// `memex get` (architect ruling D7, Req 24). A daily note gets `review`
/// (`state`, `content_version`, `reviewed_content_version`, `reviewed_at`)
/// and `latest_change` (its newest `agent_changes` row as `day`, `created_at`
/// and `bullets`, or null); any other note gets neither key.
pub fn note_review_fields(vault: &Vault, note: &Note) -> Result<Map<String, Value>> {
    let mut fields = Map::new();
    if !daily::is_daily(&note.frontmatter) {
        return Ok(fields);
    }
    let conn = vault.connection_ref();
    let note_id = note.id.as_str();
    let (content_version, reviewed_content_version, reviewed_at) = review_row(conn, note_id)?;
    fields.insert(
        "review".into(),
        json!({
            "state": daily::review_state(conn, note_id)?.as_str(),
            "content_version": content_version,
            "reviewed_content_version": reviewed_content_version,
            "reviewed_at": reviewed_at,
        }),
    );
    fields.insert("latest_change".into(), latest_change(conn, note_id)?);
    Ok(fields)
}

/// Checks change entries (Req 21) before anything is written, without tying
/// them to a reviewed day: each entry has 1 to 3 bullets; each bullet is one
/// line of at most 200 characters without a leading `- `; no note has two
/// entries. A broken rule fails with `ChangeEntriesInvalid` stating it; an
/// entry naming a note that does not exist fails with `NotFound`.
pub(crate) fn validate_change_entries(conn: &Connection, changes: &[ChangeEntry]) -> Result<()> {
    let notes = check_entry_rules(changes)?;
    check_entry_notes_exist(conn, notes)
}

/// Appends one `agent_changes` row and returns its id. `conn` may be a
/// transaction. The only writer of that table.
pub(crate) fn insert_agent_change(
    conn: &Connection,
    note_id: &str,
    day: &str,
    now_ms: i64,
    bullets: &[String],
) -> Result<String> {
    let id = Ulid::new().to_string();
    conn.execute(
        "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
         VALUES (?, ?, ?, ?, ?)",
        params![id, note_id, day, now_ms, serde_json::to_string(bullets)?],
    )?;
    Ok(id)
}

/// The id of the daily note for `date`: `InvalidDate` unless `date` is a
/// strict `YYYY-MM-DD` calendar date, `NotFound` when no daily note has that
/// title (a role-less note titled with the date does not count).
fn daily_note_id(conn: &Connection, date: &str) -> Result<String> {
    daily::daily_note_for_date(conn, daily::parse_iso_date(date)?)?
        .ok_or_else(|| MemexError::NotFound(format!("no daily note for {date}")))
}

/// `(content_version, reviewed_content_version, reviewed_at)` of the note's
/// `day_reviews` row. A daily note without a row (the daily write hook creates
/// it lazily) reads as `(0, None, None)`, which `daily::review_state` also
/// reads as `Unreviewed`.
fn review_row(conn: &Connection, note_id: &str) -> Result<(i64, Option<i64>, Option<i64>)> {
    let row = conn
        .query_row(
            "SELECT content_version, reviewed_content_version, reviewed_at
             FROM day_reviews WHERE note_id = ?",
            [note_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    Ok(row.unwrap_or((0, None, None)))
}

/// The note's review snapshot, in the block order it was taken in.
fn snapshot_blocks(conn: &Connection, note_id: &str) -> Result<Vec<SnapshotBlock>> {
    let mut stmt = conn.prepare(
        "SELECT block_id, content_hash, text FROM day_review_blocks
         WHERE note_id = ? ORDER BY rowid",
    )?;
    let snapshot = stmt
        .query_map([note_id], |r| {
            Ok(SnapshotBlock {
                block_id: r.get(0)?,
                content_hash: r.get(1)?,
                text: r.get(2)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;
    Ok(snapshot)
}

/// The note's newest `agent_changes` row as `{day, created_at, bullets}`, or
/// null when it has none.
fn latest_change(conn: &Connection, note_id: &str) -> Result<Value> {
    let row: Option<(String, i64, String)> = conn
        .query_row(
            "SELECT day, created_at, bullets_json FROM agent_changes
             WHERE note_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
            [note_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let Some((day, created_at, bullets_json)) = row else {
        return Ok(Value::Null);
    };
    let bullets: Vec<String> = serde_json::from_str(&bullets_json)?;
    Ok(json!({ "day": day, "created_at": created_at, "bullets": bullets }))
}

/// Checks the change entries of a review: the rules of
/// [`validate_change_entries`], and one entry is for the reviewed daily note
/// (`daily_id`), which fails with `ChangeEntriesInvalid` ahead of an unknown
/// note's `NotFound`.
fn validate_entries(conn: &Connection, daily_id: &str, changes: &[ChangeEntry]) -> Result<()> {
    let notes = check_entry_rules(changes)?;
    if !notes.contains(daily_id) {
        return Err(MemexError::ChangeEntriesInvalid(format!(
            "changes must include an entry for the daily note itself ({daily_id})"
        )));
    }
    check_entry_notes_exist(conn, notes)
}

/// The per-entry rules of [`validate_change_entries`]; returns the notes named.
fn check_entry_rules(changes: &[ChangeEntry]) -> Result<HashSet<&str>> {
    let invalid = |rule: String| Err(MemexError::ChangeEntriesInvalid(rule));
    let mut seen = HashSet::new();
    for entry in changes {
        let note_id = &entry.note_id;
        let count = entry.bullets.len();
        if !(1..=MAX_BULLETS).contains(&count) {
            return invalid(format!(
                "each entry needs 1 to {MAX_BULLETS} bullets; the entry for {note_id} has {count}"
            ));
        }
        for bullet in &entry.bullets {
            if bullet.contains(['\n', '\r']) {
                return invalid(format!(
                    "a bullet is one line, with no newline: {bullet:?} ({note_id})"
                ));
            }
            if bullet.chars().count() > MAX_BULLET_CHARS {
                return invalid(format!(
                    "a bullet has at most {MAX_BULLET_CHARS} characters: {bullet:?} ({note_id})"
                ));
            }
            if bullet.starts_with(LIST_PREFIX) {
                return invalid(format!(
                    "a bullet has no leading {LIST_PREFIX:?}: {bullet:?} ({note_id})"
                ));
            }
        }
        if !seen.insert(note_id.as_str()) {
            return invalid(format!(
                "duplicate entry for note {note_id}: one entry per note"
            ));
        }
    }
    Ok(seen)
}

/// `NotFound` when a change entry names a note that does not exist.
fn check_entry_notes_exist(conn: &Connection, notes: HashSet<&str>) -> Result<()> {
    for note_id in notes {
        let exists = conn
            .query_row("SELECT 1 FROM notes WHERE id = ?", [note_id], |_| Ok(()))
            .optional()?
            .is_some();
        if !exists {
            return Err(MemexError::NotFound(format!(
                "change entry names note {note_id}, which does not exist"
            )));
        }
    }
    Ok(())
}
