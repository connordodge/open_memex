use rusqlite::params;

use crate::vault::Vault;
use crate::Result;

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
