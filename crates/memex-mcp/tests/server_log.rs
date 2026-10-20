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

use regex::Regex;

use server::{client, free_port, get, wait_for_logs, ServeChild, ServeCommand, TOKEN_ENV};

const TOKEN: &str = "log-test-token-6d5c4b3a2918f7e6d5c4b3a2";

async fn start(root: &Path, log_level: &str, tz: Option<&str>) -> (ServeChild, SocketAddr) {
    let addr: SocketAddr = format!("127.0.0.1:{}", free_port()).parse().unwrap();
    let mut cmd = ServeCommand::new(&[
        "--root",
        root.to_str().unwrap(),
        "--listen",
        &addr.to_string(),
        "--log-level",
        log_level,
    ])
    .env(TOKEN_ENV, TOKEN);
    if let Some(tz) = tz {
        cmd = cmd.env("TZ", tz);
    }
    let mut child = cmd.spawn();
    child.wait_ready(addr).await;
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
