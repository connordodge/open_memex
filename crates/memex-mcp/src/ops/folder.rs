//! Smart Folder ops: `memex folder ls|new|update|rm|add|remove`
//! (C2.5–C2.10).

use memex_core::embedder::Embedder;
use memex_core::smart_folders::{Membership, SmartFolder, SmartFolderList};
use memex_core::{Clock, Vault};
use serde::Serialize;

/// `vault_id` first on the wire, then the body's own fields.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct VaultScoped<T> {
    pub vault_id: String,
    #[serde(flatten)]
    pub body: T,
}

/// The `memex folder rm` body.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Deleted {
    pub id: String,
    pub deleted: bool,
}

/// The `memex folder remove` body.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Removed {
    pub smart_folder_id: String,
    pub note_id: String,
    pub removed: bool,
}

pub type LsOutput = VaultScoped<SmartFolderList>;
pub type NewOutput = VaultScoped<SmartFolder>;
pub type UpdateOutput = VaultScoped<SmartFolder>;
pub type RmOutput = VaultScoped<Deleted>;
pub type AddOutput = VaultScoped<Membership>;
pub type RemoveOutput = VaultScoped<Removed>;

/// The input of [`ls`].
#[derive(Debug, Clone, Default)]
pub struct LsInput;

/// Lists every Smart Folder with its members, plus unsorted notes.
pub fn ls(
    vault: &mut Vault,
    input: LsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<LsOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::folder::ls is not implemented yet (#73)")
}

/// The input of [`new`].
#[derive(Debug, Clone, Default)]
pub struct NewInput {
    pub name: String,
    /// The parent folder; `None` makes a top-level folder.
    pub parent_id: Option<String>,
}

/// Creates a person-pinned folder, stamped with the clock.
pub fn new(
    vault: &mut Vault,
    input: NewInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<NewOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::folder::new is not implemented yet (#73)")
}

/// The input of [`update`].
#[derive(Debug, Clone, Default)]
pub struct UpdateInput {
    pub id: String,
    /// The new name; `None` keeps it.
    pub name: Option<String>,
    /// The new parent folder; ignored when `to_root` is set.
    pub parent_id: Option<String>,
    /// Move the folder to the top level.
    pub to_root: bool,
    /// Pin or unpin the folder; `None` keeps it.
    pub pinned: Option<bool>,
}

/// Renames, re-parents or (un)pins a folder on the person path, stamped
/// with the clock.
pub fn update(
    vault: &mut Vault,
    input: UpdateInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<UpdateOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::folder::update is not implemented yet (#73)")
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub id: String,
}

/// Deletes a folder on the person path.
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::folder::rm is not implemented yet (#73)")
}

/// The input of [`add`].
#[derive(Debug, Clone)]
pub struct AddInput {
    pub id: String,
    pub note_id: String,
    /// Pin the membership (the CLI defaults it to `true`).
    pub pinned: bool,
}

/// Adds a note to a folder, or changes its membership pin.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::folder::add is not implemented yet (#73)")
}

/// The input of [`remove`].
#[derive(Debug, Clone, Default)]
pub struct RemoveInput {
    pub id: String,
    pub note_id: String,
}

/// Removes a note from a folder.
pub fn remove(
    vault: &mut Vault,
    input: RemoveInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RemoveOutput> {
    let _ = (vault, input, clock, embedder);
    anyhow::bail!("ops::folder::remove is not implemented yet (#73)")
}
