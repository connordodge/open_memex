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
    let _ = vault;
    todo!("#83: smart_folders")
}

/// `TopicsReads.unsortedNotes`, by `note_id`: every note in no Smart Folder
/// whose role is not `daily`; invalid-JSON frontmatter counts as role-less.
pub fn unsorted_notes(vault: &Vault) -> Result<Vec<UnsortedNoteRow>> {
    let _ = vault;
    todo!("#83: unsorted_notes")
}
