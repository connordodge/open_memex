//! WI #80 (R2): MCP over streamable HTTP at `/vaults/{name}/mcp` (req 3,
//! 16, 19; D3, D7, D8).
//!
//! Every test runs the whole vault server (`server::router()`) in-process
//! on `127.0.0.1:0` over a temp vault root, except AC 11, which drives the
//! built `memex serve --root` so it can read the real log and stderr.
//!
//! MCP is spoken two ways:
//! - a real rmcp streamable-HTTP client ([`connect`]), the way an agent
//!   would;
//! - raw JSON-RPC POSTs ([`rpc`]), to control the exact headers (no
//!   `initialize`, no `Mcp-Session-Id`, an odd `Host`) and to read the reply
//!   headers.
//!
//! Stdio parity drives `memex serve --vault` over newline-delimited
//! JSON-RPC ([`Stdio`]), as `append_tools.rs` does.

#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Output, Stdio as ProcStdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use rmcp::model::CallToolRequestParams;
use rmcp::service::RunningService;
use rmcp::transport::streamable_http_client::StreamableHttpClientTransportConfig;
use rmcp::transport::StreamableHttpClientTransport;
use rmcp::{RoleClient, ServiceExt};
use serde_json::{json, Value};

use server::{
    assert_wrong_method_is_c1_405, client, make_vault, raw_request, server_logs, wait_for_logs,
    Reply, ServeCommand, TestServer, ANY_PORT, BODY_LIMIT, TEST_TOKEN, TOKEN_ENV, WAIT,
};

/// The number of tools `Memex::new` composes (tools.rs 13 + daily 1 +
/// excerpts 2 + folders 6 + review 3 + settings 1).
const TOOL_COUNT: usize = 26;

/// What an MCP streamable-HTTP client must accept on a POST.
const ACCEPT: &str = "application/json, text/event-stream";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `/vaults/<vault>/mcp`.
fn mcp_path(vault: &str) -> String {
    format!("/vaults/{vault}/mcp")
}

/// A JSON-RPC request.
fn request(id: i64, method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

/// A `tools/call` request.
fn tool_call(id: i64, tool: &str, arguments: Value) -> Value {
    request(
        id,
        "tools/call",
        json!({ "name": tool, "arguments": arguments }),
    )
}

/// POSTs one JSON-RPC message to `url` as an MCP client would (JSON body,
/// `Accept` both JSON and SSE), with an optional `Authorization` value and
/// extra headers. No `initialize` is sent first.
async fn rpc_with(
    url: &str,
    msg: &Value,
    authorization: Option<&str>,
    extra: &[(&str, &str)],
) -> Reply {
    let mut req = client()
        .post(url)
        .header("content-type", "application/json")
        .header("accept", ACCEPT)
        .body(msg.to_string());
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    for (k, v) in extra {
        req = req.header(*k, *v);
    }
    Reply::read(req.send().await.expect("send MCP POST")).await
}

/// [`rpc_with`] to `/vaults/<vault>/mcp` with the test token.
async fn rpc(srv: &TestServer, vault: &str, msg: &Value) -> Reply {
    rpc_with(&srv.url(&mcp_path(vault)), msg, Some(&srv.bearer()), &[]).await
}

/// The JSON-RPC `result` of a 200 reply; panics with the reply otherwise.
fn rpc_result(r: &Reply) -> Value {
    assert_eq!(r.status, 200, "MCP POST: {:?}", short(&r.body));
    let v = r.json();
    assert_eq!(v["jsonrpc"], "2.0", "a JSON-RPC response: {v}");
    assert!(
        v.get("error").is_none(),
        "a JSON-RPC result, not an error: {v}"
    );
    v["result"].clone()
}

/// A tool's JSON payload: the tools return one text content holding JSON.
fn tool_payload(result: &Value) -> Value {
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("a text content: {result}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("tool text is not JSON ({e}): {text}"))
}

/// Calls `tool` over raw `/mcp` (no `initialize`) and returns its payload.
async fn call(srv: &TestServer, vault: &str, tool: &str, args: Value) -> Value {
    let r = rpc(srv, vault, &tool_call(1, tool, args)).await;
    tool_payload(&rpc_result(&r))
}

/// `create_note` over raw `/mcp`; returns the new note id.
async fn create_note(srv: &TestServer, vault: &str, args: Value) -> String {
    let v = call(srv, vault, "create_note", args).await;
    v["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note returns a note_id: {v}"))
        .to_string()
}

/// The first 300 characters of `s`, for failure messages.
fn short(s: &str) -> &str {
    &s[..s.len().min(300)]
}

/// A real rmcp streamable-HTTP client of `/vaults/<vault>/mcp`, holding
/// the test token.
async fn connect(srv: &TestServer, vault: &str) -> RunningService<RoleClient, ()> {
    connect_with(srv, vault, TEST_TOKEN)
        .await
        .unwrap_or_else(|e| panic!("rmcp client connects to {}: {e}", mcp_path(vault)))
}

async fn connect_with(
    srv: &TestServer,
    vault: &str,
    token: &str,
) -> Result<RunningService<RoleClient, ()>, String> {
    let config =
        StreamableHttpClientTransportConfig::with_uri(srv.url(&mcp_path(vault))).auth_header(token);
    let transport = StreamableHttpClientTransport::with_client(client(), config);
    match tokio::time::timeout(WAIT, ().serve(transport)).await {
        Ok(Ok(running)) => Ok(running),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err(format!("no initialize reply within {WAIT:?}")),
    }
}

/// Calls `tool` through an rmcp client and returns its JSON payload.
async fn client_call(c: &RunningService<RoleClient, ()>, tool: &str, args: Value) -> Value {
    let Value::Object(arguments) = args else {
        panic!("tool arguments are an object");
    };
    let result = c
        .call_tool(CallToolRequestParams::new(tool.to_string()).with_arguments(arguments))
        .await
        .unwrap_or_else(|e| panic!("call {tool} over rmcp: {e}"));
    tool_payload(&serde_json::to_value(result).expect("serialize CallToolResult"))
}

/// `<root>/<name>`.
fn vault_dir(root: &Path, name: &str) -> PathBuf {
    root.join(name)
}

/// The notes in the vault folder's database, read from disk.
fn note_count(vault: &Path) -> i64 {
    let conn = rusqlite::Connection::open_with_flags(
        vault.join("memex.db"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open memex.db read-only");
    conn.query_row("SELECT count(*) FROM notes", [], |r| r.get(0))
        .expect("count notes")
}

/// The note titles in the vault folder's database, read from disk.
fn note_titles(vault: &Path) -> BTreeSet<String> {
    let conn = rusqlite::Connection::open_with_flags(
        vault.join("memex.db"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open memex.db read-only");
    let mut stmt = conn.prepare("SELECT title FROM notes").unwrap();
    stmt.query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Runs the built `memex` with `args` (stdin closed).
fn memex(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .env_remove(TOKEN_ENV)
        .stdin(ProcStdio::null())
        .output()
        .expect("run memex")
}

/// A successful `memex` run's one line of JSON stdout.
fn memex_json(args: &[&str]) -> Value {
    let out = memex(args);
    assert!(
        out.status.success(),
        "memex {args:?}: exit={:?} stdout={} stderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("memex prints JSON")
}

/// `memex get --vault <vault> --note-id <id>`.
fn cli_get(vault: &Path, id: &str) -> Value {
    memex_json(&["get", "--vault", vault.to_str().unwrap(), "--note-id", id])
}

/// The keys of a JSON object.
fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

/// A tool payload's C1 `error` object.
fn tool_error(v: &Value) -> &Value {
    assert!(v["error"].is_object(), "an error payload: {v}");
    &v["error"]
}

/// `tools/list` tools keyed by name.
fn by_name(tools: &Value) -> Vec<(String, Value)> {
    let mut out: Vec<(String, Value)> = tools
        .as_array()
        .unwrap_or_else(|| panic!("a tools array: {tools}"))
        .iter()
        .map(|t| {
            (
                t["name"].as_str().expect("tool name").to_string(),
                t.clone(),
            )
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// `body` in 1 MiB chunks, as `Transfer-Encoding: chunked`.
fn wi80_chunked(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    for part in body.chunks(1024 * 1024) {
        out.extend_from_slice(format!("{:x}\r\n", part.len()).as_bytes());
        out.extend_from_slice(part);
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(b"0\r\n\r\n");
    out
}

/// The head of an MCP POST to `path` with the test token. `framing` is the
/// `Content-Length` or `Transfer-Encoding` line.
fn wi80_post_head(path: &str, host: &str, framing: &str) -> String {
    format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {TEST_TOKEN}\r\n\
         Content-Type: application/json\r\nAccept: {ACCEPT}\r\n{framing}\r\n\
         Connection: close\r\n"
    )
}

// ---------------------------------------------------------------------------
// Stdio `memex serve --vault`
// ---------------------------------------------------------------------------

/// A `memex serve --vault` subprocess spoken to over newline-delimited
/// JSON-RPC.
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
                "clientInfo": { "name": "wi80-test", "version": "0" },
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

// ---------------------------------------------------------------------------
// AC 1: tool parity with stdio
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_tools_list_over_http_equals_stdio_tools_list() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");

    let mut stdio = Stdio::start(&dir);
    let stdio_tools = by_name(&stdio.request(2, "tools/list", json!({}))["result"]["tools"]);
    drop(stdio);
    assert_eq!(stdio_tools.len(), TOOL_COUNT, "stdio serves 26 tools");

    // Raw `tools/list`: the whole tool objects match.
    let http_tools = by_name(
        &rpc_result(&rpc(&srv, "work", &request(1, "tools/list", json!({}))).await)["tools"],
    );
    assert_eq!(http_tools.len(), TOOL_COUNT, "/mcp serves 26 tools");
    let names = |t: &[(String, Value)]| t.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>();
    assert_eq!(names(&http_tools), names(&stdio_tools), "same tool names");
    for ((name, http), (_, stdio)) in http_tools.iter().zip(&stdio_tools) {
        assert_eq!(
            http["description"], stdio["description"],
            "{name}: description"
        );
        assert_eq!(
            http["inputSchema"], stdio["inputSchema"],
            "{name}: input schema"
        );
        assert_eq!(http, stdio, "{name}: the whole tool object");
    }

    // An rmcp client sees the same names, descriptions and schemas.
    let c = connect(&srv, "work").await;
    let mut listed = c.list_all_tools().await.expect("rmcp list_all_tools");
    listed.sort_by(|a, b| a.name.cmp(&b.name));
    assert_eq!(listed.len(), TOOL_COUNT, "rmcp client lists 26 tools");
    for (tool, (name, stdio)) in listed.iter().zip(&stdio_tools) {
        assert_eq!(tool.name.as_ref(), name.as_str());
        assert_eq!(
            tool.description
                .as_deref()
                .map(|d| json!(d))
                .unwrap_or(Value::Null),
            stdio["description"],
            "{name}: description over rmcp"
        );
        assert_eq!(
            Value::Object((*tool.input_schema).clone()),
            stdio["inputSchema"],
            "{name}: input schema over rmcp"
        );
    }
    c.cancel().await.ok();
}

// ---------------------------------------------------------------------------
// AC 2: round trip, and the note is on disk
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_create_note_then_get_note_round_trips_and_cli_reads_it_from_disk() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");

    let c = connect(&srv, "work").await;
    let created = client_call(
        &c,
        "create_note",
        json!({ "title": "Hosted round trip", "content_md": "Written over HTTP MCP." }),
    )
    .await;
    let id = created["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note returns a note_id: {created}"))
        .to_string();

    let got = client_call(&c, "get_note", json!({ "note_id": id })).await;
    assert_eq!(got["note_id"], json!(id), "{got}");
    assert_eq!(got["title"], "Hosted round trip");
    assert_eq!(got["content_md"], "Written over HTTP MCP.");
    c.cancel().await.ok();

    let on_disk = cli_get(&dir, &id);
    assert_eq!(on_disk["note_id"], json!(id));
    assert_eq!(on_disk["title"], "Hosted round trip");
    assert_eq!(on_disk["content_md"], "Written over HTTP MCP.");
    assert_eq!(note_count(&dir), 1);
}

#[tokio::test]
async fn mcp_vault_names_resolve_case_insensitively_to_one_vault() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "Work");
    let id = create_note(
        &srv,
        "WORK",
        json!({ "title": "Any case", "content_md": "Case-insensitive names." }),
    )
    .await;
    let got = call(&srv, "work", "get_note", json!({ "note_id": id })).await;
    assert_eq!(got["title"], "Any case", "{got}");
    assert_eq!(note_count(&vault_dir(srv.root(), "Work")), 1);
}

// ---------------------------------------------------------------------------
// AC 3: agent semantics match stdio
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_create_note_over_http_stores_the_same_agent_frontmatter_as_stdio() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");

    let http_id = create_note(
        &srv,
        "work",
        json!({ "title": "Over HTTP", "content_md": "Hosted.", "agent_id": "claude" }),
    )
    .await;
    let mut stdio = Stdio::start(&dir);
    let created = stdio.call(
        2,
        "create_note",
        json!({ "title": "Over stdio", "content_md": "Local.", "agent_id": "claude" }),
    );
    drop(stdio);
    let stdio_id = created["note_id"]
        .as_str()
        .expect("stdio note_id")
        .to_string();

    let http = cli_get(&dir, &http_id);
    let local = cli_get(&dir, &stdio_id);
    assert_eq!(
        keys(&http["frontmatter"]),
        keys(&local["frontmatter"]),
        "same agent frontmatter keys: http={} stdio={}",
        http["frontmatter"],
        local["frontmatter"]
    );
    assert_eq!(http["frontmatter"]["source"], "agent", "{http}");
    assert_eq!(http["frontmatter"]["agent_id"], "claude", "{http}");
    let tags = |v: &Value| -> BTreeSet<String> {
        v["tags"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(tags(&http), tags(&local), "same agent tags");
    assert!(tags(&http).contains("agent-authored"), "{http}");
    assert!(tags(&http).contains("inbox"), "{http}");
}

#[tokio::test]
async fn mcp_update_smart_folder_on_a_person_pinned_folder_returns_pinned_rule() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");

    let folder = call(
        &srv,
        "work",
        "create_smart_folder",
        json!({ "name": "Games" }),
    )
    .await;
    let id = folder["id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_smart_folder returns an id: {folder}"))
        .to_string();
    assert_eq!(
        folder["pinned"],
        json!(false),
        "an agent folder starts unpinned"
    );

    // The person pins it from the CLI, outside the server.
    let pinned = memex_json(&[
        "folder",
        "update",
        "--vault",
        dir.to_str().unwrap(),
        "--id",
        &id,
        "--pinned",
        "true",
    ]);
    assert_eq!(pinned["pinned"], json!(true), "{pinned}");

    let got = call(
        &srv,
        "work",
        "update_smart_folder",
        json!({ "id": id, "name": "Gaming" }),
    )
    .await;
    let err = tool_error(&got);
    assert_eq!(err["code"], "pinned_rule", "{got}");
    assert_eq!(err["item"], json!(id), "{got}");
    assert!(err["message"].is_string(), "{got}");

    let listed = memex_json(&["folder", "ls", "--vault", dir.to_str().unwrap()]);
    let row = listed["folders"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["id"] == json!(id))
        .unwrap_or_else(|| panic!("the folder is still listed: {listed}"))
        .clone();
    assert_eq!(row["name"], "Games", "the folder is unchanged: {row}");
    assert_eq!(row["pinned"], json!(true), "{row}");
}

#[tokio::test]
async fn mcp_marker_rule_and_depth_exceeded_still_hold_over_http() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");

    // Marker rule: an agent may not add a link from a daily note.
    let daily = create_note(
        &srv,
        "work",
        json!({ "title": "2026-10-20", "content_md": "", "role": "daily" }),
    )
    .await;
    let topic = create_note(
        &srv,
        "work",
        json!({ "title": "Player Loop", "content_md": "Core loop.", "role": "topic" }),
    )
    .await;
    let before = call(&srv, "work", "get_note", json!({ "note_id": daily })).await;
    let got = call(
        &srv,
        "work",
        "add_link",
        json!({ "from_id": daily, "to_id": topic }),
    )
    .await;
    assert_eq!(tool_error(&got)["code"], "marker_rule", "{got}");
    let after = call(&srv, "work", "get_note", json!({ "note_id": daily })).await;
    assert_eq!(
        after["version"], before["version"],
        "the daily note is unchanged"
    );
    assert_eq!(after["content_md"], before["content_md"]);

    // Depth: the default max depth is 2.
    let a = call(&srv, "work", "create_smart_folder", json!({ "name": "A" })).await;
    let b = call(
        &srv,
        "work",
        "create_smart_folder",
        json!({ "name": "B", "parent_id": a["id"] }),
    )
    .await;
    assert!(b["id"].is_string(), "{b}");
    let got = call(
        &srv,
        "work",
        "create_smart_folder",
        json!({ "name": "C", "parent_id": b["id"] }),
    )
    .await;
    let err = tool_error(&got);
    assert_eq!(err["code"], "depth_exceeded", "{got}");
    assert_eq!(err["max_depth"], json!(2), "{got}");
    assert_eq!(err["required_depth"], json!(3), "{got}");
}

// ---------------------------------------------------------------------------
// AC 4: stateless
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_tools_call_without_initialize_or_session_succeeds_and_sets_no_session_id() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");

    // The very first request is a tools/call: no initialize, no session.
    let r = rpc(
        &srv,
        "work",
        &tool_call(
            1,
            "create_note",
            json!({ "title": "Stateless", "content_md": "No session." }),
        ),
    )
    .await;
    let created = tool_payload(&rpc_result(&r));
    let id = created["note_id"].as_str().expect("note_id").to_string();
    assert_eq!(
        r.header("mcp-session-id"),
        None,
        "tools/call sets no session"
    );

    // No other reply sets a session either.
    let init = request(
        2,
        "initialize",
        json!({
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": { "name": "wi80-test", "version": "0" },
        }),
    );
    let initialized = json!({ "jsonrpc": "2.0", "method": "notifications/initialized" });
    for (what, msg) in [
        ("initialize", init),
        ("notifications/initialized", initialized),
        ("tools/list", request(3, "tools/list", json!({}))),
    ] {
        let r = rpc(&srv, "work", &msg).await;
        assert!(
            r.status == 200 || r.status == 202,
            "{what}: {} {:?}",
            r.status,
            short(&r.body)
        );
        assert_eq!(r.header("mcp-session-id"), None, "{what} sets no session");
    }

    // A session id left over from before a restart is not needed or checked.
    let r = rpc_with(
        &srv.url(&mcp_path("work")),
        &tool_call(4, "get_note", json!({ "note_id": id })),
        Some(&srv.bearer()),
        &[("mcp-session-id", "wi80-stale-session-from-before-a-restart")],
    )
    .await;
    let got = tool_payload(&rpc_result(&r));
    assert_eq!(got["title"], "Stateless", "{got}");
    assert_eq!(r.header("mcp-session-id"), None);
}

// ---------------------------------------------------------------------------
// AC 5: JSON responses
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_tools_call_replies_with_one_application_json_body_not_sse() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");

    let r = rpc_with(
        &srv.url(&mcp_path("work")),
        &tool_call(
            7,
            "create_note",
            json!({ "title": "Json reply", "content_md": "One body." }),
        ),
        Some(&srv.bearer()),
        &[("origin", "http://evil.example")],
    )
    .await;
    assert_eq!(r.status, 200, "{:?}", short(&r.body));
    let ct = r.header("content-type").unwrap_or_default();
    assert!(
        ct.starts_with("application/json"),
        "Content-Type application/json, got {ct:?}"
    );
    assert!(!ct.contains("event-stream"), "not SSE: {ct:?}");
    let body = r.body.trim_start();
    assert!(
        !body.starts_with("data:") && !body.starts_with("event:") && !body.starts_with("id:"),
        "no SSE framing: {:?}",
        short(body)
    );
    // The whole body is exactly one JSON-RPC response.
    let v: Value = serde_json::from_str(&r.body)
        .unwrap_or_else(|e| panic!("one JSON body ({e}): {:?}", short(&r.body)));
    assert!(v.is_object(), "one response object, not a batch: {v}");
    assert_eq!(v["jsonrpc"], "2.0");
    assert_eq!(v["id"], json!(7), "{v}");
    assert!(tool_payload(&v["result"])["note_id"].is_string(), "{v}");
    let cors: Vec<_> = r
        .headers
        .iter()
        .filter(|(k, _)| k.starts_with("access-control-"))
        .collect();
    assert!(cors.is_empty(), "no CORS headers on /mcp: {cors:?}");
}

// ---------------------------------------------------------------------------
// AC 6: any Host
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_accepts_any_host_header() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let body = request(1, "tools/list", json!({})).to_string();
    for host in ["nas.local:7878", "100.64.0.1:7878", "localhost"] {
        let head = wi80_post_head(
            &mcp_path("work"),
            host,
            &format!("Content-Length: {}", body.len()),
        );
        let r = raw_request(srv.addr(), &head, body.as_bytes()).await;
        assert_eq!(r.status, 200, "Host: {host}: {:?}", short(&r.body));
        let tools = &r.json()["result"]["tools"];
        assert_eq!(
            tools.as_array().map(Vec::len),
            Some(TOOL_COUNT),
            "Host: {host}: {}",
            short(&r.body)
        );
    }
}

// ---------------------------------------------------------------------------
// AC 7: the access token guards /mcp
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_without_a_valid_token_is_401_unauthorized_and_runs_no_tool() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");
    let url = srv.url(&mcp_path("work"));
    let msg = tool_call(
        1,
        "create_note",
        json!({ "title": "Should not exist", "content_md": "Refused." }),
    );

    for authorization in [
        None,
        Some("Bearer wi80-wrong-token-0a1b2c3d4e5f"),
        Some("Basic Zm9vOmJhcg=="),
    ] {
        let r = rpc_with(&url, &msg, authorization, &[]).await;
        assert_eq!(r.status, 401, "{authorization:?}: {:?}", short(&r.body));
        assert_eq!(r.c1_code(), "unauthorized", "{authorization:?}");
        assert!(!r.body.contains(TEST_TOKEN), "no token echo");
    }
    let refused = connect_with(&srv, "work", "wi80-wrong-token-0a1b2c3d4e5f").await;
    assert!(
        refused.is_err(),
        "an rmcp client with a wrong token is refused"
    );
    assert_eq!(note_count(&dir), 0, "no tool ran");

    // The same request with the token runs the tool.
    let r = rpc_with(&url, &msg, Some(&srv.bearer()), &[]).await;
    assert!(tool_payload(&rpc_result(&r))["note_id"].is_string());
    assert_eq!(note_count(&dir), 1);
}

// ---------------------------------------------------------------------------
// AC 8: the 8 MiB body limit
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_body_over_8_mib_is_413_payload_too_large_with_content_length_and_chunked() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");
    let path = mcp_path("work");

    // A valid create_note whose body is over 8 MiB: if the limit failed, the
    // note would be written.
    let big = tool_call(
        1,
        "create_note",
        json!({ "title": "Too big", "content_md": "x".repeat(BODY_LIMIT + 1024) }),
    )
    .to_string();
    assert!(big.len() > BODY_LIMIT);

    let head = wi80_post_head(
        &path,
        "localhost",
        &format!("Content-Length: {}", big.len()),
    );
    let r = raw_request(srv.addr(), &head, big.as_bytes()).await;
    assert_eq!(r.status, 413, "Content-Length: {:?}", short(&r.body));
    assert_eq!(r.c1_code(), "payload_too_large", "Content-Length");

    let head = wi80_post_head(&path, "localhost", "Transfer-Encoding: chunked");
    let r = raw_request(srv.addr(), &head, &wi80_chunked(big.as_bytes())).await;
    assert_eq!(r.status, 413, "chunked: {:?}", short(&r.body));
    assert_eq!(
        r.c1_code(),
        "payload_too_large",
        "chunked, not an rmcp error"
    );
    assert_eq!(note_count(&dir), 0, "nothing was written");

    // A 3 MiB chunked body is under the limit and is served.
    let padded = request(
        2,
        "tools/list",
        json!({ "_meta": { "pad": "p".repeat(3 * 1024 * 1024) } }),
    )
    .to_string();
    let r = raw_request(srv.addr(), &head, &wi80_chunked(padded.as_bytes())).await;
    assert_eq!(r.status, 200, "3 MiB: {:?}", short(&r.body));
    assert_eq!(
        r.json()["result"]["tools"].as_array().map(Vec::len),
        Some(TOOL_COUNT)
    );

    // And a small write goes through.
    create_note(
        &srv,
        "work",
        json!({ "title": "Small", "content_md": "Fits." }),
    )
    .await;
    assert_eq!(note_count(&dir), 1);
}

// ---------------------------------------------------------------------------
// AC 9: unknown, deleted and recreated vaults
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_unknown_vault_is_404_vault_not_found() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let list = request(1, "tools/list", json!({}));

    let r = rpc(&srv, "nope", &list).await;
    assert_eq!(r.status, 404, "{:?}", short(&r.body));
    assert_eq!(r.c1_code(), "vault_not_found");

    // A served vault on the same server answers.
    let tools = rpc_result(&rpc(&srv, "work", &list).await);
    assert_eq!(tools["tools"].as_array().map(Vec::len), Some(TOOL_COUNT));
}

#[tokio::test]
async fn mcp_deleted_vault_is_404_and_a_recreated_vault_serves_its_own_new_data() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");

    let old = create_note(
        &srv,
        "work",
        json!({ "title": "Old vault note", "content_md": "From the first vault." }),
    )
    .await;
    let got = call(&srv, "work", "get_note", json!({ "note_id": old })).await;
    assert_eq!(got["title"], "Old vault note");

    std::fs::remove_dir_all(&dir).expect("delete the vault folder");
    let r = rpc(&srv, "work", &request(1, "tools/list", json!({}))).await;
    assert_eq!(r.status, 404, "{:?}", short(&r.body));
    assert_eq!(r.c1_code(), "vault_not_found");

    // A new vault under the same name: its own data, not the old service's.
    make_vault(srv.root(), "work");
    let got = call(&srv, "work", "get_note", json!({ "note_id": old })).await;
    assert!(got["error"].is_object(), "the old note is not found: {got}");
    assert_ne!(got["title"], "Old vault note", "{got}");

    let new = create_note(
        &srv,
        "work",
        json!({ "title": "New vault note", "content_md": "From the second vault." }),
    )
    .await;
    assert_eq!(
        note_titles(&dir),
        BTreeSet::from(["New vault note".to_string()]),
        "the write landed in the new vault's database"
    );
    assert_eq!(cli_get(&dir, &new)["title"], "New vault note");
}

// ---------------------------------------------------------------------------
// AC 10: one connection per vault under concurrency
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn mcp_eight_concurrent_clients_creating_notes_all_succeed() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let dir = vault_dir(srv.root(), "work");

    let mut clients = Vec::new();
    for _ in 0..8 {
        clients.push(connect(&srv, "work").await);
    }
    let barrier = Arc::new(tokio::sync::Barrier::new(clients.len()));
    let mut tasks = Vec::new();
    for (i, c) in clients.into_iter().enumerate() {
        let barrier = barrier.clone();
        tasks.push(tokio::spawn(async move {
            barrier.wait().await;
            let got = client_call(
                &c,
                "create_note",
                json!({ "title": format!("Concurrent {i}"), "content_md": format!("Client {i}.") }),
            )
            .await;
            c.cancel().await.ok();
            got
        }));
    }
    for (i, task) in tasks.into_iter().enumerate() {
        let got = task.await.expect("client task");
        let text = got.to_string();
        assert!(
            !text.contains("locked"),
            "client {i}: database is locked: {got}"
        );
        assert!(got["note_id"].is_string(), "client {i} succeeded: {got}");
    }
    let expected: BTreeSet<String> = (0..8).map(|i| format!("Concurrent {i}")).collect();
    assert_eq!(note_titles(&dir), expected, "all 8 notes exist");
}

// ---------------------------------------------------------------------------
// AC 11: no tool arguments or tokens in the log
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_debug_logging_never_records_tool_arguments_or_the_token() {
    const TOKEN: &str = "wi80-log-token-5e4d3c2b1a09f8e7d6c5b4a3";
    const MARKER: &str = "WI80-ARGUMENT-MARKER-7c6b5a49";
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let mut child = ServeCommand::new(&[
        "--root",
        root.path().to_str().unwrap(),
        "--listen",
        ANY_PORT,
        "--log-level",
        "debug",
    ])
    .env(TOKEN_ENV, TOKEN)
    .spawn();
    let addr = child.ready().await;
    let url = format!("http://{addr}{}", mcp_path("work"));

    let r = rpc_with(
        &url,
        &tool_call(
            1,
            "create_note",
            json!({ "title": "Logged?", "content_md": format!("Secret body {MARKER}.") }),
        ),
        Some(&format!("Bearer {TOKEN}")),
        &[],
    )
    .await;
    assert!(tool_payload(&rpc_result(&r))["note_id"].is_string());
    let r = rpc_with(
        &url,
        &request(2, "tools/list", json!({})),
        Some(&format!("Bearer {TOKEN}")),
        &[],
    )
    .await;
    rpc_result(&r);

    let logs = wait_for_logs(root.path(), |logs| {
        logs.lines()
            .filter(|l| l.contains("/vaults/work/mcp"))
            .count()
            >= 2
    })
    .await;
    child.stop();
    let logs = format!("{logs}\n{}", server_logs(root.path()));
    let stderr = child.stderr();
    let stdout = child.stdout();
    for (what, secret) in [("tool argument", MARKER), ("token", TOKEN)] {
        assert!(
            !logs.contains(secret),
            "server.log* holds the {what}:\n{logs}"
        );
        assert!(
            !stderr.contains(secret),
            "stderr holds the {what}:\n{stderr}"
        );
        assert!(
            !stdout.contains(secret),
            "stdout holds the {what}:\n{stdout}"
        );
    }
}

// ---------------------------------------------------------------------------
// Pinned contract: the route serves POST only, with C1 errors
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mcp_wrong_method_is_c1_405_and_without_the_token_401() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), "work");
    let url = srv.url(&mcp_path("work"));
    let http = client();
    for method in ["GET", "DELETE", "PUT", "PATCH"] {
        let m = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
        let r = Reply::read(
            http.request(m.clone(), &url)
                .header("authorization", srv.bearer())
                .header("accept", ACCEPT)
                .send()
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(
            r.status,
            405,
            "{method} with the token: {:?}",
            short(&r.body)
        );
        assert_eq!(r.c1_code(), "method_not_allowed", "{method}");
        let r = Reply::read(
            http.request(m, &url)
                .header("accept", ACCEPT)
                .send()
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(r.status, 401, "{method} without the token");
        assert_eq!(r.c1_code(), "unauthorized", "{method}");
    }
    // #71's shared probe: every non-POST method (OPTIONS too) is the JSON
    // C1 405, with no CORS headers, in any case of the vault name.
    assert_wrong_method_is_c1_405(
        &srv,
        &[
            ("/vaults/work/mcp", &["POST"]),
            ("/vaults/WORK/mcp", &["POST"]),
        ],
    )
    .await;
    // POST on the same path is served.
    rpc_result(&rpc(&srv, "work", &request(1, "tools/list", json!({}))).await);
}
