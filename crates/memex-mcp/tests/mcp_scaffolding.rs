//! WI #5 (R2b): the MCP side of the scaffolding.
//!
//! - `create_note` gains an optional `role` (`daily` | `topic`), stored in the
//!   frontmatter beside `source`/`agent_id`/`created_at`; any other role is a
//!   `role_rule` error (C1) and creates nothing.
//! - `get_note` merges the review and transclusion field maps (D7).
//! - The composed router (5 empty area routers) lists exactly today's 13 tools.
//! - MCP writes reindex from the stored note's `content_md` (D8).
//!
//! Params are built with `serde_json::from_value(json!(…))`, never struct
//! literals (D23).

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::notes::{self, NoteId};
use memex_core::{excerpts, review, MemexError, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

fn fresh() -> (TempDir, Arc<AppState>, Memex) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    (dir, state, memex)
}

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("tool returned non-JSON ({e}): {resp}"))
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object().expect("object").keys().cloned().collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

async fn create(memex: &Memex, args: Value) -> Value {
    parse(&memex.create_note(params(args)).await)
}

async fn create_ok(memex: &Memex, args: Value) -> String {
    let v = create(memex, args).await;
    v["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note failed: {v}"))
        .to_string()
}

/// The stored frontmatter, straight from `notes.frontmatter`.
async fn stored_frontmatter(state: &AppState, note_id: &str) -> Value {
    let vault = state.vault.lock().await;
    let raw: String = vault
        .connection_ref()
        .query_row(
            "SELECT frontmatter FROM notes WHERE id = ?",
            [note_id],
            |r| r.get(0),
        )
        .unwrap();
    serde_json::from_str(&raw).unwrap()
}

async fn note_count(state: &AppState) -> i64 {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

/// D8: the note's `chunks` and `links` rows are exactly what the indexer
/// derives from the stored `notes.content_md`.
async fn assert_indexed_from_stored_content(state: &AppState, note_id: &str) {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let stored: String = conn
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [note_id],
            |r| r.get(0),
        )
        .unwrap();

    let mut stmt = conn
        .prepare("SELECT ord, content FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let chunk_rows: Vec<(i64, String)> = stmt
        .query_map([note_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    // Only the person section is chunked (WI #418, Spec #391 req 1).
    let frontmatter: String = conn
        .query_row(
            "SELECT frontmatter FROM notes WHERE id = ?",
            [note_id],
            |r| r.get(0),
        )
        .unwrap();
    let person = if memex_core::daily::is_daily(&serde_json::from_str(&frontmatter).unwrap()) {
        memex_core::daily::split_body(&stored).person
    } else {
        memex_core::tags::person_section(&stored).to_string()
    };
    let expected_chunks: Vec<(i64, String)> = memex_core::chunker::chunk(&person)
        .into_iter()
        .map(|c| (c.ord, c.content))
        .collect();
    assert!(!expected_chunks.is_empty(), "test body must produce chunks");
    assert_eq!(
        chunk_rows, expected_chunks,
        "chunks must be derived from the stored content_md"
    );

    let mut stmt = conn
        .prepare(
            "SELECT link_text, link_kind, position FROM links
             WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap();
    let link_rows: Vec<(String, String, i64)> = stmt
        .query_map([note_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut expected_links: Vec<(String, String, i64)> =
        memex_core::link_extractor::extract(&stored)
            .all()
            .map(|l| {
                (
                    l.link_text.clone(),
                    l.link_kind.as_str().to_string(),
                    l.position,
                )
            })
            .collect();
    expected_links.sort_by_key(|l| l.2);
    assert_eq!(
        link_rows, expected_links,
        "links must be derived from the stored content_md"
    );
}

// ---------- AC 7: role stored beside the agent keys ----------

#[tokio::test]
async fn create_note_with_role_topic_stores_role_beside_agent_keys() {
    let (_dir, state, memex) = fresh();
    let id = create_ok(
        &memex,
        json!({
            "content_md": "Player loop: jump, land, repeat.",
            "title": "Player Loop",
            "agent_id": "test-agent",
            "role": "topic",
        }),
    )
    .await;

    let fm = stored_frontmatter(&state, &id).await;
    assert_eq!(fm["role"], "topic", "{fm}");
    assert_eq!(fm["source"], "agent", "{fm}");
    assert_eq!(fm["agent_id"], "test-agent", "{fm}");
    assert!(fm["created_at"].is_i64(), "created_at kept: {fm}");
    assert_eq!(
        keys(&fm),
        set(&["source", "agent_id", "created_at", "role"]),
        "{fm}"
    );
}

#[tokio::test]
async fn create_note_without_role_stores_no_role_key() {
    let (_dir, state, memex) = fresh();
    let id = create_ok(
        &memex,
        json!({ "content_md": "No role.", "title": "Plain", "agent_id": "test-agent" }),
    )
    .await;
    let fm = stored_frontmatter(&state, &id).await;
    assert_eq!(
        keys(&fm),
        set(&["source", "agent_id", "created_at"]),
        "{fm}"
    );
}

#[tokio::test]
async fn create_note_with_role_daily_and_empty_content_is_accepted() {
    // D16: `role: daily` is allowed with empty content and an ISO title.
    let (_dir, state, memex) = fresh();
    let id = create_ok(
        &memex,
        json!({ "content_md": "", "title": "2026-10-03", "role": "daily" }),
    )
    .await;
    let fm = stored_frontmatter(&state, &id).await;
    assert_eq!(fm["role"], "daily", "{fm}");
    assert_eq!(fm["source"], "agent", "{fm}");
}

// ---------- AC 8: an unknown role is a role_rule error ----------

#[tokio::test]
async fn create_note_with_bogus_role_returns_role_rule_and_creates_nothing() {
    let (_dir, state, memex) = fresh();
    for role in ["bogus", "Topic", ""] {
        let v = create(
            &memex,
            json!({ "content_md": "Body.", "title": "Bogus", "role": role }),
        )
        .await;
        assert_eq!(v["error"]["code"], "role_rule", "role {role:?}: {v}");
        let message = v["error"]["message"].as_str().expect("message");
        assert!(message.contains("role"), "role {role:?}: {v}");
        assert_eq!(keys(&v), set(&["error"]), "{v}");
        assert_eq!(keys(&v["error"]), set(&["code", "message"]), "{v}");
        // The tool returns the core `RoleRule` error's contract object (C1).
        let detail = message
            .strip_prefix("role rule: ")
            .unwrap_or_else(|| panic!("message is RoleRule's Display text: {v}"));
        assert_eq!(v, MemexError::RoleRule(detail.to_string()).to_error_json());
    }
    assert_eq!(note_count(&state).await, 0, "no note created");
}

// ---------- err_from keeps op-style codes for non-rule errors ----------

#[tokio::test]
async fn update_link_internal_error_keeps_op_style_code() {
    let (_dir, _state, memex) = fresh();
    let a = create_ok(&memex, json!({ "content_md": "alpha", "title": "A" })).await;
    let b = create_ok(&memex, json!({ "content_md": "beta", "title": "B" })).await;
    let added = parse(
        &memex
            .add_link(params(
                json!({ "from_id": a, "to_id": b, "kind": "extends" }),
            ))
            .await,
    );
    let link_id = added["link_id"].as_str().expect("link_id").to_string();

    // Changing a frontmatter link's kind is an `internal`-coded core error
    // (InvalidLinkKind), so the tool keeps today's `op` code.
    let v = parse(
        &memex
            .update_link(params(json!({ "link_id": link_id, "kind": "contradicts" })))
            .await,
    );
    assert_eq!(v["error"]["code"], "update_link", "{v}");
}

// ---------- AC 9: get_note merges the stub field maps ----------

#[tokio::test]
async fn get_note_merges_empty_stub_fields_and_keeps_todays_keys() {
    let (_dir, state, memex) = fresh();
    let id = create_ok(
        &memex,
        json!({ "content_md": "Just text.", "title": "Plain" }),
    )
    .await;

    let (review_fields, transclusion_fields) = {
        let vault = state.vault.lock().await;
        let note = notes::get_note(&vault, &NoteId::parse(&id).unwrap()).unwrap();
        (
            review::note_review_fields(&vault, &note).expect("review fields"),
            excerpts::note_transclusion_fields(&vault, &note).expect("transclusion fields"),
        )
    };
    assert!(review_fields.is_empty(), "plain note has no review fields");
    assert!(
        transclusion_fields.is_empty(),
        "plain note has no transclusion fields"
    );

    let mut expected = set(&[
        "vault_id",
        "note_id",
        "title",
        "content_md",
        "frontmatter",
        "version",
        "created_at",
        "updated_at",
        "tags",
        "agent_tags",
    ]);
    expected.extend(review_fields.keys().cloned());
    expected.extend(transclusion_fields.keys().cloned());

    let got = parse(&memex.get_note(params(json!({ "note_id": id }))).await);
    assert_eq!(keys(&got), expected, "{got}");

    let got = parse(
        &memex
            .get_note(params(json!({ "note_id": id, "include_backlinks": true })))
            .await,
    );
    let mut expected_links = expected.clone();
    expected_links.extend(set(&["links", "backlinks"]));
    assert_eq!(keys(&got), expected_links, "{got}");
}

// ---------- AC 10: the composed router lists today's 13 tools ----------

/// A `memex serve` subprocess spoken to over newline-delimited JSON-RPC.
struct Server {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Server {
    fn start(vault: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve");
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
        let mut server = Self {
            child,
            stdin,
            lines,
        };
        let init = server.request(
            1,
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi5-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        server.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        server
    }

    fn send(&mut self, msg: Value) {
        writeln!(self.stdin, "{msg}").expect("write to server");
        self.stdin.flush().unwrap();
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
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

    fn tools(&mut self) -> Vec<Value> {
        let resp = self.request(2, "tools/list", json!({}));
        resp["result"]["tools"]
            .as_array()
            .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
            .clone()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn served_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let path = path.to_str().unwrap().to_string();
    (dir, path)
}

#[test]
fn server_lists_exactly_the_thirteen_existing_tools() {
    let (_dir, vault) = served_vault();
    let mut server = Server::start(&vault);
    let names: Vec<String> = server
        .tools()
        .iter()
        .map(|t| t["name"].as_str().expect("tool name").to_string())
        .collect();
    let unique: BTreeSet<String> = names.iter().cloned().collect();
    assert_eq!(names.len(), unique.len(), "no duplicate tools: {names:?}");
    // Lead ruling (tool count): later WIs register new tools, so this checks
    // that every one of the 13 existing tools is still listed.
    let existing = set(&[
        "search",
        "get_note",
        "neighbors",
        "add_link",
        "create_note",
        "list_canvases",
        "get_canvas",
        "create_canvas",
        "add_to_canvas",
        "remove_from_canvas",
        "move_node",
        "delete_canvas",
        "update_link",
    ]);
    assert_eq!(existing.len(), 13);
    let missing: BTreeSet<&String> = existing.difference(&unique).collect();
    assert!(missing.is_empty(), "existing tools missing: {missing:?}");
}

#[test]
fn create_note_tool_schema_advertises_optional_role() {
    let (_dir, vault) = served_vault();
    let mut server = Server::start(&vault);
    let tools = server.tools();
    let create = tools
        .iter()
        .find(|t| t["name"] == "create_note")
        .expect("create_note listed");
    let schema = &create["inputSchema"];
    assert!(
        schema["properties"]["role"].is_object(),
        "create_note advertises `role`: {schema}"
    );
    let required: Vec<&str> = schema["required"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    assert!(!required.contains(&"role"), "`role` is optional: {schema}");
    assert!(required.contains(&"content_md"), "{schema}");
}

// ---------- AC 11: MCP writes reindex from the stored content (D8) ----------

#[tokio::test]
async fn mcp_create_note_and_add_link_reindex_from_stored_content() {
    let (_dir, state, memex) = fresh();
    let target = create_ok(
        &memex,
        json!({ "content_md": "target body", "title": "Target" }),
    )
    .await;

    let id = create_ok(
        &memex,
        json!({
            "content_md": "# Source\n\nFirst paragraph mentions [[Target]].\n\nSecond paragraph.\n",
            "title": "Source",
            "role": "topic",
        }),
    )
    .await;
    assert_indexed_from_stored_content(&state, &id).await;

    let added = parse(
        &memex
            .add_link(params(
                json!({ "from_id": id, "to_id": target, "kind": "extends" }),
            ))
            .await,
    );
    assert_eq!(added["was_existing"], false, "{added}");
    assert_indexed_from_stored_content(&state, &id).await;

    let plain = create_ok(
        &memex,
        json!({ "content_md": "Plain body with [[Target]] and [[Ghost]].", "title": "Plain" }),
    )
    .await;
    assert_indexed_from_stored_content(&state, &plain).await;
}
