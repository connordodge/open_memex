//! The vault server's log, `<root>/.memex/server.log.<date>` (req 12; D7).
//!
//! Our own access-log middleware writes one line per request (method, path
//! without its query string, status, duration in ms); there is no
//! `TraceLayer`, and nothing logs headers or bodies. Dependency crates are
//! capped at `info` after the user's `--log-level`, so their debug output
//! can't carry a token.

use std::path::Path;
use std::time::Instant;

use anyhow::{Context, Result};
use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_appender::rolling::{Builder, Rotation};
use tracing_subscriber::EnvFilter;

use crate::cli::InvalidArgument;

/// Directives appended after the user's `--log-level` (D7).
const DEPENDENCY_LEVELS: &str =
    "rmcp=info,hyper=info,h2=info,tower_http=info,axum=info,reqwest=info";

/// Daily log files kept.
const MAX_LOG_FILES: usize = 7;

/// The filter for `--log-level <level>`.
pub fn filter(log_level: &str) -> Result<EnvFilter> {
    EnvFilter::try_new(format!("{log_level},{DEPENDENCY_LEVELS}"))
        .map_err(|e| InvalidArgument(format!("--log-level {log_level:?}: {e}")).into())
}

/// Sends this process's tracing output to `<root>/.memex/server.log.<date>`.
/// Keep the guard alive for as long as the server runs.
pub fn init(root: &Path, filter: EnvFilter) -> Result<WorkerGuard> {
    let dir = root.join(".memex");
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let appender = Builder::new()
        .rotation(Rotation::DAILY)
        .filename_prefix("server.log")
        .max_log_files(MAX_LOG_FILES)
        .build(&dir)
        .with_context(|| format!("open the server log in {}", dir.display()))?;
    let (writer, guard) = tracing_appender::non_blocking(appender);
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(writer)
        .with_ansi(false)
        .try_init();
    Ok(guard)
}

/// Middleware: logs `method path status duration_ms` once per request, after
/// it is answered. The query string is never logged.
pub async fn access_log(req: Request, next: Next) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let started = Instant::now();
    let resp = next.run(req).await;
    let duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    tracing::info!(
        target: "memex::access",
        %method,
        %path,
        status = resp.status().as_u16(),
        duration_ms,
        "request"
    );
    resp
}
