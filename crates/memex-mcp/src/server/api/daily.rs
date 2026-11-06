//! `/vaults/{name}/api/v1/…`: the daily-note routes (#82).
//!
//! Reads are the app's `DailyReads` (`memex_core::app_reads::daily`), plus a
//! day's filing. The writes call the person-path ops the `memex` CLI runs (D2)
//! with the request's clock and the registry's shared embedder, and answer with
//! the struct the CLI prints. Every error is the CLI's C1 body. No route here
//! creates a daily note, appends to one or records a review.

use axum::routing::{delete, get, post};
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
        .route("/daily-notes/{date}/filing", get(filing))
        .route("/notes/{note_id}/review", get(review))
        .route("/notes/{note_id}/blocks", get(blocks))
        .route(
            "/notes/{note_id}/footer-chips",
            get(footer_chips).post(footer_add),
        )
        .route(
            "/notes/{note_id}/excerpts",
            delete(excerpt_rm).post(excerpt_add),
        )
        .route(
            "/notes/{note_id}/excerpts/blocks/{block_id}",
            delete(excerpt_remove_block),
        )
        .route("/notes/{note_id}/excerpts/move", post(excerpt_move))
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

/// The `{note_id}` and `{block_id}` of a block path.
#[derive(Deserialize)]
struct BlockPath {
    note_id: String,
    block_id: String,
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

/// `GET /daily-notes/{date}/filing`: the `memex filing` object (`{vault_id,
/// date, note_id, reviewed, topics, not_filed}`).
async fn filing(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<DatePath>,
) -> Result<Json<Value>, ApiError> {
    let input = excerpt::FilingInput { date: path.date };
    let out = with_vault(&entry, move |vault| {
        Ok(excerpt::filing(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
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

/// The body of `POST /notes/{note_id}/excerpts`.
#[derive(Deserialize)]
struct ExcerptAdd {
    date: String,
    block_id: String,
    note: Option<String>,
}

/// `POST /notes/{topic_note_id}/excerpts {"date", "block_id", "note"?}`: the
/// `memex excerpt add` output (`{vault_id, topic_note_id, version}`).
async fn excerpt_add(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiJson(body): ApiJson<ExcerptAdd>,
) -> Result<Json<Value>, ApiError> {
    let input = excerpt::AddInput {
        topic_note_id: path.note_id,
        date: body.date,
        block_id: body.block_id,
        note: body.note,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(excerpt::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `?date=YYYY-MM-DD&note=` of `DELETE
/// /notes/{note_id}/excerpts/blocks/{block_id}`. The date is required: it
/// never defaults to today.
#[derive(Deserialize)]
struct ExcerptRemoveBlockQuery {
    date: String,
    note: Option<String>,
}

/// `DELETE /notes/{topic_note_id}/excerpts/blocks/{block_id}?date=&note=`: the
/// `memex excerpt remove-block` output (`{vault_id, topic_note_id, version}`).
async fn excerpt_remove_block(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<BlockPath>,
    ApiQuery(q): ApiQuery<ExcerptRemoveBlockQuery>,
) -> Result<Json<Value>, ApiError> {
    let input = excerpt::RemoveBlockInput {
        topic_note_id: path.note_id,
        date: q.date,
        block_id: path.block_id,
        note: q.note,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(excerpt::remove_block(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// The body of `POST /notes/{note_id}/excerpts/move`.
#[derive(Deserialize)]
struct ExcerptMove {
    date: String,
    block_id: String,
    to_topic_note_id: String,
    note: Option<String>,
}

/// `POST /notes/{from_topic_note_id}/excerpts/move {"date", "block_id",
/// "to_topic_note_id", "note"?}`: the `memex excerpt move` output (`{vault_id,
/// from_topic_note_id, from_version, to_topic_note_id, to_version}`).
async fn excerpt_move(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiJson(body): ApiJson<ExcerptMove>,
) -> Result<Json<Value>, ApiError> {
    let input = excerpt::MoveInput {
        date: body.date,
        block_id: body.block_id,
        from_topic_note_id: path.note_id,
        to_topic_note_id: body.to_topic_note_id,
        note: body.note,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(excerpt::move_block(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}
