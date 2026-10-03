//! MCP tools for vault settings (architect ruling D7). This area's tools go
//! in the impl below; `Memex::new` already composes `settings_router`.

use memex_core::vault_settings;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_router};
use schemars::JsonSchema;
use serde::Deserialize;

use super::{err_from, Memex};

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct GetVaultSettingsParams {}

#[tool_router(router = settings_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "Read the vault settings an agent works within: \
        smart_folder_max_depth (how deep Smart Folders may nest; a top-level \
        folder is depth 1) and link_kinds (the built-in link kinds plus every \
        user-defined kind already used in the vault).")]
    pub async fn get_vault_settings(&self, _params: Parameters<GetVaultSettingsParams>) -> String {
        let vault = self.state.vault.lock().await;
        let settings = vault_settings::smart_folder_max_depth(&vault)
            .and_then(|max_depth| Ok((max_depth, vault_settings::link_kinds(&vault)?)));
        match settings {
            Ok((max_depth, link_kinds)) => serde_json::json!({
                "smart_folder_max_depth": max_depth,
                "link_kinds": link_kinds,
            })
            .to_string(),
            Err(e) => err_from("get_vault_settings", &e),
        }
    }
}
