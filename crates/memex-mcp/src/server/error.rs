//! C1 error bodies for the vault server: the code → HTTP status table, the
//! [`ApiError`] response, and the extractors every route uses so that a
//! malformed request is a C1 `invalid_argument` (400).
//!
//! Red-commit skeleton for WI #71: signatures only.

use axum::extract::{FromRequest, FromRequestParts, Request};
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::de::DeserializeOwned;

/// The HTTP status for a C1 error code. Unlisted codes are 500.
pub fn status_for_code(code: &str) -> StatusCode {
    let _ = code;
    StatusCode::INTERNAL_SERVER_ERROR
}

/// A failed request, answered with its C1 body and [`status_for_code`].
#[derive(Debug)]
pub struct ApiError(anyhow::Error);

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(err: E) -> Self {
        Self(err.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        drop(self.0);
        StatusCode::INTERNAL_SERVER_ERROR.into_response()
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
            .map_err(ApiError::from)
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
            .map_err(ApiError::from)
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
            .map_err(ApiError::from)
    }
}
