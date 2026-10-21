//! `/vaults/{name}/api/v1/…`: the graph routes (#85). The graph view's notes
//! and links, and a note's agent changes for the Activity tab. Reads only:
//! no schema-version route (the app reads `schema_version` from
//! `GET /vaults/{name}/api/v1/info`) and no `hasTables` route.

use axum::routing::get;
use axum::{Json, Router};
use memex_core::app_reads::graph;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::server::error::{ApiError, ApiPath};
use crate::server::registry::{with_vault, ServedVault};

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/graph/notes", get(notes))
        .route("/graph/links", get(links))
        .route("/notes/{note_id}/agent-changes", get(agent_changes))
}

/// The path of a note route (the nested `{name}` is ignored).
#[derive(Deserialize)]
struct NotePath {
    note_id: String,
}

/// `GET /graph/notes`: `{"notes": [{id, title, role}]}`, by id.
async fn notes(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let notes = with_vault(&entry, |vault| Ok(graph::graph_notes(vault)?)).await?;
    Ok(Json(json!({ "notes": notes })))
}

/// `GET /graph/links`: `{"links": [{from, to, kind, label}]}`, links to an
/// existing note only, by source note, then position.
async fn links(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let links = with_vault(&entry, |vault| Ok(graph::graph_links(vault)?)).await?;
    Ok(Json(json!({ "links": links })))
}

/// `GET /notes/{note_id}/agent-changes`: `{"changes": [{id, note_id, day,
/// created_at, bullets}]}`, newest first. An id no note has gives no changes.
async fn agent_changes(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let changes = with_vault(&entry, move |vault| {
        Ok(graph::agent_changes(vault, &path.note_id)?)
    })
    .await?;
    Ok(Json(json!({ "changes": changes })))
}
