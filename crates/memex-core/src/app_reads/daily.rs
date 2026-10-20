//! App API reads for daily notes (#82): the rows the app's `DailyReads`
//! (`app/lib/src/db/daily_reads.dart`) reads today, for the daily routes of
//! the vault server. Field names are the Dart models' in snake case.

use serde::Serialize;

use crate::{Result, Vault};

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
    let _ = vault;
    todo!("#82: daily_notes")
}

/// `DailyReads.dailyNoteForDate`: the `role: daily` note titled `title` (a
/// plain title match, no date validation), or `None`.
pub fn daily_note_for_date(vault: &Vault, title: &str) -> Result<Option<DailyNoteRow>> {
    let _ = (vault, title);
    todo!("#82: daily_note_for_date")
}

/// `DailyReads.reviewState`: `Unreviewed` with no `reviewed_at` when the note
/// has no `day_reviews` row.
pub fn review_info(vault: &Vault, note_id: &str) -> Result<ReviewInfo> {
    let _ = (vault, note_id);
    todo!("#82: review_info")
}

/// `DailyReads.blocksForNote`: the note's blocks in `ord` order.
pub fn blocks_for_note(vault: &Vault, note_id: &str) -> Result<Vec<BlockRow>> {
    let _ = (vault, note_id);
    todo!("#82: blocks_for_note")
}

/// `DailyReads.footerChips`: the daily note's chips in insertion (rowid)
/// order, each with its topic's title.
pub fn footer_chips(vault: &Vault, daily_note_id: &str) -> Result<Vec<FooterChipRow>> {
    let _ = (vault, daily_note_id);
    todo!("#82: footer_chips")
}
