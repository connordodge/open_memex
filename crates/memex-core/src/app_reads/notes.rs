//! App API reads for notes (#81): the rows the app's `VaultDb` reads today,
//! for the notes routes of the vault server.

use serde::Serialize;

use crate::{Result, Vault};

/// A row of `GET /notes`: the app's `NoteListItem`, in snake case.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteListItem {
    pub id: String,
    pub title: String,
    pub snippet: String,
    pub version: i64,
    pub updated_at: i64,
}

/// `VaultDb.listNotes`: up to `limit` notes, newest `updated_at` first,
/// each with its [`snippet`].
pub fn list_notes(vault: &Vault, limit: i64) -> Result<Vec<NoteListItem>> {
    let _ = (vault, limit);
    todo!("#81: list_notes")
}

/// `VaultDb._snippet` (ruling D10b): heading markers stripped, the first
/// non-blank line, trimmed; a line over 120 UTF-16 units is cut to 117
/// units (116 when the cut would split a surrogate pair), trimmed, plus `…`.
pub fn snippet(content_md: &str) -> String {
    let _ = content_md;
    todo!("#81: snippet")
}
