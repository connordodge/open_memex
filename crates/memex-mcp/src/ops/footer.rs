//! Footer ops: `memex footer add` (C2.3).

use memex_core::embedder::Embedder;
use memex_core::footer::{self, ChipOrigin};
use memex_core::{Clock, NoteId, Vault};
use serde::Serialize;

/// The input of [`add`].
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    pub daily_note_id: String,
    pub topic_note_id: String,
}

/// The `memex footer add` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddOutput {
    pub vault_id: String,
    pub daily_note_id: String,
    pub topic_note_id: String,
    /// The chip's origin after the call (`person`).
    pub origin: String,
    /// The host note's version after the call.
    pub version: i64,
}

/// Records a `person` chip for the topic on the note `daily_note_id`, which
/// may be any note but a guide (Req 17, Spec #234 R17, R46). Idempotent; an
/// `excerpt` chip is upgraded in place.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = clock;
    let daily = NoteId::parse(&input.daily_note_id)?;
    let topic = NoteId::parse(&input.topic_note_id)?;
    let written = footer::set_chip(vault, &daily, &topic, ChipOrigin::Person, embedder)?;
    let origin = written.origin.unwrap_or(ChipOrigin::Person);
    Ok(AddOutput {
        vault_id: vault.vault_id().to_string(),
        daily_note_id: daily.to_string(),
        topic_note_id: topic.to_string(),
        origin: origin.as_str().to_string(),
        version: written.note.version,
    })
}
