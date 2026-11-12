//! `/vaults/{name}/api/v1/agents`: the agents read (Spec #390 req 14, 16;
//! WI #448).
//!
//! The route answers with `memex_core::app_reads::agents::activity`, the read
//! the app's local `AgentsAccess` also uses, plus `available: true` and the
//! server clock's `server_now` (ms), so a hosted app judges expiry against
//! the server's clock rather than its own.

use axum::routing::get;
use axum::{Json, Router};
use memex_core::app_reads::agents::{self as reads, AgentActivity};
use memex_core::Clock;
use serde::Serialize;

use crate::server::error::ApiError;
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new().route("/agents", get(get_agents))
}

/// The body of `GET /agents`.
#[derive(Serialize)]
struct AgentsResponse {
    #[serde(flatten)]
    read: AgentActivity,
    available: bool,
    server_now: i64,
}

/// `GET /agents`: `{agents, recent, available: true, server_now}`.
async fn get_agents(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
) -> Result<Json<AgentsResponse>, ApiError> {
    let read = with_vault(&entry, |vault| Ok(reads::activity(vault)?)).await?;
    Ok(Json(AgentsResponse {
        read,
        available: true,
        server_now: clock.now_ms(),
    }))
}
