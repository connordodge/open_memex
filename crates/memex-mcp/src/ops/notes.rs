//! Note ops: `memex add`, `memex update`, `memex get` and `memex rm`.

use memex_core::embedder::Embedder;
use memex_core::{Clock, Vault};
use serde::Serialize;
use serde_json::{Map, Value};

use crate::cli::Role;

/// The input of [`add`]: the note body plus `memex add`'s flags.
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    /// The title. `None` derives it from the first line, or, for a daily
    /// note, uses today's date from the clock.
    pub title: Option<String>,
    /// The note body (stdin for the CLI).
    pub content_md: String,
    /// Tags added to the note after it is created.
    pub tags: Vec<String>,
    /// The `role` frontmatter value.
    pub role: Option<Role>,
}

/// What `memex add` prints: `Created note` (or `Adopted note`), then
/// `note_id`, `title`, and `tags` when there are any.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddOutput {
    pub note_id: String,
    pub title: String,
    pub tags: Vec<String>,
    /// `true` when a daily add adopted a role-less note titled with the date.
    pub adopted: bool,
}

/// Creates a note on the person path (adopting a role-less note titled with
/// the date for a daily add), tags it and indexes it.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::notes::add is not implemented yet (#73)")
}

/// The input of [`update`]: `memex update`'s flags plus the new body.
#[derive(Debug, Clone, Default)]
pub struct UpdateInput {
    pub note_id: String,
    pub expected_version: i64,
    /// The new title; `None` keeps the current one.
    pub title: Option<String>,
    /// The new body (stdin for the CLI).
    pub content_md: String,
    /// Skip the pass that rewrites `[[OldTitle]]` in linkers.
    pub no_rename_links: bool,
}

/// The `memex update` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UpdateOutput {
    pub note_id: String,
    pub version: i64,
    pub updated_at: i64,
}

/// Saves a note on the person path and reindexes it.
pub fn update(
    vault: &mut Vault,
    input: UpdateInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<UpdateOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::notes::update is not implemented yet (#73)")
}

/// The input of [`get`].
#[derive(Debug, Clone, Default)]
pub struct GetInput {
    pub note_id: String,
    /// Add `links` and `backlinks`, grouped by kind.
    pub include_links: bool,
}

/// The `memex get` object.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GetOutput {
    pub note_id: String,
    pub title: String,
    pub content_md: String,
    pub frontmatter: Value,
    pub version: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub tags: Vec<String>,
    /// The review and transclusion fields, at the top level (D7).
    #[serde(flatten)]
    pub fields: Map<String, Value>,
    /// Outgoing links by kind; `Some` only with `include_links`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<Map<String, Value>>,
    /// Incoming links by kind; `Some` only with `include_links`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backlinks: Option<Map<String, Value>>,
}

/// Reads one note with its tags, review and transclusion fields and, when
/// asked, its links.
pub fn get(
    vault: &mut Vault,
    input: GetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<GetOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::notes::get is not implemented yet (#73)")
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub note_id: String,
    pub expected_version: i64,
}

/// The `memex rm` output line (C2.2).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RmOutput {
    pub vault_id: String,
    pub note_id: String,
    pub deleted: bool,
}

/// Deletes a note on the person path (D24).
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::notes::rm is not implemented yet (#73)")
}
