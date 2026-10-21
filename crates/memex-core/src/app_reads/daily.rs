//! App API reads for daily notes (#82): the rows the app's `DailyReads`
//! (`app/lib/src/db/daily_reads.dart`) reads today, for the daily routes of
//! the vault server. Field names are the Dart models' in snake case.

use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;

use crate::{daily, links, Result, Vault};

/// A row of `GET /daily-notes`: the app's `DailyNoteRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DailyNoteRow {
    /// The note's title (an ISO date).
    pub date: String,
    pub note_id: String,
    /// The first block's text (by `ord`) up to its first `\n`; empty when the
    /// note has no blocks.
    pub preview: String,
    /// The C2 label (`daily::ReviewState::as_str`).
    pub review_state: String,
}

/// `GET /notes/{note_id}/review`: the app's `ReviewInfo`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReviewInfo {
    /// The C2 label (`daily::ReviewState::as_str`).
    pub state: String,
    /// `day_reviews.reviewed_at` (unix ms); `None` without a row.
    pub reviewed_at: Option<i64>,
}

/// A row of `GET /notes/{note_id}/blocks`: the app's `BlockRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BlockRow {
    pub block_id: String,
    pub ord: i64,
    pub text: String,
    pub source: String,
    pub created_version: i64,
    pub created_at: i64,
    pub start_byte: i64,
    pub end_byte: i64,
}

/// A row of `GET /notes/{note_id}/footer-chips`: the app's `FooterChipRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FooterChipRow {
    pub topic_note_id: String,
    pub topic_title: String,
    /// `excerpt` or `person`.
    pub origin: String,
}

/// `DailyReads.dailyNotes`: every note whose valid-JSON frontmatter has
/// `role: daily`, newest title first.
pub fn daily_notes(vault: &Vault) -> Result<Vec<DailyNoteRow>> {
    let conn = vault.conn();
    let mut stmt = conn.prepare(&format!("{DAILY_NOTE_SELECT} ORDER BY n.title DESC, n.id"))?;
    let rows = stmt
        .query_map([], daily_note_columns)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    rows.into_iter().map(|cols| daily_row(conn, cols)).collect()
}

/// `DailyReads.dailyNoteForDate`: the `role: daily` note titled `title` (a
/// plain title match, no date validation), or `None`.
pub fn daily_note_for_date(vault: &Vault, title: &str) -> Result<Option<DailyNoteRow>> {
    let conn = vault.conn();
    let Some(id) = links::daily_note_id_for_title(conn, title)? else {
        return Ok(None);
    };
    let cols = conn
        .query_row(
            &format!("{DAILY_NOTE_SELECT} AND n.id = ?"),
            [&id],
            daily_note_columns,
        )
        .optional()?;
    cols.map(|cols| daily_row(conn, cols)).transpose()
}

/// `DailyReads.reviewState`: `Unreviewed` with no `reviewed_at` when the note
/// has no `day_reviews` row.
pub fn review_info(vault: &Vault, note_id: &str) -> Result<ReviewInfo> {
    let conn = vault.conn();
    let state = daily::review_state(conn, note_id)?;
    let reviewed_at: Option<i64> = conn
        .query_row(
            "SELECT reviewed_at FROM day_reviews WHERE note_id = ?",
            [note_id],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    Ok(ReviewInfo {
        state: state.as_str().to_string(),
        reviewed_at,
    })
}

/// `DailyReads.blocksForNote`: the note's blocks in `ord` order.
pub fn blocks_for_note(vault: &Vault, note_id: &str) -> Result<Vec<BlockRow>> {
    let (blocks, created_at) = daily::stored_blocks(vault.conn(), note_id)?;
    Ok(blocks
        .into_iter()
        .map(|b| BlockRow {
            created_at: created_at.get(&b.block_id).copied().unwrap_or_default(),
            block_id: b.block_id,
            ord: b.ord as i64,
            text: b.text,
            source: b.source,
            created_version: b.created_version,
            start_byte: b.start_byte as i64,
            end_byte: b.end_byte as i64,
        })
        .collect())
}

/// `DailyReads.footerChips`: the daily note's chips in insertion (rowid)
/// order, each with its topic's title.
pub fn footer_chips(vault: &Vault, daily_note_id: &str) -> Result<Vec<FooterChipRow>> {
    let mut stmt = vault.conn().prepare(
        "SELECT c.topic_note_id, n.title, c.origin FROM footer_chips c
         JOIN notes n ON n.id = c.topic_note_id
         WHERE c.daily_note_id = ? ORDER BY c.rowid",
    )?;
    let chips = stmt
        .query_map([daily_note_id], |r| {
            Ok(FooterChipRow {
                topic_note_id: r.get(0)?,
                topic_title: r.get(1)?,
                origin: r.get(2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(chips)
}

/// The notes `DailyReads` treats as daily (valid-JSON frontmatter whose
/// `role` is exactly `daily`), each with its first block's text by `ord`.
const DAILY_NOTE_SELECT: &str = "SELECT n.id, n.title,
        (SELECT b.text FROM blocks b WHERE b.note_id = n.id ORDER BY b.ord LIMIT 1)
     FROM notes n
     WHERE (CASE WHEN json_valid(n.frontmatter)
                 THEN json_extract(n.frontmatter, '$.role') END) = 'daily'";

/// `(id, title, first block text)` of a [`DAILY_NOTE_SELECT`] row.
type DailyNoteColumns = (String, String, Option<String>);

fn daily_note_columns(r: &rusqlite::Row<'_>) -> rusqlite::Result<DailyNoteColumns> {
    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
}

/// A [`DailyNoteRow`]: the preview is the first block's text up to its first
/// `\n`, and the state comes from the note's `day_reviews` row.
fn daily_row(
    conn: &Connection,
    (note_id, date, first_block): DailyNoteColumns,
) -> Result<DailyNoteRow> {
    let text = first_block.unwrap_or_default();
    let preview = match text.find('\n') {
        Some(cut) => text[..cut].to_string(),
        None => text,
    };
    let review_state = daily::review_state(conn, &note_id)?.as_str().to_string();
    Ok(DailyNoteRow {
        date,
        note_id,
        preview,
        review_state,
    })
}
