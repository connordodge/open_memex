//! `/vaults/{name}/api/v1/…`: the daily-note routes (#82).
//!
//! Reads are the app's `DailyReads` (`memex_core::app_reads::daily`). The
//! two writes call the person-path ops the `memex` CLI runs (D2) with the
//! request's clock and the registry's shared embedder, and answer with the
//! struct the CLI prints. Every error is the CLI's C1 body. No route here
//! creates a daily note, appends to one or records a review.

use axum::routing::{delete, get};
use axum::{Json, Router};
use memex_core::app_reads::daily as reads;
use memex_core::Clock;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::ops::{excerpt, footer};
use crate::server::error::{ApiError, ApiJson, ApiPath, ApiQuery};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/daily-notes", get(daily_notes))
        .route("/daily-notes/{date}", get(daily_note_for_date))
        .route("/notes/{note_id}/review", get(review))
        .route("/notes/{note_id}/blocks", get(blocks))
        .route(
            "/notes/{note_id}/footer-chips",
            get(footer_chips).post(footer_add),
        )
        .route("/notes/{note_id}/excerpts", delete(excerpt_rm))
}

/// The `{note_id}` of a note path (the nested router also holds `{name}`).
#[derive(Deserialize)]
struct NotePath {
    note_id: String,
}

/// The `{date}` of `GET /daily-notes/{date}`: a daily note's title.
#[derive(Deserialize)]
struct DatePath {
    date: String,
}

/// `GET /daily-notes`: `{"daily_notes": [{date, note_id, preview,
/// review_state}]}`, newest date first.
async fn daily_notes(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let rows = with_vault(&entry, |vault| Ok(reads::daily_notes(vault)?)).await?;
    Ok(Json(json!({ "daily_notes": rows })))
}

/// `GET /daily-notes/{date}`: `{"daily_note": {…}}`, or `{"daily_note":
/// null}` when no daily note has that title (the title is not checked to be
/// a date).
async fn daily_note_for_date(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<DatePath>,
) -> Result<Json<Value>, ApiError> {
    let row = with_vault(&entry, move |vault| {
        Ok(reads::daily_note_for_date(vault, &path.date)?)
    })
    .await?;
    Ok(Json(json!({ "daily_note": row })))
}

/// `GET /notes/{note_id}/review`: `{"state", "reviewed_at"}`; a note with no
/// `day_reviews` row (or no note) is `Unreviewed` with `reviewed_at: null`.
async fn review(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let info = with_vault(&entry, move |vault| {
        Ok(reads::review_info(vault, &path.note_id)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(info)?))
}

/// `GET /notes/{note_id}/blocks`: `{"blocks": [...]}` in `ord` order.
async fn blocks(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let blocks = with_vault(&entry, move |vault| {
        Ok(reads::blocks_for_note(vault, &path.note_id)?)
    })
    .await?;
    Ok(Json(json!({ "blocks": blocks })))
}

/// `GET /notes/{note_id}/footer-chips`: `{"chips": [...]}` in insertion
/// order.
async fn footer_chips(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let chips = with_vault(&entry, move |vault| {
        Ok(reads::footer_chips(vault, &path.note_id)?)
    })
    .await?;
    Ok(Json(json!({ "chips": chips })))
}

/// The body of `POST /notes/{note_id}/footer-chips`.
#[derive(Deserialize)]
struct FooterAdd {
    topic_note_id: String,
}

/// `POST /notes/{daily_note_id}/footer-chips {"topic_note_id"}`: the `memex
/// footer add` output (`{vault_id, daily_note_id, topic_note_id, origin,
/// version}`).
async fn footer_add(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiJson(body): ApiJson<FooterAdd>,
) -> Result<Json<Value>, ApiError> {
    let input = footer::AddInput {
        daily_note_id: path.note_id,
        topic_note_id: body.topic_note_id,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(footer::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `?date=YYYY-MM-DD&block_ids=from[,to]` of `DELETE
/// /notes/{note_id}/excerpts`. Both are required: the date never defaults to
/// today.
#[derive(Deserialize)]
struct ExcerptRmQuery {
    date: String,
    block_ids: String,
}

/// `DELETE /notes/{topic_note_id}/excerpts?date=&block_ids=`: the `memex
/// excerpt rm` output (`{vault_id, topic_note_id, version}`). `block_ids` is
/// split on `,` as `--block-ids` is, with no trimming.
async fn excerpt_rm(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiQuery(q): ApiQuery<ExcerptRmQuery>,
) -> Result<Json<Value>, ApiError> {
    let input = excerpt::RmInput {
        topic_note_id: path.note_id,
        date: q.date,
        block_ids: q.block_ids.split(',').map(str::to_string).collect(),
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(excerpt::rm(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}
