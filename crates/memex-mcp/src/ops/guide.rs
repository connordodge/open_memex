//! Vault Guide ops: `memex guide get|revisions|restore` (#256).

use memex_core::daily;
use memex_core::embedder::Embedder;
use memex_core::guide::{self, GuideDoc, GuideRevision};
use memex_core::{Clock, Vault};
use serde::Serialize;

use crate::ops::folder::VaultScoped;

/// The input of [`get`].
#[derive(Debug, Clone, Default)]
pub struct GetInput;

/// The `memex guide get` output line: `vault_id`, then the guide.
pub type GetOutput = VaultScoped<GuideDoc>;

/// The guide, created on the first read.
pub fn get(
    vault: &mut Vault,
    input: GetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<GetOutput> {
    let _ = input;
    let body = guide::get_or_create(vault, clock, embedder)?;
    Ok(VaultScoped {
        vault_id: vault.vault_id().to_string(),
        body,
    })
}

/// The input of [`revisions`].
#[derive(Debug, Clone, Default)]
pub struct RevisionsInput;

/// The `memex guide revisions` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RevisionsOutput {
    pub vault_id: String,
    /// Newest first.
    pub revisions: Vec<GuideRevision>,
}

/// The guide's kept earlier texts. Read-only: no guide yet has no revisions.
pub fn revisions(
    vault: &mut Vault,
    input: RevisionsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RevisionsOutput> {
    let _ = (input, clock, embedder);
    let revisions = guide::revisions(vault)?;
    Ok(RevisionsOutput {
        vault_id: vault.vault_id().to_string(),
        revisions,
    })
}

/// The input of [`restore`].
#[derive(Debug, Clone, Default)]
pub struct RestoreInput {
    pub revision_id: String,
}

/// The `memex guide restore` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RestoreOutput {
    pub vault_id: String,
    pub note_id: String,
    /// The guide's version after the call.
    pub version: i64,
}

/// Returns the guide to an earlier text, keeping the replaced one as a new
/// revision. Its Activity entry is dated today in the clock's zone (R40), never
/// from the request.
pub fn restore(
    vault: &mut Vault,
    input: RestoreInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RestoreOutput> {
    let day = daily::today_with_clock(clock).to_string();
    let doc = guide::restore(vault, &input.revision_id, &day, clock, embedder)?;
    Ok(RestoreOutput {
        vault_id: vault.vault_id().to_string(),
        note_id: doc.note_id,
        version: doc.version,
    })
}
