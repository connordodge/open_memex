//! Test harness for the vault server (WI #71).
//!
//! Include it with `#[path = "support/server.rs"] mod server;` so no two
//! Work Items share a `tests/support/mod.rs`.
//!
//! - [`TestServer`] runs `memex_mcp::server::router()` in-process on
//!   `127.0.0.1:0` over a temp vault root, with the fixed [`TEST_TOKEN`]
//!   passed in the config (never through this process's environment).
//! - [`ServeCommand`] / [`ServeChild`] drive the built `memex` binary for
//!   token-source, exit-code and log tests. Environment is set on the child
//!   only, and a child is stopped through its own `Child` handle.
//! - [`raw_request`] speaks HTTP/1.1 over a bare socket, for requests a
//!   client library won't send (an oversized `Content-Length` with no body).

#![allow(dead_code)]

use std::fs::File;
use std::net::{SocketAddr, TcpListener as StdTcpListener};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use memex_mcp::server::{router, ServerConfig};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// The access token every in-process [`TestServer`] accepts.
pub const TEST_TOKEN: &str = "wi71-test-token-3f9c2a7e5b1d4c8a9e0f6b2d7c4a1e8f";

/// The env var the server reads its token from.
pub const TOKEN_ENV: &str = "MEMEX_ACCESS_TOKEN";

/// 8 MiB, the request body limit (req 19).
pub const BODY_LIMIT: usize = 8 * 1024 * 1024;

/// How long any single wait in these tests may take.
pub const WAIT: Duration = Duration::from_secs(30);

// ---------------------------------------------------------------------------
// In-process server
// ---------------------------------------------------------------------------

/// The vault server running in this test process.
pub struct TestServer {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl TestServer {
    /// Serves a fresh, empty temp vault root with [`TEST_TOKEN`].
    pub async fn start() -> Self {
        Self::start_in(tempfile::tempdir().expect("temp vault root")).await
    }

    /// Serves `root` with [`TEST_TOKEN`].
    pub async fn start_in(root: TempDir) -> Self {
        let config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN);
        let app = router(config);
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local addr");
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self { root, addr, task }
    }

    pub fn root(&self) -> &Path {
        self.root.path()
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// `http://<addr><path_and_query>`.
    pub fn url(&self, path_and_query: &str) -> String {
        format!("http://{}{}", self.addr, path_and_query)
    }

    /// `Bearer <TEST_TOKEN>`.
    pub fn bearer(&self) -> String {
        format!("Bearer {TEST_TOKEN}")
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A client that ignores proxy settings and never waits more than [`WAIT`].
pub fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .no_proxy()
        .timeout(WAIT)
        .build()
        .expect("reqwest client")
}

/// A response read to the end: status, headers and body text.
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Reply {
    pub async fn read(resp: reqwest::Response) -> Self {
        let status = resp.status().as_u16();
        let headers = resp
            .headers()
            .iter()
            .map(|(k, v)| {
                (
                    k.as_str().to_ascii_lowercase(),
                    String::from_utf8_lossy(v.as_bytes()).into_owned(),
                )
            })
            .collect();
        let body = resp.text().await.expect("read body");
        Self {
            status,
            headers,
            body,
        }
    }

    /// The body as JSON; panics with the body text when it isn't.
    pub fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or_else(|e| {
            panic!(
                "status {} body is not JSON ({e}): {:?}",
                self.status, self.body
            )
        })
    }

    /// The first value of header `name` (case-insensitive).
    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v.as_str())
    }

    /// The C1 `error.code`, panicking when the body isn't a C1 body.
    pub fn c1_code(&self) -> String {
        let v = self.json();
        let code = v["error"]["code"]
            .as_str()
            .unwrap_or_else(|| panic!("status {} body is not C1: {v}", self.status));
        assert!(
            v["error"]["message"].is_string(),
            "C1 body has a string message: {v}"
        );
        code.to_string()
    }
}

/// GET `url` with an optional `Authorization` header value.
pub async fn get(url: &str, authorization: Option<&str>) -> Reply {
    let mut req = client().get(url);
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    Reply::read(req.send().await.expect("send GET")).await
}

// ---------------------------------------------------------------------------
// Raw HTTP/1.1
// ---------------------------------------------------------------------------

/// Sends `head` (request line and headers; the blank line is added) and then
/// `body`, and reads one response. Errors while writing the body are ignored,
/// because a server may answer before reading it.
pub async fn raw_request(addr: SocketAddr, head: &str, body: &[u8]) -> Reply {
    tokio::time::timeout(WAIT, raw_request_inner(addr, head, body))
        .await
        .unwrap_or_else(|_| panic!("no response to raw request {head:?} within {WAIT:?}"))
}

async fn raw_request_inner(addr: SocketAddr, head: &str, body: &[u8]) -> Reply {
    let mut stream = TcpStream::connect(addr).await.expect("connect");
    let head = format!("{}\r\n\r\n", head.trim_end());
    stream
        .write_all(head.as_bytes())
        .await
        .expect("write request head");
    let (mut reader, mut writer) = stream.into_split();
    let body = body.to_vec();
    let writer_task = tokio::spawn(async move {
        let _ = writer.write_all(&body).await;
        let _ = writer.flush().await;
        writer
    });

    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        let n = reader.read(&mut chunk).await.expect("read response");
        assert!(n > 0, "connection closed before a full response head");
        buf.extend_from_slice(&chunk[..n]);
    };
    let head_text = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let mut lines = head_text.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| panic!("bad status line {status_line:?}"));
    let headers: Vec<(String, String)> = lines
        .filter(|l| !l.is_empty())
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    let content_length = headers
        .iter()
        .find(|(k, _)| k == "content-length")
        .and_then(|(_, v)| v.parse::<usize>().ok());
    let chunked = headers
        .iter()
        .any(|(k, v)| k == "transfer-encoding" && v.to_ascii_lowercase().contains("chunked"));
    let mut rest = buf[header_end..].to_vec();
    if let Some(len) = content_length {
        while rest.len() < len {
            let n = reader.read(&mut chunk).await.expect("read body");
            if n == 0 {
                break;
            }
            rest.extend_from_slice(&chunk[..n]);
        }
        rest.truncate(len);
    } else if chunked {
        while find(&rest, b"0\r\n\r\n").is_none() {
            let n = reader.read(&mut chunk).await.expect("read body");
            if n == 0 {
                break;
            }
            rest.extend_from_slice(&chunk[..n]);
        }
        rest = dechunk(&rest);
    } else if status != 204 && status != 304 {
        loop {
            let n = reader.read(&mut chunk).await.unwrap_or(0);
            if n == 0 {
                break;
            }
            rest.extend_from_slice(&chunk[..n]);
        }
    }
    writer_task.abort();
    Reply {
        status,
        headers,
        body: String::from_utf8_lossy(&rest).into_owned(),
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn dechunk(mut data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    while let Some(line_end) = find(data, b"\r\n") {
        let size_text = String::from_utf8_lossy(&data[..line_end]);
        let size = usize::from_str_radix(size_text.trim(), 16).unwrap_or(0);
        data = &data[line_end + 2..];
        if size == 0 || data.len() < size {
            break;
        }
        out.extend_from_slice(&data[..size]);
        data = &data[(size + 2).min(data.len())..];
    }
    out
}

// ---------------------------------------------------------------------------
// The built binary
// ---------------------------------------------------------------------------

/// `--listen` for a child that serves: the OS picks the port at bind time,
/// and [`ServeChild::ready`] reads it back from the listening line. A port
/// probed with [`free_port`] can be taken before the child binds it
/// (`Address already in use`), so [`free_port`] is only for children that
/// must never listen.
pub const ANY_PORT: &str = "127.0.0.1:0";

/// A localhost port that was free a moment ago. Use it only where nothing
/// should end up listening; see [`ANY_PORT`].
pub fn free_port() -> u16 {
    StdTcpListener::bind("127.0.0.1:0")
        .expect("bind probe port")
        .local_addr()
        .expect("probe addr")
        .port()
}

/// The `memex` binary under test, with a clean token environment.
pub struct ServeCommand {
    cmd: Command,
    scratch: TempDir,
}

/// The result of a `memex` run that exited on its own.
pub struct Finished {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl Finished {
    /// The non-empty stderr lines.
    pub fn stderr_lines(&self) -> Vec<&str> {
        self.stderr
            .lines()
            .filter(|l| !l.trim().is_empty())
            .collect()
    }

    pub fn describe(&self) -> String {
        format!(
            "exit={:?}\nstdout={}\nstderr={}",
            self.code, self.stdout, self.stderr
        )
    }
}

impl ServeCommand {
    /// `memex serve <args…>` with `MEMEX_ACCESS_TOKEN` and `RUST_LOG`
    /// removed from the child's environment, stdin closed.
    pub fn new(args: &[&str]) -> Self {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
        cmd.arg("serve").args(args);
        cmd.env_remove(TOKEN_ENV);
        cmd.env_remove("RUST_LOG");
        cmd.stdin(Stdio::null());
        Self {
            cmd,
            scratch: tempfile::tempdir().expect("scratch dir"),
        }
    }

    /// Sets `key=value` on the child only.
    pub fn env(mut self, key: &str, value: &str) -> Self {
        self.cmd.env(key, value);
        self
    }

    pub fn current_dir(mut self, dir: &Path) -> Self {
        self.cmd.current_dir(dir);
        self
    }

    fn redirect(&mut self) -> (PathBuf, PathBuf) {
        let out = self.scratch.path().join("stdout");
        let err = self.scratch.path().join("stderr");
        self.cmd
            .stdout(Stdio::from(File::create(&out).expect("stdout file")));
        self.cmd
            .stderr(Stdio::from(File::create(&err).expect("stderr file")));
        (out, err)
    }

    /// Runs to completion; panics (after killing it) if it is still running
    /// after `limit`.
    pub fn run_within(mut self, limit: Duration) -> Finished {
        let (out, err) = self.redirect();
        let mut child = self.cmd.spawn().expect("spawn memex serve");
        let started = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().expect("try_wait") {
                break status;
            }
            if started.elapsed() > limit {
                let _ = child.kill();
                let _ = child.wait();
                panic!(
                    "memex serve still running after {limit:?}; stderr={}",
                    std::fs::read_to_string(&err).unwrap_or_default()
                );
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        Finished {
            code: status.code(),
            stdout: std::fs::read_to_string(out).unwrap_or_default(),
            stderr: std::fs::read_to_string(err).unwrap_or_default(),
        }
    }

    /// Starts the child and leaves it running.
    pub fn spawn(mut self) -> ServeChild {
        let (out, err) = self.redirect();
        let child = self.cmd.spawn().expect("spawn memex serve");
        ServeChild {
            child,
            stdout_path: out,
            stderr_path: err,
            _scratch: self.scratch,
        }
    }
}

/// A running `memex serve`, killed through its own handle on drop.
pub struct ServeChild {
    child: Child,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
    _scratch: TempDir,
}

impl ServeChild {
    pub fn stderr(&self) -> String {
        std::fs::read_to_string(&self.stderr_path).unwrap_or_default()
    }

    pub fn stdout(&self) -> String {
        std::fs::read_to_string(&self.stdout_path).unwrap_or_default()
    }

    /// Waits for the child's `vault server listening on http://<addr>`
    /// stderr line and returns `<addr>`; panics if the child exits first or
    /// [`WAIT`] passes. With `--listen` [`ANY_PORT`] this is the port the
    /// child itself bound.
    pub async fn listening_addr(&mut self) -> SocketAddr {
        const PREFIX: &str = "vault server listening on http://";
        let started = Instant::now();
        loop {
            let stderr = self.stderr();
            if let Some(addr) = stderr
                .lines()
                .filter_map(|l| l.split_once(PREFIX).map(|(_, rest)| rest.trim()))
                .find_map(|rest| rest.parse::<SocketAddr>().ok())
            {
                return addr;
            }
            if let Some(status) = self.child.try_wait().expect("try_wait") {
                panic!("memex serve exited before listening: {status}; stderr={stderr}");
            }
            assert!(
                started.elapsed() < WAIT,
                "memex serve printed no listening line after {WAIT:?}; stderr={stderr}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// [`Self::listening_addr`], then [`Self::wait_ready`] on it.
    pub async fn ready(&mut self) -> SocketAddr {
        let addr = self.listening_addr().await;
        assert_ne!(addr.port(), 0, "the listening line names the bound port");
        self.wait_ready(addr).await;
        addr
    }

    /// Waits until `addr` answers any HTTP request; panics if the child exits
    /// first or [`WAIT`] passes.
    pub async fn wait_ready(&mut self, addr: SocketAddr) {
        let started = Instant::now();
        let url = format!("http://{addr}/api/v1/info");
        let probe = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(2))
            .build()
            .expect("probe client");
        loop {
            if let Some(status) = self.child.try_wait().expect("try_wait") {
                panic!(
                    "memex serve exited before listening: {status}; stderr={}",
                    self.stderr()
                );
            }
            if probe.get(&url).send().await.is_ok() {
                return;
            }
            assert!(
                started.elapsed() < WAIT,
                "memex serve not answering on {addr} after {WAIT:?}; stderr={}",
                self.stderr()
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Sends signal `name` (`TERM`, `INT`, …) to this child only, by its own
    /// pid, through `kill -s <name> <pid>`.
    pub fn signal(&self, name: &str) {
        let status = Command::new("kill")
            .args(["-s", name, &self.child.id().to_string()])
            .status()
            .expect("run kill");
        assert!(status.success(), "kill -s {name} {}", self.child.id());
    }

    /// Waits up to `limit` for the child to exit on its own; `None` if it is
    /// still running.
    pub fn wait_exit(&mut self, limit: Duration) -> Option<std::process::ExitStatus> {
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

    /// Kills the child and waits for it.
    pub fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for ServeChild {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Every `server.log*` file under `<root>/.memex/`, concatenated.
pub fn server_logs(root: &Path) -> String {
    let dir = root.join(".memex");
    let mut names: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with("server.log"))
                })
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
        .iter()
        .map(|p| std::fs::read_to_string(p).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Polls `server_logs(root)` until `done` holds; returns the last read.
/// Panics with the logs when [`WAIT`] passes.
pub async fn wait_for_logs(root: &Path, done: impl Fn(&str) -> bool) -> String {
    let started = Instant::now();
    loop {
        let logs = server_logs(root);
        if done(&logs) {
            return logs;
        }
        assert!(
            started.elapsed() < WAIT,
            "server.log never reached the expected state; logs=\n{logs}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
