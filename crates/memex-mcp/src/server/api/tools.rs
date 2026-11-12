//! `GET /vaults/{name}/api/v1/tools` (Spec #394, ruling D12): the MCP tools
//! and prompts this binary serves. The body is `memex tools`' output; the list
//! is the binary's, so every served vault gets the same one.

use axum::routing::get;
use axum::{Json, Router};
use serde_json::Value;

use crate::cli;
use crate::server::error::ApiError;
use crate::server::registry::ServedVault;

/// The tools route, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new().route("/tools", get(list))
}

/// `GET …/tools`: [`cli::tools::body`].
async fn list(ServedVault(_entry): ServedVault) -> Result<Json<Value>, ApiError> {
    Ok(Json(cli::tools::body()?))
}
