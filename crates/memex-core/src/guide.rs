//! The Vault Guide (#233 R24-R31): the one `role: guide` note of a vault,
//! created on first read, whose only agent write path is [`update`].

use serde::Serialize;

use crate::canvas::Clock;
use crate::embedder::Embedder;
use crate::vault::Vault;
use crate::Result;

/// The guide as read or written: what `get_vault_guide` and
/// `update_vault_guide` answer with (field names are a contract, #256).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GuideDoc {
    pub note_id: String,
    pub version: i64,
    pub content_md: String,
}

/// One kept earlier text of the guide, as listed by [`revisions`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GuideRevision {
    pub id: String,
    /// `None` once the linked `agent_changes` row is gone (`ON DELETE SET NULL`).
    pub agent_change_id: Option<String>,
    pub created_at: i64,
}

/// The guide, created on the first read: `role: guide`, titled `Vault Guide`
/// (`Vault Guide 2`, and so on, when that title is taken), with empty
/// `## Framework` and `## Decisions` sections. A process that loses the race
/// to create it returns the winner's note.
pub fn get_or_create(
    _vault: &mut Vault,
    _clock: &dyn Clock,
    _embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    unimplemented!()
}

/// [`get_or_create`] with a test seam: `before_create` runs once per create
/// attempt, after the free title is picked and before the create, with no
/// transaction open. It does not run when the guide is found.
#[doc(hidden)]
pub fn get_or_create_with_hook(
    _vault: &mut Vault,
    _clock: &dyn Clock,
    _embedder: Option<&dyn Embedder>,
    _before_create: &mut dyn FnMut(&mut Vault),
) -> Result<GuideDoc> {
    unimplemented!()
}

/// The agent's one write path to the guide. A stale `expected_version` fails
/// with `version_conflict`, invalid `bullets` with `change_entries_invalid`,
/// and neither writes anything. The note, one `vault_guide_revisions` row
/// holding the previous text and one `agent_changes` row dated `day` commit in
/// one transaction; the note is reindexed afterwards.
pub fn update(
    _vault: &mut Vault,
    _expected_version: i64,
    _content_md: &str,
    _bullets: &[String],
    _day: &str,
    _clock: &dyn Clock,
    _embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    unimplemented!()
}

/// A person write replacing the current text with that of `revision_id`
/// (`not_found` when unknown). The replaced text is kept as a new revision,
/// linked to one new `agent_changes` row with the bullet
/// `Restored an earlier version`, under the same transaction as [`update`].
pub fn restore(
    _vault: &mut Vault,
    _revision_id: &str,
    _day: &str,
    _clock: &dyn Clock,
    _embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    unimplemented!()
}

/// The guide's revisions, newest first.
pub fn revisions(_vault: &Vault) -> Result<Vec<GuideRevision>> {
    Ok(Vec::new())
}
