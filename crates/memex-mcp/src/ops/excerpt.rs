//! Excerpt ops: `memex excerpt rm` (C2.4).

use memex_core::embedder::Embedder;
use memex_core::{Clock, Vault};
use serde::Serialize;

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub topic_note_id: String,
    /// The daily note's date, `YYYY-MM-DD`.
    pub date: String,
    /// The transclusion's endpoint block ids: one id, or `from, to`.
    pub block_ids: Vec<String>,
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
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::excerpt::rm is not implemented yet (#73)")
}
