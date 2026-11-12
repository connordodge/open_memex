//! WI #451 (Spec #390 req 7, 8, 9, 11, 12, 13): the agent activity log, written
//! by the `call_tool` hook in `impl ServerHandler for Memex`.
//!
//! - A `tools/call` whose request has a session (the `AgentSessions` seam
//!   returns `Some`) and whose tool `meta::is_write` names appends one
//!   `agent_activity` row when `activity_summary::summarize` returns a
//!   summary: `{ULID id, session_id, client_name, tool, summary, note_id,
//!   created_at}`. No session, a read tool, an `{"error": …}` result or a
//!   "wrote nothing" signal appends nothing.
//! - Names the call destroys or changes (a Smart Folder's name and parent, a
//!   canvas title, a link's endpoint titles) are read before the call.
//! - The insert runs after the tool's write, in its own transaction, and
//!   prunes the table to the newest 1,000. When it fails, the tool's result is
//!   returned unchanged and a WARN is logged.
//! - The stdio server (`serve_stdio_on`) and the vault server
//!   (`POST /vaults/{name}/mcp`) log the same way.
//!
//! Every logging assertion goes through an rmcp client or the vault server
//! router: direct tool method calls bypass the hook. Every test that expects
//! zero rows first shows that the same world logs a write, so "zero" is never
//! vacuous. Nothing here drops `content_revision`; the forced insert failure
//! is a test-only `BEFORE INSERT` trigger on `agent_activity` that raises.
//! Waits poll in 1 ms steps under a bound; every MCP call has a timeout, so a
//! lock held across the tool call fails the test instead of hanging it.

use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use axum::Router;
use memex_core::agents::activity::ActivityEntry;
use memex_core::agents::presence::{presence_dir, Transport, HEARTBEAT_MS};
use memex_core::notes::{self, CreateNote};
use memex_core::{feedback, indexer, now_unix_ms, Caller, Clock, Vault};
use memex_mcp::activity_summary::{summarize, PreSnapshot, TitleLookup, WRITE_TOOLS};
use memex_mcp::cli::serve::serve_stdio_on;
use memex_mcp::presence::{AgentSession, AgentSessions, RequestKind};
use memex_mcp::server::request_clock::SharedClock;
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::AppState;
use memex_mcp::tools::{meta, Memex};
use rmcp::model::{CallToolRequestParams, ClientCapabilities, ClientInfo, Implementation};
use rmcp::service::{RequestContext, RunningService};
use rmcp::{RoleClient, RoleServer, ServiceExt};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::task::JoinHandle;
use tower::ServiceExt as _;

const DAY: &str = "2026-09-05";
/// Three blocks, pinned by ord to [`B7`], [`C3`] and [`F6`].
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const B7: &str = "b7k2m9";
const C3: &str = "c3d4e5";
const F6: &str = "f6g7h8";
const TOPIC: &str = "Player Loop";
/// The session id the in-process test seam reports.
const SESSION: &str = "01J9W4510000000000000000AB";
const CLIENT: &str = "test-agent";
/// A well-formed id nothing in a fresh vault has.
const UNKNOWN_ID: &str = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
/// The fake server clock's time when an HTTP test starts (ms epoch, 2023-11-14).
const T0: i64 = 1_700_000_000_000;
/// The vault server's access token in these tests.
const TOKEN: &str = "wi451-test-token-6c1d8e2f4a9b3c7d5e0f1a2b3c4d5e6f";
const ACCEPT: &str = "application/json, text/event-stream";
const SESSION_HEADER: &str = "x-memex-agent-session";
const CLIENT_HEADER: &str = "x-memex-agent-client";
/// The newest rows the table keeps (req 11).
const KEEP: usize = 1_000;
/// The longest any one MCP call may take before the test fails (a deadlock
/// between the hook and the tool would otherwise hang it).
const CALL_TIMEOUT: Duration = Duration::from_secs(120);
/// Upper bound on 1 ms polls while waiting for a file.
const POLLS: usize = 20_000;
/// The SQL that makes every `agent_activity` insert fail (test-only trigger).
const FAIL_INSERTS: &str = "CREATE TRIGGER wi451_fail_activity BEFORE INSERT ON agent_activity
     BEGIN SELECT RAISE(ABORT, 'wi451 forced activity insert failure'); END;";

// ======================================================================
// Harness: a session seam, an in-process world, rows.
// ======================================================================

/// A session seam that answers every request with one fixed identity, or
/// with none.
struct FixedSession(Option<AgentSession>);

impl FixedSession {
    fn some() -> Arc<dyn AgentSessions> {
        Arc::new(FixedSession(Some(AgentSession {
            session_id: SESSION.to_string(),
            client_name: CLIENT.to_string(),
            transport: Transport::Stdio,
        })))
    }

    fn none() -> Arc<dyn AgentSessions> {
        Arc::new(FixedSession(None))
    }
}

impl AgentSessions for FixedSession {
    fn on_request(
        &self,
        _ctx: &RequestContext<RoleServer>,
        _kind: RequestKind,
    ) -> Option<AgentSession> {
        self.0.clone()
    }
}

fn client_info(name: &str, version: &str) -> ClientInfo {
    ClientInfo::new(
        ClientCapabilities::default(),
        Implementation::new(name, version),
    )
}

/// The vault's person-side fixture: the day [`DAY`] and the topic [`TOPIC`].
struct Fixture {
    day: String,
    topic: String,
}

/// A note created on the person path and indexed, as the app would.
fn person_note(vault: &mut Vault, title: &str, body: &str, role: Option<&str>) -> String {
    let note = notes::create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: role.map(|r| json!({ "role": r })),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note.id.to_string()
}

/// The person's day [`DAY`] (blocks pinned to B7, C3, F6) and topic [`TOPIC`].
fn fixture(vault: &mut Vault) -> Fixture {
    let day = person_note(vault, DAY, DAY_BODY, Some("daily"));
    for (ord, id) in [B7, C3, F6].iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, day, ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "precondition: block at ord {ord}");
    }
    let topic = person_note(vault, TOPIC, "About the loop.\n", Some("topic"));
    // `#work` written by the person, so `tag_note` may apply it.
    person_note(vault, "Vocabulary", "#work\n", None);
    Fixture { day, topic }
}

/// A fresh vault under a temp dir, with the fixture written; closed.
fn fixture_vault() -> (TempDir, PathBuf, Fixture) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let mut vault = Vault::create(&path).unwrap();
    let fx = fixture(&mut vault);
    drop(vault);
    (dir, path, fx)
}

/// Copies the (closed) vault `from` to `to`, every file.
fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// A vault served in process over an rmcp duplex, as `test-agent`.
struct World {
    _dir: Option<TempDir>,
    state: Arc<AppState>,
    client: RunningService<RoleClient, ClientInfo>,
    server: JoinHandle<()>,
}

impl Drop for World {
    fn drop(&mut self) {
        self.server.abort();
    }
}

/// Serves the vault at `path` with `sessions` attached (none: `Memex::new`
/// alone).
async fn serve_vault(path: &Path, sessions: Option<Arc<dyn AgentSessions>>) -> World {
    let vault = Vault::open(path).unwrap();
    let state = Arc::new(AppState::new(vault, path.to_path_buf(), None));
    let mut memex = Memex::new(state.clone());
    if let Some(s) = sessions {
        memex = memex.with_sessions(s);
    }
    let (server_io, client_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(async move {
        if let Ok(running) = memex.serve(server_io).await {
            let _ = running.waiting().await;
        }
    });
    let client = client_info(CLIENT, "1.2.3")
        .serve(client_io)
        .await
        .expect("initialize handshake");
    World {
        _dir: None,
        state,
        client,
        server,
    }
}

/// A fresh fixture vault served with `sessions`.
async fn world(sessions: Option<Arc<dyn AgentSessions>>) -> (World, Fixture) {
    let (dir, path, fx) = fixture_vault();
    let mut w = serve_vault(&path, sessions).await;
    w._dir = Some(dir);
    (w, fx)
}

/// The text payload of a `CallToolResult`, parsed.
fn payload(result: &Value, tool: &str) -> Value {
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("{tool}: a text content: {result}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("{tool}: not JSON ({e}): {text}"))
}

impl World {
    /// Calls `tool` through the rmcp client; the whole `CallToolResult` as JSON.
    async fn call_raw(&self, tool: &str, args: Value) -> Value {
        let Value::Object(arguments) = args else {
            panic!("tool arguments are an object");
        };
        let call = self
            .client
            .call_tool(CallToolRequestParams::new(tool.to_string()).with_arguments(arguments));
        let result = tokio::time::timeout(CALL_TIMEOUT, call)
            .await
            .unwrap_or_else(|_| panic!("{tool}: no answer within {CALL_TIMEOUT:?}"))
            .unwrap_or_else(|e| panic!("call {tool}: {e}"));
        serde_json::to_value(result).expect("serialize CallToolResult")
    }

    /// Calls `tool`; its JSON payload.
    async fn call(&self, tool: &str, args: Value) -> Value {
        payload(&self.call_raw(tool, args).await, tool)
    }

    /// [`Self::call`], asserting the call succeeded.
    async fn ok(&self, tool: &str, args: Value) -> Value {
        let v = self.call(tool, args).await;
        assert!(v.get("error").is_none(), "{tool} failed: {v}");
        v
    }

    /// [`Self::call`], asserting the call failed.
    async fn err(&self, tool: &str, args: Value) -> Value {
        let v = self.call(tool, args).await;
        assert!(v.get("error").is_some(), "{tool} should fail: {v}");
        v
    }

    async fn rows(&self) -> Vec<ActivityEntry> {
        let vault = self.state.vault.lock().await;
        rows_in(vault.connection_ref())
    }

    async fn count(&self) -> usize {
        self.rows().await.len()
    }

    async fn revision(&self) -> i64 {
        let vault = self.state.vault.lock().await;
        revision_in(vault.connection_ref())
    }

    /// Calls `tool`, asserting success; its payload and the rows it appended.
    async fn logged(&self, tool: &str, args: Value) -> (Value, Vec<ActivityEntry>) {
        let before: HashSet<String> = self.rows().await.into_iter().map(|r| r.id).collect();
        let v = self.ok(tool, args).await;
        let new = self
            .rows()
            .await
            .into_iter()
            .filter(|r| !before.contains(&r.id))
            .collect();
        (v, new)
    }

    /// The one row a successful `tool` call appended; panics unless it
    /// appended exactly one.
    async fn one_row(&self, tool: &str, args: Value) -> (Value, ActivityEntry) {
        let (v, mut new) = self.logged(tool, args).await;
        assert_eq!(
            new.len(),
            1,
            "{tool}: one successful write adds one row: {new:?}"
        );
        (v, new.remove(0))
    }

    /// Asserts a call of `tool` appends no row; returns its payload.
    async fn no_row(&self, tool: &str, args: Value) -> Value {
        let before = self.count().await;
        let v = self.call(tool, args).await;
        assert_eq!(self.count().await, before, "{tool} must add no row: {v}");
        v
    }

    async fn sql(&self, sql: &str) {
        let vault = self.state.vault.lock().await;
        vault.connection_ref().execute_batch(sql).unwrap();
    }
}

/// Every `agent_activity` row, oldest first (created_at, then id).
fn rows_in(conn: &rusqlite::Connection) -> Vec<ActivityEntry> {
    let mut stmt = conn
        .prepare(
            "SELECT id, session_id, client_name, tool, summary, note_id, created_at
             FROM agent_activity ORDER BY created_at, id",
        )
        .unwrap();
    let rows = stmt
        .query_map([], |r| {
            Ok(ActivityEntry {
                id: r.get(0)?,
                session_id: r.get(1)?,
                client_name: r.get(2)?,
                tool: r.get(3)?,
                summary: r.get(4)?,
                note_id: r.get(5)?,
                created_at: r.get(6)?,
            })
        })
        .unwrap();
    rows.map(Result::unwrap).collect()
}

fn revision_in(conn: &rusqlite::Connection) -> i64 {
    conn.query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
        r.get(0)
    })
    .unwrap()
}

fn assert_is_ulid(id: &str) {
    let parsed = ulid::Ulid::from_string(id).unwrap_or_else(|e| panic!("{id} is a ULID ({e})"));
    assert_eq!(parsed.to_string(), id, "a canonical ULID string");
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("`{key}` is a string: {v}"))
}

/// Polls `f` in 1 ms steps until it returns `Some`.
async fn eventually<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    for _ in 0..POLLS {
        if let Some(v) = f() {
            return v;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    panic!("timed out waiting for {what}");
}

/// The presence record files in `vault`, as (file stem, JSON).
fn presence_records(vault: &Path) -> Vec<(String, Value)> {
    let Ok(entries) = fs::read_dir(presence_dir(vault)) else {
        return Vec::new();
    };
    entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "json"))
        .filter_map(|p| {
            let stem = p.file_stem()?.to_string_lossy().into_owned();
            let v = serde_json::from_slice(&fs::read(&p).ok()?).ok()?;
            Some((stem, v))
        })
        .collect()
}

// ---------- captured logs ----------

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

/// This test binary's `tracing` output (one process-wide subscriber: a
/// scoped one misses events while other tests run in parallel).
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

/// Whether `logs` holds a WARN line that mentions the activity log.
fn logs_activity_warning(logs: &str) -> bool {
    logs.lines()
        .any(|l| l.contains("WARN") && l.to_lowercase().contains("activity"))
}

// ======================================================================
// AC 1: stdio. One row under the presence record's session; a repeat of
// the same blocks adds none.
// ======================================================================

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

#[tokio::test]
async fn stdio_add_excerpt_logs_one_row_under_the_presence_session_and_a_repeat_adds_none() {
    let (_dir, path, fx) = fixture_vault();
    let vault = Vault::open(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path.clone(), None));
    let clock: SharedClock = Arc::new(FakeClock(AtomicI64::new(T0)));
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(serve_stdio_on(
        state.clone(),
        false,
        clock,
        Duration::from_millis(HEARTBEAT_MS as u64),
        server_io,
    ));
    let client = client_info("test-agent", "1.2.3")
        .serve(client_io)
        .await
        .expect("initialize handshake");
    let (session_id, record) = eventually("the stdio presence record", || {
        let mut all = presence_records(&path);
        (all.len() == 1).then(|| all.remove(0))
    })
    .await;
    assert_eq!(record["client_name"], json!("test-agent"), "{record}");

    let call = |args: Value| {
        let client = &client;
        async move {
            let Value::Object(arguments) = args else {
                unreachable!()
            };
            let result = tokio::time::timeout(
                CALL_TIMEOUT,
                client.call_tool(
                    CallToolRequestParams::new("add_excerpt".to_string()).with_arguments(arguments),
                ),
            )
            .await
            .expect("add_excerpt answers")
            .expect("tools/call add_excerpt");
            payload(&serde_json::to_value(result).unwrap(), "add_excerpt")
        }
    };
    let args = json!({ "topic_note_id": fx.topic, "date": DAY, "block_ids": [B7, C3] });

    let before_ms = now_unix_ms();
    let first = call(args.clone()).await;
    let after_ms = now_unix_ms();
    assert_eq!(first["filed_block_ids"], json!([B7, C3]), "{first}");
    let rows = rows_in(state.vault.lock().await.connection_ref());
    assert_eq!(rows.len(), 1, "exactly one row: {rows:?}");
    let row = &rows[0];
    assert_is_ulid(&row.id);
    assert_eq!(
        row.session_id, session_id,
        "the presence record's session_id"
    );
    assert_eq!(row.client_name, "test-agent");
    assert_eq!(row.tool, "add_excerpt");
    assert_eq!(row.summary, format!("filed 2 blocks → {TOPIC}"));
    assert_eq!(row.note_id.as_deref(), Some(fx.topic.as_str()), "the topic");
    assert!(
        (before_ms..=after_ms).contains(&row.created_at),
        "created_at is the stdio request clock's now (SystemClock): {} not in {before_ms}..={after_ms}",
        row.created_at
    );

    let again = call(args).await;
    assert_eq!(again["filed_block_ids"], json!([]), "{again}");
    let rows = rows_in(state.vault.lock().await.connection_ref());
    assert_eq!(
        rows.len(),
        1,
        "the repeat wrote nothing and adds no row: {rows:?}"
    );

    drop(client);
    let _ = tokio::time::timeout(CALL_TIMEOUT, server).await;
}

// ======================================================================
// AC 2: HTTP. Bridge headers log under the bridge session; a plain client
// under its own http session_id. created_at is the request clock.
// ======================================================================

/// One in-memory vault server over a temp root holding the vault `work`.
struct Http {
    _dir: TempDir,
    work: PathBuf,
    clock: Arc<FakeClock>,
    router: Router,
    fx: Fixture,
}

impl Http {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = std::path::absolute(dir.path().join("root")).unwrap();
        fs::create_dir(&root).unwrap();
        let work = root.join("work");
        let mut vault = Vault::create(&work).unwrap();
        let fx = fixture(&mut vault);
        drop(vault);
        let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
        let shared: SharedClock = clock.clone();
        let router = router(ServerConfig::new(root, TOKEN).with_clock(shared));
        Self {
            _dir: dir,
            work,
            clock,
            router,
            fx,
        }
    }

    /// POSTs `msg` to `/vaults/work/mcp` with `headers` from `peer`.
    async fn post(&self, headers: &[(&str, &str)], peer: SocketAddr, msg: &Value) -> Value {
        let mut req = Request::builder()
            .method("POST")
            .uri("/vaults/work/mcp")
            .header("host", "localhost")
            .header("authorization", format!("Bearer {TOKEN}"))
            .header("content-type", "application/json")
            .header("accept", ACCEPT);
        for (name, value) in headers {
            req = req.header(*name, *value);
        }
        let req = req
            .extension(ConnectInfo(peer))
            .body(Body::from(msg.to_string()))
            .unwrap();
        let resp = tokio::time::timeout(CALL_TIMEOUT, self.router.clone().oneshot(req))
            .await
            .expect("the server answers in time")
            .expect("router answers");
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("read body");
        let body: Value = serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| panic!("JSON body: {}", String::from_utf8_lossy(&bytes)));
        assert_eq!(status, StatusCode::OK, "MCP POST answers 200: {body}");
        assert!(body.get("error").is_none(), "a JSON-RPC result: {body}");
        body
    }

    /// A `tools/call` of `tool`; its payload, asserted successful.
    async fn tool(
        &self,
        headers: &[(&str, &str)],
        peer: SocketAddr,
        tool: &str,
        args: Value,
    ) -> Value {
        let msg = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": { "name": tool, "arguments": args },
        });
        let body = self.post(headers, peer, &msg).await;
        let v = payload(&body["result"], tool);
        assert!(v.get("error").is_none(), "{tool} failed: {v}");
        v
    }

    async fn ping(&self, headers: &[(&str, &str)], peer: SocketAddr) {
        let body = self
            .post(
                headers,
                peer,
                &json!({ "jsonrpc": "2.0", "id": 1, "method": "ping" }),
            )
            .await;
        assert!(body.get("result").is_some(), "a ping result: {body}");
    }

    fn db(&self) -> rusqlite::Connection {
        rusqlite::Connection::open_with_flags(
            self.work.join("memex.db"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap()
    }

    fn rows(&self) -> Vec<ActivityEntry> {
        rows_in(&self.db())
    }

    fn revision(&self) -> i64 {
        revision_in(&self.db())
    }

    fn excerpt_args(&self, ids: &[&str]) -> Value {
        json!({ "topic_note_id": self.fx.topic, "date": DAY, "block_ids": ids })
    }
}

fn peer(ip: [u8; 4]) -> SocketAddr {
    SocketAddr::from((ip, 50_000))
}

#[tokio::test]
async fn http_add_excerpt_with_bridge_headers_logs_one_row_under_the_bridge_session() {
    let h = Http::new();
    let session = ulid::Ulid::new().to_string();
    let headers = [
        (SESSION_HEADER, session.as_str()),
        (CLIENT_HEADER, "claude-ai/0.9.1"),
        ("user-agent", "memex-bridge/1.0"),
    ];
    h.clock.set(T0 + 1_234);
    let v = h
        .tool(
            &headers,
            peer([10, 0, 0, 1]),
            "add_excerpt",
            h.excerpt_args(&[B7, C3]),
        )
        .await;
    assert_eq!(v["filed_block_ids"], json!([B7, C3]), "{v}");

    let rows = h.rows();
    assert_eq!(rows.len(), 1, "exactly one row: {rows:?}");
    let row = &rows[0];
    assert_is_ulid(&row.id);
    assert_eq!(row.session_id, session, "the bridge session id");
    assert_eq!(row.client_name, "claude-ai", "the bridge's client");
    assert_eq!(row.tool, "add_excerpt");
    assert_eq!(row.summary, format!("filed 2 blocks → {TOPIC}"));
    assert_eq!(row.note_id.as_deref(), Some(h.fx.topic.as_str()));
    assert_eq!(
        row.created_at,
        T0 + 1_234,
        "created_at is the request clock (the server's clock)"
    );

    // The same blocks again wrote nothing.
    h.tool(
        &headers,
        peer([10, 0, 0, 1]),
        "add_excerpt",
        h.excerpt_args(&[B7, C3]),
    )
    .await;
    assert_eq!(h.rows().len(), 1, "a repeat adds no row");
}

#[tokio::test]
async fn http_add_excerpt_without_bridge_headers_logs_one_row_under_the_http_session() {
    let h = Http::new();
    let headers = [("user-agent", "claude-code/1.2.3 (darwin)")];
    let from = peer([10, 0, 0, 7]);
    h.clock.set(T0 + 7_000);
    h.tool(&headers, from, "add_excerpt", h.excerpt_args(&[B7, C3]))
        .await;

    let (session_id, record) = eventually("the http presence record", || {
        let mut all = presence_records(&h.work);
        (all.len() == 1).then(|| all.remove(0))
    })
    .await;
    assert_eq!(record["transport"], json!("http"), "{record}");
    assert_is_ulid(&session_id);

    let rows = h.rows();
    assert_eq!(rows.len(), 1, "exactly one row: {rows:?}");
    let row = &rows[0];
    assert_eq!(row.session_id, session_id, "the plain client's session_id");
    assert_eq!(row.client_name, "claude-code");
    assert_eq!(row.tool, "add_excerpt");
    assert_eq!(row.summary, format!("filed 2 blocks → {TOPIC}"));
    assert_eq!(row.created_at, T0 + 7_000);
}

// ======================================================================
// AC 5: a bridge ping adds zero rows and leaves content_revision.n.
// ======================================================================

#[tokio::test]
async fn a_bridge_ping_adds_zero_rows_and_leaves_content_revision_unchanged() {
    let h = Http::new();
    let session = ulid::Ulid::new().to_string();
    let headers = [
        (SESSION_HEADER, session.as_str()),
        (CLIENT_HEADER, "claude-ai/0.9.1"),
    ];
    let n = h.revision();
    for k in 0..3 {
        h.clock.set(T0 + k * 5_000);
        h.ping(&headers, peer([10, 0, 0, 1])).await;
    }
    assert_eq!(h.rows().len(), 0, "pings add no activity row");
    assert_eq!(h.revision(), n, "pings move no content revision");

    // Control: the same bridge's write is logged, so "zero" is not vacuous.
    h.tool(
        &headers,
        peer([10, 0, 0, 1]),
        "add_excerpt",
        h.excerpt_args(&[B7]),
    )
    .await;
    let rows = h.rows();
    assert_eq!(rows.len(), 1, "the bridge's write is logged: {rows:?}");
    assert_eq!(rows[0].session_id, session);
}

// ======================================================================
// AC 3: each "wrote nothing" signal of req 8 adds zero rows.
// ======================================================================

#[tokio::test]
async fn excerpt_tools_wrote_nothing_signals_add_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let excerpt =
        |ids: &[&str]| json!({ "topic_note_id": fx.topic, "date": DAY, "block_ids": ids });

    w.one_row("add_excerpt", excerpt(&[B7, C3])).await;
    let v = w.no_row("add_excerpt", excerpt(&[B7, C3])).await;
    assert_eq!(
        v["filed_block_ids"],
        json!([]),
        "filed_block_ids empty: {v}"
    );

    w.one_row("remove_excerpt", excerpt(&[B7, C3])).await;
    // #449 ruling: a remove of blocks not filed is not_found (an error), so
    // `removed_count: 0` never reaches the log.
    let v = w.no_row("remove_excerpt", excerpt(&[B7, C3])).await;
    assert!(v.get("error").is_some(), "{v}");

    w.one_row("add_excerpt", excerpt(&[F6])).await;
    let block = json!({ "topic_note_id": fx.topic, "date": DAY, "block_id": F6 });
    w.one_row("remove_excerpt_block", block.clone()).await;
    let v = w.no_row("remove_excerpt_block", block).await;
    assert!(v.get("error").is_some(), "{v}");
}

#[tokio::test]
async fn footer_and_link_tools_wrote_nothing_signals_add_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let note = str_of(
        &w.ok(
            "create_note",
            json!({ "title": "Plain", "content_md": "Body.\n" }),
        )
        .await,
        "note_id",
    )
    .to_string();
    assert_eq!(w.count().await, 1, "create_note always writes and logs");

    let chip = json!({ "note_id": note, "topic_note_id": fx.topic });
    w.one_row("add_footer_topic", chip.clone()).await;
    let v = w.no_row("add_footer_topic", chip).await;
    assert_eq!(v["changed"], json!(false), "{v}");

    // A body link (kind `references`), so update_link may change it.
    let link = json!({ "from_id": note, "to_id": fx.topic });
    let (added, _) = w.one_row("add_link", link.clone()).await;
    let v = w.no_row("add_link", link).await;
    assert_eq!(v["was_existing"], json!(true), "{v}");

    let link_id = str_of(&added, "link_id").to_string();
    let (updated, _) = w
        .one_row(
            "update_link",
            json!({ "link_id": link_id, "label": "the loop" }),
        )
        .await;
    // The rewritten link has a new id; the same label on it is a no-op.
    let again = json!({ "link_id": str_of(&updated, "link_id"), "label": "the loop" });
    let v = w.no_row("update_link", again).await;
    assert_eq!(v["changed"], json!(false), "{v}");
}

#[tokio::test]
async fn smart_folder_tools_wrote_nothing_signals_add_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let (folder, _) = w
        .one_row("create_smart_folder", json!({ "name": "Games" }))
        .await;
    let folder = str_of(&folder, "id").to_string();

    let v = w
        .no_row(
            "update_smart_folder",
            json!({ "id": folder, "name": "Games" }),
        )
        .await;
    assert_eq!(v["changed"], json!(false), "{v}");

    let member = json!({ "smart_folder_id": folder, "topic_note_id": fx.topic });
    w.one_row("add_to_smart_folder", member.clone()).await;
    let v = w.no_row("add_to_smart_folder", member.clone()).await;
    assert_eq!(v["added"], json!(false), "{v}");

    w.one_row("remove_from_smart_folder", member.clone()).await;
    let v = w.no_row("remove_from_smart_folder", member).await;
    assert_eq!(v["removed"], json!(false), "{v}");
}

#[tokio::test]
async fn tag_tools_wrote_nothing_signals_add_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let tag = json!({ "note_id": fx.topic, "tag": "work" });
    w.one_row("tag_note", tag.clone()).await;
    let v = w.no_row("tag_note", tag.clone()).await;
    assert_eq!(v["applied"], json!(false), "{v}");

    w.one_row("untag_note", tag.clone()).await;
    let v = w.no_row("untag_note", tag).await;
    assert_eq!(v["removed"], json!(false), "{v}");
}

#[tokio::test]
async fn canvas_tools_wrote_nothing_signals_add_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let (canvas, _) = w
        .one_row("create_canvas", json!({ "title": "Board" }))
        .await;
    let canvas = str_of(&canvas, "canvas_id").to_string();

    let place = json!({ "canvas_id": canvas, "note_id": fx.topic, "x": 1.0, "y": 2.0 });
    w.one_row("add_to_canvas", place.clone()).await;
    let v = w.no_row("add_to_canvas", place).await;
    assert_eq!(v["added"], json!(false), "{v}");

    let to = json!({ "canvas_id": canvas, "note_id": fx.topic, "x": 3.0, "y": 4.0 });
    w.one_row("move_node", to.clone()).await;
    let v = w.no_row("move_node", to).await;
    assert_eq!(v["changed"], json!(false), "{v}");

    let unplace = json!({ "canvas_id": canvas, "note_id": fx.topic });
    w.one_row("remove_from_canvas", unplace.clone()).await;
    let v = w.no_row("remove_from_canvas", unplace).await;
    assert_eq!(v["removed"], json!(false), "{v}");
}

// ======================================================================
// AC 4: an {"error": …} result and the read tools add zero rows.
// ======================================================================

#[tokio::test]
async fn a_write_tool_error_result_adds_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let before = w.count().await;
    w.err("tag_note", json!({ "note_id": UNKNOWN_ID, "tag": "work" }))
        .await;
    w.err(
        "add_excerpt",
        json!({ "topic_note_id": UNKNOWN_ID, "date": DAY, "block_ids": [B7] }),
    )
    .await;
    w.err(
        "create_note",
        json!({ "content_md": "x", "role": "nonsense" }),
    )
    .await;
    w.err("delete_smart_folder", json!({ "id": UNKNOWN_ID }))
        .await;
    assert_eq!(w.count().await, before, "failed calls add no row");

    // Control: the same world logs a successful write.
    w.one_row("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
}

#[tokio::test]
async fn read_tools_add_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let n = w.revision().await;
    w.ok("search", json!({ "query": "jump" })).await;
    w.ok("get_note", json!({ "note_id": fx.topic })).await;
    w.ok("list_tags", json!({})).await;
    w.ok("neighbors", json!({ "note_id": fx.topic })).await;
    assert_eq!(w.count().await, 0, "read tools add no row");
    assert_eq!(w.revision().await, n, "read tools move no revision");

    // Control: the same world logs a successful write.
    w.one_row("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
}

#[tokio::test]
async fn a_write_call_the_router_rejects_adds_zero_rows() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let n = w.revision().await;
    // `tag` is required: the router answers with a protocol error, not a
    // tool result, so the hook has nothing to log.
    let Value::Object(arguments) = json!({ "note_id": fx.topic }) else {
        unreachable!()
    };
    let rejected = w
        .client
        .call_tool(CallToolRequestParams::new("tag_note".to_string()).with_arguments(arguments))
        .await;
    assert!(rejected.is_err(), "missing params are a protocol error");
    // A call with no arguments at all is rejected the same way.
    let bare = w
        .client
        .call_tool(CallToolRequestParams::new("tag_note".to_string()))
        .await;
    assert!(bare.is_err(), "absent params are a protocol error");
    assert_eq!(w.count().await, 0, "a rejected call adds no row");
    assert_eq!(w.revision().await, n, "a rejected call moves no revision");

    // Control: the same world logs a successful write.
    w.one_row("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
}

// ======================================================================
// AC 6 / AC 10: every write tool in meta::write_tools() logs exactly one
// row through the hook, with its summary and note_id.
// ======================================================================

/// One logged call: what it appended and what it should have.
struct Check {
    tool: &'static str,
    new: Vec<ActivityEntry>,
    text: String,
    note_id: Option<String>,
}

#[tokio::test]
async fn every_write_tool_in_meta_write_tools_logs_exactly_one_row_with_its_summary() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let mut checks: Vec<Check> = Vec::new();
    macro_rules! step {
        ($tool:literal, $args:expr, |$v:ident| ($text:expr, $note:expr)) => {{
            let (v, new) = w.logged($tool, $args).await;
            let $v = &v;
            let (text, note_id): (String, Option<String>) = ($text.to_string(), $note);
            checks.push(Check {
                tool: $tool,
                new,
                text,
                note_id,
            });
            v
        }};
    }

    let topic = step!(
        "create_note",
        json!({ "title": "Jump Arc", "content_md": "About jumps.\n", "role": "topic" }),
        |v| (
            "created topic Jump Arc",
            Some(str_of(v, "note_id").to_string())
        )
    );
    let topic = str_of(&topic, "note_id").to_string();
    // No title: the summary takes the stored title, derived from line one (D32).
    let plain = step!(
        "create_note",
        json!({ "content_md": "# Plain Note\n\nBody.\n" }),
        |v| ("created Plain Note", Some(str_of(v, "note_id").to_string()))
    );
    let plain = str_of(&plain, "note_id").to_string();

    let excerpt = |ids: &[&str]| json!({ "topic_note_id": topic, "date": DAY, "block_ids": ids });
    step!("add_excerpt", excerpt(&[B7, C3, F6]), |_v| (
        "filed 3 blocks → Jump Arc",
        Some(topic.clone())
    ));
    step!(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": C3 }),
        |_v| ("unfiled 1 block from Jump Arc", Some(topic.clone()))
    );
    step!("remove_excerpt", excerpt(&[B7]), |_v| (
        "unfiled 1 block from Jump Arc",
        Some(topic.clone())
    ));
    step!(
        "add_footer_topic",
        json!({ "note_id": plain, "topic_note_id": topic }),
        |_v| ("added Jump Arc to Plain Note footer", Some(plain.clone()))
    );
    step!(
        "add_link",
        json!({ "from_id": plain, "to_id": topic, "kind": "extends" }),
        |_v| (
            "linked Plain Note → Jump Arc (extends)",
            Some(plain.clone())
        )
    );
    // update_link changes body links only: a note whose body links the topic.
    let source = step!(
        "create_note",
        json!({ "title": "Source", "content_md": "Hello [[Jump Arc]] world.\n" }),
        |v| ("created Source", Some(str_of(v, "note_id").to_string()))
    );
    let source = str_of(&source, "note_id").to_string();
    let got = w
        .ok(
            "get_note",
            json!({ "note_id": source, "include_backlinks": true }),
        )
        .await;
    let body_link = got["links"]["references"][0]["link_id"]
        .as_str()
        .unwrap_or_else(|| panic!("the [[Jump Arc]] link: {got}"))
        .to_string();
    step!(
        "update_link",
        json!({ "link_id": body_link, "kind": "extends" }),
        |_v| ("updated link Source → Jump Arc", Some(source.clone()))
    );

    let folder = step!("create_smart_folder", json!({ "name": "Games" }), |_v| (
        "created folder Games",
        None
    ));
    let folder = str_of(&folder, "id").to_string();
    step!(
        "update_smart_folder",
        json!({ "id": folder, "name": "Gaming" }),
        |_v| ("renamed folder Games → Gaming", None)
    );
    let member = json!({ "smart_folder_id": folder, "topic_note_id": topic });
    step!("add_to_smart_folder", member.clone(), |_v| (
        "added Jump Arc to Gaming",
        Some(topic.clone())
    ));
    step!("remove_from_smart_folder", member, |_v| (
        "removed Jump Arc from Gaming",
        Some(topic.clone())
    ));

    let tag = json!({ "note_id": plain, "tag": "work" });
    step!("tag_note", tag.clone(), |_v| (
        "tagged Plain Note #work",
        Some(plain.clone())
    ));
    step!("untag_note", tag, |_v| (
        "untagged Plain Note #work",
        Some(plain.clone())
    ));

    step!(
        "append_to_daily_note",
        json!({ "text": "Late thought.", "date": "2026-09-06" }),
        |v| (
            "captured 1 block on 2026-09-06",
            Some(str_of(v, "note_id").to_string())
        )
    );
    let changes = w.ok("get_daily_note_changes", json!({ "date": DAY })).await;
    step!(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [{ "note_id": fx.day, "bullets": ["Filed the day"] }],
        }),
        |_v| ("marked 2026-09-05 reviewed", Some(fx.day.clone()))
    );

    let canvas = step!("create_canvas", json!({ "title": "Board" }), |_v| (
        "created canvas Board",
        None
    ));
    let canvas = str_of(&canvas, "canvas_id").to_string();
    step!(
        "add_to_canvas",
        json!({ "canvas_id": canvas, "note_id": plain, "x": 1.0, "y": 2.0 }),
        |_v| ("placed Plain Note on Board", Some(plain.clone()))
    );
    step!(
        "move_node",
        json!({ "canvas_id": canvas, "note_id": plain, "x": 3.0, "y": 4.0 }),
        |_v| ("moved Plain Note on Board", Some(plain.clone()))
    );
    step!(
        "remove_from_canvas",
        json!({ "canvas_id": canvas, "note_id": plain }),
        |_v| ("removed Plain Note from Board", Some(plain.clone()))
    );
    let version = w.ok("get_canvas", json!({ "canvas_id": canvas })).await["version"].clone();
    step!(
        "delete_canvas",
        json!({ "canvas_id": canvas, "expected_version": version }),
        |_v| ("deleted canvas Board", None)
    );
    step!("delete_smart_folder", json!({ "id": folder }), |_v| (
        "deleted folder Gaming",
        None
    ));

    let guide = w.ok("get_vault_guide", json!({})).await;
    step!(
        "update_vault_guide",
        json!({
            "version": guide["version"],
            "content_md": "## Framework\n\nGames first.\n",
            "bullets": ["Added a rule"],
        }),
        |_v| ("updated Vault Guide", None)
    );
    step!(
        "record_feedback",
        json!({
            "text": "SENTINEL-FEEDBACK-TEXT keep topics broad.",
            "reply": "Noted",
            "changes": [{ "note_id": topic, "bullets": ["Noted the rule"] }],
        }),
        |_v| ("recorded feedback", None)
    );
    // An Open comment by the person on the day's Activity entry.
    let comment = {
        let mut vault = w.state.vault.lock().await;
        let change: String = vault
            .connection_ref()
            .query_row(
                "SELECT id FROM agent_changes WHERE note_id = ? ORDER BY rowid DESC LIMIT 1",
                [&fx.day],
                |r| r.get(0),
            )
            .unwrap();
        feedback::add(
            &mut vault,
            &fx.day,
            DAY,
            &change,
            "Wrong topic.",
            &memex_core::SystemClock,
        )
        .unwrap()
        .id
    };
    step!(
        "resolve_feedback",
        json!({ "id": comment, "reply": "Moved it" }),
        |_v| ("resolved feedback", None)
    );

    let called: BTreeSet<&str> = checks.iter().map(|c| c.tool).collect();
    let writes: BTreeSet<&str> = meta::write_tools().into_iter().collect();
    assert_eq!(
        called, writes,
        "this test calls every tool meta::write_tools() names, and only those"
    );

    let mut wrong = Vec::new();
    for c in &checks {
        match c.new.as_slice() {
            [row] => {
                let got = (
                    row.tool.as_str(),
                    row.summary.as_str(),
                    row.note_id.as_deref(),
                    row.session_id.as_str(),
                    row.client_name.as_str(),
                );
                let want = (
                    c.tool,
                    c.text.as_str(),
                    c.note_id.as_deref(),
                    SESSION,
                    CLIENT,
                );
                if got != want || ulid::Ulid::from_string(&row.id).is_err() {
                    wrong.push(format!(
                        "{}: got {got:?} (id {}), want {want:?}",
                        c.tool, row.id
                    ));
                }
                if row.summary.contains("SENTINEL") {
                    wrong.push(format!("{}: Feedback text in the summary", c.tool));
                }
            }
            rows => wrong.push(format!("{}: {} rows, want 1: {rows:?}", c.tool, rows.len())),
        }
    }
    assert!(
        wrong.is_empty(),
        "{} of {} calls logged wrong:\n{}",
        wrong.len(),
        checks.len(),
        wrong.join("\n")
    );
    assert_eq!(
        w.count().await,
        checks.len(),
        "no row from the read calls between"
    );
}

#[test]
fn summarize_covers_exactly_the_tools_meta_write_tools_names() {
    struct NoTitles;
    impl TitleLookup for NoTitles {
        fn note_title(&self, _: &str) -> Option<String> {
            None
        }
        fn folder_name(&self, _: &str) -> Option<String> {
            None
        }
        fn canvas_title(&self, _: &str) -> Option<String> {
            None
        }
    }
    // A representative successful result: every count non-zero, no flag
    // saying "wrote nothing".
    let result = json!({ "filed_block_ids": ["b7k2m9"], "removed_count": 1 });
    let pre = PreSnapshot::default();

    let writes: BTreeSet<&str> = meta::write_tools().into_iter().collect();
    let summarized: BTreeSet<&str> = meta::tools()
        .iter()
        .map(|t| t.name)
        .filter(|name| summarize(name, &json!({}), &pre, &result, &NoTitles).is_some())
        .collect();
    assert_eq!(
        summarized, writes,
        "summarize returns Some for exactly the write tools"
    );
    assert_eq!(
        WRITE_TOOLS.iter().copied().collect::<BTreeSet<_>>(),
        writes,
        "activity_summary::WRITE_TOOLS (as a set) == meta::write_tools() (D11)"
    );
}

// ======================================================================
// AC 7: pruning to the newest 1,000 through the hook.
// ======================================================================

#[tokio::test]
async fn a_logged_write_on_a_full_table_keeps_the_newest_1000() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    {
        let vault = w.state.vault.lock().await;
        let conn = vault.connection_ref();
        let tx = conn.unchecked_transaction().unwrap();
        for i in 0..KEEP {
            tx.execute(
                "INSERT INTO agent_activity
                 (id, session_id, client_name, tool, summary, note_id, created_at)
                 VALUES (?, 'OLD', 'old-agent', 'tag_note', 'tagged x #y', NULL, ?)",
                params![format!("01H0{i:022}"), 1_000 + i as i64],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    let (_, row) = w
        .one_row("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
    let rows = w.rows().await;
    assert_eq!(rows.len(), KEEP, "pruned to 1,000");
    assert_eq!(
        rows.last().map(|r| &r.id),
        Some(&row.id),
        "the new row is the newest"
    );
    assert!(
        !rows.iter().any(|r| r.id == format!("01H0{:022}", 0)),
        "the oldest row is pruned"
    );
}

// ======================================================================
// AC 8: a failed insert leaves the tool's result as an unlogged call's and
// logs a warning.
// ======================================================================

#[tokio::test]
async fn with_the_insert_forced_to_fail_the_result_equals_an_unlogged_call_and_a_warning_is_logged()
{
    let logs = captured_logs();
    let (dir, base, fx) = fixture_vault();
    let logged_path = dir.path().join("logged");
    let plain_path = dir.path().join("plain");
    copy_dir(&base, &logged_path);
    copy_dir(&base, &plain_path);

    let plain = serve_vault(&plain_path, None).await;
    let logged = serve_vault(&logged_path, Some(FixedSession::some())).await;
    logged.sql(FAIL_INSERTS).await;

    let args = json!({ "topic_note_id": fx.topic, "date": DAY, "block_ids": [B7, C3] });
    let want = plain.call_raw("add_excerpt", args.clone()).await;
    let mark = logs.len();
    let got = logged.call_raw("add_excerpt", args.clone()).await;
    let text = logs.text_since(mark);

    assert_eq!(
        got, want,
        "the tool's result is unchanged by a failed insert"
    );
    assert_eq!(
        payload(&got, "add_excerpt")["filed_block_ids"],
        json!([B7, C3])
    );
    assert_eq!(logged.count().await, 0, "the insert failed");
    let again = logged.call("add_excerpt", args).await;
    assert_eq!(
        again["filed_block_ids"],
        json!([]),
        "the tool's own write committed: {again}"
    );
    assert!(
        logs_activity_warning(&text),
        "the failed activity insert is logged at WARN:\n{text}"
    );
}

#[tokio::test]
async fn a_logged_call_returns_the_same_result_as_an_unlogged_call() {
    let (dir, base, fx) = fixture_vault();
    let logged_path = dir.path().join("logged");
    let plain_path = dir.path().join("plain");
    copy_dir(&base, &logged_path);
    copy_dir(&base, &plain_path);
    let plain = serve_vault(&plain_path, None).await;
    let logged = serve_vault(&logged_path, Some(FixedSession::some())).await;

    let args = json!({ "topic_note_id": fx.topic, "date": DAY, "block_ids": [B7, C3] });
    let want = plain.call_raw("add_excerpt", args.clone()).await;
    let got = logged.call_raw("add_excerpt", args).await;
    assert_eq!(got, want, "logging never changes the tool's result");
    assert_eq!(logged.count().await, 1, "and the call was logged");
    assert_eq!(plain.count().await, 0, "the unlogged server wrote no row");
}

// ======================================================================
// AC 9: names taken before the call.
// ======================================================================

#[tokio::test]
async fn delete_smart_folder_logs_the_folder_name_taken_before_the_call() {
    let (w, _) = world(Some(FixedSession::some())).await;
    let folder = w
        .ok("create_smart_folder", json!({ "name": "Games" }))
        .await;
    let (_, row) = w
        .one_row(
            "delete_smart_folder",
            json!({ "id": str_of(&folder, "id") }),
        )
        .await;
    assert_eq!(row.summary, "deleted folder Games");
    assert_eq!(row.note_id, None);
}

#[tokio::test]
async fn delete_canvas_logs_the_canvas_title_taken_before_the_call() {
    let (w, _) = world(Some(FixedSession::some())).await;
    let canvas = w.ok("create_canvas", json!({ "title": "Board" })).await;
    let (_, row) = w
        .one_row(
            "delete_canvas",
            json!({ "canvas_id": str_of(&canvas, "canvas_id"), "expected_version": canvas["version"] }),
        )
        .await;
    assert_eq!(row.summary, "deleted canvas Board");
    assert_eq!(row.note_id, None);
}

#[tokio::test]
async fn renaming_a_folder_logs_the_old_and_new_names() {
    let (w, _) = world(Some(FixedSession::some())).await;
    let folder = w
        .ok("create_smart_folder", json!({ "name": "Games" }))
        .await;
    let (_, row) = w
        .one_row(
            "update_smart_folder",
            json!({ "id": str_of(&folder, "id"), "name": "Gaming" }),
        )
        .await;
    assert_eq!(row.summary, "renamed folder Games → Gaming");
}

#[tokio::test]
async fn moving_a_folder_logs_moved_and_a_rename_with_a_move_logs_both() {
    let (w, _) = world(Some(FixedSession::some())).await;
    let parent = w
        .ok("create_smart_folder", json!({ "name": "Parent" }))
        .await;
    let parent = str_of(&parent, "id").to_string();
    let other = w
        .ok("create_smart_folder", json!({ "name": "Other" }))
        .await;
    let other = str_of(&other, "id").to_string();
    let folder = w
        .ok("create_smart_folder", json!({ "name": "Games" }))
        .await;
    let folder = str_of(&folder, "id").to_string();

    let (_, row) = w
        .one_row(
            "update_smart_folder",
            json!({ "id": folder, "parent_id": parent }),
        )
        .await;
    assert_eq!(row.summary, "moved folder Games", "root → Parent");

    let (_, row) = w
        .one_row(
            "update_smart_folder",
            json!({ "id": folder, "parent_id": other }),
        )
        .await;
    assert_eq!(row.summary, "moved folder Games", "Parent → Other");

    // The old parent comes from before the call: a move to the root.
    let (_, row) = w
        .one_row(
            "update_smart_folder",
            json!({ "id": folder, "to_root": true }),
        )
        .await;
    assert_eq!(row.summary, "moved folder Games", "Other → root");

    let (_, row) = w
        .one_row(
            "update_smart_folder",
            json!({ "id": folder, "name": "Gaming", "parent_id": parent }),
        )
        .await;
    assert_eq!(row.summary, "renamed and moved folder Games → Gaming");
}

#[tokio::test]
async fn update_link_logs_the_endpoint_titles() {
    let (w, fx) = world(Some(FixedSession::some())).await;
    let source = w
        .ok(
            "create_note",
            json!({ "title": "Source", "content_md": "Body.\n" }),
        )
        .await;
    let source = str_of(&source, "note_id").to_string();
    let link = w
        .ok("add_link", json!({ "from_id": source, "to_id": fx.topic }))
        .await;
    let (_, row) = w
        .one_row(
            "update_link",
            json!({ "link_id": str_of(&link, "link_id"), "kind": "extends" }),
        )
        .await;
    assert_eq!(row.summary, format!("updated link Source → {TOPIC}"));
    assert_eq!(row.note_id.as_deref(), Some(source.as_str()));
}

// ======================================================================
// AC 11 / req 7: no session, no row; a non-serve CLI write adds none.
// ======================================================================

#[tokio::test]
async fn a_write_without_a_session_adds_no_row() {
    let (bare, fx) = world(None).await;
    bare.ok("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
    assert_eq!(bare.count().await, 0, "Memex::new alone logs nothing");

    let (no_identity, fx) = world(Some(FixedSession::none())).await;
    no_identity
        .ok("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
    assert_eq!(
        no_identity.count().await,
        0,
        "a seam that returns no session logs nothing"
    );

    // Control: the same call with a session is logged.
    let (with, fx) = world(Some(FixedSession::some())).await;
    with.one_row("tag_note", json!({ "note_id": fx.topic, "tag": "work" }))
        .await;
}

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
fn a_non_serve_cli_write_adds_no_agent_activity_row() {
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

    let db = rusqlite::Connection::open(vault.join("memex.db")).unwrap();
    let tagged: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM tags WHERE note_id = ? AND tag = 'work'",
            [&note],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(tagged, 1, "precondition: the CLI write happened");
    assert!(
        rows_in(&db).is_empty(),
        "MemexCli-style writes log no activity"
    );
}
