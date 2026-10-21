//! WI #95 (R5): `memex serve --remote <server-url>/vaults/<name>/mcp`, the
//! stdio bridge to a hosted vault (req 27, 28, 59; D3, D6).
//!
//! The bridge runs as the built `memex` binary ([`Bridge`]), spoken to over
//! newline-delimited JSON-RPC on its stdin and stdout, as `append_tools.rs`
//! does. It talks to the in-process vault server ([`TestServer`]), usually
//! through a [`Proxy`] in this test process that records every request
//! (method, path, headers, body) and can be switched to drop every
//! connection (an outage) or to forward with a rotated token (the server
//! starts answering 401). `TZ` and `MEMEX_ACCESS_TOKEN` are set on the child
//! only, and every child is stopped through its own handle.
//!
//! One test drives `server::bridge::run` in-process with a clock whose
//! offset the test moves between requests, to pin that the offset header is
//! read again for every request (D6: that is how daylight saving is
//! handled).

#[path = "support/server.rs"]
mod server;

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, AtomicU8, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::{Request, State};
use axum::response::{IntoResponse, Response};
use axum::Router;
use memex_core::{Clock, FixedOffset};
use memex_mcp::caller_tz::parse_utc_offset;
use memex_mcp::server::bridge::{self, BridgeOptions};
use memex_mcp::server::request_clock::SharedClock;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

use server::{
    client, free_port, make_vault, Reply, TestServer, BODY_LIMIT, TEST_TOKEN, TOKEN_ENV, WAIT,
};

/// The number of tools `Memex::new` composes, over stdio or HTTP.
const TOOL_COUNT: usize = 26;

/// What an MCP streamable-HTTP client must accept on a POST.
const ACCEPT: &str = "application/json, text/event-stream";

/// The offset header the bridge sends.
const OFFSET_HEADER: &str = "x-memex-utc-offset";

/// The client name the tests' `initialize` carries.
const CLIENT_NAME: &str = "wi95-test";

/// The token the rotated-token proxy mode forwards instead of the real one.
const ROTATED_TOKEN: &str = "wi95-rotated-away-token-0000000000000000";

/// A token the server never accepted.
const WRONG_TOKEN: &str = "wi95-wrong-token-7d1e4b9a2c6f8e3d5a0b";

/// Proxy environment the child must not inherit (the bridge talks to
/// 127.0.0.1 directly).
const PROXY_ENV: [&str; 6] = [
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
];

// ---------------------------------------------------------------------------
// JSON-RPC helpers
// ---------------------------------------------------------------------------

/// `/vaults/<vault>/mcp`.
fn mcp_path(vault: &str) -> String {
    format!("/vaults/{vault}/mcp")
}

/// `/vaults/<vault>/api/v1/info`, the preflight path.
fn info_path(vault: &str) -> String {
    format!("/vaults/{vault}/api/v1/info")
}

fn request(id: i64, method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

fn initialize(id: i64) -> Value {
    request(
        id,
        "initialize",
        json!({
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": { "name": CLIENT_NAME, "version": "0" },
        }),
    )
}

fn initialized() -> Value {
    json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
}

fn tool_call(id: i64, tool: &str, arguments: Value) -> Value {
    request(
        id,
        "tools/call",
        json!({ "name": tool, "arguments": arguments }),
    )
}

/// The `result` of a JSON-RPC success response; panics otherwise.
fn result_of(resp: &Value) -> Value {
    assert_eq!(resp["jsonrpc"], "2.0", "a JSON-RPC response: {resp}");
    assert!(
        resp.get("error").is_none(),
        "a JSON-RPC result, not an error: {resp}"
    );
    assert!(resp["result"].is_object(), "a result object: {resp}");
    resp["result"].clone()
}

/// A tool's JSON payload: the tools return one text content holding JSON.
fn tool_payload(result: &Value) -> Value {
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("a text content: {result}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("tool text is not JSON ({e}): {text}"))
}

/// `tools/list` tools keyed by name.
fn by_name(tools: &Value) -> BTreeMap<String, Value> {
    tools
        .as_array()
        .unwrap_or_else(|| panic!("a tools array: {tools}"))
        .iter()
        .map(|t| {
            (
                t["name"].as_str().expect("tool name").to_string(),
                t.clone(),
            )
        })
        .collect()
}

/// POSTs one JSON-RPC message straight to the server's `/vaults/<vault>/mcp`
/// with the test token, bypassing the bridge, and returns the reply body.
async fn direct(srv: &TestServer, vault: &str, msg: &Value) -> Value {
    let resp = client()
        .post(srv.url(&mcp_path(vault)))
        .header("content-type", "application/json")
        .header("accept", ACCEPT)
        .header("authorization", srv.bearer())
        .body(msg.to_string())
        .send()
        .await
        .expect("send direct MCP POST");
    let reply = Reply::read(resp).await;
    assert_eq!(reply.status, 200, "direct MCP POST: {}", reply.body);
    reply.json()
}

/// `memex get --vault <vault> --note-id <id>` (no token in its env).
fn cli_get(vault: &Path, id: &str) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["get", "--vault", vault.to_str().unwrap(), "--note-id", id])
        .env_remove(TOKEN_ENV)
        .stdin(Stdio::null())
        .output()
        .expect("run memex get");
    assert!(
        out.status.success(),
        "memex get: exit={:?} stdout={} stderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("memex get prints JSON")
}

/// Exactly one non-empty stderr line, a C1 object with a string code and
/// message; returns its `error.code`.
fn one_c1_code(stderr: &str) -> String {
    let lines: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(lines.len(), 1, "exactly one C1 line on stderr: {stderr:?}");
    let v: Value = serde_json::from_str(lines[0])
        .unwrap_or_else(|e| panic!("the stderr line is JSON ({e}): {:?}", lines[0]));
    assert!(
        v["error"]["message"].is_string(),
        "a C1 line has a string message: {v}"
    );
    v["error"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("a C1 line has a string code: {v}"))
        .to_string()
}

/// AC 11: `secret` appears on neither stream.
fn assert_token_not_printed(what: &str, secret: &str, stdout: &str, stderr: &str) {
    assert!(!secret.is_empty(), "{what}: checking an empty token");
    assert!(
        !stdout.contains(secret),
        "{what}: the token leaked on stdout: {stdout:?}"
    );
    assert!(
        !stderr.contains(secret),
        "{what}: the token leaked on stderr: {stderr:?}"
    );
}

/// Polls `done` until it holds; panics with `what` after [`WAIT`].
async fn eventually(what: &str, done: impl Fn() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < WAIT, "{what} after {WAIT:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

// ---------------------------------------------------------------------------
// Recording, switchable proxy
// ---------------------------------------------------------------------------

/// What the proxy does with the next connection or request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
enum Mode {
    /// Forward to the server unchanged.
    Forward = 0,
    /// Accept each connection and close it at once: the server can't be
    /// reached.
    Down = 1,
    /// Forward with a token the server doesn't accept, so it answers its own
    /// 401 `unauthorized` (the token was rotated).
    RotatedToken = 2,
}

impl Mode {
    fn load(cell: &AtomicU8) -> Self {
        match cell.load(Ordering::SeqCst) {
            0 => Mode::Forward,
            1 => Mode::Down,
            _ => Mode::RotatedToken,
        }
    }
}

/// One request the proxy received.
#[derive(Clone, Debug)]
struct Seen {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl Seen {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    /// Every value of header `name`.
    fn header_values(&self, name: &str) -> Vec<&str> {
        self.headers
            .iter()
            .filter(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    /// The JSON-RPC `method` of the body, when it is one message.
    fn rpc_method(&self) -> Option<String> {
        let v: Value = serde_json::from_str(&self.body).ok()?;
        v["method"].as_str().map(str::to_string)
    }

    fn rpc_body(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or(Value::Null)
    }
}

struct ProxyState {
    upstream: SocketAddr,
    mode: Arc<AtomicU8>,
    seen: Arc<Mutex<Vec<Seen>>>,
    http: reqwest::Client,
}

/// A reverse proxy on `127.0.0.1:0` in front of a [`TestServer`]. Every
/// response carries `Connection: close`, so each request opens a new
/// connection and a switch to [`Mode::Down`] applies to the very next one.
struct Proxy {
    addr: SocketAddr,
    mode: Arc<AtomicU8>,
    seen: Arc<Mutex<Vec<Seen>>>,
    task: JoinHandle<()>,
}

/// A listener that, in [`Mode::Down`], closes every connection it accepts.
struct GateListener {
    inner: TcpListener,
    mode: Arc<AtomicU8>,
}

impl axum::serve::Listener for GateListener {
    type Io = TcpStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (TcpStream, SocketAddr) {
        loop {
            match self.inner.accept().await {
                Ok((stream, addr)) => {
                    if Mode::load(&self.mode) == Mode::Down {
                        drop(stream);
                        continue;
                    }
                    return (stream, addr);
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(5)).await,
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<SocketAddr> {
        self.inner.local_addr()
    }
}

impl Proxy {
    async fn start(upstream: SocketAddr) -> Self {
        let mode = Arc::new(AtomicU8::new(Mode::Forward as u8));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let state = Arc::new(ProxyState {
            upstream,
            mode: mode.clone(),
            seen: seen.clone(),
            http: client(),
        });
        let app = Router::new().fallback(proxy_handle).with_state(state);
        let inner = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind proxy on 127.0.0.1:0");
        let addr = inner.local_addr().expect("proxy addr");
        let listener = GateListener {
            inner,
            mode: mode.clone(),
        };
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("proxy serve");
        });
        Self {
            addr,
            mode,
            seen,
            task,
        }
    }

    fn set(&self, mode: Mode) {
        self.mode.store(mode as u8, Ordering::SeqCst);
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    /// The POSTs whose JSON-RPC method is `method`.
    fn rpc(&self, method: &str) -> Vec<Seen> {
        self.seen()
            .into_iter()
            .filter(|s| s.method == "POST" && s.rpc_method().as_deref() == Some(method))
            .collect()
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Hop-by-hop or recomputed headers the proxy never copies.
fn skip_header(name: &str) -> bool {
    matches!(
        name,
        "host" | "content-length" | "connection" | "transfer-encoding" | "keep-alive"
    )
}

async fn proxy_handle(State(st): State<Arc<ProxyState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let bytes = axum::body::to_bytes(body, BODY_LIMIT)
        .await
        .unwrap_or_default();
    let path = parts
        .uri
        .path_and_query()
        .map(|p| p.as_str().to_string())
        .unwrap_or_else(|| parts.uri.path().to_string());
    st.seen.lock().unwrap().push(Seen {
        method: parts.method.as_str().to_string(),
        path: path.clone(),
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
    });

    let mode = Mode::load(&st.mode);
    let method = reqwest::Method::from_bytes(parts.method.as_str().as_bytes()).expect("method");
    let mut out = st
        .http
        .request(method, format!("http://{}{}", st.upstream, path));
    for (k, v) in parts.headers.iter() {
        let name = k.as_str();
        if skip_header(name) || (mode == Mode::RotatedToken && name == "authorization") {
            continue;
        }
        out = out.header(name, v.as_bytes());
    }
    if mode == Mode::RotatedToken {
        out = out.header("authorization", format!("Bearer {ROTATED_TOKEN}"));
    }
    let resp = match out.body(bytes.to_vec()).send().await {
        Ok(resp) => resp,
        Err(e) => return (axum::http::StatusCode::BAD_GATEWAY, e.to_string()).into_response(),
    };
    let status = resp.status().as_u16();
    let headers: Vec<(String, Vec<u8>)> = resp
        .headers()
        .iter()
        .map(|(k, v)| (k.as_str().to_string(), v.as_bytes().to_vec()))
        .collect();
    let body = resp.bytes().await.unwrap_or_default();
    let mut builder = axum::http::Response::builder().status(status);
    for (k, v) in headers {
        if !skip_header(&k) {
            builder = builder.header(k, v);
        }
    }
    builder
        .header("connection", "close")
        .body(Body::from(body))
        .expect("proxy response")
}

// ---------------------------------------------------------------------------
// The bridge child process
// ---------------------------------------------------------------------------

/// A running `memex serve --remote <url>` with piped stdin and stdout,
/// killed through its own handle on drop.
struct Bridge {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    stdout_all: Arc<Mutex<String>>,
    stderr_path: PathBuf,
    _scratch: TempDir,
}

impl Bridge {
    /// Spawns the bridge with `TZ=<tz>` and, when `token` is `Some`,
    /// `MEMEX_ACCESS_TOKEN=<token>` set on the child only.
    fn spawn(url: &str, token: Option<&str>, tz: &str) -> Self {
        let scratch = tempfile::tempdir().expect("bridge scratch dir");
        let stderr_path = scratch.path().join("stderr");
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
        cmd.args(["serve", "--remote", url])
            .env_remove(TOKEN_ENV)
            .env_remove("RUST_LOG")
            .env("TZ", tz)
            .current_dir(scratch.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(
                std::fs::File::create(&stderr_path).expect("stderr file"),
            ));
        for key in PROXY_ENV {
            cmd.env_remove(key);
        }
        if let Some(token) = token {
            cmd.env(TOKEN_ENV, token);
        }
        let mut child = cmd.spawn().expect("spawn memex serve --remote");
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("child stdout");
        let stdout_all = Arc::new(Mutex::new(String::new()));
        let (tx, lines) = mpsc::channel::<String>();
        let all = stdout_all.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                {
                    let mut all = all.lock().unwrap();
                    all.push_str(&line);
                    all.push('\n');
                }
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            stdin,
            lines,
            stdout_all,
            stderr_path,
            _scratch: scratch,
        }
    }

    /// Writes `msg` as one line; panics with the bridge's exit and stderr if
    /// it has gone.
    fn send(&mut self, msg: &Value) {
        let stdin = self.stdin.as_mut().expect("stdin is open");
        let written = writeln!(stdin, "{msg}").and_then(|()| stdin.flush());
        if let Err(e) = written {
            let status = self.wait_exit(Duration::from_secs(5));
            panic!(
                "cannot write to the bridge ({e}): exit={status:?}\n{}",
                self.describe()
            );
        }
    }

    /// Waits until `done` holds while the bridge keeps running; panics if it
    /// exits first or [`WAIT`] passes.
    fn wait_until(&mut self, what: &str, done: impl Fn() -> bool) {
        let started = Instant::now();
        while !done() {
            if let Some(status) = self.child.try_wait().expect("try_wait") {
                panic!(
                    "the bridge exited ({status}) before {what}\n{}",
                    self.describe()
                );
            }
            assert!(started.elapsed() < WAIT, "{what} after {WAIT:?}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The response with `id`; panics if the bridge exits first or [`WAIT`]
    /// passes.
    fn recv(&mut self, id: i64) -> Value {
        let started = Instant::now();
        loop {
            match self.lines.recv_timeout(Duration::from_millis(100)) {
                Ok(line) => {
                    if let Ok(v) = serde_json::from_str::<Value>(&line) {
                        if v["id"] == json!(id) {
                            return v;
                        }
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => panic!(
                    "the bridge closed stdout before answering {id}: exit={:?} stderr={}",
                    self.child.try_wait().ok().flatten(),
                    self.stderr()
                ),
            }
            if let Some(status) = self.child.try_wait().expect("try_wait") {
                panic!(
                    "the bridge exited ({status}) before answering {id}; stderr={}",
                    self.stderr()
                );
            }
            assert!(
                started.elapsed() < WAIT,
                "no response to {id} after {WAIT:?}; stderr={}",
                self.stderr()
            );
        }
    }

    /// `initialize` (id 1), then `notifications/initialized`; returns the
    /// initialize result.
    fn handshake(&mut self) -> Value {
        self.send(&initialize(1));
        let resp = self.recv(1);
        let result = result_of(&resp);
        self.send(&initialized());
        result
    }

    fn close_stdin(&mut self) {
        self.stdin.take();
    }

    fn running(&mut self) -> bool {
        self.child.try_wait().expect("try_wait").is_none()
    }

    /// Waits up to `limit` for the bridge to exit on its own.
    fn wait_exit(&mut self, limit: Duration) -> Option<ExitStatus> {
        let started = Instant::now();
        loop {
            if let Some(status) = self.child.try_wait().expect("try_wait") {
                return Some(status);
            }
            if started.elapsed() > limit {
                return None;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The exit code once the bridge exits on its own; panics after [`WAIT`].
    fn exit_code(&mut self) -> Option<i32> {
        match self.wait_exit(WAIT) {
            Some(status) => status.code(),
            None => panic!(
                "the bridge is still running after {WAIT:?}; stderr={}",
                self.stderr()
            ),
        }
    }

    fn stdout(&self) -> String {
        self.stdout_all.lock().unwrap().clone()
    }

    fn stderr(&self) -> String {
        std::fs::read_to_string(&self.stderr_path).unwrap_or_default()
    }

    fn describe(&self) -> String {
        format!("stdout={}\nstderr={}", self.stdout(), self.stderr())
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A [`TestServer`] with the vault `work`, and a [`Proxy`] in front of it.
async fn served_work() -> (TestServer, Proxy) {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let proxy = Proxy::start(srv.addr()).await;
    (srv, proxy)
}

// ---------------------------------------------------------------------------
// AC 1: round trip
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_round_trips_initialize_tools_list_and_create_note() {
    let (srv, proxy) = served_work().await;
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(TEST_TOKEN), "UTC");

    let init = b.handshake();
    let direct_init = result_of(&direct(&srv, "work", &initialize(1)).await);
    assert_eq!(
        init["serverInfo"], direct_init["serverInfo"],
        "initialize answers with the vault server's own serverInfo: {init}"
    );
    assert!(init["capabilities"]["tools"].is_object(), "{init}");

    // The client's own initialize reached the server, then its
    // notifications/initialized.
    let inits = proxy.rpc("initialize");
    assert!(
        inits
            .iter()
            .any(|s| s.rpc_body()["params"]["clientInfo"]["name"] == CLIENT_NAME),
        "the client's initialize is forwarded to /vaults/work/mcp: {:?}",
        proxy.seen()
    );
    eventually("notifications/initialized forwarded", || {
        !proxy.rpc("notifications/initialized").is_empty()
    })
    .await;
    for s in proxy.rpc("initialize") {
        assert_eq!(s.path, mcp_path("work"), "{s:?}");
    }

    // tools/list: the vault server's 26 tools, exactly as it lists them.
    b.send(&request(2, "tools/list", json!({})));
    let listed = result_of(&b.recv(2));
    let bridged = by_name(&listed["tools"]);
    assert_eq!(bridged.len(), TOOL_COUNT, "{listed}");
    let direct_list = result_of(&direct(&srv, "work", &request(2, "tools/list", json!({}))).await);
    assert_eq!(
        bridged,
        by_name(&direct_list["tools"]),
        "tools/list over the bridge equals the vault server's tools/list"
    );

    // tools/call create_note lands in <root>/work; `memex get` reads it.
    b.send(&tool_call(
        3,
        "create_note",
        json!({ "title": "Bridged note", "content_md": "Written through the bridge." }),
    ));
    let created = tool_payload(&result_of(&b.recv(3)));
    let id = created["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note returns a note_id: {created}"))
        .to_string();
    assert!(
        !proxy
            .rpc("tools/call")
            .iter()
            .any(|s| s.path != mcp_path("work")),
        "tools/call goes to /vaults/work/mcp: {:?}",
        proxy.seen()
    );
    let on_disk = cli_get(&srv.root().join("work"), &id);
    assert_eq!(on_disk["note_id"], json!(id), "{on_disk}");
    assert_eq!(on_disk["title"], "Bridged note");
    assert_eq!(on_disk["content_md"], "Written through the bridge.");

    b.close_stdin();
    assert_eq!(b.exit_code(), Some(0), "{}", b.describe());
    assert_token_not_printed("round trip", TEST_TOKEN, &b.stdout(), &b.stderr());
}

// ---------------------------------------------------------------------------
// AC 2: the URL path is exactly /vaults/<name>/mcp
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_url_path_must_be_exactly_vaults_name_mcp() {
    let (_srv, proxy) = served_work().await;
    let base = format!("http://{}", proxy.addr);
    let cases = [
        format!("{base}/mcp"),
        format!("{base}/vaults/x"),
        format!("{base}/vaults/x/mcp/"),
        format!("{base}/vaults/x/mcp/extra"),
        format!("{base}/vaults/x/api/v1/info"),
        format!("{base}/prefix/vaults/x/mcp"),
        format!("{base}/vaults//mcp"),
        base.clone(),
        "not a url".to_string(),
    ];
    for url in cases {
        let mut b = Bridge::spawn(&url, Some(TEST_TOKEN), "UTC");
        let code = b.exit_code();
        assert_eq!(
            code,
            Some(2),
            "--remote {url:?} is a usage error (exit 2)\n{}",
            b.describe()
        );
        assert!(
            !b.stderr().trim().is_empty(),
            "{url:?}: the usage error is explained on stderr"
        );
        assert!(b.stdout().is_empty(), "{url:?}: {}", b.describe());
        assert_token_not_printed(&url, TEST_TOKEN, &b.stdout(), &b.stderr());
    }
    assert!(
        proxy.seen().is_empty(),
        "a usage error sends no request: {:?}",
        proxy.seen()
    );
}

// ---------------------------------------------------------------------------
// AC 3-6: the startup preflight
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_without_a_token_exits_1_access_token_missing_and_sends_nothing() {
    let (_srv, proxy) = served_work().await;
    for (case, token) in [("unset", None), ("empty", Some(""))] {
        let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), token, "UTC");
        assert_eq!(b.exit_code(), Some(1), "{case}\n{}", b.describe());
        assert_eq!(
            one_c1_code(&b.stderr()),
            "access_token_missing",
            "{case}\n{}",
            b.describe()
        );
        assert!(b.stdout().is_empty(), "{case}: {}", b.describe());
    }
    assert!(
        proxy.seen().is_empty(),
        "no request is sent without a token: {:?}",
        proxy.seen()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_preflight_unreachable_exits_1_server_unreachable() {
    // Nothing listening, and a host that accepts and drops every connection.
    let (_srv, proxy) = served_work().await;
    proxy.set(Mode::Down);
    let cases = [
        (
            "nothing listening",
            format!("http://127.0.0.1:{}/vaults/work/mcp", free_port()),
        ),
        ("connection dropped", proxy.url(&mcp_path("work"))),
    ];
    for (case, url) in cases {
        let mut b = Bridge::spawn(&url, Some(TEST_TOKEN), "UTC");
        assert_eq!(b.exit_code(), Some(1), "{case}\n{}", b.describe());
        assert_eq!(
            one_c1_code(&b.stderr()),
            "server_unreachable",
            "{case}\n{}",
            b.describe()
        );
        assert!(b.stdout().is_empty(), "{case}: {}", b.describe());
        assert_token_not_printed(case, TEST_TOKEN, &b.stdout(), &b.stderr());
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_preflight_wrong_token_exits_1_unauthorized() {
    let (_srv, proxy) = served_work().await;
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(WRONG_TOKEN), "UTC");
    assert_eq!(b.exit_code(), Some(1), "{}", b.describe());
    assert_eq!(one_c1_code(&b.stderr()), "unauthorized", "{}", b.describe());
    assert!(b.stdout().is_empty(), "{}", b.describe());
    assert_token_not_printed("wrong token", WRONG_TOKEN, &b.stdout(), &b.stderr());

    // The 401 came from the preflight, and no MCP request followed it.
    let seen = proxy.seen();
    assert_eq!(seen.len(), 1, "only the preflight is sent: {seen:?}");
    assert_eq!(seen[0].method, "GET", "{seen:?}");
    assert_eq!(seen[0].path, info_path("work"), "{seen:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_preflight_unknown_vault_exits_1_vault_not_found() {
    let (srv, proxy) = served_work().await;
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("missing")), Some(TEST_TOKEN), "UTC");
    assert_eq!(b.exit_code(), Some(1), "{}", b.describe());
    assert_eq!(
        one_c1_code(&b.stderr()),
        "vault_not_found",
        "{}",
        b.describe()
    );
    assert!(b.stdout().is_empty(), "{}", b.describe());
    assert_token_not_printed("unknown vault", TEST_TOKEN, &b.stdout(), &b.stderr());

    let seen = proxy.seen();
    assert_eq!(seen.len(), 1, "only the preflight is sent: {seen:?}");
    assert_eq!(seen[0].method, "GET", "{seen:?}");
    assert_eq!(seen[0].path, info_path("missing"), "{seen:?}");
    assert!(
        !srv.root().join("missing").exists(),
        "the preflight creates no vault"
    );
}

// ---------------------------------------------------------------------------
// AC 7: Authorization and X-Memex-UTC-Offset on every request
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_sends_token_and_local_utc_offset_on_every_request() {
    let cases = [
        ("Asia/Kathmandu", "+05:45"),
        ("Pacific/Marquesas", "-09:30"),
        ("UTC", "+00:00"),
    ];
    for (tz, offset) in cases {
        let (_srv, proxy) = served_work().await;
        let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(TEST_TOKEN), tz);
        b.handshake();
        b.send(&request(2, "tools/list", json!({})));
        result_of(&b.recv(2));
        b.send(&tool_call(3, "get_vault_settings", json!({})));
        result_of(&b.recv(3));
        b.close_stdin();
        assert_eq!(b.exit_code(), Some(0), "TZ={tz}\n{}", b.describe());
        assert_token_not_printed(tz, TEST_TOKEN, &b.stdout(), &b.stderr());

        let seen = proxy.seen();
        // The preflight comes first, then every MCP message.
        assert!(!seen.is_empty(), "TZ={tz}: no requests recorded");
        assert_eq!(seen[0].method, "GET", "TZ={tz}: preflight first: {seen:?}");
        assert_eq!(seen[0].path, info_path("work"), "TZ={tz}: {seen:?}");
        for method in ["initialize", "notifications/initialized"] {
            assert!(
                !proxy.rpc(method).is_empty(),
                "TZ={tz}: {method} is forwarded: {seen:?}"
            );
        }
        for method in ["tools/list", "tools/call"] {
            assert_eq!(
                proxy.rpc(method).len(),
                1,
                "TZ={tz}: one forwarded {method}: {seen:?}"
            );
        }
        for s in &seen {
            let what = format!("TZ={tz}: {} {} {:?}", s.method, s.path, s.rpc_method());
            assert_eq!(
                s.header_values("authorization"),
                vec![format!("Bearer {TEST_TOKEN}").as_str()],
                "{what}: one Authorization: Bearer <token>"
            );
            assert_eq!(
                s.header_values(OFFSET_HEADER),
                vec![offset],
                "{what}: one X-Memex-UTC-Offset with the local offset"
            );
            assert!(
                parse_utc_offset(s.header(OFFSET_HEADER).unwrap()).is_some(),
                "{what}: the header follows the D5 grammar"
            );
        }
    }
}

/// A clock whose UTC offset the test moves; its instant is the real one.
struct ShiftingClock {
    offset_secs: AtomicI32,
}

impl ShiftingClock {
    fn set(&self, hours: i32, minutes: i32) {
        let sign = if hours < 0 { -1 } else { 1 };
        self.offset_secs
            .store(sign * (hours.abs() * 3600 + minutes * 60), Ordering::SeqCst);
    }
}

impl Clock for ShiftingClock {
    fn now_ms(&self) -> i64 {
        memex_core::now_unix_ms()
    }

    fn utc_offset_at(&self, _now_ms: i64) -> FixedOffset {
        FixedOffset::east_opt(self.offset_secs.load(Ordering::SeqCst)).expect("valid offset")
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn bridge_rereads_the_utc_offset_for_every_request() {
    let (_srv, proxy) = served_work().await;
    let clock = Arc::new(ShiftingClock {
        offset_secs: AtomicI32::new(0),
    });
    clock.set(1, 0); // CET
    let shared: SharedClock = clock.clone();
    let (bridge_io, client_io) = tokio::io::duplex(1 << 20);
    let (bridge_in, bridge_out) = tokio::io::split(bridge_io);
    let (client_in, mut client_out) = tokio::io::split(client_io);
    let task = tokio::spawn(bridge::run(
        BridgeOptions {
            url: proxy.url(&mcp_path("work")),
            token: TEST_TOKEN.to_string(),
            clock: shared,
        },
        bridge_in,
        bridge_out,
    ));
    let mut lines = tokio::io::BufReader::new(client_in).lines();

    // The preflight reads the offset at startup.
    let started = Instant::now();
    while proxy.seen().is_empty() {
        if task.is_finished() {
            let res = task.await.expect("bridge task");
            panic!("bridge::run ended before any request: {res:?}");
        }
        assert!(started.elapsed() < WAIT, "no preflight after {WAIT:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let preflight = proxy.seen()[0].clone();
    assert_eq!(preflight.path, info_path("work"), "{preflight:?}");
    assert_eq!(preflight.header(OFFSET_HEADER), Some("+01:00"));

    async fn send(out: &mut tokio::io::WriteHalf<tokio::io::DuplexStream>, msg: Value) {
        out.write_all(format!("{msg}\n").as_bytes())
            .await
            .expect("write to the bridge");
        out.flush().await.expect("flush");
    }
    async fn recv(
        lines: &mut tokio::io::Lines<
            tokio::io::BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>,
        >,
        id: i64,
    ) -> Value {
        tokio::time::timeout(WAIT, async {
            loop {
                let line = lines
                    .next_line()
                    .await
                    .expect("read the bridge's output")
                    .unwrap_or_else(|| panic!("the bridge closed its output before {id}"));
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    if v["id"] == json!(id) {
                        return v;
                    }
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("no response to {id} after {WAIT:?}"))
    }

    // Daylight saving starts: the next request carries the new offset.
    clock.set(2, 0); // CEST
    send(&mut client_out, initialize(1)).await;
    result_of(&recv(&mut lines, 1).await);
    let init = proxy.rpc("initialize");
    assert_eq!(init.len(), 1, "{:?}", proxy.seen());
    assert_eq!(init[0].header(OFFSET_HEADER), Some("+02:00"), "{init:?}");

    // The Mac moves time zone mid-session.
    clock.set(-3, 30); // Newfoundland
    send(&mut client_out, initialized()).await;
    send(&mut client_out, request(2, "tools/list", json!({}))).await;
    result_of(&recv(&mut lines, 2).await);
    let list = proxy.rpc("tools/list");
    assert_eq!(list.len(), 1, "{:?}", proxy.seen());
    assert_eq!(list[0].header(OFFSET_HEADER), Some("-03:30"), "{list:?}");

    clock.set(13, 45); // Chatham, daylight time
    send(
        &mut client_out,
        tool_call(3, "get_vault_settings", json!({})),
    )
    .await;
    result_of(&recv(&mut lines, 3).await);
    let call = proxy.rpc("tools/call");
    assert_eq!(call.len(), 1, "{:?}", proxy.seen());
    assert_eq!(call[0].header(OFFSET_HEADER), Some("+13:45"), "{call:?}");

    // Every request also carried the token.
    for s in proxy.seen() {
        assert_eq!(
            s.header("authorization"),
            Some(format!("Bearer {TEST_TOKEN}").as_str()),
            "{s:?}"
        );
    }

    // Closing the input ends the bridge cleanly.
    drop(client_out);
    let res = tokio::time::timeout(WAIT, task)
        .await
        .expect("bridge::run ends when its input closes")
        .expect("bridge task");
    assert!(res.is_ok(), "input EOF is Ok: {res:?}");
}

// ---------------------------------------------------------------------------
// AC 8: a mid-session outage is a JSON-RPC error, then the bridge recovers
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_mid_session_outage_answers_a_json_rpc_error_and_recovers() {
    let (srv, proxy) = served_work().await;
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(TEST_TOKEN), "UTC");
    b.handshake();

    proxy.set(Mode::Down);
    b.send(&tool_call(
        2,
        "create_note",
        json!({ "title": "Lost in the outage", "content_md": "x" }),
    ));
    let failed = b.recv(2);
    assert_eq!(failed["jsonrpc"], "2.0", "{failed}");
    assert_eq!(failed["id"], json!(2), "the error answers the same id");
    assert!(
        failed["error"]["code"].is_i64(),
        "a JSON-RPC error with an integer code: {failed}"
    );
    assert!(
        failed["error"]["message"].is_string(),
        "a JSON-RPC error with a message: {failed}"
    );
    assert!(failed.get("result").is_none(), "{failed}");
    assert!(
        b.wait_exit(Duration::from_millis(300)).is_none(),
        "the bridge keeps running through an outage\n{}",
        b.describe()
    );
    assert!(b.running());

    // The server is back: the next call goes through.
    proxy.set(Mode::Forward);
    b.send(&tool_call(
        3,
        "create_note",
        json!({ "title": "After the outage", "content_md": "Back again." }),
    ));
    let created = tool_payload(&result_of(&b.recv(3)));
    let id = created["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note returns a note_id: {created}"))
        .to_string();
    let on_disk = cli_get(&srv.root().join("work"), &id);
    assert_eq!(on_disk["title"], "After the outage", "{on_disk}");

    b.close_stdin();
    assert_eq!(b.exit_code(), Some(0), "{}", b.describe());
    assert_token_not_printed("outage", TEST_TOKEN, &b.stdout(), &b.stderr());
}

// ---------------------------------------------------------------------------
// AC 9: a mid-session 401 ends the bridge
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_mid_session_401_exits_1_unauthorized() {
    let (_srv, proxy) = served_work().await;
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(TEST_TOKEN), "UTC");
    b.handshake();

    proxy.set(Mode::RotatedToken);
    b.send(&tool_call(2, "get_vault_settings", json!({})));
    assert_eq!(b.exit_code(), Some(1), "{}", b.describe());
    assert_eq!(one_c1_code(&b.stderr()), "unauthorized", "{}", b.describe());
    assert_token_not_printed("mid-session 401", TEST_TOKEN, &b.stdout(), &b.stderr());
    assert!(
        !proxy.rpc("tools/call").is_empty(),
        "the 401 answered the forwarded tools/call: {:?}",
        proxy.seen()
    );
}

// ---------------------------------------------------------------------------
// AC 10: stdin EOF exits 0
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_exits_0_when_stdin_closes() {
    // Before any message, once the preflight has passed.
    let (_srv, proxy) = served_work().await;
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(TEST_TOKEN), "UTC");
    b.wait_until("the preflight is sent", || !proxy.seen().is_empty());
    b.close_stdin();
    assert_eq!(
        b.exit_code(),
        Some(0),
        "EOF before initialize\n{}",
        b.describe()
    );
    assert!(b.stderr().trim().is_empty(), "{}", b.describe());

    // After a session.
    let mut b = Bridge::spawn(&proxy.url(&mcp_path("work")), Some(TEST_TOKEN), "UTC");
    b.handshake();
    b.send(&request(2, "ping", json!({})));
    let _ = b.recv(2);
    b.close_stdin();
    assert_eq!(
        b.exit_code(),
        Some(0),
        "EOF after a session\n{}",
        b.describe()
    );
    assert!(b.stderr().trim().is_empty(), "{}", b.describe());
}

// ---------------------------------------------------------------------------
// AC 11: the token never leaves through output
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_remote_never_prints_the_token() {
    let (srv, proxy) = served_work().await;
    let url = proxy.url(&mcp_path("work"));

    // A session with a tool error, an outage and a 401 at the end.
    let mut b = Bridge::spawn(&url, Some(TEST_TOKEN), "Asia/Kathmandu");
    b.handshake();
    b.send(&tool_call(
        2,
        "get_note",
        json!({ "note_id": "01J9V5NOSUCHNOTE0000000000" }),
    ));
    let _ = b.recv(2);
    proxy.set(Mode::Down);
    b.send(&tool_call(3, "get_vault_settings", json!({})));
    let _ = b.recv(3);
    proxy.set(Mode::RotatedToken);
    b.send(&tool_call(4, "get_vault_settings", json!({})));
    let code = b.exit_code();
    assert_eq!(code, Some(1), "{}", b.describe());
    assert_token_not_printed("session", TEST_TOKEN, &b.stdout(), &b.stderr());
    assert_token_not_printed("session", ROTATED_TOKEN, &b.stdout(), &b.stderr());

    // Every preflight failure.
    proxy.set(Mode::Forward);
    let failures = [
        ("wrong token", url.clone(), WRONG_TOKEN),
        ("unknown vault", proxy.url(&mcp_path("missing")), TEST_TOKEN),
        (
            "unreachable",
            format!("http://127.0.0.1:{}/vaults/work/mcp", free_port()),
            TEST_TOKEN,
        ),
        ("usage error", srv.url("/vaults/work/mcp/extra"), TEST_TOKEN),
    ];
    for (case, url, token) in failures {
        let mut b = Bridge::spawn(&url, Some(token), "UTC");
        let code = b.exit_code();
        assert_ne!(code, Some(0), "{case}\n{}", b.describe());
        assert!(
            !b.stderr().trim().is_empty(),
            "{case}: the failure is reported\n{}",
            b.describe()
        );
        assert_token_not_printed(case, token, &b.stdout(), &b.stderr());
    }
}
