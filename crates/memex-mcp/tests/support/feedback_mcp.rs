//! Shared by `feedback_tools.rs` and `guide_tools.rs` (WI #254).
//!
//! Include it after `support/server.rs`:
//! `#[path = "support/server.rs"] mod server;` then
//! `#[path = "support/feedback_mcp.rs"] mod feedback_mcp;`.
//!
//! - [`Stdio`] speaks newline-delimited JSON-RPC to a `memex serve` subprocess.
//! - [`Hosted`] runs `server::router()` in-process on a clock the test fixes, for
//!   the `/mcp` tools that read the caller's date (`X-Memex-UTC-Offset`) and the
//!   hosted `agent-changes` route.
//! - The fixtures write the person's side through core, before the server's first
//!   call. The tools are driven over the wire only.

#![allow(dead_code)]

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio as ProcStdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::feedback;
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote, Note};
use memex_core::review::{self, ChangeEntry};
use memex_core::{Caller, Clock, Vault};
use memex_mcp::server::{router, ServerConfig};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::server::{client, make_vault, Reply, TEST_TOKEN};

pub const DAY: &str = "2026-09-05";
/// Three blocks, pinned to [`B7`], [`C3`] and [`F6`] by [`person_day`].
pub const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
pub const B7: &str = "b7k2m9";
pub const C3: &str = "c3d4e5";
pub const F6: &str = "f6g7h8";
pub const B7_TEXT: &str = "Fixed the jump arc.";
pub const C3_TEXT: &str = "- tried coyote time";
pub const F6_TEXT: &str = "Sleep was bad.";

pub const TOPIC: &str = "Player Loop";
/// A stamp for the person's writes, apart from every clock the server runs on.
pub const T0: i64 = 1_759_500_000_000;
/// A well-formed id nothing in a fresh vault has.
pub const UNKNOWN_ID: &str = "01ARZ3NDEKTSV4RRFFQ69G5FAV";

/// 2026-03-02T00:15:00Z: 2026-03-02 at `+00:00`, 2026-03-01 at `-00:30`.
pub const BOUNDARY_MS: i64 = 1_772_410_500_000;
pub const BOUNDARY_UTC_DATE: &str = "2026-03-02";
pub const BOUNDARY_WEST_DATE: &str = "2026-03-01";
pub const UTC: &str = "+00:00";
pub const WEST: &str = "-00:30";

/// Every field of the Feedback Contract (#256).
pub const FEEDBACK_KEYS: [&str; 13] = [
    "id",
    "kind",
    "source",
    "note_id",
    "day",
    "agent_change_id",
    "text",
    "correction",
    "status",
    "reply",
    "created_at",
    "updated_at",
    "handled_at",
];

// ---------- the person's writes, through core ----------

pub struct FixedClock(pub i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

pub fn person_note(vault: &mut Vault, title: &str, body: &str, fm: Value) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(fm),
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
    note
}

pub fn person_topic(vault: &mut Vault, title: &str) -> String {
    let body = format!("About {title}.\n");
    person_note(vault, title, &body, json!({ "role": "topic" }))
        .id
        .to_string()
}

/// A person-written daily note whose stored block ids are pinned by ord.
pub fn person_day(vault: &mut Vault, date: &str, body: &str, ids: &[&str]) -> String {
    let note = person_note(vault, date, body, json!({ "role": "daily" }));
    for (ord, id) in ids.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, note.id.as_str(), ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "{date}: block at ord {ord}");
    }
    note.id.to_string()
}

/// The day [`DAY`], pinned to its three blocks.
pub fn fixture_day(vault: &mut Vault) -> String {
    person_day(vault, DAY, DAY_BODY, &[B7, C3, F6])
}

/// Reviews `date` at content version 1 and returns the daily note's Activity
/// entry id.
pub fn reviewed(vault: &mut Vault, date: &str, note_id: &str) -> String {
    review::mark_day_reviewed(
        vault,
        date,
        1,
        &[ChangeEntry {
            note_id: note_id.to_string(),
            bullets: vec!["Filed the day".into()],
        }],
        &FixedClock(T0),
    )
    .unwrap_or_else(|e| panic!("review {date}: {e}"));
    vault
        .connection_ref()
        .query_row(
            "SELECT id FROM agent_changes WHERE note_id = ? ORDER BY rowid DESC LIMIT 1",
            [note_id],
            |r| r.get(0),
        )
        .unwrap()
}

/// An Open comment on the Activity entry `change_id`, written at `at`; its id.
pub fn comment(
    vault: &mut Vault,
    note_id: &str,
    date: &str,
    change_id: &str,
    text: &str,
    at: i64,
) -> String {
    feedback::add(vault, note_id, date, change_id, text, &FixedClock(at))
        .unwrap_or_else(|e| panic!("comment {text:?}: {e}"))
        .id
}

/// An open tag Correction (raw SQL: #234's write path has no hook into Feedback).
/// Returns its id, `tag-<id>`.
pub fn tag_correction(
    vault: &Vault,
    note_id: &str,
    title: &str,
    tag: &str,
    at: i64,
    cleared_at: Option<i64>,
) -> String {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at, cleared_at)
             VALUES (?, ?, ?, 'removed', ?, ?)",
            params![note_id, title, tag, at, cleared_at],
        )
        .unwrap();
    format!("tag-{}", vault.connection_ref().last_insert_rowid())
}

/// Creates a temp vault, runs `setup` on it, closes it and returns its path.
pub fn vault_with(setup: impl FnOnce(&mut Vault)) -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    {
        let mut vault = Vault::create(&path).unwrap();
        setup(&mut vault);
    }
    let path = path.to_str().unwrap().to_string();
    (dir, path)
}

// ---------- reading the vault from disk ----------

pub fn open_db(vault: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open_with_flags(
        vault.join("memex.db"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open memex.db read-only")
}

pub fn count(vault: &Path, sql: &str) -> i64 {
    open_db(vault)
        .query_row(sql, [], |r| r.get(0))
        .unwrap_or_else(|e| panic!("{sql}: {e}"))
}

/// `(day, created_at, bullets)` of every Activity row of `note_id`, oldest first.
pub fn activity(vault: &Path, note_id: &str) -> Vec<(String, i64, Value)> {
    let conn = open_db(vault);
    let mut stmt = conn
        .prepare(
            "SELECT day, created_at, bullets_json FROM agent_changes
             WHERE note_id = ? ORDER BY rowid",
        )
        .unwrap();
    stmt.query_map([note_id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, String>(2)?,
        ))
    })
    .unwrap()
    .map(|row| {
        let (day, at, bullets) = row.unwrap();
        (day, at, serde_json::from_str(&bullets).unwrap())
    })
    .collect()
}

// ---------- small helpers over tool results ----------

pub fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("expected an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

pub fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

pub fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("`{key}` is not a string in {v}"))
}

/// A failure of these tools is the C1 object with `code`, never an `op.sub` code.
pub fn assert_c1(v: &Value, code: &str, what: &str) {
    assert_eq!(keys(v), set(&["error"]), "{what}: {v}");
    assert_eq!(v["error"]["code"], json!(code), "{what}: {v}");
    assert!(
        v["error"]["message"]
            .as_str()
            .is_some_and(|m| !m.is_empty()),
        "{what}: a C1 error has a message: {v}"
    );
}

// ---------- `memex serve` over stdio ----------

pub struct Stdio {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: i64,
}

impl Stdio {
    pub fn start(vault: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault])
            .stdin(ProcStdio::piped())
            .stdout(ProcStdio::piped())
            .stderr(ProcStdio::null())
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
            next_id: 1,
        };
        let init = server.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi254-test", "version": "0" },
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

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(60))
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }

    /// Every listed tool, as `tools/list` describes it.
    pub fn tools(&mut self) -> Vec<Value> {
        let resp = self.request("tools/list", json!({}));
        resp["result"]["tools"]
            .as_array()
            .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
            .clone()
    }

    /// The tool's JSON payload, error objects included. A tool the server doesn't
    /// have fails the test here, naming the tool.
    pub fn call_raw(&mut self, name: &str, arguments: Value) -> Value {
        let resp = self.request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        let result = &resp["result"];
        assert!(result.is_object(), "tools/call {name} failed: {resp}");
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} returned no text content: {resp}"));
        serde_json::from_str(text)
            .unwrap_or_else(|e| panic!("{name} returned non-JSON ({e}): {text}"))
    }

    /// Like [`Self::call_raw`], but fails the test on an error object.
    pub fn call(&mut self, name: &str, arguments: Value) -> Value {
        let v = self.call_raw(name, arguments);
        assert!(v.get("error").is_none(), "{name} errored: {v}");
        v
    }
}

impl Drop for Stdio {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---------- the vault server on a fixed clock ----------

/// `server::router()` on `127.0.0.1:0`, its base clock frozen at one instant.
pub struct Hosted {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl Hosted {
    pub async fn at(ms: i64) -> Self {
        let root = tempfile::tempdir().expect("temp vault root");
        let config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN)
            .with_clock(Arc::new(FixedClock(ms)));
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

    /// A new vault `<root>/<name>`, seeded by `setup` before any request.
    pub fn vault(&self, name: &str, setup: impl FnOnce(&mut Vault)) -> PathBuf {
        make_vault(self.root.path(), name);
        let path = self.root.path().join(name);
        let mut vault = Vault::open(&path).unwrap();
        setup(&mut vault);
        path
    }

    /// The tool's JSON payload over `/vaults/<vault>/mcp`, with the token and an
    /// optional caller offset.
    pub async fn call_raw(
        &self,
        vault: &str,
        offset: Option<&str>,
        tool: &str,
        arguments: Value,
    ) -> Value {
        let msg = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": tool, "arguments": arguments },
        });
        let mut req = client()
            .post(format!("http://{}/vaults/{vault}/mcp", self.addr))
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("authorization", format!("Bearer {TEST_TOKEN}"))
            .body(msg.to_string());
        if let Some(offset) = offset {
            req = req.header("X-Memex-UTC-Offset", offset);
        }
        let reply = Reply::read(req.send().await.expect("send MCP POST")).await;
        assert_eq!(reply.status, 200, "{tool}: {:?}", reply.body);
        let v = reply.json();
        assert!(
            v.get("error").is_none(),
            "tools/call {tool} failed, a JSON-RPC error: {v}"
        );
        let text = v["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{tool} returned no text content: {v}"));
        serde_json::from_str(text)
            .unwrap_or_else(|e| panic!("{tool} returned non-JSON ({e}): {text}"))
    }

    /// Like [`Self::call_raw`], but fails the test on an error object.
    pub async fn call(
        &self,
        vault: &str,
        offset: Option<&str>,
        tool: &str,
        arguments: Value,
    ) -> Value {
        let v = self.call_raw(vault, offset, tool, arguments).await;
        assert!(v.get("error").is_none(), "{tool} ({offset:?}) errored: {v}");
        v
    }

    /// `GET /notes/<id>/agent-changes` of `vault`: the hosted Activity list,
    /// newest first.
    pub async fn agent_changes(&self, vault: &str, note_id: &str) -> Vec<Value> {
        let url = format!(
            "http://{}/vaults/{vault}/api/v1/notes/{note_id}/agent-changes",
            self.addr
        );
        let reply = Reply::read(
            client()
                .get(url)
                .header("authorization", format!("Bearer {TEST_TOKEN}"))
                .send()
                .await
                .expect("send GET"),
        )
        .await;
        assert_eq!(reply.status, 200, "agent-changes: {:?}", reply.body);
        reply.json()["changes"]
            .as_array()
            .unwrap_or_else(|| panic!("a changes array: {:?}", reply.body))
            .clone()
    }
}

impl Drop for Hosted {
    fn drop(&mut self) {
        self.task.abort();
    }
}
