//! WI #8 (R5): the marker guard over MCP, and the person (CLI) path it never
//! blocks (Req 16, Req 47, Req 75, D3).
//!
//! - MCP `add_link` with a daily note as `from`, and MCP `update_link` on a
//!   link whose source is a daily note, return the C1 object
//!   `{"error":{"code":"marker_rule","message":…}}` (the message contains
//!   `<!-- memex:topics -->`) and leave the daily note unchanged.
//! - MCP `add_link` from a topic note to a daily note succeeds.
//! - CLI `memex update`, `memex add-link` and `memex update-link` with a daily
//!   note as the source succeed (person path).
//!
//! Params are built with `serde_json::from_value(json!(…))` (D23). Error JSON
//! is compared as parsed values.

use std::io::Write;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;

use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId, RenameOptions, UpdateNote};
use memex_core::{Caller, MemexError, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

const MARKER: &str = "<!-- memex:topics -->";

struct Fixture {
    _dir: TempDir,
    path: String,
    state: Arc<AppState>,
    memex: Memex,
}

fn fresh() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path.clone(), None));
    let memex = Memex::new(state.clone());
    Fixture {
        _dir: dir,
        path: path.to_str().unwrap().to_string(),
        state,
        memex,
    }
}

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
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

#[derive(Debug, PartialEq)]
struct Stored {
    title: String,
    content_md: String,
    frontmatter: Value,
    version: i64,
    updated_at: i64,
    links: Vec<(String, String, Option<String>)>,
}

async fn stored(state: &AppState, id: &str) -> Stored {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let (title, content_md, fm, version, updated_at): (String, String, String, i64, i64) = conn
        .query_row(
            "SELECT title, content_md, frontmatter, version, updated_at FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .unwrap();
    let links = conn
        .prepare(
            "SELECT link_text, link_kind, label FROM links WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap()
        .query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    Stored {
        title,
        content_md,
        frontmatter: serde_json::from_str(&fm).unwrap(),
        version,
        updated_at,
        links,
    }
}

async fn link_id_from(state: &AppState, from: &str, link_text: &str) -> String {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links WHERE from_note_id = ? AND link_text = ? ORDER BY position LIMIT 1",
            [from, link_text],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("no link {link_text:?} from {from}: {e}"))
}

/// Asserts the C1 `marker_rule` object: exactly `code` and `message`, the
/// message containing the marker.
fn assert_marker_rule(v: &Value, what: &str) {
    let err = v
        .get("error")
        .and_then(Value::as_object)
        .unwrap_or_else(|| panic!("{what}: expected an error object, got {v}"));
    assert_eq!(err.get("code"), Some(&json!("marker_rule")), "{what}: {v}");
    let mut keys: Vec<&str> = err.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        ["code", "message"],
        "{what}: C1 marker_rule has no extra fields: {v}"
    );
    let message = err["message"].as_str().unwrap_or_default();
    assert!(
        message.contains(MARKER),
        "{what}: the message must contain {MARKER}: {v}"
    );
    assert_eq!(
        v.as_object().map(|o| o.len()),
        Some(1),
        "{what}: only `error`: {v}"
    );
}

async fn mcp_add_link(memex: &Memex, args: Value) -> Value {
    parse(&memex.add_link(params(args)).await)
}

async fn mcp_update_link(memex: &Memex, args: Value) -> Value {
    parse(&memex.update_link(params(args)).await)
}

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("spawn memex");
    if let Some(body) = stdin_body {
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(body.as_bytes())
            .unwrap();
    }
    drop(child.stdin.take());
    child.wait_with_output().expect("wait")
}

fn ok_json(out: Output) -> Value {
    assert!(
        out.status.success(),
        "expected success: exit={:?} stdout={} stderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    serde_json::from_str(stdout.trim_end())
        .unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

// ---------- AC 1: add_link from a daily note ----------

#[tokio::test]
async fn mcp_add_link_from_a_daily_note_returns_marker_rule_and_leaves_it_unchanged() {
    let f = fresh();
    let topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(&f.state, "2026-10-01", "Morning pages.\n", Some("daily")).await;
    let before = stored(&f.state, &daily).await;

    // `references` (body) and a typed kind (frontmatter) are both refused.
    for args in [
        json!({ "from_id": daily, "to_id": topic }),
        json!({ "from_id": daily, "to_id": topic, "kind": "references", "label": "loop" }),
        json!({ "from_id": daily, "to_id": topic, "kind": "extends" }),
    ] {
        let v = mcp_add_link(&f.memex, args.clone()).await;
        assert_marker_rule(&v, &format!("add_link {args}"));
        assert_eq!(
            stored(&f.state, &daily).await,
            before,
            "after add_link {args}"
        );
    }
}

/// Lead ruling: the guard is on the source and runs before the idempotency
/// check, so an existing link from a daily note is refused as well.
#[tokio::test]
async fn mcp_add_link_from_a_daily_note_when_the_link_exists_returns_marker_rule() {
    let f = fresh();
    let topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(
        &f.state,
        "2026-10-01",
        "Thinking about [[Player Loop]] today.\n",
        Some("daily"),
    )
    .await;
    link_id_from(&f.state, &daily, "Player Loop").await;
    let before = stored(&f.state, &daily).await;

    let v = mcp_add_link(
        &f.memex,
        json!({ "from_id": daily, "to_id": topic, "kind": "references" }),
    )
    .await;
    assert_marker_rule(&v, "add_link of an existing link");
    assert_eq!(stored(&f.state, &daily).await, before);

    // The same existing link from a topic note answers was_existing.
    let other = person_note(&f.state, "Sleep", "See [[Player Loop]].\n", Some("topic")).await;
    let v = mcp_add_link(&f.memex, json!({ "from_id": other, "to_id": topic })).await;
    assert_eq!(v["was_existing"], json!(true), "{v}");
}

/// The same for `update_link`: an edit that changes nothing on a daily
/// source is refused before `update_link_as` would answer it unsaved.
#[tokio::test]
async fn mcp_update_link_that_changes_nothing_on_a_daily_source_returns_marker_rule() {
    let f = fresh();
    let _topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(
        &f.state,
        "2026-10-01",
        "Thinking about [[Player Loop]] today.\n",
        Some("daily"),
    )
    .await;
    let link_id = link_id_from(&f.state, &daily, "Player Loop").await;
    let before = stored(&f.state, &daily).await;

    let v = mcp_update_link(
        &f.memex,
        json!({ "link_id": link_id, "kind": "references" }),
    )
    .await;
    assert_marker_rule(&v, "no-op update_link");
    assert_eq!(stored(&f.state, &daily).await, before);

    // An unknown link keeps its own error.
    let v = mcp_update_link(&f.memex, json!({ "link_id": "nope", "kind": "extends" })).await;
    assert_ne!(v["error"]["code"], json!("marker_rule"), "{v}");
}

// ---------- AC 2: update_link on a link whose source is a daily note ----------

#[tokio::test]
async fn mcp_update_link_with_a_daily_source_returns_marker_rule_and_leaves_it_unchanged() {
    let f = fresh();
    let _topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(
        &f.state,
        "2026-10-01",
        "Thinking about [[Player Loop]] today.\n",
        Some("daily"),
    )
    .await;
    let link_id = link_id_from(&f.state, &daily, "Player Loop").await;
    let before = stored(&f.state, &daily).await;

    for args in [
        json!({ "link_id": link_id, "kind": "extends" }),
        json!({ "link_id": link_id, "label": "the loop" }),
        json!({ "link_id": link_id, "kind": "contradicts", "label": "nope" }),
    ] {
        let v = mcp_update_link(&f.memex, args.clone()).await;
        assert_marker_rule(&v, &format!("update_link {args}"));
        assert_eq!(
            stored(&f.state, &daily).await,
            before,
            "after update_link {args}"
        );
    }
}

// ---------- AC 3: add_link from a topic note to a daily note ----------

#[tokio::test]
async fn mcp_add_link_from_a_topic_note_to_a_daily_note_succeeds_while_the_reverse_is_refused() {
    let f = fresh();
    let topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(&f.state, "2026-10-01", "Morning pages.\n", Some("daily")).await;
    let daily_before = stored(&f.state, &daily).await;
    let topic_before = stored(&f.state, &topic).await;

    let v = mcp_add_link(&f.memex, json!({ "from_id": topic, "to_id": daily })).await;
    assert!(v.get("error").is_none(), "topic -> daily must succeed: {v}");
    assert_eq!(v["from_id"], json!(topic));
    assert_eq!(v["to_id"], json!(daily));
    assert_eq!(v["was_existing"], json!(false));
    assert_eq!(v["note_version"], json!(topic_before.version + 1));
    assert!(v["link_id"].is_string(), "{v}");
    let topic_after = stored(&f.state, &topic).await;
    assert!(
        topic_after.content_md.contains("[[2026-10-01]]"),
        "{:?}",
        topic_after.content_md
    );
    assert_eq!(
        stored(&f.state, &daily).await,
        daily_before,
        "the target is untouched"
    );

    let v = mcp_add_link(&f.memex, json!({ "from_id": daily, "to_id": topic })).await;
    assert_marker_rule(&v, "daily -> topic");
}

// ---------- AC 5: the person (CLI) path is never blocked ----------

#[tokio::test]
async fn cli_update_of_a_daily_note_succeeds_where_the_agent_update_is_refused() {
    let f = fresh();
    let daily = person_note(&f.state, "2026-10-01", "Morning pages.\n", Some("daily")).await;
    let id = NoteId::parse(&daily).unwrap();
    let new_body = "Morning pages.\n\nAfternoon walk.\n";

    {
        let mut vault = f.state.vault.lock().await;
        let err = notes::update_note_as(
            &mut vault,
            &id,
            1,
            UpdateNote {
                content_md: Some(new_body.into()),
                ..Default::default()
            },
            RenameOptions::default(),
            Caller::Agent,
        )
        .map(|_| ())
        .unwrap_err();
        assert!(matches!(err, MemexError::MarkerRule(_)), "agent: {err:?}");
    }
    assert_eq!(stored(&f.state, &daily).await.version, 1);

    let out = ok_json(run(
        &[
            "update",
            "--vault",
            &f.path,
            "--note-id",
            &daily,
            "--expected-version",
            "1",
        ],
        Some(new_body),
    ));
    assert_eq!(out["note_id"], json!(daily));
    assert_eq!(out["version"], json!(2));
    let after = stored(&f.state, &daily).await;
    assert_eq!(after.version, 2);
    assert_eq!(after.content_md, format!("{new_body}{MARKER}\n"));
}

#[tokio::test]
async fn cli_add_link_from_a_daily_note_succeeds_where_mcp_add_link_is_refused() {
    let f = fresh();
    let topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(&f.state, "2026-10-01", "Morning pages.\n", Some("daily")).await;

    let v = mcp_add_link(&f.memex, json!({ "from_id": daily, "to_id": topic })).await;
    assert_marker_rule(&v, "mcp add_link");
    assert_eq!(stored(&f.state, &daily).await.version, 1);

    let out = ok_json(run(
        &[
            "add-link", "--vault", &f.path, "--from", &daily, "--to", &topic,
        ],
        None,
    ));
    assert_eq!(out["from"], json!(daily));
    assert_eq!(out["to"], json!(topic));
    assert_eq!(out["was_existing"], json!(false));
    assert_eq!(out["note_version"], json!(2));
    let after = stored(&f.state, &daily).await;
    assert_eq!(after.version, 2);
    assert!(
        after.content_md.contains("[[Player Loop]]"),
        "{:?}",
        after.content_md
    );
    assert!(
        after.links.iter().any(|l| l.0 == "Player Loop"),
        "{:?}",
        after.links
    );
}

#[tokio::test]
async fn cli_update_link_with_a_daily_source_succeeds_where_mcp_update_link_is_refused() {
    let f = fresh();
    let _topic = person_note(&f.state, "Player Loop", "Topic body.\n", Some("topic")).await;
    let daily = person_note(
        &f.state,
        "2026-10-01",
        "Thinking about [[Player Loop]] today.\n",
        Some("daily"),
    )
    .await;
    let link_id = link_id_from(&f.state, &daily, "Player Loop").await;

    let v = mcp_update_link(&f.memex, json!({ "link_id": link_id, "kind": "extends" })).await;
    assert_marker_rule(&v, "mcp update_link");
    assert_eq!(stored(&f.state, &daily).await.version, 1);

    let out = ok_json(run(
        &[
            "update-link",
            "--vault",
            &f.path,
            "--link-id",
            &link_id,
            "--kind",
            "extends",
        ],
        None,
    ));
    assert_eq!(out["kind"], json!("extends"));
    assert_eq!(out["from_note_id"], json!(daily));
    let after = stored(&f.state, &daily).await;
    assert_eq!(after.version, 2);
    assert!(
        after.content_md.contains("[[Player Loop~extends]]"),
        "{:?}",
        after.content_md
    );
}
