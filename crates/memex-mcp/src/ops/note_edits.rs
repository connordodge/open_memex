//! Agent read-only and agent-edit revision ops (Spec #7 Req 37; rulings D5,
//! D11, D13, D14): `memex read-only set|clear` and `memex revisions
//! list|restore`, and the app API routes that answer with the same structs.
//!
//! Frozen output (D14):
//!
//! - [`set_agent_read_only`] -> `{vault_id, note_id, agent_read_only}`
//! - [`note_revisions`] -> `{vault_id, revisions: [{id, agent_change_id | null,
//!   created_at}]}`, newest first
//! - [`restore_note_revision`] -> `{vault_id, note_id, version, content_md}`
//!
//! These are person writes (`Caller::Person`).

use memex_core::daily;
use memex_core::embedder::Embedder;
use memex_core::note_edits::{self, NoteRevision};
use memex_core::notes::{self, NoteId};
use memex_core::{Clock, Vault};
use serde::Serialize;

/// The input of [`set_agent_read_only`].
#[derive(Debug, Clone, Default)]
pub struct SetAgentReadOnlyInput {
    pub note_id: String,
    /// `true` sets the flag, `false` clears it.
    pub agent_read_only: bool,
}

/// The `memex read-only set|clear` output line and the
/// `PUT /notes/{note_id}/agent-read-only` body.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct AgentReadOnlyOutput {
    pub vault_id: String,
    pub note_id: String,
    /// The flag after the call.
    pub agent_read_only: bool,
}

/// Sets or clears the note's Agent read-only flag (D5). Setting it on a
/// daily note or on the Vault Guide is `role_rule`; clearing always works;
/// the value the note already has succeeds and writes nothing. An unknown
/// note is `not_found`.
pub fn set_agent_read_only(
    vault: &mut Vault,
    input: SetAgentReadOnlyInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AgentReadOnlyOutput> {
    let _ = (clock, embedder);
    let id = NoteId::parse(&input.note_id)?;
    notes::set_agent_read_only(vault, &id, input.agent_read_only)?;
    Ok(AgentReadOnlyOutput {
        vault_id: vault.vault_id().to_string(),
        note_id: id.as_str().to_string(),
        agent_read_only: input.agent_read_only,
    })
}

/// The input of [`note_revisions`].
#[derive(Debug, Clone, Default)]
pub struct NoteRevisionsInput {
    pub note_id: String,
}

/// The `memex revisions list` output line and the
/// `GET /notes/{note_id}/revisions` body.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct NoteRevisionsOutput {
    pub vault_id: String,
    /// Newest first.
    pub revisions: Vec<NoteRevision>,
}

/// The note's agent-edit revisions, newest first. An unknown note is
/// `not_found`.
pub fn note_revisions(
    vault: &mut Vault,
    input: NoteRevisionsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<NoteRevisionsOutput> {
    let _ = (clock, embedder);
    let id = NoteId::parse(&input.note_id)?;
    let revisions = note_edits::revisions(vault, &id)?;
    Ok(NoteRevisionsOutput {
        vault_id: vault.vault_id().to_string(),
        revisions,
    })
}

/// The input of [`restore_note_revision`].
#[derive(Debug, Clone, Default)]
pub struct RestoreNoteRevisionInput {
    pub revision_id: String,
    /// The note the revision must belong to (the API path's `{note_id}`,
    /// D11); `None` from the CLI.
    pub note_id: Option<String>,
}

/// The `memex revisions restore` output line and the
/// `POST /notes/{note_id}/revisions/{revision_id}/restore` body.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct RestoreNoteRevisionOutput {
    pub vault_id: String,
    pub note_id: String,
    /// The note's version after the call.
    pub version: i64,
    /// The note's stored body after the call.
    pub content_md: String,
}

/// Restores the person section a revision kept, keeping the replaced text as
/// a new revision. Its Activity entry is dated today in the clock's zone. An
/// unknown, pruned or (with `note_id`) foreign revision is `not_found`.
pub fn restore_note_revision(
    vault: &mut Vault,
    input: RestoreNoteRevisionInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RestoreNoteRevisionOutput> {
    let note_id = input.note_id.as_deref().map(NoteId::parse).transpose()?;
    let day = daily::today_with_clock(clock).to_string();
    let out = note_edits::restore(
        vault,
        &input.revision_id,
        note_id.as_ref(),
        &day,
        clock,
        embedder,
    )?;
    Ok(RestoreNoteRevisionOutput {
        vault_id: vault.vault_id().to_string(),
        note_id: out.note_id.as_str().to_string(),
        version: out.version,
        content_md: out.content_md,
    })
}
