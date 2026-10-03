//! Review.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::blocks::{Block, SnapshotBlock};
use crate::canvas::Clock;
use crate::daily::ReviewState;
use crate::notes::Note;
use crate::vault::Vault;
use crate::Result;

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
pub fn list_unreviewed_days(_vault: &Vault) -> Result<Vec<UnreviewedDay>> {
    todo!("WI #11: list_unreviewed_days")
}

/// The day's current content version and its blocks diffed against the review
/// snapshot (Req 26). `InvalidDate` for a malformed date, `NotFound` when the
/// date has no daily note.
pub fn get_daily_note_changes(_vault: &Vault, _date: &str) -> Result<DailyNoteChanges> {
    todo!("WI #11: get_daily_note_changes")
}

/// Records a review of the day (Req 21, 22): strict content version check
/// (`ReviewStale`), change-entry validation (`ChangeEntriesInvalid`), then in
/// one transaction replaces the snapshot, updates `day_reviews` and appends
/// one `agent_changes` row per entry, with times from `clock` (D14).
pub fn mark_day_reviewed(
    _vault: &mut Vault,
    _date: &str,
    _version: i64,
    _changes: &[ChangeEntry],
    _clock: &dyn Clock,
) -> Result<DayReview> {
    todo!("WI #11: mark_day_reviewed")
}

/// Review fields merged into the top level of MCP `get_note` and CLI
/// `memex get` (architect ruling D7). Empty for a note with no review state;
/// filled by the review Work Item (#11).
pub fn note_review_fields(_vault: &Vault, _note: &Note) -> Result<Map<String, Value>> {
    Ok(Map::new())
}
