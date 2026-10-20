//! `/vaults/{name}/mcp`: the vault's MCP endpoint over streamable HTTP
//! (req 3, 16, 19; D3, D7, D8).
//!
//! rmcp's service factory never sees the request, so each served vault gets
//! its own `StreamableHttpService`, built on first use and cached here by the
//! vault's `open_id`. A vault that is evicted and reopened has a new
//! `open_id`, so it never reuses a service bound to its old `AppState`.
//!
//! Every service is stateless (`with_stateful_mode(false)`: no `initialize`
//! needed, no `Mcp-Session-Id`), answers with one `application/json`
//! JSON-RPC body (`with_json_response(true)`, never SSE), and accepts any
//! `Host` (`disable_allowed_hosts()`): the bearer token layer (D7) is the
//! guard, and the server sends no CORS headers.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use axum::body::Body;
use axum::extract::{Request, State};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::Router;
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use ulid::Ulid;

use super::error;
use super::registry::{ServedVault, VaultEntry};
use super::BODY_LIMIT;
use crate::tools::Memex;

/// One vault's MCP service.
type McpService = StreamableHttpService<Memex, NeverSessionManager>;

/// The MCP routes, nested under `/vaults/{name}/mcp`. POST only: any other
/// method is the server's 405 `method_not_allowed`.
pub fn router() -> Router {
    Router::new()
        .route("/", post(handle))
        .with_state(Arc::new(Services::default()))
}

/// The cached services, by the `open_id` of the vault each serves.
#[derive(Default)]
struct Services {
    by_open_id: Mutex<HashMap<Ulid, (Weak<VaultEntry>, McpService)>>,
}

impl Services {
    /// The service for `entry`, built on first use. Services whose vault
    /// entry is gone (evicted and no longer in use) are dropped here, so a
    /// closed vault's connection is not kept open by its old service.
    fn get(&self, entry: &Arc<VaultEntry>) -> McpService {
        let mut map = self
            .by_open_id
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        map.retain(|_, (vault, _)| vault.strong_count() > 0);
        map.entry(entry.open_id)
            .or_insert_with(|| (Arc::downgrade(entry), service_for(entry)))
            .1
            .clone()
    }
}

/// A stateless, JSON-response, any-Host MCP service over `entry`'s
/// `AppState` (the same connection and mutex the app API uses).
fn service_for(entry: &VaultEntry) -> McpService {
    let state = Arc::new(entry.state.clone());
    let config = StreamableHttpServerConfig::default()
        .with_stateful_mode(false)
        .with_json_response(true)
        .disable_allowed_hosts();
    StreamableHttpService::new(
        move || Ok(Memex::new(state.clone())),
        Arc::new(NeverSessionManager::default()),
        config,
    )
}

/// `POST /vaults/{name}/mcp`. The body is read here, up to the 8 MiB limit,
/// so a chunked body over it is the C1 413 `payload_too_large` rather than
/// rmcp's own error.
async fn handle(
    State(services): State<Arc<Services>>,
    ServedVault(entry): ServedVault,
    req: Request,
) -> Response {
    let (parts, body) = req.into_parts();
    let Ok(bytes) = axum::body::to_bytes(body, BODY_LIMIT).await else {
        return error::payload_too_large().into_response();
    };
    let service = services.get(&entry);
    drop(entry);
    service
        .handle(Request::from_parts(parts, Body::from(bytes)))
        .await
        .map(Body::new)
        .into_response()
}

#[cfg(test)]
mod tests {
    use memex_core::Vault;

    use super::*;
    use crate::state::AppState;

    /// A fresh vault in `dir/<name>`, as an entry with a new `open_id`.
    fn wi80_entry(dir: &std::path::Path, name: &str) -> Arc<VaultEntry> {
        let path = dir.join(name);
        let vault = Vault::create(&path).expect("create vault");
        Arc::new(VaultEntry {
            open_id: Ulid::new(),
            state: AppState::new(vault, path, None),
        })
    }

    /// The `open_id`s the cache holds a service for, sorted.
    fn cached(services: &Services) -> Vec<Ulid> {
        let mut ids: Vec<Ulid> = services
            .by_open_id
            .lock()
            .unwrap()
            .keys()
            .copied()
            .collect();
        ids.sort();
        ids
    }

    fn sorted(mut ids: Vec<Ulid>) -> Vec<Ulid> {
        ids.sort();
        ids
    }

    #[test]
    fn mcp_service_cache_drops_a_service_whose_vault_entry_is_gone_and_releases_its_connection() {
        let dir = tempfile::tempdir().unwrap();
        let services = Services::default();
        let old = wi80_entry(dir.path(), "work");
        let old_id = old.open_id;
        let old_conn = Arc::downgrade(&old.state.vault);
        drop(services.get(&old));
        assert_eq!(cached(&services), vec![old_id]);

        // The registry evicts the entry and no request holds it: only the
        // cached service still holds the vault's connection.
        drop(old);
        assert!(
            old_conn.upgrade().is_some(),
            "the cached service holds the connection until the next lookup"
        );

        // The next lookup, for any vault, drops the dead vault's service.
        let other = wi80_entry(dir.path(), "other");
        drop(services.get(&other));
        assert_eq!(cached(&services), vec![other.open_id]);
        assert!(
            old_conn.upgrade().is_none(),
            "the deleted vault's connection is closed, not kept by its old service"
        );
    }

    #[test]
    fn mcp_service_cache_keeps_one_service_per_live_vault_entry() {
        let dir = tempfile::tempdir().unwrap();
        let services = Services::default();
        let a = wi80_entry(dir.path(), "a");
        let b = wi80_entry(dir.path(), "b");
        for _ in 0..3 {
            drop(services.get(&a));
        }
        drop(services.get(&b));
        drop(services.get(&a));
        assert_eq!(
            cached(&services),
            sorted(vec![a.open_id, b.open_id]),
            "a live vault's service is kept while other vaults are served"
        );
        // One service per vault: the entry and one cached service hold each
        // connection.
        assert_eq!(Arc::strong_count(&a.state.vault), 2);
        assert_eq!(Arc::strong_count(&b.state.vault), 2);

        // A reopened vault (a new open_id over a new AppState) gets its own
        // service, never the old one's; the old entry's goes once it is gone.
        let reopened = wi80_entry(dir.path(), "a2");
        let a_conn = Arc::downgrade(&a.state.vault);
        drop(a);
        drop(services.get(&reopened));
        assert_eq!(cached(&services), sorted(vec![b.open_id, reopened.open_id]));
        assert_eq!(Arc::strong_count(&reopened.state.vault), 2);
        assert!(a_conn.upgrade().is_none());
    }
}
