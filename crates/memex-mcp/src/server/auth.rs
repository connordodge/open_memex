//! The one bearer-token layer over the whole router (D7).
//!
//! The token is read only from `Authorization: Bearer <token>` (the scheme is
//! case-insensitive), never from a query string, a cookie or another header,
//! and is compared with `subtle::ConstantTimeEq`, the only token comparison
//! in the server. There is no Host or Origin check and no CORS.

use std::sync::Arc;

use axum::extract::{Request, State};
use axum::http::header::AUTHORIZATION;
use axum::http::HeaderMap;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use subtle::ConstantTimeEq;

use super::error::ApiError;

/// The token the layer accepts. No `Debug`, so it can't be logged.
#[derive(Clone)]
pub struct AccessToken(Arc<[u8]>);

impl AccessToken {
    pub fn new(token: &str) -> Self {
        Self(Arc::from(token.as_bytes()))
    }

    /// Whether `presented` is this token, in time independent of where they
    /// differ.
    fn matches(&self, presented: &[u8]) -> bool {
        bool::from(self.0.as_ref().ct_eq(presented))
    }
}

/// Middleware: runs `next` only for a request carrying the token, and
/// answers everything else 401 `unauthorized` without reading its body.
pub async fn require_token(State(token): State<AccessToken>, req: Request, next: Next) -> Response {
    match bearer_credentials(req.headers()) {
        Some(presented) if token.matches(presented) => next.run(req).await,
        _ => unauthorized().into_response(),
    }
}

/// The credentials of the request's single `Authorization: Bearer` header.
fn bearer_credentials(headers: &HeaderMap) -> Option<&[u8]> {
    let mut values = headers.get_all(AUTHORIZATION).iter();
    let value = values.next()?;
    if values.next().is_some() {
        return None;
    }
    let value = value.as_bytes();
    let space = value.iter().position(|b| *b == b' ')?;
    let (scheme, rest) = value.split_at(space);
    if !scheme.eq_ignore_ascii_case(b"bearer") {
        return None;
    }
    let credentials = rest.trim_ascii();
    (!credentials.is_empty()).then_some(credentials)
}

/// The 401 body. It never echoes what the request presented.
fn unauthorized() -> ApiError {
    ApiError::new(
        "unauthorized",
        "missing or wrong access token; send Authorization: Bearer <token>",
    )
}
