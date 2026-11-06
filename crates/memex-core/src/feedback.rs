//! Feedback: written comments, chat comments and Corrections (Spec #233 R1-R5a,
//! R19-R23, R40, R41; WI #250).
//!
//! The field names of [`Feedback`] are the frozen Contract shape in #256:
//! `correction` is `correction_json` parsed, and an unhandled tag Correction
//! lists with the synthetic id `tag-<n>`.
//!
//! The `record_*` functions are the Correction hooks. `excerpts.rs` and
//! `smart_folders.rs` call them for [`Caller::Person`](crate::Caller) only, once
//! their writes have succeeded, with names and previews read before those
//! writes. Nothing here touches a day's review state.

use rusqlite::{params, Connection, OptionalExtension, Params, TransactionBehavior};
use serde::Serialize;
use serde_json::{json, Value};
use ulid::Ulid;

use crate::canvas::Clock;
use crate::daily;
use crate::error::MemexError;
use crate::review::{self, ChangeEntry};
use crate::vault::{now_unix_ms, Vault};
use crate::Result;

/// Most characters (Unicode scalar values) a comment may have (R17).
const MAX_COMMENT_CHARS: usize = 2000;
/// Most characters (Unicode scalar values) a reply may have (R19).
const MAX_REPLY_CHARS: usize = 200;
/// Most characters (Unicode scalar values) a block preview keeps.
const MAX_PREVIEW_CHARS: usize = 80;

const KIND_COMMENT: &str = "comment";
const KIND_CORRECTION: &str = "correction";
const SOURCE_PERSON: &str = "person";
const SOURCE_CHAT: &str = "chat";
const STATUS_OPEN: &str = "open";
const STATUS_HANDLED: &str = "handled";

/// The synthetic id prefix of a `tag_corrections` row.
const TAG_ID_PREFIX: &str = "tag-";

const COLUMNS: &str = "id, kind, source, note_id, day, agent_change_id, text, correction_json,
     status, reply, created_at, updated_at, handled_at";

/// The `tag_corrections` rows still open: not lifted and not yet Handled.
const OPEN_TAG_ROWS: &str = "SELECT tc.id, tc.note_id, tc.note_title, tc.tag, tc.created_at
     FROM tag_corrections tc
     WHERE tc.cleared_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM feedback f WHERE f.tag_correction_id = tc.id)";

/// One Feedback row as the agent, the CLI and the hosted API see it.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Feedback {
    /// A ULID, or `tag-<n>` for an unhandled tag Correction.
    pub id: String,
    /// `comment` or `correction`.
    pub kind: String,
    /// `person` or `chat`.
    pub source: String,
    pub note_id: Option<String>,
    pub day: Option<String>,
    pub agent_change_id: Option<String>,
    pub text: Option<String>,
    pub correction: Option<Value>,
    /// `open` or `handled`.
    pub status: String,
    pub reply: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub handled_at: Option<i64>,
}

/// Stores an Open comment on the Activity entry `change_id` of `note_id`. The
/// text is stored verbatim. Errors: `FeedbackInvalid` (empty after trimming or
/// over 2,000 characters), `InvalidDate`, `NotFound` (unknown note, or no such
/// entry on that note).
pub fn add(
    vault: &mut Vault,
    note_id: &str,
    date: &str,
    change_id: &str,
    text: &str,
    clock: &dyn Clock,
) -> Result<Feedback> {
    check_text(text)?;
    daily::parse_iso_date(date)?;
    let conn = vault.connection_ref();
    check_note_exists(conn, note_id)?;
    let entry_exists = conn
        .query_row(
            "SELECT 1 FROM agent_changes WHERE id = ? AND note_id = ?",
            [change_id, note_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !entry_exists {
        return Err(MemexError::NotFound(format!(
            "no Activity entry {change_id} on note {note_id}"
        )));
    }
    let now = clock.now_ms();
    let id = insert(
        conn,
        &NewRow {
            kind: KIND_COMMENT,
            source: SOURCE_PERSON,
            note_id: Some(note_id),
            day: Some(date),
            agent_change_id: Some(change_id),
            text: Some(text),
            status: STATUS_OPEN,
            created_at: now,
            updated_at: now,
            ..Default::default()
        },
    )?;
    get(conn, &id)
}

/// Replaces the text of an Open comment, verbatim. Errors, in this order:
/// `NotFound`, `FeedbackInvalid` (a Correction), `FeedbackHandled`,
/// `FeedbackInvalid` (the text).
pub fn edit(vault: &mut Vault, id: &str, text: &str, clock: &dyn Clock) -> Result<Feedback> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    check_open_comment(&tx, id)?;
    check_text(text)?;
    tx.execute(
        "UPDATE feedback SET text = ?, updated_at = ? WHERE id = ?",
        params![text, clock.now_ms(), id],
    )?;
    let edited = get(&tx, id)?;
    tx.commit()?;
    Ok(edited)
}

/// Deletes an Open comment. Errors: `NotFound`, `FeedbackInvalid` (a
/// Correction), `FeedbackHandled`.
pub fn delete(vault: &mut Vault, id: &str) -> Result<()> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    check_open_comment(&tx, id)?;
    tx.execute("DELETE FROM feedback WHERE id = ?", [id])?;
    tx.commit()?;
    Ok(())
}

/// Every Open row oldest first, merged with the open tag Corrections.
pub fn list_open(vault: &Vault) -> Result<Vec<Feedback>> {
    let conn = vault.connection_ref();
    let rows = query_rows(
        conn,
        &format!("SELECT {COLUMNS} FROM feedback WHERE status = ? ORDER BY created_at, rowid"),
        [STATUS_OPEN],
    )?;
    let tags = query_tag_rows(conn, &format!("{OPEN_TAG_ROWS} ORDER BY tc.id"), [])?;
    Ok(oldest_first(rows, tags))
}

/// Every row of `note_id` (`None`: rows with no note), all statuses, newest
/// first, merged with its open tag Corrections.
pub fn list_for_note(vault: &Vault, note_id: Option<&str>) -> Result<Vec<Feedback>> {
    let conn = vault.connection_ref();
    let rows = query_rows(
        conn,
        &format!("SELECT {COLUMNS} FROM feedback WHERE note_id IS ? ORDER BY created_at, rowid"),
        [note_id],
    )?;
    let tags = query_tag_rows(
        conn,
        &format!("{OPEN_TAG_ROWS} AND tc.note_id IS ? ORDER BY tc.id"),
        [note_id],
    )?;
    let mut all = oldest_first(rows, tags);
    all.reverse();
    Ok(all)
}

/// Marks a row Handled with `reply` and writes `changes` as `agent_changes`,
/// dated the row's day, else today from `clock`. Resolving `tag-<n>` inserts the
/// handled row, with the tag Correction copied into it. All or nothing.
///
/// Errors, in this order: `NotFound` (unknown id, or a tag Correction lifted
/// before it was Handled), `FeedbackHandled`, `FeedbackInvalid` (the reply),
/// then the change entry errors.
pub fn resolve(
    vault: &mut Vault,
    id: &str,
    reply: &str,
    changes: &[ChangeEntry],
    clock: &dyn Clock,
) -> Result<Feedback> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let target = resolve_target(&tx, id)?;
    check_reply(reply)?;
    review::validate_change_entries(&tx, changes)?;

    let now = clock.now_ms();
    let (row_id, day) = match target {
        ResolveTarget::Row(row) => {
            tx.execute(
                "UPDATE feedback SET status = ?, reply = ?, handled_at = ?, updated_at = ?
                 WHERE id = ?",
                params![STATUS_HANDLED, reply, now, now, id],
            )?;
            (row.id, row.day)
        }
        ResolveTarget::Tag(tag) => {
            let row_id = insert(
                &tx,
                &NewRow {
                    kind: KIND_CORRECTION,
                    source: SOURCE_PERSON,
                    note_id: tag.row.note_id.as_deref(),
                    correction: tag.row.correction.as_ref(),
                    status: STATUS_HANDLED,
                    reply: Some(reply),
                    tag_correction_id: Some(tag.number),
                    created_at: tag.row.created_at,
                    updated_at: now,
                    handled_at: Some(now),
                    ..Default::default()
                },
            )?;
            (row_id, None)
        }
    };
    write_changes(&tx, changes, day.as_deref(), now, clock)?;
    let resolved = get(&tx, &row_id)?;
    tx.commit()?;
    Ok(resolved)
}

/// Stores a chat comment verbatim, already Handled, and writes `changes`, dated
/// `date`, else today from `clock`. All or nothing. Errors: `FeedbackInvalid`
/// (text or reply), `InvalidDate`, `NotFound` (unknown note), then the change
/// entry errors.
pub fn record_chat(
    vault: &mut Vault,
    text: &str,
    note_id: Option<&str>,
    date: Option<&str>,
    reply: &str,
    changes: &[ChangeEntry],
    clock: &dyn Clock,
) -> Result<Feedback> {
    check_text(text)?;
    check_reply(reply)?;
    if let Some(date) = date {
        daily::parse_iso_date(date)?;
    }
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(note_id) = note_id {
        check_note_exists(&tx, note_id)?;
    }
    review::validate_change_entries(&tx, changes)?;

    let now = clock.now_ms();
    let id = insert(
        &tx,
        &NewRow {
            kind: KIND_COMMENT,
            source: SOURCE_CHAT,
            note_id,
            day: date,
            text: Some(text),
            status: STATUS_HANDLED,
            reply: Some(reply),
            created_at: now,
            updated_at: now,
            handled_at: Some(now),
            ..Default::default()
        },
    )?;
    write_changes(&tx, changes, date, now, clock)?;
    let recorded = get(&tx, &id)?;
    tx.commit()?;
    Ok(recorded)
}

// ---------- Correction hooks ----------

/// One block of a day as an excerpt Correction names it.
pub(crate) struct ExcerptBlock {
    pub(crate) id: String,
    pub(crate) preview: String,
}

/// What a Correction shows of a block's stored text: its first line, trimmed, at
/// most 80 characters, with no ellipsis (R18).
pub(crate) fn preview(text: &str) -> String {
    text.lines()
        .next()
        .unwrap_or_default()
        .trim()
        .chars()
        .take(MAX_PREVIEW_CHARS)
        .collect()
}

/// A person filed `blocks` into a topic note: one `excerpt_added` per block, all
/// or none.
pub(crate) fn record_excerpts_added(
    vault: &mut Vault,
    date: &str,
    blocks: &[ExcerptBlock],
    topic_note_id: &str,
    title: &str,
    note: Option<&str>,
) -> Result<()> {
    if blocks.is_empty() {
        return Ok(());
    }
    let now = now_unix_ms();
    let tx = vault.conn_mut().transaction()?;
    let home = ExcerptHome::of_day(&tx, date)?;
    for block in blocks {
        let correction = json!({
            "kind": "excerpt_added",
            "date": date,
            "block_id": block.id,
            "preview": block.preview,
            "topic_note_id": topic_note_id,
            "title": title,
        });
        home.record(&tx, date, note, &correction, now)?;
    }
    tx.commit()?;
    Ok(())
}

/// A person removed `blocks` from a topic note: one `excerpt_removed` naming the
/// blocks that count as undone work (R5), or nothing when none does.
pub(crate) fn record_excerpt_removed(
    conn: &Connection,
    date: &str,
    blocks: &[ExcerptBlock],
    topic_note_id: &str,
    title: &str,
    note: Option<&str>,
) -> Result<()> {
    let mut undone = Vec::with_capacity(blocks.len());
    for block in blocks {
        if records_undoing(conn, date, &block.id, topic_note_id)? {
            undone.push(block);
        }
    }
    let Some(first) = undone.first() else {
        return Ok(());
    };
    let block_ids: Vec<&str> = undone.iter().map(|b| b.id.as_str()).collect();
    let correction = json!({
        "kind": "excerpt_removed",
        "date": date,
        "block_ids": block_ids,
        "preview": first.preview,
        "topic_note_id": topic_note_id,
        "title": title,
    });
    let home = ExcerptHome::of_day(conn, date)?;
    home.record(conn, date, note, &correction, now_unix_ms())
}

/// A person moved `block` between two topic notes, each `(id, title)`: one
/// `excerpt_moved`, unless the block doesn't count as undone work in its source
/// (R5).
pub(crate) fn record_excerpt_moved(
    conn: &Connection,
    date: &str,
    block: &ExcerptBlock,
    from: (&str, &str),
    to: (&str, &str),
    note: Option<&str>,
) -> Result<()> {
    if !records_undoing(conn, date, &block.id, from.0)? {
        return Ok(());
    }
    let correction = json!({
        "kind": "excerpt_moved",
        "date": date,
        "block_id": block.id,
        "preview": block.preview,
        "from_topic_note_id": from.0,
        "from_title": from.1,
        "to_topic_note_id": to.0,
        "to_title": to.1,
    });
    let home = ExcerptHome::of_day(conn, date)?;
    home.record(conn, date, note, &correction, now_unix_ms())
}

/// A person removed an unpinned membership; the Correction's home is the note.
pub(crate) fn record_membership_removed(
    conn: &Connection,
    note_id: &str,
    note_title: &str,
    folder_id: &str,
    folder_name: &str,
) -> Result<()> {
    let correction = json!({
        "kind": "membership_removed",
        "note_id": note_id,
        "note_title": note_title,
        "smart_folder_id": folder_id,
        "folder_name": folder_name,
    });
    record_correction(conn, Some(note_id), &correction, now_unix_ms())
}

/// A person renamed an unpinned Smart Folder; the Correction has no note.
pub(crate) fn record_folder_renamed(
    conn: &Connection,
    folder_id: &str,
    old_name: &str,
    new_name: &str,
    now: i64,
) -> Result<()> {
    let correction = json!({
        "kind": "folder_renamed",
        "smart_folder_id": folder_id,
        "old_name": old_name,
        "new_name": new_name,
    });
    record_correction(conn, None, &correction, now)
}

/// A person re-parented an unpinned Smart Folder; the Correction has no note.
pub(crate) fn record_folder_moved(
    conn: &Connection,
    folder_id: &str,
    name: &str,
    old_parent_id: Option<&str>,
    new_parent_id: Option<&str>,
    now: i64,
) -> Result<()> {
    let correction = json!({
        "kind": "folder_moved",
        "smart_folder_id": folder_id,
        "name": name,
        "old_parent_id": old_parent_id,
        "new_parent_id": new_parent_id,
    });
    record_correction(conn, None, &correction, now)
}

/// A person deleted an unpinned Smart Folder; the Correction has no note.
pub(crate) fn record_folder_deleted(conn: &Connection, folder_id: &str, name: &str) -> Result<()> {
    let correction = json!({
        "kind": "folder_deleted",
        "smart_folder_id": folder_id,
        "name": name,
    });
    record_correction(conn, None, &correction, now_unix_ms())
}

/// Stores a membership or folder Correction: no day, no entry, no `Why?` note.
fn record_correction(
    conn: &Connection,
    note_id: Option<&str>,
    correction: &Value,
    now: i64,
) -> Result<()> {
    insert(
        conn,
        &NewRow {
            kind: KIND_CORRECTION,
            source: SOURCE_PERSON,
            note_id,
            correction: Some(correction),
            status: STATUS_OPEN,
            created_at: now,
            updated_at: now,
            ..Default::default()
        },
    )?;
    Ok(())
}

/// Where an excerpt Correction of a day lives (R23).
struct ExcerptHome {
    /// The day's daily note, if it still exists.
    note_id: Option<String>,
    /// That note's newest `agent_changes` row for the day, if any.
    agent_change_id: Option<String>,
}

impl ExcerptHome {
    fn of_day(conn: &Connection, date: &str) -> Result<Self> {
        let note_id = daily::daily_note_for_date(conn, daily::parse_iso_date(date)?)?;
        let agent_change_id = conn
            .query_row(
                "SELECT id FROM agent_changes WHERE note_id IS ? AND day = ?
                 ORDER BY created_at DESC, rowid DESC LIMIT 1",
                params![note_id, date],
                |r| r.get(0),
            )
            .optional()?;
        Ok(Self {
            note_id,
            agent_change_id,
        })
    }

    fn record(
        &self,
        conn: &Connection,
        date: &str,
        note: Option<&str>,
        correction: &Value,
        now: i64,
    ) -> Result<()> {
        insert(
            conn,
            &NewRow {
                kind: KIND_CORRECTION,
                source: SOURCE_PERSON,
                note_id: self.note_id.as_deref(),
                day: Some(date),
                agent_change_id: self.agent_change_id.as_deref(),
                text: note,
                correction: Some(correction),
                status: STATUS_OPEN,
                created_at: now,
                updated_at: now,
                ..Default::default()
            },
        )?;
        Ok(())
    }
}

/// Excerpt provenance (R5, TD7): whether moving or removing this block of the day
/// `date` from this topic note records a Correction. Only the newest Correction
/// naming the block and the topic counts, by insertion order, so a wall clock
/// stepping back can't change the answer. A block that row filed into this topic
/// is the person's: it records only while that row is Open. Anything else is
/// agent work and records.
fn records_undoing(conn: &Connection, date: &str, block_id: &str, topic: &str) -> Result<bool> {
    let mut stmt = conn.prepare(
        "SELECT correction_json, status FROM feedback
         WHERE kind = ? AND day = ? ORDER BY rowid DESC",
    )?;
    let rows = stmt.query_map([KIND_CORRECTION, date], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (correction_json, status) = row?;
        let correction: Value = serde_json::from_str(&correction_json)?;
        if let Some(filed_here) = filed_into_topic(&correction, block_id, topic) {
            return Ok(!filed_here || status != STATUS_HANDLED);
        }
    }
    Ok(true)
}

/// `None` when `correction` doesn't name this block and topic; otherwise whether
/// it filed the block into the topic.
fn filed_into_topic(correction: &Value, block_id: &str, topic: &str) -> Option<bool> {
    let is = |key: &str, wanted: &str| correction[key].as_str() == Some(wanted);
    match correction["kind"].as_str()? {
        "excerpt_added" => (is("block_id", block_id) && is("topic_note_id", topic)).then_some(true),
        "excerpt_moved" if is("block_id", block_id) => {
            if is("to_topic_note_id", topic) {
                Some(true)
            } else {
                is("from_topic_note_id", topic).then_some(false)
            }
        }
        "excerpt_removed" => {
            let names_block = correction["block_ids"]
                .as_array()?
                .iter()
                .any(|id| id.as_str() == Some(block_id));
            (names_block && is("topic_note_id", topic)).then_some(false)
        }
        _ => None,
    }
}

// ---------- internals ----------

/// The columns of a new `feedback` row; the id is minted on insert.
#[derive(Default)]
struct NewRow<'a> {
    kind: &'a str,
    source: &'a str,
    note_id: Option<&'a str>,
    day: Option<&'a str>,
    agent_change_id: Option<&'a str>,
    text: Option<&'a str>,
    correction: Option<&'a Value>,
    status: &'a str,
    reply: Option<&'a str>,
    tag_correction_id: Option<i64>,
    created_at: i64,
    updated_at: i64,
    handled_at: Option<i64>,
}

fn insert(conn: &Connection, row: &NewRow<'_>) -> Result<String> {
    let id = Ulid::new().to_string();
    let correction_json = row.correction.map(serde_json::to_string).transpose()?;
    conn.execute(
        "INSERT INTO feedback (id, kind, source, note_id, day, agent_change_id, text,
             correction_json, status, reply, tag_correction_id, created_at, updated_at,
             handled_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            id,
            row.kind,
            row.source,
            row.note_id,
            row.day,
            row.agent_change_id,
            row.text,
            correction_json,
            row.status,
            row.reply,
            row.tag_correction_id,
            row.created_at,
            row.updated_at,
            row.handled_at,
        ],
    )?;
    Ok(id)
}

/// The `feedback` row `id`, or `NotFound`.
fn get(conn: &Connection, id: &str) -> Result<Feedback> {
    conn.query_row(
        &format!("SELECT {COLUMNS} FROM feedback WHERE id = ?"),
        [id],
        row_to_feedback,
    )
    .optional()?
    .ok_or_else(|| MemexError::NotFound(format!("Feedback {id}")))
}

fn query_rows<P: Params>(conn: &Connection, sql: &str, params: P) -> Result<Vec<Feedback>> {
    let rows = conn
        .prepare(sql)?
        .query_map(params, row_to_feedback)?
        .collect::<rusqlite::Result<_>>()?;
    Ok(rows)
}

fn query_tag_rows<P: Params>(conn: &Connection, sql: &str, params: P) -> Result<Vec<Feedback>> {
    let rows = conn
        .prepare(sql)?
        .query_map(params, tag_row_to_feedback)?
        .collect::<rusqlite::Result<_>>()?;
    Ok(rows)
}

/// A row of [`COLUMNS`].
fn row_to_feedback(r: &rusqlite::Row<'_>) -> rusqlite::Result<Feedback> {
    let correction = r
        .get::<_, Option<String>>(7)?
        .map(|json| serde_json::from_str(&json))
        .transpose()
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(7, rusqlite::types::Type::Text, Box::new(e))
        })?;
    Ok(Feedback {
        id: r.get(0)?,
        kind: r.get(1)?,
        source: r.get(2)?,
        note_id: r.get(3)?,
        day: r.get(4)?,
        agent_change_id: r.get(5)?,
        text: r.get(6)?,
        correction,
        status: r.get(8)?,
        reply: r.get(9)?,
        created_at: r.get(10)?,
        updated_at: r.get(11)?,
        handled_at: r.get(12)?,
    })
}

/// A row of [`OPEN_TAG_ROWS`] as the Feedback it lists as (D7).
fn tag_row_to_feedback(r: &rusqlite::Row<'_>) -> rusqlite::Result<Feedback> {
    let number: i64 = r.get(0)?;
    Ok(tag_feedback(
        number,
        r.get(1)?,
        &r.get::<_, String>(2)?,
        &r.get::<_, String>(3)?,
        r.get(4)?,
    ))
}

fn tag_feedback(
    number: i64,
    note_id: Option<String>,
    note_title: &str,
    tag: &str,
    created_at: i64,
) -> Feedback {
    Feedback {
        id: format!("{TAG_ID_PREFIX}{number}"),
        kind: KIND_CORRECTION.to_string(),
        source: SOURCE_PERSON.to_string(),
        correction: Some(json!({
            "kind": "tag_removed",
            "tag": tag,
            "note_id": note_id,
            "note_title": note_title,
        })),
        note_id,
        status: STATUS_OPEN.to_string(),
        created_at,
        updated_at: created_at,
        ..Default::default()
    }
}

/// `rows` and `tags`, each already oldest first, merged by `created_at`.
fn oldest_first(rows: Vec<Feedback>, tags: Vec<Feedback>) -> Vec<Feedback> {
    let mut all = rows;
    all.extend(tags);
    all.sort_by_key(|f| f.created_at);
    all
}

/// A `tag_corrections` row, whatever its state.
struct TagCorrection {
    number: i64,
    /// The row as it lists while open.
    row: Feedback,
    cleared: bool,
    handled: bool,
}

/// The tag Correction with the canonical id `id`, if there is one.
fn tag_correction(conn: &Connection, id: &str) -> Result<Option<TagCorrection>> {
    let Some(number) = id
        .strip_prefix(TAG_ID_PREFIX)
        .and_then(|n| n.parse::<i64>().ok())
        .filter(|n| format!("{TAG_ID_PREFIX}{n}") == id)
    else {
        return Ok(None);
    };
    let tag = conn
        .query_row(
            "SELECT tc.id, tc.note_id, tc.note_title, tc.tag, tc.created_at,
                    tc.cleared_at IS NOT NULL,
                    EXISTS (SELECT 1 FROM feedback f WHERE f.tag_correction_id = tc.id)
             FROM tag_corrections tc WHERE tc.id = ?",
            [number],
            |r| {
                Ok(TagCorrection {
                    number,
                    row: tag_row_to_feedback(r)?,
                    cleared: r.get(5)?,
                    handled: r.get(6)?,
                })
            },
        )
        .optional()?;
    Ok(tag)
}

/// What [`resolve`] acts on, once it has passed the state checks.
enum ResolveTarget {
    /// A `feedback` row.
    Row(Feedback),
    /// An open tag Correction, which has no `feedback` row yet.
    Tag(TagCorrection),
}

fn resolve_target(conn: &Connection, id: &str) -> Result<ResolveTarget> {
    let handled = || MemexError::FeedbackHandled(format!("Feedback {id} is already handled"));
    if let Some(tag) = tag_correction(conn, id)? {
        if tag.handled {
            return Err(handled());
        }
        if tag.cleared {
            return Err(MemexError::NotFound(format!(
                "tag Correction {id} was lifted"
            )));
        }
        return Ok(ResolveTarget::Tag(tag));
    }
    let row = get(conn, id)?;
    if row.status == STATUS_HANDLED {
        return Err(handled());
    }
    Ok(ResolveTarget::Row(row))
}

/// Only an Open comment may be edited or deleted (R20).
fn check_open_comment(conn: &Connection, id: &str) -> Result<()> {
    let correction = || MemexError::FeedbackInvalid(format!("Feedback {id} is a Correction"));
    if tag_correction(conn, id)?.is_some() {
        return Err(correction());
    }
    let row = get(conn, id)?;
    if row.kind == KIND_CORRECTION {
        return Err(correction());
    }
    if row.status == STATUS_HANDLED {
        return Err(MemexError::FeedbackHandled(format!(
            "Feedback {id} is already handled"
        )));
    }
    Ok(())
}

fn check_note_exists(conn: &Connection, note_id: &str) -> Result<()> {
    conn.query_row("SELECT 1 FROM notes WHERE id = ?", [note_id], |_| Ok(()))
        .optional()?
        .ok_or_else(|| MemexError::NotFound(format!("note {note_id}")))
}

fn check_text(text: &str) -> Result<()> {
    if text.trim().is_empty() {
        return Err(MemexError::FeedbackInvalid(
            "a comment needs some text".into(),
        ));
    }
    if text.chars().count() > MAX_COMMENT_CHARS {
        return Err(MemexError::FeedbackInvalid(format!(
            "a comment has at most {MAX_COMMENT_CHARS} characters"
        )));
    }
    Ok(())
}

fn check_reply(reply: &str) -> Result<()> {
    if reply.trim().is_empty() {
        return Err(MemexError::FeedbackInvalid("a reply is required".into()));
    }
    if reply.contains(['\n', '\r']) {
        return Err(MemexError::FeedbackInvalid("a reply is one line".into()));
    }
    if reply.chars().count() > MAX_REPLY_CHARS {
        return Err(MemexError::FeedbackInvalid(format!(
            "a reply has at most {MAX_REPLY_CHARS} characters"
        )));
    }
    Ok(())
}

/// One `agent_changes` row per entry, dated `day`, else today from `clock` (R40).
fn write_changes(
    conn: &Connection,
    changes: &[ChangeEntry],
    day: Option<&str>,
    now: i64,
    clock: &dyn Clock,
) -> Result<()> {
    let day = day.map_or_else(
        || daily::today_with_clock(clock).to_string(),
        str::to_string,
    );
    for entry in changes {
        review::insert_agent_change(conn, &entry.note_id, &day, now, &entry.bullets)?;
    }
    Ok(())
}
