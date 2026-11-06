//! Excerpt ops: `memex excerpt rm` (C2.4), `memex excerpt add|remove-block|move`
//! and `memex filing` (#256).

use memex_core::embedder::Embedder;
use memex_core::excerpts;
use memex_core::filing::{self as core_filing, DayFiling};
use memex_core::{Caller, Clock, MemexError, Note, NoteId, Vault};
use serde::Serialize;

use crate::cli::InvalidArgument;
use crate::ops::folder::VaultScoped;

/// Most characters (Unicode scalar values) a note on a block write may have
/// (R17), counted on the raw text as core counts a comment (D40).
const MAX_NOTE_CHARS: usize = 2000;

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub topic_note_id: String,
    /// The daily note's date, `YYYY-MM-DD`.
    pub date: String,
    /// The transclusion's endpoint block ids: one id, or `from, to`.
    pub block_ids: Vec<String>,
}

impl RmInput {
    /// The checks `memex excerpt rm` makes before it opens the vault, in its
    /// order: no blank block id, then a well-formed topic id. [`rm`] makes
    /// the same checks.
    pub fn validate(&self) -> anyhow::Result<NoteId> {
        if self.block_ids.iter().any(|id| id.trim().is_empty()) {
            let msg = "--block-ids must list one or two non-empty block ids".to_string();
            return Err(InvalidArgument(msg).into());
        }
        Ok(NoteId::parse(&self.topic_note_id)?)
    }
}

/// The `memex excerpt rm` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RmOutput {
    pub vault_id: String,
    pub topic_note_id: String,
    /// The topic note's version after the call.
    pub version: i64,
}

/// Removes one transclusion from a topic note on the person path (Req 14).
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = clock;
    let topic = input.validate()?;
    let written = excerpts::remove_excerpt(
        vault,
        &topic,
        &input.date,
        &input.block_ids,
        Caller::Person,
        embedder,
    )?;
    Ok(RmOutput {
        vault_id: vault.vault_id().to_string(),
        topic_note_id: written.id.to_string(),
        version: written.version,
    })
}

/// A blank block id is never sent to core.
fn check_block_id(block_id: &str) -> anyhow::Result<()> {
    if block_id.trim().is_empty() {
        let msg = "block_id must not be blank".to_string();
        return Err(InvalidArgument(msg).into());
    }
    Ok(())
}

/// The note a block write stores as its Correction's `text`: an absent, empty
/// or whitespace-only note is no note, more than [`MAX_NOTE_CHARS`] is
/// `feedback_invalid`, and anything else is stored as given.
fn stored_note(note: Option<&str>) -> Result<Option<&str>, MemexError> {
    match note {
        Some(text) if text.trim().is_empty() => Ok(None),
        Some(text) if text.chars().count() > MAX_NOTE_CHARS => Err(MemexError::FeedbackInvalid(
            format!("a note has at most {MAX_NOTE_CHARS} characters"),
        )),
        other => Ok(other),
    }
}

/// The `{vault_id, topic_note_id, version}` answer to one topic write.
fn topic_written(vault: &Vault, written: &Note) -> RmOutput {
    RmOutput {
        vault_id: vault.vault_id().to_string(),
        topic_note_id: written.id.to_string(),
        version: written.version,
    }
}

/// The input of [`add`].
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    pub topic_note_id: String,
    /// The daily note's date, `YYYY-MM-DD`.
    pub date: String,
    pub block_id: String,
    /// The person's `Why?`, stored as the Correction's `text`.
    pub note: Option<String>,
}

impl AddInput {
    /// The checks `memex excerpt add` makes before it opens the vault: no
    /// blank block id, a well-formed topic id, a note within the limit.
    /// [`add`] makes the same checks.
    pub fn validate(&self) -> anyhow::Result<NoteId> {
        check_block_id(&self.block_id)?;
        let topic = NoteId::parse(&self.topic_note_id)?;
        stored_note(self.note.as_deref())?;
        Ok(topic)
    }
}

/// The `memex excerpt add` output line.
pub type AddOutput = RmOutput;

/// Files one block of a day in a topic note on the person path.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = clock;
    let topic = input.validate()?;
    let written = excerpts::add_excerpt_noted(
        vault,
        &topic,
        &input.date,
        std::slice::from_ref(&input.block_id),
        Caller::Person,
        embedder,
        stored_note(input.note.as_deref())?,
    )?;
    Ok(topic_written(vault, &written))
}

/// The input of [`remove_block`].
#[derive(Debug, Clone, Default)]
pub struct RemoveBlockInput {
    pub topic_note_id: String,
    /// The daily note's date, `YYYY-MM-DD`.
    pub date: String,
    pub block_id: String,
    /// The person's `Why?`, stored as the Correction's `text`.
    pub note: Option<String>,
}

impl RemoveBlockInput {
    /// The checks `memex excerpt remove-block` makes before it opens the
    /// vault: no blank block id, a well-formed topic id, a note within the
    /// limit. [`remove_block`] makes the same checks.
    pub fn validate(&self) -> anyhow::Result<NoteId> {
        check_block_id(&self.block_id)?;
        let topic = NoteId::parse(&self.topic_note_id)?;
        stored_note(self.note.as_deref())?;
        Ok(topic)
    }
}

/// The `memex excerpt remove-block` output line.
pub type RemoveBlockOutput = RmOutput;

/// Removes one block of a day from a topic note on the person path.
pub fn remove_block(
    vault: &mut Vault,
    input: RemoveBlockInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RemoveBlockOutput> {
    let _ = clock;
    let topic = input.validate()?;
    let written = excerpts::remove_excerpt_block_noted(
        vault,
        &topic,
        &input.date,
        &input.block_id,
        Caller::Person,
        embedder,
        stored_note(input.note.as_deref())?,
    )?;
    Ok(topic_written(vault, &written))
}

/// The input of [`move_block`].
#[derive(Debug, Clone, Default)]
pub struct MoveInput {
    /// The daily note's date, `YYYY-MM-DD`.
    pub date: String,
    pub block_id: String,
    pub from_topic_note_id: String,
    pub to_topic_note_id: String,
    /// The person's `Why?`, stored as the Correction's `text`.
    pub note: Option<String>,
}

impl MoveInput {
    /// The checks `memex excerpt move` makes before it opens the vault: no
    /// blank block id, two well-formed topic ids that differ, a note within
    /// the limit. [`move_block`] makes the same checks. Returns the source,
    /// then the target.
    pub fn validate(&self) -> anyhow::Result<(NoteId, NoteId)> {
        check_block_id(&self.block_id)?;
        let from = NoteId::parse(&self.from_topic_note_id)?;
        let to = NoteId::parse(&self.to_topic_note_id)?;
        if from == to {
            let msg = "a block moves between two different topic notes".to_string();
            return Err(InvalidArgument(msg).into());
        }
        stored_note(self.note.as_deref())?;
        Ok((from, to))
    }
}

/// The `memex excerpt move` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MoveOutput {
    pub vault_id: String,
    pub from_topic_note_id: String,
    /// The source topic note's version after the call.
    pub from_version: i64,
    pub to_topic_note_id: String,
    /// The target topic note's version after the call.
    pub to_version: i64,
}

/// Moves one block of a day from one topic note to another on the person path.
pub fn move_block(
    vault: &mut Vault,
    input: MoveInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<MoveOutput> {
    let _ = clock;
    let (from, to) = input.validate()?;
    let moved = excerpts::move_block_noted(
        vault,
        &input.date,
        &input.block_id,
        &from,
        &to,
        Caller::Person,
        embedder,
        stored_note(input.note.as_deref())?,
    )?;
    Ok(MoveOutput {
        vault_id: vault.vault_id().to_string(),
        from_topic_note_id: moved.from.id.to_string(),
        from_version: moved.from.version,
        to_topic_note_id: moved.to.id.to_string(),
        to_version: moved.to.version,
    })
}

/// The input of [`filing`].
#[derive(Debug, Clone, Default)]
pub struct FilingInput {
    /// The daily note's date, `YYYY-MM-DD`.
    pub date: String,
}

/// The `memex filing` output line: `vault_id`, then the day's filing.
pub type FilingOutput = VaultScoped<DayFiling>;

/// Where the blocks of one day are filed. Read-only.
pub fn filing(
    vault: &mut Vault,
    input: FilingInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<FilingOutput> {
    let _ = (clock, embedder);
    let body = core_filing::day_filing(vault, &input.date)?;
    Ok(VaultScoped {
        vault_id: vault.vault_id().to_string(),
        body,
    })
}
