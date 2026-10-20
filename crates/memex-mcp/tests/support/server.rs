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

    /// [`Self::new`], but the child runs under `umask <mask>` (set by
    /// `/bin/sh`, which then execs `memex`, so the pid is still memex's).
    pub fn under_umask(mask: &str, args: &[&str]) -> Self {
        let mut cmd = Command::new("/bin/sh");
        cmd.arg("-c")
            .arg(format!("umask {mask} && exec \"$0\" serve \"$@\""))
            .arg(env!("CARGO_BIN_EXE_memex"))
            .args(args);
        cmd.env_remove(TOKEN_ENV);
        cmd.env_remove("RUST_LOG");
        cmd.stdin(Stdio::null());
        Self {
            cmd,
            scratch: tempfile::tempdir().expect("scratch dir"),
        }
    }

    /// Removes `key` from the child's environment.
    pub fn env_remove(mut self, key: &str) -> Self {
        self.cmd.env_remove(key);
        self
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

// ---------------------------------------------------------------------------
// Vaults (WI #72)
// ---------------------------------------------------------------------------

/// POST `url` with the JSON `body` and an optional `Authorization` value.
pub async fn post_json(url: &str, body: &Value, authorization: Option<&str>) -> Reply {
    let mut req = client().post(url).json(body);
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    Reply::read(req.send().await.expect("send POST")).await
}

/// Creates the vault folder `<root>/<name>` with `Vault::create` (as
/// `memex init` would), closes it and returns its `vault_id`.
pub fn make_vault(root: &Path, name: &str) -> String {
    let dir = std::path::absolute(root.join(name)).expect("absolute vault path");
    let vault = memex_core::Vault::create(&dir)
        .unwrap_or_else(|e| panic!("create vault {}: {e}", dir.display()));
    vault.manifest().vault_id.clone()
}

/// `s` as one percent-encoded path segment: every byte outside
/// `A-Za-z0-9-_` is `%XX`, so `/`, `.`, `\` and NUL can't split or
/// normalize the path.
pub fn encode_segment(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// A directory on a case-sensitive file system, where `Work` and `work` can
/// sit side by side. A plain temp dir when the temp file system is already
/// case-sensitive (Linux); on a case-insensitive one (default macOS APFS) a
/// small case-sensitive APFS disk image mounted with `hdiutil`, detached on
/// drop. Never skipped: a machine that can't mount it fails the test.
pub struct CaseSensitiveDir {
    base: TempDir,
    mount: Option<PathBuf>,
}

impl CaseSensitiveDir {
    pub fn new() -> Self {
        let base = tempfile::tempdir().expect("case-sensitive base dir");
        if is_case_sensitive(base.path()) {
            return Self { base, mount: None };
        }
        let image = base.path().join("cs");
        let mount = base.path().join("mnt");
        let created = Command::new("hdiutil")
            .args(["create", "-quiet", "-size", "64m"])
            .args(["-fs", "Case-sensitive APFS", "-volname", "memexcs"])
            .args(["-type", "SPARSE"])
            .arg(&image)
            .status()
            .expect("run hdiutil create");
        assert!(created.success(), "hdiutil create failed: {created}");
        let attached = Command::new("hdiutil")
            .args(["attach", "-quiet", "-nobrowse", "-noverify", "-mountpoint"])
            .arg(&mount)
            .arg(base.path().join("cs.sparseimage"))
            .status()
            .expect("run hdiutil attach");
        assert!(attached.success(), "hdiutil attach failed: {attached}");
        assert!(
            is_case_sensitive(&mount),
            "the mounted image at {} is not case-sensitive",
            mount.display()
        );
        Self {
            base,
            mount: Some(mount),
        }
    }

    /// The case-sensitive directory.
    pub fn path(&self) -> &Path {
        self.mount.as_deref().unwrap_or(self.base.path())
    }

    /// A fresh temp dir inside [`Self::path`], for `TestServer::start_in`.
    /// Drop it (and the server) before this value.
    pub fn tempdir(&self) -> TempDir {
        tempfile::tempdir_in(self.path()).expect("temp dir on the case-sensitive fs")
    }
}

impl Default for CaseSensitiveDir {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for CaseSensitiveDir {
    fn drop(&mut self) {
        if let Some(mount) = &self.mount {
            let _ = Command::new("hdiutil")
                .args(["detach", "-quiet", "-force"])
                .arg(mount)
                .status();
        }
    }
}

/// Whether `dir`'s file system tells `CaseProbe` and `caseprobe` apart.
fn is_case_sensitive(dir: &Path) -> bool {
    let probe = dir.join("CaseProbe");
    std::fs::create_dir(&probe).expect("create case probe");
    let sensitive = !dir.join("caseprobe").exists();
    std::fs::remove_dir(&probe).expect("remove case probe");
    sensitive
}

/// Every path under `dir` (relative, sorted), with each file's bytes, for
/// "nothing was created, changed or opened" checks. A SQLite open shows up
/// as new `-wal`/`-shm` files. Symlinks are listed, never followed.
pub fn tree_snapshot(dir: &Path) -> Vec<(PathBuf, Option<Vec<u8>>)> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            let rel = path.strip_prefix(dir).expect("under dir").to_path_buf();
            let meta = std::fs::symlink_metadata(&path).expect("metadata");
            if meta.is_dir() {
                out.push((rel, None));
                stack.push(path);
            } else if meta.file_type().is_symlink() {
                out.push((rel, None));
            } else {
                out.push((rel, Some(std::fs::read(&path).unwrap_or_default())));
            }
        }
    }
    out.sort();
    out
}

/// Sends `GET <path>` (or another method) exactly as written, over a bare
/// socket, so the client can't normalize `..` or `%2E%2E` segments away.
pub async fn raw_get(srv: &TestServer, method: &str, path: &str) -> Reply {
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: {}\r\n\
         Content-Length: 0\r\nConnection: close\r\n",
        srv.bearer()
    );
    raw_request(srv.addr(), &head, b"").await
}

/// The complete V4 schema (v1..v4 as shipped), pinned at version 4: the
/// fixture `crates/memex-core/tests/migration_v5.rs` builds (copied, since
/// that file is another crate's test).
const V4_DDL: &str = "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);

     CREATE TABLE notes (
         id           TEXT PRIMARY KEY,
         title        TEXT NOT NULL,
         content_md   TEXT NOT NULL,
         frontmatter  TEXT NOT NULL DEFAULT '{}',
         version      INTEGER NOT NULL DEFAULT 1,
         created_at   INTEGER NOT NULL,
         updated_at   INTEGER NOT NULL,
         crdt_state   BLOB,
         has_open_questions      INTEGER NOT NULL DEFAULT 0,
         frontmatter_parse_error INTEGER NOT NULL DEFAULT 0
     );
     CREATE INDEX idx_notes_updated_at ON notes(updated_at DESC);
     CREATE UNIQUE INDEX idx_notes_title_unique ON notes(title);

     CREATE TABLE chunks (
         id                  TEXT PRIMARY KEY,
         note_id             TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         ord                 INTEGER NOT NULL,
         content             TEXT NOT NULL,
         token_count         INTEGER NOT NULL,
         embed_model_version TEXT
     );
     CREATE INDEX idx_chunks_note ON chunks(note_id, ord);

     CREATE VIRTUAL TABLE chunk_fts USING fts5(
         content,
         chunk_id UNINDEXED,
         note_id UNINDEXED,
         tokenize = 'porter unicode61'
     );

     CREATE TABLE tags (
         note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         tag     TEXT NOT NULL,
         PRIMARY KEY (note_id, tag)
     );
     CREATE INDEX idx_tags_tag ON tags(tag);

     CREATE TABLE pending_index (
         note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         enqueued_at INTEGER NOT NULL
     );

     CREATE TABLE notes_dedup_log (
         note_id      TEXT PRIMARY KEY,
         old_title    TEXT NOT NULL,
         new_title    TEXT NOT NULL,
         migrated_at  INTEGER NOT NULL
     );

     CREATE TABLE links (
         id            TEXT PRIMARY KEY,
         from_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         to_note_id    TEXT NULL REFERENCES notes(id) ON DELETE SET NULL,
         link_text     TEXT NOT NULL,
         link_kind     TEXT NOT NULL
                       CHECK (link_kind GLOB '[a-z][a-z0-9-]*' AND length(link_kind) <= 64),
         label         TEXT NULL,
         position      INTEGER NOT NULL,
         source        TEXT NOT NULL
                       CHECK (source IN ('inline_body','inline_section','frontmatter','auto_added')),
         UNIQUE (from_note_id, position)
     );
     CREATE INDEX idx_links_from ON links(from_note_id);
     CREATE INDEX idx_links_to   ON links(to_note_id);
     CREATE INDEX idx_links_kind ON links(link_kind, to_note_id);

     CREATE TABLE canvases (
         id          TEXT PRIMARY KEY,
         title       TEXT NOT NULL,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL,
         version     INTEGER NOT NULL DEFAULT 1
     );
     CREATE UNIQUE INDEX idx_canvases_title_unique ON canvases(title);
     CREATE INDEX idx_canvases_updated_at ON canvases(updated_at DESC);

     CREATE TABLE canvas_nodes (
         canvas_id   TEXT NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
         note_id     TEXT NOT NULL REFERENCES notes(id)    ON DELETE CASCADE,
         x           REAL NOT NULL,
         y           REAL NOT NULL,
         z_order     INTEGER NOT NULL DEFAULT 0,
         placed_at   INTEGER NOT NULL,
         PRIMARY KEY (canvas_id, note_id)
     );
     CREATE INDEX idx_canvas_nodes_note ON canvas_nodes(note_id);

     INSERT INTO schema_version(version) VALUES (1);
     INSERT INTO schema_version(version) VALUES (2);
     INSERT INTO schema_version(version) VALUES (3);
     INSERT INTO schema_version(version) VALUES (4);";

/// Creates `<root>/<name>` as a vault at schema version 4 (manifest and
/// database), which `Vault::open` migrates to 5. Returns its `vault_id`.
pub fn make_v4_vault(root: &Path, name: &str) -> String {
    let dir = root.join(name);
    std::fs::create_dir_all(dir.join("objects")).expect("create v4 vault dir");
    let conn = rusqlite::Connection::open(dir.join("memex.db")).expect("open v4 db");
    conn.pragma_update(None, "journal_mode", "WAL")
        .expect("wal");
    conn.execute_batch(V4_DDL).expect("apply the v4 schema");
    conn.execute(
        "INSERT INTO notes (id, title, content_md, created_at, updated_at) \
         VALUES ('01J9V5PLAIN000000000000000', 'Plain note', 'Body.', 1700000000000, 1700000000000)",
        [],
    )
    .expect("insert a v4 note");
    drop(conn);
    let vault_id = ulid::Ulid::new().to_string();
    let manifest = serde_json::json!({
        "vault_id": vault_id,
        "schema_version": 4,
        "created_at": 1_700_000_000_000_i64,
    });
    std::fs::write(
        dir.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).expect("manifest json"),
    )
    .expect("write v4 manifest");
    vault_id
}

/// Rewrites `<vault>/manifest.json` with `schema_version` = `version`.
pub fn set_manifest_schema_version(vault: &Path, version: i64) {
    let path = vault.join("manifest.json");
    let mut manifest: Value =
        serde_json::from_slice(&std::fs::read(&path).expect("read manifest")).expect("manifest");
    manifest["schema_version"] = Value::from(version);
    std::fs::write(&path, serde_json::to_vec_pretty(&manifest).expect("json"))
        .expect("write manifest");
}
