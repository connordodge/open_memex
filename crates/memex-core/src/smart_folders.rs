//! Smart Folders.
//!
//! A tree of vault rows (`smart_folders`) with case-insensitively unique
//! sibling names, plus topic-note memberships (`smart_folder_members`).
//! Depth is limited by the vault setting `smart_folder_max_depth`
//! ([`crate::vault_settings`]) for every caller; pinning guards only
//! [`Caller::Agent`], and person writes pin what they touch (architect ruling
//! D17, Spec Reqs 34–47).

use serde::Serialize;

use crate::caller::Caller;
use crate::canvas::Clock;
use crate::embedder::Embedder;
use crate::vault::Vault;
use crate::Result;

/// One Smart Folder. `depth` is 1 for a root folder, 2 for its child, ….
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolder {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub pinned: bool,
    pub depth: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// A topic note's membership as listed under its folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FolderMember {
    pub note_id: String,
    pub title: String,
    pub pinned: bool,
}

/// A folder in [`SmartFolderList::folders`]: the folder's fields plus its
/// members.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ListedFolder {
    #[serde(flatten)]
    pub folder: SmartFolder,
    pub members: Vec<FolderMember>,
}

/// A non-daily note with no membership (the implicit Unsorted row).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UnsortedNote {
    pub note_id: String,
    pub title: String,
}

/// The whole tree as a flat list (each folder carries `parent_id`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolderList {
    pub max_depth: i64,
    pub folders: Vec<ListedFolder>,
    pub unsorted: Vec<UnsortedNote>,
}

/// The result of [`add_member`]. `role_set` is true when a role-less note
/// became `role: topic` (Connor Q3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Membership {
    pub smart_folder_id: String,
    pub note_id: String,
    pub pinned: bool,
    pub role_set: bool,
}

/// Where [`update_folder`] moves a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NewParent {
    /// Make it a root folder (`--to-root`, MCP `to_root: true`).
    Root,
    /// Make it a child of this folder id.
    Folder(String),
}

/// A partial update of a Smart Folder. `None` leaves the field unchanged.
/// `pinned` is honoured for [`Caller::Person`] only; without it, a person
/// rename or re-parent pins the folder (Req 41).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FolderUpdate {
    pub name: Option<String>,
    pub parent: Option<NewParent>,
    pub pinned: Option<bool>,
}

/// Every folder with its members, plus the unsorted notes and the current
/// `smart_folder_max_depth`.
pub fn list_folders(_vault: &Vault) -> Result<SmartFolderList> {
    unimplemented!("smart_folders::list_folders")
}

/// Creates a folder named `name` under `parent_id` (`None` = root). Pinned
/// when the caller is the person.
pub fn create_folder(
    _vault: &mut Vault,
    _name: &str,
    _parent_id: Option<&str>,
    _caller: Caller,
    _clock: &dyn Clock,
) -> Result<SmartFolder> {
    unimplemented!("smart_folders::create_folder")
}

/// Renames, re-parents and (person only) pins or unpins a folder.
pub fn update_folder(
    _vault: &mut Vault,
    _id: &str,
    _update: FolderUpdate,
    _caller: Caller,
    _clock: &dyn Clock,
) -> Result<SmartFolder> {
    unimplemented!("smart_folders::update_folder")
}

/// Deletes a folder: re-parents its children to its parent, drops its
/// memberships, never deletes a note.
pub fn delete_folder(_vault: &mut Vault, _id: &str, _caller: Caller) -> Result<()> {
    unimplemented!("smart_folders::delete_folder")
}

/// Adds a topic note to a folder (idempotent upsert). `pinned: None` means
/// the caller's default (person: pinned, agent: unpinned); `Some(_)` is the
/// person's membership pin toggle. A person adding a role-less non-daily note
/// sets its `role: topic` and reindexes it with `embedder`.
pub fn add_member(
    _vault: &mut Vault,
    _folder_id: &str,
    _note_id: &str,
    _pinned: Option<bool>,
    _caller: Caller,
    _embedder: Option<&dyn Embedder>,
) -> Result<Membership> {
    unimplemented!("smart_folders::add_member")
}

/// Removes a topic note from a folder.
pub fn remove_member(
    _vault: &mut Vault,
    _folder_id: &str,
    _note_id: &str,
    _caller: Caller,
) -> Result<()> {
    unimplemented!("smart_folders::remove_member")
}
