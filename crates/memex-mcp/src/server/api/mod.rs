//! The app API of one served vault, nested under `/vaults/{name}/api/v1`.
//! Each domain owns its own file (D3). The vault guard has already resolved
//! the vault; a handler takes it as a `registry::ServedVault`.

use axum::Router;

pub mod agents;
pub mod backup;
pub mod canvas;
pub mod daily;
pub mod embeddings;
pub mod feedback;
pub mod graph;
pub mod notes;
pub mod revision;
pub mod tags;
pub mod tools;
pub mod topics;
pub mod words;

/// Every domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .merge(notes::router())
        .merge(agents::router())
        .merge(daily::router())
        .merge(topics::router())
        .merge(canvas::router())
        .merge(graph::router())
        .merge(words::router())
        .merge(revision::router())
        .merge(feedback::router())
        .merge(tags::router())
        .merge(backup::router())
        .merge(tools::router())
        .merge(embeddings::router())
}
