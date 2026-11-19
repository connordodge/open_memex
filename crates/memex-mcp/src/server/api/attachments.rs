//! `/vaults/{name}/api/v1/attachments…`: the attachment upload and download
//! routes (Spec #123 R40, ruling D19; WI #139).
//!
//! - `POST /attachments?name=<name>`: the raw body, up to 100 MB, stored
//!   with `memex_core::attachments::store_bytes`; answers
//!   `{markdown, path, name, size, type}`.
//! - `GET|HEAD /attachments/{*path}`: the file's bytes (GET), with
//!   `Content-Type` from its extension and `Content-Length`.

use axum::Router;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
}
