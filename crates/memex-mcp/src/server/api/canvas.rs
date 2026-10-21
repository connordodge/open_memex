//! `/vaults/{name}/api/v1/…`: the canvas routes (#84).
//!
//! Reads and writes alike call the canvas ops the `memex canvas` CLI runs
//! (D2) with the request's clock and the registry's shared embedder, and
//! answer with the struct the CLI prints. Every error is the CLI's C1 body.
//! Coordinates are `f64` from the request body to the response.

use axum::http::StatusCode;
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use memex_core::Clock;
use serde::Deserialize;

use crate::ops::canvas as canvas_ops;
use crate::server::error::{ApiError, ApiJson, ApiPath};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/canvases", get(list_canvases).post(create_canvas))
        .route("/canvases/{canvas_id}", get(get_canvas))
        .route("/canvases/{canvas_id}/nodes", post(add_node))
        .route("/canvases/{canvas_id}/nodes/{note_id}", patch(move_node))
}

/// The `{canvas_id}` of a canvas path (the nested router also holds
/// `{name}`).
#[derive(Deserialize)]
struct CanvasPath {
    canvas_id: String,
}

/// The `{canvas_id}` and `{note_id}` of a placement path.
#[derive(Deserialize)]
struct NodePath {
    canvas_id: String,
    note_id: String,
}

/// `GET /canvases`: the `memex canvas ls` object `{canvases, vault_id}`.
async fn list_canvases(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
) -> Result<Json<canvas_ops::LsOutput>, ApiError> {
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(canvas_ops::ls(
            vault,
            canvas_ops::LsInput,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// `GET /canvases/{canvas_id}`: the `memex canvas get` object (nodes and
/// edges); an unknown id is `not_found`, a malformed one `invalid_id`.
async fn get_canvas(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<CanvasPath>,
) -> Result<Json<canvas_ops::GetOutput>, ApiError> {
    let input = canvas_ops::GetInput {
        canvas_id: path.canvas_id,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(canvas_ops::get(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// The body of `POST /canvases`.
#[derive(Deserialize)]
struct CreateCanvas {
    title: String,
}

/// `POST /canvases {title}`: 201 with the `memex canvas new` object; a used
/// title is `title_conflict` with `existing_id`.
async fn create_canvas(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiJson(body): ApiJson<CreateCanvas>,
) -> Result<(StatusCode, Json<canvas_ops::NewOutput>), ApiError> {
    let input = canvas_ops::NewInput { title: body.title };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(canvas_ops::new(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok((StatusCode::CREATED, Json(out)))
}

/// The body of `POST /canvases/{canvas_id}/nodes`: every field is required.
#[derive(Deserialize)]
struct AddNode {
    note_id: String,
    x: f64,
    y: f64,
}

/// `POST /canvases/{canvas_id}/nodes {note_id, x, y}`: the `memex canvas
/// add` object. Placing a placed note returns its existing placement.
async fn add_node(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<CanvasPath>,
    ApiJson(body): ApiJson<AddNode>,
) -> Result<Json<canvas_ops::AddOutput>, ApiError> {
    let input = canvas_ops::AddInput {
        canvas_id: path.canvas_id,
        note_id: body.note_id,
        x: body.x,
        y: body.y,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(canvas_ops::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// The body of `PATCH /canvases/{canvas_id}/nodes/{note_id}`: an omitted
/// `z_order` keeps the node's z; a given one must be an integer.
#[derive(Deserialize)]
struct MoveNode {
    x: f64,
    y: f64,
    z_order: Option<i64>,
}

/// `PATCH /canvases/{canvas_id}/nodes/{note_id} {x, y, z_order?}`: the
/// `memex canvas move` object (no `placed_at`).
async fn move_node(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NodePath>,
    ApiJson(body): ApiJson<MoveNode>,
) -> Result<Json<canvas_ops::MoveOutput>, ApiError> {
    let input = canvas_ops::MoveInput {
        canvas_id: path.canvas_id,
        note_id: path.note_id,
        x: body.x,
        y: body.y,
        z: body.z_order,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(canvas_ops::move_node(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}
