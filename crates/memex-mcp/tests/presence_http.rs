//! WI #446 (Spec #390 req 2, 3, 4, 5, 6): agent presence for MCP clients
//! of the vault server (`POST /vaults/{name}/mcp`).
//!
//! - Identity: a valid-ULID `X-Memex-Agent-Session` makes a `bridge` record
//!   keyed on that id, named from `X-Memex-Agent-Client` (split at the last
//!   `/`) or else the User-Agent. Without one, the record is `http`, keyed
//!   on `sha256(User-Agent, peer IP)` and named from the User-Agent's first
//!   product token (`http client` when there is none). Both identity values
//!   are cut to 64 chars. A non-ULID session header names no file.
//! - Writes: every request updates the in-memory record; the file is
//!   written at most once every 5 s per client, the first request at once
//!   and one trailing write at the window's end carrying the newest state.
//! - Sweep: expired records are deleted when a vault is first served and by
//!   the hourly sweep (`spawn_presence_sweeps`).
//! - A write failure never fails the request. `ConnectInfo` is optional.
//!
//! Every in-process test drives `server::router()` in memory with
//! `tower::ServiceExt::oneshot` on a paused tokio clock, with a fake server
//! `Clock` moved in lockstep ([`Env::at`]). A peer address is given by
//! inserting `ConnectInfo<SocketAddr>` into the request, as
//! `into_make_service_with_connect_info` does; requests without it are the
//! oneshot-router case. Waits poll in 1 ms steps of paused time; no test
//! sleeps longer than 100 ms. One test drives the built `memex serve
//! --root` binary to check the real server reads the peer address.

#[path = "support/server.rs"]
mod server;

use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{HeaderValue, Request, StatusCode};
use axum::Router;
use memex_core::agents::presence::{self, presence_dir, PresenceRecord, Transport};
use memex_core::embedder::FakeEmbedder;
use memex_core::Clock;
use memex_mcp::server::presence::spawn_presence_sweeps;
use memex_mcp::server::registry::Registry;
use memex_mcp::server::request_clock::SharedClock;
use memex_mcp::server::{router, ServerConfig};
use serde_json::{json, Value};
use tempfile::TempDir;
use tower::ServiceExt;

use server::{make_vault, ServeCommand, TEST_TOKEN, TOKEN_ENV, WAIT};

/// The fake clock's time when a test starts (ms epoch, 2023-11-14). Far
/// from the real clock, so a server that reads `SystemClock` is caught.
const T0: i64 = 1_700_000_000_000;
/// Upper bound on 1 ms polls of paused time while waiting for an event.
const POLLS: usize = 1_000;
/// What an MCP streamable-HTTP client must accept on a POST.
const ACCEPT: &str = "application/json, text/event-stream";
const SESSION_HEADER: &str = "x-memex-agent-session";
const CLIENT_HEADER: &str = "x-memex-agent-client";
const MINUTE_MS: i64 = 60_000;
const HOUR: Duration = Duration::from_secs(60 * 60);

// ---------- harness ----------

/// A `Clock` the test sets by hand.
struct FakeClock(AtomicI64);

impl FakeClock {
    fn set(&self, ms: i64) {
        self.0.store(ms, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// One in-memory vault server over a temp root holding the vault `work`.
struct Env {
    _dir: TempDir,
    root: PathBuf,
    clock: Arc<FakeClock>,
    router: Router,
    /// Paused tokio time when the fake clock read `T0`.
    start: tokio::time::Instant,
}

impl Env {
    fn new() -> Self {
        Self::with_config(|c| c)
    }

    /// A server whose config is `edit(ServerConfig::new(root, token))`
    /// plus the fake clock at `T0`.
    fn with_config(edit: impl FnOnce(ServerConfig) -> ServerConfig) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        fs::create_dir(&root).unwrap();
        make_vault(&root, "work");
        let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
        let router = serve(&root, clock.clone(), edit);
        Self {
            _dir: dir,
            root,
            clock,
            router,
            start: tokio::time::Instant::now(),
        }
    }

    /// `<root>/<name>`.
    fn vault(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    /// The vault `work`.
    fn work(&self) -> PathBuf {
        self.vault("work")
    }

    /// Sets the fake clock to `T0 + offset_ms` and moves paused tokio time
    /// to the same offset from the start, firing any timer due by then.
    async fn at(&self, offset_ms: i64) {
        self.clock.set(T0 + offset_ms);
        let target = self.start + Duration::from_millis(offset_ms as u64);
        let now = tokio::time::Instant::now();
        if target > now {
            tokio::time::advance(target - now).await;
        }
    }

    /// POSTs `msg` to `/vaults/<vault>/mcp` as `client`; returns the
    /// status and the JSON body.
    async fn post_to(&self, vault: &str, client: &Agent, msg: &Value) -> (StatusCode, Value) {
        post(&self.router, vault, client, msg).await
    }

    /// A `ping` to `work` as `client`; panics unless it is a JSON-RPC result.
    async fn ping(&self, client: &Agent) {
        let (status, body) = self.post_to("work", client, &ping_msg()).await;
        assert_rpc_ok(status, &body);
    }

    /// A `tools/call` of `list_tags` to `work` as `client`; panics unless
    /// it is a successful tool result.
    async fn tool_call(&self, client: &Agent) {
        let (status, body) = self.post_to("work", client, &tool_call_msg()).await;
        assert_tool_ok(status, &body);
    }
}

/// The vault server router over `root` with `clock` as its base clock.
fn serve(
    root: &Path,
    clock: Arc<FakeClock>,
    edit: impl FnOnce(ServerConfig) -> ServerConfig,
) -> Router {
    let shared: SharedClock = clock;
    router(edit(
        ServerConfig::new(root.to_path_buf(), TEST_TOKEN).with_clock(shared),
    ))
}

/// How a test client identifies itself: request headers and, optionally,
/// a peer address (`ConnectInfo`).
#[derive(Clone, Default)]
struct Agent {
    headers: Vec<(&'static str, HeaderValue)>,
    peer: Option<SocketAddr>,
}

impl Agent {
    /// A plain HTTP client with `user_agent` (none when `None`) from `ip`.
    fn plain(user_agent: Option<&str>, ip: [u8; 4]) -> Self {
        let mut a = Self::default().peer_ip(ip, 50_000);
        if let Some(ua) = user_agent {
            a = a.header("user-agent", ua);
        }
        a
    }

    /// A bridge: `X-Memex-Agent-Session: session`, `X-Memex-Agent-Client:
    /// client`, from 10.0.0.1.
    fn bridge(session: &str, client: &str) -> Self {
        Self::default()
            .peer_ip([10, 0, 0, 1], 50_000)
            .header(SESSION_HEADER, session)
            .header(CLIENT_HEADER, client)
    }

    fn header(self, name: &'static str, value: &str) -> Self {
        self.header_bytes(name, value.as_bytes())
    }

    fn header_bytes(mut self, name: &'static str, value: &[u8]) -> Self {
        self.headers.retain(|(n, _)| *n != name);
        self.headers
            .push((name, HeaderValue::from_bytes(value).expect("header value")));
        self
    }

    fn peer_ip(mut self, ip: [u8; 4], port: u16) -> Self {
        self.peer = Some(SocketAddr::from((ip, port)));
        self
    }

    fn no_peer(mut self) -> Self {
        self.peer = None;
        self
    }
}

fn ping_msg() -> Value {
    json!({ "jsonrpc": "2.0", "id": 1, "method": "ping" })
}

fn tool_call_msg() -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": { "name": "list_tags", "arguments": {} },
    })
}

/// POSTs `msg` to `/vaults/<vault>/mcp` through `router` in memory.
async fn post(router: &Router, vault: &str, client: &Agent, msg: &Value) -> (StatusCode, Value) {
    let mut req = Request::builder()
        .method("POST")
        .uri(format!("/vaults/{vault}/mcp"))
        .header("host", "localhost")
        .header("authorization", format!("Bearer {TEST_TOKEN}"))
        .header("content-type", "application/json")
        .header("accept", ACCEPT);
    for (name, value) in &client.headers {
        req = req.header(*name, value.clone());
    }
    if let Some(peer) = client.peer {
        req = req.extension(ConnectInfo(peer));
    }
    let req = req.body(Body::from(msg.to_string())).unwrap();
    let resp = router.clone().oneshot(req).await.expect("router answers");
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read body");
    let body = serde_json::from_slice(&bytes)
        .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into_owned()));
    (status, body)
}

fn assert_rpc_ok(status: StatusCode, body: &Value) {
    assert_eq!(status, StatusCode::OK, "MCP POST answers 200: {body}");
    assert_eq!(body["jsonrpc"], "2.0", "a JSON-RPC response: {body}");
    assert!(
        body.get("error").is_none(),
        "a result, not an error: {body}"
    );
    assert!(body.get("result").is_some(), "a result: {body}");
}

fn assert_tool_ok(status: StatusCode, body: &Value) {
    assert_rpc_ok(status, body);
    let result = &body["result"];
    assert_ne!(result["isError"], true, "the tool succeeds: {body}");
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("a text content: {body}"));
    let payload: Value = serde_json::from_str(text)
        .unwrap_or_else(|e| panic!("list_tags returns JSON ({e}): {text}"));
    assert!(
        payload.get("error").is_none(),
        "list_tags succeeds: {payload}"
    );
}

/// The record files (`*.json`) in `vault`'s presence dir, as
/// `(file stem, record)`, sorted by stem.
fn records(vault: &Path) -> Vec<(String, PresenceRecord)> {
    let Ok(entries) = fs::read_dir(presence_dir(vault)) else {
        return Vec::new();
    };
    let mut out: Vec<(String, PresenceRecord)> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "json"))
        .filter_map(|p| {
            let stem = p.file_stem()?.to_string_lossy().into_owned();
            let raw = fs::read(&p).ok()?;
            let record = serde_json::from_slice(&raw)
                .unwrap_or_else(|e| panic!("{} is not a record ({e})", p.display()));
            Some((stem, record))
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// Every file name in `vault`'s presence dir, sorted (records, `.tmp` and
/// anything else).
fn presence_file_names(vault: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(presence_dir(vault)) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// The raw JSON of the record `<session_id>.json` in `vault`.
fn record_json(vault: &Path, session_id: &str) -> Value {
    let path = presence_dir(vault).join(format!("{session_id}.json"));
    let raw = fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_slice(&raw).unwrap()
}

/// The one record in `vault`, if there is exactly one.
fn only_record(vault: &Path) -> Option<(String, PresenceRecord)> {
    let mut all = records(vault);
    (all.len() == 1).then(|| all.remove(0))
}

/// The record in `vault` named `client_name`, if exactly one is.
fn record_named(vault: &Path, client_name: &str) -> Option<(String, PresenceRecord)> {
    let mut all: Vec<_> = records(vault)
        .into_iter()
        .filter(|(_, r)| r.client_name == client_name)
        .collect();
    (all.len() == 1).then(|| all.remove(0))
}

/// Polls `f` in 1 ms steps of paused time until it returns `Some`.
async fn eventually<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    for _ in 0..POLLS {
        if let Some(v) = f() {
            return v;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    panic!("timed out waiting for {what}");
}

/// The one record in `vault` once it has `last_request_at == T0 + at`.
async fn only_record_at(vault: &Path, at: i64) -> (String, PresenceRecord) {
    let v = vault.to_path_buf();
    eventually(
        &format!("one presence record with last_request_at T0+{at}"),
        || only_record(&v).filter(|(_, r)| r.last_request_at == T0 + at),
    )
    .await
}

/// The one record in `vault`, which must already have
/// `last_request_at == T0 + at`: no polling, no waiting. The write runs
/// inside the request handler, so it is on disk when the response returns.
fn only_record_now(vault: &Path, at: i64) -> (String, PresenceRecord) {
    let (id, record) = only_record(vault).unwrap_or_else(|| {
        panic!(
            "exactly one record right after the response; found {:?}",
            records(vault)
        )
    });
    assert_eq!(
        record.last_request_at,
        T0 + at,
        "the record is written before the response returns"
    );
    (id, record)
}

/// Lets spawned tasks run without moving paused time.
async fn settle() {
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
}

/// A presence record of another session, as a stdio session or an earlier
/// server would have left it, expiring at `expires_at`.
fn left_record(session_id: &str, expires_at: i64) -> PresenceRecord {
    PresenceRecord {
        session_id: session_id.to_string(),
        client_name: format!("left-{session_id}"),
        client_version: None,
        transport: Transport::Stdio,
        started_at: expires_at - 20_000,
        last_seen_at: expires_at - 15_000,
        last_request_at: expires_at - 15_000,
        last_tool_at: None,
        expires_at,
        embeddings: false,
    }
}

fn write_left(vault: &Path, session_id: &str, expires_at: i64) {
    presence::write(&presence_dir(vault), &left_record(session_id, expires_at)).unwrap();
}

/// Whether `<vault>/.memex/agents/<session_id>.json` exists.
fn has_record(vault: &Path, session_id: &str) -> bool {
    presence_dir(vault)
        .join(format!("{session_id}.json"))
        .exists()
}

/// Every path under `dir`, recursively.
fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.filter_map(|e| e.ok()) {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        }
        out.push(path);
    }
    out
}

fn assert_is_ulid(id: &str) {
    let parsed = ulid::Ulid::from_string(id).unwrap_or_else(|e| panic!("{id} is a ULID ({e})"));
    assert_eq!(parsed.to_string(), id, "a canonical ULID string");
}

// ---------- AC 1: bridge headers ----------

#[tokio::test(start_paused = true)]
async fn bridge_headers_create_one_bridge_record_keyed_on_the_session_ulid() {
    let env = Env::new();
    let session = ulid::Ulid::new().to_string();
    let first = Agent::bridge(&session, "claude-ai/0.9.1").header("user-agent", "other-agent/9.9");
    env.ping(&first).await;
    let (stem, rec) = only_record_at(&env.work(), 0).await;
    assert_eq!(stem, session, "the file is <session ulid>.json");
    assert_eq!(rec.started_at, T0);

    // The same bridge session from another User-Agent and peer is the same
    // record: a bridge is keyed on its session header alone.
    env.at(6_000).await;
    let later = first
        .clone()
        .header("user-agent", "different/1.0")
        .peer_ip([192, 168, 1, 9], 61_000);
    env.tool_call(&later).await;
    let (stem, rec) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(stem, session);
    assert_eq!(rec.session_id, session);
    assert_eq!(rec.transport, Transport::Bridge);
    assert_eq!(rec.client_name, "claude-ai");
    assert_eq!(rec.client_version.as_deref(), Some("0.9.1"));
    assert_eq!(rec.started_at, T0, "started_at stays at first sight");
    assert_eq!(
        rec.last_seen_at,
        T0 + 6_000,
        "last_seen_at is the request time"
    );
    assert_eq!(rec.last_tool_at, Some(T0 + 6_000));
    assert_eq!(rec.expires_at, rec.last_seen_at + 15_000);
    assert_eq!(record_json(&env.work(), &session)["transport"], "bridge");
}

#[tokio::test(start_paused = true)]
async fn two_bridge_sessions_and_a_plain_client_from_one_peer_get_three_records() {
    let env = Env::new();
    let a = ulid::Ulid::new().to_string();
    let b = ulid::Ulid::new().to_string();
    let ua = "claude-code/1.2.3 (darwin)";
    env.ping(&Agent::bridge(&a, "alpha/1").header("user-agent", ua))
        .await;
    env.ping(&Agent::bridge(&b, "beta/2").header("user-agent", ua))
        .await;
    env.ping(&Agent::plain(Some(ua), [10, 0, 0, 1])).await;
    let vault = env.work();
    let all = eventually("three records", || {
        let all = records(&vault);
        (all.len() == 3).then_some(all)
    })
    .await;
    let by_name: Vec<(String, Transport)> = {
        let mut v: Vec<_> = all
            .iter()
            .map(|(_, r)| (r.client_name.clone(), r.transport))
            .collect();
        v.sort_by(|x, y| x.0.cmp(&y.0));
        v
    };
    assert_eq!(
        by_name,
        vec![
            ("alpha".to_string(), Transport::Bridge),
            ("beta".to_string(), Transport::Bridge),
            ("claude-code".to_string(), Transport::Http),
        ]
    );
    assert!(has_record(&vault, &a) && has_record(&vault, &b));
}

#[tokio::test(start_paused = true)]
async fn the_agent_client_header_splits_at_the_last_slash() {
    // (header, client_name, client_version)
    let cases: [(&str, &str, Option<&str>); 3] = [
        ("claude-ai/0.9.1", "claude-ai", Some("0.9.1")),
        ("org/agent/2.0", "org/agent", Some("2.0")),
        ("claude-ai", "claude-ai", None),
    ];
    for (header, name, version) in cases {
        let env = Env::new();
        let session = ulid::Ulid::new().to_string();
        env.ping(&Agent::bridge(&session, header).header("user-agent", "ua-agent/7.7"))
            .await;
        let (_, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(rec.client_name, name, "{header}");
        assert_eq!(rec.client_version.as_deref(), version, "{header}");
        assert_eq!(rec.transport, Transport::Bridge, "{header}");
        if version.is_none() {
            assert_eq!(
                record_json(&env.work(), &session)["client_version"],
                Value::Null,
                "{header}: no `/` stores a null version"
            );
        }
    }
}

/// (client header bytes, or none; user agent, or none; name, version)
type FallbackCase = (
    Option<&'static [u8]>,
    Option<&'static str>,
    &'static str,
    Option<&'static str>,
);

#[tokio::test(start_paused = true)]
async fn a_bridge_session_without_a_usable_client_header_takes_the_user_agent_identity() {
    let cases: [FallbackCase; 4] = [
        (
            None,
            Some("claude-code/1.2.3 (darwin)"),
            "claude-code",
            Some("1.2.3"),
        ),
        (
            Some(b""),
            Some("claude-code/1.2.3 (darwin)"),
            "claude-code",
            Some("1.2.3"),
        ),
        (
            Some(b"\xff\xfebad/1.0"),
            Some("claude-code/1.2.3 (darwin)"),
            "claude-code",
            Some("1.2.3"),
        ),
        (None, None, "http client", None),
    ];
    for (i, (client, ua, name, version)) in cases.into_iter().enumerate() {
        let env = Env::new();
        let session = ulid::Ulid::new().to_string();
        let mut agent = Agent::default()
            .peer_ip([10, 0, 0, 1], 50_000)
            .header(SESSION_HEADER, &session);
        if let Some(bytes) = client {
            agent = agent.header_bytes(CLIENT_HEADER, bytes);
        }
        if let Some(ua) = ua {
            agent = agent.header("user-agent", ua);
        }
        env.ping(&agent).await;
        let (stem, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(stem, session, "case {i}: still keyed on the session");
        assert_eq!(rec.transport, Transport::Bridge, "case {i}");
        assert_eq!(rec.client_name, name, "case {i}");
        assert_eq!(rec.client_version.as_deref(), version, "case {i}");
    }
}

// ---------- AC 2: plain HTTP keyed on User-Agent and peer IP ----------

#[tokio::test(start_paused = true)]
async fn a_plain_http_client_is_keyed_on_user_agent_and_peer_ip_and_reuses_its_session_id() {
    let env = Env::new();
    let ua = "claude-code/1.2.3 (darwin)";
    env.ping(&Agent::plain(Some(ua), [10, 0, 0, 7]).peer_ip([10, 0, 0, 7], 50_001))
        .await;
    let (first_id, rec) = only_record_at(&env.work(), 0).await;
    assert_is_ulid(&first_id);
    assert_eq!(rec.session_id, first_id, "the file is <session_id>.json");
    assert_eq!(rec.started_at, T0);

    // Same User-Agent and IP from another source port: the same session.
    env.at(6_000).await;
    env.ping(&Agent::plain(Some(ua), [10, 0, 0, 7]).peer_ip([10, 0, 0, 7], 50_999))
        .await;
    let (id, rec) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(id, first_id, "repeated requests reuse the session_id");
    assert_eq!(rec.session_id, first_id);
    assert_eq!(rec.transport, Transport::Http);
    assert_eq!(rec.client_name, "claude-code");
    assert_eq!(rec.client_version.as_deref(), Some("1.2.3"));
    assert_eq!(rec.started_at, T0, "started_at stays at first sight");
    assert_eq!(
        rec.last_seen_at,
        T0 + 6_000,
        "last_seen_at is the request time"
    );
    assert_eq!(rec.expires_at, rec.last_request_at + 60_000);
    assert_eq!(record_json(&env.work(), &id)["transport"], "http");
}

#[tokio::test(start_paused = true)]
async fn the_same_user_agent_from_two_peer_ips_gets_two_records() {
    let env = Env::new();
    let ua = "claude-code/1.2.3 (darwin)";
    env.ping(&Agent::plain(Some(ua), [10, 0, 0, 7])).await;
    env.ping(&Agent::plain(Some(ua), [10, 0, 0, 8])).await;
    let vault = env.work();
    let all = eventually("two records", || {
        let all = records(&vault);
        (all.len() == 2).then_some(all)
    })
    .await;
    assert_ne!(all[0].1.session_id, all[1].1.session_id);
    assert!(all
        .iter()
        .all(|(_, r)| r.client_name == "claude-code" && r.transport == Transport::Http));
}

#[tokio::test]
async fn memex_serve_keys_plain_http_clients_by_their_peer_address() {
    // The real server (`run`) serves with ConnectInfo: one User-Agent from
    // two peer addresses (IPv4 and IPv6 loopback on a dual-stack listener)
    // is two clients.
    let dir = tempfile::tempdir().unwrap();
    make_vault(dir.path(), "work");
    let root = dir.path().to_str().unwrap();
    let mut child = ServeCommand::new(&["--root", root, "--listen", "[::]:0"])
        .env(TOKEN_ENV, TEST_TOKEN)
        .spawn();
    let port = child.listening_addr().await.port();
    let http = server::client();
    for host in ["127.0.0.1", "[::1]"] {
        let resp = http
            .post(format!("http://{host}:{port}/vaults/work/mcp"))
            .header("authorization", format!("Bearer {TEST_TOKEN}"))
            .header("content-type", "application/json")
            .header("accept", ACCEPT)
            .header("user-agent", "probe-agent/3.1")
            .body(ping_msg().to_string())
            .send()
            .await
            .unwrap_or_else(|e| panic!("POST via {host}: {e}"));
        assert_eq!(resp.status(), 200, "ping via {host}");
    }
    let vault = dir.path().join("work");
    let started = std::time::Instant::now();
    loop {
        let all = records(&vault);
        if all.len() == 2 {
            assert!(all
                .iter()
                .all(|(_, r)| r.client_name == "probe-agent" && r.transport == Transport::Http));
            assert_ne!(all[0].1.session_id, all[1].1.session_id);
            break;
        }
        assert!(
            started.elapsed() < WAIT,
            "two http records, one per peer address; have {:?}; stderr={}",
            presence_file_names(&vault),
            child.stderr()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    child.stop();
}

// ---------- AC 3: User-Agent identity ----------

#[tokio::test(start_paused = true)]
async fn a_different_user_agent_from_the_same_ip_gets_a_second_record() {
    let env = Env::new();
    env.ping(&Agent::plain(
        Some("claude-code/1.2.3 (darwin)"),
        [10, 0, 0, 7],
    ))
    .await;
    env.ping(&Agent::plain(Some("cursor/0.42.0"), [10, 0, 0, 7]))
        .await;
    let vault = env.work();
    let (_, code) = eventually("claude-code's record", || {
        record_named(&vault, "claude-code")
    })
    .await;
    let (_, cursor) = eventually("cursor's record", || record_named(&vault, "cursor")).await;
    assert_ne!(code.session_id, cursor.session_id);
    assert_eq!(cursor.client_version.as_deref(), Some("0.42.0"));
    assert_eq!(records(&vault).len(), 2);
}

#[tokio::test(start_paused = true)]
async fn a_request_without_user_agent_is_named_http_client_with_a_null_version() {
    let env = Env::new();
    env.ping(&Agent::plain(None, [10, 0, 0, 7])).await;
    let (id, rec) = only_record_at(&env.work(), 0).await;
    assert_eq!(rec.client_name, "http client");
    assert_eq!(rec.client_version, None);
    assert_eq!(rec.transport, Transport::Http);
    assert_eq!(record_json(&env.work(), &id)["client_version"], Value::Null);

    // No User-Agent is its own client, apart from one with a User-Agent.
    env.ping(&Agent::plain(Some("curl/8.4.0"), [10, 0, 0, 7]))
        .await;
    let vault = env.work();
    eventually("a second record", || {
        (records(&vault).len() == 2).then_some(())
    })
    .await;
}

#[tokio::test(start_paused = true)]
async fn the_user_agent_first_product_token_gives_name_and_version() {
    // (User-Agent, client_name, client_version)
    let cases: [(&str, &str, Option<&str>); 4] = [
        ("claude-code/1.2.3 (darwin)", "claude-code", Some("1.2.3")),
        ("python-httpx/0.27.0", "python-httpx", Some("0.27.0")),
        (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1",
            "Mozilla",
            Some("5.0"),
        ),
        ("curl", "curl", None),
    ];
    for (ua, name, version) in cases {
        let env = Env::new();
        env.ping(&Agent::plain(Some(ua), [10, 0, 0, 7])).await;
        let (_, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(rec.client_name, name, "{ua}");
        assert_eq!(rec.client_version.as_deref(), version, "{ua}");
    }
}

// ---------- AC 4: 64-char identity ----------

#[tokio::test(start_paused = true)]
async fn a_100_char_client_name_or_version_is_stored_as_64_chars() {
    let long_name = "n".repeat(100);
    let long_version = "9".repeat(100);
    let short_name = "n".repeat(64);
    let short_version = "9".repeat(64);
    // (agent, client_name, client_version)
    let session = ulid::Ulid::new().to_string();
    let cases: Vec<(&str, Agent, String, Option<String>)> = vec![
        (
            "bridge client header name",
            Agent::bridge(&session, &format!("{long_name}/0.9.1")),
            short_name.clone(),
            Some("0.9.1".to_string()),
        ),
        (
            "bridge client header version",
            Agent::bridge(&session, &format!("claude-ai/{long_version}")),
            "claude-ai".to_string(),
            Some(short_version.clone()),
        ),
        (
            "user agent name",
            Agent::plain(Some(&format!("{long_name}/1.0 (darwin)")), [10, 0, 0, 7]),
            short_name.clone(),
            Some("1.0".to_string()),
        ),
        (
            "user agent version",
            Agent::plain(Some(&format!("agent/{long_version}")), [10, 0, 0, 7]),
            "agent".to_string(),
            Some(short_version.clone()),
        ),
        (
            "bridge falling back to the user agent",
            Agent::default()
                .peer_ip([10, 0, 0, 1], 50_000)
                .header(SESSION_HEADER, &session)
                .header("user-agent", &format!("{long_name}/{long_version}")),
            short_name.clone(),
            Some(short_version.clone()),
        ),
    ];
    for (what, agent, name, version) in cases {
        let env = Env::new();
        env.ping(&agent).await;
        let (_, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(rec.client_name, name, "{what}");
        assert_eq!(rec.client_version, version, "{what}");
    }
}

// ---------- AC 5: a non-ULID session header names no file ----------

#[tokio::test(start_paused = true)]
async fn a_non_ulid_session_header_is_ignored_and_names_no_file() {
    let bogus = [
        "../../evil",
        "",
        "evil.json",
        "/tmp/evil",
        // 25 and 27 chars.
        "01ARZ3NDEKTSV4RRFFQ69G5FA",
        "01ARZ3NDEKTSV4RRFFQ69G5FAVX",
        // 26 chars with a non-Crockford character.
        "01ARZ3NDEKTSV4RRFFQ69G5FA!",
    ];
    for value in bogus {
        let env = Env::new();
        let plain = Agent::plain(Some("probe/1.0"), [10, 0, 0, 7]);
        env.ping(&plain).await;
        let (plain_id, _) = only_record_at(&env.work(), 0).await;

        env.at(6_000).await;
        let spoofed = plain
            .clone()
            .header(SESSION_HEADER, value)
            .header(CLIENT_HEADER, "evil-client/6.6.6");
        env.ping(&spoofed).await;
        let (id, rec) = only_record_at(&env.work(), 6_000).await;
        assert_eq!(
            id, plain_id,
            "{value:?}: keyed as the plain HTTP client from that User-Agent and IP"
        );
        assert_eq!(rec.transport, Transport::Http, "{value:?}");
        assert_eq!(
            rec.client_name, "probe",
            "{value:?}: the plain-HTTP identity"
        );
        assert_eq!(
            presence_file_names(&env.work()),
            vec![format!("{plain_id}.json")],
            "{value:?}: only the plain client's record"
        );
        let named_after: Vec<PathBuf> = walk(env._dir.path())
            .into_iter()
            .filter(|p| {
                let name = p.file_name().unwrap().to_string_lossy();
                name.contains("evil") || (!value.is_empty() && name.starts_with(value))
            })
            .collect();
        assert!(
            named_after.is_empty(),
            "{value:?}: no file is named after the header: {named_after:?}"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn a_lowercase_session_ulid_is_stored_under_its_canonical_uppercase_id() {
    let env = Env::new();
    let session = ulid::Ulid::new().to_string();
    let lower = session.to_lowercase();
    env.ping(&Agent::bridge(&lower, "claude-ai/0.9.1")).await;
    let (stem, rec) = only_record_at(&env.work(), 0).await;
    assert_eq!(stem, session, "the file is named by the canonical ULID");
    assert_eq!(rec.session_id, session);
    assert_eq!(rec.transport, Transport::Bridge);

    env.at(6_000).await;
    env.ping(&Agent::bridge(&session, "claude-ai/0.9.1")).await;
    let (stem, _) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(stem, session, "either case is the same session");
}

// ---------- AC 6: no ConnectInfo ----------

#[tokio::test(start_paused = true)]
async fn a_oneshot_router_without_connect_info_answers_mcp_and_writes_a_record() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [0, 0, 0, 0]).no_peer();
    let (status, body) = env.post_to("work", &agent, &tool_call_msg()).await;
    assert_tool_ok(status, &body);
    let (id, rec) = only_record_at(&env.work(), 0).await;
    assert_eq!(rec.transport, Transport::Http);
    assert_eq!(rec.client_name, "claude-code");
    assert_eq!(rec.last_tool_at, Some(T0));

    env.at(6_000).await;
    let (status, body) = env.post_to("work", &agent, &ping_msg()).await;
    assert_rpc_ok(status, &body);
    let (again, _) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(
        again, id,
        "without a peer address the key is the User-Agent alone"
    );
}

// ---------- AC 7: 5 s write throttle with one trailing write ----------

#[tokio::test(start_paused = true)]
async fn two_requests_1s_apart_write_once_then_trail_at_the_window_end() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    let (id, _) = only_record_at(&env.work(), 0).await;

    env.at(1_000).await;
    env.ping(&agent).await;
    settle().await;
    assert_eq!(
        only_record(&env.work()).unwrap().1.last_request_at,
        T0,
        "a request inside the window does not write at once"
    );

    env.at(4_900).await;
    settle().await;
    assert_eq!(
        only_record(&env.work()).unwrap().1.last_request_at,
        T0,
        "no write before the window ends"
    );

    env.at(5_000).await;
    let (again, rec) = only_record_at(&env.work(), 1_000).await;
    assert_eq!(again, id);
    assert_eq!(rec.last_seen_at, T0 + 1_000);
    assert_eq!(rec.expires_at, T0 + 1_000 + 60_000);
}

#[tokio::test(start_paused = true)]
async fn the_trailing_write_carries_the_newest_of_several_requests() {
    let env = Env::new();
    let session = ulid::Ulid::new().to_string();
    let agent = Agent::bridge(&session, "claude-ai/0.9.1");
    env.ping(&agent).await;
    only_record_at(&env.work(), 0).await;

    env.at(1_000).await;
    env.tool_call(&agent).await;
    env.at(3_000).await;
    env.ping(&agent).await;
    env.at(4_999).await;
    settle().await;
    assert_eq!(only_record(&env.work()).unwrap().1.last_request_at, T0);

    env.at(5_000).await;
    let (_, rec) = only_record_at(&env.work(), 3_000).await;
    assert_eq!(rec.last_tool_at, Some(T0 + 1_000));
    assert_eq!(rec.last_seen_at, T0 + 3_000);
    assert_eq!(rec.expires_at, T0 + 3_000 + 15_000);
}

#[tokio::test(start_paused = true)]
async fn a_request_5s_after_the_last_write_writes_at_once() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    only_record_at(&env.work(), 0).await;
    env.at(5_000).await;
    env.ping(&agent).await;
    // On disk when the response returns: a window of exactly 5000 ms is
    // over, so this is not a trailing write that merely fires soon.
    let (_, rec) = only_record_now(&env.work(), 5_000);
    assert_eq!(rec.last_seen_at, T0 + 5_000);
}

#[tokio::test(start_paused = true)]
async fn the_first_request_writes_its_record_before_the_response_returns() {
    let env = Env::new();
    let session = ulid::Ulid::new().to_string();
    // A plain client and a bridge: each writes at once, with no wait.
    env.ping(&Agent::plain(
        Some("claude-code/1.2.3 (darwin)"),
        [10, 0, 0, 7],
    ))
    .await;
    let (_, http) = only_record_now(&env.work(), 0);
    assert_eq!(http.transport, Transport::Http);

    let bridge = Agent::bridge(&session, "claude-ai/0.9.1");
    env.ping(&bridge).await;
    let written = records(&env.work());
    assert_eq!(written.len(), 2, "both clients are on disk at once");
    let (_, rec) = written
        .iter()
        .find(|(id, _)| *id == session)
        .expect("the bridge record");
    assert_eq!(rec.last_request_at, T0);
}

#[tokio::test(start_paused = true)]
async fn a_request_after_the_clock_stepped_back_writes_at_once() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    only_record_now(&env.work(), 0);

    // An NTP or manual correction puts the clock 30 minutes back: the last
    // write is stamped in the future. The next request must not wait for
    // the clock to catch up (a trailing write 30 minutes out would let the
    // record expire while the agent is active): it writes at once.
    let back = -30 * MINUTE_MS;
    env.clock.set(T0 + back);
    env.ping(&agent).await;
    let (_, rec) = only_record_now(&env.work(), back);
    assert_eq!(rec.last_seen_at, T0 + back);
    assert_eq!(rec.expires_at, T0 + back + 60_000);
}

#[tokio::test(start_paused = true)]
async fn after_the_clock_stepped_back_the_throttle_runs_from_the_new_time() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    let back = -30 * MINUTE_MS;
    env.clock.set(T0 + back);
    env.ping(&agent).await;
    only_record_now(&env.work(), back);

    // The write at the stepped-back time is a write: a request 1 s later is
    // inside its window and waits for the trailing write at the window's
    // end, at most one window away, not 30 minutes.
    env.clock.set(T0 + back + 1_000);
    tokio::time::advance(Duration::from_millis(1_000)).await;
    env.ping(&agent).await;
    settle().await;
    assert_eq!(
        only_record(&env.work()).unwrap().1.last_request_at,
        T0 + back,
        "inside the window of the write at the stepped-back time"
    );
    env.clock.set(T0 + back + 5_000);
    tokio::time::advance(Duration::from_millis(4_000)).await;
    let (_, rec) = only_record_at(&env.work(), back + 1_000).await;
    assert_eq!(rec.last_seen_at, T0 + back + 1_000);
}

#[tokio::test(start_paused = true)]
async fn a_request_just_inside_the_window_waits_for_the_trailing_write() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    only_record_at(&env.work(), 0).await;
    env.at(4_999).await;
    env.ping(&agent).await;
    settle().await;
    assert_eq!(
        only_record(&env.work()).unwrap().1.last_request_at,
        T0,
        "4999 ms after the last write is still inside the window"
    );
    env.at(5_000).await;
    only_record_at(&env.work(), 4_999).await;
}

#[tokio::test(start_paused = true)]
async fn a_request_after_a_trailing_write_waits_a_full_window_from_it() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    only_record_at(&env.work(), 0).await;
    env.at(1_000).await;
    env.ping(&agent).await;
    env.at(5_000).await;
    only_record_at(&env.work(), 1_000).await;

    // The trailing write at 5 s is a write: the next one is 5 s after it.
    env.at(6_000).await;
    env.ping(&agent).await;
    settle().await;
    assert_eq!(
        only_record(&env.work()).unwrap().1.last_request_at,
        T0 + 1_000
    );
    env.at(9_900).await;
    settle().await;
    assert_eq!(
        only_record(&env.work()).unwrap().1.last_request_at,
        T0 + 1_000
    );
    env.at(10_000).await;
    only_record_at(&env.work(), 6_000).await;
}

#[tokio::test(start_paused = true)]
async fn the_write_throttle_is_per_client() {
    let env = Env::new();
    env.ping(&Agent::plain(Some("alpha/1.0"), [10, 0, 0, 7]))
        .await;
    env.at(1_000).await;
    env.ping(&Agent::plain(Some("beta/1.0"), [10, 0, 0, 7]))
        .await;
    let vault = env.work();
    let (_, beta) = eventually("beta's record, written at once", || {
        record_named(&vault, "beta")
    })
    .await;
    assert_eq!(beta.last_request_at, T0 + 1_000);
}

// ---------- AC 8: ping vs tools/call ----------

#[tokio::test(start_paused = true)]
async fn a_ping_sets_last_request_at_but_not_last_tool_at_and_a_tool_call_sets_both() {
    let session = ulid::Ulid::new().to_string();
    let clients = [
        (
            "http",
            Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]),
        ),
        ("bridge", Agent::bridge(&session, "claude-ai/0.9.1")),
    ];
    for (what, agent) in clients {
        let env = Env::new();
        env.ping(&agent).await;
        let (id, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(rec.last_tool_at, None, "{what}: a ping is not a tool call");
        assert_eq!(record_json(&env.work(), &id)["last_tool_at"], Value::Null);

        env.at(5_000).await;
        env.tool_call(&agent).await;
        let (_, rec) = only_record_at(&env.work(), 5_000).await;
        assert_eq!(
            rec.last_tool_at,
            Some(T0 + 5_000),
            "{what}: tools/call sets both"
        );

        env.at(10_000).await;
        env.ping(&agent).await;
        let (_, rec) = only_record_at(&env.work(), 10_000).await;
        assert_eq!(
            rec.last_tool_at,
            Some(T0 + 5_000),
            "{what}: a later ping keeps last_tool_at"
        );
    }
}

// ---------- AC 9: embeddings ----------

#[tokio::test(start_paused = true)]
async fn records_carry_the_servers_embedder_state() {
    for on in [true, false] {
        let env = Env::with_config(|c| {
            if on {
                c.with_embeddings(true)
                    .with_embedder(Arc::new(FakeEmbedder::new(384)))
            } else {
                c
            }
        });
        let session = ulid::Ulid::new().to_string();
        env.ping(&Agent::plain(
            Some("claude-code/1.2.3 (darwin)"),
            [10, 0, 0, 7],
        ))
        .await;
        env.ping(&Agent::bridge(&session, "claude-ai/0.9.1")).await;
        let vault = env.work();
        let all = eventually("two records", || {
            let all = records(&vault);
            (all.len() == 2).then_some(all)
        })
        .await;
        for (id, rec) in &all {
            assert_eq!(
                rec.embeddings, on,
                "{:?} record with embedder on={on}",
                rec.transport
            );
            assert_eq!(record_json(&vault, id)["embeddings"], on);
        }
    }
}

// ---------- AC 10: sweeps ----------

#[tokio::test(start_paused = true)]
async fn a_served_vaults_expired_records_are_swept_when_the_server_first_serves_it() {
    let env = Env::new();
    let vault = env.work();
    let gone = ulid::Ulid::new().to_string();
    let edge = ulid::Ulid::new().to_string();
    let live = ulid::Ulid::new().to_string();
    write_left(&vault, &gone, T0 - 60_000);
    write_left(&vault, &edge, T0);
    write_left(&vault, &live, T0 + 1);

    env.ping(&Agent::plain(
        Some("claude-code/1.2.3 (darwin)"),
        [10, 0, 0, 7],
    ))
    .await;
    eventually("the expired records swept", || {
        (!has_record(&vault, &gone) && !has_record(&vault, &edge)).then_some(())
    })
    .await;
    assert!(has_record(&vault, &live), "an unexpired record is kept");
    eventually("the client's own record", || {
        record_named(&vault, "claude-code")
    })
    .await;
}

#[tokio::test(start_paused = true)]
async fn the_hourly_sweep_deletes_every_served_vaults_expired_records() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    make_vault(&root, "alpha");
    make_vault(&root, "beta");
    let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let shared: SharedClock = clock.clone();
    let registry = Arc::new(Registry::new(root.clone(), None));
    registry.get("alpha").await.expect("serve alpha");
    registry.get("beta").await.expect("serve beta");
    let (alpha, beta) = (root.join("alpha"), root.join("beta"));
    let a_30 = ulid::Ulid::new().to_string();
    let a_90 = ulid::Ulid::new().to_string();
    let b_30 = ulid::Ulid::new().to_string();
    write_left(&alpha, &a_30, T0 + 30 * MINUTE_MS);
    write_left(&alpha, &a_90, T0 + 90 * MINUTE_MS);
    write_left(&beta, &b_30, T0 + 30 * MINUTE_MS);

    let start = tokio::time::Instant::now();
    let at = |minutes: i64| {
        let clock = clock.clone();
        async move {
            clock.set(T0 + minutes * MINUTE_MS);
            let target = start + Duration::from_secs(minutes as u64 * 60);
            let now = tokio::time::Instant::now();
            if target > now {
                tokio::time::advance(target - now).await;
            }
        }
    };
    let sweeps = spawn_presence_sweeps(registry.clone(), shared, HOUR);
    settle().await;
    assert!(has_record(&alpha, &a_30) && has_record(&beta, &b_30));

    at(31).await;
    settle().await;
    assert!(
        has_record(&alpha, &a_30) && has_record(&beta, &b_30),
        "no sweep before the hour"
    );

    at(60).await;
    eventually("the hourly sweep of both vaults", || {
        (!has_record(&alpha, &a_30) && !has_record(&beta, &b_30)).then_some(())
    })
    .await;
    assert!(has_record(&alpha, &a_90), "an unexpired record is kept");

    at(120).await;
    eventually("the next hour's sweep", || {
        (!has_record(&alpha, &a_90)).then_some(())
    })
    .await;
    sweeps.abort();
}

// ---------- AC 11: restart ----------

#[tokio::test(start_paused = true)]
async fn after_a_restart_the_same_user_agent_and_ip_get_a_new_session_id() {
    let env = Env::new();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    let (old_id, old) = only_record_at(&env.work(), 0).await;

    // A restarted server: a fresh router, registry and HttpSessions over
    // the same root.
    env.at(1_000).await;
    let restarted = serve(&env.root, env.clock.clone(), |c| c);
    let (status, body) = post(&restarted, "work", &agent, &ping_msg()).await;
    assert_rpc_ok(status, &body);
    let vault = env.work();
    let all = eventually("a second record", || {
        let all = records(&vault);
        (all.len() == 2).then_some(all)
    })
    .await;
    let new = all
        .iter()
        .find(|(id, _)| *id != old_id)
        .map(|(_, r)| r.clone())
        .unwrap();
    assert_is_ulid(&new.session_id);
    assert_ne!(new.session_id, old_id, "a new session_id after the restart");
    assert_eq!(new.last_request_at, T0 + 1_000);
    assert_eq!(new.started_at, T0 + 1_000);
    let (_, still) = all.iter().find(|(id, _)| *id == old_id).unwrap();
    assert_eq!(*still, old, "the old record is left to expire");
}

// ---------- AC 12: a write failure ----------

#[tokio::test(start_paused = true)]
async fn a_presence_write_failure_does_not_fail_the_mcp_request() {
    let env = Env::new();
    let vault = env.work();
    // A file where the presence dir should be: every write fails.
    let blocker = presence_dir(&vault);
    fs::create_dir_all(blocker.parent().unwrap()).unwrap();
    fs::write(&blocker, b"not a directory").unwrap();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);

    env.tool_call(&agent).await;
    env.ping(&agent).await;
    let session = ulid::Ulid::new().to_string();
    env.ping(&Agent::bridge(&session, "claude-ai/0.9.1")).await;
    settle().await;
    assert!(blocker.is_file(), "the blocker is still there");

    // Presence resumes once the directory can be written: the newest state
    // lands by the end of the next window at the latest.
    fs::remove_file(&blocker).unwrap();
    env.at(5_000).await;
    env.ping(&agent).await;
    env.at(10_000).await;
    eventually("the record once writes succeed", || {
        record_named(&vault, "claude-code").filter(|(_, r)| r.last_request_at == T0 + 5_000)
    })
    .await;
}

// ---------- per-vault state ----------

#[tokio::test(start_paused = true)]
async fn each_served_vault_keeps_its_own_presence_records() {
    let env = Env::new();
    make_vault(&env.root, "other");
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    let (status, body) = env.post_to("other", &agent, &ping_msg()).await;
    assert_rpc_ok(status, &body);
    let other = env.vault("other");
    eventually("the record in the vault it was sent to", || {
        only_record(&other)
    })
    .await;
    assert!(
        records(&env.work()).is_empty(),
        "nothing in a vault the client never called"
    );
    env.ping(&agent).await;
    only_record_at(&env.work(), 0).await;
    assert_eq!(records(&other).len(), 1);
}

// ---------- contracts the handoff left unpinned ----------

#[tokio::test(start_paused = true)]
async fn a_26_char_session_header_past_the_ulid_range_is_ignored() {
    // 26 Crockford chars, but above 2^128: the `ulid` crate decodes it to
    // another id, so it must not name a file.
    let over_range = "8ZZZZZZZZZZZZZZZZZZZZZZZZZ";
    let env = Env::new();
    let plain = Agent::plain(Some("probe/1.0"), [10, 0, 0, 7]);
    env.ping(&plain).await;
    let (plain_id, _) = only_record_at(&env.work(), 0).await;
    env.at(6_000).await;
    env.ping(&plain.clone().header(SESSION_HEADER, over_range))
        .await;
    let (id, rec) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(id, plain_id, "keyed as the plain HTTP client");
    assert_eq!(rec.transport, Transport::Http);
    assert_eq!(
        presence_file_names(&env.work()),
        vec![format!("{plain_id}.json")]
    );
}

#[tokio::test(start_paused = true)]
async fn the_agent_client_header_is_trimmed_and_an_empty_part_is_handled() {
    // (header, client_name, client_version); the User-Agent is `ua/7.7`.
    let cases: [(&str, &str, Option<&str>); 4] = [
        ("  claude-ai/0.9.1  ", "claude-ai", Some("0.9.1")),
        // An empty version is no version.
        ("claude-ai/", "claude-ai", None),
        // An empty name is unusable: the User-Agent names the client.
        ("/1.0", "ua", Some("7.7")),
        ("   ", "ua", Some("7.7")),
    ];
    for (header, name, version) in cases {
        let env = Env::new();
        let session = ulid::Ulid::new().to_string();
        env.ping(&Agent::bridge(&session, header).header("user-agent", "ua/7.7"))
            .await;
        let (stem, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(stem, session, "{header:?}");
        assert_eq!(rec.client_name, name, "{header:?}");
        assert_eq!(rec.client_version.as_deref(), version, "{header:?}");
    }
}

#[tokio::test(start_paused = true)]
async fn a_user_agent_with_an_empty_name_or_version_is_handled() {
    // (user agent, client_name, client_version)
    let cases: [(&str, &str, Option<&str>); 4] = [
        ("/1.0", "http client", None),
        ("solo", "solo", None),
        ("trailing/", "trailing", None),
        ("   ", "http client", None),
    ];
    for (ua, name, version) in cases {
        let env = Env::new();
        env.ping(&Agent::plain(Some(ua), [10, 0, 0, 7])).await;
        let (_, rec) = only_record_at(&env.work(), 0).await;
        assert_eq!(rec.client_name, name, "{ua:?}");
        assert_eq!(rec.client_version.as_deref(), version, "{ua:?}");
    }
}

#[tokio::test(start_paused = true)]
async fn user_agents_that_are_not_utf8_are_named_http_client_but_keep_their_own_record() {
    let env = Env::new();
    let one = Agent::plain(None, [10, 0, 0, 7]).header_bytes("user-agent", b"\xff\xfeone/1.0");
    let two = Agent::plain(None, [10, 0, 0, 7]).header_bytes("user-agent", b"\xff\xfetwo/1.0");
    env.ping(&one).await;
    env.ping(&two).await;
    let vault = env.work();
    let all = eventually("two records", || {
        let all = records(&vault);
        (all.len() == 2).then_some(all)
    })
    .await;
    for (_, rec) in &all {
        assert_eq!(rec.client_name, "http client");
        assert_eq!(rec.client_version, None);
    }
    env.at(6_000).await;
    env.ping(&one).await;
    eventually("the first client's record is reused", || {
        let all = records(&vault);
        let newest = all.iter().filter(|(_, r)| r.last_request_at == T0 + 6_000);
        (all.len() == 2 && newest.count() == 1).then_some(())
    })
    .await;
}

#[tokio::test(start_paused = true)]
async fn a_v4_mapped_v6_peer_address_is_the_same_client_as_its_v4_address() {
    let env = Env::new();
    let ua = "claude-code/1.2.3 (darwin)";
    env.ping(&Agent::plain(Some(ua), [127, 0, 0, 1])).await;
    let (first_id, _) = only_record_at(&env.work(), 0).await;

    env.at(6_000).await;
    let mut mapped = Agent::plain(Some(ua), [127, 0, 0, 1]);
    mapped.peer = Some(SocketAddr::new("::ffff:127.0.0.1".parse().unwrap(), 50_000));
    env.ping(&mapped).await;
    let (id, _) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(id, first_id, "::ffff:127.0.0.1 is 127.0.0.1");

    env.at(12_000).await;
    let mut other = Agent::plain(Some(ua), [127, 0, 0, 1]);
    other.peer = Some(SocketAddr::new("::1".parse().unwrap(), 50_000));
    env.ping(&other).await;
    let vault = env.work();
    eventually("a second record for a different v6 address", || {
        (records(&vault).len() == 2).then_some(())
    })
    .await;
}

#[tokio::test(start_paused = true)]
async fn a_bridge_follows_the_newest_headers_and_keeps_its_first_started_at() {
    let env = Env::new();
    let session = ulid::Ulid::new().to_string();
    env.ping(&Agent::bridge(&session, "claude-ai/0.9.1")).await;
    only_record_at(&env.work(), 0).await;

    env.at(6_000).await;
    env.ping(&Agent::bridge(&session, "claude-desktop/1.0.0"))
        .await;
    let (stem, rec) = only_record_at(&env.work(), 6_000).await;
    assert_eq!(stem, session);
    assert_eq!(rec.client_name, "claude-desktop");
    assert_eq!(rec.client_version.as_deref(), Some("1.0.0"));
    assert_eq!(rec.started_at, T0, "started_at stays at first sight");
    assert_eq!(rec.last_seen_at, T0 + 6_000);
    assert_eq!(rec.expires_at, T0 + 6_000 + 15_000);
}

#[tokio::test(start_paused = true)]
async fn a_failed_write_counts_as_a_write_for_the_throttle() {
    let env = Env::new();
    let vault = env.work();
    let blocker = presence_dir(&vault);
    fs::create_dir_all(blocker.parent().unwrap()).unwrap();
    fs::write(&blocker, b"not a directory").unwrap();
    let agent = Agent::plain(Some("claude-code/1.2.3 (darwin)"), [10, 0, 0, 7]);
    env.ping(&agent).await;
    settle().await;
    fs::remove_file(&blocker).unwrap();

    // The failed write at T0 was an attempt: this request is inside its
    // window, so it waits for the trailing write.
    env.at(1_000).await;
    env.ping(&agent).await;
    settle().await;
    assert!(records(&vault).is_empty(), "no retry inside the window");
    env.at(5_000).await;
    only_record_at(&vault, 1_000).await;
}

#[tokio::test(start_paused = true)]
async fn the_first_hourly_sweep_is_an_hour_after_the_server_starts() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    make_vault(&root, "alpha");
    let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let shared: SharedClock = clock.clone();
    let registry = Arc::new(Registry::new(root.clone(), None));
    registry.get("alpha").await.expect("serve alpha");
    let alpha = root.join("alpha");
    let expired = ulid::Ulid::new().to_string();
    write_left(&alpha, &expired, T0 - 1);

    let sweeps = spawn_presence_sweeps(registry.clone(), shared, HOUR);
    settle().await;
    assert!(
        has_record(&alpha, &expired),
        "spawning the sweep does not sweep at once"
    );
    tokio::time::advance(HOUR - Duration::from_millis(1)).await;
    settle().await;
    assert!(has_record(&alpha, &expired), "no sweep before the hour");
    tokio::time::advance(Duration::from_millis(1)).await;
    eventually("the sweep at the hour", || {
        (!has_record(&alpha, &expired)).then_some(())
    })
    .await;
    sweeps.abort();
}

// ---------- AC 10: the hourly sweep is started by `memex serve` ----------

#[test]
fn the_server_sweeps_presence_every_hour() {
    assert_eq!(
        memex_mcp::server::presence::SWEEP_EVERY,
        HOUR,
        "the hourly sweep"
    );
}

/// The real server entry point (`server::run`, what `memex serve --root`
/// calls) starts the hourly sweep: a vault holding an expired record loses
/// it an hour after the server starts, and not a millisecond sooner. Nothing
/// opens the vault, so the first-serve sweep cannot be what deletes it.
#[tokio::test(start_paused = true)]
async fn memex_serve_starts_the_hourly_presence_sweep() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    fs::create_dir(&root).unwrap();
    make_vault(&root, "work");
    let work = root.join("work");
    // `run` reads the real clock: a record that expired a minute ago.
    let real_now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let expired = ulid::Ulid::new().to_string();
    write_left(&work, &expired, real_now - MINUTE_MS);

    let server = tokio::spawn(memex_mcp::server::run(memex_mcp::server::RunOptions {
        root: root.clone(),
        listen: "127.0.0.1:0".to_string(),
        with_embeddings: false,
        log_level: "info".to_string(),
        backup: None,
    }));
    // `run` reaches `axum::serve` without a real wait: let it get there.
    settle().await;
    assert!(!server.is_finished(), "the server is running");
    assert!(
        has_record(&work, &expired),
        "starting the server does not sweep at once"
    );

    tokio::time::advance(HOUR - Duration::from_millis(1)).await;
    settle().await;
    assert!(has_record(&work, &expired), "no sweep before the hour");

    tokio::time::advance(Duration::from_millis(1)).await;
    eventually("the sweep an hour after the server started", || {
        (!has_record(&work, &expired)).then_some(())
    })
    .await;
    server.abort();
}
