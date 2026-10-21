//! `/vaults/{name}/api/v1/…`: the daily-note routes (#82). Empty until that
//! slice lands (D3).

use axum::Router;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
}
