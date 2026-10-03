//! MCP tools for vault settings (architect ruling D7). This area's tools go
//! in the impl below; `Memex::new` already composes `settings_router`.

use rmcp::handler::server::wrapper::Parameters;
use rmcp::tool_router;
use schemars::JsonSchema;
use serde::Deserialize;

use super::Memex;

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct GetVaultSettingsParams {}

#[tool_router(router = settings_router, vis = "pub(crate)")]
impl Memex {}

// Skeleton for WI #13: the implementation registers this as a `#[tool]` in
// the router above.
impl Memex {
    pub async fn get_vault_settings(&self, _params: Parameters<GetVaultSettingsParams>) -> String {
        unimplemented!("get_vault_settings")
    }
}
