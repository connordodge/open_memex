//! `/vaults/{name}/mcp`: the vault's MCP endpoint (#80). Empty until that
//! slice lands (D3).

use axum::Router;

/// The MCP routes, nested under `/vaults/{name}/mcp`.
pub fn router() -> Router {
    Router::new()
}
