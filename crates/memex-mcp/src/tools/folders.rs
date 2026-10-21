//! MCP tools for Smart Folders (architect ruling D7). This area's tools go in
//! the impl below; `Memex::new` already composes `folders_router`.

use memex_core::smart_folders::{self as sf, FolderUpdate, NewParent};
use memex_core::{Caller, Clock, SystemClock};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::service::RequestContext;
use rmcp::{tool, tool_router, RoleServer};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::{call_clock, err_from, err_payload, Memex};

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListSmartFoldersParams {}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateSmartFolderParams {
    /// Folder name, unique among its siblings (case-insensitively).
    pub name: String,
    /// Parent folder id; omit for a top-level folder.
    #[serde(default)]
    pub parent_id: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct UpdateSmartFolderParams {
    /// The folder id.
    pub id: String,
    /// New name.
    #[serde(default)]
    pub name: Option<String>,
    /// New parent folder id.
    #[serde(default)]
    pub parent_id: Option<String>,
    /// Move the folder to the top level. Default false.
    #[serde(default)]
    pub to_root: Option<bool>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DeleteSmartFolderParams {
    /// The folder id.
    pub id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddToSmartFolderParams {
    /// The topic note id.
    pub topic_note_id: String,
    /// The Smart Folder id.
    pub smart_folder_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RemoveFromSmartFolderParams {
    /// The topic note id.
    pub topic_note_id: String,
    /// The Smart Folder id.
    pub smart_folder_id: String,
}

/// A core result with the vault id beside its fields (contract C2).
#[derive(Serialize)]
struct InVault<'a, T: Serialize> {
    vault_id: &'a str,
    #[serde(flatten)]
    result: T,
}

fn in_vault<T: Serialize>(op: &str, vault_id: &str, result: T) -> String {
    serde_json::to_string(&InVault { vault_id, result })
        .unwrap_or_else(|e| err_payload(&format!("{op}.serialize"), &e.to_string()))
}

// Every tool acts as `Caller::Agent`: pinned folders and memberships are the
// person's and stay out of an agent's reach (D17).
#[tool_router(router = folders_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "List every Smart Folder as a flat list (each with \
        parent_id, depth, pinned and its member topic notes), plus `unsorted`: \
        the non-daily notes in no folder, and the vault's max_depth.")]
    pub async fn list_smart_folders(&self, _params: Parameters<ListSmartFoldersParams>) -> String {
        let vault = self.state.vault.lock().await;
        match sf::list_folders(&vault) {
            Ok(list) => in_vault("list_smart_folders", vault.vault_id(), list),
            Err(e) => err_from("list_smart_folders", &e),
        }
    }

    /// Creates a Smart Folder on the system clock. The MCP tool is
    /// [`Self::create_smart_folder_tool`].
    pub async fn create_smart_folder(&self, params: Parameters<CreateSmartFolderParams>) -> String {
        self.create_smart_folder_impl(params, &SystemClock).await
    }

    /// The `create_smart_folder` tool, on the call's clock ([`call_clock`]).
    #[tool(
        name = "create_smart_folder",
        description = "Create a Smart Folder, at the top level or under \
        parent_id. Names are unique among siblings ignoring case, and the tree \
        may not nest deeper than the vault's smart_folder_max_depth. Folders \
        you create are unpinned. Returns the folder."
    )]
    async fn create_smart_folder_tool(
        &self,
        params: Parameters<CreateSmartFolderParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        self.create_smart_folder_impl(params, &*call_clock(&ctx))
            .await
    }

    async fn create_smart_folder_impl(
        &self,
        params: Parameters<CreateSmartFolderParams>,
        clock: &(dyn Clock + Sync),
    ) -> String {
        let CreateSmartFolderParams { name, parent_id } = params.0;
        let mut vault = self.state.vault.lock().await;
        match sf::create_folder(
            &mut vault,
            &name,
            parent_id.as_deref(),
            Caller::Agent,
            clock,
        ) {
            Ok(folder) => in_vault("create_smart_folder", vault.vault_id(), folder),
            Err(e) => err_from("create_smart_folder", &e),
        }
    }

    /// Renames or moves a Smart Folder on the system clock. The MCP tool is
    /// [`Self::update_smart_folder_tool`].
    pub async fn update_smart_folder(&self, params: Parameters<UpdateSmartFolderParams>) -> String {
        self.update_smart_folder_impl(params, &SystemClock).await
    }

    /// The `update_smart_folder` tool, on the call's clock ([`call_clock`]).
    #[tool(
        name = "update_smart_folder",
        description = "Rename a Smart Folder, move it under parent_id, or \
        move it to the top level with to_root: true. A folder the user pinned \
        cannot be renamed or moved (pinned_rule). Returns the folder."
    )]
    async fn update_smart_folder_tool(
        &self,
        params: Parameters<UpdateSmartFolderParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        self.update_smart_folder_impl(params, &*call_clock(&ctx))
            .await
    }

    async fn update_smart_folder_impl(
        &self,
        params: Parameters<UpdateSmartFolderParams>,
        clock: &(dyn Clock + Sync),
    ) -> String {
        let UpdateSmartFolderParams {
            id,
            name,
            parent_id,
            to_root,
        } = params.0;
        let parent = match (to_root.unwrap_or(false), parent_id) {
            (true, Some(_)) => {
                return err_payload(
                    "update_smart_folder.invalid_params",
                    "pass parent_id or to_root: true, not both",
                )
            }
            (true, None) => Some(NewParent::Root),
            (false, parent_id) => parent_id.map(NewParent::Folder),
        };
        let update = FolderUpdate {
            name,
            parent,
            pinned: None,
        };
        let mut vault = self.state.vault.lock().await;
        match sf::update_folder(&mut vault, &id, update, Caller::Agent, clock) {
            Ok(folder) => in_vault("update_smart_folder", vault.vault_id(), folder),
            Err(e) => err_from("update_smart_folder", &e),
        }
    }

    #[tool(description = "Delete a Smart Folder. Its subfolders move up to its \
        parent and its memberships go; no note is deleted. A pinned folder, or \
        one holding a pinned membership, cannot be deleted (pinned_rule).")]
    pub async fn delete_smart_folder(&self, params: Parameters<DeleteSmartFolderParams>) -> String {
        let id = params.0.id;
        let mut vault = self.state.vault.lock().await;
        match sf::delete_folder(&mut vault, &id, Caller::Agent) {
            Ok(()) => in_vault(
                "delete_smart_folder",
                vault.vault_id(),
                serde_json::json!({ "id": id, "deleted": true }),
            ),
            Err(e) => err_from("delete_smart_folder", &e),
        }
    }

    #[tool(description = "Add a topic note (role: topic) to a Smart Folder. A \
        note may be in several folders. Adding it again changes nothing; daily \
        and role-less notes are refused (role_rule).")]
    pub async fn add_to_smart_folder(&self, params: Parameters<AddToSmartFolderParams>) -> String {
        let AddToSmartFolderParams {
            topic_note_id,
            smart_folder_id,
        } = params.0;
        let embedder = self.state.embedder.clone();
        let mut vault = self.state.vault.lock().await;
        match sf::add_member(
            &mut vault,
            &smart_folder_id,
            &topic_note_id,
            None,
            Caller::Agent,
            embedder.as_deref(),
        ) {
            Ok(membership) => in_vault("add_to_smart_folder", vault.vault_id(), membership),
            Err(e) => err_from("add_to_smart_folder", &e),
        }
    }

    #[tool(description = "Remove a topic note from a Smart Folder. Memberships \
        of a pinned folder, and pinned memberships, cannot be removed \
        (pinned_rule).")]
    pub async fn remove_from_smart_folder(
        &self,
        params: Parameters<RemoveFromSmartFolderParams>,
    ) -> String {
        let RemoveFromSmartFolderParams {
            topic_note_id,
            smart_folder_id,
        } = params.0;
        let mut vault = self.state.vault.lock().await;
        match sf::remove_member(&mut vault, &smart_folder_id, &topic_note_id, Caller::Agent) {
            Ok(()) => in_vault(
                "remove_from_smart_folder",
                vault.vault_id(),
                serde_json::json!({
                    "smart_folder_id": smart_folder_id,
                    "note_id": topic_note_id,
                    "removed": true,
                }),
            ),
            Err(e) => err_from("remove_from_smart_folder", &e),
        }
    }
}
