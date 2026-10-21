//! App API reads for topics (#83): the rows the app's `TopicsReads`
//! (app/lib/src/db/topics_reads.dart) reads today, for the topics routes of
//! the vault server. Row fields are the Dart models' fields in snake case.

use serde::Serialize;

use crate::{Result, Vault};

/// A folder row of `GET /smart-folders` (the app's `SmartFolderRow`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolderRow {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub pinned: bool,
}

/// A membership row of `GET /smart-folders` (the app's
/// `SmartFolderMemberRow`): the member note's title comes from `notes`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolderMemberRow {
    pub folder_id: String,
    pub note_id: String,
    pub title: String,
    pub pinned: bool,
}

/// Every Smart Folder and every membership (the app's `SmartFolderData`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolderData {
    pub folders: Vec<SmartFolderRow>,
    pub members: Vec<SmartFolderMemberRow>,
}

/// A row of `GET /unsorted` (the app's `UnsortedNoteRow`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UnsortedNoteRow {
    pub note_id: String,
    pub title: String,
    pub role: Option<String>,
}

/// `TopicsReads.smartFolders`: every folder (by `id`) and every membership
/// (by `folder_id`, then `note_id`).
pub fn smart_folders(vault: &Vault) -> Result<SmartFolderData> {
    let conn = vault.conn();
    let mut stmt =
        conn.prepare("SELECT id, name, parent_id, pinned FROM smart_folders ORDER BY id")?;
    let folders = stmt
        .query_map([], |r| {
            Ok(SmartFolderRow {
                id: r.get(0)?,
                name: r.get(1)?,
                parent_id: r.get(2)?,
                pinned: r.get(3)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut stmt = conn.prepare(
        "SELECT m.smart_folder_id, m.note_id, n.title, m.pinned
         FROM smart_folder_members m JOIN notes n ON n.id = m.note_id
         ORDER BY m.smart_folder_id, m.note_id",
    )?;
    let members = stmt
        .query_map([], |r| {
            Ok(SmartFolderMemberRow {
                folder_id: r.get(0)?,
                note_id: r.get(1)?,
                title: r.get(2)?,
                pinned: r.get(3)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(SmartFolderData { folders, members })
}

/// `TopicsReads.unsortedNotes`, by `note_id`: every note in no Smart Folder
/// whose role is not `daily`; invalid-JSON frontmatter counts as role-less.
pub fn unsorted_notes(vault: &Vault) -> Result<Vec<UnsortedNoteRow>> {
    let mut stmt = vault.conn().prepare(
        "SELECT id, title, role FROM (
             SELECT n.id AS id, n.title AS title,
                 (CASE WHEN json_valid(n.frontmatter)
                     THEN json_extract(n.frontmatter, '$.role') END) AS role
             FROM notes n WHERE NOT EXISTS (
                 SELECT 1 FROM smart_folder_members m WHERE m.note_id = n.id))
         WHERE role IS NULL OR role != 'daily'
         ORDER BY id",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(UnsortedNoteRow {
                note_id: r.get(0)?,
                title: r.get(1)?,
                role: r.get(2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}
