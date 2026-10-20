//! The vault routes: `GET /api/v1/vaults`, `POST /api/v1/vaults`,
//! `GET /vaults/{name}/api/v1/info`, and the guard that answers every
//! `/vaults/{name}/…` path with 404 `vault_not_found` unless `name` is a
//! served vault (D8).

use std::sync::Arc;

use axum::extract::{OriginalUri, Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::{Extension, Json};
use serde::Deserialize;
use serde_json::{json, Value};

use super::error::{ApiError, ApiJson};
use super::registry::{with_vault, Registry, ServedVault};

/// `GET /api/v1/vaults`: `{"vaults": [{"name", "vault_id"}]}`, sorted by
/// lower-cased name.
pub async fn list(Extension(registry): Extension<Arc<Registry>>) -> Result<Json<Value>, ApiError> {
    let vaults: Vec<Value> = registry
        .list()
        .await?
        .into_iter()
        .map(|v| json!({ "name": v.name, "vault_id": v.vault_id }))
        .collect();
    Ok(Json(json!({ "vaults": vaults })))
}

/// The body of `POST /api/v1/vaults`.
#[derive(Deserialize)]
pub struct CreateVault {
    pub name: String,
}

/// `POST /api/v1/vaults {"name"}`: 201 `{"name", "vault_id"}`.
pub async fn create(
    Extension(registry): Extension<Arc<Registry>>,
    ApiJson(body): ApiJson<CreateVault>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let vault_id = registry.create(&body.name).await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "name": body.name, "vault_id": vault_id })),
    ))
}

/// `GET /vaults/{name}/api/v1/info`: `{"name", "vault_id",
/// "schema_version"}`, with `name` the folder name.
pub async fn info(ServedVault(entry): ServedVault) -> Result<Json<Value>, ApiError> {
    let name = entry
        .state
        .vault_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let manifest = with_vault(&entry, |vault| Ok(vault.manifest().clone())).await?;
    Ok(Json(json!({
        "name": name,
        "vault_id": manifest.vault_id,
        "schema_version": manifest.schema_version,
    })))
}

/// Middleware: on a `/vaults/{name}/…` path, resolves `name` through the
/// registry and puts the [`ServedVault`] in the request extensions, or
/// answers 404 `vault_not_found`. Other paths pass through.
pub async fn vault_guard(
    State(registry): State<Arc<Registry>>,
    mut req: Request,
    next: Next,
) -> Response {
    let path = match req.extensions().get::<OriginalUri>() {
        Some(OriginalUri(uri)) => uri.path().to_owned(),
        None => req.uri().path().to_owned(),
    };
    let Some(rest) = path.strip_prefix("/vaults/") else {
        return next.run(req).await;
    };
    let segment = rest.split('/').next().unwrap_or_default();
    let name = percent_decode(segment);
    match registry.get(&name).await {
        Ok(entry) => {
            req.extensions_mut().insert(ServedVault(entry));
            next.run(req).await
        }
        Err(e) => e.into_response(),
    }
}

/// One path segment with its `%XX` escapes decoded (a malformed escape
/// stays as written).
fn percent_decode(segment: &str) -> String {
    fn hex(b: u8) -> Option<u8> {
        (b as char).to_digit(16).map(|d| d as u8)
    }
    let bytes = segment.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escaped = match (bytes[i], bytes.get(i + 1), bytes.get(i + 2)) {
            (b'%', Some(&h), Some(&l)) => hex(h).zip(hex(l)),
            _ => None,
        };
        match escaped {
            Some((h, l)) => {
                out.push(h * 16 + l);
                i += 3;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
