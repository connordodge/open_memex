//! WI #71 (R0a): the vault server's log `<root>/.memex/server.log*`
//! (req 12; D7). Drives the built `memex` binary.
//!
//! - AC 12: one access-log line per request (method, path without the
//!   query string, status, duration in ms); the startup lines carry the
//!   server's UTC offset.
//! - AC 13: at `--log-level debug`, neither the log nor stderr ever holds
//!   the token, a wrong token or a request body.

#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::Path;
use std::sync::{Arc, Mutex};

use regex::Regex;
use tracing::Level;
use tracing_subscriber::layer::SubscriberExt;

use server::{client, get, wait_for_logs, ServeChild, ServeCommand, ANY_PORT, TOKEN_ENV};

const TOKEN: &str = "log-test-token-6d5c4b3a2918f7e6d5c4b3a2";

async fn start(root: &Path, log_level: &str, tz: Option<&str>) -> (ServeChild, SocketAddr) {
    let mut cmd = ServeCommand::new(&[
        "--root",
        root.to_str().unwrap(),
        "--listen",
        ANY_PORT,
        "--log-level",
        log_level,
    ])
    .env(TOKEN_ENV, TOKEN);
    if let Some(tz) = tz {
        cmd = cmd.env("TZ", tz);
    }
    let mut child = cmd.spawn();
    let addr = child.ready().await;
    (child, addr)
}

/// Log lines that mention `needle`.
fn lines_with<'a>(logs: &'a str, needle: &str) -> Vec<&'a str> {
    logs.lines().filter(|l| l.contains(needle)).collect()
}

/// A duration in milliseconds: `12ms`, `3.4 ms`, `duration_ms=7`, `ms: 7`.
fn has_ms_duration(line: &str) -> bool {
    Regex::new(r"(\d+(\.\d+)?\s?ms\b)|(\bms\W{0,3}\d)|(_ms\W{0,3}\d)")
        .unwrap()
        .is_match(line)
}

fn has_status(line: &str, status: u16) -> bool {
    Regex::new(&format!(r"\b{status}\b"))
        .unwrap()
        .is_match(line)
}

// ---------- AC 12: access log ----------

#[tokio::test]
async fn each_request_appends_one_access_line_without_its_query_string() {
    let dir = tempfile::tempdir().unwrap();
    let (child, addr) = start(dir.path(), "info", None).await;
    let bearer = format!("Bearer {TOKEN}");
    let base = format!("http://{addr}");

    // The readiness probe was one tokenless GET /api/v1/info (401).
    let r = get(
        &format!("{base}/api/v1/info?probe=QUERYMARK1"),
        Some(&bearer),
    )
    .await;
    assert_eq!(r.status, 200);
    let r = get(
        &format!("{base}/access-log-unknown?probe=QUERYMARK2"),
        Some(&bearer),
    )
    .await;
    assert_eq!(r.status, 404);
    let r = client()
        .post(format!("{base}/access-log-post-unauth"))
        .body("x")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status().as_u16(), 401);

    let logs = wait_for_logs(dir.path(), |logs| {
        logs.contains("/access-log-unknown") && logs.contains("/access-log-post-unauth")
    })
    .await;

    let unknown = lines_with(&logs, "/access-log-unknown");
    assert_eq!(unknown.len(), 1, "one line per request:\n{logs}");
    let line = unknown[0];
    assert!(line.contains("GET"), "method: {line}");
    assert!(has_status(line, 404), "status: {line}");
    assert!(has_ms_duration(line), "duration in ms: {line}");

    let unauth = lines_with(&logs, "/access-log-post-unauth");
    assert_eq!(unauth.len(), 1, "a refused request is logged once:\n{logs}");
    assert!(unauth[0].contains("POST"), "method: {}", unauth[0]);
    assert!(has_status(unauth[0], 401), "status: {}", unauth[0]);
    assert!(has_ms_duration(unauth[0]), "duration in ms: {}", unauth[0]);

    let info: Vec<&str> = lines_with(&logs, "/api/v1/info")
        .into_iter()
        .filter(|l| has_status(l, 200))
        .collect();
    assert_eq!(info.len(), 1, "the authenticated info request:\n{logs}");
    assert!(
        info[0].contains("GET") && has_ms_duration(info[0]),
        "{}",
        info[0]
    );

    assert!(
        !logs.contains("QUERYMARK") && !logs.contains("probe="),
        "the query string is never logged:\n{logs}"
    );
    drop(child);
}

#[tokio::test]
async fn startup_logs_the_server_utc_offset_from_tz() {
    for (tz, offset) in [("Asia/Kathmandu", "+05:45"), ("Etc/GMT+3", "-03:00")] {
        let dir = tempfile::tempdir().unwrap();
        let (child, _addr) = start(dir.path(), "info", Some(tz)).await;
        let logs = wait_for_logs(dir.path(), |logs| logs.contains(offset)).await;
        assert!(logs.contains(offset), "TZ={tz} logs {offset}:\n{logs}");
        drop(child);
    }
}

// ---------- AC 13: nothing secret is logged ----------

#[tokio::test]
async fn debug_log_and_stderr_never_hold_tokens_or_bodies() {
    const WRONG: &str = "wrong-token-for-log-test-1a2b3c4d";
    const MARKER: &str = "BODY-MARKER-8e7d6c5b";
    let dir = tempfile::tempdir().unwrap();
    let (child, addr) = start(dir.path(), "debug", None).await;
    let base = format!("http://{addr}");
    let bearer = format!("Bearer {TOKEN}");
    let http = client();

    let r = get(&format!("{base}/api/v1/info"), Some(&bearer)).await;
    assert_eq!(r.status, 200);
    let r = get(
        &format!("{base}/api/v1/info?access_token={TOKEN}"),
        Some(&bearer),
    )
    .await;
    assert_eq!(r.status, 200);
    let r = get(&format!("{base}/api/v1/info?access_token={TOKEN}"), None).await;
    assert_eq!(r.status, 401);
    let r = get(
        &format!("{base}/api/v1/info"),
        Some(&format!("Bearer {WRONG}")),
    )
    .await;
    assert_eq!(r.status, 401);
    let r = http
        .post(format!("{base}/api/v1/info"))
        .header("authorization", &bearer)
        .header("content-type", "application/json")
        .body(format!("{{\"text\": \"{MARKER}\"}}"))
        .send()
        .await
        .unwrap();
    assert_ne!(r.status().as_u16(), 200, "POST to a GET route");
    let r = http
        .post(format!("{base}/log-secret-last"))
        .header("authorization", &bearer)
        .body(format!("{{\"text\": \"{MARKER}\"}}"))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status().as_u16(), 404);

    let logs = wait_for_logs(dir.path(), |logs| logs.contains("/log-secret-last")).await;
    assert!(
        lines_with(&logs, "/api/v1/info").len() >= 5,
        "the requests were logged:\n{logs}"
    );
    let stderr = child.stderr();
    for (what, secret) in [("token", TOKEN), ("wrong token", WRONG), ("body", MARKER)] {
        assert!(
            !logs.contains(secret),
            "server.log* holds the {what}:\n{logs}"
        );
        assert!(
            !stderr.contains(secret),
            "stderr holds the {what}:\n{stderr}"
        );
    }
    drop(child);
}

// ---------- Graceful shutdown (handoff contract) ----------

#[tokio::test]
async fn sigterm_and_sigint_shut_the_vault_server_down_gracefully() {
    for signal in ["TERM", "INT"] {
        let dir = tempfile::tempdir().unwrap();
        let (mut child, addr) = start(dir.path(), "info", None).await;
        let r = get(
            &format!("http://{addr}/api/v1/info"),
            Some(&format!("Bearer {TOKEN}")),
        )
        .await;
        assert_eq!(r.status, 200, "SIG{signal}: serving before the signal");
        assert!(
            child
                .stderr()
                .contains(&format!("vault server listening on http://{addr}")),
            "SIG{signal}: the listening line names the address: {}",
            child.stderr()
        );

        child.signal(signal);
        let status = child
            .wait_exit(server::WAIT)
            .unwrap_or_else(|| panic!("SIG{signal}: still running after {:?}", server::WAIT));
        assert_eq!(
            status.code(),
            Some(0),
            "SIG{signal}: a clean exit, not death by signal ({status}); stderr={}",
            child.stderr()
        );
        assert!(
            std::net::TcpStream::connect(addr).is_err(),
            "SIG{signal}: the listener is closed"
        );
        let logs = server::server_logs(dir.path());
        assert!(
            logs.contains("vault server stopped"),
            "SIG{signal}: the shutdown is logged and the log flushed:\n{logs}"
        );
    }
}

// ---------- Review round 1: the dependency cap holds for any --log-level ----------
//
// `server::log::filter` is driven directly: the probe events below go
// through a subscriber built from the filter, and a recording layer keeps
// the (target, level) of each event the filter let through.

/// The dependency crates whose events never pass above `info` (D7).
const WI71_CAPPED: [&str; 7] = [
    "rmcp",
    "hyper",
    "hyper_util",
    "h2",
    "tower_http",
    "axum",
    "reqwest",
];

/// Whether `target` belongs to a capped crate (the crate or a submodule).
fn wi71_is_capped(target: &str) -> bool {
    WI71_CAPPED
        .iter()
        .any(|c| target == *c || target.starts_with(&format!("{c}::")))
}

#[derive(Clone, Default)]
struct Wi71Recorder(Arc<Mutex<Vec<(String, Level)>>>);

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for Wi71Recorder {
    fn on_event(&self, event: &tracing::Event<'_>, _: tracing_subscriber::layer::Context<'_, S>) {
        let meta = event.metadata();
        self.0
            .lock()
            .unwrap()
            .push((meta.target().to_string(), *meta.level()));
    }
}

/// One info, one debug and one trace event for each literal target.
macro_rules! wi71_emit {
    ($($target:literal),* $(,)?) => {
        $(
            tracing::event!(target: $target, Level::INFO, "probe");
            tracing::event!(target: $target, Level::DEBUG, "probe");
            tracing::event!(target: $target, Level::TRACE, "probe");
        )*
    };
}

/// Every capped crate, some of their submodules, and our own crate.
fn wi71_emit_probes() {
    wi71_emit!(
        "rmcp",
        "rmcp::transport",
        "rmcp::transport::streamable_http_server",
        "rmcp::wi71sub",
        "hyper",
        "hyper::proto::h1::io",
        "hyper::wi71sub",
        "hyper_util",
        "hyper_util::client::legacy::pool",
        "hyper_util::wi71sub",
        "h2",
        "h2::codec::framed_read",
        "h2::wi71sub",
        "tower_http",
        "tower_http::trace::on_request",
        "tower_http::wi71sub",
        "axum",
        "axum::rejection",
        "axum::wi71sub",
        "reqwest",
        "reqwest::connect",
        "reqwest::wi71sub",
        "memex_mcp",
        "memex_mcp::server",
    );
}

/// The (target, level) of every probe event `filter(log_level)` lets
/// through. With `in_span`, the probes run inside a `memex_mcp` info span
/// named `wi71span` with a `wi71field` field.
fn wi71_events(log_level: &str, in_span: bool) -> Vec<(String, Level)> {
    let filter = memex_mcp::server::log::filter(log_level)
        .unwrap_or_else(|e| panic!("--log-level {log_level:?} is accepted: {e:#}"));
    let recorder = Wi71Recorder::default();
    let subscriber = tracing_subscriber::registry()
        .with(filter)
        .with(recorder.clone());
    tracing::subscriber::with_default(subscriber, || {
        if in_span {
            let span = tracing::info_span!(target: "memex_mcp", "wi71span", wi71field = 1);
            span.in_scope(wi71_emit_probes);
        } else {
            wi71_emit_probes();
        }
    });
    let events = recorder.0.lock().unwrap().clone();
    events
}

/// The capped events above `info` among `events`.
fn wi71_leaks(events: &[(String, Level)]) -> Vec<&(String, Level)> {
    events
        .iter()
        .filter(|(t, l)| wi71_is_capped(t) && *l > Level::INFO)
        .collect()
}

fn wi71_has(events: &[(String, Level)], target: &str, level: Level) -> bool {
    events.iter().any(|(t, l)| t == target && *l == level)
}

/// Asserts no capped event above `info` passed `log_level`, and that each
/// `(target, level)` in `must` did (so the probes ran and the filter is not
/// simply closed).
fn wi71_assert_capped(log_level: &str, in_span: bool, must: &[(&str, Level)]) {
    let events = wi71_events(log_level, in_span);
    let what = format!("--log-level {log_level:?} (in span: {in_span})");
    assert!(
        wi71_leaks(&events).is_empty(),
        "{what}: dependency events above info passed: {:?}",
        wi71_leaks(&events)
    );
    for (target, level) in must {
        assert!(
            wi71_has(&events, target, *level),
            "{what}: {target} {level} should pass; passed: {events:?}"
        );
    }
}

#[test]
fn log_filter_caps_dependency_targets_and_submodules_at_info_for_any_directive() {
    use Level as L;
    let every_capped_info: Vec<(&str, Level)> = WI71_CAPPED.iter().map(|c| (*c, L::INFO)).collect();
    let with = |mut m: Vec<(&'static str, Level)>, extra: (&'static str, Level)| {
        m.push(extra);
        m
    };
    let mut cases: Vec<(String, Vec<(&str, Level)>)> = vec![
        // Bare global levels.
        (
            "debug".into(),
            with(every_capped_info.clone(), ("memex_mcp", L::DEBUG)),
        ),
        (
            "trace".into(),
            with(every_capped_info.clone(), ("memex_mcp", L::TRACE)),
        ),
        // A submodule of a capped crate.
        (
            "rmcp::transport=debug".into(),
            vec![("rmcp::transport", L::INFO)],
        ),
        (
            "trace,rmcp::transport=trace".into(),
            vec![("rmcp::transport", L::INFO), ("memex_mcp", L::TRACE)],
        ),
        (
            "hyper_util=trace".into(),
            vec![
                ("hyper_util", L::INFO),
                ("hyper_util::client::legacy::pool", L::INFO),
            ],
        ),
        (
            "hyper_util::client=trace".into(),
            vec![("hyper_util::client::legacy::pool", L::INFO)],
        ),
        // A bare target and an empty level both mean trace to EnvFilter.
        (
            "rmcp".into(),
            vec![("rmcp", L::INFO), ("rmcp::transport", L::INFO)],
        ),
        (
            "rmcp=".into(),
            vec![("rmcp", L::INFO), ("rmcp::transport", L::INFO)],
        ),
        ("rmcp::transport".into(), vec![("rmcp::transport", L::INFO)]),
        (
            "rmcp::transport=".into(),
            vec![("rmcp::transport", L::INFO)],
        ),
        // Other level spellings.
        ("rmcp=DEBUG".into(), vec![("rmcp", L::INFO)]),
        ("rmcp=5".into(), vec![("rmcp", L::INFO)]),
        // Several capped directives at once, with our own crate.
        (
            "hyper=debug,h2=trace,tower_http=debug,axum=trace,reqwest=debug,memex_mcp=trace".into(),
            vec![
                ("hyper", L::INFO),
                ("h2", L::INFO),
                ("tower_http", L::INFO),
                ("axum", L::INFO),
                ("reqwest", L::INFO),
                ("memex_mcp", L::TRACE),
            ],
        ),
    ];
    // Each capped crate on its own, and a submodule of it.
    for c in WI71_CAPPED {
        cases.push((format!("{c}=trace"), vec![(c, L::INFO)]));
        cases.push((format!("info,{c}=debug"), vec![(c, L::INFO)]));
        cases.push((format!("{c}::wi71sub=trace"), vec![]));
    }
    for (log_level, must) in &cases {
        wi71_assert_capped(log_level, false, must);
    }
}

#[test]
fn log_filter_clamps_span_scoped_directives_so_dependencies_stay_at_info_inside_the_span() {
    // Inside a span that a span-scoped directive matches, EnvFilter enables
    // events of every target at that directive's level, so the directive
    // itself is capped at info. Its info level still applies: memex_mcp's
    // info probe (off without the span directive, since none of these sets
    // a global level of info) passes inside the span.
    for log_level in [
        "[wi71span]=debug",
        "[wi71span]=trace",
        "[wi71span]",
        "[wi71span]=",
        "memex_mcp[wi71span]=trace",
        "[{wi71field}]=debug",
        "[wi71span{wi71field}]=trace",
        "warn,[wi71span]=trace",
    ] {
        wi71_assert_capped(
            log_level,
            true,
            &[("memex_mcp", Level::INFO), ("rmcp", Level::INFO)],
        );
    }
    // A span-scoped directive on a capped target.
    wi71_assert_capped("rmcp[wi71span]=debug", true, &[("rmcp", Level::INFO)]);
}

#[test]
fn log_filter_keeps_debug_for_memex_mcp() {
    let events = wi71_events("memex_mcp=debug", false);
    assert!(wi71_has(&events, "memex_mcp", Level::DEBUG), "{events:?}");
    assert!(
        wi71_has(&events, "memex_mcp::server", Level::DEBUG),
        "{events:?}"
    );
    assert!(
        !wi71_has(&events, "memex_mcp", Level::TRACE),
        "debug, not trace: {events:?}"
    );
    assert!(wi71_leaks(&events).is_empty(), "{events:?}");

    let events = wi71_events("info,memex_mcp=trace,rmcp=debug", false);
    assert!(wi71_has(&events, "memex_mcp", Level::TRACE), "{events:?}");
    assert!(wi71_has(&events, "rmcp", Level::INFO), "{events:?}");
    assert!(wi71_leaks(&events).is_empty(), "{events:?}");
}

#[test]
fn log_filter_rejects_an_unparsable_list_as_invalid_argument() {
    for log_level in [
        "rmcp=loud",
        "rmcp::transport=verbose",
        "memex_mcp=debug,hyper=noisy",
        "[wi71span=debug",
    ] {
        let err = match memex_mcp::server::log::filter(log_level) {
            Ok(_) => panic!("--log-level {log_level:?} is rejected"),
            Err(e) => e,
        };
        assert!(
            err.downcast_ref::<memex_mcp::cli::InvalidArgument>()
                .is_some(),
            "{log_level:?}: an InvalidArgument (exit 1 invalid_argument), got {err:#}"
        );
    }
}

#[tokio::test]
async fn a_clamped_log_level_starts_silently_and_logs_no_dependency_debug() {
    // Clamping is silent: no stderr line beyond the listening line and no
    // WARN in server.log, and no capped crate logs above info while the
    // server answers requests.
    let dir = tempfile::tempdir().unwrap();
    let (child, addr) = start(
        dir.path(),
        "trace,rmcp::transport=trace,hyper=trace,hyper_util=debug,[wi71span]=trace",
        None,
    )
    .await;
    let bearer = format!("Bearer {TOKEN}");
    for path in ["/api/v1/info", "/clamp-silent-last"] {
        let _ = get(&format!("http://{addr}{path}"), Some(&bearer)).await;
    }
    let logs = wait_for_logs(dir.path(), |logs| logs.contains("/clamp-silent-last")).await;

    let stderr = child.stderr();
    let lines: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(lines.len(), 1, "only the listening line: {stderr}");
    assert!(
        lines[0].contains("vault server listening on http://"),
        "{stderr}"
    );
    assert!(
        !logs.lines().any(|l| l.contains(" WARN ")),
        "no warning about the clamp:\n{logs}"
    );
    let level_target = Regex::new(r"\b(DEBUG|TRACE)\s+([A-Za-z0-9_:]+)").unwrap();
    let leaks: Vec<&str> = logs
        .lines()
        .filter(|l| {
            level_target
                .captures(l)
                .is_some_and(|c| wi71_is_capped(c[2].trim_end_matches(':')))
        })
        .collect();
    assert!(
        leaks.is_empty(),
        "dependency debug in server.log: {leaks:#?}"
    );
    assert!(
        logs.contains("vault server started"),
        "the server logged its start:\n{logs}"
    );
    drop(child);
}

// ---------- Mutation round: the span part ends at its closing bracket ----------

#[test]
fn log_filter_clamps_a_span_directive_whose_name_ends_in_a_multibyte_char() {
    // The level is read from just past the closing `]`. A span name ending
    // in a two-byte char (`é`) puts a char boundary right at `]`, so the
    // split must land after the bracket, never inside the char before it.
    for log_level in [
        "[wi71spané]=trace",
        "[wi71spané]=debug",
        "[wi71spané]",
        "memex_mcp[wi71spané]=trace",
    ] {
        let filter = memex_mcp::server::log::filter(log_level)
            .unwrap_or_else(|e| panic!("--log-level {log_level:?} is accepted: {e:#}"));
        let recorder = Wi71Recorder::default();
        let subscriber = tracing_subscriber::registry()
            .with(filter)
            .with(recorder.clone());
        tracing::subscriber::with_default(subscriber, || {
            let span = tracing::info_span!(target: "memex_mcp", "wi71spané", wi71field = 1);
            span.in_scope(wi71_emit_probes);
        });
        let events = recorder.0.lock().unwrap().clone();
        assert!(
            wi71_leaks(&events).is_empty(),
            "{log_level:?}: dependency events above info passed: {:?}",
            wi71_leaks(&events)
        );
        for (target, level) in [("memex_mcp", Level::INFO), ("rmcp", Level::INFO)] {
            assert!(
                wi71_has(&events, target, level),
                "{log_level:?}: {target} {level} passes inside the span: {events:?}"
            );
        }
        assert!(
            !wi71_has(&events, "memex_mcp", Level::DEBUG),
            "{log_level:?}: the span directive is clamped to info: {events:?}"
        );
    }
}
