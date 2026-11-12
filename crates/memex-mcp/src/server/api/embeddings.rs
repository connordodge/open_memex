//! `GET /vaults/{name}/api/v1/embeddings` (Spec #394, rulings D6, D20, D39
//! and D40): the `memex embeddings status` body for the served vault.
//!
//! `server_embeddings` is whether this server runs with an embedder; the
//! answer is 200 either way. The counts come from the served vault and the
//! model fields from the server's own cache dir `model_cache_dir(<root>)`,
//! never a vault's. The route builds no embedder, loads or downloads no
//! model and creates no cache dir.

use std::sync::Arc;

use axum::routing::get;
use axum::{Extension, Json, Router};
use serde_json::Value;

use crate::cli::embeddings::body;
use crate::server::error::ApiError;
use crate::server::registry::{with_vault, Registry, ServedVault};
use crate::state::model_cache_dir;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new().route("/embeddings", get(status))
}

/// `GET …/embeddings`: `{server_embeddings, chunks, embedded, model_cached,
/// model_bytes}`.
async fn status(
    Extension(registry): Extension<Arc<Registry>>,
    ServedVault(entry): ServedVault,
) -> Result<Json<Value>, ApiError> {
    let server_embeddings = entry.state.embedder.is_some();
    let counts = with_vault(&entry, |vault| {
        Ok(memex_core::vectors::embedding_counts(
            vault.connection_ref(),
        )?)
    })
    .await?;
    let cache_dir = model_cache_dir(registry.root());
    let value =
        tokio::task::spawn_blocking(move || body(Some(server_embeddings), counts, &cache_dir))
            .await
            .map_err(|e| ApiError::from(anyhow::anyhow!("embeddings status task failed: {e}")))?;
    Ok(Json(value))
}
