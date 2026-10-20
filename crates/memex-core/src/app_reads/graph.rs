//! App API reads for the graph view and the activity log (#85): the rows the
//! app's `GraphReads` (`app/lib/src/db/graph_reads.dart`) and `ActivityReads`
//! (`app/lib/src/db/activity_reads.dart`) read today, for the graph routes of
//! the vault server. Field names are the Dart models' in snake case.

use serde::Serialize;

use crate::{Result, Vault};

/// A row of `GET /graph/notes`: the app's `GraphNoteRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GraphNoteRow {
    pub id: String,
    pub title: String,
    /// `json_extract(frontmatter, '$.role')` when the frontmatter is valid
    /// JSON and that value comes back as text; `None` otherwise.
    pub role: Option<String>,
}

/// A row of `GET /graph/links`: the app's `GraphLinkRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GraphLinkRow {
    pub from: String,
    pub to: String,
    pub kind: String,
    pub label: Option<String>,
}

/// A row of `GET /notes/{note_id}/agent-changes`: the app's `AgentChangeRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AgentChangeRow {
    pub id: String,
    pub note_id: String,
    pub day: String,
    /// Unix ms.
    pub created_at: i64,
    pub bullets: Vec<String>,
}

/// `GraphReads.graphNotes`: every note with its role, ordered by id.
pub fn graph_notes(vault: &Vault) -> Result<Vec<GraphNoteRow>> {
    let _ = vault;
    todo!("#85: graph_notes")
}

/// `GraphReads.graphLinks`: every link whose target note exists, ordered by
/// source note, then position.
pub fn graph_links(vault: &Vault) -> Result<Vec<GraphLinkRow>> {
    let _ = vault;
    todo!("#85: graph_links")
}

/// `ActivityReads.agentChanges`: `note_id`'s change-log rows, newest
/// `created_at` first, then newest inserted first.
pub fn agent_changes(vault: &Vault, note_id: &str) -> Result<Vec<AgentChangeRow>> {
    let _ = (vault, note_id);
    todo!("#85: agent_changes")
}
