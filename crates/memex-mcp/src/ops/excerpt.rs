//! Excerpt ops: `memex excerpt rm` (C2.4).

use memex_core::embedder::Embedder;
use memex_core::excerpts;
use memex_core::{Caller, Clock, NoteId, Vault};
use serde::Serialize;

use crate::cli::InvalidArgument;

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
