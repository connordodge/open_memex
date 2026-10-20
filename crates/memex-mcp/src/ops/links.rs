//! Link ops: `memex add-link` and `memex update-link`.

use memex_core::embedder::Embedder;
use memex_core::{Clock, Vault};
use serde::Serialize;

/// The input of [`add_link`].
#[derive(Debug, Clone)]
pub struct AddLinkInput {
    /// Source note id.
    pub from: String,
    /// Target note id.
    pub to: String,
    /// Link kind (the CLI defaults it to `references`).
    pub kind: String,
    /// Optional display alias (`[[Title|alias]]`).
    pub label: Option<String>,
}

/// The `memex add-link` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddLinkOutput {
    pub vault_id: String,
    pub link_id: Option<String>,
    pub from: String,
    pub to: String,
    pub kind: String,
    pub source: String,
    /// `true` when a link of this kind already ran from `from` to `to`;
    /// nothing was written.
    pub was_existing: bool,
    /// The source note's version after the call.
    pub note_version: i64,
}

/// Adds a wikilink to the source note's markdown on the person path and
/// reindexes it. Idempotent per (from, to, kind).
pub fn add_link(
    vault: &mut Vault,
    input: AddLinkInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddLinkOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::links::add_link is not implemented yet (#73)")
}

/// The input of [`update_link`].
#[derive(Debug, Clone, Default)]
pub struct UpdateLinkInput {
    pub link_id: String,
    /// The new kind; `None` keeps it.
    pub kind: Option<String>,
    /// The new label; `None` keeps it.
    pub label: Option<String>,
    /// Clear the label (overrides `label`).
    pub clear_label: bool,
}

/// The `memex update-link` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UpdateLinkOutput {
    pub from_note_id: String,
    pub kind: String,
    pub label: Option<String>,
    pub link_id: String,
    pub position: i64,
    pub source: String,
    pub to_note_id: Option<String>,
    pub vault_id: String,
}

/// Rewrites a wikilink's kind and/or label in place on the person path.
pub fn update_link(
    vault: &mut Vault,
    input: UpdateLinkInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<UpdateLinkOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::links::update_link is not implemented yet (#73)")
}
