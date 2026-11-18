//! `/vaults/{name}/api/v1/search`: the Command palette's note-text search
//! (Spec #59 requirements 34, 37, 38).
//!
//! The route answers `memex_core::note_search`'s JSON, the same rules the
//! `memex search` CLI runs. It never downloads a model and never embeds
//! pending chunks (D10): the server's background backfill does that.

use std::path::Path;
use std::sync::Arc;

use axum::routing::get;
use axum::{Extension, Json, Router};
use memex_core::embedder::{Embedder, FastEmbedder};
use memex_core::note_search::{note_search, SearchEmbedder};
use memex_core::MemexError;
use serde::Deserialize;
use serde_json::Value;

use crate::backfill::VaultLease;
use crate::cli::echoes::validate_limit;
use crate::server::error::{ApiError, ApiQuery};
use crate::server::registry::{Registry, ServedVault};
use crate::state::model_cache_dir;

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
/// are 200. A blank query probes the model only when it is already in the
/// server's cache `model_cache_dir(<root>)`, else answers `unavailable`, so
/// it never downloads one. `note_search` runs on a blocking thread through
/// a [`VaultLease`], so the vault lock is never held across inference.
async fn search(
    Extension(registry): Extension<Arc<Registry>>,
    ServedVault(entry): ServedVault,
    ApiQuery(params): ApiQuery<SearchQuery>,
) -> Result<Json<Value>, ApiError> {
    let limit = validate_limit(params.limit.unwrap_or(DEFAULT_LIMIT))?;
    let query = params.q.unwrap_or_default();
    let embedder = entry.state.embedder.clone();
    let vault = entry.state.vault.clone();
    let cache_dir = model_cache_dir(registry.root());
    let out = tokio::task::spawn_blocking(move || {
        let cached_only;
        let search_embedder = match embedder.as_deref() {
            Some(e) if query.trim().is_empty() => {
                cached_only = CachedOnly {
                    inner: e,
                    cache_dir: &cache_dir,
                };
                SearchEmbedder::Ready(&cached_only)
            }
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

/// The server's embedder for a blank query: a batch fails with
/// `model_not_downloaded` (which `note_search` answers as `unavailable`)
/// while the model is not in `cache_dir`, before the embedder (and so the
/// network) is reached.
struct CachedOnly<'a> {
    inner: &'a dyn Embedder,
    cache_dir: &'a Path,
}

impl Embedder for CachedOnly<'_> {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        if !FastEmbedder::is_cached(self.cache_dir) {
            return Err(MemexError::ModelNotDownloaded);
        }
        self.inner.embed_batch(texts)
    }
}
