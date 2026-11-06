//! `/vaults/{name}/api/v1/…`: the Smart Folder, unsorted, vault settings
//! and review prompt routes (#83).
//!
//! Reads are the app's `TopicsReads` (`memex_core::app_reads::topics`),
//! plus the vault's `smart_folder_max_depth`. Writes, `settings get` and the
//! review prompt call the ops the `memex` CLI runs (D2) with the request's
//! clock, and answer with the struct the CLI prints. Every error is the
//! CLI's C1 body.

use axum::http::StatusCode;
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use memex_core::app_reads::topics as reads;
use memex_core::{vault_settings, Clock};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::cli::InvalidArgument;
use crate::ops::{folder as folder_ops, prompt as prompt_ops, settings as settings_ops};
use crate::server::error::{ApiError, ApiJson, ApiPath};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/smart-folders", get(smart_folders).post(new_folder))
        .route(
            "/smart-folders/{folder_id}",
            patch(update_folder).delete(delete_folder),
        )
        .route("/smart-folders/{folder_id}/members", post(add_member))
        .route(
            "/smart-folders/{folder_id}/members/{note_id}",
            delete(remove_member),
        )
        .route("/unsorted", get(unsorted))
        .route("/settings/{key}", get(get_setting).put(set_setting))
        .route("/prompts/review", get(review_prompt))
}

/// The `{folder_id}` of a Smart Folder path (the nested router also holds
/// `{name}`).
#[derive(Deserialize)]
struct FolderPath {
    folder_id: String,
}

/// The `{folder_id}` and `{note_id}` of a membership path.
#[derive(Deserialize)]
struct MemberPath {
    folder_id: String,
    note_id: String,
}

/// The `{key}` of a settings path.
#[derive(Deserialize)]
struct SettingPath {
    key: String,
}

/// `GET /smart-folders`: `{"max_depth": n, "folders": [{id, name,
/// parent_id, pinned}], "members": [{folder_id, note_id, title, pinned}]}`,
/// folders by `id`, members by `folder_id` then `note_id`.
async fn smart_folders(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let (max_depth, data) = with_vault(&entry, |vault| {
        let max_depth = vault_settings::smart_folder_max_depth(vault)?;
        Ok((max_depth, reads::smart_folders(vault)?))
    })
    .await?;
    Ok(Json(json!({
        "max_depth": max_depth,
        "folders": data.folders,
        "members": data.members,
    })))
}

/// `GET /unsorted`: `{"notes": [{note_id, title, role}]}` by `note_id`.
async fn unsorted(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let notes = with_vault(&entry, |vault| Ok(reads::unsorted_notes(vault)?)).await?;
    Ok(Json(json!({ "notes": notes })))
}

/// The body of `POST /smart-folders`: `memex folder new`'s flags.
#[derive(Deserialize)]
struct NewFolder {
    name: String,
    parent_id: Option<String>,
}

/// `POST /smart-folders`: 201 with the `memex folder new` object (a
/// person-created folder, so pinned).
async fn new_folder(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiJson(body): ApiJson<NewFolder>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let input = folder_ops::NewInput {
        name: body.name,
        parent_id: body.parent_id,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(folder_ops::new(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok((StatusCode::CREATED, Json(serde_json::to_value(out)?)))
}

/// The body of `PATCH /smart-folders/{folder_id}`: `memex folder update`'s
/// flags.
#[derive(Deserialize)]
struct UpdateFolder {
    name: Option<String>,
    parent_id: Option<String>,
    #[serde(default)]
    to_root: bool,
    pinned: Option<bool>,
}

/// `PATCH /smart-folders/{folder_id}`: the `memex folder update` object.
/// `parent_id` with `to_root: true` is `invalid_argument`, as the CLI
/// refuses `--parent-id` with `--to-root`.
async fn update_folder(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<FolderPath>,
    ApiJson(body): ApiJson<UpdateFolder>,
) -> Result<Json<Value>, ApiError> {
    if body.to_root && body.parent_id.is_some() {
        return Err(InvalidArgument("parent_id conflicts with to_root".into()).into());
    }
    let input = folder_ops::UpdateInput {
        id: path.folder_id,
        name: body.name,
        parent_id: body.parent_id,
        to_root: body.to_root,
        pinned: body.pinned,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(folder_ops::update(
            vault,
            input,
            &clock as &dyn Clock,
            None,
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `DELETE /smart-folders/{folder_id}`: the `memex folder rm` object
/// (`{vault_id, id, deleted}`).
async fn delete_folder(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<FolderPath>,
) -> Result<Json<Value>, ApiError> {
    let input = folder_ops::RmInput { id: path.folder_id };
    let out = with_vault(&entry, move |vault| {
        Ok(folder_ops::rm(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// The body of `POST /smart-folders/{folder_id}/members`: `memex folder
/// add`'s flags.
#[derive(Deserialize)]
struct AddMember {
    note_id: String,
    /// The CLI's `--pinned` default.
    #[serde(default = "pinned_default")]
    pinned: bool,
}

fn pinned_default() -> bool {
    true
}

/// `POST /smart-folders/{folder_id}/members`: the `memex folder add` object
/// (`{vault_id, smart_folder_id, note_id, pinned, role_set}`).
async fn add_member(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<FolderPath>,
    ApiJson(body): ApiJson<AddMember>,
) -> Result<Json<Value>, ApiError> {
    let input = folder_ops::AddInput {
        id: path.folder_id,
        note_id: body.note_id,
        pinned: body.pinned,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(folder_ops::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `DELETE /smart-folders/{folder_id}/members/{note_id}`: the `memex folder
/// remove` object (`{vault_id, smart_folder_id, note_id, removed}`). Removing
/// an agent-placed membership records `membership_removed` in core; a pinned
/// one records nothing.
async fn remove_member(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<MemberPath>,
) -> Result<Json<Value>, ApiError> {
    let input = folder_ops::RemoveInput {
        id: path.folder_id,
        note_id: path.note_id,
    };
    let out = with_vault(&entry, move |vault| {
        Ok(folder_ops::remove(
            vault,
            input,
            &clock as &dyn Clock,
            None,
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `GET /settings/{key}`: the `memex settings get` object (`{vault_id, key,
/// value}`); an unknown key is `setting_invalid`.
async fn get_setting(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<SettingPath>,
) -> Result<Json<Value>, ApiError> {
    let input = settings_ops::GetInput { key: path.key };
    let out = with_vault(&entry, move |vault| {
        Ok(settings_ops::get(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// The body of `PUT /settings/{key}`. `value` is any JSON value, so a
/// non-integer reaches core's validation as `setting_invalid`.
#[derive(Deserialize)]
struct SetSetting {
    value: Value,
}

/// `PUT /settings/{key} {"value": n}`: the `memex settings set` object. The
/// value goes to the op as its JSON text (an integer's decimal digits, as
/// `--value` would carry them); anything but an integer from 1 to 5, or an
/// unknown key, is `setting_invalid`.
async fn set_setting(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<SettingPath>,
    ApiJson(body): ApiJson<SetSetting>,
) -> Result<Json<Value>, ApiError> {
    let input = settings_ops::SetInput {
        key: path.key,
        value: body.value.to_string(),
    };
    let out = with_vault(&entry, move |vault| {
        Ok(settings_ops::set(vault, input, &clock as &dyn Clock, None)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `GET /prompts/review`: `{"text": …}`, the `memex prompt review` stdout
/// byte for byte.
async fn review_prompt() -> Result<Json<Value>, ApiError> {
    let out = prompt_ops::get(prompt_ops::PromptKind::Review)?;
    Ok(Json(serde_json::to_value(out)?))
}
