//! `/vaults/{name}/api/v1/…`: the tag routes (Spec #234 R47, WI #242).
//!
//! Every route calls the tag op the `memex tag` CLI runs (D2) with the
//! request's clock and the registry's shared embedder, and answers with the
//! struct the CLI prints. Every error is the CLI's C1 body. `{tag}` arrives
//! percent-decoded, so non-ASCII names work.

use axum::routing::{delete, get, post};
use axum::{Json, Router};
use memex_core::Clock;
use serde::Deserialize;

use crate::ops::tags as tag_ops;
use crate::server::error::{ApiError, ApiJson, ApiPath};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/tags", get(list_tags))
        .route("/tags/{tag}/notes", get(tag_notes))
        .route("/notes/{note_id}/tags", post(add_tag))
        .route("/notes/{note_id}/tags/{tag}", delete(remove_tag))
}

/// The `{tag}` of a tag path (the nested router also holds `{name}`).
#[derive(Deserialize)]
struct TagPath {
    tag: String,
}

/// The `{note_id}` of a note path.
#[derive(Deserialize)]
struct NotePath {
    note_id: String,
}

/// The `{note_id}` and `{tag}` of a note's tag path.
#[derive(Deserialize)]
struct NoteTagPath {
    note_id: String,
    tag: String,
}

/// `GET /tags`: the `memex tag ls` object `{tags: [{tag, note_count, system}]}`.
async fn list_tags(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
) -> Result<Json<tag_ops::LsOutput>, ApiError> {
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(tag_ops::ls(
            vault,
            tag_ops::LsInput,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// `GET /tags/{tag}/notes`: `{notes: [{note_id, title, role, first_line,
/// updated_at}]}`, most recently updated first. `{tag}` is the exact name, as
/// in the app's local read; a name no note has is an empty list.
async fn tag_notes(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<TagPath>,
) -> Result<Json<tag_ops::TagNotesOutput>, ApiError> {
    let input = tag_ops::TagNotesInput { tag: path.tag };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(tag_ops::tag_notes(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// The body of `POST /notes/{note_id}/tags`.
#[derive(Deserialize)]
struct AddTag {
    tag: String,
}

/// `POST /notes/{note_id}/tags {"tag"}`: the `memex tag add` output.
async fn add_tag(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiJson(body): ApiJson<AddTag>,
) -> Result<Json<tag_ops::AddOutput>, ApiError> {
    let input = tag_ops::AddInput {
        note_id: path.note_id,
        tag: body.tag,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(tag_ops::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// `DELETE /notes/{note_id}/tags/{tag}`: the `memex tag rm` output; a tag
/// already gone is 200 with `removed: false`.
async fn remove_tag(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NoteTagPath>,
) -> Result<Json<tag_ops::RmOutput>, ApiError> {
    let input = tag_ops::RmInput {
        note_id: path.note_id,
        tag: path.tag,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(tag_ops::rm(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}
