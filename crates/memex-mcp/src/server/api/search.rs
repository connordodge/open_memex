//! `/vaults/{name}/api/v1/search`: the Command palette's note-text search
//! (Spec #59 requirements 34, 37, 38).
//!
//! The route answers `memex_core::note_search`'s JSON, the same rules the
//! `memex search` CLI runs. It never downloads a model and never embeds
//! pending chunks (D10): the server's background backfill does that.

use axum::routing::get;
use axum::{Json, Router};
use memex_core::note_search::{note_search, SearchEmbedder};
use serde::Deserialize;
use serde_json::Value;

use crate::backfill::VaultLease;
use crate::cli::echoes::validate_limit;
use crate::server::error::{ApiError, ApiQuery};
use crate::server::registry::ServedVault;

/// The `pending_cap` of the route's search: the request embeds no pending
/// chunk (D10).
const SEARCH_PENDING_CAP: usize = 0;

/// The `limit` when the request names none.
const DEFAULT_LIMIT: i64 = 8;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new().route("/search", get(search))
}

/// `?q=<text>&limit=<n>` of the search.
#[derive(Deserialize)]
struct SearchQuery {
    q: Option<String>,
    limit: Option<i64>,
}

/// `GET /search?q=<text>&limit=<n>` (Spec #59 requirement 34):
/// `{query, semantic, hits, truncated}`, with `limit` 1 to 20 (default 8).
///
/// A missing `q` is the empty query, which answers no hits. Without an
/// embedder (`--with-embeddings` off) it answers keyword hits as
/// `embeddings_off`; an embedder error answers them as `unavailable`. Both
/// are 200. `note_search` runs on a blocking thread through a
/// [`VaultLease`], so the vault lock is never held across inference.
async fn search(
    ServedVault(entry): ServedVault,
    ApiQuery(params): ApiQuery<SearchQuery>,
) -> Result<Json<Value>, ApiError> {
    let limit = validate_limit(params.limit.unwrap_or(DEFAULT_LIMIT))?;
    let query = params.q.unwrap_or_default();
    let embedder = entry.state.embedder.clone();
    let vault = entry.state.vault.clone();
    let out = tokio::task::spawn_blocking(move || {
        let search_embedder = match embedder.as_deref() {
            Some(e) => SearchEmbedder::Ready(e),
            None => SearchEmbedder::Off,
        };
        note_search(
            &mut VaultLease::new(vault),
            &query,
            limit,
            search_embedder,
            SEARCH_PENDING_CAP,
        )
    })
    .await
    .map_err(|e| ApiError::from(anyhow::anyhow!("vault task failed: {e}")))??;
    Ok(Json(serde_json::to_value(out)?))
}
