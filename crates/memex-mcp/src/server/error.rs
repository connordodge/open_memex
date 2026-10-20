//! C1 error bodies for the vault server: the code → HTTP status table, the
//! [`ApiError`] response, and the extractors every route uses so that a
//! malformed request is a C1 `invalid_argument` (400).
//!
//! The app keys on the C1 code, never on the status; the status only follows
//! the code through [`status_for_code`].

use std::fmt;

use axum::extract::{FromRequest, FromRequestParts, Request};
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::de::DeserializeOwned;
use serde_json::json;

use crate::cli::{error_json, InvalidArgument};

/// The HTTP status for a C1 error code. Codes match exactly; unlisted codes
/// are 500.
pub fn status_for_code(code: &str) -> StatusCode {
    match code {
        "not_found" | "vault_not_found" => StatusCode::NOT_FOUND,
        "version_conflict" | "title_conflict" | "daily_note_exists" | "name_conflict"
        | "vault_exists" => StatusCode::CONFLICT,
        "invalid_argument" | "invalid_vault_name" | "invalid_utc_offset" | "invalid_id"
        | "invalid_date" | "setting_invalid" => StatusCode::BAD_REQUEST,
        "marker_rule"
        | "role_rule"
        | "pinned_rule"
        | "depth_exceeded"
        | "folder_cycle"
        | "change_entries_invalid"
        | "review_stale"
        | "block_not_found" => StatusCode::UNPROCESSABLE_ENTITY,
        "unauthorized" => StatusCode::UNAUTHORIZED,
        "payload_too_large" => StatusCode::PAYLOAD_TOO_LARGE,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

/// A failed request, answered with its C1 body and [`status_for_code`].
///
/// The body is `cli::error_json`'s, so a `MemexError` (even under
/// `.context(…)`) keeps its code and rule fields. Codes only the vault server
/// raises (`unauthorized`, `payload_too_large`, …) come from
/// [`ApiError::new`].
#[derive(Debug)]
pub struct ApiError(anyhow::Error);

impl ApiError {
    /// An error with a server-only C1 `code` and `message`.
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self(anyhow::Error::new(ServerCode {
            code,
            message: message.into(),
        }))
    }

    /// The C1 body: `{"error": {"code": …, "message": …, …}}`.
    fn body(&self) -> serde_json::Value {
        match self.0.downcast_ref::<ServerCode>() {
            Some(e) => json!({ "error": { "code": e.code, "message": e.message } }),
            None => error_json(&self.0),
        }
    }
}

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(err: E) -> Self {
        Self(err.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = self.body();
        let status = status_for_code(body["error"]["code"].as_str().unwrap_or_default());
        if status.is_server_error() {
            tracing::error!(error = %format!("{:#}", self.0), "request failed");
        }
        (status, Json(body)).into_response()
    }
}

/// A C1 code the core never raises (see [`ApiError::new`]).
#[derive(Debug)]
struct ServerCode {
    code: &'static str,
    message: String,
}

impl fmt::Display for ServerCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ServerCode {}

/// The answer to a request body over the limit (`payload_too_large`, 413).
pub fn payload_too_large() -> ApiError {
    ApiError::new("payload_too_large", "the request body is larger than 8 MiB")
}

/// An axum extractor rejection as a C1 error: a body over the limit is
/// `payload_too_large`, a server-side extractor fault stays `internal`, and
/// every other malformed request is `invalid_argument`.
fn rejected(status: StatusCode, text: String) -> ApiError {
    if status == StatusCode::PAYLOAD_TOO_LARGE {
        payload_too_large()
    } else if status.is_server_error() {
        ApiError::from(anyhow::anyhow!(text))
    } else {
        ApiError::from(InvalidArgument(text))
    }
}

/// `axum::Json<T>` whose rejection is a C1 `invalid_argument`.
pub struct ApiJson<T>(pub T);

impl<S, T> FromRequest<S> for ApiJson<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        axum::Json::<T>::from_request(req, state)
            .await
            .map(|axum::Json(value)| Self(value))
            .map_err(|r| rejected(r.status(), r.body_text()))
    }
}

/// `axum::extract::Path<T>` whose rejection is a C1 `invalid_argument`.
pub struct ApiPath<T>(pub T);

impl<S, T> FromRequestParts<S> for ApiPath<T>
where
    T: DeserializeOwned + Send,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        axum::extract::Path::<T>::from_request_parts(parts, state)
            .await
            .map(|axum::extract::Path(value)| Self(value))
            .map_err(|r| rejected(r.status(), r.body_text()))
    }
}

/// `axum::extract::Query<T>` whose rejection is a C1 `invalid_argument`.
pub struct ApiQuery<T>(pub T);

impl<S, T> FromRequestParts<S> for ApiQuery<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        axum::extract::Query::<T>::from_request_parts(parts, state)
            .await
            .map(|axum::extract::Query(value)| Self(value))
            .map_err(|r| rejected(r.status(), r.body_text()))
    }
}
