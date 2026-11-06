use rusqlite::params;

use crate::vault::Vault;
use crate::Result;

/// A tag found in a person section: its lowercase name and the first line
/// holding it (Spec #234 R4-R8, WI #236).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractedTag {
    pub name: String,
    pub first_line: String,
}

/// The tags written in `person_text`, sorted by name, one per name.
pub fn extract(person_text: &str) -> Vec<ExtractedTag> {
    let _ = person_text;
    Vec::new()
}

/// The person section of a non-daily note body: above the first marker line
/// outside fenced code, without a leading frontmatter block.
pub fn person_section(body: &str) -> &str {
    let _ = body;
    ""
}

/// `Some(lowercase)` only when the whole `input` is one valid tag name.
pub fn normalize_name(input: &str) -> Option<String> {
    let _ = input;
    None
}

/// True only for the system tags `inbox` and `agent-authored` (R20, D17).
pub fn is_system_tag(name: &str) -> bool {
    let _ = name;
    false
}

pub fn add_tag(vault: &Vault, note_id: &str, tag: &str) -> Result<()> {
    vault.connection_ref().execute(
        "INSERT OR IGNORE INTO tags (note_id, tag) VALUES (?, ?)",
        params![note_id, tag],
    )?;
    Ok(())
}

pub fn remove_tag(vault: &Vault, note_id: &str, tag: &str) -> Result<()> {
    vault.connection_ref().execute(
        "DELETE FROM tags WHERE note_id = ? AND tag = ?",
        params![note_id, tag],
    )?;
    Ok(())
}

pub fn tags_for_note(vault: &Vault, note_id: &str) -> Result<Vec<String>> {
    let mut stmt = vault
        .connection_ref()
        .prepare("SELECT tag FROM tags WHERE note_id = ? ORDER BY tag")?;
    let mut rows = stmt.query(params![note_id])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        out.push(r.get::<_, String>(0)?);
    }
    Ok(out)
}
