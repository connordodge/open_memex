//! WI #139 (Spec #123 W2; R4, R15, R40; rulings D19, compat): the vault
//! server's attachment routes and its per-request body limit, in-process.
//!
//! | Route | Answer |
//! |---|---|
//! | `POST /vaults/{name}/api/v1/attachments?name=<name>` | the raw body stored (R1-R3), `{markdown, path, name, size, type}`; up to 104,857,600 bytes, a larger body is a JSON C1 413 `payload_too_large` with the R15 text |
//! | `GET /vaults/{name}/api/v1/attachments/{*path}` | the file's bytes, `Content-Type` from the extension, `Content-Length` |
//! | `HEAD` on the same path | the same headers, no body |
//!
//! A path that isn't an attachment path (R4), or that resolves outside the
//! vault's `objects/` (a symlink included), is 400. A missing file is 404
//! `not found: attachment <path>`, distinct from an unknown route's `not
//! found: no route for this path` (D19). Every other route keeps the 8 MiB
//! limit and its 413.
//!
//! Large bodies are streamed from a repeating pattern over a bare socket,
//! never held in memory, and the tests that send 50 MB or more take
//! [`BIG`] so only one runs at a time. Concurrency is settled on events (a
//! paused body, a held embedder), never on a fixed sleep.

#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use memex_core::attachments::{markdown_for, parse_path, store_bytes, StoredAttachment};
use memex_core::embedder::{FakeEmbedder, GatedEmbedder};
use memex_mcp::server::{router, ServerConfig};
use reqwest::Method;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;

use server::{
    assert_wrong_method_is_c1_405, client, make_vault, raw_get, raw_request, tree_snapshot, Reply,
    TestServer, BODY_LIMIT, TEST_TOKEN, WAIT,
};

/// The served vault every test uses.
const VAULT: &str = "v";

/// Its app API prefix.
const BASE: &str = "/vaults/v/api/v1";

/// The upload route's own limit (R15, R40): 100 MB.
const UPLOAD_LIMIT: usize = 104_857_600;

/// How long one large streamed request may take end to end (debug builds
/// hash 100 MB slowly).
const BIG_WAIT: Duration = Duration::from_secs(300);

/// Held by every test that streams 50 MB or more, so their buffers never
/// add up.
static BIG: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Text no served response may ever contain.
const SECRET: &str = "WI139-TOP-SECRET-5d1f";

/// A well-formed content hash for paths the tests make up.
fn fake_hash(h2: &str) -> String {
    format!("{h2}{}", "c".repeat(62))
}

// ---------------------------------------------------------------------------
// Servers
// ---------------------------------------------------------------------------

/// A server over a fresh root holding the vault [`VAULT`].
async fn start() -> TestServer {
    let root = tempfile::tempdir().expect("temp vault root");
    make_vault(root.path(), VAULT);
    TestServer::start_in(root).await
}

fn vault_dir(srv: &TestServer) -> PathBuf {
    srv.root().join(VAULT)
}

/// The full router over a fresh root holding [`VAULT`], with `embedder` as
/// every vault's embedder.
struct EmbedderServer {
    root: TempDir,
    addr: SocketAddr,
    task: tokio::task::JoinHandle<()>,
}

impl EmbedderServer {
    async fn start(embedder: Arc<GatedEmbedder>) -> Self {
        let root = tempfile::tempdir().expect("temp vault root");
        make_vault(root.path(), VAULT);
        let config =
            ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN).with_embedder(embedder);
        let app = router(config);
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self { root, addr, task }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }
}

impl Drop for EmbedderServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Opens the gate when dropped, so a failing test never leaves a blocked
/// embedder thread behind.
struct OpenOnDrop(Arc<GatedEmbedder>);

impl Drop for OpenOnDrop {
    fn drop(&mut self) {
        self.0.release();
    }
}

// ---------------------------------------------------------------------------
// Bodies, hashes and stored files
// ---------------------------------------------------------------------------

/// Byte `i` of every generated body is `i % PERIOD`.
const PERIOD: usize = 251;

/// The streamed write size, a whole number of periods.
const CHUNK: usize = PERIOD * 1024;

fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i % PERIOD) as u8).collect()
}

fn sha_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// `objects/<h2>/<h>/<name>`.
fn object_path(hash: &str, name: &str) -> String {
    format!("objects/{}/{hash}/{name}", &hash[..2])
}

/// Every regular file under the vault's `objects/`, relative to the vault,
/// with its size, sorted.
fn stored_files(vault: &Path) -> Vec<(String, u64)> {
    let mut out = Vec::new();
    let mut stack = vec![vault.join("objects")];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path).expect("metadata");
            if meta.is_dir() {
                stack.push(path);
            } else if meta.is_file() {
                let rel = path.strip_prefix(vault).expect("under the vault");
                out.push((rel.to_string_lossy().into_owned(), meta.len()));
            }
        }
    }
    out.sort();
    out
}

/// Waits (polling the file system, up to [`WAIT`]) until a regular file
/// named `name` of `size` bytes is under the vault's `objects/`; false at
/// the deadline, or as soon as `request` ended without storing it.
async fn wait_for_stored<T>(
    vault: &Path,
    name: &str,
    size: u64,
    request: &tokio::task::JoinHandle<T>,
) -> bool {
    let deadline = tokio::time::Instant::now() + WAIT;
    let found = || {
        stored_files(vault)
            .iter()
            .any(|(rel, len)| rel.rsplit('/').next() == Some(name) && *len == size)
    };
    loop {
        let ended = request.is_finished();
        if found() {
            return true;
        }
        if ended || tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The R3 url in a stored attachment's markdown (between its last `(` and
/// the closing `)`).
fn markdown_url(stored: &StoredAttachment) -> String {
    let open = stored.markdown.rfind('(').expect("markdown has a url");
    stored.markdown[open + 1..stored.markdown.len() - 1].to_string()
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

fn upload_path(name_query: &str) -> String {
    format!("{BASE}/attachments?name={name_query}")
}

/// POSTs `body` to the upload route with the token (reqwest sends its
/// `Content-Length`).
async fn upload(srv: &TestServer, name_query: &str, body: &[u8]) -> Reply {
    let req = client()
        .post(srv.url(&upload_path(name_query)))
        .header("authorization", srv.bearer())
        .header("content-type", "application/octet-stream")
        .body(body.to_vec());
    Reply::read(req.send().await.expect("send upload")).await
}

/// A response with its body as bytes.
struct Got {
    status: u16,
    headers: reqwest::header::HeaderMap,
    body: Vec<u8>,
}

impl Got {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).and_then(|v| v.to_str().ok())
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or_else(|e| {
            panic!(
                "status {} body is not JSON ({e}): {:?}",
                self.status,
                String::from_utf8_lossy(&self.body)
            )
        })
    }
}

/// `method path` with the token, through reqwest.
async fn fetch(srv: &TestServer, method: Method, path: &str) -> Got {
    let resp = client()
        .request(method.clone(), srv.url(path))
        .header("authorization", srv.bearer())
        .send()
        .await
        .unwrap_or_else(|e| panic!("send {method} {path}: {e}"));
    let status = resp.status().as_u16();
    let headers = resp.headers().clone();
    let body = resp.bytes().await.expect("read body").to_vec();
    Got {
        status,
        headers,
        body,
    }
}

/// The request line and headers of an upload: `Content-Length` when given,
/// otherwise `Transfer-Encoding: chunked`.
fn upload_head(
    method: &str,
    path_and_query: &str,
    authorization: Option<&str>,
    content_length: Option<usize>,
) -> String {
    let mut head = format!(
        "{method} {path_and_query} HTTP/1.1\r\nHost: localhost\r\n\
         Content-Type: application/octet-stream\r\nConnection: close\r\n"
    );
    match content_length {
        Some(len) => head.push_str(&format!("Content-Length: {len}\r\n")),
        None => head.push_str("Transfer-Encoding: chunked\r\n"),
    }
    if let Some(value) = authorization {
        head.push_str(&format!("Authorization: {value}\r\n"));
    }
    head
}

/// Where a streamed body stops until the test lets it go on.
struct Pause {
    /// The body offset it stops at.
    at: usize,
    /// Sent once `at` bytes are written; dropped unsent when the server
    /// stopped taking the body first.
    reached: oneshot::Sender<()>,
    resume: oneshot::Receiver<()>,
}

/// A response read off a bare socket.
struct Raw {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl std::fmt::Debug for Raw {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let shown = self.body.len().min(400);
        write!(
            f,
            "{} {:?} {:?} ({} body bytes)",
            self.status,
            self.headers,
            String::from_utf8_lossy(&self.body[..shown]),
            self.body.len()
        )
    }
}

impl Raw {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or_else(|e| {
            panic!(
                "status {} body is not JSON ({e}): {:?}",
                self.status,
                String::from_utf8_lossy(&self.body)
            )
        })
    }
}

/// Sends `head`, then a generated body of `len` bytes ([`pattern`]), chunked
/// when `chunked`, stopping at `pause` if given; reads one response.
async fn stream_request(
    addr: SocketAddr,
    head: String,
    len: usize,
    chunked: bool,
    pause: Option<Pause>,
) -> Raw {
    tokio::time::timeout(BIG_WAIT, stream_inner(addr, head, len, chunked, pause))
        .await
        .unwrap_or_else(|_| panic!("no response to a {len}-byte upload within {BIG_WAIT:?}"))
}

async fn stream_inner(
    addr: SocketAddr,
    head: String,
    len: usize,
    chunked: bool,
    mut pause: Option<Pause>,
) -> Raw {
    let stream = TcpStream::connect(addr).await.expect("connect");
    let (mut reader, mut writer) = stream.into_split();
    let head = format!("{}\r\n\r\n", head.trim_end());
    let writer_task = tokio::spawn(async move {
        if writer.write_all(head.as_bytes()).await.is_err() {
            return writer;
        }
        let buf = pattern(CHUNK + PERIOD);
        let mut written = 0;
        while written < len {
            if pause.as_ref().is_some_and(|p| p.at == written) {
                let p = pause.take().expect("pause");
                let _ = p.reached.send(());
                let _ = p.resume.await;
            }
            let mut n = CHUNK.min(len - written);
            if let Some(p) = &pause {
                n = n.min(p.at - written);
            }
            let off = written % PERIOD;
            let data = &buf[off..off + n];
            let sent = if chunked {
                writer
                    .write_all(format!("{n:x}\r\n").as_bytes())
                    .await
                    .is_ok()
                    && writer.write_all(data).await.is_ok()
                    && writer.write_all(b"\r\n").await.is_ok()
            } else {
                writer.write_all(data).await.is_ok()
            };
            if !sent {
                // The server stopped reading; `pause` drops unsent.
                return writer;
            }
            written += n;
        }
        if chunked {
            let _ = writer.write_all(b"0\r\n\r\n").await;
        }
        let _ = writer.flush().await;
        writer
    });

    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        let n = reader.read(&mut chunk).await.expect("read response head");
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
    let mut body = buf[header_end..].to_vec();
    loop {
        if content_length.is_some_and(|l| body.len() >= l) {
            break;
        }
        match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
        }
    }
    if let Some(l) = content_length {
        body.truncate(l);
    }
    writer_task.abort();
    Raw {
        status,
        headers,
        body,
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// The success answer of an upload: 200 or 201.
fn is_stored(status: u16) -> bool {
    matches!(status, 200 | 201)
}

/// The C1 413 body of an upload over 100 MB named `name` (R15).
fn upload_too_large(name: &str) -> Value {
    json!({
        "error": {
            "code": "payload_too_large",
            "message": format!("{name} is larger than 100 MB and wasn't attached."),
        }
    })
}

/// The C1 413 body every other route answers past 8 MiB.
fn other_route_too_large() -> Value {
    json!({
        "error": {
            "code": "payload_too_large",
            "message": "the request body is larger than 8 MiB",
        }
    })
}

// ---------------------------------------------------------------------------
// AC 1: upload stores the body and answers {markdown, path, name, size, type}
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn upload_stores_the_body_and_answers_markdown_path_name_size_type() {
    let srv = start().await;
    let vault = vault_dir(&srv);

    // A PNG-looking body, built at run time.
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    png.extend(pattern(1000));
    let hash = sha_hex(&png);
    let r = upload(&srv, "mock.png", &png).await;
    assert!(
        is_stored(r.status),
        "upload mock.png: {} {}",
        r.status,
        r.body
    );
    assert!(
        r.header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "a JSON answer: {:?}",
        r.headers
    );
    let path = object_path(&hash, "mock.png");
    assert_eq!(
        r.json(),
        json!({
            "markdown": format!("![mock.png](objects/{}/{hash}/mock.png)", &hash[..2]),
            "path": path,
            "name": "mock.png",
            "size": png.len(),
            "type": "image/png",
        }),
        "exactly the five R40 keys"
    );
    assert_eq!(
        std::fs::read(vault.join(&path)).expect("the file is under objects/"),
        png
    );

    // The query value is percent-decoded; the name and markdown follow R1/R3.
    let pdf = format!("%PDF-1.4 {}", "q3 numbers ".repeat(40)).into_bytes();
    let pdf_hash = sha_hex(&pdf);
    let r = upload(&srv, "Q3%20report.pdf", &pdf).await;
    assert!(
        is_stored(r.status),
        "upload Q3 report.pdf: {} {}",
        r.status,
        r.body
    );
    let pdf_path = object_path(&pdf_hash, "Q3 report.pdf");
    assert_eq!(
        r.json(),
        json!({
            "markdown": markdown_for("Q3 report.pdf", &pdf_hash),
            "path": pdf_path,
            "name": "Q3 report.pdf",
            "size": pdf.len(),
            "type": "application/pdf",
        })
    );
    assert_eq!(
        r.json()["markdown"],
        json!(format!(
            "[Q3 report.pdf](objects/{}/{pdf_hash}/Q3%20report.pdf)",
            &pdf_hash[..2]
        ))
    );
    assert_eq!(std::fs::read(vault.join(&pdf_path)).unwrap(), pdf);

    // An unknown extension is application/octet-stream.
    let r = upload(&srv, "data.xyz", b"some bytes").await;
    assert!(
        is_stored(r.status),
        "upload data.xyz: {} {}",
        r.status,
        r.body
    );
    assert_eq!(r.json()["type"], json!("application/octet-stream"));
    assert_eq!(stored_files(&vault).len(), 3, "{:?}", stored_files(&vault));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn upload_just_over_8_mib_is_accepted_and_stored() {
    let srv = start().await;
    let len = BODY_LIMIT + 1;
    let body = pattern(len);
    let hash = sha_hex(&body);
    let r = stream_request(
        srv.addr(),
        upload_head(
            "POST",
            &upload_path("over8.bin"),
            Some(&srv.bearer()),
            Some(len),
        ),
        len,
        false,
        None,
    )
    .await;
    assert!(is_stored(r.status), "{r:?}");
    let v = r.json();
    assert_eq!(v["path"], json!(object_path(&hash, "over8.bin")));
    assert_eq!(v["size"], json!(len));
    let on_disk = std::fs::read(vault_dir(&srv).join(object_path(&hash, "over8.bin")))
        .expect("stored under objects/");
    assert!(on_disk == body, "the stored bytes are the body");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chunked_upload_over_8_mib_is_accepted_and_stored() {
    let srv = start().await;
    let len = BODY_LIMIT + 1024 * 1024;
    let hash = sha_hex(&pattern(len));
    let r = stream_request(
        srv.addr(),
        upload_head(
            "POST",
            &upload_path("chunked9.bin"),
            Some(&srv.bearer()),
            None,
        ),
        len,
        true,
        None,
    )
    .await;
    assert!(is_stored(r.status), "{r:?}");
    assert_eq!(r.json()["path"], json!(object_path(&hash, "chunked9.bin")));
    assert_eq!(r.json()["size"], json!(len));
    assert_eq!(
        stored_files(&vault_dir(&srv)),
        vec![(object_path(&hash, "chunked9.bin"), len as u64)]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn upload_of_exactly_100_mb_is_accepted_and_stored() {
    let _big = BIG.lock().await;
    let srv = start().await;
    let r = stream_request(
        srv.addr(),
        upload_head(
            "POST",
            &upload_path("exact.bin"),
            Some(&srv.bearer()),
            Some(UPLOAD_LIMIT),
        ),
        UPLOAD_LIMIT,
        false,
        None,
    )
    .await;
    assert!(is_stored(r.status), "{r:?}");
    let v = r.json();
    assert_eq!(v["size"], json!(UPLOAD_LIMIT));
    assert_eq!(v["name"], json!("exact.bin"));
    let path = v["path"].as_str().expect("path").to_string();
    let parsed = parse_path(&path).unwrap_or_else(|| panic!("{path} is an attachment path"));
    assert_eq!(parsed.name, "exact.bin");
    assert_eq!(
        stored_files(&vault_dir(&srv)),
        vec![(path, UPLOAD_LIMIT as u64)]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn upload_without_a_name_is_400_and_writes_nothing() {
    let srv = start().await;
    let before = tree_snapshot(&vault_dir(&srv).join("objects"));
    let req = client()
        .post(srv.url(&format!("{BASE}/attachments")))
        .header("authorization", srv.bearer())
        .body(b"nameless".to_vec());
    let r = Reply::read(req.send().await.unwrap()).await;
    assert_eq!(r.status, 400, "{}", r.body);
    assert_eq!(r.c1_code(), "invalid_argument");
    assert_eq!(
        tree_snapshot(&vault_dir(&srv).join("objects")),
        before,
        "nothing written"
    );
    // The same request with a name stores it.
    let r = upload(&srv, "named.txt", b"nameless").await;
    assert!(is_stored(r.status), "{} {}", r.status, r.body);
}

// ---------------------------------------------------------------------------
// AC 2: over 104,857,600 bytes is a JSON C1 413 with the R15 text
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn upload_over_100_mb_by_content_length_is_413_with_the_r15_text_and_writes_nothing() {
    let srv = start().await;
    let vault = vault_dir(&srv);
    let before = tree_snapshot(&vault.join("objects"));
    // Only the head is sent: the limit answers on Content-Length.
    let r = raw_request(
        srv.addr(),
        &upload_head(
            "POST",
            &upload_path("big.bin"),
            Some(&srv.bearer()),
            Some(UPLOAD_LIMIT + 1),
        ),
        b"",
    )
    .await;
    assert_eq!(r.status, 413, "{}", r.body);
    assert!(
        r.header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "{:?}",
        r.headers
    );
    assert_eq!(r.json(), upload_too_large("big.bin"));
    assert_eq!(
        tree_snapshot(&vault.join("objects")),
        before,
        "nothing written"
    );

    // The name in the text is the upload's own.
    let r = raw_request(
        srv.addr(),
        &upload_head(
            "POST",
            &upload_path("Holiday%20video.mov"),
            Some(&srv.bearer()),
            Some(UPLOAD_LIMIT + 1),
        ),
        b"",
    )
    .await;
    assert_eq!(r.status, 413, "{}", r.body);
    assert_eq!(r.json(), upload_too_large("Holiday video.mov"));
    assert_eq!(
        tree_snapshot(&vault.join("objects")),
        before,
        "nothing written"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chunked_upload_over_100_mb_is_413_with_the_r15_text_and_writes_nothing() {
    let _big = BIG.lock().await;
    let srv = start().await;
    let r = stream_request(
        srv.addr(),
        upload_head("POST", &upload_path("big.bin"), Some(&srv.bearer()), None),
        UPLOAD_LIMIT + 1,
        true,
        None,
    )
    .await;
    assert_eq!(r.status, 413, "{r:?}");
    assert!(
        r.header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "{r:?}"
    );
    assert_eq!(r.json(), upload_too_large("big.bin"));
    assert_eq!(
        stored_files(&vault_dir(&srv)),
        Vec::<(String, u64)>::new(),
        "nothing stored, no temp file left"
    );
}

// ---------------------------------------------------------------------------
// AC 3: every other route keeps 8 MiB and its 413
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_other_route_keeps_the_8_mib_limit_and_its_413() {
    let srv = start().await;
    let h = fake_hash("ab");
    let routes = [
        ("POST", format!("{BASE}/notes")),
        ("PUT", upload_path("a.bin")),
        ("PATCH", upload_path("a.bin")),
        ("POST", format!("{BASE}/attachments/objects/ab/{h}/a.bin")),
        ("POST", format!("{BASE}/attachmentsx?name=a.bin")),
        ("POST", format!("{BASE}/x/attachments?name=a.bin")),
        ("POST", "/vaults/v/mcp".to_string()),
        ("POST", "/api/v1/vaults".to_string()),
    ];
    for (method, path) in &routes {
        let r = raw_request(
            srv.addr(),
            &upload_head(method, path, Some(&srv.bearer()), Some(BODY_LIMIT + 1)),
            b"",
        )
        .await;
        assert_eq!(r.status, 413, "{method} {path} past 8 MiB: {}", r.body);
        assert_eq!(r.json(), other_route_too_large(), "{method} {path}");
    }
}

// ---------------------------------------------------------------------------
// AC 4: GET returns the bytes with Content-Type and Content-Length; HEAD the
// same headers, no body; encoded and decoded paths
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_and_head_serve_the_file_with_its_type_and_length_by_encoded_or_decoded_path() {
    let srv = start().await;
    let vault = vault_dir(&srv);
    let mut pdf_bytes = b"%PDF-1.4\n".to_vec();
    pdf_bytes.extend(pattern(5000));
    let cases = [
        ("mock.png", pattern(3000), "image/png"),
        ("Q3 report.pdf", pdf_bytes, "application/pdf"),
        (
            "page.html",
            b"<script>alert(1)</script>".to_vec(),
            "application/octet-stream",
        ),
        ("data.xyz", pattern(10), "application/octet-stream"),
    ];
    for (name, bytes, mime) in &cases {
        let stored = store_bytes(&vault, bytes, name).expect("store");
        let url = markdown_url(&stored);
        // On the wire: the R3 url as is (the server sees the decoded path),
        // and the R3 url encoded once more (the server sees the encoded url).
        let wire = [url.clone(), url.replace('%', "%25")];
        for form in &wire {
            let path = format!("{BASE}/attachments/{form}");
            let got = fetch(&srv, Method::GET, &path).await;
            assert_eq!(
                got.status,
                200,
                "GET {path}: {:?}",
                String::from_utf8_lossy(&got.body)
            );
            assert!(got.body == *bytes, "GET {path}: the file's bytes");
            assert_eq!(got.header("content-type"), Some(*mime), "GET {path}");
            let length = bytes.len().to_string();
            assert_eq!(
                got.header("content-length"),
                Some(length.as_str()),
                "GET {path}"
            );

            let head = fetch(&srv, Method::HEAD, &path).await;
            assert_eq!(head.status, 200, "HEAD {path}");
            assert_eq!(head.header("content-type"), Some(*mime), "HEAD {path}");
            assert_eq!(
                head.header("content-length"),
                Some(length.as_str()),
                "HEAD {path}"
            );
            assert!(head.body.is_empty(), "HEAD {path}: no body");
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_uploaded_attachment_downloads_by_the_path_and_the_markdown_url_it_answered() {
    let srv = start().await;
    let bytes = format!("hello from {}", "a".repeat(100)).into_bytes();
    let r = upload(&srv, "Read%20me.txt", &bytes).await;
    assert!(is_stored(r.status), "{} {}", r.status, r.body);
    let v = r.json();
    let markdown = v["markdown"].as_str().unwrap();
    let open = markdown.rfind('(').unwrap();
    let url = &markdown[open + 1..markdown.len() - 1];
    for form in [url.to_string(), url.replace('%', "%25")] {
        let got = fetch(&srv, Method::GET, &format!("{BASE}/attachments/{form}")).await;
        assert_eq!(got.status, 200, "GET {form}");
        assert!(got.body == bytes, "GET {form}: the uploaded bytes");
    }
    assert_eq!(
        v["path"],
        json!(object_path(&sha_hex(&bytes), "Read me.txt"))
    );
}

// ---------------------------------------------------------------------------
// AC 5: 400 for non-attachment paths, traversal and symlinks out; 404 texts
// ---------------------------------------------------------------------------

/// Writes [`SECRET`] files inside the vault (outside `objects/`) and next to
/// the vault, and a real attachment; returns its hash.
fn plant_secrets(srv: &TestServer) -> String {
    let vault = vault_dir(srv);
    std::fs::write(vault.join("secret.txt"), SECRET).unwrap();
    std::fs::write(srv.root().join("secret.txt"), SECRET).unwrap();
    let stored = store_bytes(&vault, b"an attachment", "real.txt").unwrap();
    parse_path(&stored.path).unwrap().hash
}

fn assert_400_without_secret(r: &Reply, what: &str, method: &str) {
    assert_eq!(r.status, 400, "{what}: {}", r.body);
    assert!(!r.body.contains(SECRET), "{what}: served a secret");
    if method == "GET" {
        assert_eq!(r.c1_code(), "invalid_argument", "{what}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_path_that_is_not_an_attachment_path_is_400() {
    let srv = start().await;
    let h = plant_secrets(&srv);
    // Uppercase hex resolves to the real file on a case-insensitive volume:
    // only the grammar refuses it.
    let upper = h.to_ascii_uppercase();
    let other_h2 = if &h[..2] == "ff" { "fe" } else { "ff" };
    let paths = [
        "secret.txt".to_string(),
        "notes/abc.md".to_string(),
        ".memex/manifest.json".to_string(),
        format!("objects/zz/{h}/real.txt"),
        format!("objects/{other_h2}/{h}/real.txt"),
        format!("objects/{}/{upper}/real.txt", &h[..2]),
        format!("objects/{}/{upper}/real.txt", &upper[..2]),
        format!("objects/AB/{}/real.txt", fake_hash("ab")),
        format!("objects/{}/{}/real.txt", &h[..2], &h[..63]),
        format!("objects/{}/{h}", &h[..2]),
        format!("objects/{}/{h}/", &h[..2]),
        format!("objects/{}/{h}/sub/real.txt", &h[..2]),
        format!("objects/{}/{h}/%2E", &h[..2]),
        format!("objects/{}/{h}/%2E%2E", &h[..2]),
        format!("files/{}/{h}/real.txt", &h[..2]),
    ];
    for method in ["GET", "HEAD"] {
        for p in &paths {
            let path = format!("{BASE}/attachments/{p}");
            let r = raw_get(&srv, method, &path).await;
            assert_400_without_secret(&r, &format!("{method} {path}"), method);
        }
    }
    // The real attachment next to them is served.
    let ok = raw_get(
        &srv,
        "GET",
        &format!("{BASE}/attachments/objects/{}/{h}/real.txt", &h[..2]),
    )
    .await;
    assert_eq!((ok.status, ok.body.as_str()), (200, "an attachment"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dot_dot_traversal_is_400_and_never_serves_a_file_outside_objects() {
    let srv = start().await;
    let h = plant_secrets(&srv);
    let h2 = &h[..2];
    let paths = [
        format!("objects/{h2}/{h}/../../../secret.txt"),
        format!("objects/{h2}/{h}/../../../../secret.txt"),
        format!("objects/{h2}/{h}/..%2F..%2F..%2Fsecret.txt"),
        format!("objects/{h2}/{h}/%2E%2E%2F%2E%2E%2F%2E%2E%2Fsecret.txt"),
        format!("objects/%2E%2E/{h}/secret.txt"),
        "../secret.txt".to_string(),
        "..%2F..%2Fsecret.txt".to_string(),
        "objects/../secret.txt".to_string(),
        "%2E%2E/%2E%2E/secret.txt".to_string(),
    ];
    for method in ["GET", "HEAD"] {
        for p in &paths {
            let path = format!("{BASE}/attachments/{p}");
            let r = raw_get(&srv, method, &path).await;
            assert_400_without_secret(&r, &format!("{method} {path}"), method);
        }
    }
    // Encoded twice: whatever the server makes of it, it never serves the
    // secret.
    for p in [
        format!("objects/{h2}/{h}/..%252F..%252F..%252Fsecret.txt"),
        format!("objects/{h2}/{h}/%252E%252E"),
    ] {
        let path = format!("{BASE}/attachments/{p}");
        let r = raw_get(&srv, "GET", &path).await;
        assert!(
            matches!(r.status, 400 | 404),
            "GET {path}: {} {}",
            r.status,
            r.body
        );
        assert!(!r.body.contains(SECRET), "GET {path}: served a secret");
    }
    // The real attachment is still served.
    let ok = raw_get(
        &srv,
        "GET",
        &format!("{BASE}/attachments/objects/{h2}/{h}/real.txt"),
    )
    .await;
    assert_eq!((ok.status, ok.body.as_str()), (200, "an attachment"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_symlink_under_objects_that_resolves_outside_it_is_400() {
    use std::os::unix::fs::symlink;

    let srv = start().await;
    let h = plant_secrets(&srv);
    let vault = vault_dir(&srv);
    let root = srv.root().to_path_buf();
    let objects = vault.join("objects");

    // A file link out of the vault, and one into the vault outside objects/.
    let dir = objects.join(&h[..2]).join(&h);
    symlink(root.join("secret.txt"), dir.join("leak.txt")).unwrap();
    symlink(vault.join("secret.txt"), dir.join("vault-leak.txt")).unwrap();
    symlink(&vault, dir.join("vault-dir")).unwrap();

    // A hash folder that is a link to a folder outside.
    let h_cd = fake_hash("cd");
    let outside_cd = root.join("outside-cd");
    std::fs::create_dir_all(&outside_cd).unwrap();
    std::fs::write(outside_cd.join("a.png"), SECRET).unwrap();
    std::fs::create_dir_all(objects.join("cd")).unwrap();
    symlink(&outside_cd, objects.join("cd").join(&h_cd)).unwrap();

    // A two-hex folder that is a link to a folder outside.
    let h_ef = fake_hash("ef");
    let outside_ef = root.join("outside-ef");
    std::fs::create_dir_all(outside_ef.join(&h_ef)).unwrap();
    std::fs::write(outside_ef.join(&h_ef).join("a.png"), SECRET).unwrap();
    symlink(&outside_ef, objects.join("ef")).unwrap();

    let paths = [
        format!("objects/{}/{h}/leak.txt", &h[..2]),
        format!("objects/{}/{h}/vault-leak.txt", &h[..2]),
        format!("objects/{}/{h}/vault-dir", &h[..2]),
        format!("objects/cd/{h_cd}/a.png"),
        format!("objects/ef/{h_ef}/a.png"),
    ];
    for method in ["GET", "HEAD"] {
        for p in &paths {
            let path = format!("{BASE}/attachments/{p}");
            let r = raw_get(&srv, method, &path).await;
            assert_400_without_secret(&r, &format!("{method} {path}"), method);
        }
    }
    let ok = raw_get(
        &srv,
        "GET",
        &format!("{BASE}/attachments/objects/{}/{h}/real.txt", &h[..2]),
    )
    .await;
    assert_eq!((ok.status, ok.body.as_str()), (200, "an attachment"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_attachment_is_404_with_its_own_text_distinct_from_an_unknown_route() {
    let srv = start().await;
    let h = plant_secrets(&srv);
    let missing = [
        // No such hash folder.
        object_path(&fake_hash("ab"), "gone.png"),
        // The hash folder exists; the name doesn't.
        object_path(&h, "gone.png"),
    ];
    for p in &missing {
        let path = format!("{BASE}/attachments/{p}");
        let got = fetch(&srv, Method::GET, &path).await;
        assert_eq!(got.status, 404, "GET {path}");
        assert_eq!(
            got.json(),
            json!({
                "error": {
                    "code": "not_found",
                    "message": format!("not found: attachment {p}"),
                }
            }),
            "GET {path}"
        );
        let head = fetch(&srv, Method::HEAD, &path).await;
        assert_eq!(head.status, 404, "HEAD {path}");
        assert!(head.body.is_empty(), "HEAD {path}: no body");
    }
    // An unknown route keeps the old server's text.
    for path in [
        format!("{BASE}/attachment/{}", missing[0]),
        format!("{BASE}/zz-no-such-route"),
    ] {
        let got = fetch(&srv, Method::GET, &path).await;
        assert_eq!(got.status, 404, "GET {path}");
        assert_eq!(
            got.json(),
            json!({
                "error": {
                    "code": "not_found",
                    "message": "not found: no route for this path",
                }
            }),
            "GET {path}"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 6: no token or a wrong one is the existing 401, and nothing is written
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_attachment_route_without_the_token_is_401_and_writes_nothing() {
    let srv = start().await;
    let vault = vault_dir(&srv);
    let stored = store_bytes(&vault, SECRET.as_bytes(), "kept.txt").unwrap();
    let get_path = format!("{BASE}/attachments/{}", markdown_url(&stored));
    let before = tree_snapshot(&vault.join("objects"));
    let http = client();

    // (authorization header, extra query)
    let bad: [(Option<String>, String); 5] = [
        (None, String::new()),
        (Some("Bearer wrong-token-139".to_string()), String::new()),
        (Some(format!("Basic {TEST_TOKEN}")), String::new()),
        (None, format!("&token={TEST_TOKEN}")),
        (None, format!("&access_token={TEST_TOKEN}")),
    ];
    for (authorization, query) in &bad {
        let what = format!("{authorization:?} {query:?}");
        let mut post = http
            .post(srv.url(&format!("{}{query}", upload_path("evil.bin"))))
            .body(b"evil".to_vec());
        let get_query = query.replacen('&', "?", 1);
        let mut get = http.get(srv.url(&format!("{get_path}{get_query}")));
        let mut head = http.head(srv.url(&format!("{get_path}{get_query}")));
        if let Some(value) = authorization {
            post = post.header("authorization", value);
            get = get.header("authorization", value);
            head = head.header("authorization", value);
        }
        let r = Reply::read(post.send().await.unwrap()).await;
        assert_eq!(r.status, 401, "POST {what}: {}", r.body);
        assert_eq!(r.c1_code(), "unauthorized", "POST {what}");
        let r = Reply::read(get.send().await.unwrap()).await;
        assert_eq!(r.status, 401, "GET {what}: {}", r.body);
        assert_eq!(r.c1_code(), "unauthorized", "GET {what}");
        assert!(!r.body.contains(SECRET), "GET {what}: served the file");
        let r = Reply::read(head.send().await.unwrap()).await;
        assert_eq!(r.status, 401, "HEAD {what}");
    }
    // Oversized bodies without the token are 401 too: auth runs first.
    for len in [BODY_LIMIT + 1, UPLOAD_LIMIT + 1] {
        for authorization in [None, Some("Bearer wrong-token-139")] {
            let r = raw_request(
                srv.addr(),
                &upload_head("POST", &upload_path("evil.bin"), authorization, Some(len)),
                b"",
            )
            .await;
            assert_eq!(r.status, 401, "{len} bytes, {authorization:?}: {}", r.body);
            assert_eq!(r.c1_code(), "unauthorized");
        }
    }
    assert_eq!(
        tree_snapshot(&vault.join("objects")),
        before,
        "nothing written"
    );

    // With the token, the same routes answer.
    let r = upload(&srv, "evil.bin", b"evil").await;
    assert!(
        is_stored(r.status),
        "POST with the token: {} {}",
        r.status,
        r.body
    );
    let got = fetch(&srv, Method::GET, &get_path).await;
    assert_eq!(got.status, 200, "GET with the token");
    assert!(got.body == SECRET.as_bytes());
    let head = fetch(&srv, Method::HEAD, &get_path).await;
    assert_eq!(head.status, 200, "HEAD with the token");
}

// ---------------------------------------------------------------------------
// AC 7: a large upload never holds the vault
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn get_notes_completes_while_a_50_mb_upload_is_in_flight() {
    let _big = BIG.lock().await;
    let srv = start().await;
    let len = 50 * 1024 * 1024;
    // Past every socket buffer: the server must be reading the body to take
    // this much of it.
    let at = 30 * 1024 * 1024;
    let (reached_tx, reached) = oneshot::channel();
    let (resume, resume_rx) = oneshot::channel();
    let pause = Pause {
        at,
        reached: reached_tx,
        resume: resume_rx,
    };
    let addr = srv.addr();
    let head = upload_head(
        "POST",
        &upload_path("fifty.bin"),
        Some(&srv.bearer()),
        Some(len),
    );
    let upload = tokio::spawn(stream_request(addr, head, len, false, Some(pause)));

    match tokio::time::timeout(WAIT, reached).await {
        Ok(Ok(())) => {}
        other => {
            let answer = if upload.is_finished() {
                format!("{:?}", upload.await)
            } else {
                "still waiting".to_string()
            };
            panic!("the server never took 30 MB of the upload ({other:?}); upload: {answer}");
        }
    }

    // The upload is mid-body; another request on the vault still answers.
    let notes = tokio::time::timeout(
        WAIT,
        fetch(&srv, Method::GET, &format!("{BASE}/notes?limit=3")),
    )
    .await
    .expect("GET /notes completed while the upload was in flight");
    assert_eq!(
        notes.status,
        200,
        "{:?}",
        String::from_utf8_lossy(&notes.body)
    );
    assert_eq!(notes.json(), json!({ "notes": [] }));
    assert!(!upload.is_finished(), "the upload is still in flight");

    resume.send(()).expect("resume the upload");
    let r = upload.await.expect("upload task");
    assert!(is_stored(r.status), "{r:?}");
    assert_eq!(r.json()["size"], json!(len));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_50_mb_upload_is_stored_while_another_request_holds_the_vault() {
    let _big = BIG.lock().await;
    let gate = Arc::new(GatedEmbedder::new(FakeEmbedder::new(8)));
    let _open = OpenOnDrop(gate.clone());
    let srv = EmbedderServer::start(gate.clone()).await;
    let vault = srv.root.path().join(VAULT);

    // POST /notes embeds its chunks under the vault lock: held at the gate,
    // it holds the vault.
    let notes_url = srv.url(&format!("{BASE}/notes"));
    let mut add_note = tokio::spawn(async move {
        let req = client()
            .post(notes_url)
            .header("authorization", format!("Bearer {TEST_TOKEN}"))
            .json(&json!({ "title": "Held", "content_md": "words that need embedding" }));
        Reply::read(req.send().await.expect("send POST /notes")).await
    });
    let probe = gate.clone();
    let entered = tokio::task::spawn_blocking(move || probe.wait_entered());
    tokio::select! {
        r = &mut add_note => {
            let r = r.unwrap();
            panic!("POST /notes answered before reaching the embedder: {} {}", r.status, r.body);
        }
        waited = tokio::time::timeout(WAIT, entered) => {
            match waited {
                Ok(Ok(true)) => {}
                other => panic!("POST /notes never reached the embedder: {other:?}"),
            }
        }
    }

    let len = 50 * 1024 * 1024;
    let head = upload_head(
        "POST",
        &upload_path("held.bin"),
        Some(&format!("Bearer {TEST_TOKEN}")),
        Some(len),
    );
    let upload = tokio::spawn(stream_request(srv.addr, head, len, false, None));

    // The store (hash and write) needs no vault lock.
    let stored = wait_for_stored(&vault, "held.bin", len as u64, &upload).await;
    if !stored {
        let answer = if upload.is_finished() {
            format!("{:?}", upload.await)
        } else {
            "still waiting".to_string()
        };
        panic!("the upload was not stored while another request held the vault; upload: {answer}");
    }
    assert!(!add_note.is_finished(), "the vault is still held");
    assert_eq!(gate.calls(), 1, "only POST /notes embedded");

    gate.release();
    let r = upload.await.expect("upload task");
    assert!(is_stored(r.status), "{r:?}");
    assert_eq!(r.json()["size"], json!(len));
    let note = add_note.await.expect("POST /notes task");
    assert_eq!(note.status, 201, "{}", note.body);
}

// ---------------------------------------------------------------------------
// AC 8: the full api::router() starts with the routes nested (D19)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_starts_with_the_attachment_routes_nested_under_the_vault_api() {
    // Each builds on its own (an axum path clash panics here).
    let _ = memex_mcp::server::api::attachments::router();
    let _ = memex_mcp::server::api::router();
    let srv = start().await;

    let bytes = b"nested".to_vec();
    let r = upload(&srv, "n.txt", &bytes).await;
    assert!(is_stored(r.status), "{} {}", r.status, r.body);
    let path = r.json()["path"].as_str().unwrap().to_string();
    let got = fetch(&srv, Method::GET, &format!("{BASE}/attachments/{path}")).await;
    assert_eq!(got.status, 200);
    assert!(got.body == bytes);

    // Under another vault name, the same routes answer for that vault.
    make_vault(srv.root(), "work");
    let r = Reply::read(
        client()
            .post(srv.url("/vaults/work/api/v1/attachments?name=w.txt"))
            .header("authorization", srv.bearer())
            .body(b"work bytes".to_vec())
            .send()
            .await
            .unwrap(),
    )
    .await;
    assert!(is_stored(r.status), "{} {}", r.status, r.body);
    let work_path = r.json()["path"].as_str().unwrap().to_string();
    assert!(srv.root().join("work").join(&work_path).is_file());
    assert!(
        !vault_dir(&srv).join(&work_path).exists(),
        "stored in its own vault"
    );

    // Released clients' routes still answer.
    for p in [
        format!("{BASE}/notes?limit=3"),
        format!("{BASE}/info"),
        "/api/v1/info".to_string(),
    ] {
        let got = fetch(&srv, Method::GET, &p).await;
        assert_eq!(got.status, 200, "GET {p}");
    }

    // Wrong methods get the C1 405 (the routes sit above the 405 fallback).
    let get_route = format!("{BASE}/attachments/{path}");
    let upload_route = format!("{BASE}/attachments");
    assert_wrong_method_is_c1_405(
        &srv,
        &[
            (upload_route.as_str(), &["POST"]),
            (get_route.as_str(), &["GET"]),
        ],
    )
    .await;
}
