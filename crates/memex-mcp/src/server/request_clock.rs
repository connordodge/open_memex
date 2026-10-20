//! The clock a vault server handler reads: [`RequestClock`].
//!
//! `router()` puts the server's base clock ([`BaseClock`], a `SystemClock`
//! unless the config says otherwise) in every request's extensions. A
//! handler extracts a [`RequestClock`] and passes it to the core as
//! `&dyn Clock`. With no caller offset in the extensions, dates are mapped
//! in the server's local time, exactly as `SystemClock` maps them (req 59).
//!
//! The caller-offset middleware (`X-Memex-UTC-Offset`) is #93's; it inserts
//! a [`CallerUtcOffset`] that this extractor picks up.

use std::convert::Infallible;
use std::sync::Arc;

use axum::extract::{FromRequestParts, Request};
use axum::http::request::Parts;
use axum::middleware::Next;
use axum::response::Response;
use memex_core::{Clock, SystemClock};

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
}

/// The `X-Memex-UTC-Offset` middleware (D6), layered with
/// `axum::middleware::from_fn` in D7's request-clock slot. It parses the
/// header once per request with `caller_tz::parse_utc_offset`: a valid value
/// is inserted as a [`CallerUtcOffset`], a malformed one is answered with 400
/// `invalid_utc_offset` before any handler runs, and no header leaves the
/// request as it is (server-local dates).
///
/// Skeleton (#93 red): passes every request through unchanged.
pub async fn caller_utc_offset(req: Request, next: Next) -> Response {
    next.run(req).await
}

impl<S> FromRequestParts<S> for RequestClock
where
    S: Send + Sync,
{
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let base = match parts.extensions.get::<BaseClock>() {
            Some(BaseClock(clock)) => clock.clone(),
            None => Arc::new(SystemClock),
        };
        Ok(Self {
            base,
            offset: parts.extensions.get::<CallerUtcOffset>().copied(),
        })
    }
}
