//! The clock a vault server handler reads: [`RequestClock`].
//!
//! `router()` puts the server's base clock ([`BaseClock`], a `SystemClock`
//! unless the config says otherwise) in every request's extensions. A
//! handler extracts a [`RequestClock`] and passes it to the core as
//! `&dyn Clock`. With no caller offset in the extensions, dates are mapped
//! in the server's local time, exactly as `SystemClock` maps them (req 59).
//!
//! The caller-offset middleware ([`caller_utc_offset`], `X-Memex-UTC-Offset`)
//! inserts a [`CallerUtcOffset`] that this extractor picks up; the
//! `RequestClock` then maps dates in that offset (D6).

use std::convert::Infallible;
use std::sync::Arc;

use axum::extract::{FromRequestParts, Request};
use axum::http::request::Parts;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use memex_core::{Clock, FixedOffset, SystemClock};

use super::error::ApiError;
use crate::caller_tz::parse_utc_offset;

/// The request header that carries the caller's UTC offset (req 59).
pub const UTC_OFFSET_HEADER: &str = "x-memex-utc-offset";

/// A clock the server shares between requests.
pub type SharedClock = Arc<dyn Clock + Send + Sync>;

/// The server's base clock, as a request extension.
#[derive(Clone)]
pub struct BaseClock(pub SharedClock);

/// The caller's UTC offset in signed minutes east of UTC (`+05:30` is 330),
/// as a request extension.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CallerUtcOffset(pub i32);

/// The clock for one request: the server's base clock, read on every call,
/// plus the caller's UTC offset when the request carried one.
#[derive(Clone)]
pub struct RequestClock {
    base: SharedClock,
    offset: Option<CallerUtcOffset>,
}

impl RequestClock {
    /// The clock for the request `parts` belong to: its [`BaseClock`] (or a
    /// `SystemClock` when it has none) and its [`CallerUtcOffset`], if any.
    pub fn from_parts(parts: &Parts) -> Self {
        let base = match parts.extensions.get::<BaseClock>() {
            Some(BaseClock(clock)) => clock.clone(),
            None => Arc::new(SystemClock),
        };
        Self {
            base,
            offset: parts.extensions.get::<CallerUtcOffset>().copied(),
        }
    }

    /// The caller's UTC offset, or `None` when dates map in the server's
    /// local time.
    pub fn caller_offset(&self) -> Option<CallerUtcOffset> {
        self.offset
    }
}

impl Clock for RequestClock {
    fn now_ms(&self) -> i64 {
        self.base.now_ms()
    }

    /// The caller's offset at every instant when the request carried one
    /// (like a `CallerClock` over the base clock); otherwise the server's
    /// local offset at `now_ms`, as `SystemClock` reports it.
    fn utc_offset_at(&self, now_ms: i64) -> FixedOffset {
        match self
            .offset
            .and_then(|CallerUtcOffset(minutes)| FixedOffset::east_opt(minutes.checked_mul(60)?))
        {
            Some(offset) => offset,
            None => SystemClock.utc_offset_at(now_ms),
        }
    }
}

/// The `X-Memex-UTC-Offset` middleware (D6), layered with
/// `axum::middleware::from_fn` in D7's request-clock slot. It parses the
/// header once per request with `caller_tz::parse_utc_offset`: a valid value
/// is inserted as a [`CallerUtcOffset`], a malformed one is answered with 400
/// `invalid_utc_offset` before any handler runs, and no header leaves the
/// request as it is (server-local dates).
pub async fn caller_utc_offset(mut req: Request, next: Next) -> Response {
    if let Some(value) = req.headers().get(UTC_OFFSET_HEADER) {
        let parsed = value.to_str().ok().and_then(parse_utc_offset);
        let Some(offset) = parsed else {
            return ApiError::new(
                "invalid_utc_offset",
                "X-Memex-UTC-Offset must be +HH:MM or -HH:MM, at most 14:00",
            )
            .into_response();
        };
        let minutes = offset.local_minus_utc() / 60;
        req.extensions_mut().insert(CallerUtcOffset(minutes));
    }
    next.run(req).await
}

impl<S> FromRequestParts<S> for RequestClock
where
    S: Send + Sync,
{
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        Ok(Self::from_parts(parts))
    }
}
