//! `/vaults/{name}/api/v1/…`: the Agent read-only and agent-edit revision
//! routes (Spec #7 Req 37; rulings D13, D14).
//!
//! - `PUT /notes/{note_id}/agent-read-only {agent_read_only}` -> the
//!   `memex read-only set|clear` object
//! - `GET /notes/{note_id}/revisions` -> the `memex revisions list` object
//! - `POST /notes/{note_id}/revisions/{revision_id}/restore` (no body) -> the
//!   `memex revisions restore` object; a revision of another note is
//!   `not_found`
//!
//! Each route calls the person-path op the `memex` CLI runs (D2) with the
//! request's clock and answers with the struct the CLI prints. Every error is
//! the CLI's C1 body.

use axum::routing::{get, post, put};
use axum::{Json, Router};
use memex_core::Clock;
use serde::Deserialize;
use serde_json::Value;

use crate::ops::note_edits;
use crate::server::error::{ApiError, ApiJson, ApiPath};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/notes/{note_id}/agent-read-only", put(put_agent_read_only))
        .route("/notes/{note_id}/revisions", get(list_revisions))
        .route(
            "/notes/{note_id}/revisions/{revision_id}/restore",
            post(restore_revision),
        )
}

/// The `{note_id}` of a note path (the nested router also holds `{name}`).
#[derive(Deserialize)]
struct NotePath {
    note_id: String,
}

/// The `{note_id}` and `{revision_id}` of a restore path.
#[derive(Deserialize)]
struct RevisionPath {
    note_id: String,
    revision_id: String,
}

/// The body of `PUT /notes/{note_id}/agent-read-only`.
#[derive(Deserialize)]
struct AgentReadOnlyBody {
    agent_read_only: bool,
}

/// `PUT /notes/{note_id}/agent-read-only {"agent_read_only": bool}`: the
/// `memex read-only set|clear` object (`{vault_id, note_id,
/// agent_read_only}`).
async fn put_agent_read_only(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiJson(body): ApiJson<AgentReadOnlyBody>,
) -> Result<Json<Value>, ApiError> {
    let input = note_edits::SetAgentReadOnlyInput {
        note_id: path.note_id,
        agent_read_only: body.agent_read_only,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(note_edits::set_agent_read_only(
            vault,
            input,
            &clock as &dyn Clock,
            None,
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `GET /notes/{note_id}/revisions`: the `memex revisions list` object
/// (`{vault_id, revisions}`), newest first.
async fn list_revisions(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let input = note_edits::NoteRevisionsInput {
        note_id: path.note_id,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(note_edits::note_revisions(
            vault,
            input,
            &clock as &dyn Clock,
            None,
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `POST /notes/{note_id}/revisions/{revision_id}/restore`: the `memex
/// revisions restore` object (`{vault_id, note_id, version, content_md}`).
/// The revision must belong to `{note_id}` (D11). Its Activity entry is dated
/// today in the request's zone, and the note is reindexed with the shared
/// embedder.
async fn restore_revision(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<RevisionPath>,
) -> Result<Json<Value>, ApiError> {
    let input = note_edits::RestoreNoteRevisionInput {
        revision_id: path.revision_id,
        note_id: Some(path.note_id),
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(note_edits::restore_note_revision(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}
