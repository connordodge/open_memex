//! WI #12 (R9): the MCP tool `append_to_daily_note(text, date?)`.
//!
//! - Appends `text` verbatim to the person section of the day's daily note
//!   (default today, local time), above the Topics footer marker, creating
//!   the note when absent; new blocks get `source: agent`.
//! - Returns `note_id`, `date`, `block_ids`, `content_version`, `version` and
//!   `prior_state` (the review state just before the append), which the
//!   `capture` prompt relies on.
//! - Errors (CONTRACTS C1): `invalid_date`, `invalid_argument` (empty text),
//!   `title_conflict` with `existing_id` (agents never adopt, Q2). Every
//!   failure writes nothing.
//!
//! The race with a person save (AC 7) is tested in core
//! (`crates/memex-core/tests/append.rs`) through the deterministic seam.
//! Params are built with `serde_json::from_value(json!(…))` (D23).

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::canvas::SystemClock;
use memex_core::notes::{self, CreateNote, NoteId, RenameOptions, UpdateNote};
use memex_core::{daily, Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

const MARKER_LINE: &str = "<!-- memex:topics -->\n";

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

async fn append(memex: &Memex, args: Value) -> Value {
    let resp = memex.append_to_daily_note(params(args)).await;
    serde_json::from_str(&resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
}

/// Calls the tool and asserts it succeeded.
async fn append_ok(memex: &Memex, args: Value) -> Value {
    let v = append(memex, args).await;
    assert!(
        v.get("error").is_none() && v["note_id"].is_string(),
        "append_to_daily_note failed: {v}"
    );
    v
}

fn today() -> String {
    daily::today_with_clock(&SystemClock).to_string()
}

async fn create_daily(state: &AppState, title: &str, body: &str) -> String {
    let mut vault = state.vault.lock().await;
    notes::create_note_as(
        &mut vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(json!({ "role": "daily" })),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create daily {title}: {e}"))
    .id
    .to_string()
}

async fn create_plain(state: &AppState, title: &str, body: &str, fm: Option<Value>) -> String {
    let mut vault = state.vault.lock().await;
    notes::create_note_as(
        &mut vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"))
    .id
    .to_string()
}

async fn person_save(state: &AppState, id: &str, body: &str) {
    let mut vault = state.vault.lock().await;
    let id = NoteId::parse(id).unwrap();
    let version = notes::get_note(&vault, &id).unwrap().version;
    notes::update_note_as(
        &mut vault,
        &id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person save {id}: {e}"));
}

/// Marks the day reviewed at its current content version.
async fn mark_reviewed(state: &AppState, id: &str) {
    let vault = state.vault.lock().await;
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE day_reviews SET reviewed_content_version = content_version, reviewed_at = 1
             WHERE note_id = ?",
            [id],
        )
        .unwrap();
    assert_eq!(n, 1);
}

async fn review_state(state: &AppState, id: &str) -> &'static str {
    let vault = state.vault.lock().await;
    daily::review_state(vault.connection_ref(), id)
        .unwrap()
        .as_str()
}

struct Stored {
    title: String,
    content_md: String,
    frontmatter: Value,
    version: i64,
}

async fn stored(state: &AppState, id: &str) -> Stored {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT title, content_md, frontmatter, version FROM notes WHERE id = ?",
            [id],
            |r| {
                let fm: String = r.get(2)?;
                Ok(Stored {
                    title: r.get(0)?,
                    content_md: r.get(1)?,
                    frontmatter: serde_json::from_str(&fm).unwrap(),
                    version: r.get(3)?,
                })
            },
        )
        .unwrap()
}

/// `(block_id, text, source, created_version)` in `ord` order.
async fn blocks_of(state: &AppState, id: &str) -> Vec<(String, String, String, i64)> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT block_id, text, source, created_version FROM blocks
             WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

async fn content_version(state: &AppState, id: &str) -> Option<i64> {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id],
            |r| r.get(0),
        )
        .ok()
}

/// Every note row, by id: `(id, title, content_md, frontmatter, version)`.
async fn snapshot(state: &AppState) -> Vec<(String, String, String, String, i64)> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT id, title, content_md, frontmatter, version FROM notes ORDER BY id")
        .unwrap();
    stmt.query_map([], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

async fn block_count(state: &AppState) -> i64 {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM blocks", [], |r| r.get(0))
        .unwrap()
}

fn str_ids(v: &Value) -> Vec<String> {
    v["block_ids"]
        .as_array()
        .unwrap_or_else(|| panic!("block_ids is an array: {v}"))
        .iter()
        .map(|b| b.as_str().expect("block id string").to_string())
        .collect()
}

// ---------- AC 1: today by default; the returned fields ----------

#[tokio::test]
async fn append_tool_without_date_appends_to_todays_daily_note_and_returns_the_outcome() {
    let (_dir, state, memex) = fresh();
    let day = today();
    let id = create_daily(&state, &day, "Morning pages\n").await;

    let v = append_ok(&memex, json!({ "text": "Bought a new keyboard." })).await;
    if today() != day {
        return; // crossed local midnight mid-test
    }

    for key in [
        "note_id",
        "date",
        "block_ids",
        "content_version",
        "version",
        "prior_state",
    ] {
        assert!(v.get(key).is_some(), "missing {key}: {v}");
    }
    assert_eq!(v["note_id"], id.as_str());
    assert_eq!(v["date"], day.as_str());
    let s = stored(&state, &id).await;
    assert_eq!(
        s.content_md,
        format!("Morning pages\n\nBought a new keyboard.\n{MARKER_LINE}")
    );
    assert_eq!(v["version"], json!(s.version));
    assert_eq!(s.version, 2);
    assert_eq!(v["content_version"], json!(2));
    assert_eq!(content_version(&state, &id).await, Some(2));
    assert_eq!(v["prior_state"], "Unreviewed");

    let ids = str_ids(&v);
    let blocks = blocks_of(&state, &id).await;
    assert_eq!(ids.len(), 1, "{v}");
    assert_eq!(blocks.len(), 2);
    assert_eq!(ids[0], blocks[1].0);
    assert_eq!(blocks[1].1, "Bought a new keyboard.");
}

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
                "clientInfo": { "name": "wi12-test", "version": "0" },
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

#[test]
fn append_tool_is_served_with_text_required_and_date_optional() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = Server::start(path.to_str().unwrap());
    let resp = server.request(2, "tools/list", json!({}));
    let tools = resp["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list failed: {resp}"));
    let names: Vec<&str> = tools.iter().filter_map(|t| t["name"].as_str()).collect();
    let tool = tools
        .iter()
        .find(|t| t["name"] == "append_to_daily_note")
        .unwrap_or_else(|| panic!("append_to_daily_note not served: {names:?}"));
    let unique: BTreeSet<&str> = names.iter().copied().collect();
    assert_eq!(unique.len(), names.len(), "no duplicate tools: {names:?}");

    let schema = &tool["inputSchema"];
    assert!(schema["properties"]["text"].is_object(), "{schema}");
    assert!(schema["properties"]["date"].is_object(), "{schema}");
    let required: Vec<&str> = schema["required"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    assert_eq!(required, vec!["text"], "{schema}");
}

// ---------- AC 2: creates today's daily note when missing ----------

#[tokio::test]
async fn append_tool_creates_todays_daily_note_when_missing() {
    let (_dir, state, memex) = fresh();
    let before = today();
    let v = append_ok(&memex, json!({ "text": "Bought a new keyboard." })).await;
    let after = today();

    let id = v["note_id"].as_str().unwrap().to_string();
    let s = stored(&state, &id).await;
    assert!(
        s.title == before || s.title == after,
        "title {:?} is not today ({before}/{after})",
        s.title
    );
    assert_eq!(v["date"], s.title.as_str());
    assert_eq!(s.frontmatter["role"], "daily");
    assert_eq!(
        s.content_md,
        format!("Bought a new keyboard.\n{MARKER_LINE}")
    );
    assert_eq!(snapshot(&state).await.len(), 1);
    assert_eq!(v["version"], json!(s.version));
    assert_eq!(v["content_version"], json!(1));
    assert_eq!(v["prior_state"], "Unreviewed");

    let blocks = blocks_of(&state, &id).await;
    assert_eq!(blocks.len(), 1);
    assert_eq!(str_ids(&v), vec![blocks[0].0.clone()]);
    assert_eq!(blocks[0].2, "agent");
    assert_eq!(blocks[0].3, s.version);
}

// ---------- AC 3: end of the person section, footer untouched ----------

#[tokio::test]
async fn append_tool_keeps_the_text_verbatim_above_the_footer() {
    let (_dir, state, memex) = fresh();
    let topic = create_plain(
        &state,
        "Player Loop",
        "jump",
        Some(json!({ "role": "topic" })),
    )
    .await;
    let id = create_daily(&state, "2026-10-01", "Morning pages\n").await;
    {
        let vault = state.vault.lock().await;
        vault
            .connection_ref()
            .execute(
                "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
                 VALUES (?, ?, 'person', 0)",
                params![id, topic],
            )
            .unwrap();
    }
    person_save(&state, &id, "Morning pages\n").await;
    let footer = format!("{MARKER_LINE}[[Player Loop~about]]\n");
    assert_eq!(
        stored(&state, &id).await.content_md,
        format!("Morning pages\n{footer}")
    );

    let text = "teh keybaord is *great*,  honestly — café\n- tried coyote time";
    append_ok(&memex, json!({ "text": text, "date": "2026-10-01" })).await;

    assert_eq!(
        stored(&state, &id).await.content_md,
        format!("Morning pages\n\n{text}\n{footer}")
    );
}

// ---------- AC 4: two paragraphs, two agent blocks ----------

#[tokio::test]
async fn append_tool_two_paragraphs_return_two_agent_blocks_in_order() {
    let (_dir, state, memex) = fresh();
    let id = create_daily(&state, "2026-10-01", "Morning pages\n").await;

    let v = append_ok(
        &memex,
        json!({ "text": "First thought.\n\nSecond thought.", "date": "2026-10-01" }),
    )
    .await;

    let blocks = blocks_of(&state, &id).await;
    assert_eq!(blocks.len(), 3);
    assert_eq!(blocks[0].2, "person");
    assert_eq!(str_ids(&v), vec![blocks[1].0.clone(), blocks[2].0.clone()]);
    assert_eq!(blocks[1].1, "First thought.");
    assert_eq!(blocks[2].1, "Second thought.");
    let version = v["version"].as_i64().expect("version is an integer");
    assert_eq!(version, 2);
    for b in &blocks[1..] {
        assert_eq!(b.2, "agent", "{b:?}");
        assert_eq!(b.3, version, "{b:?}");
    }
}

// ---------- AC 5: prior_state labels ----------

#[tokio::test]
async fn append_tool_reports_each_prior_state_label() {
    let (_dir, state, memex) = fresh();
    let reviewed = create_daily(&state, "2026-10-01", "Reviewed day.\n").await;
    mark_reviewed(&state, &reviewed).await;
    create_daily(&state, "2026-10-02", "Never reviewed.\n").await;
    let changed = create_daily(&state, "2026-09-30", "Reviewed once.\n").await;
    mark_reviewed(&state, &changed).await;
    person_save(&state, &changed, "Reviewed once.\n\nUnfiled person edit.\n").await;

    for (date, label) in [
        ("2026-10-01", "Reviewed"),
        ("2026-10-02", "Unreviewed"),
        ("2026-09-30", "Changed since review"),
    ] {
        let v = append_ok(&memex, json!({ "text": "Captured.", "date": date })).await;
        assert_eq!(v["prior_state"], label, "{date}: {v}");
    }
}

// ---------- AC 6: state and content_version after the append ----------

#[tokio::test]
async fn append_tool_bumps_content_version_and_leaves_a_reviewed_day_changed_since_review() {
    let (_dir, state, memex) = fresh();
    let reviewed = create_daily(&state, "2026-10-01", "Reviewed day.\n").await;
    mark_reviewed(&state, &reviewed).await;
    let fresh_day = create_daily(&state, "2026-10-02", "Never reviewed.\n").await;

    for (id, date, after) in [
        (&reviewed, "2026-10-01", "Changed since review"),
        (&fresh_day, "2026-10-02", "Unreviewed"),
    ] {
        let before = content_version(&state, id).await.unwrap();
        let v = append_ok(&memex, json!({ "text": "Captured.", "date": date })).await;
        assert_eq!(v["content_version"], json!(before + 1), "{date}: {v}");
        assert_eq!(content_version(&state, id).await, Some(before + 1));
        assert_eq!(review_state(&state, id).await, after, "{date}");
    }
}

// ---------- AC 8: explicit date; malformed date ----------

#[tokio::test]
async fn append_tool_with_an_explicit_date_appends_to_that_day() {
    let (_dir, state, memex) = fresh();
    let other = create_daily(&state, &today(), "Today.\n").await;
    let id = create_daily(&state, "2026-10-01", "Earlier day.\n").await;

    let v = append_ok(
        &memex,
        json!({ "text": "Bought a new keyboard.", "date": "2026-10-01" }),
    )
    .await;

    assert_eq!(v["note_id"], id.as_str());
    assert_eq!(v["date"], "2026-10-01");
    assert_eq!(
        stored(&state, &id).await.content_md,
        format!("Earlier day.\n\nBought a new keyboard.\n{MARKER_LINE}")
    );
    let kept = stored(&state, &other).await;
    assert_eq!(kept.version, 1);
    assert_eq!(kept.content_md, format!("Today.\n{MARKER_LINE}"));
}

#[tokio::test]
async fn append_tool_with_a_malformed_date_returns_invalid_date_and_writes_nothing() {
    let (_dir, state, memex) = fresh();
    create_daily(&state, "2026-10-01", "Earlier day.\n").await;
    let before = snapshot(&state).await;
    let blocks = block_count(&state).await;

    for bad in ["2026-10-1", "2026-02-30", "01-10-2026"] {
        let v = append(
            &memex,
            json!({ "text": "Bought a new keyboard.", "date": bad }),
        )
        .await;
        assert_eq!(v["error"]["code"], "invalid_date", "{bad}: {v}");
    }
    assert_eq!(snapshot(&state).await, before);
    assert_eq!(block_count(&state).await, blocks);
}

// ---------- AC 9: empty or whitespace-only text ----------

#[tokio::test]
async fn append_tool_with_empty_or_whitespace_text_returns_invalid_argument_and_writes_nothing() {
    let (_dir, state, memex) = fresh();
    create_daily(&state, "2026-10-01", "Earlier day.\n").await;
    let before = snapshot(&state).await;
    let blocks = block_count(&state).await;

    for text in ["", "   ", "\n\n", " \t\r\n "] {
        for args in [
            json!({ "text": text }),
            json!({ "text": text, "date": "2026-10-01" }),
        ] {
            let v = append(&memex, args.clone()).await;
            assert_eq!(v["error"]["code"], "invalid_argument", "{args}: {v}");
            assert!(v["error"]["message"].is_string(), "{v}");
        }
    }
    assert_eq!(snapshot(&state).await, before, "nothing written");
    assert_eq!(block_count(&state).await, blocks);
}

// ---------- AC 10: a role-less note titled with the date ----------

#[tokio::test]
async fn append_tool_over_a_role_less_note_returns_title_conflict_with_existing_id() {
    let (_dir, state, memex) = fresh();
    let old = create_plain(&state, "2026-10-01", "Old note body\n", None).await;
    let before = snapshot(&state).await;

    let v = append(
        &memex,
        json!({ "text": "Bought a new keyboard.", "date": "2026-10-01" }),
    )
    .await;

    assert_eq!(v["error"]["code"], "title_conflict", "{v}");
    assert_eq!(v["error"]["existing_id"], old.as_str(), "{v}");
    assert_eq!(
        snapshot(&state).await,
        before,
        "the role-less note is unchanged"
    );
    assert_eq!(block_count(&state).await, 0);
    assert_eq!(content_version(&state, &old).await, None);
}
