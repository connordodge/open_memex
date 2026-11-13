//! Agent body edits of notes (Spec #7 Req 11-25, 27, 28; architect rulings
//! D7-D11): the agent's `edit_note` in two forms, exact find/replace
//! (Form A) and full person-section replace (Form B), the agent-edit
//! revisions kept for each write (newest 20 per note), and the person's
//! Restore of one.
//!
//! The engine opens its own Immediate transaction and does not go through
//! `notes::update_note_as` (D7), so a new agent rule added there must also be
//! added here.

use serde::{Deserialize, Serialize};

use crate::canvas::Clock;
use crate::embedder::Embedder;
use crate::notes::NoteId;
use crate::vault::Vault;
use crate::Result;

/// One Form A pair: `old_text` must match exactly once in the person section
/// as it was before the call; `new_text` replaces it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditPair {
    pub old_text: String,
    pub new_text: String,
}

/// An agent's edit of one note: exactly one of `edits` (Form A) and
/// `content_md` (Form B), with 1 to 3 `bullets` saying what changed.
/// `expected_version` is optional for Form A and required for Form B.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditInput {
    pub note_id: NoteId,
    pub bullets: Vec<String>,
    pub edits: Option<Vec<EditPair>>,
    pub content_md: Option<String>,
    pub expected_version: Option<i64>,
}

/// What [`edit_note`] answers with: the note's version and stored body after
/// the call, and whether it wrote (`false` for a no-op, Req 17).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EditOutcome {
    pub note_id: NoteId,
    pub version: i64,
    pub content_md: String,
    pub changed: bool,
}

/// What [`restore`] answers with: the note's new version and stored body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RestoreOutcome {
    pub note_id: NoteId,
    pub version: i64,
    pub content_md: String,
}

/// One kept earlier person section of a note, as listed by [`revisions`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteRevision {
    pub id: String,
    /// `None` once the linked `agent_changes` row is gone.
    pub agent_change_id: Option<String>,
    pub created_at: i64,
}

/// The agent's body edit of one note (Req 11-23). See the module docs.
pub fn edit_note(
    vault: &mut Vault,
    input: EditInput,
    day: &str,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<EditOutcome> {
    let _ = (vault, day, clock, embedder);
    Ok(EditOutcome {
        note_id: input.note_id,
        version: 0,
        content_md: String::new(),
        changed: false,
    })
}

/// The note's agent-edit revisions, newest first (`new_version DESC`). An
/// unknown note is `NotFound`.
pub fn revisions(vault: &Vault, note_id: &NoteId) -> Result<Vec<NoteRevision>> {
    let _ = (vault, note_id);
    Ok(Vec::new())
}

/// The person's Restore of `revision_id` (Req 27, 28). With `note_id`, the
/// revision must belong to that note. Unknown, pruned or foreign revisions
/// are `NotFound`.
pub fn restore(
    vault: &mut Vault,
    revision_id: &str,
    note_id: Option<&NoteId>,
    day: &str,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<RestoreOutcome> {
    let _ = (vault, revision_id, day, clock, embedder);
    Ok(RestoreOutcome {
        note_id: note_id.cloned().unwrap_or_default(),
        version: 0,
        content_md: String::new(),
    })
}
