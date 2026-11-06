//! Feedback ops: `memex feedback add|edit|rm|ls` (#256).

use memex_core::embedder::Embedder;
use memex_core::feedback::{self, Feedback};
use memex_core::{Clock, Vault};
use serde::Serialize;

use crate::cli::InvalidArgument;

/// The input of [`add`].
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    pub note_id: String,
    /// The day the comment is about, `YYYY-MM-DD`.
    pub date: String,
    /// The Activity entry the comment is on.
    pub change_id: String,
    pub text: String,
}

/// Stores an Open comment, stamped with the clock.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<Feedback> {
    let _ = embedder;
    Ok(feedback::add(
        vault,
        &input.note_id,
        &input.date,
        &input.change_id,
        &input.text,
        clock,
    )?)
}

/// The input of [`edit`].
#[derive(Debug, Clone, Default)]
pub struct EditInput {
    pub id: String,
    pub text: String,
}

/// Replaces the text of an Open comment, stamped with the clock.
pub fn edit(
    vault: &mut Vault,
    input: EditInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<Feedback> {
    let _ = embedder;
    Ok(feedback::edit(vault, &input.id, &input.text, clock)?)
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub id: String,
}

/// The `memex feedback rm` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RmOutput {
    pub vault_id: String,
    pub id: String,
}

/// Deletes an Open comment.
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = (clock, embedder);
    feedback::delete(vault, &input.id)?;
    Ok(RmOutput {
        vault_id: vault.vault_id().to_string(),
        id: input.id,
    })
}

/// The input of [`ls`].
#[derive(Debug, Clone, Default)]
pub struct LsInput {
    /// The note whose rows to list; `None` lists the rows with no note.
    pub note_id: Option<String>,
}

impl LsInput {
    /// An empty note id is a mistake, never the no-note list. [`ls`] makes the
    /// same check.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.note_id.as_deref() == Some("") {
            let msg = "note_id must not be empty".to_string();
            return Err(InvalidArgument(msg).into());
        }
        Ok(())
    }
}

/// The `memex feedback ls` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LsOutput {
    pub vault_id: String,
    /// All statuses, newest first.
    pub feedback: Vec<Feedback>,
}

/// Lists one note's rows, or the rows with no note. An unknown note id has no
/// rows, so it lists nothing.
pub fn ls(
    vault: &mut Vault,
    input: LsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<LsOutput> {
    let _ = (clock, embedder);
    input.validate()?;
    let feedback = feedback::list_for_note(vault, input.note_id.as_deref())?;
    Ok(LsOutput {
        vault_id: vault.vault_id().to_string(),
        feedback,
    })
}
