//! WI #445 (Spec #390 req 1, 3, 4, 5, 6, 7): stdio agent presence and the
//! MCP session hook.
//!
//! - The session hook: `impl ServerHandler for Memex` tells an attached
//!   `AgentSessions` seam about every request, once and before it runs:
//!   `tools/call` as `RequestKind::ToolCall`, everything else as `Other`.
//!   A `Memex` with no seam behaves as before and writes nothing.
//! - Stdio presence: `serve_stdio_on` (the testable `serve --vault`) sweeps
//!   expired records at start, writes `<vault>/.memex/agents/<id>.json` when
//!   initialize completes, rewrites it every heartbeat, and on a clean end
//!   stops the heartbeat before deleting it. A write failure is logged and
//!   never ends the session.
//!
//! Every in-process test runs on a paused tokio clock with a fake `Clock`:
//! a heartbeat is `clock.set(..)` plus `tokio::time::advance(interval)`, and
//! waits poll in 1 ms steps of paused time. No test sleeps longer than
//! 100 ms. Tests that assert hook behaviour go through the rmcp client.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use memex_core::agents::presence::{
    self, presence_dir, PresenceRecord, Transport, HEARTBEAT_MS, STDIO_TTL_MS,
};
use memex_core::{Clock, Vault};
use memex_mcp::cli::serve::{serve_stdio_on, serve_stdio_until};
use memex_mcp::presence::{AgentSession, AgentSessions, RequestKind};
use memex_mcp::server::request_clock::SharedClock;
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::model::{
    CallToolRequestParams, ClientCapabilities, ClientInfo, ClientRequest, GetPromptRequestParams,
    Implementation, PingRequest,
};
use rmcp::service::{RequestContext, RunningService};
use rmcp::{RoleClient, RoleServer, ServiceExt};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::DuplexStream;
use tokio::task::JoinHandle;

/// The fake clock's time when a test starts (ms epoch, 2023-11-14). Far
/// from the real clock, so a server that reads `SystemClock` is caught.
const T0: i64 = 1_700_000_000_000;
/// The heartbeat interval every in-process test serves with.
const INTERVAL: Duration = Duration::from_millis(HEARTBEAT_MS as u64);
/// Upper bound on 1 ms polls of paused time while waiting for an event.
const POLLS: usize = 1_000;

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

fn fresh_vault() -> (TempDir, PathBuf, Arc<AppState>) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path.clone(), None));
    (dir, path, state)
}

/// One in-process stdio server (`serve_stdio_on`) on a duplex pipe.
struct Session {
    _dir: TempDir,
    vault: PathBuf,
    clock: Arc<FakeClock>,
    server: JoinHandle<anyhow::Result<()>>,
}

/// A vault, then `start_on` it.
fn start(with_embeddings: bool) -> (Session, DuplexStream) {
    let (dir, vault, state) = fresh_vault();
    start_on(dir, vault, state, with_embeddings)
}

/// Spawns `serve_stdio_on` for `state` with the fake clock at `T0`. Returns
/// the client's end of the pipe; dropping it is stdin EOF for the server.
fn start_on(
    dir: TempDir,
    vault: PathBuf,
    state: Arc<AppState>,
    with_embeddings: bool,
) -> (Session, DuplexStream) {
    let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let shared: SharedClock = clock.clone();
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(serve_stdio_on(
        state,
        with_embeddings,
        shared,
        INTERVAL,
        server_io,
    ));
    (
        Session {
            _dir: dir,
            vault,
            clock,
            server,
        },
        client_io,
    )
}

fn client_info(name: &str, version: &str) -> ClientInfo {
    ClientInfo::new(
        ClientCapabilities::default(),
        Implementation::new(name, version),
    )
}

/// Completes the MCP initialize handshake as `name`/`version`.
async fn connect(
    io: DuplexStream,
    name: &str,
    version: &str,
) -> RunningService<RoleClient, ClientInfo> {
    client_info(name, version)
        .serve(io)
        .await
        .expect("initialize handshake")
}

/// The record files (`*.json`, not `*.json.tmp`) in the vault's presence
/// dir, as `(file stem, parsed JSON)`.
fn record_files(vault: &Path) -> Vec<(String, Value)> {
    let Ok(entries) = fs::read_dir(presence_dir(vault)) else {
        return Vec::new();
    };
    entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "json"))
        .map(|p| {
            let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
            let raw = fs::read(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()));
            let v: Value = serde_json::from_slice(&raw)
                .unwrap_or_else(|e| panic!("{} is not JSON ({e})", p.display()));
            (stem, v)
        })
        .collect()
}

/// The one record in the vault's presence dir, if there is exactly one.
fn only_record(vault: &Path) -> Option<(String, Value)> {
    let mut all = record_files(vault);
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

/// Lets the server run for `n` ms of paused time.
async fn settle(n: u64) {
    for _ in 0..n {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

impl Session {
    /// The record once initialize has written it.
    async fn record(&self) -> (String, Value) {
        let vault = self.vault.clone();
        eventually("the presence record", || only_record(&vault)).await
    }

    /// Sets the fake clock to `at`, advances paused time by one interval and
    /// returns the record once a heartbeat has rewritten it at `at`.
    async fn heartbeat(&self, at: i64) -> Value {
        self.clock.set(at);
        tokio::time::advance(INTERVAL).await;
        let vault = self.vault.clone();
        eventually(&format!("a heartbeat with last_seen_at {at}"), || {
            only_record(&vault)
                .map(|(_, r)| r)
                .filter(|r| r["last_seen_at"] == json!(at))
        })
        .await
    }

    /// Waits for the server to return after the client went away. Hands the
    /// vault's `TempDir` back: the caller keeps it alive while it asserts on
    /// the files the ended server left or removed (dropping it deletes the
    /// vault, which would make "the record is gone" pass vacuously).
    async fn ended(self) -> (TempDir, anyhow::Result<()>) {
        let result = tokio::time::timeout(Duration::from_secs(1), self.server)
            .await
            .expect("the server must end promptly once stdin closes")
            .expect("server task panicked");
        (self._dir, result)
    }
}

fn record(v: &Value) -> PresenceRecord {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("not a PresenceRecord ({e}): {v}"))
}

async fn ping(client: &RunningService<RoleClient, ClientInfo>) {
    client
        .send_request(ClientRequest::PingRequest(PingRequest::default()))
        .await
        .expect("ping");
}

/// Calls `name` with `args` and returns the tool's JSON payload.
async fn call(client: &RunningService<RoleClient, ClientInfo>, name: &str, args: Value) -> Value {
    let params = CallToolRequestParams::new(name.to_string())
        .with_arguments(args.as_object().expect("object args").clone());
    let result = client
        .call_tool(params)
        .await
        .unwrap_or_else(|e| panic!("tools/call {name}: {e}"));
    assert_ne!(result.is_error, Some(true), "{name} errored: {result:?}");
    let v = serde_json::to_value(&result).unwrap();
    let text = v["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("{name} returned no text: {v}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("{name} returned non-JSON ({e}): {text}"))
}

/// A record file other sessions left behind.
fn leftover(session_id: &str, expires_at: i64) -> PresenceRecord {
    PresenceRecord {
        session_id: session_id.to_string(),
        client_name: "other-agent".to_string(),
        client_version: Some("0.1".to_string()),
        transport: Transport::Stdio,
        started_at: expires_at - 60_000,
        last_seen_at: expires_at - STDIO_TTL_MS,
        last_request_at: expires_at - STDIO_TTL_MS,
        last_tool_at: None,
        expires_at,
        embeddings: false,
    }
}

// ---------- record on initialize (req 1, 3, 5) ----------

#[tokio::test(start_paused = true)]
async fn initialize_writes_the_stdio_presence_record_with_the_client_identity() {
    let (h, io) = start(false);

    // Serve start alone writes no record: it waits for the handshake.
    settle(20).await;
    assert!(
        record_files(&h.vault).is_empty(),
        "no record before initialize completes"
    );

    let client = connect(io, "test-agent", "1.2.3").await;
    let (stem, v) = h.record().await;

    assert_eq!(v["session_id"], json!(stem), "file is <session_id>.json");
    assert!(
        stem.parse::<ulid::Ulid>().is_ok(),
        "session_id is a ULID: {stem}"
    );
    assert_eq!(v["client_name"], json!("test-agent"));
    assert_eq!(v["client_version"], json!("1.2.3"));
    assert_eq!(v["transport"], json!("stdio"));
    assert_eq!(v["embeddings"], json!(false));
    assert!(
        v.as_object().unwrap().contains_key("last_tool_at") && v["last_tool_at"].is_null(),
        "last_tool_at is present and null: {v}"
    );
    assert_eq!(v["started_at"], json!(T0), "stamped by the fake clock");
    assert_eq!(v["last_seen_at"], json!(T0));
    assert_eq!(v["last_request_at"], json!(T0));
    assert_eq!(v["expires_at"], json!(T0 + 15_000), "last_seen_at + 15000");
    assert!(!h.server.is_finished(), "the session keeps running");

    drop(client);
}

#[tokio::test(start_paused = true)]
async fn with_embeddings_on_the_record_says_embeddings_true() {
    // No embedder is built: the flag alone is recorded.
    let (h, io) = start(true);
    let _client = connect(io, "test-agent", "1.2.3").await;
    let (_, v) = h.record().await;
    assert_eq!(v["embeddings"], json!(true), "{v}");
    assert_eq!(v["transport"], json!("stdio"));
}

#[tokio::test(start_paused = true)]
async fn client_identity_longer_than_64_chars_is_truncated_in_the_record() {
    let (h, io) = start(false);
    let name = "n".repeat(100);
    let version = "9".repeat(70);
    let _client = connect(io, &name, &version).await;
    let (_, v) = h.record().await;
    assert_eq!(v["client_name"], json!("n".repeat(64)));
    assert_eq!(v["client_version"], json!("9".repeat(64)));
}

// ---------- heartbeat (req 1, 4) ----------

#[tokio::test(start_paused = true)]
async fn advancing_the_fake_clock_one_interval_rewrites_the_record() {
    let (h, io) = start(false);
    let _client = connect(io, "test-agent", "1.2.3").await;
    let (stem, _) = h.record().await;

    let t1 = T0 + HEARTBEAT_MS;
    let v = h.heartbeat(t1).await;
    assert_eq!(v["session_id"], json!(stem), "the same session's record");
    assert_eq!(v["expires_at"], json!(t1 + 15_000));
    assert_eq!(v["started_at"], json!(T0), "started_at never moves");
    assert_eq!(
        v["last_request_at"],
        json!(T0),
        "a heartbeat is not a request"
    );
    assert!(v["last_tool_at"].is_null(), "{v}");
    assert_eq!(v["client_name"], json!("test-agent"));

    let t2 = t1 + HEARTBEAT_MS;
    let v = h.heartbeat(t2).await;
    assert_eq!(v["expires_at"], json!(t2 + 15_000), "every interval");
    assert_eq!(only_record(&h.vault).unwrap().0, stem, "one record file");
}

/// A `Clock` that moves 1 s forward on every read, so a heartbeat that fires
/// at any moment shows up as a `last_seen_at` later than `started_at` (the
/// paused tokio clock alone can't tell an immediate tick from a late one).
struct StepClock(AtomicI64);

impl Clock for StepClock {
    fn now_ms(&self) -> i64 {
        self.0.fetch_add(1_000, Ordering::SeqCst)
    }
}

#[tokio::test(start_paused = true)]
async fn the_first_heartbeat_comes_one_full_interval_after_initialize_not_before() {
    let (_dir, vault, state) = fresh_vault();
    let clock: SharedClock = Arc::new(StepClock(AtomicI64::new(T0)));
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let _server = tokio::spawn(serve_stdio_on(state, false, clock, INTERVAL, server_io));
    let _client = connect(client_io, "test-agent", "1.2.3").await;
    let v = eventually("the presence record", || {
        only_record(&vault).map(|(_, r)| r)
    })
    .await;
    assert_eq!(
        v["last_seen_at"], v["started_at"],
        "initialize writes the record once: {v}"
    );

    // Less than one interval of paused time passes: no heartbeat yet.
    tokio::time::advance(INTERVAL / 2).await;
    settle(5).await;
    let (_, v) = only_record(&vault).expect("the record");
    assert_eq!(
        v["last_seen_at"], v["started_at"],
        "no heartbeat before one interval has passed: {v}"
    );

    // The rest of the interval fires the first one.
    tokio::time::advance(INTERVAL / 2 + Duration::from_millis(50)).await;
    let v = eventually("the first heartbeat", || {
        only_record(&vault)
            .map(|(_, r)| r)
            .filter(|r| r["last_seen_at"] != r["started_at"])
    })
    .await;
    assert!(v["last_seen_at"].as_i64() > v["started_at"].as_i64(), "{v}");
}

// ---------- last_request_at / last_tool_at (req 3, D1) ----------

#[tokio::test(start_paused = true)]
async fn a_tools_call_sets_last_request_at_and_last_tool_at_in_the_next_record() {
    let (h, io) = start(false);
    let client = connect(io, "test-agent", "1.2.3").await;
    h.record().await;

    let t_call = T0 + 1_000;
    h.clock.set(t_call);
    call(&client, "get_vault_settings", json!({})).await;
    let v = h.heartbeat(T0 + HEARTBEAT_MS).await;
    assert_eq!(v["last_request_at"], json!(t_call), "{v}");
    assert_eq!(v["last_tool_at"], json!(t_call), "{v}");

    // A later ping moves last_request_at and keeps the last tool call.
    let t_ping = T0 + HEARTBEAT_MS + 1_000;
    h.clock.set(t_ping);
    ping(&client).await;
    let v = h.heartbeat(T0 + 2 * HEARTBEAT_MS).await;
    assert_eq!(v["last_request_at"], json!(t_ping), "{v}");
    assert_eq!(
        v["last_tool_at"],
        json!(t_call),
        "a ping keeps last_tool_at"
    );
}

#[tokio::test(start_paused = true)]
async fn a_ping_and_a_tools_list_set_last_request_at_only() {
    let (h, io) = start(false);
    let client = connect(io, "test-agent", "1.2.3").await;
    h.record().await;

    let t_ping = T0 + 1_000;
    h.clock.set(t_ping);
    ping(&client).await;
    let v = h.heartbeat(T0 + HEARTBEAT_MS).await;
    assert_eq!(v["last_request_at"], json!(t_ping), "{v}");
    assert!(
        v["last_tool_at"].is_null(),
        "a ping is not a tool call: {v}"
    );

    let t_list = T0 + HEARTBEAT_MS + 1_000;
    h.clock.set(t_list);
    let tools = client.list_all_tools().await.expect("tools/list");
    assert!(!tools.is_empty());
    let v = h.heartbeat(T0 + 2 * HEARTBEAT_MS).await;
    assert_eq!(v["last_request_at"], json!(t_list), "{v}");
    assert!(
        v["last_tool_at"].is_null(),
        "tools/list is not a tool call: {v}"
    );
}

// ---------- clean end (req 1) ----------

#[tokio::test(start_paused = true)]
async fn closing_stdin_deletes_the_record_and_a_later_heartbeat_does_not_recreate_it() {
    let (h, io) = start(false);
    let client = connect(io, "test-agent", "1.2.3").await;
    h.record().await;
    h.heartbeat(T0 + HEARTBEAT_MS).await;

    // Closing the client's end is stdin EOF for the server.
    client.cancel().await.expect("close the client");
    let vault = h.vault.clone();
    let clock = h.clock.clone();
    let (_dir, result) = h.ended().await;
    assert!(result.is_ok(), "stdin EOF is a clean end: {result:?}");
    assert!(
        vault.join("memex.db").exists(),
        "the vault outlives the server, so an empty agents dir is a real delete"
    );
    assert!(
        record_files(&vault).is_empty(),
        "the record is deleted on a clean end"
    );

    clock.set(T0 + 2 * HEARTBEAT_MS);
    tokio::time::advance(INTERVAL).await;
    settle(20).await;
    assert!(
        record_files(&vault).is_empty(),
        "no heartbeat after the end recreates the record"
    );
}

#[tokio::test(start_paused = true)]
async fn a_shutdown_signal_deletes_the_record_while_the_client_still_holds_stdin() {
    let (dir, vault, state) = fresh_vault();
    let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let shared: SharedClock = clock.clone();
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let (signal, shutdown) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(serve_stdio_until(
        state,
        false,
        shared,
        INTERVAL,
        server_io,
        async move {
            let _ = shutdown.await;
        },
    ));
    let client = connect(client_io, "test-agent", "1.2.3").await;
    eventually("the presence record", || only_record(&vault)).await;
    ping(&client).await;
    assert!(
        !server.is_finished(),
        "nothing ends the server before the signal"
    );

    // SIGINT or SIGTERM while the client keeps its end of the pipe open.
    signal.send(()).unwrap();
    let result = tokio::time::timeout(Duration::from_secs(1), server)
        .await
        .expect("a shutdown signal ends the server while stdin is still open")
        .expect("server task panicked");
    assert!(
        result.is_ok(),
        "a shutdown signal is a clean end: {result:?}"
    );
    assert!(
        vault.join("memex.db").exists(),
        "the vault outlives the server, so an empty agents dir is a real delete"
    );
    assert!(
        record_files(&vault).is_empty(),
        "a shutdown signal deletes the record"
    );

    clock.set(T0 + 2 * HEARTBEAT_MS);
    tokio::time::advance(INTERVAL).await;
    settle(20).await;
    assert!(
        record_files(&vault).is_empty(),
        "no heartbeat after the shutdown recreates the record"
    );
    drop((client, dir));
}

#[tokio::test(start_paused = true)]
async fn a_shutdown_future_that_never_resolves_leaves_the_server_running() {
    let (dir, vault, state) = fresh_vault();
    let clock: SharedClock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(serve_stdio_until(
        state,
        false,
        clock,
        INTERVAL,
        server_io,
        std::future::pending::<()>(),
    ));
    let client = connect(client_io, "test-agent", "1.2.3").await;
    eventually("the presence record", || only_record(&vault)).await;
    settle(20).await;
    assert!(!server.is_finished(), "no signal, no end");
    assert!(only_record(&vault).is_some(), "the record stays");
    drop((client, dir));
}

// ---------- shutdown order on a multi-threaded runtime (req 1) ----------

/// A clock whose reads block once armed, until released. The heartbeat is
/// the only reader while the session is idle, so an armed clock freezes it
/// mid-write on a worker thread (the production runtime is multi-threaded;
/// on a current_thread runtime an aborted idle heartbeat can't be mid-write).
#[derive(Default)]
struct GateClock(Arc<(Mutex<Gate>, Condvar)>);

#[derive(Default)]
struct Gate {
    armed: bool,
    blocked: bool,
    released: bool,
}

impl Clock for GateClock {
    fn now_ms(&self) -> i64 {
        let (lock, cv) = &*self.0;
        let mut g = lock.lock().unwrap();
        if g.armed && !g.released {
            g.blocked = true;
            cv.notify_all();
            while !g.released {
                g = cv.wait(g).unwrap();
            }
        }
        T0
    }
}

/// The test's handle on a [`GateClock`]. Releases the gate on drop, so a
/// failed assertion can't leave a worker thread blocked (the runtime would
/// then hang on shutdown).
struct Release(Arc<(Mutex<Gate>, Condvar)>);

impl Release {
    fn arm(&self) {
        self.0 .0.lock().unwrap().armed = true;
    }
    fn is_blocked(&self) -> bool {
        self.0 .0.lock().unwrap().blocked
    }
    fn release(&self) {
        let (lock, cv) = &*self.0;
        lock.lock().unwrap().released = true;
        cv.notify_all();
    }
}

impl Drop for Release {
    fn drop(&mut self) {
        self.release();
    }
}

/// Sleeps `ms` on the test thread. These tests block a worker thread in the
/// clock on purpose, which can leave the runtime's timer driver without an
/// owner, so they wait with std sleeps and polls, never `tokio::time`.
fn real_sleep(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

/// How a multi-threaded session with a heartbeat frozen mid-write ends.
enum End {
    StdinEof,
    Signal,
}

/// Serves on a multi-threaded runtime, freezes the heartbeat inside its clock
/// read, ends the session as `end`, then checks the server waits for that
/// heartbeat before it deletes the record, and that the record stays gone.
async fn end_with_heartbeat_in_flight(end: End) {
    let (dir, vault, state) = fresh_vault();
    let gate = GateClock::default();
    let release = Release(gate.0.clone());
    let clock: SharedClock = Arc::new(gate);
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let (signal, shutdown) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(serve_stdio_until(
        state,
        false,
        clock,
        Duration::from_millis(20),
        server_io,
        async move {
            let _ = shutdown.await;
        },
    ));
    let client = connect(client_io, "test-agent", "1.2.3").await;
    eventually_real("the initialize record", || only_record(&vault));

    release.arm();
    eventually_real("a heartbeat blocked in the clock", || {
        release.is_blocked().then_some(())
    });

    // The session ends while a heartbeat is mid-write.
    match end {
        End::StdinEof => {
            client.cancel().await.expect("close the client");
        }
        End::Signal => signal.send(()).unwrap(),
    }
    real_sleep(50);
    assert!(
        !server.is_finished(),
        "the server waits for the in-flight heartbeat before it deletes the record"
    );

    release.release();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !server.is_finished() {
        assert!(
            Instant::now() < deadline,
            "the server ends once the heartbeat is released"
        );
        real_sleep(2);
    }
    let result = server.await.expect("server task panicked");
    assert!(result.is_ok(), "a clean end: {result:?}");
    assert!(
        record_files(&vault).is_empty(),
        "the record is deleted after the in-flight heartbeat, not before it"
    );
    real_sleep(50);
    real_sleep(50);
    assert!(
        record_files(&vault).is_empty(),
        "a late heartbeat write doesn't recreate the record"
    );
    drop(dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stdin_eof_stops_and_joins_the_heartbeat_before_it_deletes_the_record() {
    end_with_heartbeat_in_flight(End::StdinEof).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_shutdown_signal_stops_and_joins_the_heartbeat_before_it_deletes_the_record() {
    end_with_heartbeat_in_flight(End::Signal).await;
}

// ---------- memex.db untouched (TD "Presence lives in files") ----------

#[tokio::test(start_paused = true)]
async fn three_heartbeats_leave_memex_db_data_version_unchanged() {
    let (h, io) = start(false);
    let client = connect(io, "test-agent", "1.2.3").await;
    h.record().await;

    let probe = rusqlite::Connection::open(h.vault.join("memex.db")).unwrap();
    let data_version = || -> i64 {
        probe
            .query_row("PRAGMA data_version", [], |r| r.get(0))
            .unwrap()
    };
    let before = data_version();

    for k in 1..=3 {
        // Requests between heartbeats update presence in memory only.
        ping(&client).await;
        client.list_all_tools().await.expect("tools/list");
        let at = T0 + k * HEARTBEAT_MS;
        let v = h.heartbeat(at).await;
        assert_eq!(v["expires_at"], json!(at + 15_000));
    }
    assert_eq!(
        data_version(),
        before,
        "presence heartbeats and requests must not write memex.db"
    );

    // Control: the probe does see a write through the same server.
    call(&client, "create_note", json!({ "content_md": "# Probe\n" })).await;
    assert_ne!(data_version(), before, "the data_version probe sees writes");
}

// ---------- sweep at serve start (req 6) ----------

#[tokio::test(start_paused = true)]
async fn serve_start_sweeps_the_expired_record_and_keeps_the_unexpired_one() {
    let (dir, vault, state) = fresh_vault();
    let agents = presence_dir(&vault);
    let expired = ulid::Ulid::new().to_string();
    let live = ulid::Ulid::new().to_string();
    // By the fake clock (T0) one has expired and one has not; by the real
    // clock both have, so a sweep that reads SystemClock deletes both.
    presence::write(&agents, &leftover(&expired, T0 - 1)).unwrap();
    presence::write(&agents, &leftover(&live, T0 + 1)).unwrap();

    // No handshake: the sweep runs at serve start.
    let (h, io) = start_on(dir, vault, state, false);
    eventually("the expired record to be swept", || {
        (!agents.join(format!("{expired}.json")).exists()).then_some(())
    })
    .await;
    assert!(
        agents.join(format!("{live}.json")).exists(),
        "the unexpired record is kept"
    );

    drop(io);
    let (_dir, _result) = h.ended().await;
    assert!(
        agents.join(format!("{live}.json")).exists(),
        "another session's record is never deleted"
    );
}

// ---------- write failure (req 1, 12) ----------

/// A `tracing` writer into a shared buffer.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn len(&self) -> usize {
        self.0.lock().unwrap().len()
    }
    fn text_since(&self, mark: usize) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()[mark..]).into_owned()
    }
}

impl Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// This test binary's `tracing` output. A process-wide subscriber, not a
/// scoped one: a scoped `set_default` misses events while other tests run
/// in parallel (seen in red mode: nothing captured).
fn captured_logs() -> &'static Captured {
    static LOGS: OnceLock<Captured> = OnceLock::new();
    LOGS.get_or_init(|| {
        let logs = Captured::default();
        let writer = logs.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_writer(move || writer.clone())
            .with_ansi(false)
            .finish();
        tracing::subscriber::set_global_default(subscriber).expect("one global subscriber");
        logs
    })
}

#[tokio::test(start_paused = true)]
async fn a_presence_write_failure_does_not_fail_initialize_or_a_tool_call_and_is_logged() {
    let logs = captured_logs();
    let mark = logs.len();

    let (dir, vault, state) = fresh_vault();
    // `.memex/agents` is a file, so every presence write fails.
    fs::create_dir_all(vault.join(".memex")).unwrap();
    fs::write(presence_dir(&vault), b"not a directory").unwrap();

    let (h, io) = start_on(dir, vault.clone(), state, false);
    let client = connect(io, "test-agent", "1.2.3").await;
    let settings = call(&client, "get_vault_settings", json!({})).await;
    assert!(settings.get("error").is_none(), "{settings}");

    h.clock.set(T0 + HEARTBEAT_MS);
    tokio::time::advance(INTERVAL).await;
    settle(20).await;
    let again = call(&client, "get_vault_settings", json!({})).await;
    assert!(again.get("error").is_none(), "{again}");
    assert!(
        !h.server.is_finished(),
        "a failed heartbeat never ends the session"
    );
    let text = logs.text_since(mark);
    assert!(
        text.contains("agent presence write failed"),
        "the failed presence write is logged:\n{text}"
    );

    // The heartbeat keeps running: once the dir is writable again the next
    // one writes the record.
    fs::remove_file(presence_dir(&vault)).unwrap();
    let at = T0 + 2 * HEARTBEAT_MS;
    let v = h.heartbeat(at).await;
    // The failed writes were this session's: the record that finally lands
    // carries the id the WARN lines name, at WARN level. (The log buffer is
    // shared with the sweep and delete tests, so the line must name it.)
    let (session_id, _) = h.record().await;
    let text = logs.text_since(mark);
    assert!(
        text.lines().any(|l| l.contains("WARN")
            && l.contains("agent presence write failed")
            && l.contains(&session_id)),
        "the failed write is logged at WARN with this session's id {session_id}:\n{text}"
    );
    assert_eq!(v["client_name"], json!("test-agent"), "{v}");
    assert_eq!(v["started_at"], json!(T0), "{v}");
    assert_eq!(v["expires_at"], json!(at + 15_000), "{v}");
}

/// Makes `dir` read-only so deleting a file in it fails (not for root).
#[cfg(unix)]
fn set_dir_mode(dir: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(dir, fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(unix)]
#[tokio::test(start_paused = true)]
async fn a_failed_sweep_is_logged_and_does_not_stop_serve() {
    let logs = captured_logs();
    let mark = logs.len();
    let (dir, vault, state) = fresh_vault();
    let agents = presence_dir(&vault);
    let expired = ulid::Ulid::new().to_string();
    presence::write(&agents, &leftover(&expired, T0 - 1)).unwrap();
    set_dir_mode(&agents, 0o555);

    let (h, io) = start_on(dir, vault, state, false);
    let client = connect(io, "test-agent", "1.2.3").await;
    settle(20).await;
    let text = logs.text_since(mark);
    let swept = !agents.join(format!("{expired}.json")).exists();
    set_dir_mode(&agents, 0o755);
    assert!(!swept, "the delete really failed (not running as root?)");
    assert!(
        text.contains("agent presence sweep failed"),
        "a failed sweep is logged:\n{text}"
    );
    assert!(!h.server.is_finished(), "a failed sweep never ends serve");
    ping(&client).await;
}

#[cfg(unix)]
#[tokio::test(start_paused = true)]
async fn a_failed_delete_at_the_end_is_logged_and_serve_still_ends_cleanly() {
    let logs = captured_logs();
    let mark = logs.len();
    let (h, io) = start(false);
    let client = connect(io, "test-agent", "1.2.3").await;
    let (session_id, _) = h.record().await;
    let agents = presence_dir(&h.vault);
    set_dir_mode(&agents, 0o555);

    client.cancel().await.expect("close the client");
    let vault = h.vault.clone();
    let (_dir, result) = h.ended().await;
    let still_there = agents.join(format!("{session_id}.json")).exists();
    set_dir_mode(&agents, 0o755);
    assert!(
        result.is_ok(),
        "a failed delete never fails the end: {result:?}"
    );
    assert!(
        still_there,
        "the delete really failed (not running as root?)"
    );
    let text = logs.text_since(mark);
    assert!(
        text.lines()
            .any(|l| l.contains("agent presence delete failed") && l.contains(&session_id)),
        "the failed delete is logged with the session id:\n{text}"
    );
    assert!(vault.exists());
}

/// A clock that advances 1 ms on every read, so `last_seen_at` counts the
/// reads (one per heartbeat once no request is running).
struct TickClock(AtomicI64);

impl Clock for TickClock {
    fn now_ms(&self) -> i64 {
        self.0.fetch_add(1, Ordering::SeqCst)
    }
}

#[tokio::test(start_paused = true)]
async fn a_stalled_runtime_gets_one_heartbeat_not_a_burst_of_missed_ones() {
    let (dir, vault, state) = fresh_vault();
    let _keep = dir;
    let clock: SharedClock = Arc::new(TickClock(AtomicI64::new(T0)));
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(serve_stdio_on(state, false, clock, INTERVAL, server_io));
    let client = connect(client_io, "test-agent", "1.2.3").await;
    let begun = eventually("the initialize record", || only_record(&vault))
        .await
        .1["last_seen_at"]
        .as_i64()
        .unwrap();

    // Three intervals pass at once: one heartbeat answers them, and the next
    // is a full interval later (MissedTickBehavior::Delay), not three at once.
    tokio::time::advance(INTERVAL * 3).await;
    eventually("a heartbeat", || {
        only_record(&vault).filter(|(_, r)| r["last_seen_at"].as_i64().unwrap() > begun)
    })
    .await;
    settle(50).await;
    let after = only_record(&vault).unwrap().1["last_seen_at"]
        .as_i64()
        .unwrap();
    assert_eq!(
        after,
        begun + 1,
        "exactly one heartbeat after a 3-interval stall"
    );
    assert!(!server.is_finished());
    drop(client);
}

// ---------- the session seam (D27: the hook every later WI uses) ----------

#[derive(Debug, Clone, PartialEq)]
struct Seen {
    kind: RequestKind,
    /// `clientInfo.name` from `ctx.peer.peer_info()` at the call.
    client: Option<String>,
    /// Notes in the vault when the seam was called.
    notes: i64,
}

/// A seam that records every call and returns a fixed identity.
struct Recorder {
    state: Arc<AppState>,
    seen: Mutex<Vec<Seen>>,
}

impl Recorder {
    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

impl AgentSessions for Recorder {
    fn on_request(
        &self,
        ctx: &RequestContext<RoleServer>,
        kind: RequestKind,
    ) -> Option<AgentSession> {
        let notes = match self.state.vault.try_lock() {
            Ok(vault) => vault
                .connection_ref()
                .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
                .unwrap(),
            Err(_) => -1,
        };
        let client = ctx.peer.peer_info().map(|i| i.client_info.name.clone());
        self.seen.lock().unwrap().push(Seen {
            kind,
            client,
            notes,
        });
        Some(AgentSession {
            session_id: "01HZZZZZZZZZZZZZZZZZZZZZZZ".to_string(),
            client_name: "recorder".to_string(),
            transport: Transport::Stdio,
        })
    }
}

/// Serves `memex` on a duplex pipe and connects a "test-agent" client.
async fn serve_in_process(memex: Memex) -> RunningService<RoleClient, ClientInfo> {
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    tokio::spawn(async move {
        if let Ok(service) = memex.serve(server_io).await {
            let _ = service.waiting().await;
        }
    });
    connect(client_io, "test-agent", "1.2.3").await
}

fn seen(kind: RequestKind, notes: i64) -> Seen {
    Seen {
        kind,
        client: Some("test-agent".to_string()),
        notes,
    }
}

async fn note_count(state: &AppState) -> i64 {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

#[tokio::test]
async fn every_request_reports_to_the_seam_once_with_its_kind() {
    let (_dir, _vault, state) = fresh_vault();
    let recorder = Arc::new(Recorder {
        state: state.clone(),
        seen: Mutex::new(Vec::new()),
    });
    let memex = Memex::new(state.clone()).with_sessions(recorder.clone());
    let client = serve_in_process(memex).await;

    // initialize
    assert_eq!(recorder.seen(), vec![seen(RequestKind::Other, 0)]);

    ping(&client).await;
    client.list_all_tools().await.expect("tools/list");
    client.list_all_prompts().await.expect("prompts/list");
    client
        .get_prompt(GetPromptRequestParams::new("capture"))
        .await
        .expect("prompts/get");
    assert_eq!(
        recorder.seen(),
        vec![seen(RequestKind::Other, 0); 5],
        "initialize, ping, tools/list, prompts/list and prompts/get are Other"
    );

    let created = call(&client, "create_note", json!({ "content_md": "# Hook\n" })).await;
    assert!(created["note_id"].is_string(), "{created}");
    let all = recorder.seen();
    assert_eq!(all.len(), 6, "one call per request: {all:?}");
    assert_eq!(
        all[5],
        seen(RequestKind::ToolCall, 0),
        "tools/call is ToolCall, reported before the tool runs"
    );
    assert_eq!(note_count(&state).await, 1, "the tool still ran");
}

/// Delegates to a real `StdioSessions` and keeps what it returned.
struct ReturnSpy {
    inner: Arc<memex_mcp::presence::StdioSessions>,
    returned: Mutex<Vec<Option<AgentSession>>>,
}

impl AgentSessions for ReturnSpy {
    fn on_request(
        &self,
        ctx: &RequestContext<RoleServer>,
        kind: RequestKind,
    ) -> Option<AgentSession> {
        let r = self.inner.on_request(ctx, kind);
        self.returned.lock().unwrap().push(r.clone());
        r
    }
}

#[tokio::test(start_paused = true)]
async fn stdio_sessions_on_request_returns_the_session_identity() {
    let (_dir, vault, state) = fresh_vault();
    let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let shared: SharedClock = clock.clone();
    let inner = Arc::new(memex_mcp::presence::StdioSessions::new(
        &vault, shared, false,
    ));
    let spy = Arc::new(ReturnSpy {
        inner: inner.clone(),
        returned: Mutex::new(Vec::new()),
    });
    let memex = Memex::new(state).with_sessions(spy.clone());
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    tokio::spawn(async move {
        if let Ok(service) = memex.serve(server_io).await {
            let _ = service.waiting().await;
        }
    });
    let long = "n".repeat(100);
    let client = connect(client_io, &long, "1.2.3").await;
    ping(&client).await;
    call(&client, "create_note", json!({ "content_md": "# Id\n" })).await;

    let returned = spy.returned.lock().unwrap().clone();
    assert_eq!(
        returned.len(),
        3,
        "initialize, ping, tools/call: {returned:?}"
    );
    let expected = Some(AgentSession {
        session_id: inner.session_id().to_string(),
        client_name: "n".repeat(64),
        transport: Transport::Stdio,
    });
    for (i, r) in returned.iter().enumerate() {
        assert_eq!(
            r, &expected,
            "request {i} runs under the stdio session identity"
        );
    }
    assert_eq!(inner.session_id().len(), 26, "a ULID session id");
}

#[tokio::test]
async fn a_memex_without_a_seam_writes_no_presence() {
    let (_dir, vault, state) = fresh_vault();
    let client = serve_in_process(Memex::new(state)).await;
    ping(&client).await;
    call(&client, "create_note", json!({ "content_md": "# Plain\n" })).await;
    assert!(
        !presence_dir(&vault).exists(),
        "Memex::new alone writes no presence"
    );
}

/// `initialize` result, `tools/list` and `prompts/list` as JSON.
async fn surface(client: &RunningService<RoleClient, ClientInfo>) -> (Value, Value, Value) {
    let init = serde_json::to_value(client.peer_info().expect("server info")).unwrap();
    let tools = serde_json::to_value(client.list_all_tools().await.unwrap()).unwrap();
    let prompts = serde_json::to_value(client.list_all_prompts().await.unwrap()).unwrap();
    (init, tools, prompts)
}

#[tokio::test]
async fn attaching_a_seam_keeps_initialize_tools_list_and_prompts_unchanged() {
    let (_d1, _v1, plain_state) = fresh_vault();
    let plain = serve_in_process(Memex::new(plain_state)).await;

    let (_d2, _v2, state) = fresh_vault();
    let recorder = Arc::new(Recorder {
        state: state.clone(),
        seen: Mutex::new(Vec::new()),
    });
    let hooked = serve_in_process(Memex::new(state).with_sessions(recorder)).await;

    let (init_a, tools_a, prompts_a) = surface(&plain).await;
    let (init_b, tools_b, prompts_b) = surface(&hooked).await;
    assert_eq!(init_a, init_b, "initialize result");
    assert!(init_a["capabilities"]["tools"].is_object(), "{init_a}");
    assert!(init_a["capabilities"]["prompts"].is_object(), "{init_a}");
    assert_eq!(tools_a, tools_b, "tools/list");
    assert_eq!(prompts_a, prompts_b, "prompts/list");
}

// ---------- the real `memex serve --vault` (CLI wiring) ----------

/// A `memex serve --vault` subprocess spoken to over newline-delimited
/// JSON-RPC. Real clock and real 5 s heartbeat; waits poll in 10 ms steps.
struct Cli {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    next_id: i64,
}

impl Cli {
    fn start(vault: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve --vault");
        let stdin = child.stdin.take();
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
        Self {
            child,
            stdin,
            lines,
            next_id: 1,
        }
    }

    fn send(&mut self, msg: Value) {
        let stdin = self.stdin.as_mut().expect("stdin open");
        writeln!(stdin, "{msg}").unwrap();
        stdin.flush().unwrap();
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }

    fn initialize(&mut self) {
        let init = self.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "test-agent", "version": "1.2.3" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        self.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
    }

    /// Closes stdin and waits for the process to exit.
    fn close(&mut self) {
        drop(self.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            if self.child.try_wait().unwrap().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("memex serve --vault did not exit after stdin EOF");
    }
}

impl Drop for Cli {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Polls `f` in 10 ms steps of real time, for up to 10 s.
fn eventually_real<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(v) = f() {
            return v;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("timed out waiting for {what}");
}

#[test]
fn serve_vault_cli_writes_presence_on_initialize_and_deletes_it_at_stdin_eof() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();

    let mut cli = Cli::start(&vault);
    cli.initialize();
    let (_, v) = eventually_real("the presence record", || only_record(&vault));
    assert_eq!(v["client_name"], json!("test-agent"));
    assert_eq!(v["client_version"], json!("1.2.3"));
    assert_eq!(v["transport"], json!("stdio"));
    assert_eq!(v["embeddings"], json!(false));
    let rec = record(&v);
    assert_eq!(rec.expires_at, rec.last_seen_at + STDIO_TTL_MS);

    cli.close();
    assert!(
        record_files(&vault).is_empty(),
        "stdin EOF deletes the record"
    );
}

#[test]
fn serve_vault_cli_logs_a_presence_write_failure_to_mcp_log() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();
    fs::create_dir_all(vault.join(".memex")).unwrap();
    fs::write(presence_dir(&vault), b"not a directory").unwrap();

    let mut cli = Cli::start(&vault);
    cli.initialize();
    let resp = cli.request(
        "tools/call",
        json!({ "name": "get_vault_settings", "arguments": {} }),
    );
    assert!(resp["result"].is_object(), "tools/call failed: {resp}");
    assert_ne!(resp["result"]["isError"], json!(true), "{resp}");
    cli.close();

    let mut logs = String::new();
    for entry in fs::read_dir(vault.join(".memex")).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if name.starts_with("mcp.log") {
            logs.push_str(&fs::read_to_string(&path).unwrap());
        }
    }
    // Not just any presence line: closing stdin also logs a failed delete
    // (the agents "dir" is a file), which must not satisfy this.
    assert!(
        logs.lines()
            .any(|l| l.contains("WARN") && l.contains("agent presence write failed")),
        ".memex/mcp.log.* holds the failed presence write at WARN:\n{logs}"
    );
}

/// Sends `sig` (`TERM` or `INT`) to the `memex serve --vault` child while the
/// client still holds its stdin open, and returns how it exited.
#[cfg(unix)]
fn signal_the_stdio_server(sig: &str) -> std::process::ExitStatus {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();

    let mut cli = Cli::start(&vault);
    cli.initialize();
    eventually_real("the presence record", || only_record(&vault));
    // A round trip: the server is past startup and waiting on the signal.
    let pong = cli.request("ping", json!({}));
    assert!(pong["result"].is_object(), "ping failed: {pong}");

    let sent = Command::new("kill")
        .args([format!("-{sig}"), cli.child.id().to_string()])
        .status()
        .expect("run kill");
    assert!(sent.success(), "kill -{sig} failed");
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = cli.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "memex serve --vault did not exit on SIG{sig} with stdin open"
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    assert!(
        cli.stdin.is_some(),
        "stdin was still open when the server exited"
    );
    assert!(
        record_files(&vault).is_empty(),
        "SIG{sig} deletes the record"
    );
    assert!(vault.join("memex.db").exists());
    status
}

#[cfg(unix)]
#[test]
fn serve_vault_cli_sigterm_with_stdin_open_deletes_the_record_and_exits_cleanly() {
    let status = signal_the_stdio_server("TERM");
    assert!(status.success(), "SIGTERM is a clean shutdown: {status:?}");
}

#[cfg(unix)]
#[test]
fn serve_vault_cli_sigint_with_stdin_open_deletes_the_record_and_exits_cleanly() {
    let status = signal_the_stdio_server("INT");
    assert!(status.success(), "SIGINT is a clean shutdown: {status:?}");
}

// ---------- non-serve CLI writes (req 7) ----------

fn run_cli(args: &[&str], stdin_body: Option<&str>) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex");
    let mut stdin = child.stdin.take().unwrap();
    if let Some(body) = stdin_body {
        stdin.write_all(body.as_bytes()).unwrap();
    }
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "memex {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

#[test]
fn a_non_serve_cli_write_creates_no_agents_dir() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();
    let v = vault.to_str().unwrap();

    let added = run_cli(&["add", "--vault", v, "--title", "Req 7"], Some("Body.\n"));
    let stdout = String::from_utf8_lossy(&added.stdout);
    let note = stdout
        .split_whitespace()
        .skip_while(|w| *w != "note_id:")
        .nth(1)
        .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))
        .to_string();
    run_cli(
        &[
            "tag",
            "add",
            "--vault",
            v,
            "--note-id",
            &note,
            "--tag",
            "work",
        ],
        None,
    );

    assert!(
        !presence_dir(&vault).exists(),
        "MemexCli-style writes never create .memex/agents/"
    );
}
