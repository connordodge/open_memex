//! The app API of one served vault, nested under `/vaults/{name}/api/v1`.
//! Each domain owns its own file (D3). The vault guard has already resolved
//! the vault; a handler takes it as a `registry::ServedVault`.

use axum::Router;

pub mod canvas;
pub mod daily;
pub mod feedback;
pub mod graph;
pub mod notes;
pub mod revision;
pub mod tags;
pub mod topics;

/// Every domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .merge(notes::router())
        .merge(daily::router())
        .merge(topics::router())
        .merge(canvas::router())
        .merge(graph::router())
        .merge(revision::router())
        .merge(tags::router())
        .merge(feedback::router())
}
