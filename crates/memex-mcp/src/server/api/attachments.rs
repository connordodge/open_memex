//! `/vaults/{name}/api/v1/attachments…`: the attachment upload and download
//! routes (Spec #123 R40, ruling D19; WI #139).
//!
//! - `POST /attachments?name=<name>`: the raw body, up to 100 MB, stored
//!   with `memex_core::attachments::store_bytes`; answers
//!   `{markdown, path, name, size, type}`.
//! - `GET|HEAD /attachments/{*path}`: the file's bytes (GET), with
//!   `Content-Type` from its extension and `Content-Length`.
//!
//! Hashing, writing and reading run on the blocking pool against the vault
//! folder, without the vault lock (TD "No vault lease during heavy work").
//! The upload then extracts the file's text in a child process (#136) and
//! takes the lock only for the short `attachments` row writes.

use std::io;
use std::path::{Path, PathBuf};

use axum::body::Body;
use axum::http::header::{CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::{HeaderMap, Method};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use memex_core::attachments::{self, AttachmentPath, StoredAttachment, MAX_ATTACHMENT_BYTES};
use memex_core::MemexError;
use serde::Deserialize;

use crate::attachment_extract_child::extract_and_record;
use crate::cli::InvalidArgument;
use crate::server::content_length;
use crate::server::error::{ApiError, ApiPath, ApiQuery};
use crate::server::registry::ServedVault;

/// The largest upload body (R15): 104,857,600 bytes.
const UPLOAD_LIMIT: usize = MAX_ATTACHMENT_BYTES as usize;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/attachments", post(upload))
        .route("/attachments/{*path}", get(download))
}

/// Whether a request is the upload, the one route whose body may run to
/// 100 MB: `POST /vaults/<name>/api/v1/attachments`, exactly.
pub(crate) fn is_upload(method: &Method, path: &str) -> bool {
    method == Method::POST
        && path
            .strip_prefix("/vaults/")
            .and_then(|rest| rest.split_once('/'))
            .is_some_and(|(name, rest)| !name.is_empty() && rest == "api/v1/attachments")
}

#[derive(Deserialize)]
struct UploadQuery {
    name: String,
}

#[derive(Deserialize)]
struct DownloadPath {
    path: String,
}

/// `POST …/attachments?name=<name>`: stores the body (R1) and answers
/// `{markdown, path, name, size, type}`. A body over 100 MB, by
/// `Content-Length` or as it streams, is the C1 413 with the R15 text.
async fn upload(
    ServedVault(entry): ServedVault,
    ApiQuery(UploadQuery { name }): ApiQuery<UploadQuery>,
    headers: HeaderMap,
    body: Body,
) -> Result<Json<StoredAttachment>, ApiError> {
    if content_length(&headers).is_some_and(|len| len > UPLOAD_LIMIT) {
        return Err(too_large(&name));
    }
    let Ok(bytes) = axum::body::to_bytes(body, UPLOAD_LIMIT).await else {
        return Err(too_large(&name));
    };
    let state = entry.state.clone();
    drop(entry);
    let vault = state.vault_path.clone();
    let stored =
        tokio::task::spawn_blocking(move || attachments::store_bytes(&vault, &bytes, &name))
            .await??;
    // R17 (#136): extract the stored file's text in the child, with the
    // vault lock held only for the row writes, before answering.
    extract_and_record(&state, &stored).await?;
    Ok(Json(stored))
}

/// The C1 413 of an upload over 100 MB named `name` (R15).
fn too_large(name: &str) -> ApiError {
    let name = attachments::stored_name(name);
    ApiError::new(
        "payload_too_large",
        format!("{name} is larger than 100 MB and wasn't attached."),
    )
}

/// `GET|HEAD …/attachments/{*path}`: the file's bytes (none for HEAD) with
/// its `Content-Type` and `Content-Length`.
async fn download(
    method: Method,
    ServedVault(entry): ServedVault,
    ApiPath(DownloadPath { path }): ApiPath<DownloadPath>,
) -> Result<Response, ApiError> {
    let vault = entry.state.vault_path.clone();
    drop(entry);
    let with_bytes = method != Method::HEAD;
    let (name, len, bytes) =
        tokio::task::spawn_blocking(move || read(&vault, &path, with_bytes)).await??;
    let headers = [
        (CONTENT_TYPE, attachments::mime_for(&name).to_string()),
        (CONTENT_LENGTH, len.to_string()),
    ];
    Ok((headers, Body::from(bytes)).into_response())
}

/// The attachment at `path`: its name, its size and (when `with_bytes`) its
/// bytes.
///
/// `path` is tried as given, then percent-decoded (the R3 markdown url), so
/// both forms serve the file. A path that is not an R4 attachment path, or
/// one whose folders or file are a symlink or not what they should be, is
/// 400; a missing file is 404 `not found: attachment <decoded path>`.
fn read(vault: &Path, path: &str, with_bytes: bool) -> Result<(String, u64, Vec<u8>), ApiError> {
    let candidates: Vec<AttachmentPath> = [
        attachments::parse_path(path),
        attachments::parse_destination(path),
    ]
    .into_iter()
    .flatten()
    .collect();
    let Some(last) = candidates.last() else {
        return Err(InvalidArgument(format!("{path} is not an attachment path")).into());
    };
    for candidate in &candidates {
        if let Some(file) = locate(vault, candidate)? {
            let len = std::fs::metadata(&file)?.len();
            let bytes = if with_bytes {
                std::fs::read(&file)?
            } else {
                Vec::new()
            };
            return Ok((candidate.name.clone(), len, bytes));
        }
    }
    Err(MemexError::NotFound(format!("attachment {}", last.path)).into())
}

/// `<vault>/<path>` when it is a regular file reached without a symlink.
/// `None` (404) when it or a folder on the way is missing, or when its name
/// is one R1 never stores (a NUL, over 255 bytes: anything
/// [`attachments::stored_name`] changes), so no such file can exist. 400
/// when a part is a symlink or not what it should be (a file in a folder's
/// place, an end that is not a file). `path` is an R4 path, so it has no
/// `..` and stays under `<vault>/objects`.
fn locate(vault: &Path, path: &AttachmentPath) -> Result<Option<PathBuf>, ApiError> {
    let rel = &path.path;
    if attachments::stored_name(&path.name) != path.name {
        return Ok(None);
    }
    let not_a_file = || ApiError::from(InvalidArgument(format!("{rel} is not a file")));
    let mut at = vault.to_path_buf();
    for part in rel.split('/') {
        at.push(part);
        let meta = match std::fs::symlink_metadata(&at) {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) if e.kind() == io::ErrorKind::NotADirectory => return Err(not_a_file()),
            Err(e) => return Err(e.into()),
        };
        if meta.file_type().is_symlink() {
            return Err(InvalidArgument(format!("{rel} is not inside objects/")).into());
        }
    }
    if !at.is_file() {
        return Err(not_a_file());
    }
    Ok(Some(at))
}
