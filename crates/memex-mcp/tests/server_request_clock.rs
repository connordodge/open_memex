//! WI #93 (R3b): the request clock wiring for the app API and MCP (D6, D7,
//! req 59).
//!
//! - The `X-Memex-UTC-Offset` middleware (`request_clock::caller_utc_offset`)
//!   parses the header once per request: a valid value becomes a
//!   `CallerUtcOffset` in the request extensions, a malformed one is 400
//!   `invalid_utc_offset` before any handler runs, and no header keeps the
//!   server's local dates.
//! - `RequestClock` honours that offset (`utc_offset_at` is the caller's),
//!   over the server's base clock (`ServerConfig::with_clock`).
//! - Over `/mcp`, `create_note`, `append_to_daily_note`, `mark_day_reviewed`,
//!   `create_smart_folder` and `update_smart_folder` read the request clock;
//!   stdio `serve --vault` and direct method calls keep `SystemClock`.
//!
//! Most tests run the whole vault server (`server::router()`) in-process on
//! `127.0.0.1:0` with a base clock the test sets ([`ClockServer`]). App-API
//! handlers that take a `RequestClock` are checked on a probe router built
//! from the same middleware and base-clock extension ([`Probe`]), because no
//! app-API route that maps a date has landed yet.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio as ProcStdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::FromRequestParts;
use axum::middleware::from_fn;
use axum::routing::get;
use axum::{Extension, Json, Router};
use memex_core::daily::today_with_clock;
use memex_core::{CallerClock, Clock, FixedOffset, SystemClock, Vault};
use memex_mcp::server::request_clock::{
    caller_utc_offset, BaseClock, CallerUtcOffset, RequestClock, SharedClock,
};
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use server::{client, make_vault, raw_request, Reply, BODY_LIMIT, TEST_TOKEN, TOKEN_ENV};

/// The request header (req 59).
const HEADER: &str = "X-Memex-UTC-Offset";

/// What an MCP streamable-HTTP client must accept on a POST.
const ACCEPT: &str = "application/json, text/event-stream";

/// The number of tools `Memex::new` composes.
const TOOL_COUNT: usize = 26;

/// 2026-03-01T10:30:00Z (AC 1).
const BASE_MS: i64 = 1_772_361_000_000;

/// 2026-03-02T00:15:00Z (AC 1, `-00:30`).
const BASE_EARLY_MS: i64 = 1_772_410_500_000;

/// One hour.
const HOUR_MS: i64 = 3_600_000;

/// The malformed headers AC 2 names.
const AC2_MALFORMED: [&str; 5] = ["+15:00", "+5:00", "+05:60", "abc", ""];

// ---------------------------------------------------------------------------
// Clocks and expected dates
// ---------------------------------------------------------------------------

/// A base clock the test moves between requests (read on every call).
struct SetClock(AtomicI64);

impl SetClock {
    fn at(ms: i64) -> Arc<Self> {
        Arc::new(Self(AtomicI64::new(ms)))
    }

    fn set(&self, ms: i64) {
        self.0.store(ms, Ordering::SeqCst);
    }
}

impl Clock for SetClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// A clock frozen at one instant.
struct Fixed(i64);

impl Clock for Fixed {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

fn offset(minutes: i32) -> FixedOffset {
    FixedOffset::east_opt(minutes * 60).unwrap_or_else(|| panic!("bad offset {minutes} min"))
}

/// The date at `ms` in a caller's offset of `minutes`.
fn caller_date(minutes: i32, ms: i64) -> String {
    today_with_clock(&CallerClock {
        offset: offset(minutes),
        base: Fixed(ms),
    })
    .to_string()
}

/// The server's local date at `ms`.
fn local_date(ms: i64) -> String {
    today_with_clock(&Fixed(ms)).to_string()
}

/// Today in a caller's offset of `minutes`, read from the system clock now.
fn caller_today(minutes: i32) -> String {
    today_with_clock(&CallerClock {
        offset: offset(minutes),
        base: SystemClock,
    })
    .to_string()
}

/// Today in the machine's local time, now.
fn local_today() -> String {
    today_with_clock(&SystemClock).to_string()
}

/// Asserts `got` is `before` or `after` (a midnight may fall in between).
fn assert_between(got: &str, before: &str, after: &str, what: &str) {
    assert!(
        got == before || got == after,
        "{what}: got {got}, want {before} (or {after} across midnight)"
    );
}

// ---------------------------------------------------------------------------
// The in-process vault server, with a base clock
// ---------------------------------------------------------------------------

/// `server::router()` on `127.0.0.1:0` over a temp vault root, accepting
/// [`TEST_TOKEN`], with `clock` as its base clock (or the default
/// `SystemClock` when `None`).
struct ClockServer {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl ClockServer {
    async fn start(clock: Option<SharedClock>) -> Self {
        let root = tempfile::tempdir().expect("temp vault root");
        let mut config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN);
        if let Some(clock) = clock {
            config = config.with_clock(clock);
        }
        let (addr, task) = serve(router(config)).await;
        Self { root, addr, task }
    }

    async fn fixed(ms: i64) -> Self {
        Self::start(Some(Arc::new(Fixed(ms)))).await
    }

    fn root(&self) -> &Path {
        self.root.path()
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    /// A new vault folder `<root>/<name>`; returns its path.
    fn vault(&self, name: &str) -> PathBuf {
        make_vault(self.root(), name);
        self.root().join(name)
    }
}

impl Drop for ClockServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn serve(app: Router) -> (SocketAddr, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local addr");
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve");
    });
    (addr, task)
}

fn bearer() -> String {
    format!("Bearer {TEST_TOKEN}")
}

/// The headers of a request with an optional offset header.
fn with_offset(header: Option<&str>) -> Vec<(&'static str, String)> {
    header
        .map(|h| vec![(HEADER, h.to_string())])
        .unwrap_or_default()
}

/// GET `url` with `headers` and an optional `Authorization` value.
async fn get_with(
    url: &str,
    authorization: Option<&str>,
    headers: &[(&'static str, String)],
) -> Reply {
    let mut req = client().get(url);
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    for (k, v) in headers {
        req = req.header(*k, v.as_str());
    }
    Reply::read(req.send().await.expect("send GET")).await
}

// ---------------------------------------------------------------------------
// MCP over HTTP
// ---------------------------------------------------------------------------

fn mcp_path(vault: &str) -> String {
    format!("/vaults/{vault}/mcp")
}

fn request(id: i64, method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

fn tool_call(tool: &str, arguments: Value) -> Value {
    request(
        1,
        "tools/call",
        json!({ "name": tool, "arguments": arguments }),
    )
}

/// POSTs one JSON-RPC message as an MCP client would (no `initialize`).
async fn rpc_with(
    url: &str,
    msg: &Value,
    authorization: Option<&str>,
    headers: &[(&'static str, String)],
) -> Reply {
    let mut req = client()
        .post(url)
        .header("content-type", "application/json")
        .header("accept", ACCEPT)
        .body(msg.to_string());
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    for (k, v) in headers {
        req = req.header(*k, v.as_str());
    }
    Reply::read(req.send().await.expect("send MCP POST")).await
}

/// The JSON-RPC `result` of a 200 reply; panics with the reply otherwise.
fn rpc_result(r: &Reply) -> Value {
    assert_eq!(r.status, 200, "MCP POST: {:?}", short(&r.body));
    let v = r.json();
    assert!(v.get("error").is_none(), "a JSON-RPC result: {v}");
    v["result"].clone()
}

/// A tool's JSON payload (one text content holding JSON).
fn tool_payload(result: &Value) -> Value {
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("a text content: {result}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("tool text is not JSON ({e}): {text}"))
}

/// Calls `tool` over `/vaults/<vault>/mcp` with the token and an optional
/// offset header; returns its payload.
async fn call(
    srv: &ClockServer,
    vault: &str,
    header: Option<&str>,
    tool: &str,
    args: Value,
) -> Value {
    let r = rpc_with(
        &srv.url(&mcp_path(vault)),
        &tool_call(tool, args),
        Some(&bearer()),
        &with_offset(header),
    )
    .await;
    tool_payload(&rpc_result(&r))
}

/// Like [`call`], asserting the payload is not an error.
async fn call_ok(
    srv: &ClockServer,
    vault: &str,
    header: Option<&str>,
    tool: &str,
    args: Value,
) -> Value {
    let v = call(srv, vault, header, tool, args).await;
    assert!(v.get("error").is_none(), "{tool} ({header:?}) failed: {v}");
    v
}

/// `create_note` with role daily and no title over `/mcp`; returns the new
/// note's title as stored on disk.
async fn daily_title_over_mcp(srv: &ClockServer, vault: &str, header: Option<&str>) -> String {
    let v = call_ok(
        srv,
        vault,
        header,
        "create_note",
        json!({ "content_md": "", "role": "daily" }),
    )
    .await;
    let id = v["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note returns a note_id: {v}"));
    note_row(&srv.root().join(vault), id).0
}

/// `append_to_daily_note` without `date` over `/mcp`; returns the outcome.
async fn append_over_mcp(
    srv: &ClockServer,
    vault: &str,
    header: Option<&str>,
    text: &str,
) -> Value {
    call_ok(
        srv,
        vault,
        header,
        "append_to_daily_note",
        json!({ "text": text }),
    )
    .await
}

fn short(s: &str) -> &str {
    &s[..s.len().min(300)]
}

// ---------------------------------------------------------------------------
// Reading the vault from disk
// ---------------------------------------------------------------------------

fn open_db(vault: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open_with_flags(
        vault.join("memex.db"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open memex.db read-only")
}

/// `(title, content_md)` of note `id`.
fn note_row(vault: &Path, id: &str) -> (String, String) {
    open_db(vault)
        .query_row(
            "SELECT title, content_md FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or_else(|e| panic!("note {id}: {e}"))
}

fn note_count(vault: &Path) -> i64 {
    open_db(vault)
        .query_row("SELECT count(*) FROM notes", [], |r| r.get(0))
        .expect("count notes")
}

// ---------------------------------------------------------------------------
// The probe: what an app-API handler extracts
// ---------------------------------------------------------------------------

/// A router with one route, `GET /probe`, whose handler takes a
/// `RequestClock` as an app-API handler does, under the offset middleware
/// and the base-clock extension `router()` adds.
struct Probe {
    addr: SocketAddr,
    task: JoinHandle<()>,
}

/// What the probe's handler saw.
#[derive(Debug, PartialEq, Eq)]
struct Seen {
    today: String,
    now_ms: i64,
    utc_offset_secs: i32,
    caller_offset: Option<i32>,
}

async fn probe_handler(clock: RequestClock) -> Json<Value> {
    let now = clock.now_ms();
    Json(json!({
        "today": today_with_clock(&clock).to_string(),
        "now_ms": now,
        "utc_offset_secs": clock.utc_offset_at(now).local_minus_utc(),
        "caller_offset": clock.caller_offset().map(|CallerUtcOffset(m)| m),
    }))
}

impl Probe {
    async fn start(base: SharedClock) -> Self {
        let app = Router::new()
            .route("/probe", get(probe_handler))
            .layer(from_fn(caller_utc_offset))
            .layer(Extension(BaseClock(base)));
        let (addr, task) = serve(app).await;
        Self { addr, task }
    }

    async fn send(&self, header: Option<&str>) -> Reply {
        get_with(
            &format!("http://{}/probe", self.addr),
            None,
            &with_offset(header),
        )
        .await
    }

    async fn seen(&self, header: Option<&str>) -> Seen {
        let r = self.send(header).await;
        assert_eq!(r.status, 200, "probe with {header:?}: {:?}", short(&r.body));
        let v = r.json();
        Seen {
            today: v["today"].as_str().expect("today").to_string(),
            now_ms: v["now_ms"].as_i64().expect("now_ms"),
            utc_offset_secs: i32::try_from(v["utc_offset_secs"].as_i64().expect("offset"))
                .expect("offset fits i32"),
            caller_offset: v["caller_offset"]
                .as_i64()
                .map(|m| i32::try_from(m).expect("minutes fit i32")),
        }
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The local UTC offset, in seconds, the default `Clock::utc_offset_at`
/// gives at `ms`.
fn local_offset_secs(ms: i64) -> i32 {
    Fixed(ms).utc_offset_at(ms).local_minus_utc()
}

// ---------------------------------------------------------------------------
// AC 1: fixed base clock, end to end
// ---------------------------------------------------------------------------

#[tokio::test]
async fn fixed_base_clock_mcp_create_note_daily_title_follows_the_caller_offset() {
    let srv = ClockServer::fixed(BASE_MS).await;
    for (vault, header, want) in [
        ("plus14", Some("+14:00"), "2026-03-02".to_string()),
        ("minus12", Some("-12:00"), "2026-02-28".to_string()),
        ("none", None, local_date(BASE_MS)),
    ] {
        srv.vault(vault);
        assert_eq!(
            daily_title_over_mcp(&srv, vault, header).await,
            want,
            "base 2026-03-01T10:30:00Z, header {header:?}"
        );
    }

    let early = ClockServer::fixed(BASE_EARLY_MS).await;
    early.vault("work");
    assert_eq!(
        daily_title_over_mcp(&early, "work", Some("-00:30")).await,
        "2026-03-01",
        "base 2026-03-02T00:15:00Z with -00:30 is still March 1"
    );
}

#[tokio::test]
async fn fixed_base_clock_request_clock_an_api_handler_extracts_gives_the_same_dates() {
    let config =
        ServerConfig::new("/tmp/wi93-unused-root", TEST_TOKEN).with_clock(Arc::new(Fixed(BASE_MS)));
    let probe = Probe::start(config.clock()).await;
    for (header, minutes, want) in [
        ("+14:00", 840, "2026-03-02"),
        ("-12:00", -720, "2026-02-28"),
    ] {
        let seen = probe.seen(Some(header)).await;
        assert_eq!(
            seen,
            Seen {
                today: want.to_string(),
                now_ms: BASE_MS,
                utc_offset_secs: minutes * 60,
                caller_offset: Some(minutes),
            },
            "{header}"
        );
    }
    assert_eq!(
        probe.seen(None).await,
        Seen {
            today: local_date(BASE_MS),
            now_ms: BASE_MS,
            utc_offset_secs: local_offset_secs(BASE_MS),
            caller_offset: None,
        },
        "no header: the server's local date and offset"
    );

    let early = Probe::start(Arc::new(Fixed(BASE_EARLY_MS))).await;
    let seen = early.seen(Some("-00:30")).await;
    assert_eq!(seen.today, "2026-03-01");
    assert_eq!(
        seen.utc_offset_secs, -1800,
        "-00:30 is minus thirty minutes"
    );
    assert_eq!(
        seen.now_ms, BASE_EARLY_MS,
        "the offset never moves the instant"
    );
}

#[tokio::test]
async fn request_clock_with_an_inserted_caller_offset_reports_that_offset_and_date() {
    let base: SharedClock = Arc::new(Fixed(BASE_MS));
    for (minutes, want) in [(840, "2026-03-02"), (-720, "2026-02-28"), (0, "2026-03-01")] {
        let (mut parts, ()) = axum::http::Request::builder()
            .uri("/vaults/work/api/v1/info")
            .extension(BaseClock(base.clone()))
            .extension(CallerUtcOffset(minutes))
            .body(())
            .unwrap()
            .into_parts();
        let Ok(clock) = RequestClock::from_request_parts(&mut parts, &()).await;
        assert_eq!(
            clock.utc_offset_at(BASE_MS),
            offset(minutes),
            "{minutes} min: utc_offset_at is the caller's offset"
        );
        assert_eq!(
            clock.utc_offset_at(BASE_MS - 180 * 24 * HOUR_MS),
            offset(minutes),
            "{minutes} min: the same offset at any instant (no DST of the server's)"
        );
        assert_eq!(today_with_clock(&clock).to_string(), want, "{minutes} min");
        assert_eq!(clock.now_ms(), BASE_MS, "the base clock's instant");
    }

    // No offset: the server's local offset, as SystemClock reports it.
    let (mut parts, ()) = axum::http::Request::builder()
        .uri("/vaults/work/api/v1/info")
        .extension(BaseClock(base))
        .body(())
        .unwrap()
        .into_parts();
    let Ok(clock) = RequestClock::from_request_parts(&mut parts, &()).await;
    assert_eq!(
        clock.utc_offset_at(BASE_MS).local_minus_utc(),
        local_offset_secs(BASE_MS)
    );
    assert_eq!(today_with_clock(&clock).to_string(), local_date(BASE_MS));
}

// ---------------------------------------------------------------------------
// AC 2: a malformed header is 400 invalid_utc_offset, and no handler runs
// ---------------------------------------------------------------------------

/// Asserts `r` is the C1 400 `invalid_utc_offset`.
fn assert_invalid_offset(r: &Reply, what: &str) {
    assert_eq!(r.status, 400, "{what}: {:?}", short(&r.body));
    assert_eq!(r.c1_code(), "invalid_utc_offset", "{what}");
}

#[tokio::test]
async fn malformed_offset_header_is_400_invalid_utc_offset_on_vault_info_and_mcp() {
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");
    for bad in AC2_MALFORMED {
        let headers = with_offset(Some(bad));
        let r = get_with(
            &srv.url("/vaults/work/api/v1/info"),
            Some(&bearer()),
            &headers,
        )
        .await;
        assert_invalid_offset(&r, &format!("GET vault info with {bad:?}"));

        let r = rpc_with(
            &srv.url(&mcp_path("work")),
            &tool_call("create_note", json!({ "content_md": "", "role": "daily" })),
            Some(&bearer()),
            &headers,
        )
        .await;
        assert_invalid_offset(&r, &format!("POST /mcp create_note with {bad:?}"));
    }
    assert_eq!(
        note_count(&dir),
        0,
        "create_note never ran: a malformed header creates nothing"
    );

    // The same requests with a valid header are served.
    let r = get_with(
        &srv.url("/vaults/work/api/v1/info"),
        Some(&bearer()),
        &with_offset(Some("+05:30")),
    )
    .await;
    assert_eq!(r.status, 200, "valid header: {:?}", short(&r.body));
    daily_title_over_mcp(&srv, "work", Some("+05:30")).await;
    assert_eq!(note_count(&dir), 1);
}

#[tokio::test]
async fn malformed_offset_header_on_mcp_append_and_folder_writes_writes_nothing() {
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");
    for (tool, args) in [
        ("append_to_daily_note", json!({ "text": "Never written." })),
        ("create_smart_folder", json!({ "name": "Never made" })),
        (
            "create_note",
            json!({ "title": "Never made", "content_md": "No." }),
        ),
    ] {
        let r = rpc_with(
            &srv.url(&mcp_path("work")),
            &tool_call(tool, args),
            Some(&bearer()),
            &with_offset(Some("+15:00")),
        )
        .await;
        assert_invalid_offset(&r, tool);
    }
    assert_eq!(note_count(&dir), 0, "no note written");
    let folders: i64 = open_db(&dir)
        .query_row("SELECT count(*) FROM smart_folders", [], |r| r.get(0))
        .expect("count folders");
    assert_eq!(folders, 0, "no folder written");
}

#[tokio::test]
async fn utc_offsets_fixture_invalid_rows_are_400_on_every_route_class() {
    let cases = api_fixtures::load_utc_offsets();
    assert!(!cases.invalid.is_empty(), "the fixture has invalid rows");
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");
    for bad in &cases.invalid {
        let headers = with_offset(Some(bad));
        for path in ["/api/v1/info", "/api/v1/vaults", "/vaults/work/api/v1/info"] {
            let r = get_with(&srv.url(path), Some(&bearer()), &headers).await;
            assert_invalid_offset(&r, &format!("GET {path} with {bad:?}"));
        }
        let r = rpc_with(
            &srv.url(&mcp_path("work")),
            &request(1, "tools/list", json!({})),
            Some(&bearer()),
            &headers,
        )
        .await;
        assert_invalid_offset(&r, &format!("POST /mcp tools/list with {bad:?}"));
    }
    assert_eq!(note_count(&dir), 0);
}

#[tokio::test]
async fn utc_offsets_fixture_rows_through_the_middleware_reach_the_request_clock() {
    let cases = api_fixtures::load_utc_offsets();
    assert!(cases.valid.len() >= 4, "the fixture has valid rows");
    let probe = Probe::start(Arc::new(Fixed(BASE_MS))).await;
    for (header, minutes) in &cases.valid {
        let seen = probe.seen(Some(header)).await;
        assert_eq!(
            seen,
            Seen {
                today: caller_date(*minutes, BASE_MS),
                now_ms: BASE_MS,
                utc_offset_secs: minutes * 60,
                caller_offset: Some(*minutes),
            },
            "valid row {header:?}"
        );
    }
    for bad in &cases.invalid {
        assert_invalid_offset(&probe.send(Some(bad)).await, &format!("probe {bad:?}"));
    }
    for bad in AC2_MALFORMED {
        assert_invalid_offset(&probe.send(Some(bad)).await, &format!("probe {bad:?}"));
    }
}

#[tokio::test]
async fn utc_offsets_fixture_valid_rows_set_the_mcp_daily_title_end_to_end() {
    let cases = api_fixtures::load_utc_offsets();
    // 2026-03-01T23:50Z: east of +00:10 it is already March 2.
    let late = BASE_MS + 13 * HOUR_MS + 20 * 60_000;
    let srv = ClockServer::fixed(late).await;
    let mut dates = BTreeSet::new();
    for (i, (header, minutes)) in cases.valid.iter().enumerate() {
        let vault = format!("v{i}");
        srv.vault(&vault);
        let want = caller_date(*minutes, late);
        assert_eq!(
            daily_title_over_mcp(&srv, &vault, Some(header)).await,
            want,
            "valid row {header:?}"
        );
        dates.insert(want);
    }
    assert!(
        dates.len() >= 2,
        "the rows straddle a day boundary at this instant: {dates:?}"
    );
}

#[tokio::test]
async fn non_ascii_offset_header_is_400_not_treated_as_absent() {
    let srv = ClockServer::fixed(BASE_MS).await;
    srv.vault("work");
    // Arabic-Indic digits: not ASCII, so not the grammar's \d.
    for bad in ["+\u{0660}\u{0665}:\u{0663}\u{0660}", "+05:30\u{00a0}"] {
        let head = format!(
            "GET /vaults/work/api/v1/info HTTP/1.1\r\nHost: localhost\r\n\
             Authorization: Bearer {TEST_TOKEN}\r\n{HEADER}: {bad}\r\nConnection: close\r\n"
        );
        let r = raw_request(srv.addr, &head, b"").await;
        assert_invalid_offset(&r, &format!("{bad:?}"));
    }
}

// ---------------------------------------------------------------------------
// AC 3: layer order (auth, then the body limit, then the request clock)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn tokenless_request_with_a_malformed_offset_is_401_unauthorized() {
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");
    let headers = with_offset(Some("+15:00"));
    for path in ["/api/v1/info", "/vaults/work/api/v1/info"] {
        let r = get_with(&srv.url(path), None, &headers).await;
        assert_eq!(r.status, 401, "GET {path}: {:?}", short(&r.body));
        assert_eq!(r.c1_code(), "unauthorized", "GET {path}");
    }
    let r = rpc_with(
        &srv.url(&mcp_path("work")),
        &tool_call("create_note", json!({ "content_md": "", "role": "daily" })),
        None,
        &headers,
    )
    .await;
    assert_eq!(r.status, 401, "POST /mcp: {:?}", short(&r.body));
    assert_eq!(r.c1_code(), "unauthorized");
    assert_eq!(note_count(&dir), 0);
}

#[tokio::test]
async fn oversized_body_with_a_malformed_offset_is_413_payload_too_large() {
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");
    let head = |len: usize| {
        format!(
            "POST /vaults/work/mcp HTTP/1.1\r\nHost: localhost\r\n\
             Authorization: Bearer {TEST_TOKEN}\r\nContent-Type: application/json\r\n\
             Accept: {ACCEPT}\r\n{HEADER}: +15:00\r\nContent-Length: {len}\r\n\
             Connection: close\r\n"
        )
    };
    let big = tool_call(
        "create_note",
        json!({ "title": "Too big", "content_md": "x".repeat(BODY_LIMIT + 1024) }),
    )
    .to_string();
    let r = raw_request(srv.addr, &head(big.len()), big.as_bytes()).await;
    assert_eq!(r.status, 413, "over 8 MiB: {:?}", short(&r.body));
    assert_eq!(r.c1_code(), "payload_too_large");

    // The same malformed header on a body that fits is the offset's 400.
    let small = tool_call(
        "create_note",
        json!({ "title": "Small", "content_md": "x" }),
    )
    .to_string();
    let r = raw_request(srv.addr, &head(small.len()), small.as_bytes()).await;
    assert_invalid_offset(&r, "a body under the limit");
    assert_eq!(note_count(&dir), 0);
}

// ---------------------------------------------------------------------------
// AC 4: the caller's date at request time, +14:00 and -12:00
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_create_note_daily_is_the_caller_date_at_request_time_for_plus_14_and_minus_12() {
    let srv = ClockServer::start(None).await;
    srv.vault("work");

    let before = caller_today(840);
    let east = daily_title_over_mcp(&srv, "work", Some("+14:00")).await;
    let after = caller_today(840);
    assert_between(&east, &before, &after, "+14:00");

    let before = caller_today(-720);
    let west = daily_title_over_mcp(&srv, "work", Some("-12:00")).await;
    let after = caller_today(-720);
    assert_between(&west, &before, &after, "-12:00");

    assert_ne!(east, west, "UTC+14 and UTC-12 are never on the same date");
}

// ---------------------------------------------------------------------------
// AC 5: append_to_daily_note follows the caller's date
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_append_to_daily_note_without_date_appends_to_the_caller_daily_note() {
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");
    for (header, want, text) in [
        ("+14:00", "2026-03-02", "Called from Kiritimati."),
        ("-12:00", "2026-02-28", "Called from Baker Island."),
    ] {
        let v = append_over_mcp(&srv, "work", Some(header), text).await;
        assert_eq!(v["date"], want, "{header}: the outcome's date");
        let id = v["note_id"].as_str().expect("note_id");
        let (title, content) = note_row(&dir, id);
        assert_eq!(title, want, "{header}: appended to that day's daily note");
        assert!(
            content.contains(text),
            "{header}: the text is there: {content:?}"
        );
    }
}

#[tokio::test]
async fn mcp_append_to_daily_note_without_date_with_plus_14_at_request_time() {
    let srv = ClockServer::start(None).await;
    srv.vault("work");
    let before = caller_today(840);
    let v = append_over_mcp(&srv, "work", Some("+14:00"), "Ahead of everyone.").await;
    let after = caller_today(840);
    let date = v["date"].as_str().expect("date");
    assert_between(date, &before, &after, "+14:00 append");
}

// ---------------------------------------------------------------------------
// AC 6: no header over /mcp is the server's local date
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_create_note_daily_without_header_is_the_server_local_date_of_the_base_clock() {
    let srv = ClockServer::fixed(BASE_MS).await;
    srv.vault("work");
    assert_eq!(
        daily_title_over_mcp(&srv, "work", None).await,
        local_date(BASE_MS),
        "the base clock's instant in the server's local time"
    );
    let v = append_over_mcp(&srv, "work", None, "No header.").await;
    assert_eq!(v["date"].as_str(), Some(local_date(BASE_MS).as_str()));
}

#[tokio::test]
async fn mcp_create_note_daily_without_header_on_the_system_clock_is_today_local() {
    let srv = ClockServer::start(None).await;
    srv.vault("work");
    let before = local_today();
    let title = daily_title_over_mcp(&srv, "work", None).await;
    let after = local_today();
    assert_between(&title, &before, &after, "no header");
}

// ---------------------------------------------------------------------------
// Per request: never cached, and a base clock that jumps back
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_offset_is_read_per_request_and_never_kept_for_the_next_request() {
    let srv = ClockServer::fixed(BASE_MS).await;
    srv.vault("work");
    for (header, want) in [
        (Some("+14:00"), "2026-03-02".to_string()),
        (None, local_date(BASE_MS)),
        (Some("-12:00"), "2026-02-28".to_string()),
        (Some("+14:00"), "2026-03-02".to_string()),
        (None, local_date(BASE_MS)),
    ] {
        let v = append_over_mcp(&srv, "work", header, "Again.").await;
        assert_eq!(v["date"].as_str(), Some(want.as_str()), "{header:?}");
    }
}

#[tokio::test]
async fn mcp_caller_date_follows_a_base_clock_that_jumps_back_across_midnight() {
    // 2026-03-01T10:15Z is 00:15 on March 2 at +14:00.
    let t = BASE_MS - 15 * 60_000;
    let clock = SetClock::at(t);
    let srv = ClockServer::start(Some(clock.clone() as SharedClock)).await;
    srv.vault("work");
    assert_eq!(
        daily_title_over_mcp(&srv, "work", Some("+14:00")).await,
        "2026-03-02"
    );

    // NTP or a manual change moves the base clock back an hour: 23:15 on
    // March 1 at +14:00. The date follows; nothing is clamped or cached.
    clock.set(t - HOUR_MS);
    assert_eq!(
        daily_title_over_mcp(&srv, "work", Some("+14:00")).await,
        "2026-03-01"
    );
    let v = append_over_mcp(&srv, "work", Some("+14:00"), "After the jump.").await;
    assert_eq!(v["date"], "2026-03-01");

    clock.set(t);
    let v = append_over_mcp(&srv, "work", Some("+14:00"), "Forward again.").await;
    assert_eq!(v["date"], "2026-03-02");
}

#[tokio::test]
async fn probe_request_clock_reads_the_base_clock_per_request_when_it_jumps_back() {
    let t = BASE_MS - 15 * 60_000;
    let clock = SetClock::at(t);
    let probe = Probe::start(clock.clone()).await;
    let seen = probe.seen(Some("+14:00")).await;
    assert_eq!((seen.today.as_str(), seen.now_ms), ("2026-03-02", t));
    clock.set(t - HOUR_MS);
    let seen = probe.seen(Some("+14:00")).await;
    assert_eq!(
        (seen.today.as_str(), seen.now_ms),
        ("2026-03-01", t - HOUR_MS)
    );
}

// ---------------------------------------------------------------------------
// AC 7: stdio serve --vault keeps local time
// ---------------------------------------------------------------------------

/// A `memex serve --vault` subprocess over newline-delimited JSON-RPC.
struct Stdio {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Stdio {
    fn start(vault: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault.to_str().unwrap()])
            .env_remove(TOKEN_ENV)
            .stdin(ProcStdio::piped())
            .stdout(ProcStdio::piped())
            .stderr(ProcStdio::null())
            .spawn()
            .expect("spawn memex serve --vault");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut stdio = Self {
            child,
            stdin,
            lines,
        };
        let init = stdio.request(
            1,
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi93-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "stdio initialize: {init}");
        stdio.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        stdio
    }

    fn send(&mut self, msg: Value) {
        writeln!(self.stdin, "{msg}").expect("write to stdio server");
        self.stdin.flush().unwrap();
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
        self.send(request(id, method, params));
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|e| panic!("no stdio response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }

    fn call(&mut self, id: i64, tool: &str, args: Value) -> Value {
        let v = self.request(id, "tools/call", json!({ "name": tool, "arguments": args }));
        tool_payload(&v["result"])
    }
}

impl Drop for Stdio {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[tokio::test]
async fn stdio_serve_append_to_daily_note_without_date_uses_the_machine_local_date() {
    let dir = tempfile::tempdir().unwrap();
    make_vault(dir.path(), "work");
    let vault = dir.path().join("work");
    let mut stdio = Stdio::start(&vault);

    let before = local_today();
    let v = stdio.call(2, "append_to_daily_note", json!({ "text": "Over stdio." }));
    let created = stdio.call(3, "create_smart_folder", json!({ "name": "Stdio folder" }));
    let after = local_today();
    drop(stdio);

    let date = v["date"]
        .as_str()
        .unwrap_or_else(|| panic!("append outcome: {v}"));
    assert_between(date, &before, &after, "stdio append");
    let id = v["note_id"].as_str().expect("note_id");
    assert_eq!(note_row(&vault, id).0, date);
    assert!(
        created["created_at"].as_i64().is_some(),
        "stdio create_smart_folder still works: {created}"
    );
}

// ---------------------------------------------------------------------------
// AC 8: direct method calls are unchanged
// ---------------------------------------------------------------------------

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
}

#[tokio::test]
async fn direct_tool_calls_keep_their_signatures_and_use_the_system_clock() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let memex = Memex::new(Arc::new(AppState::new(vault, path.clone(), None)));

    let before_day = local_today();
    let before_ms = SystemClock.now_ms();
    let note = parse(
        &memex
            .create_note(params(json!({ "content_md": "", "role": "daily" })))
            .await,
    );
    let appended = parse(
        &memex
            .append_to_daily_note(params(json!({ "text": "Direct." })))
            .await,
    );
    let folder = parse(
        &memex
            .create_smart_folder(params(json!({ "name": "Direct" })))
            .await,
    );
    let folder_id = folder["id"].as_str().expect("folder id").to_string();
    let updated = parse(
        &memex
            .update_smart_folder(params(json!({ "id": folder_id, "name": "Renamed" })))
            .await,
    );
    let day = appended["date"].as_str().expect("date").to_string();
    let changes = parse(
        &memex
            .get_daily_note_changes(params(json!({ "date": day })))
            .await,
    );
    let daily_id = appended["note_id"].as_str().expect("note_id").to_string();
    let reviewed = parse(
        &memex
            .mark_day_reviewed(params(json!({
                "date": day,
                "version": changes["content_version"],
                "changes": [{ "note_id": daily_id, "bullets": ["Reviewed directly"] }],
            })))
            .await,
    );
    let after_ms = SystemClock.now_ms();
    let after_day = local_today();

    let id = note["note_id"].as_str().unwrap_or_else(|| panic!("{note}"));
    assert_between(
        &note_row(&path, id).0,
        &before_day,
        &after_day,
        "create_note",
    );
    assert_between(&day, &before_day, &after_day, "append_to_daily_note");
    for (what, v) in [
        ("created_at", &folder["created_at"]),
        ("updated_at", &updated["updated_at"]),
        ("reviewed_at", &reviewed["reviewed_at"]),
    ] {
        let ms = v.as_i64().unwrap_or_else(|| panic!("{what}: {v}"));
        assert!(
            (before_ms..=after_ms).contains(&ms),
            "{what} from the system clock: {before_ms} <= {ms} <= {after_ms}"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 9: tool schemas are unchanged
// ---------------------------------------------------------------------------

/// The five rewired tools as `tools/list` showed them before this WI:
/// `(name, description, inputSchema)`.
fn rewired_tools() -> Vec<(&'static str, &'static str, Value)> {
    let schema = |s: &str| -> Value { serde_json::from_str(s).expect("schema literal") };
    vec![
        (
            "append_to_daily_note",
            "Append text to the end of the user's daily note for `date` (YYYY-MM-DD; default today, local time), above its Topics footer, creating the daily note when the day has none. The text is kept verbatim; this is the only way to add to a daily note. Returns note_id, date, block_ids (the new blocks), content_version, version and prior_state: the day's review state just before the append (`Unreviewed`, `Reviewed` or `Changed since review`). Fails with invalid_argument for empty text, invalid_date, and title_conflict (with existing_id) when a non-daily note already has that date as its title.",
            schema(
                r#"{"$schema": "https://json-schema.org/draft/2020-12/schema", "properties": {"date": {"default": null, "description": "The day, YYYY-MM-DD; omit for today (local time).", "type": ["string", "null"]}, "text": {"description": "The text to append, verbatim.", "type": "string"}}, "required": ["text"], "title": "AppendToDailyNoteParams", "type": "object"}"#,
            ),
        ),
        (
            "create_note",
            "Create a new note in the user's vault. Returns the new note_id. Notes you create are tagged 'agent-authored' and 'inbox' by default so the user can review them.",
            schema(
                r#"{"$schema": "https://json-schema.org/draft/2020-12/schema", "properties": {"agent_id": {"default": null, "description": "Identifier for the agent creating this note. Stored in frontmatter.", "type": ["string", "null"]}, "content_md": {"description": "Markdown content of the note.", "type": "string"}, "role": {"default": null, "description": "Optional role, `daily` or `topic`. Stored in frontmatter as `role`;\nany other value is a `role_rule` error.", "type": ["string", "null"]}, "tags": {"default": null, "description": "Optional tags to attach.", "items": {"type": "string"}, "type": ["array", "null"]}, "title": {"default": null, "description": "Optional title. If omitted, derived from the first line of content.", "type": ["string", "null"]}}, "required": ["content_md"], "title": "CreateNoteParams", "type": "object"}"#,
            ),
        ),
        (
            "create_smart_folder",
            "Create a Smart Folder, at the top level or under parent_id. Names are unique among siblings ignoring case, and the tree may not nest deeper than the vault's smart_folder_max_depth. Folders you create are unpinned. Returns the folder.",
            schema(
                r#"{"$schema": "https://json-schema.org/draft/2020-12/schema", "properties": {"name": {"description": "Folder name, unique among its siblings (case-insensitively).", "type": "string"}, "parent_id": {"default": null, "description": "Parent folder id; omit for a top-level folder.", "type": ["string", "null"]}}, "required": ["name"], "title": "CreateSmartFolderParams", "type": "object"}"#,
            ),
        ),
        (
            "mark_day_reviewed",
            "Mark a daily note (date YYYY-MM-DD) reviewed at `version`, the content_version from get_daily_note_changes; if the person edited the day since, this fails with review_stale. `changes` has one entry per note you touched, including the daily note itself: {note_id, bullets} with 1 to 3 bullets, each one line of plain markdown, at most 200 characters, without a leading \"- \". Any invalid entry rejects the whole call (change_entries_invalid) and nothing is recorded.",
            schema(
                r##"{"$defs": {"ChangeEntryParams": {"properties": {"bullets": {"description": "1 to 3 bullets saying what was done.", "items": {"type": "string"}, "type": "array"}, "note_id": {"description": "The id of a note touched in this run.", "type": "string"}}, "required": ["note_id", "bullets"], "type": "object"}}, "$schema": "https://json-schema.org/draft/2020-12/schema", "properties": {"changes": {"description": "One entry per note touched, including the daily note itself.", "items": {"$ref": "#/$defs/ChangeEntryParams"}, "type": "array"}, "date": {"description": "The day, `YYYY-MM-DD`.", "type": "string"}, "version": {"description": "The content version fetched with `get_daily_note_changes`.", "format": "int64", "type": "integer"}}, "required": ["date", "version", "changes"], "title": "MarkDayReviewedParams", "type": "object"}"##,
            ),
        ),
        (
            "update_smart_folder",
            "Rename a Smart Folder, move it under parent_id, or move it to the top level with to_root: true. A folder the user pinned cannot be renamed or moved (pinned_rule). Returns the folder.",
            schema(
                r#"{"$schema": "https://json-schema.org/draft/2020-12/schema", "properties": {"id": {"description": "The folder id.", "type": "string"}, "name": {"default": null, "description": "New name.", "type": ["string", "null"]}, "parent_id": {"default": null, "description": "New parent folder id.", "type": ["string", "null"]}, "to_root": {"default": null, "description": "Move the folder to the top level. Default false.", "type": ["boolean", "null"]}}, "required": ["id"], "title": "UpdateSmartFolderParams", "type": "object"}"#,
            ),
        ),
    ]
}

/// Asserts `listed` (a `tools/list` result's `tools`) has 26 tools and the
/// five rewired ones exactly as before, property by property.
fn assert_rewired_schemas_unchanged(listed: &Value, transport: &str) {
    let tools = listed
        .as_array()
        .unwrap_or_else(|| panic!("{transport}: a tools array: {listed}"));
    assert_eq!(tools.len(), TOOL_COUNT, "{transport}: 26 tools");
    for (name, description, schema) in rewired_tools() {
        let tool = tools
            .iter()
            .find(|t| t["name"] == name)
            .unwrap_or_else(|| panic!("{transport}: {name} is listed by its name"));
        assert_eq!(
            tool["description"], description,
            "{transport} {name}: description"
        );
        let got = &tool["inputSchema"];
        let want_props = schema["properties"].as_object().expect("properties");
        let got_props = got["properties"]
            .as_object()
            .unwrap_or_else(|| panic!("{transport} {name}: properties: {got}"));
        let names = |m: &serde_json::Map<String, Value>| m.keys().cloned().collect::<Vec<_>>();
        assert_eq!(
            names(got_props),
            names(want_props),
            "{transport} {name}: the same properties (no ctx or other added property)"
        );
        assert!(!got_props.contains_key("ctx"), "{transport} {name}: no ctx");
        for (prop, want) in want_props {
            assert_eq!(&got_props[prop], want, "{transport} {name}.{prop}");
        }
        assert_eq!(
            got["required"], schema["required"],
            "{transport} {name}: required"
        );
        assert_eq!(got, &schema, "{transport} {name}: the whole input schema");
    }
}

#[tokio::test]
async fn tools_list_over_stdio_and_mcp_keeps_26_tools_and_the_rewired_schemas() {
    let srv = ClockServer::fixed(BASE_MS).await;
    let dir = srv.vault("work");

    let mut stdio = Stdio::start(&dir);
    let listed = stdio.request(2, "tools/list", json!({}));
    drop(stdio);
    assert_rewired_schemas_unchanged(&listed["result"]["tools"], "stdio");

    for header in [None, Some("+14:00")] {
        let r = rpc_with(
            &srv.url(&mcp_path("work")),
            &request(1, "tools/list", json!({})),
            Some(&bearer()),
            &with_offset(header),
        )
        .await;
        assert_rewired_schemas_unchanged(&rpc_result(&r)["tools"], &format!("/mcp {header:?}"));
    }
}

// ---------------------------------------------------------------------------
// AC 10: the offset never shifts timestamps
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_offset_never_shifts_created_at_updated_at_or_reviewed_at_from_the_base_clock() {
    let clock = SetClock::at(BASE_MS);
    let srv = ClockServer::start(Some(clock.clone() as SharedClock)).await;
    srv.vault("work");

    let mut created = Vec::new();
    for (name, header) in [("East", Some("+14:00")), ("Plain", None)] {
        let f = call_ok(
            &srv,
            "work",
            header,
            "create_smart_folder",
            json!({ "name": name }),
        )
        .await;
        assert_eq!(f["created_at"], BASE_MS, "{header:?}: created_at");
        assert_eq!(f["updated_at"], BASE_MS, "{header:?}: updated_at");
        created.push(f["id"].as_str().expect("folder id").to_string());
    }

    clock.set(BASE_MS + 5_000);
    for (id, header) in created.iter().zip([Some("+14:00"), None]) {
        let f = call_ok(
            &srv,
            "work",
            header,
            "update_smart_folder",
            json!({ "id": id, "name": format!("{id} renamed") }),
        )
        .await;
        assert_eq!(f["updated_at"], BASE_MS + 5_000, "{header:?}: updated_at");
        assert_eq!(f["created_at"], BASE_MS, "{header:?}: created_at kept");
    }

    clock.set(BASE_MS + 9_000);
    for (date, header) in [("2026-02-10", Some("+14:00")), ("2026-02-11", None)] {
        let appended = call_ok(
            &srv,
            "work",
            header,
            "append_to_daily_note",
            json!({ "text": "Something to review.", "date": date }),
        )
        .await;
        let daily_id = appended["note_id"].as_str().expect("note_id");
        let changes = call_ok(
            &srv,
            "work",
            header,
            "get_daily_note_changes",
            json!({ "date": date }),
        )
        .await;
        let reviewed = call_ok(
            &srv,
            "work",
            header,
            "mark_day_reviewed",
            json!({
                "date": date,
                "version": changes["content_version"],
                "changes": [{ "note_id": daily_id, "bullets": ["Looked it over"] }],
            }),
        )
        .await;
        assert_eq!(
            reviewed["reviewed_at"],
            BASE_MS + 9_000,
            "{header:?}: reviewed_at is the base instant"
        );
    }
}
