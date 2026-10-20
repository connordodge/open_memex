//! Footer ops: `memex footer add` (C2.3).

use memex_core::embedder::Embedder;
use memex_core::{Clock, Vault};
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
    /// The daily note's version after the call.
    pub version: i64,
}

/// Records a `person` chip for the topic on the daily note (Req 17).
/// Idempotent; an `excerpt` chip is upgraded in place.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::footer::add is not implemented yet (#73)")
}
