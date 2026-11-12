//! WI #447 (Spec #390 req 2a, 5): the `memex serve --remote` bridge's agent
//! identity headers and its `ping` heartbeat.
//!
//! Every test drives `server::bridge::run` (or `run_with`) in-process over a
//! duplex pipe, against the real vault server router (P3's agent presence
//! included) served on `127.0.0.1:0` in the same runtime behind a recording
//! front ([`World`]). The front records every request with the fake clock's
//! time, and can answer pings with a fixed HTTP status or drop every
//! connection (the server can't be reached).
//!
//! Time: each test runs on a paused current-thread tokio clock with
//! auto-advance held off ([`HoldTime`]), so time moves only when the test
//! calls [`World::at`], which moves the fake `Clock` (shared by the bridge
//! and the server) and tokio time in lockstep. Network round trips happen
//! with time stopped. Waits for events spin on `yield_now` under a
//! wall-clock cap; no test sleeps longer than 1 ms at a time.

#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::HeaderValue;
use axum::response::Response;
use axum::Router;
use memex_core::agents::presence::{self, presence_dir, PresenceRecord, Transport, BRIDGE_TTL_MS};
use memex_core::{Clock, FixedOffset};
use memex_mcp::server::bridge::{self, BridgeOptions, Heartbeat};
use memex_mcp::server::request_clock::SharedClock;
use memex_mcp::server::{router, ServerConfig};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, DuplexStream, WriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;
use tower::ServiceExt;
use ulid::Ulid;

use server::{make_vault, BODY_LIMIT, TEST_TOKEN};

/// The fake clock's time when a test starts (ms epoch, 2023-11-14).
const T0: i64 = 1_700_000_000_000;
/// The default heartbeat interval the WI names (5 s).
const FIVE_S: i64 = 5_000;
const SESSION_HEADER: &str = "x-memex-agent-session";
const CLIENT_HEADER: &str = "x-memex-agent-client";
const OFFSET_HEADER: &str = "x-memex-utc-offset";
const MCP_PATH: &str = "/vaults/work/mcp";
const INFO_PATH: &str = "/vaults/work/api/v1/info";
/// How long an absence check lets in-flight requests land (wall clock).
const SETTLE: Duration = Duration::from_millis(40);
/// The wall-clock cap on waiting for one event (a request or a reply).
const EVENT_WAIT: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// A `Clock` the test sets by hand, at UTC.
struct FakeClock(AtomicI64);

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }

    fn utc_offset_at(&self, _now_ms: i64) -> FixedOffset {
        FixedOffset::east_opt(0).expect("UTC")
    }
}

/// Keeps tokio's paused clock from auto-advancing while it lives: a
/// running blocking task inhibits auto-advance on a current-thread runtime
/// (tokio `test-util`), so time moves only through `tokio::time::advance`,
/// and a network wait never jumps a timer.
struct HoldTime(Option<std::sync::mpsc::Sender<()>>);

impl HoldTime {
    fn new() -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        tokio::task::spawn_blocking(move || {
            let _ = rx.recv();
        });
        Self(Some(tx))
    }
}

impl Drop for HoldTime {
    fn drop(&mut self) {
        self.0.take();
    }
}

/// Spins until `done` holds, letting the runtime's other tasks and I/O run;
/// panics after [`EVENT_WAIT`] of wall-clock time.
async fn until(what: &str, done: impl Fn() -> bool) {
    let started = Instant::now();
    let mut spins = 0u32;
    while !done() {
        assert!(
            started.elapsed() < EVENT_WAIT,
            "{what} after {EVENT_WAIT:?}"
        );
        tokio::task::yield_now().await;
        spins += 1;
        if spins.is_multiple_of(64) {
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

/// Lets in-flight requests land for [`SETTLE`] of wall-clock time, with
/// tokio time stopped.
async fn settle() {
    let started = Instant::now();
    let mut spins = 0u32;
    while started.elapsed() < SETTLE {
        tokio::task::yield_now().await;
        spins += 1;
        if spins.is_multiple_of(64) {
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

// ---------------------------------------------------------------------------
// The vault server and its recording front
// ---------------------------------------------------------------------------

/// One request the front received.
#[derive(Clone, Debug)]
struct Seen {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: String,
    /// The fake clock's time when it arrived.
    at: i64,
}

impl Seen {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    fn header_values(&self, name: &str) -> Vec<&str> {
        self.headers
            .iter()
            .filter(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    fn rpc(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or(Value::Null)
    }

    fn rpc_method(&self) -> Option<String> {
        self.rpc()["method"].as_str().map(str::to_string)
    }

    fn is_mcp_post(&self) -> bool {
        self.method == "POST" && self.path == MCP_PATH
    }
}

/// The front forwards to the server.
const FORWARD: u8 = 0;
/// The front's listener drops every connection it accepts.
const DOWN: u8 = 1;

struct FrontState {
    router: Router,
    clock: Arc<FakeClock>,
    seen: Arc<Mutex<Vec<Seen>>>,
    /// When set, every `ping` POST is answered with this status instead of
    /// being forwarded (it is still recorded).
    ping_status: Arc<Mutex<Option<u16>>>,
    /// While set, a `ping` POST is recorded and then never answered.
    hang_pings: Arc<AtomicBool>,
    /// How many unanswered pings were abandoned (their request dropped).
    abandoned: Arc<AtomicUsize>,
}

/// Counts a hung request's drop: the bridge gave up on it.
struct Abandoned(Arc<AtomicUsize>);

impl Drop for Abandoned {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

async fn front(State(st): State<Arc<FrontState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let bytes = axum::body::to_bytes(body, BODY_LIMIT)
        .await
        .unwrap_or_default();
    let seen = Seen {
        method: parts.method.as_str().to_string(),
        path: parts.uri.path().to_string(),
        headers: parts
            .headers
            .iter()
            .map(|(k, v)| {
                (
                    k.as_str().to_ascii_lowercase(),
                    String::from_utf8_lossy(v.as_bytes()).into_owned(),
                )
            })
            .collect(),
        body: String::from_utf8_lossy(&bytes).into_owned(),
        at: st.clock.now_ms(),
    };
    let is_ping = seen.is_mcp_post() && seen.rpc_method().as_deref() == Some("ping");
    st.seen.lock().unwrap().push(seen);
    if is_ping && st.hang_pings.load(Ordering::SeqCst) {
        let _abandoned = Abandoned(st.abandoned.clone());
        std::future::pending::<()>().await;
    }
    let canned = *st.ping_status.lock().unwrap();
    let mut resp = match canned.filter(|_| is_ping) {
        Some(status) => {
            let code = if status == 401 {
                "unauthorized"
            } else {
                "internal"
            };
            let body = json!({ "error": { "code": code, "message": "canned" } });
            axum::http::Response::builder()
                .status(status)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .expect("canned response")
        }
        None => {
            let req = axum::http::Request::from_parts(parts, Body::from(bytes));
            match st.router.clone().oneshot(req).await {
                Ok(resp) => resp,
                Err(never) => match never {},
            }
        }
    };
    // One request per connection, so a switch to DOWN applies to the next.
    resp.headers_mut()
        .insert("connection", HeaderValue::from_static("close"));
    resp
}

/// A listener that, while the mode is [`DOWN`], drops every connection.
struct GateListener {
    inner: TcpListener,
    mode: Arc<AtomicU8>,
    dropped: Arc<AtomicUsize>,
}

impl axum::serve::Listener for GateListener {
    type Io = TcpStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (TcpStream, SocketAddr) {
        loop {
            match self.inner.accept().await {
                Ok((stream, addr)) => {
                    if self.mode.load(Ordering::SeqCst) == DOWN {
                        self.dropped.fetch_add(1, Ordering::SeqCst);
                        drop(stream);
                        continue;
                    }
                    return (stream, addr);
                }
                Err(_) => tokio::task::yield_now().await,
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<SocketAddr> {
        self.inner.local_addr()
    }
}

/// The vault server over a temp root holding `work`, its recording front,
/// the fake clock both it and the bridge read, and the held tokio clock.
struct World {
    _dir: TempDir,
    root: PathBuf,
    clock: Arc<FakeClock>,
    seen: Arc<Mutex<Vec<Seen>>>,
    ping_status: Arc<Mutex<Option<u16>>>,
    hang_pings: Arc<AtomicBool>,
    abandoned: Arc<AtomicUsize>,
    mode: Arc<AtomicU8>,
    dropped: Arc<AtomicUsize>,
    /// Every JSON-RPC `id` a test client sent.
    client_ids: Arc<Mutex<Vec<Value>>>,
    addr: SocketAddr,
    server: JoinHandle<()>,
    start: tokio::time::Instant,
    _hold: HoldTime,
}

impl World {
    async fn new() -> Self {
        let hold = HoldTime::new();
        let dir = tempfile::tempdir().expect("temp root");
        let root = dir.path().join("root");
        std::fs::create_dir(&root).expect("root dir");
        make_vault(&root, "work");
        let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
        let shared: SharedClock = clock.clone();
        let router = router(ServerConfig::new(root.clone(), TEST_TOKEN).with_clock(shared));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let ping_status = Arc::new(Mutex::new(None));
        let hang_pings = Arc::new(AtomicBool::new(false));
        let abandoned = Arc::new(AtomicUsize::new(0));
        let mode = Arc::new(AtomicU8::new(FORWARD));
        let dropped = Arc::new(AtomicUsize::new(0));
        let state = Arc::new(FrontState {
            router,
            clock: clock.clone(),
            seen: seen.clone(),
            ping_status: ping_status.clone(),
            hang_pings: hang_pings.clone(),
            abandoned: abandoned.clone(),
        });
        let app = Router::new().fallback(front).with_state(state);
        let inner = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = inner.local_addr().expect("front addr");
        let listener = GateListener {
            inner,
            mode: mode.clone(),
            dropped: dropped.clone(),
        };
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self {
            _dir: dir,
            root,
            clock,
            seen,
            ping_status,
            hang_pings,
            abandoned,
            mode,
            dropped,
            client_ids: Arc::new(Mutex::new(Vec::new())),
            addr,
            server,
            start: tokio::time::Instant::now(),
            _hold: hold,
        }
    }

    fn url(&self) -> String {
        format!("http://{}{MCP_PATH}", self.addr)
    }

    /// Sets the fake clock to `T0 + offset_ms` and moves paused tokio time
    /// to the same offset from the start, firing every timer due by then.
    async fn at(&self, offset_ms: i64) {
        self.clock.0.store(T0 + offset_ms, Ordering::SeqCst);
        let target = self.start + Duration::from_millis(offset_ms as u64);
        let now = tokio::time::Instant::now();
        if target > now {
            tokio::time::advance(target - now).await;
        }
        tokio::task::yield_now().await;
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    /// Every POST to the vault's `/mcp`.
    fn mcp_posts(&self) -> Vec<Seen> {
        self.seen().into_iter().filter(Seen::is_mcp_post).collect()
    }

    /// The bridge's own pings: `ping` POSTs whose id no client sent.
    fn pings(&self) -> Vec<Seen> {
        let client_ids = self.client_ids.lock().unwrap().clone();
        self.mcp_posts()
            .into_iter()
            .filter(|s| {
                s.rpc_method().as_deref() == Some("ping") && !client_ids.contains(&s.rpc()["id"])
            })
            .collect()
    }

    fn preflights(&self) -> usize {
        self.seen()
            .iter()
            .filter(|s| s.method == "GET" && s.path == INFO_PATH)
            .count()
    }

    /// Answers every `ping` with `status` (`None`: forward again).
    fn fail_pings(&self, status: Option<u16>) {
        *self.ping_status.lock().unwrap() = status;
    }

    /// While `hang` holds, a `ping` is recorded and never answered.
    fn hang_pings(&self, hang: bool) {
        self.hang_pings.store(hang, Ordering::SeqCst);
    }

    /// How many hung pings the bridge gave up on.
    fn abandoned(&self) -> usize {
        self.abandoned.load(Ordering::SeqCst)
    }

    fn set_down(&self, down: bool) {
        self.mode
            .store(if down { DOWN } else { FORWARD }, Ordering::SeqCst);
    }

    fn dropped(&self) -> usize {
        self.dropped.load(Ordering::SeqCst)
    }

    /// The presence records of `work`.
    fn records(&self) -> Vec<PresenceRecord> {
        presence::read_all(&presence_dir(&self.root.join("work")))
    }

    /// Waits until the bridge has sent `n` pings, then lets anything else in
    /// flight land, and checks no further ping came.
    async fn expect_pings(&self, n: usize, what: &str) {
        until(&format!("{what}: ping {n} reaches the server"), || {
            self.pings().len() >= n
        })
        .await;
        settle().await;
        assert_eq!(
            self.pings().len(),
            n,
            "{what}: exactly {n} pings so far: {:?}",
            self.pings()
        );
    }

    /// Lets in-flight requests land and checks the bridge has sent exactly
    /// `n` pings.
    async fn expect_still(&self, n: usize, what: &str) {
        settle().await;
        assert_eq!(
            self.pings().len(),
            n,
            "{what}: still {n} pings: {:?}",
            self.pings()
        );
    }
}

impl Drop for World {
    fn drop(&mut self) {
        self.server.abort();
    }
}

// ---------------------------------------------------------------------------
// The bridge under test
// ---------------------------------------------------------------------------

/// `bridge::run` (or `run_with`) on a duplex pipe: the test writes the
/// client's lines and collects every line the bridge writes.
struct Bridge {
    task: Option<JoinHandle<anyhow::Result<()>>>,
    input: Option<WriteHalf<DuplexStream>>,
    stdout: Arc<Mutex<Vec<String>>>,
    reader: JoinHandle<()>,
    client_ids: Arc<Mutex<Vec<Value>>>,
}

impl Bridge {
    /// Starts the bridge against `world` (`heartbeat: None` is plain
    /// `bridge::run`) and waits for its preflight.
    async fn start(world: &World, heartbeat: Option<Heartbeat>) -> Self {
        let preflights = world.preflights();
        let shared: SharedClock = world.clock.clone();
        let options = BridgeOptions {
            url: world.url(),
            token: TEST_TOKEN.to_string(),
            clock: shared,
        };
        let (bridge_io, client_io) = tokio::io::duplex(1 << 20);
        let (bridge_in, bridge_out) = tokio::io::split(bridge_io);
        let (client_in, client_out) = tokio::io::split(client_io);
        let task = match heartbeat {
            None => tokio::spawn(bridge::run(options, bridge_in, bridge_out)),
            Some(hb) => tokio::spawn(bridge::run_with(options, hb, bridge_in, bridge_out)),
        };
        let stdout = Arc::new(Mutex::new(Vec::new()));
        let sink = stdout.clone();
        let reader = tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(client_in).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                sink.lock().unwrap().push(line);
            }
        });
        until("the bridge's preflight", || {
            assert!(
                !task.is_finished(),
                "bridge::run ended before its preflight"
            );
            world.preflights() > preflights
        })
        .await;
        Self {
            task: Some(task),
            input: Some(client_out),
            stdout,
            reader,
            client_ids: world.client_ids.clone(),
        }
    }

    /// Writes `msg` as one line.
    async fn send(&mut self, msg: &Value) {
        if let Some(id) = msg.get("id") {
            self.client_ids.lock().unwrap().push(id.clone());
        }
        let input = self.input.as_mut().expect("the bridge's input is open");
        input
            .write_all(format!("{msg}\n").as_bytes())
            .await
            .expect("write to the bridge");
        input.flush().await.expect("flush");
    }

    /// Every line the bridge wrote so far, as JSON.
    fn stdout(&self) -> Vec<Value> {
        self.stdout
            .lock()
            .unwrap()
            .iter()
            .map(|l| {
                serde_json::from_str(l).unwrap_or_else(|e| panic!("stdout line is JSON ({e}): {l}"))
            })
            .collect()
    }

    /// The reply to `id` on stdout; panics if the bridge ends first.
    async fn recv(&self, id: Value) -> Value {
        let found = || self.stdout().into_iter().find(|v| v["id"] == id);
        until(&format!("a reply to {id} on stdout"), || {
            if let Some(task) = &self.task {
                assert!(
                    !task.is_finished() || found().is_some(),
                    "bridge::run ended before replying to {id}"
                );
            }
            found().is_some()
        })
        .await;
        found().expect("reply")
    }

    /// `initialize` (id 1) with `client_info` (none when `Null`), its reply,
    /// then `notifications/initialized`.
    async fn handshake(&mut self, client_info: Value) {
        self.send(&initialize(1, client_info)).await;
        let reply = self.recv(json!(1)).await;
        assert!(reply["result"].is_object(), "initialize succeeds: {reply}");
        self.send(&initialized()).await;
    }

    fn running(&self) -> bool {
        self.task.as_ref().is_some_and(|t| !t.is_finished())
    }

    /// Closes the bridge's input and waits for `run` to return.
    async fn close(&mut self) -> anyhow::Result<()> {
        let mut input = self.input.take().expect("the bridge's input is open");
        input.shutdown().await.expect("close the bridge's input");
        drop(input);
        let task = self.task.take().expect("bridge task");
        until("bridge::run returns after its input closes", || {
            task.is_finished()
        })
        .await;
        task.await.expect("bridge task")
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        if let Some(task) = &self.task {
            task.abort();
        }
        self.reader.abort();
    }
}

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

fn request(id: Value, method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

fn client_info(name: &str, version: &str) -> Value {
    json!({ "name": name, "version": version })
}

fn initialize(id: i64, client_info: Value) -> Value {
    let mut params = json!({ "protocolVersion": "2025-03-26", "capabilities": {} });
    if !client_info.is_null() {
        params["clientInfo"] = client_info;
    }
    request(json!(id), "initialize", params)
}

fn initialized() -> Value {
    json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
}

fn tools_list(id: i64) -> Value {
    request(json!(id), "tools/list", json!({}))
}

fn tool_call(id: i64, tool: &str, arguments: Value) -> Value {
    request(
        json!(id),
        "tools/call",
        json!({ "name": tool, "arguments": arguments }),
    )
}

/// The single `X-Memex-Agent-Session` value of `s`, checked to be a ULID.
fn session_of(s: &Seen) -> String {
    let values = s.header_values(SESSION_HEADER);
    assert_eq!(values.len(), 1, "one {SESSION_HEADER} header: {s:?}");
    let session = values[0].to_string();
    assert_eq!(session.len(), 26, "{SESSION_HEADER} is a ULID: {s:?}");
    Ulid::from_string(&session)
        .unwrap_or_else(|e| panic!("{SESSION_HEADER} is a ULID ({e}): {s:?}"));
    session
}

/// The ids of `lines`, sorted, as JSON text.
fn ids_of(lines: &[Value]) -> Vec<String> {
    let mut ids: Vec<String> = lines.iter().map(|v| v["id"].to_string()).collect();
    ids.sort();
    ids
}

// ---------------------------------------------------------------------------
// AC 1: identity headers on every request and ping
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn bridge_sends_the_same_session_and_client_headers_on_every_request_and_ping() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;

    // initialize and the requests right behind it go out back to back, so
    // they are forwarded concurrently: each must still carry the identity.
    b.send(&initialize(1, client_info("test-agent", "1.2.3")))
        .await;
    b.send(&initialized()).await;
    b.send(&tools_list(2)).await;
    b.send(&tool_call(3, "list_tags", json!({}))).await;
    for id in 1..=3 {
        b.recv(json!(id)).await;
    }
    world.at(FIVE_S).await;
    world.expect_pings(1, "after 5 s").await;
    world.at(2 * FIVE_S).await;
    world.expect_pings(2, "after 10 s").await;
    b.send(&tools_list(4)).await;
    b.recv(json!(4)).await;
    assert!(b.close().await.is_ok());

    let posts = world.mcp_posts();
    let methods: Vec<Option<String>> = posts.iter().map(Seen::rpc_method).collect();
    for m in [
        "initialize",
        "notifications/initialized",
        "tools/list",
        "tools/call",
    ] {
        assert!(
            methods.contains(&Some(m.to_string())),
            "{m} was forwarded: {methods:?}"
        );
    }
    assert_eq!(world.pings().len(), 2, "{posts:?}");

    let init = posts
        .iter()
        .find(|s| s.rpc_method().as_deref() == Some("initialize"))
        .expect("initialize forwarded");
    let session = session_of(init);
    assert_eq!(
        init.header(CLIENT_HEADER),
        Some("test-agent/1.2.3"),
        "the initialize request itself carries the client: {init:?}"
    );
    for s in &posts {
        assert_eq!(session_of(s), session, "the same session throughout: {s:?}");
        assert_eq!(
            s.header_values(CLIENT_HEADER),
            vec!["test-agent/1.2.3"],
            "one client header on every request and ping: {s:?}"
        );
        assert_eq!(
            s.header("authorization"),
            Some(format!("Bearer {TEST_TOKEN}").as_str()),
            "the token is unchanged: {s:?}"
        );
        assert_eq!(
            s.header(OFFSET_HEADER),
            Some("+00:00"),
            "the UTC offset is unchanged: {s:?}"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn each_bridge_run_makes_its_own_session_id() {
    let world = World::new().await;
    let mut sessions = Vec::new();
    for run in 0..2 {
        let before = world.mcp_posts().len();
        let mut b = Bridge::start(&world, None).await;
        b.handshake(client_info("test-agent", "1.2.3")).await;
        b.send(&tools_list(2)).await;
        b.recv(json!(2)).await;
        assert!(b.close().await.is_ok());
        let posts: Vec<Seen> = world.mcp_posts().into_iter().skip(before).collect();
        assert_eq!(posts.len(), 3, "run {run}: {posts:?}");
        let session = session_of(&posts[0]);
        for s in &posts {
            assert_eq!(session_of(s), session, "run {run}: one session: {s:?}");
        }
        sessions.push(session);
    }
    assert_ne!(
        sessions[0], sessions[1],
        "each bridge run makes a new session id"
    );
}

// ---------------------------------------------------------------------------
// AC 2: one ping per interval after initialize, none before
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn bridge_pings_once_per_five_seconds_after_initialize_and_never_before() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;

    // Stdin is open but the client hasn't initialized: no ping.
    world.at(12_000).await;
    world.expect_still(0, "before any client line").await;
    // A line that isn't initialize starts nothing either.
    b.send(&tools_list(7)).await;
    b.recv(json!(7)).await;
    world.at(14_000).await;
    world.expect_still(0, "after a non-initialize line").await;

    // initialize at 14 s: pings at 19, 24, 29, 34 s and never in between.
    b.handshake(client_info("test-agent", "1.2.3")).await;
    let initialized_at = 14_000;
    for k in 1..=4 {
        let due = initialized_at + k * FIVE_S;
        world.at(due - 1).await;
        world
            .expect_still(k as usize - 1, &format!("1 ms before ping {k}"))
            .await;
        world.at(due).await;
        world
            .expect_pings(k as usize, &format!("at {due} ms"))
            .await;
        assert!(b.running(), "the bridge keeps running");
    }

    let pings = world.pings();
    let ats: Vec<i64> = pings.iter().map(|s| s.at - T0).collect();
    assert_eq!(ats, vec![19_000, 24_000, 29_000, 34_000], "{pings:?}");
    for s in &pings {
        let rpc = s.rpc();
        assert_eq!(rpc["jsonrpc"], "2.0", "{s:?}");
        assert_eq!(rpc["method"], "ping", "{s:?}");
        assert!(rpc["id"].is_string(), "a bridge-private string id: {s:?}");
    }
    assert!(b.close().await.is_ok());
}

#[tokio::test(start_paused = true)]
async fn bridge_heartbeat_interval_comes_from_run_with() {
    let world = World::new().await;
    let heartbeat = Heartbeat {
        interval: Duration::from_millis(2_000),
    };
    let mut b = Bridge::start(&world, Some(heartbeat)).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    for k in 1..=3 {
        world.at(k * 2_000 - 1).await;
        world
            .expect_still(k as usize - 1, &format!("1 ms before ping {k}"))
            .await;
        world.at(k * 2_000).await;
        world
            .expect_pings(k as usize, &format!("at {} ms", k * 2_000))
            .await;
    }
    assert!(b.close().await.is_ok());
}

// ---------------------------------------------------------------------------
// AC 3: stdout holds the client's replies only
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn bridge_stdout_holds_only_the_replies_to_the_clients_own_requests() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    b.send(&tools_list(2)).await;
    // The client's own pings, with a number and a string id, are answered.
    b.send(&request(json!(3), "ping", json!({}))).await;
    b.send(&request(json!("client-ping"), "ping", json!({})))
        .await;
    for id in [json!(2), json!(3), json!("client-ping")] {
        b.recv(id).await;
    }
    for k in 1..=3 {
        world.at(k * FIVE_S).await;
        world.expect_pings(k as usize, "while stdin is open").await;
    }
    b.send(&tools_list(4)).await;
    b.recv(json!(4)).await;
    assert!(b.close().await.is_ok());

    let lines = b.stdout();
    assert_eq!(
        ids_of(&lines),
        vec!["\"client-ping\"", "1", "2", "3", "4"],
        "exactly one line per client request: {lines:?}"
    );
    for line in &lines {
        assert!(line["result"].is_object(), "a reply: {line}");
    }
    let ping_ids: Vec<Value> = world
        .pings()
        .iter()
        .map(|s| s.rpc()["id"].clone())
        .collect();
    assert_eq!(ping_ids.len(), 3);
    for line in &lines {
        assert!(
            !ping_ids.contains(&line["id"]),
            "no ping reply on stdout: {line}"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 4: a failed ping is ignored and the next interval pings again
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn a_failed_ping_writes_nothing_and_the_next_interval_pings_again() {
    for failure in ["http 500", "http 401", "unreachable"] {
        let world = World::new().await;
        let mut b = Bridge::start(&world, None).await;
        b.handshake(client_info("test-agent", "1.2.3")).await;
        match failure {
            "http 500" => world.fail_pings(Some(500)),
            "http 401" => world.fail_pings(Some(401)),
            _ => world.set_down(true),
        }

        for k in 1..=2 {
            world.at(k * FIVE_S).await;
            if failure == "unreachable" {
                let dropped = k as usize;
                until(
                    &format!("{failure}: ping attempt {k} reaches the listener"),
                    || world.dropped() >= dropped,
                )
                .await;
                settle().await;
            } else {
                world
                    .expect_pings(k as usize, &format!("{failure}: failing ping {k}"))
                    .await;
            }
            assert!(
                b.running(),
                "{failure}: a failed ping doesn't end the bridge"
            );
            assert_eq!(
                ids_of(&b.stdout()),
                vec!["1"],
                "{failure}: a failed ping writes nothing to stdout"
            );
        }

        // The server is back: the next interval pings, and the client's
        // requests still go through.
        world.fail_pings(None);
        world.set_down(false);
        let before = world.pings().len();
        world.at(3 * FIVE_S).await;
        world
            .expect_pings(before + 1, &format!("{failure}: the next interval"))
            .await;
        let last = world.pings().last().cloned().expect("a ping");
        assert_eq!(last.at - T0, 3 * FIVE_S, "{failure}: {last:?}");
        session_of(&last);
        b.send(&tools_list(2)).await;
        b.recv(json!(2)).await;
        assert!(b.running(), "{failure}: the bridge is still running");
        assert!(b.close().await.is_ok(), "{failure}: run ends Ok");
        assert_eq!(
            ids_of(&b.stdout()),
            vec!["1", "2"],
            "{failure}: stdout holds the client's replies only"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 5: stdin EOF stops the heartbeat
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn stdin_eof_stops_the_heartbeat_and_run_returns_ok() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    world.at(FIVE_S).await;
    world.expect_pings(1, "after 5 s").await;
    world.at(2 * FIVE_S).await;
    world.expect_pings(2, "after 10 s").await;

    // Close mid-interval.
    world.at(12_500).await;
    let res = b.close().await;
    assert!(res.is_ok(), "input EOF is Ok: {res:?}");
    let posts = world.mcp_posts().len();

    for k in 3..=12 {
        world.at(k * FIVE_S).await;
    }
    world.expect_still(2, "a minute after stdin closed").await;
    assert_eq!(
        world.mcp_posts().len(),
        posts,
        "nothing is sent after run returns: {:?}",
        world.mcp_posts()
    );
}

// ---------------------------------------------------------------------------
// AC 6: P3's bridge record lives while pinging, expires 15 s after the last
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn the_bridge_record_lives_while_pinging_and_expires_15_s_after_the_last_ping() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    let session = session_of(&world.mcp_posts()[0]);

    for k in 1..=4 {
        world.at(k * FIVE_S).await;
        world.expect_pings(k as usize, "while stdin is open").await;
        let now = T0 + k * FIVE_S;
        let records = world.records();
        assert_eq!(records.len(), 1, "one record at {now}: {records:?}");
        let rec = &records[0];
        assert_eq!(rec.transport, Transport::Bridge, "{rec:?}");
        assert_eq!(
            rec.session_id, session,
            "keyed on the bridge session: {rec:?}"
        );
        assert_eq!(rec.client_name, "test-agent", "{rec:?}");
        assert_eq!(rec.client_version.as_deref(), Some("1.2.3"), "{rec:?}");
        assert!(
            !presence::is_expired(rec, now),
            "the pings keep the record live at {now}: {rec:?}"
        );
    }

    // stdin closes right after the ping at 20 s.
    assert!(b.close().await.is_ok());
    world.at(25_000).await;
    settle().await;
    let records = world.records();
    assert_eq!(records.len(), 1, "{records:?}");
    let rec = records[0].clone();
    assert_eq!(rec.session_id, session, "{rec:?}");
    assert_eq!(rec.last_seen_at, T0 + 4 * FIVE_S, "the last ping: {rec:?}");
    assert_eq!(
        rec.expires_at,
        T0 + 4 * FIVE_S + BRIDGE_TTL_MS,
        "15 s after the last ping: {rec:?}"
    );

    world.at(34_999).await;
    let rec = world.records().pop().expect("the record");
    assert!(
        !presence::is_expired(&rec, T0 + 34_999),
        "live until 15 s after the last ping: {rec:?}"
    );
    world.at(35_000).await;
    let rec = world.records().pop().expect("the record");
    assert!(
        presence::is_expired(&rec, T0 + 35_000),
        "expired 15 s after the last ping: {rec:?}"
    );
}

// ---------------------------------------------------------------------------
// AC 7: pings leave memex.db untouched
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn pings_leave_memex_db_untouched() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;

    let db = rusqlite::Connection::open(world.root.join("work").join("memex.db"))
        .expect("open a second connection to memex.db");
    let data_version = || -> i64 {
        db.query_row("PRAGMA data_version", [], |r| r.get(0))
            .expect("PRAGMA data_version")
    };
    let before = data_version();
    for k in 1..=3 {
        world.at(k * FIVE_S).await;
        world.expect_pings(k as usize, "pinging").await;
    }
    assert_eq!(data_version(), before, "three pings changed no revision");

    // The probe sees a real write.
    b.send(&tool_call(
        2,
        "create_note",
        json!({ "title": "Bridged", "content_md": "through the bridge" }),
    ))
    .await;
    let reply = b.recv(json!(2)).await;
    assert!(reply["result"].is_object(), "create_note succeeds: {reply}");
    assert_ne!(data_version(), before, "a write moves data_version");
    assert!(b.close().await.is_ok());
}

// ---------------------------------------------------------------------------
// AC 8: a client name that isn't a header value omits the client header
// ---------------------------------------------------------------------------

#[tokio::test(start_paused = true)]
async fn a_client_name_that_is_no_header_value_omits_the_client_header() {
    let cases = [
        ("a newline in the name", client_info("bad\nagent", "1.0")),
        (
            "a carriage return in the version",
            client_info("agent", "1.0\r"),
        ),
        ("a tab in the name", client_info("tab\tagent", "1.0")),
        ("DEL in the name", client_info("agent\u{7f}", "1.0")),
        ("a non-ASCII name", client_info("agént", "1.0")),
        ("a non-ASCII version", client_info("agent", "1.0-β")),
    ];
    for (case, info) in cases {
        let world = World::new().await;
        let mut b = Bridge::start(&world, None).await;
        b.handshake(info).await;
        b.send(&tools_list(2)).await;
        b.recv(json!(2)).await;
        world.at(FIVE_S).await;
        world.expect_pings(1, case).await;
        assert!(b.close().await.is_ok(), "{case}");

        let posts = world.mcp_posts();
        assert_eq!(posts.len(), 4, "{case}: {posts:?}");
        let session = session_of(&posts[0]);
        for s in &posts {
            assert_eq!(
                session_of(s),
                session,
                "{case}: the session header is still sent: {s:?}"
            );
            assert!(
                s.header_values(CLIENT_HEADER).is_empty(),
                "{case}: no client header: {s:?}"
            );
        }
    }
}

#[tokio::test(start_paused = true)]
async fn a_client_name_of_visible_ascii_edges_is_sent_as_is() {
    // Space (0x20) and `~` (0x7E) are the ends of the visible-ASCII range.
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("my agent~", "!1.0 rc~")).await;
    world.at(FIVE_S).await;
    world.expect_pings(1, "visible ASCII").await;
    assert!(b.close().await.is_ok());
    for s in world.mcp_posts() {
        session_of(&s);
        assert_eq!(
            s.header_values(CLIENT_HEADER),
            vec!["my agent~/!1.0 rc~"],
            "{s:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// Contracts the bridge's docs promise
// ---------------------------------------------------------------------------

/// `initialize` (id 1) with `info`, its reply (any: the server may refuse
/// what it can't parse), then `notifications/initialized`.
async fn raw_handshake(b: &mut Bridge, info: Value) {
    b.send(&initialize(1, info)).await;
    b.recv(json!(1)).await;
    b.send(&initialized()).await;
}

#[tokio::test(start_paused = true)]
async fn a_client_info_without_a_string_name_and_version_omits_the_client_header() {
    let cases = [
        ("no clientInfo", Value::Null),
        ("clientInfo is not an object", json!("test-agent/1.2.3")),
        ("no name", json!({ "version": "1.2.3" })),
        ("no version", json!({ "name": "test-agent" })),
        ("a number for a name", json!({ "name": 7, "version": "1" })),
        (
            "a number for a version",
            json!({ "name": "agent", "version": 1 }),
        ),
        (
            "a null version",
            json!({ "name": "agent", "version": Value::Null }),
        ),
    ];
    for (case, info) in cases {
        let world = World::new().await;
        let mut b = Bridge::start(&world, None).await;
        raw_handshake(&mut b, info).await;
        world.at(FIVE_S).await;
        world.expect_pings(1, case).await;
        assert!(b.close().await.is_ok(), "{case}");

        let posts = world.mcp_posts();
        assert!(posts.len() >= 3, "{case}: {posts:?}");
        let session = session_of(&posts[0]);
        for s in &posts {
            assert_eq!(
                session_of(s),
                session,
                "{case}: the session header is still sent: {s:?}"
            );
            assert!(
                s.header_values(CLIENT_HEADER).is_empty(),
                "{case}: no client header: {s:?}"
            );
        }
    }
}

#[tokio::test(start_paused = true)]
async fn a_later_initialize_replaces_the_client_header_and_keeps_one_heartbeat() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    b.send(&initialize(2, client_info("other-agent", "9.9")))
        .await;
    b.recv(json!(2)).await;

    // A second initialize starts no second heartbeat: one ping per interval.
    world.at(FIVE_S).await;
    world.expect_pings(1, "after 5 s").await;
    assert_eq!(
        world.pings()[0].header_values(CLIENT_HEADER),
        vec!["other-agent/9.9"],
        "the latest initialize names the client"
    );

    // An initialize that names no client clears the header again.
    b.send(&initialize(3, Value::Null)).await;
    b.recv(json!(3)).await;
    world.at(2 * FIVE_S).await;
    world.expect_pings(2, "after 10 s").await;
    assert!(
        world.pings()[1].header_values(CLIENT_HEADER).is_empty(),
        "no clientInfo, no client header: {:?}",
        world.pings()[1]
    );
    assert!(b.close().await.is_ok());

    let posts = world.mcp_posts();
    let initialize_of = |id: i64| -> Seen {
        posts
            .iter()
            .find(|s| s.rpc()["id"] == json!(id) && s.rpc_method().as_deref() == Some("initialize"))
            .cloned()
            .unwrap_or_else(|| panic!("initialize {id} was forwarded: {posts:?}"))
    };
    assert_eq!(
        initialize_of(1).header_values(CLIENT_HEADER),
        vec!["test-agent/1.2.3"]
    );
    assert_eq!(
        initialize_of(2).header_values(CLIENT_HEADER),
        vec!["other-agent/9.9"],
        "the second initialize carries its own client"
    );
    assert!(initialize_of(3).header_values(CLIENT_HEADER).is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_batched_initialize_names_the_client_and_starts_the_heartbeat() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    let batch = json!([
        tools_list(5),
        initialize(1, client_info("test-agent", "1.2.3")),
    ]);
    let input = b.input.as_mut().expect("input");
    input
        .write_all(format!("{batch}\n").as_bytes())
        .await
        .expect("write the batch");
    input.flush().await.expect("flush");
    until("the batch reaches the server", || {
        !world.mcp_posts().is_empty()
    })
    .await;
    world.at(FIVE_S).await;
    world.expect_pings(1, "after a batched initialize").await;
    assert!(b.close().await.is_ok());

    for s in world.mcp_posts() {
        assert_eq!(
            s.header_values(CLIENT_HEADER),
            vec!["test-agent/1.2.3"],
            "the batch and the ping carry the client: {s:?}"
        );
        session_of(&s);
    }
}

#[tokio::test(start_paused = true)]
async fn an_initialize_notification_without_an_id_names_no_client_and_starts_no_heartbeat() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.send(&json!({
        "jsonrpc": "2.0",
        "method": "initialize",
        "params": { "clientInfo": client_info("test-agent", "1.2.3") },
    }))
    .await;
    until("the notification reaches the server", || {
        !world.mcp_posts().is_empty()
    })
    .await;
    world.at(2 * FIVE_S).await;
    world
        .expect_still(0, "after an initialize without an id")
        .await;
    assert!(b.close().await.is_ok());
    for s in world.mcp_posts() {
        assert!(
            s.header_values(CLIENT_HEADER).is_empty(),
            "a request without an id is no initialize: {s:?}"
        );
        session_of(&s);
    }
}

#[tokio::test(start_paused = true)]
async fn heartbeat_pings_use_distinct_string_ids_in_the_bridge_namespace() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    for k in 1..=3 {
        world.at(k * FIVE_S).await;
        world.expect_pings(k as usize, "pinging").await;
    }
    assert!(b.close().await.is_ok());
    let ids: Vec<String> = world
        .pings()
        .iter()
        .map(|s| {
            s.rpc()["id"]
                .as_str()
                .unwrap_or_else(|| panic!("a string id: {s:?}"))
                .to_string()
        })
        .collect();
    let mut distinct = ids.clone();
    distinct.sort();
    distinct.dedup();
    assert_eq!(distinct.len(), 3, "every ping has its own id: {ids:?}");
    for id in &ids {
        assert!(id.starts_with("memex-bridge-ping-"), "{id}");
    }
}

#[tokio::test(start_paused = true)]
async fn a_long_pause_sends_one_ping_and_then_resumes_the_interval() {
    // A machine that slept through three intervals pings once on waking,
    // not three times in a row.
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    world.at(3 * FIVE_S + 2_000).await;
    world.expect_pings(1, "after waking").await;
    world.at(4 * FIVE_S + 1_999).await;
    world
        .expect_still(1, "1 ms before the interval after waking")
        .await;
    world.at(4 * FIVE_S + 2_000).await;
    world.expect_pings(2, "one interval after waking").await;
    assert!(b.close().await.is_ok());
    let ats: Vec<i64> = world.pings().iter().map(|s| s.at - T0).collect();
    assert_eq!(ats, vec![17_000, 22_000], "{:?}", world.pings());
}

#[tokio::test(start_paused = true)]
async fn a_slow_ping_never_delays_the_next_and_is_dropped_after_one_interval() {
    let world = World::new().await;
    let mut b = Bridge::start(&world, None).await;
    b.handshake(client_info("test-agent", "1.2.3")).await;
    world.hang_pings(true);

    world.at(FIVE_S).await;
    world.expect_pings(1, "the first, unanswered").await;
    world.at(2 * FIVE_S - 1).await;
    world.expect_still(1, "1 ms before the second").await;
    assert_eq!(
        world.abandoned(),
        0,
        "ping 1 is still waiting for its reply"
    );

    // The second goes out although the first never came back, and the
    // first is given up on exactly one interval after it was sent.
    world.at(2 * FIVE_S).await;
    world
        .expect_pings(2, "the second, while the first hangs")
        .await;
    until("the first ping is dropped after one interval", || {
        world.abandoned() >= 1
    })
    .await;
    assert!(b.running(), "a hung ping doesn't end the bridge");
    assert_eq!(ids_of(&b.stdout()), vec!["1"], "and writes nothing");
    assert!(b.close().await.is_ok());
}
