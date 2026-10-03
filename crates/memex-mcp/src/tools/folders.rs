//! MCP tools for Smart Folders (architect ruling D7). This area's tools go in
//! the impl below; `Memex::new` already composes `folders_router`.

use rmcp::handler::server::wrapper::Parameters;
use rmcp::tool_router;
use schemars::JsonSchema;
use serde::Deserialize;

use super::Memex;

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

#[tool_router(router = folders_router, vis = "pub(crate)")]
impl Memex {}

// Skeleton for WI #13: the implementation registers these as `#[tool]`s in
// the router above.
impl Memex {
    pub async fn list_smart_folders(&self, _params: Parameters<ListSmartFoldersParams>) -> String {
        unimplemented!("list_smart_folders")
    }

    pub async fn create_smart_folder(
        &self,
        _params: Parameters<CreateSmartFolderParams>,
    ) -> String {
        unimplemented!("create_smart_folder")
    }

    pub async fn update_smart_folder(
        &self,
        _params: Parameters<UpdateSmartFolderParams>,
    ) -> String {
        unimplemented!("update_smart_folder")
    }

    pub async fn delete_smart_folder(
        &self,
        _params: Parameters<DeleteSmartFolderParams>,
    ) -> String {
        unimplemented!("delete_smart_folder")
    }

    pub async fn add_to_smart_folder(&self, _params: Parameters<AddToSmartFolderParams>) -> String {
        unimplemented!("add_to_smart_folder")
    }

    pub async fn remove_from_smart_folder(
        &self,
        _params: Parameters<RemoveFromSmartFolderParams>,
    ) -> String {
        unimplemented!("remove_from_smart_folder")
    }
}
