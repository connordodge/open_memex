//! `/vaults/{name}/api/v1/…`: the notes and links routes (#81).
//!
//! Reads are the app's `VaultDb` reads (`memex_core::app_reads::notes`).
//! Writes call the person-path ops the `memex` CLI runs (D2) with the
//! request's clock and the registry's shared embedder, and answer with the
//! struct the CLI prints. Every error is the CLI's C1 body.

use std::collections::BTreeMap;

use axum::http::StatusCode;
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use memex_core::app_reads::notes as reads;
use memex_core::echoes::echoes;
use memex_core::{Clock, NoteId};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::backfill::VaultLease;
use crate::cli::echoes::validate_limit;
use crate::cli::{InvalidArgument, Role};
use crate::ops::{links as link_ops, notes as note_ops};
use crate::server::error::{ApiError, ApiJson, ApiPath, ApiQuery};
use crate::server::registry::{with_vault, ServedVault};
use crate::server::request_clock::RequestClock;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/notes", get(list_notes).post(add_note))
        .route(
            "/notes/{note_id}",
            get(get_note).patch(update_note).delete(delete_note),
        )
        .route("/notes/{note_id}/links/out", get(links_out))
        .route("/notes/{note_id}/links/in", get(links_in))
        .route("/notes/{note_id}/echoes", get(note_echoes))
        .route("/titles", get(all_titles))
        .route("/titles/lookup", post(titles_lookup))
        .route("/link-kinds", get(link_kinds))
        .route("/links", post(add_link))
        .route("/links/{link_id}", patch(update_link))
}

/// The `{note_id}` of a note path (the nested router also holds `{name}`).
#[derive(Deserialize)]
struct NotePath {
    note_id: String,
}

/// The `{link_id}` of a link path.
#[derive(Deserialize)]
struct LinkPath {
    link_id: String,
}

/// `?limit=N` of the list reads.
#[derive(Deserialize)]
struct LimitQuery {
    limit: i64,
}

/// `GET /notes?limit=N`: `{"notes": [{id, title, snippet, version,
/// updated_at}]}`, newest first.
async fn list_notes(
    ServedVault(entry): ServedVault,
    ApiQuery(q): ApiQuery<LimitQuery>,
) -> Result<Json<Value>, ApiError> {
    let notes = with_vault(&entry, move |vault| Ok(reads::list_notes(vault, q.limit)?)).await?;
    Ok(Json(json!({ "notes": notes })))
}

/// `GET /notes/{note_id}`: the `memex get` object without links, plus
/// `footer_tags`; an unknown id is `not_found`.
async fn get_note(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let note = with_vault(&entry, move |vault| {
        let id = NoteId::parse(&path.note_id)?;
        Ok(reads::get_note(vault, &id)?)
    })
    .await?;
    Ok(Json(serde_json::to_value(note)?))
}

/// `GET /titles?limit=N`: `{"titles": [{id, title, updated_at}]}`, newest
/// first.
async fn all_titles(
    ServedVault(entry): ServedVault,
    ApiQuery(q): ApiQuery<LimitQuery>,
) -> Result<Json<Value>, ApiError> {
    let titles = with_vault(&entry, move |vault| Ok(reads::all_titles(vault, q.limit)?)).await?;
    Ok(Json(json!({ "titles": titles })))
}

/// `GET /notes/{note_id}/links/out`: `{"links": [...]}` by position.
async fn links_out(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
) -> Result<Json<Value>, ApiError> {
    let links = with_vault(&entry, move |vault| {
        Ok(reads::links_out(vault, &path.note_id)?)
    })
    .await?;
    Ok(Json(json!({ "links": links })))
}

/// The `others_cap` of the route's echoes read: the server's background
/// backfill embeds the other notes (Spec #391 req 11.1).
const ECHOES_OTHERS_CAP: usize = 0;

/// `GET /notes/{note_id}/echoes?limit=N` (Spec #391 req 19): `memex
/// echoes`' JSON, `{echoes, reason, pending}`, with `limit` 1 to 20.
///
/// Without an embedder (`--with-embeddings` off) it is `embeddings_off`; a
/// missing note is the core's `not_found`. `echoes()` runs on a blocking
/// thread through a [`VaultLease`], so the vault lock is held only for each
/// lease call and never across inference.
async fn note_echoes(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
    ApiQuery(q): ApiQuery<LimitQuery>,
) -> Result<Json<Value>, ApiError> {
    let Some(embedder) = entry.state.embedder.clone() else {
        return Err(ApiError::new(
            "embeddings_off",
            "embeddings are off on this vault server (start it with --with-embeddings)",
        ));
    };
    let limit = validate_limit(q.limit)?;
    let vault = entry.state.vault.clone();
    let out = tokio::task::spawn_blocking(move || {
        echoes(
            &mut VaultLease::new(vault),
            &*embedder,
            &path.note_id,
            limit,
            ECHOES_OTHERS_CAP,
        )
    })
    .await
    .map_err(|e| ApiError::from(anyhow::anyhow!("vault task failed: {e}")))??;
    Ok(Json(serde_json::to_value(out)?))
}

/// `?kind=` of the incoming-links read.
#[derive(Deserialize)]
struct KindQuery {
    kind: Option<String>,
}

/// `GET /notes/{note_id}/links/in[?kind=]`: `{"links": [...]}`, only those
/// of `kind` (matched as given) when it is set.
async fn links_in(
    ServedVault(entry): ServedVault,
    ApiPath(path): ApiPath<NotePath>,
    ApiQuery(q): ApiQuery<KindQuery>,
) -> Result<Json<Value>, ApiError> {
    let links = with_vault(&entry, move |vault| {
        Ok(reads::links_in(vault, &path.note_id, q.kind.as_deref())?)
    })
    .await?;
    Ok(Json(json!({ "links": links })))
}

/// The body of `POST /titles/lookup`.
#[derive(Deserialize)]
struct TitlesLookup {
    ids: Vec<String>,
}

/// `POST /titles/lookup {"ids": [...]}`: `{"titles": {"<id>": "<title>"}}`
/// for the ids that exist.
async fn titles_lookup(
    ServedVault(entry): ServedVault,
    ApiJson(body): ApiJson<TitlesLookup>,
) -> Result<Json<Value>, ApiError> {
    let titles: BTreeMap<String, String> = with_vault(&entry, move |vault| {
        Ok(reads::titles_for_ids(vault, &body.ids)?)
    })
    .await?;
    Ok(Json(json!({ "titles": titles })))
}

/// `GET /link-kinds`: `{"kinds": [...]}`, every kind in the links table.
async fn link_kinds(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let kinds = with_vault(&entry, |vault| Ok(reads::distinct_link_kinds(vault)?)).await?;
    Ok(Json(json!({ "kinds": kinds })))
}

/// The body of `POST /notes`: `memex add`'s flags plus the body.
#[derive(Deserialize)]
struct AddNote {
    title: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    role: Option<String>,
    content_md: String,
}

/// `POST /notes`: 201 with the `memex add` output (`{note_id, title, tags,
/// adopted}`). A tag name outside the grammar is `invalid_argument`, with no
/// note created (D43).
async fn add_note(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiJson(body): ApiJson<AddNote>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let role = match body.role.as_deref() {
        None => None,
        Some(r) => Some(Role::parse(r).ok_or_else(|| {
            ApiError::from(InvalidArgument(format!(
                "invalid role: {r} (daily or topic)"
            )))
        })?),
    };
    let input = note_ops::AddInput {
        title: body.title,
        content_md: body.content_md,
        tags: body.tags,
        role,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(note_ops::add(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok((StatusCode::CREATED, Json(serde_json::to_value(out)?)))
}

/// The body of `PATCH /notes/{note_id}`: `memex update`'s flags plus the
/// body.
#[derive(Deserialize)]
struct UpdateNote {
    expected_version: i64,
    title: Option<String>,
    content_md: String,
    #[serde(default)]
    no_rename_links: bool,
}

/// `PATCH /notes/{note_id}`: the `memex update` output (`{note_id, version,
/// updated_at}`).
async fn update_note(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiJson(body): ApiJson<UpdateNote>,
) -> Result<Json<Value>, ApiError> {
    let input = note_ops::UpdateInput {
        note_id: path.note_id,
        expected_version: body.expected_version,
        title: body.title,
        content_md: body.content_md,
        no_rename_links: body.no_rename_links,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(note_ops::update(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// `?expected_version=N` of `DELETE /notes/{note_id}`.
#[derive(Deserialize)]
struct DeleteQuery {
    expected_version: i64,
}

/// `DELETE /notes/{note_id}?expected_version=N`: the `memex rm` output
/// (`{vault_id, note_id, deleted}`).
async fn delete_note(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<NotePath>,
    ApiQuery(q): ApiQuery<DeleteQuery>,
) -> Result<Json<Value>, ApiError> {
    let input = note_ops::RmInput {
        note_id: path.note_id,
        expected_version: q.expected_version,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(note_ops::rm(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// The kind `memex add-link` uses without `--kind`.
fn default_link_kind() -> String {
    "references".to_string()
}

/// The body of `POST /links`: `memex add-link`'s flags.
#[derive(Deserialize)]
struct AddLink {
    from: String,
    to: String,
    #[serde(default = "default_link_kind")]
    kind: String,
    label: Option<String>,
}

/// `POST /links`: the `memex add-link` output. Idempotent per (from, to,
/// kind).
async fn add_link(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiJson(body): ApiJson<AddLink>,
) -> Result<Json<Value>, ApiError> {
    let input = link_ops::AddLinkInput {
        from: body.from,
        to: body.to,
        kind: body.kind,
        label: body.label,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(link_ops::add_link(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}

/// The body of `PATCH /links/{link_id}`: `memex update-link`'s flags.
#[derive(Deserialize)]
struct UpdateLink {
    kind: Option<String>,
    label: Option<String>,
    #[serde(default)]
    clear_label: bool,
}

/// `PATCH /links/{link_id}`: the `memex update-link` output.
async fn update_link(
    ServedVault(entry): ServedVault,
    clock: RequestClock,
    ApiPath(path): ApiPath<LinkPath>,
    ApiJson(body): ApiJson<UpdateLink>,
) -> Result<Json<Value>, ApiError> {
    let input = link_ops::UpdateLinkInput {
        link_id: path.link_id,
        kind: body.kind,
        label: body.label,
        clear_label: body.clear_label,
    };
    let embedder = entry.state.embedder.clone();
    let out = with_vault(&entry, move |vault| {
        Ok(link_ops::update_link(
            vault,
            input,
            &clock as &dyn Clock,
            embedder.as_deref(),
        )?)
    })
    .await?;
    Ok(Json(serde_json::to_value(out)?))
}
