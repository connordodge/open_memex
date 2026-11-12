//! `/vaults/{name}/api/v1/…`: the learned-words routes (Spec #392, WI #431).
//!
//! Every route calls the words op the `memex words` CLI runs and answers with
//! the struct the CLI prints. Every error is the CLI's C1 body. `{word}`
//! arrives percent-decoded, so non-ASCII words work.

use axum::routing::{delete, get};
use axum::{Json, Router};
use memex_core::Clock;
use serde::Deserialize;

use crate::ops::words as word_ops;
use crate::server::error::{ApiError, ApiJson, ApiPath};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/words", get(list_words).post(add_word))
        .route("/words/{word}", delete(remove_word))
}

/// The `{word}` of a word path (the nested router also holds `{name}`).
#[derive(Deserialize)]
struct WordPath {
    word: String,
}

/// The body of `POST /words`.
#[derive(Deserialize)]
struct AddWord {
    word: String,
}

/// `GET /words`: the `memex words ls` object `{vault_id, words: [{word,
/// created_at}]}`.
async fn list_words(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
) -> Result<Json<word_ops::LsOutput>, ApiError> {
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(word_ops::ls(
            vault,
            word_ops::LsInput,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// `POST /words {"word"}`: the `memex words add` output.
async fn add_word(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiJson(body): ApiJson<AddWord>,
) -> Result<Json<word_ops::WriteOutput>, ApiError> {
    let input = word_ops::AddInput { word: body.word };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(word_ops::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}

/// `DELETE /words/{word}`: the `memex words rm` output; a word not learned
/// is 200 with `changed: false`.
async fn remove_word(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<WordPath>,
) -> Result<Json<word_ops::WriteOutput>, ApiError> {
    let input = word_ops::RmInput { word: path.word };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(word_ops::rm(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(out))
}
