//! WI #138 (Spec #123 R18-R22, TD "MCP transport"; Ledger L3, L4, L15): the
//! MCP tools `add_attachment` and `get_attachment`.
//!
//! - Local: `Memex::new` (the stdio `memex serve` transport, Local by
//!   default) served in process over an rmcp duplex, with a fixed agent
//!   session attached so the activity hook runs.
//! - Hosted: the vault server router (`POST /vaults/work/mcp`), whose
//!   `service_for` marks the transport Hosted.
//!
//! A refusal may come back as a tool payload `{"error":{"message":…}}`, a
//! `CallToolResult` with `isError`, or a JSON-RPC error; every refusal test
//! pins its exact message (Spec R19, R21, R15 texts) and that nothing was
//! stored. Where a symlink resolves to the refused place, the message may
//! name either the given or the resolved path.
//!
//! Every temp folder here is made with a visible prefix (`tempfile`'s
//! default `.tmp…` is itself a hidden component), and hidden fixtures are
//! built under it at run time (`<tmp>/.secret/key.txt`).
//!
//! The expected `markdown`, `path` and `type` come from memex-core's
//! attachments module, which pins those rules itself.

use std::collections::BTreeSet;
use std::fs;
use std::net::SocketAddr;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::symlink;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use axum::Router;
use memex_core::agents::presence::Transport;
use memex_core::attachments::{markdown_for, mime_for, store_bytes, MAX_ATTACHMENT_BYTES};
use memex_core::notes::{self, CreateNote};
use memex_core::{Caller, Vault};
use memex_mcp::presence::{AgentSession, AgentSessions, RequestKind};
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::model::{CallToolRequestParams, ClientCapabilities, ClientInfo, Implementation};
use rmcp::service::{RequestContext, RunningService};
use rmcp::{RoleClient, RoleServer, ServiceExt};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::task::JoinHandle;
use tower::ServiceExt as _;

const SESSION: &str = "01JA138AT0000000000000000A";
const CLIENT: &str = "test-agent";
const TOKEN: &str = "wi138-test-token-1b7e4c9a2d5f8e3b6a0c4d7e1f2a5b8c";
const ACCEPT: &str = "application/json, text/event-stream";
/// The longest any one MCP call may take before the test fails.
const CALL_TIMEOUT: Duration = Duration::from_secs(180);
/// The longest a refused FIFO may take before the test calls it blocked.
const FIFO_TIMEOUT: Duration = Duration::from_secs(30);
/// R21: the largest image returned as image content.
const IMAGE_LIMIT: usize = 5_242_880;
/// R21: the largest text file returned as text content.
const TEXT_LIMIT: usize = 1_048_576;
/// The hosted MCP request body limit (R20).
const BODY_LIMIT: usize = 8 * 1024 * 1024;

const PNG_HEAD: &[u8] = b"\x89PNG\r\n\x1a\n";

const EXACTLY_ONE: &str = "Send exactly one of file_path or data.";
const HOSTED_FILE_PATH: &str = "file_path works only with a local vault; send data instead.";
const NOT_ABSOLUTE: &str = "file_path must be an absolute path.";
const BAD_BASE64: &str = "data is not valid base64.";

fn hidden_text(path: &str) -> String {
    format!("{path} is hidden or inside a hidden folder and can't be attached.")
}

fn inside_vault_text(path: &str) -> String {
    format!("{path} is inside the vault and can't be attached.")
}

// ======================================================================
// Helpers: base64, hashes, paths.
// ======================================================================

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding.
fn b64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (chunk[0] as u32) << 16 | b1 << 8 | b2;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            B64[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            B64[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Decodes standard base64 (padding optional); panics on anything else.
fn unb64(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.bytes().filter(|&c| c != b'=') {
        let v = B64
            .iter()
            .position(|&t| t == c)
            .unwrap_or_else(|| panic!("not base64: {c:?}")) as u32;
        acc = acc << 6 | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    out
}

/// The base64 of `len` zero bytes, built without an encoder (all `A`s).
fn zeros_b64(len: usize) -> String {
    let mut s = "A".repeat(len / 3 * 4);
    match len % 3 {
        1 => s.push_str("AA=="),
        2 => s.push_str("AAA="),
        _ => {}
    }
    s
}

fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The decoded vault-relative path the store of `bytes` as `name` gives.
fn object_path(bytes: &[u8], name: &str) -> String {
    let hash = hex_sha256(bytes);
    format!("objects/{}/{hash}/{name}", &hash[..2])
}

/// The `{markdown, path, name, size, type}` the store of `bytes` under the
/// stored name `name` returns.
fn expected(bytes: &[u8], name: &str) -> Value {
    let hash = hex_sha256(bytes);
    json!({
        "markdown": markdown_for(name, &hash),
        "path": object_path(bytes, name),
        "name": name,
        "size": bytes.len() as u64,
        "type": mime_for(name),
    })
}

fn has_hidden_component(p: &Path) -> bool {
    p.components()
        .any(|c| matches!(c, Component::Normal(s) if s.as_bytes().starts_with(b".")))
}

/// A temp folder whose path (given and resolved) has no hidden component.
fn visible_tempdir(prefix: &str) -> TempDir {
    let dir = tempfile::Builder::new().prefix(prefix).tempdir().unwrap();
    let canonical = fs::canonicalize(dir.path()).unwrap();
    assert!(
        !has_hidden_component(dir.path()) && !has_hidden_component(&canonical),
        "precondition: the temp folder {} ({}) has no hidden component; set TMPDIR to a \
         visible folder",
        dir.path().display(),
        canonical.display()
    );
    dir
}

fn s(p: &Path) -> &str {
    p.to_str().expect("utf8 path")
}

fn canonical(p: &Path) -> String {
    fs::canonicalize(p).unwrap().to_string_lossy().into_owned()
}

/// Every file under `<vault>/objects/` (temp files included), vault-relative.
fn objects_in(vault: &Path) -> Vec<String> {
    fn walk(dir: &Path, base: &Path, out: &mut Vec<String>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(&path, base, out);
            } else {
                out.push(
                    path.strip_prefix(base)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
    }
    let mut out = Vec::new();
    walk(&vault.join("objects"), vault, &mut out);
    out.sort();
    out
}

/// A file of `len` bytes that takes no disk space (a hole).
fn sparse(path: &Path, len: u64) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::File::create(path).unwrap().set_len(len).unwrap();
}

fn mkfifo(path: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let made = Command::new("mkfifo")
        .arg(path)
        .status()
        .expect("run mkfifo");
    assert!(made.success(), "mkfifo {}", path.display());
}

// ======================================================================
// Results: a CallToolResult as JSON, or a JSON-RPC error message.
// ======================================================================

type Reply = Result<Value, String>;

/// The refusal message of `reply`; panics when it succeeded.
fn error_message(tool: &str, reply: &Reply) -> String {
    let result = match reply {
        Err(message) => return message.clone(),
        Ok(result) => result,
    };
    let text = result["content"][0]["text"].as_str().unwrap_or_default();
    if let Ok(v) = serde_json::from_str::<Value>(text) {
        if let Some(m) = v["error"]["message"].as_str() {
            return m.to_string();
        }
    }
    assert_eq!(
        result["isError"],
        json!(true),
        "{tool} should have been refused: {result}"
    );
    text.to_string()
}

/// The one content item of a successful `reply`.
fn content(tool: &str, reply: &Reply) -> Value {
    let result = reply
        .as_ref()
        .unwrap_or_else(|e| panic!("{tool}: JSON-RPC error: {e}"));
    assert_ne!(result["isError"], json!(true), "{tool} failed: {result}");
    let items = result["content"]
        .as_array()
        .unwrap_or_else(|| panic!("{tool}: a content list: {result}"));
    assert_eq!(items.len(), 1, "{tool}: one content item: {result}");
    items[0].clone()
}

/// The JSON text payload of a successful `reply` (no `error` key).
fn payload(tool: &str, reply: &Reply) -> Value {
    let item = content(tool, reply);
    assert_eq!(item["type"], json!("text"), "{tool}: a text item: {item}");
    let text = item["text"].as_str().unwrap();
    let v: Value =
        serde_json::from_str(text).unwrap_or_else(|e| panic!("{tool}: not JSON ({e}): {text}"));
    assert!(v.get("error").is_none(), "{tool} failed: {v}");
    v
}

/// The (MIME type, decoded bytes) of an image `reply`.
fn image(reply: &Reply) -> (String, Vec<u8>) {
    let item = content("get_attachment", reply);
    assert_eq!(item["type"], json!("image"), "an image item: {item}");
    let mime = item["mimeType"].as_str().unwrap().to_string();
    (mime, unb64(item["data"].as_str().unwrap()))
}

/// The text of a text `reply`.
fn text(reply: &Reply) -> String {
    let item = content("get_attachment", reply);
    assert_eq!(item["type"], json!("text"), "a text item: {item}");
    item["text"].as_str().unwrap().to_string()
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn key_set(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|n| n.to_string()).collect()
}

/// Asserts `message` is `text_for(path)` for the given or the resolved path.
fn assert_names_either(message: &str, given: &str, resolved: &str, text_for: fn(&str) -> String) {
    let allowed = [text_for(given), text_for(resolved)];
    assert!(
        allowed.iter().any(|a| a == message),
        "got {message:?}, want one of {allowed:?}"
    );
}

// ======================================================================
// Local: Memex::new over an rmcp duplex, with an agent session.
// ======================================================================

struct FixedSession;

impl AgentSessions for FixedSession {
    fn on_request(
        &self,
        _ctx: &RequestContext<RoleServer>,
        _kind: RequestKind,
    ) -> Option<AgentSession> {
        Some(AgentSession {
            session_id: SESSION.to_string(),
            client_name: CLIENT.to_string(),
            transport: Transport::Stdio,
        })
    }
}

/// A temp folder `<tmp>` with a vault at `<tmp>/vault` (one person note) and
/// a `<tmp>/files` folder, served locally.
struct Local {
    _dir: TempDir,
    root: PathBuf,
    vault: PathBuf,
    state: Arc<AppState>,
    client: RunningService<RoleClient, ClientInfo>,
    server: JoinHandle<()>,
}

impl Drop for Local {
    fn drop(&mut self) {
        self.server.abort();
    }
}

/// A temp folder with a vault at `<tmp>/vault` holding one person note.
fn vault_dir() -> (TempDir, PathBuf, PathBuf) {
    let dir = visible_tempdir("wi138-mcp-");
    let root = dir.path().to_path_buf();
    let vault = root.join("vault");
    let mut v = Vault::create(&vault).unwrap();
    notes::create_note_as(
        &mut v,
        CreateNote {
            title: Some("Project log".into()),
            content_md: "Screenshots go here.\n".into(),
            frontmatter: None,
        },
        Caller::Person,
    )
    .unwrap();
    drop(v);
    fs::create_dir(root.join("files")).unwrap();
    (dir, root, vault)
}

async fn local() -> Local {
    let (dir, root, vault) = vault_dir();
    let open = vault.clone();
    local_opened_at(dir, root, vault, &open).await
}

/// Serves the vault at `vault`, opened (and given to `AppState`) as `open`,
/// which may be a symlink to it.
async fn local_opened_at(dir: TempDir, root: PathBuf, vault: PathBuf, open: &Path) -> Local {
    let v = Vault::open(open).unwrap();
    let state = Arc::new(AppState::new(v, open.to_path_buf(), None));
    let memex = Memex::new(state.clone()).with_sessions(Arc::new(FixedSession));
    let (server_io, client_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(async move {
        if let Ok(running) = memex.serve(server_io).await {
            let _ = running.waiting().await;
        }
    });
    let client = ClientInfo::new(
        ClientCapabilities::default(),
        Implementation::new(CLIENT, "1.0.0"),
    )
    .serve(client_io)
    .await
    .expect("initialize handshake");
    Local {
        _dir: dir,
        root,
        vault,
        state,
        client,
        server,
    }
}

impl Local {
    async fn call_within(&self, limit: Duration, tool: &str, args: Value) -> Reply {
        let Value::Object(arguments) = args else {
            panic!("tool arguments are an object");
        };
        let call = self
            .client
            .call_tool(CallToolRequestParams::new(tool.to_string()).with_arguments(arguments));
        match tokio::time::timeout(limit, call).await {
            Err(_) => panic!("{tool}: no answer within {limit:?}"),
            Ok(Err(rmcp::ServiceError::McpError(e))) => Err(e.message.to_string()),
            Ok(Err(e)) => panic!("{tool}: {e}"),
            Ok(Ok(result)) => Ok(serde_json::to_value(result).expect("serialize CallToolResult")),
        }
    }

    async fn call(&self, tool: &str, args: Value) -> Reply {
        self.call_within(CALL_TIMEOUT, tool, args).await
    }

    /// Writes `bytes` to `<tmp>/<rel>`, making its folders.
    fn file(&self, rel: &str, bytes: &[u8]) -> PathBuf {
        let path = self.root.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        path
    }

    fn objects(&self) -> Vec<String> {
        objects_in(&self.vault)
    }

    /// Stores `bytes` as `name` through the core (test setup, not under test).
    fn stored(&self, bytes: &[u8], name: &str) -> String {
        store_bytes(&self.vault, bytes, name).unwrap().path
    }

    /// Every note as (id, version, content_md, updated_at), by id.
    async fn notes(&self) -> Vec<(String, i64, String, i64)> {
        let vault = self.state.vault.lock().await;
        let mut stmt = vault
            .connection_ref()
            .prepare("SELECT id, version, content_md, updated_at FROM notes ORDER BY id")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap();
        rows.map(Result::unwrap).collect()
    }

    async fn activity_rows(&self) -> i64 {
        let vault = self.state.vault.lock().await;
        vault
            .connection_ref()
            .query_row("SELECT COUNT(*) FROM agent_activity", [], |r| r.get(0))
            .unwrap()
    }

    /// `add_attachment` with `file_path` (and no name); asserts it was
    /// refused with nothing stored; returns the message.
    async fn refused_path(&self, file_path: &str) -> String {
        let reply = self
            .call("add_attachment", json!({ "file_path": file_path }))
            .await;
        let message = error_message("add_attachment", &reply);
        assert_eq!(self.objects(), Vec::<String>::new(), "nothing stored");
        message
    }

    async fn get(&self, path: &str) -> Reply {
        self.call("get_attachment", json!({ "path": path })).await
    }
}

// ======================================================================
// Hosted: the vault server router, vault `work`.
// ======================================================================

struct Hosted {
    _dir: TempDir,
    root: PathBuf,
    work: PathBuf,
    router: Router,
}

fn hosted() -> Hosted {
    let dir = visible_tempdir("wi138-hosted-");
    let root = std::path::absolute(dir.path().join("root")).unwrap();
    fs::create_dir(&root).unwrap();
    let work = root.join("work");
    drop(Vault::create(&work).unwrap());
    let router = router(ServerConfig::new(root.clone(), TOKEN));
    Hosted {
        _dir: dir,
        root,
        work,
        router,
    }
}

fn peer() -> SocketAddr {
    SocketAddr::from(([10, 0, 0, 1], 50_000))
}

impl Hosted {
    /// POSTs `body` to `/vaults/work/mcp`; the status and the body, as JSON.
    async fn post(&self, body: Vec<u8>) -> (StatusCode, Value) {
        let req = Request::builder()
            .method("POST")
            .uri("/vaults/work/mcp")
            .header("host", "localhost")
            .header("authorization", format!("Bearer {TOKEN}"))
            .header("content-type", "application/json")
            .header("accept", ACCEPT)
            .extension(ConnectInfo(peer()))
            .body(Body::from(body))
            .unwrap();
        let resp = tokio::time::timeout(CALL_TIMEOUT, self.router.clone().oneshot(req))
            .await
            .expect("the server answers in time")
            .expect("router answers");
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("read body");
        let v = serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| panic!("JSON body: {}", String::from_utf8_lossy(&bytes)));
        (status, v)
    }

    fn call_body(tool: &str, args: &Value) -> Vec<u8> {
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": { "name": tool, "arguments": args },
        })
        .to_string()
        .into_bytes()
    }

    async fn call(&self, tool: &str, args: Value) -> Reply {
        let (status, body) = self.post(Self::call_body(tool, &args)).await;
        assert_eq!(status, StatusCode::OK, "MCP POST answers 200: {body}");
        match body.get("result") {
            Some(result) => Ok(result.clone()),
            None => Err(body["error"]["message"]
                .as_str()
                .unwrap_or_else(|| panic!("a result or an error: {body}"))
                .to_string()),
        }
    }

    fn objects(&self) -> Vec<String> {
        objects_in(&self.work)
    }

    fn stored(&self, bytes: &[u8], name: &str) -> String {
        store_bytes(&self.work, bytes, name).unwrap().path
    }
}

#[test]
fn wi138_base64_helpers_round_trip() {
    assert_eq!(b64(b"Man"), "TWFu");
    assert_eq!(b64(b"Ma"), "TWE=");
    assert_eq!(b64(b"M"), "TQ==");
    for n in 0..8 {
        assert_eq!(zeros_b64(n), b64(&vec![0u8; n]), "{n} zeros");
    }
    let bytes: Vec<u8> = (0..=255u8).collect();
    assert_eq!(unb64(&b64(&bytes)), bytes);
}

// ======================================================================
// AC 3 (R18): add_attachment stores by file_path and by data; no Agent
// activity entry; no note changes.
// ======================================================================

#[tokio::test]
async fn local_add_attachment_file_path_stores_the_file_and_returns_the_five_fields() {
    let w = local().await;
    let notes_before = w.notes().await;
    let bytes: &[u8] = b"\x89PNG\r\n\x1a\nwi138 chart pixels";
    let src = w.file("files/Revenue chart.png", bytes);

    let reply = w
        .call("add_attachment", json!({ "file_path": s(&src) }))
        .await;
    let got = payload("add_attachment", &reply);
    assert_eq!(got, expected(bytes, "Revenue chart.png"), "the base name");
    assert_eq!(
        fs::read(w.vault.join(object_path(bytes, "Revenue chart.png"))).unwrap(),
        bytes
    );

    // `name` overrides the base name.
    let reply = w
        .call(
            "add_attachment",
            json!({ "file_path": s(&src), "name": "Q3 chart.png" }),
        )
        .await;
    assert_eq!(
        payload("add_attachment", &reply),
        expected(bytes, "Q3 chart.png")
    );

    assert_eq!(w.activity_rows().await, 0, "no Agent activity entry");
    assert_eq!(w.notes().await, notes_before, "no note changed");

    // Control: the same world logs a note write, so zero above is not vacuous.
    let created = w
        .call(
            "create_note",
            json!({ "title": "Control", "content_md": "logged\n" }),
        )
        .await;
    payload("create_note", &created);
    assert_eq!(w.activity_rows().await, 1, "a create_note is logged");
}

#[tokio::test]
async fn local_add_attachment_data_stores_the_bytes_under_name_and_returns_the_five_fields() {
    let w = local().await;
    let notes_before = w.notes().await;
    let bytes: &[u8] = b"%PDF-1.4 wi138 agent-made report";

    let reply = w
        .call(
            "add_attachment",
            json!({ "data": b64(bytes), "name": "Q3 report.pdf" }),
        )
        .await;
    let got = payload("add_attachment", &reply);
    assert_eq!(got, expected(bytes, "Q3 report.pdf"));
    assert_eq!(
        keys(&got),
        key_set(&["markdown", "path", "name", "size", "type"])
    );
    let hash = hex_sha256(bytes);
    assert_eq!(
        got["markdown"],
        json!(format!(
            "[Q3 report.pdf](objects/{}/{hash}/Q3%20report.pdf)",
            &hash[..2]
        ))
    );
    assert_eq!(
        fs::read(w.vault.join(object_path(bytes, "Q3 report.pdf"))).unwrap(),
        bytes
    );

    assert_eq!(w.activity_rows().await, 0, "no Agent activity entry");
    assert_eq!(w.notes().await, notes_before, "no note changed");

    let created = w
        .call(
            "create_note",
            json!({ "title": "Control", "content_md": "logged\n" }),
        )
        .await;
    payload("create_note", &created);
    assert_eq!(w.activity_rows().await, 1, "a create_note is logged");
}

#[tokio::test]
async fn add_attachment_data_without_name_is_refused_while_data_with_name_stores() {
    let w = local().await;
    // Control: the same data with a name is stored.
    let named: &[u8] = b"wi138 named bytes";
    let reply = w
        .call(
            "add_attachment",
            json!({ "data": b64(named), "name": "named.bin" }),
        )
        .await;
    assert_eq!(
        payload("add_attachment", &reply),
        expected(named, "named.bin")
    );

    // `name` is required with `data` (R18).
    let reply = w
        .call("add_attachment", json!({ "data": b64(b"no name given") }))
        .await;
    let message = error_message("add_attachment", &reply);
    assert!(!message.is_empty(), "a refusal message");
    assert_eq!(
        w.objects(),
        vec![object_path(named, "named.bin")],
        "the nameless data is not stored"
    );
}

#[tokio::test]
async fn add_attachment_file_path_follows_a_visible_symlink_and_accepts_a_file_in_objects() {
    let w = local().await;
    // A visible link to a visible file outside the vault stores the target.
    let bytes: &[u8] = b"wi138 linked csv\n1,2\n";
    let target = w.file("files/real/data.csv", bytes);
    let link = w.root.join("files/data-link.csv");
    symlink(&target, &link).unwrap();
    let reply = w
        .call(
            "add_attachment",
            json!({ "file_path": s(&link), "name": "data.csv" }),
        )
        .await;
    assert_eq!(
        payload("add_attachment", &reply),
        expected(bytes, "data.csv")
    );

    // A file already in objects/ is inside the vault but not outside
    // objects/, so it may be attached again (R19).
    let path = w.stored(b"\x89PNG\r\n\x1a\nalready stored", "kept.png");
    let reply = w
        .call(
            "add_attachment",
            json!({ "file_path": s(&w.vault.join(&path)) }),
        )
        .await;
    let got = payload("add_attachment", &reply);
    assert_eq!(got["path"], json!(path), "{got}");
}

// ======================================================================
// AC 4 (R19): every refusal with its exact text; nothing stored.
// ======================================================================

#[tokio::test]
async fn add_attachment_refuses_both_and_neither_of_file_path_and_data() {
    let w = local().await;
    let src = w.file("files/ok.txt", b"fine");
    for args in [
        json!({ "file_path": s(&src), "data": b64(b"fine"), "name": "ok.txt" }),
        json!({ "name": "ok.txt" }),
        json!({}),
    ] {
        let reply = w.call("add_attachment", args.clone()).await;
        assert_eq!(
            error_message("add_attachment", &reply),
            EXACTLY_ONE,
            "{args}"
        );
    }
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
}

#[tokio::test]
async fn hosted_add_attachment_refuses_file_path() {
    let h = hosted();
    let outside = h.root.parent().unwrap().join("files/report.pdf");
    fs::create_dir_all(outside.parent().unwrap()).unwrap();
    fs::write(&outside, b"%PDF-1.4 on the server's disk").unwrap();

    for args in [
        json!({ "file_path": s(&outside) }),
        json!({ "file_path": s(&outside), "name": "report.pdf" }),
    ] {
        let reply = h.call("add_attachment", args.clone()).await;
        assert_eq!(
            error_message("add_attachment", &reply),
            HOSTED_FILE_PATH,
            "{args}"
        );
    }
    assert_eq!(h.objects(), Vec::<String>::new(), "nothing stored");
}

#[tokio::test]
async fn add_attachment_refuses_a_relative_file_path() {
    let w = local().await;
    w.file("files/report.pdf", b"%PDF-1.4");
    for rel in ["files/report.pdf", "report.pdf", "./files/report.pdf"] {
        assert_eq!(w.refused_path(rel).await, NOT_ABSOLUTE, "{rel}");
    }
}

#[tokio::test]
async fn add_attachment_refuses_a_hidden_file() {
    let w = local().await;
    let env = w.file("files/.env", b"API_KEY=wi138-not-a-real-key");
    assert_eq!(w.refused_path(s(&env)).await, hidden_text(s(&env)));

    // A hidden link to a visible file: the given path is hidden.
    let visible = w.file("files/visible.txt", b"visible");
    let link = w.root.join("files/.visible-link");
    symlink(&visible, &link).unwrap();
    assert_eq!(w.refused_path(s(&link)).await, hidden_text(s(&link)));
}

#[tokio::test]
async fn add_attachment_refuses_a_file_in_a_hidden_folder() {
    let w = local().await;
    let key = w.file(".secret/key.txt", b"wi138 fake private key");
    assert_eq!(w.refused_path(s(&key)).await, hidden_text(s(&key)));

    let deep = w.file("files/.aws/nested/credentials.txt", b"wi138 fake creds");
    assert_eq!(w.refused_path(s(&deep)).await, hidden_text(s(&deep)));
}

#[tokio::test]
async fn add_attachment_refuses_a_symlink_in_a_visible_folder_pointing_into_a_hidden_folder() {
    let w = local().await;
    let key = w.file(".secret/key.txt", b"wi138 fake private key");

    // A file link: <tmp>/files/key.txt -> <tmp>/.secret/key.txt.
    let link = w.root.join("files/key.txt");
    symlink(&key, &link).unwrap();
    let message = w.refused_path(s(&link)).await;
    assert_names_either(&message, s(&link), &canonical(&link), hidden_text);

    // A folder link: <tmp>/files/keys -> <tmp>/.secret, then keys/key.txt.
    let folder = w.root.join("files/keys");
    symlink(w.root.join(".secret"), &folder).unwrap();
    let through = folder.join("key.txt");
    let message = w.refused_path(s(&through)).await;
    assert_names_either(&message, s(&through), &canonical(&through), hidden_text);

    // A relative link target resolves the same way.
    let rel_link = w.root.join("files/rel-key.txt");
    symlink("../.secret/key.txt", &rel_link).unwrap();
    let message = w.refused_path(s(&rel_link)).await;
    assert_names_either(&message, s(&rel_link), &canonical(&rel_link), hidden_text);
}

#[tokio::test]
async fn add_attachment_refuses_a_path_inside_the_vault_outside_objects() {
    let w = local().await;
    // A file at the vault root, given as the vault's own path.
    let in_root = w.vault.join("report.pdf");
    fs::write(&in_root, b"%PDF-1.4 in the vault folder").unwrap();
    assert_eq!(
        w.refused_path(s(&in_root)).await,
        inside_vault_text(s(&in_root))
    );

    // The vault's database, given by its resolved path (on macOS the temp
    // folder is under /var -> /private/var, so this differs from vault_path).
    let db = PathBuf::from(canonical(&w.vault)).join("memex.db");
    assert_eq!(w.refused_path(s(&db)).await, inside_vault_text(s(&db)));

    // A visible link outside the vault pointing at the vault's database.
    let link = w.root.join("files/db-link.bin");
    symlink(w.vault.join("memex.db"), &link).unwrap();
    let message = w.refused_path(s(&link)).await;
    assert_names_either(&message, s(&link), &canonical(&link), inside_vault_text);

    // A link to the vault folder itself, then a file through it.
    let alias = w.root.join("files/vault-alias");
    symlink(&w.vault, &alias).unwrap();
    let through = alias.join("report.pdf");
    let message = w.refused_path(s(&through)).await;
    assert_names_either(
        &message,
        s(&through),
        &canonical(&through),
        inside_vault_text,
    );
}

#[tokio::test]
async fn add_attachment_refuses_a_path_inside_a_vault_opened_through_a_symlink() {
    // The vault folder's own symlinks are resolved too: the vault is served
    // as <tmp>/vault-link -> <tmp>/vault, and the file is given by its real
    // path.
    let (dir, root, vault) = vault_dir();
    let open = root.join("vault-link");
    symlink(&vault, &open).unwrap();
    let w = local_opened_at(dir, root, vault, &open).await;
    let real = w.vault.join("report.pdf");
    fs::write(&real, b"%PDF-1.4 in the vault folder").unwrap();

    let message = w.refused_path(s(&real)).await;
    assert_names_either(&message, s(&real), &canonical(&real), inside_vault_text);

    let via_link = open.join("report.pdf");
    let message = w.refused_path(s(&via_link)).await;
    assert_names_either(
        &message,
        s(&via_link),
        &canonical(&via_link),
        inside_vault_text,
    );
}

#[tokio::test]
async fn add_attachment_file_path_refuses_one_byte_over_100_mb_and_accepts_exactly_100_mb() {
    let w = local().await;
    let big = w.root.join("files/big.bin");
    sparse(&big, MAX_ATTACHMENT_BYTES + 1);
    assert_eq!(
        w.refused_path(s(&big)).await,
        "big.bin is larger than 100 MB and wasn't attached."
    );

    fs::File::options()
        .write(true)
        .open(&big)
        .unwrap()
        .set_len(MAX_ATTACHMENT_BYTES)
        .unwrap();
    let reply = w
        .call("add_attachment", json!({ "file_path": s(&big) }))
        .await;
    let got = payload("add_attachment", &reply);
    assert_eq!(got["size"], json!(MAX_ATTACHMENT_BYTES), "{got}");
    assert_eq!(got["name"], json!("big.bin"));
    assert_eq!(
        fs::metadata(w.vault.join(got["path"].as_str().unwrap()))
            .unwrap()
            .len(),
        MAX_ATTACHMENT_BYTES
    );
}

#[tokio::test]
async fn add_attachment_refuses_a_folder() {
    let w = local().await;
    let folder = w.root.join("files/Screenshots");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("inside.png"), b"\x89PNG inside").unwrap();
    assert_eq!(
        w.refused_path(s(&folder)).await,
        "Folders can't be attached."
    );
}

#[tokio::test]
async fn add_attachment_refuses_a_fifo_without_blocking() {
    let w = local().await;
    let fifo = w.root.join("files/pipe");
    mkfifo(&fifo);
    let reply = w
        .call_within(
            FIFO_TIMEOUT,
            "add_attachment",
            json!({ "file_path": s(&fifo) }),
        )
        .await;
    assert_eq!(
        error_message("add_attachment", &reply),
        "pipe isn't a regular file and wasn't attached."
    );
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
}

#[tokio::test]
async fn add_attachment_refuses_invalid_base64() {
    let w = local().await;
    for data in ["wi138 is not base64!", "%%%%", "QUJD*A=="] {
        let reply = w
            .call("add_attachment", json!({ "data": data, "name": "x.bin" }))
            .await;
        assert_eq!(
            error_message("add_attachment", &reply),
            BAD_BASE64,
            "{data:?}"
        );
    }
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
}

// ======================================================================
// AC 5 (R20): local data up to 100 MB; hosted bounded by the 8 MiB body.
// ======================================================================

#[tokio::test]
async fn local_add_attachment_data_accepts_exactly_100_mb_and_refuses_one_byte_more() {
    let w = local().await;
    let max = MAX_ATTACHMENT_BYTES as usize;

    let reply = w
        .call(
            "add_attachment",
            json!({ "data": zeros_b64(max + 1), "name": "edge.bin" }),
        )
        .await;
    assert_eq!(
        error_message("add_attachment", &reply),
        "edge.bin is larger than 100 MB and wasn't attached."
    );
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");

    let reply = w
        .call(
            "add_attachment",
            json!({ "data": zeros_b64(max), "name": "edge.bin" }),
        )
        .await;
    let got = payload("add_attachment", &reply);
    assert_eq!(got, expected(&vec![0u8; max], "edge.bin"));
    assert_eq!(
        fs::metadata(w.vault.join(got["path"].as_str().unwrap()))
            .unwrap()
            .len(),
        MAX_ATTACHMENT_BYTES
    );
}

#[tokio::test]
async fn hosted_add_attachment_data_within_8_mib_stores_and_a_body_over_8_mib_gets_413() {
    let h = hosted();
    // About 6 MB of file data fits the 8 MiB body after base64 (R20).
    let bytes: Vec<u8> = (0..6_000_000u32).map(|i| (i % 251) as u8).collect();
    let args = json!({ "data": b64(&bytes), "name": "scan.bin" });
    assert!(Hosted::call_body("add_attachment", &args).len() < BODY_LIMIT);
    let reply = h.call("add_attachment", args).await;
    let got = payload("add_attachment", &reply);
    assert_eq!(got, expected(&bytes, "scan.bin"));
    assert_eq!(
        fs::read(h.work.join(object_path(&bytes, "scan.bin"))).unwrap(),
        bytes
    );

    // A body over the limit gets the existing C1 413.
    let big = json!({ "data": zeros_b64(BODY_LIMIT), "name": "big.bin" });
    let body = Hosted::call_body("add_attachment", &big);
    assert!(body.len() > BODY_LIMIT);
    let (status, reply) = h.post(body).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "{reply}");
    assert_eq!(
        reply["error"]["code"],
        json!("payload_too_large"),
        "{reply}"
    );
    assert_eq!(
        h.objects(),
        vec![object_path(&bytes, "scan.bin")],
        "only the first file is stored"
    );
}

// ======================================================================
// AC 6 (R21): get_attachment.
// ======================================================================

/// `len` bytes of an image: `head`, then filler.
fn image_bytes(head: &[u8], len: usize) -> Vec<u8> {
    let mut b = head.to_vec();
    b.resize(len, 0x5a);
    b
}

#[tokio::test]
async fn get_attachment_of_a_png_up_to_5_mb_returns_image_content() {
    let w = local().await;
    for len in [64, IMAGE_LIMIT] {
        let bytes = image_bytes(PNG_HEAD, len);
        let path = w.stored(&bytes, &format!("shot-{len}.png"));
        let (mime, data) = image(&w.get(&path).await);
        assert_eq!(mime, "image/png", "{len} bytes");
        assert!(data == bytes, "{len} bytes: the image's own bytes");
    }
}

#[tokio::test]
async fn get_attachment_returns_image_content_for_jpeg_gif_and_webp() {
    let w = local().await;
    let cases: [(&str, &[u8], &str); 4] = [
        (
            "photo.jpg",
            b"\xff\xd8\xff\xe0\x00\x10JFIF\x00",
            "image/jpeg",
        ),
        (
            "photo.jpeg",
            b"\xff\xd8\xff\xe1\x00\x10Exif\x00",
            "image/jpeg",
        ),
        ("loop.gif", b"GIF89a\x01\x00\x01\x00", "image/gif"),
        ("still.webp", b"RIFF\x24\x00\x00\x00WEBPVP8 ", "image/webp"),
    ];
    for (name, head, want) in cases {
        let bytes = image_bytes(head, 200);
        let path = w.stored(&bytes, name);
        let (mime, data) = image(&w.get(&path).await);
        assert_eq!(mime, want, "{name}");
        assert_eq!(data, bytes, "{name}");
    }
}

#[tokio::test]
async fn get_attachment_of_a_md_up_to_1_mb_returns_its_text() {
    let w = local().await;
    let small = "# Meeting notes\n\n- ship it\n";
    let path = w.stored(small.as_bytes(), "notes.md");
    assert_eq!(text(&w.get(&path).await), small);

    let edge = "x".repeat(TEXT_LIMIT);
    let path = w.stored(edge.as_bytes(), "edge.md");
    assert!(text(&w.get(&path).await) == edge, "exactly 1 MB is text");
}

#[tokio::test]
async fn get_attachment_returns_text_for_txt_csv_and_json() {
    let w = local().await;
    for (name, body) in [
        ("todo.txt", "buy milk\n"),
        ("table.csv", "a,b\n1,2\n"),
        ("data.json", "{\"k\": [1, 2]}\n"),
        ("notes.md", "*emphasis*\n"),
    ] {
        let path = w.stored(body.as_bytes(), name);
        assert_eq!(text(&w.get(&path).await), body, "{name}");
    }
}

#[tokio::test]
async fn get_attachment_replaces_invalid_utf8_bytes() {
    let w = local().await;
    let path = w.stored(b"caf\xff au lait\n", "menu.txt");
    assert_eq!(text(&w.get(&path).await), "caf\u{FFFD} au lait\n");
}

/// Asserts `details` is `{name, size, type, file_path}` with `file_path` the
/// absolute path of `<vault>/<path>`.
fn assert_local_details(details: &Value, vault: &Path, path: &str, name: &str, size: usize) {
    assert_eq!(
        keys(details),
        key_set(&["name", "size", "type", "file_path"]),
        "{details}"
    );
    assert_eq!(details["name"], json!(name));
    assert_eq!(details["size"], json!(size));
    assert_eq!(details["type"], json!(mime_for(name)));
    let file_path = Path::new(details["file_path"].as_str().unwrap());
    assert!(file_path.is_absolute(), "{details}");
    assert_eq!(
        fs::canonicalize(file_path).unwrap(),
        fs::canonicalize(vault.join(path)).unwrap(),
        "file_path is the attachment's file"
    );
}

#[tokio::test]
async fn get_attachment_of_a_pdf_returns_name_size_type_and_file_path_on_local() {
    let w = local().await;
    let bytes = b"%PDF-1.4 wi138 quarterly report";
    let path = w.stored(bytes, "Q3 report.pdf");
    let details = payload("get_attachment", &w.get(&path).await);
    assert_local_details(&details, &w.vault, &path, "Q3 report.pdf", bytes.len());
}

#[tokio::test]
async fn get_attachment_of_an_image_over_5_mb_returns_its_details() {
    let w = local().await;
    for len in [IMAGE_LIMIT + 1, 6_000_000] {
        let bytes = image_bytes(PNG_HEAD, len);
        let name = format!("big-{len}.png");
        let path = w.stored(&bytes, &name);
        let details = payload("get_attachment", &w.get(&path).await);
        assert_local_details(&details, &w.vault, &path, &name, len);
    }
}

#[tokio::test]
async fn get_attachment_of_text_over_1_mb_returns_its_details() {
    let w = local().await;
    let body = "y".repeat(TEXT_LIMIT + 1);
    let path = w.stored(body.as_bytes(), "long.md");
    let details = payload("get_attachment", &w.get(&path).await);
    assert_local_details(&details, &w.vault, &path, "long.md", TEXT_LIMIT + 1);
}

#[tokio::test]
async fn hosted_get_attachment_details_have_no_file_path() {
    let h = hosted();
    let get = |path: String| {
        let h = &h;
        async move { h.call("get_attachment", json!({ "path": path })).await }
    };

    let pdf = b"%PDF-1.4 hosted report";
    let details = payload("get_attachment", &get(h.stored(pdf, "report.pdf")).await);
    assert_eq!(
        details,
        json!({ "name": "report.pdf", "size": pdf.len(), "type": "application/pdf" })
    );

    let big = image_bytes(PNG_HEAD, 6_000_000);
    let details = payload("get_attachment", &get(h.stored(&big, "big.png")).await);
    assert_eq!(
        details,
        json!({ "name": "big.png", "size": 6_000_000, "type": "image/png" })
    );

    // Image content works the same on hosted.
    let small = image_bytes(PNG_HEAD, 64);
    let (mime, data) = image(&get(h.stored(&small, "small.png")).await);
    assert_eq!((mime.as_str(), data), ("image/png", small));
}

#[tokio::test]
async fn get_attachment_tries_the_path_as_given_then_percent_decoded() {
    let w = local().await;
    let bytes = b"%PDF-1.4 wi138 encoded names";
    let spaced = w.stored(bytes, "Q3 report.pdf");
    let hash = hex_sha256(bytes);
    let dir = format!("objects/{}/{hash}", &hash[..2]);

    // The markdown destination form (R3) works.
    let encoded = format!("{dir}/Q3%20report.pdf");
    let details = payload("get_attachment", &w.get(&encoded).await);
    assert_eq!(details["name"], json!("Q3 report.pdf"), "{details}");
    // So does the decoded path.
    let details = payload("get_attachment", &w.get(&spaced).await);
    assert_eq!(details["name"], json!("Q3 report.pdf"), "{details}");

    // As given first: a stored name that itself holds `%20`.
    w.stored(bytes, "a%20b.pdf");
    w.stored(bytes, "a b.pdf");
    let details = payload("get_attachment", &w.get(&format!("{dir}/a%20b.pdf")).await);
    assert_eq!(details["name"], json!("a%20b.pdf"), "tried as given first");
    let details = payload(
        "get_attachment",
        &w.get(&format!("{dir}/a%2520b.pdf")).await,
    );
    assert_eq!(details["name"], json!("a%20b.pdf"), "then decoded once");
}

#[tokio::test]
async fn get_attachment_of_a_non_attachment_path_gives_the_exact_error() {
    let w = local().await;
    let hash = hex_sha256(b"wi138 any bytes");
    let upper = hash.to_uppercase();
    let paths = [
        "memex.db".to_string(),
        "notes/today.md".to_string(),
        "https://example.com/cat.png".to_string(),
        format!("objects/zz/{hash}/cat.png"),
        format!("objects/{}/{upper}/cat.png", &upper[..2]),
        format!("objects/{}/{hash}/..", &hash[..2]),
        format!("objects/{}/{}/cat.png", &hash[..2], &hash[..63]),
    ];
    for path in paths {
        let reply = w.get(&path).await;
        assert_eq!(
            error_message("get_attachment", &reply),
            format!("Not an attachment path: {path}"),
        );
    }
}

#[tokio::test]
async fn get_attachment_of_a_missing_file_gives_the_exact_error() {
    let w = local().await;
    let path = object_path(b"wi138 never stored", "gone.png");
    let reply = w.get(&path).await;
    assert_eq!(
        error_message("get_attachment", &reply),
        format!("Attachment not found: {path}")
    );

    // A stored file's folder with another name is still missing.
    let kept = w.stored(b"wi138 stored", "kept.txt");
    let other = kept.replace("kept.txt", "other.txt");
    let reply = w.get(&other).await;
    assert_eq!(
        error_message("get_attachment", &reply),
        format!("Attachment not found: {other}")
    );
}

#[tokio::test]
async fn get_attachment_never_reads_outside_objects() {
    let w = local().await;
    let hash = hex_sha256(b"wi138 traversal");
    for path in [
        format!("objects/{}/{hash}/..%2F..%2F..%2Fmemex.db", &hash[..2]),
        format!("objects/{}/{hash}/%2E%2E", &hash[..2]),
        "objects/../memex.db".to_string(),
    ] {
        let reply = w.get(&path).await;
        let message = error_message("get_attachment", &reply);
        assert!(
            message == format!("Not an attachment path: {path}")
                || message == format!("Attachment not found: {path}"),
            "{path}: {message}"
        );
    }
}

// ======================================================================
// AC 7 (R18): tools/list.
// ======================================================================

#[tokio::test]
async fn tools_list_includes_add_attachment_and_get_attachment_with_their_parameters() {
    let w = local().await;
    let tools = w.client.list_all_tools().await.expect("tools/list");
    let find = |name: &str| -> Value {
        let tool = tools
            .iter()
            .find(|t| t.name == name)
            .unwrap_or_else(|| panic!("tools/list includes {name}"));
        serde_json::to_value(tool).unwrap()
    };

    let add = find("add_attachment");
    let props = keys(&add["inputSchema"]["properties"]);
    for p in ["file_path", "data", "name"] {
        assert!(props.contains(p), "add_attachment takes {p}: {add}");
    }
    let required: Vec<&str> = add["inputSchema"]["required"]
        .as_array()
        .map(|r| r.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    assert!(
        required.is_empty(),
        "no add_attachment parameter is schema-required, so the tool's own exactly-one \
         refusal answers: {add}"
    );
    let description = add["description"].as_str().unwrap_or_default();
    for placed_by in ["create_note", "edit_note", "append_to_daily_note"] {
        assert!(
            description.contains(placed_by),
            "the description tells the agent to place markdown with {placed_by}: {description}"
        );
    }

    let get = find("get_attachment");
    assert!(
        keys(&get["inputSchema"]["properties"]).contains("path"),
        "get_attachment takes path: {get}"
    );
}

// ======================================================================
// WI #138 verify: contracts the handoff listed as unpinned (R19, R21).
// ======================================================================

/// The C1 error object `{code, message}` of a refused `reply`.
fn error_object(reply: &Reply) -> Value {
    let result = reply.as_ref().expect("a tool result, not a JSON-RPC error");
    let text = result["content"][0]["text"].as_str().unwrap_or_default();
    let v: Value = serde_json::from_str(text).unwrap_or_else(|e| panic!("C1 JSON ({e}): {text}"));
    assert!(v["error"].is_object(), "refused: {result}");
    v["error"].clone()
}

#[tokio::test]
async fn add_attachment_refuses_a_missing_file_path_as_not_found_and_a_hidden_one_as_hidden() {
    let w = local().await;
    let missing = w.root.join("files/never-written.txt");
    let reply = w
        .call("add_attachment", json!({ "file_path": s(&missing) }))
        .await;
    let err = error_object(&reply);
    assert_eq!(err["code"], json!("not_found"), "{err}");
    assert!(
        err["message"]
            .as_str()
            .unwrap()
            .starts_with(&format!("{} can't be read: ", s(&missing))),
        "{err}"
    );
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");

    // A missing hidden path is refused as hidden, before it is resolved, so
    // the refusal does not say whether the path exists.
    let hidden = w.root.join(".secret/never-written.txt");
    assert_eq!(w.refused_path(s(&hidden)).await, hidden_text(s(&hidden)));
}

#[tokio::test]
async fn add_attachment_refuses_dot_dot_inside_an_absolute_file_path_as_hidden() {
    let w = local().await;
    w.file("files/visible.txt", b"visible");
    let given = format!("{}/files/../files/visible.txt", s(&w.root));
    assert_eq!(w.refused_path(&given).await, hidden_text(&given));
}

#[tokio::test]
async fn add_attachment_data_accepts_base64_with_or_without_its_padding() {
    let w = local().await;
    // "hi" is `aGk=`; "hi!" is `aGkh` (no padding to drop).
    for (data, name, bytes) in [
        ("aGk=", "padded.txt", &b"hi"[..]),
        ("aGk", "unpadded.txt", &b"hi"[..]),
        ("aGkh", "whole.txt", &b"hi!"[..]),
    ] {
        let reply = w
            .call("add_attachment", json!({ "data": data, "name": name }))
            .await;
        assert_eq!(
            payload("add_attachment", &reply),
            expected(bytes, name),
            "{data}"
        );
        assert_eq!(
            fs::read(w.vault.join(object_path(bytes, name))).unwrap(),
            bytes
        );
    }
}

#[tokio::test]
async fn get_attachment_matches_an_extension_in_any_letter_case() {
    let w = local().await;
    let path = w.stored(b"loud notes\n", "NOTES.TXT");
    assert_eq!(text(&w.get(&path).await), "loud notes\n");

    let bytes = image_bytes(PNG_HEAD, 64);
    let path = w.stored(&bytes, "SHOT.PNG");
    let (mime, data) = image(&w.get(&path).await);
    assert_eq!(mime, "image/png");
    assert_eq!(data, bytes);
}

#[tokio::test]
async fn get_attachment_refuses_a_link_inside_objects_that_points_outside() {
    let w = local().await;
    let secret = w.file("outside/secret.txt", b"wi138 outside secret");
    let hidden = w.file(".secret/key.txt", b"wi138 hidden secret");

    // The stored file itself replaced by a link to a file outside the vault.
    let path = w.stored(b"original", "file-link.txt");
    let on_disk = w.vault.join(&path);
    fs::remove_file(&on_disk).unwrap();
    symlink(&secret, &on_disk).unwrap();
    let reply = w.get(&path).await;
    assert_eq!(
        error_message("get_attachment", &reply),
        format!("Attachment not found: {path}")
    );

    // The same, into a hidden folder.
    let path = w.stored(b"original two", "hidden-link.txt");
    let on_disk = w.vault.join(&path);
    fs::remove_file(&on_disk).unwrap();
    symlink(&hidden, &on_disk).unwrap();
    let reply = w.get(&path).await;
    assert_eq!(
        error_message("get_attachment", &reply),
        format!("Attachment not found: {path}")
    );

    // The `<hash>` folder replaced by a link to a folder outside the vault
    // that holds a file of the same name.
    let path = w.stored(b"original three", "folder-link.txt");
    let on_disk = w.vault.join(&path);
    let hash_dir = on_disk.parent().unwrap().to_path_buf();
    fs::remove_dir_all(&hash_dir).unwrap();
    w.file(
        "outside/folder/folder-link.txt",
        b"wi138 outside folder secret",
    );
    symlink(w.root.join("outside/folder"), &hash_dir).unwrap();
    let reply = w.get(&path).await;
    assert_eq!(
        error_message("get_attachment", &reply),
        format!("Attachment not found: {path}")
    );
}

#[tokio::test]
async fn get_attachment_of_a_folder_at_an_attachment_path_gives_not_found() {
    let w = local().await;
    let path = w.stored(b"original", "was-a-file.txt");
    let on_disk = w.vault.join(&path);
    fs::remove_file(&on_disk).unwrap();
    fs::create_dir(&on_disk).unwrap();
    let reply = w.get(&path).await;
    assert_eq!(
        error_message("get_attachment", &reply),
        format!("Attachment not found: {path}")
    );
}
