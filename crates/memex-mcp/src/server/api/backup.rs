//! `GET` and `POST /vaults/{name}/api/v1/backup` (Spec #315 req 28;
//! architecture D17). The server's [`BackupService`] does the work; these
//! handlers only pass it the served vault's folder.

use std::sync::Arc;

use axum::http::StatusCode;
use axum::routing::get;
use axum::{Extension, Json, Router};
use serde_json::Value;

use crate::server::backup::BackupService;
use crate::server::error::ApiError;
use crate::server::registry::ServedVault;

/// The backup routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new().route("/backup", get(status).post(start))
}

/// `GET …/backup`: the vault's backup status (D17 keys, exactly).
async fn status(
    Extension(service): Extension<Arc<BackupService>>,
    ServedVault(entry): ServedVault,
) -> Json<Value> {
    Json(service.status(entry.state.vault_path.clone()).await)
}

/// `POST …/backup`: 202 with the GET body and `in_progress` true, without
/// waiting for the backup. 409 `backup_in_progress` or
/// `backups_not_configured`.
async fn start(
    Extension(service): Extension<Arc<BackupService>>,
    ServedVault(entry): ServedVault,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let body = service.start(entry.state.vault_path.clone()).await?;
    Ok((StatusCode::ACCEPTED, Json(body)))
}
