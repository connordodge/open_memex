//! Feedback: written comments, chat comments and Corrections (Spec #233 R1-R5a,
//! R19-R23, R40, R41; WI #250).
//!
//! The field names of [`Feedback`] are the frozen Contract shape in #256:
//! `correction` is `correction_json` parsed, and an unhandled tag Correction
//! lists with the synthetic id `tag-<n>`.

use serde::Serialize;
use serde_json::Value;

use crate::canvas::Clock;
use crate::review::ChangeEntry;
use crate::vault::Vault;
use crate::Result;

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

/// Stores an Open comment on the Activity entry `change_id` of `note_id`.
pub fn add(
    _vault: &mut Vault,
    _note_id: &str,
    _date: &str,
    _change_id: &str,
    _text: &str,
    _clock: &dyn Clock,
) -> Result<Feedback> {
    Ok(Feedback::default())
}

/// Replaces the text of an Open comment.
pub fn edit(_vault: &mut Vault, _id: &str, _text: &str, _clock: &dyn Clock) -> Result<Feedback> {
    Ok(Feedback::default())
}

/// Deletes an Open comment.
pub fn delete(_vault: &mut Vault, _id: &str) -> Result<()> {
    Ok(())
}

/// Every Open row oldest first, merged with the open tag Corrections.
pub fn list_open(_vault: &Vault) -> Result<Vec<Feedback>> {
    Ok(Vec::new())
}

/// Every row of `note_id` (`None`: rows with no note), all statuses, newest
/// first, merged with its open tag Corrections.
pub fn list_for_note(_vault: &Vault, _note_id: Option<&str>) -> Result<Vec<Feedback>> {
    Ok(Vec::new())
}

/// Marks a row Handled with `reply` and writes `changes` as `agent_changes`.
pub fn resolve(
    _vault: &mut Vault,
    _id: &str,
    _reply: &str,
    _changes: &[ChangeEntry],
    _clock: &dyn Clock,
) -> Result<Feedback> {
    Ok(Feedback::default())
}

/// Stores a chat comment, already Handled, and writes `changes`.
pub fn record_chat(
    _vault: &mut Vault,
    _text: &str,
    _note_id: Option<&str>,
    _date: Option<&str>,
    _reply: &str,
    _changes: &[ChangeEntry],
    _clock: &dyn Clock,
) -> Result<Feedback> {
    Ok(Feedback::default())
}
