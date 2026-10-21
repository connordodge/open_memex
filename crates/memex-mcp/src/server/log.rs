//! The vault server's log, `<root>/.memex/server.log.<date>` (req 12; D7).
//!
//! Our own access-log middleware writes one line per request (method, path
//! without its query string, status, duration in ms); there is no
//! `TraceLayer`, and nothing logs headers or bodies. Dependency crates are
//! capped at `info` whatever the user's `--log-level` says, so their debug
//! output can't carry a token (see [`filter`]).

use std::path::Path;
use std::time::Instant;

use anyhow::{Context, Result};
use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_appender::rolling::{Builder, Rotation};
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::EnvFilter;

use crate::cli::InvalidArgument;

/// Crates whose events never pass above `info` (D7). A target matches a
/// capped crate when it starts with the crate's name, as `EnvFilter` matches
/// targets (so `hyper` also covers `hyper_util`).
const CAPPED_CRATES: [&str; 7] = [
    "rmcp",
    "hyper",
    "hyper_util",
    "h2",
    "tower_http",
    "axum",
    "reqwest",
];

/// The most a capped crate, or a span-scoped directive, may enable.
const CAP: LevelFilter = LevelFilter::INFO;

/// Daily log files kept.
const MAX_LOG_FILES: usize = 7;

/// The filter for `--log-level <level>`, an `EnvFilter` directive list.
///
/// The cap on dependency crates holds for any directive list (D7):
/// - a directive whose target starts with a capped crate's name (`rmcp`,
///   `rmcp::transport`, `hyper_util::client`, …) is clamped to at most
///   `info`, including a bare target (which means `trace`);
/// - every span- or field-scoped directive (`[span]=debug`,
///   `memex_mcp[span]=trace`) is clamped to at most `info`, because inside a
///   matching span it enables events of every target, dependencies included;
/// - `<crate>=info` is appended for each capped crate, so a bare level such
///   as `debug` or `trace` doesn't reach them either.
///
/// Every other directive is kept, so `memex_mcp=debug` still enables debug
/// for `memex_mcp`. Clamping is silent; an unparsable list is a usage error.
pub fn filter(log_level: &str) -> Result<EnvFilter> {
    let invalid = |e: tracing_subscriber::filter::ParseError| -> anyhow::Error {
        InvalidArgument(format!("--log-level {log_level:?}: {e}")).into()
    };
    EnvFilter::try_new(log_level).map_err(invalid)?;
    let mut directives: Vec<String> = log_level
        .split(',')
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(clamp_directive)
        .collect();
    directives.extend(CAPPED_CRATES.iter().map(|c| format!("{c}={CAP}")));
    EnvFilter::try_new(directives.join(",")).map_err(invalid)
}

/// One valid, trimmed `EnvFilter` directive, with its level lowered to
/// [`CAP`] when it could enable a capped crate's events above `info`.
fn clamp_directive(directive: &str) -> String {
    if directive.parse::<LevelFilter>().is_ok() {
        // A bare global level: the appended caps outrank it.
        return directive.to_string();
    }
    // `target[span{fields}]=level`: the target runs up to the first `[` or
    // `=`; the level follows the first `=` after the span, if any.
    let target_end = directive.find(['[', '=']).unwrap_or(directive.len());
    let target = &directive[..target_end];
    let scoped = directive[target_end..].starts_with('[');
    let after_span = if scoped {
        directive.rfind(']').map_or(directive.len(), |i| i + 1)
    } else {
        target_end
    };
    let (head, level) = match directive[after_span..].find('=') {
        Some(i) => (
            &directive[..after_span + i],
            &directive[after_span + i + 1..],
        ),
        None => (directive, ""),
    };
    // No level, or an empty one, means `trace` to `EnvFilter` (while
    // `LevelFilter` parses "" as `error`).
    let level = match level {
        "" => LevelFilter::TRACE,
        level => level.parse().unwrap_or(LevelFilter::TRACE),
    };
    let capped = scoped || CAPPED_CRATES.iter().any(|c| target.starts_with(c));
    if capped && level > CAP {
        format!("{head}={CAP}")
    } else {
        directive.to_string()
    }
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
