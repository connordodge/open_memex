//! `/vaults/{name}/api/v1/…`: the Feedback and Vault Guide routes (#256).
//!
//! Each route calls the person-path op the `memex` CLI runs (D2) with the
//! request's clock and answers with the struct the CLI prints. Every error is
//! the CLI's C1 body.

use axum::http::StatusCode;
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use memex_core::Clock;
use serde::Deserialize;
use serde_json::Value;

use crate::ops::{feedback, guide};
use crate::server::error::{ApiError, ApiJson, ApiPath, ApiQuery};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/feedback", get(feedback_ls).post(feedback_add))
        .route(
            "/feedback/{feedback_id}",
            patch(feedback_edit).delete(feedback_rm),
        )
        .route("/guide", get(guide_get))
        .route("/guide/revisions", get(guide_revisions))
        .route(
            "/guide/revisions/{revision_id}/restore",
            post(guide_restore),
        )
}

/// The `{feedback_id}` of a Feedback path (the nested router also holds
/// `{name}`).
#[derive(Deserialize)]
struct FeedbackPath {
    feedback_id: String,
}

/// The `{revision_id}` of a guide revision path.
#[derive(Deserialize)]
struct RevisionPath {
    revision_id: String,
}

/// The body of `POST /feedback`.
#[derive(Deserialize)]
struct FeedbackAdd {
    note_id: String,
    date: String,
    change_id: String,
    text: String,
}

/// `POST /feedback {"note_id", "date", "change_id", "text"}`: 201 with the
/// Feedback row `memex feedback add` prints.
async fn feedback_add(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiJson(body): ApiJson<FeedbackAdd>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let input = feedback::AddInput {
        note_id: body.note_id,
        date: body.date,
        change_id: body.change_id,
        text: body.text,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(feedback::add(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok((StatusCode::CREATED, Json(serde_json::to_value(out)?)))
}

/// The body of `PATCH /feedback/{feedback_id}`.
#[derive(Deserialize)]
struct FeedbackEdit {
    text: String,
}

/// `PATCH /feedback/{feedback_id} {"text"}`: the Feedback row `memex feedback
/// edit` prints.
async fn feedback_edit(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<FeedbackPath>,
    ApiJson(body): ApiJson<FeedbackEdit>,
) -> Result<Json<Value>, ApiError> {
    let input = feedback::EditInput {
        id: path.feedback_id,
        text: body.text,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(feedback::edit(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `DELETE /feedback/{feedback_id}`: the `memex feedback rm` object (`{vault_id,
/// id}`).
async fn feedback_rm(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<FeedbackPath>,
) -> Result<Json<Value>, ApiError> {
    let input = feedback::RmInput {
        id: path.feedback_id,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(feedback::rm(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `?note_id=` of `GET /feedback`. Absent is the no-note list; empty is
/// `invalid_argument`, so the two stay apart.
#[derive(Deserialize)]
struct FeedbackLsQuery {
    note_id: Option<String>,
}

/// `GET /feedback?note_id=`: the `memex feedback ls` object (`{vault_id,
/// feedback}`), all statuses, newest first.
async fn feedback_ls(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiQuery(q): ApiQuery<FeedbackLsQuery>,
) -> Result<Json<Value>, ApiError> {
    let input = feedback::LsInput { note_id: q.note_id };
    let out = with_vault(&entry, move |vault| {
        Ok(feedback::ls(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `GET /guide`: the `memex guide get` object (`{vault_id, note_id, version,
/// content_md}`). The first read creates the guide, so it reindexes with the
/// shared embedder.
async fn guide_get(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
) -> Result<Json<Value>, ApiError> {
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(guide::get(
            vault,
            guide::GetInput,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `GET /guide/revisions`: the `memex guide revisions` object (`{vault_id,
/// revisions}`), newest first.
async fn guide_revisions(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
) -> Result<Json<Value>, ApiError> {
    let out = with_vault(&entry, move |vault| {
        Ok(guide::revisions(
            vault,
            guide::RevisionsInput,
            &clock as &dyn Clock,
            None,
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `POST /guide/revisions/{revision_id}/restore`: the `memex guide restore`
/// object (`{vault_id, note_id, version}`). Its Activity entry is dated today in
/// the request's zone (R40).
async fn guide_restore(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<RevisionPath>,
) -> Result<Json<Value>, ApiError> {
    let input = guide::RestoreInput {
        revision_id: path.revision_id,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(guide::restore(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}
