//! WI #10 (R7): the `add_excerpt` / `remove_excerpt` MCP tools and the
//! additive `transclusions` field of MCP `get_note`.
//!
//! - Both tools act as the agent and still write the daily note's Topics
//!   footer (the D9 internal path, not the marker-guarded save path). They
//!   return `{"vault_id","topic_note_id","version"}` (`version` = the topic
//!   note's new version).
//! - Every failure returns the C1 object `{"error":{"code","message"}}` with
//!   the rule code (new tools use C1 for every error) and writes nothing.
//! - `get_note` on a note with transclusion tokens includes `transclusions`:
//!   one `{date, from, to, text}` per token, rendered per CONTRACTS C4
//!   (fixtures X1–X5 verbatim). The key is absent without tokens.
//!
//! Params are built with `serde_json::from_value(json!(…))` (D23). JSON is
//! compared as parsed values.

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
/// The C4 render-fixture daily note: blocks (0, b7k2m9), (1, c3d4e5), (2, f6g7h8).
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const DAY_BLOCK_IDS: [&str; 3] = ["b7k2m9", "c3d4e5", "f6g7h8"];
const TOPIC_TITLE: &str = "Player Loop";

struct Fixture {
    _dir: TempDir,
    state: Arc<AppState>,
    memex: Memex,
    day: String,
    topic: String,
}

/// A served vault with the C4 fixture day and the topic `Player Loop`.
async fn fresh() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    let day = person_note(&state, DAY, DAY_BODY, Some("daily")).await;
    pin_block_ids(&state, &day).await;
    let topic = person_note(
        &state,
        TOPIC_TITLE,
        "All about the player loop.\n",
        Some("topic"),
    )
    .await;
    Fixture {
        _dir: dir,
        state,
        memex,
        day,
        topic,
    }
}

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("tool returned non-JSON ({e}): {resp}"))
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("expected an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// A note created on the person path and indexed, as the app would.
async fn person_note(state: &AppState, title: &str, body: &str, role: Option<&str>) -> String {
    let mut vault = state.vault.lock().await;
    let note = notes::create_note_as(
        &mut vault,
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

/// Pins the fixture day's stored block ids to the C4 ids by ord.
async fn pin_block_ids(state: &AppState, day: &str) {
    let vault = state.vault.lock().await;
    for (ord, id) in DAY_BLOCK_IDS.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, day, ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "precondition: block at ord {ord}");
    }
}

async fn vault_id(state: &AppState) -> String {
    state.vault.lock().await.vault_id().to_string()
}

/// `(content_md, version)` of a note.
async fn note_row(state: &AppState, id: &str) -> (String, i64) {
    state
        .vault
        .lock()
        .await
        .connection_ref()
        .query_row(
            "SELECT content_md, version FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

/// Every note's `(id, content_md, version)` plus every chip: what a failed
/// call must leave untouched.
type Snapshot = (Vec<(String, String, i64)>, Vec<(String, String, String)>);

async fn snapshot(state: &AppState) -> Snapshot {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let notes = conn
        .prepare("SELECT id, content_md, version FROM notes ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let chips = conn
        .prepare("SELECT daily_note_id, topic_note_id, origin FROM footer_chips ORDER BY rowid")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    (notes, chips)
}

/// `(topic_note_id, origin)` of a daily note's chips, in rowid order.
async fn chip_rows(state: &AppState, day: &str) -> Vec<(String, String)> {
    state
        .vault
        .lock()
        .await
        .connection_ref()
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap()
        .query_map([day], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn chip(topic: &str, origin: &str) -> (String, String) {
    (topic.to_string(), origin.to_string())
}

async fn add_excerpt(m: &Memex, topic: &str, date: &str, block_ids: &[&str]) -> Value {
    parse(
        &m.add_excerpt(params(json!({
            "topic_note_id": topic,
            "date": date,
            "block_ids": block_ids,
        })))
        .await,
    )
}

async fn remove_excerpt(m: &Memex, topic: &str, date: &str, block_ids: &[&str]) -> Value {
    parse(
        &m.remove_excerpt(params(json!({
            "topic_note_id": topic,
            "date": date,
            "block_ids": block_ids,
        })))
        .await,
    )
}

async fn get_note(m: &Memex, id: &str) -> Value {
    parse(&m.get_note(params(json!({ "note_id": id }))).await)
}

/// The expected success shape: exactly `vault_id`, `topic_note_id`, `version`.
async fn c2_shape(state: &AppState, topic: &str) -> Value {
    json!({
        "vault_id": vault_id(state).await,
        "topic_note_id": topic,
        "version": note_row(state, topic).await.1,
    })
}

/// `shape` plus the tool's additive WI #449 result field `key`.
fn with_field(mut shape: Value, key: &str, value: Value) -> Value {
    shape[key] = value;
    shape
}

/// Asserts the C1 object: only `error`, holding exactly `code` and `message`.
fn assert_c1(v: &Value, code: &str) {
    assert_eq!(keys(v), set(&["error"]), "only `error`: {v}");
    let e = &v["error"];
    assert_eq!(e["code"], json!(code), "{v}");
    assert!(e["message"].is_string(), "message: {v}");
    assert_eq!(
        keys(e),
        set(&["code", "message"]),
        "C1 fields for {code}: {v}"
    );
    if code == "role_rule" {
        let message = e["message"].as_str().unwrap();
        assert!(message.contains("role"), "the message names the role: {v}");
    }
}

// ======================================================================
// AC 15: the tools act as the agent, write the daily footer despite the
// marker rule, and return {"vault_id","topic_note_id","version"}.
// ======================================================================

#[tokio::test]
async fn mcp_add_excerpt_as_the_agent_writes_the_footer_and_returns_the_c2_shape() {
    let f = fresh().await;
    let (_, v0) = note_row(&f.state, &f.topic).await;

    let resp = add_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9", "c3d4e5"]).await;

    assert_eq!(
        resp,
        with_field(
            c2_shape(&f.state, &f.topic).await,
            "filed_block_ids",
            json!(["b7k2m9", "c3d4e5"])
        ),
        "{resp}"
    );
    assert_eq!(
        resp["version"],
        json!(v0 + 1),
        "the topic note's new version"
    );
    let (topic_body, _) = note_row(&f.state, &f.topic).await;
    assert!(
        topic_body.contains("## 2026-09-05")
            && topic_body.contains("![[2026-09-05#^b7k2m9..^c3d4e5]]"),
        "{topic_body}"
    );
    assert_eq!(
        chip_rows(&f.state, &f.day).await,
        [chip(&f.topic, "excerpt")],
        "the agent call wrote the daily footer"
    );
    let (day_body, _) = note_row(&f.state, &f.day).await;
    assert!(
        day_body
            .lines()
            .any(|l| l.trim_end() == "[[Player Loop~about]]"),
        "{day_body}"
    );
}

#[tokio::test]
async fn mcp_remove_excerpt_as_the_agent_returns_the_c2_shape_and_clears_the_chip() {
    let f = fresh().await;
    let added = add_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9"]).await;
    let added_version = added["version"]
        .as_i64()
        .unwrap_or_else(|| panic!("add_excerpt failed: {added}"));

    let resp = remove_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9"]).await;

    assert_eq!(
        resp,
        with_field(
            c2_shape(&f.state, &f.topic).await,
            "removed_count",
            json!(1)
        ),
        "{resp}"
    );
    assert_eq!(resp["version"], json!(added_version + 1));
    let (topic_body, _) = note_row(&f.state, &f.topic).await;
    assert!(!topic_body.contains("![["), "{topic_body}");
    assert!(!topic_body.contains("## 2026-09-05"), "{topic_body}");
    assert_eq!(chip_rows(&f.state, &f.day).await, []);
    let (day_body, _) = note_row(&f.state, &f.day).await;
    assert!(!day_body.contains("[[Player Loop~about]]"), "{day_body}");
}

#[tokio::test]
async fn mcp_remove_excerpt_keeps_a_person_chip() {
    let f = fresh().await;
    add_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9"]).await;
    {
        let mut vault = f.state.vault.lock().await;
        footer::set_chip(
            &mut vault,
            &NoteId::parse(&f.day).unwrap(),
            &NoteId::parse(&f.topic).unwrap(),
            ChipOrigin::Person,
            None,
        )
        .unwrap();
    }

    let resp = remove_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9"]).await;

    assert_eq!(
        resp,
        with_field(
            c2_shape(&f.state, &f.topic).await,
            "removed_count",
            json!(1)
        ),
        "{resp}"
    );
    assert_eq!(
        chip_rows(&f.state, &f.day).await,
        [chip(&f.topic, "person")]
    );
}

// ======================================================================
// AC 15: rule errors use the C1 shape with the rule code; nothing written.
// ======================================================================

#[tokio::test]
async fn mcp_add_excerpt_errors_use_the_c1_shape_and_write_nothing() {
    let f = fresh().await;
    let plain = person_note(&f.state, "Loose note", "Just text.\n", None).await;
    let before = snapshot(&f.state).await;

    let cases: Vec<(&str, &str, Vec<&str>, &str)> = vec![
        (plain.as_str(), DAY, vec!["b7k2m9"], "role_rule"),
        (f.day.as_str(), DAY, vec!["b7k2m9"], "role_rule"),
        (f.topic.as_str(), DAY, vec!["zzzzzz"], "block_not_found"),
        (f.topic.as_str(), "2026-09-06", vec!["b7k2m9"], "not_found"),
        (f.topic.as_str(), "2026-9-5", vec!["b7k2m9"], "invalid_date"),
        (
            "01J9Z8Y7X6W5V4T3S2R1Q0P9N8",
            DAY,
            vec!["b7k2m9"],
            "not_found",
        ),
        ("not-a-ulid", DAY, vec!["b7k2m9"], "invalid_id"),
    ];
    for (topic, date, ids, code) in cases {
        let resp = add_excerpt(&f.memex, topic, date, &ids).await;
        assert_c1(&resp, code);
    }

    assert_eq!(snapshot(&f.state).await, before);
}

#[tokio::test]
async fn mcp_remove_excerpt_errors_use_the_c1_shape_and_write_nothing() {
    let f = fresh().await;
    let added = add_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9", "c3d4e5"]).await;
    assert!(added["version"].is_i64(), "add_excerpt failed: {added}");
    let plain = person_note(
        &f.state,
        "Loose note",
        "![[2026-09-05#^b7k2m9..^c3d4e5]]\n",
        None,
    )
    .await;
    let before = snapshot(&f.state).await;

    let cases: Vec<(&str, &str, Vec<&str>, &str)> = vec![
        (plain.as_str(), DAY, vec!["b7k2m9", "c3d4e5"], "role_rule"),
        (f.topic.as_str(), DAY, vec!["b7k2m9"], "not_found"),
        (f.topic.as_str(), DAY, vec!["c3d4e5", "f6g7h8"], "not_found"),
        (
            f.topic.as_str(),
            "2026-9-5",
            vec!["b7k2m9", "c3d4e5"],
            "invalid_date",
        ),
    ];
    for (topic, date, ids, code) in cases {
        let resp = remove_excerpt(&f.memex, topic, date, &ids).await;
        assert_c1(&resp, code);
    }

    assert_eq!(snapshot(&f.state).await, before);
}

// ======================================================================
// AC 18: get_note includes `transclusions` rendered per C4 (X1–X5); the key
// is absent for a note without transclusions.
// ======================================================================

#[tokio::test]
async fn mcp_get_note_lists_transclusions_rendered_per_c4() {
    let f = fresh().await;
    let body = "## 2026-09-05\n\n\
                ![[2026-09-05#^b7k2m9]]\n\n\
                ![[2026-09-05#^b7k2m9..^c3d4e5]]\n\n\
                ![[2026-09-05#^zzzzzz]]\n\n\
                ![[2026-09-05#^b7k2m9..^zzzzzz]]\n\n\
                ![[2026-09-06#^b7k2m9]]\n";
    let fixtures = person_note(&f.state, "Fixtures", body, Some("topic")).await;

    let resp = get_note(&f.memex, &fixtures).await;

    assert_eq!(resp["note_id"], json!(fixtures), "{resp}");
    assert_eq!(
        resp["transclusions"],
        json!([
            { "date": "2026-09-05", "from": "b7k2m9", "to": null,
              "text": "Fixed the jump arc." },
            { "date": "2026-09-05", "from": "b7k2m9", "to": "c3d4e5",
              "text": "Fixed the jump arc.\n- tried coyote time" },
            { "date": "2026-09-05", "from": "zzzzzz", "to": null,
              "text": "removed from 2026-09-05" },
            { "date": "2026-09-05", "from": "b7k2m9", "to": "zzzzzz",
              "text": "removed from 2026-09-05" },
            { "date": "2026-09-06", "from": "b7k2m9", "to": null,
              "text": "removed from 2026-09-06" },
        ]),
        "{resp}"
    );
}

#[tokio::test]
async fn mcp_get_note_shows_an_added_excerpt_and_drops_the_key_after_removal() {
    let f = fresh().await;
    let plain = get_note(&f.memex, &f.topic).await;
    assert!(plain["note_id"].is_string(), "{plain}");
    assert!(
        plain.get("transclusions").is_none(),
        "absent without tokens: {plain}"
    );

    add_excerpt(&f.memex, &f.topic, DAY, &["f6g7h8"]).await;
    let resp = get_note(&f.memex, &f.topic).await;
    assert_eq!(
        resp["transclusions"],
        json!([
            { "date": "2026-09-05", "from": "f6g7h8", "to": null, "text": "Sleep was bad." },
        ]),
        "{resp}"
    );

    remove_excerpt(&f.memex, &f.topic, DAY, &["f6g7h8"]).await;
    let resp = get_note(&f.memex, &f.topic).await;
    assert!(resp["note_id"].is_string(), "{resp}");
    assert!(
        resp.get("transclusions").is_none(),
        "absent once the last token is gone: {resp}"
    );
}

// ======================================================================
// AC 15: both tools are registered on the served router with the three
// required params.
// ======================================================================

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
                "clientInfo": { "name": "wi10-test", "version": "0" },
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
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn string_set(v: &Value) -> BTreeSet<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn mcp_server_registers_add_excerpt_and_remove_excerpt() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = Server::start(path.to_str().unwrap());
    let resp = server.request(2, "tools/list", json!({}));
    let tools = resp["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
        .clone();

    for name in ["add_excerpt", "remove_excerpt"] {
        let schema = tools
            .iter()
            .find(|t| t["name"] == json!(name))
            .unwrap_or_else(|| panic!("tool {name} is registered"))["inputSchema"]
            .clone();
        let props: BTreeSet<String> = schema["properties"]
            .as_object()
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        let fields = set(&["topic_note_id", "date", "block_ids"]);
        assert_eq!(props, fields, "{name}: {schema}");
        assert_eq!(string_set(&schema["required"]), fields, "{name}: {schema}");
    }
}

// ======================================================================
// Implementer addition (#10), lead ruling: an empty `block_ids` is C1
// `invalid_argument` for both tools; nothing is written.
// ======================================================================

#[tokio::test]
async fn mcp_excerpt_tools_reject_empty_block_ids_with_invalid_argument() {
    let f = fresh().await;
    let added = add_excerpt(&f.memex, &f.topic, DAY, &["b7k2m9"]).await;
    assert!(added["version"].is_i64(), "add_excerpt failed: {added}");
    let before = snapshot(&f.state).await;

    assert_c1(
        &add_excerpt(&f.memex, &f.topic, DAY, &[]).await,
        "invalid_argument",
    );
    assert_c1(
        &remove_excerpt(&f.memex, &f.topic, DAY, &[]).await,
        "invalid_argument",
    );

    assert_eq!(snapshot(&f.state).await, before);
}
