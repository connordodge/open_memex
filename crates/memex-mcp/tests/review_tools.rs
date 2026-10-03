//! WI #11 (R8): the review MCP tools and the review fields of `get_note` /
//! `memex get`.
//!
//! - `list_unreviewed_days` → `{"vault_id", "days": [{date, note_id, state,
//!   content_version, reviewed_content_version}]}`, oldest first.
//! - `get_daily_note_changes(date)` → `{"vault_id", "date", "note_id",
//!   "content_version", "added", "changed", "removed"}`, blocks as
//!   `{id, source, text}`.
//! - `mark_day_reviewed(date, version, changes)` → `{"vault_id", "date",
//!   "note_id", "state", "content_version", "reviewed_content_version",
//!   "reviewed_at"}`.
//! - Rule errors use the C1 object (`review_stale` with `version` and
//!   `current`, `change_entries_invalid`, `invalid_date`, `not_found`).
//! - MCP `get_note` and CLI `memex get` add `review` and `latest_change` for
//!   daily notes only.
//!
//! The person's notes are written through core with `Caller::Person`, as the
//! app does through the CLI. Params are built with
//! `serde_json::from_value(json!(…))`, never struct literals (D23). Error
//! JSON is compared as parsed values (keys serialize alphabetically).

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::canvas::Clock;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, NoteId, RenameOptions, UpdateNote,
};
use memex_core::review::{self, ChangeEntry};
use memex_core::{now_unix_ms, Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

const THREE_BLOCKS: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";

// ---------- harness ----------

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
    v.as_object()
        .unwrap_or_else(|| panic!("expected an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn assert_c1(v: &Value, code: &str, extra: &[&str]) {
    assert!(v["error"].is_object(), "expected an error object, got {v}");
    let e = &v["error"];
    assert_eq!(e["code"], json!(code), "{v}");
    assert!(e["message"].is_string(), "message: {v}");
    let mut expected = set(&["code", "message"]);
    expected.extend(set(extra));
    assert_eq!(keys(e), expected, "C1 fields for {code}: {v}");
}

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

// ---------- the person's writes (through core, Caller::Person) ----------

fn create_in(vault: &mut Vault, title: &str, body: &str, frontmatter: Value) -> String {
    create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(frontmatter),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"))
    .id
    .to_string()
}

async fn person_create(state: &AppState, title: &str, body: &str, frontmatter: Value) -> String {
    let mut vault = state.vault.lock().await;
    create_in(&mut vault, title, body, frontmatter)
}

async fn daily(state: &AppState, date: &str, body: &str) -> String {
    person_create(state, date, body, json!({ "role": "daily" })).await
}

async fn topic(state: &AppState, title: &str) -> String {
    person_create(state, title, "A topic.", json!({ "role": "topic" })).await
}

fn update_in(vault: &mut Vault, id: &str, patch: UpdateNote) {
    let id = NoteId::parse(id).unwrap();
    let version = get_note(vault, &id).unwrap().version;
    update_note_as(
        vault,
        &id,
        version,
        patch,
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("update {id}: {e}"));
}

async fn person_set_body(state: &AppState, id: &str, body: &str) {
    let mut vault = state.vault.lock().await;
    update_in(
        &mut vault,
        id,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
    );
}

// ---------- reads ----------

async fn vault_id(state: &AppState) -> String {
    state.vault.lock().await.vault_id().to_string()
}

/// `(content_version, reviewed_content_version, reviewed_at)`.
async fn day_review_row(state: &AppState, id: &str) -> (i64, Option<i64>, Option<i64>) {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version, reviewed_content_version, reviewed_at
             FROM day_reviews WHERE note_id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap()
}

/// `(block_id, source, text)` of the current blocks, in `ord` order.
async fn blocks_of(state: &AppState, id: &str) -> Vec<(String, String, String)> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT block_id, source, text FROM blocks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    stmt.query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

async fn snapshot_count(state: &AppState, id: &str) -> i64 {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM day_review_blocks WHERE note_id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

/// `(note_id, day, created_at, bullets)` of every `agent_changes` row, oldest first.
async fn change_rows(state: &AppState) -> Vec<(String, String, i64, Vec<String>)> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT note_id, day, created_at, bullets_json FROM agent_changes
             ORDER BY created_at, rowid",
        )
        .unwrap();
    stmt.query_map([], |r| {
        let bullets: String = r.get(3)?;
        Ok((
            r.get(0)?,
            r.get(1)?,
            r.get(2)?,
            serde_json::from_str(&bullets).unwrap(),
        ))
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

fn block_json(blocks: &[(String, String, String)]) -> Value {
    Value::Array(
        blocks
            .iter()
            .map(|(id, source, text)| json!({ "id": id, "source": source, "text": text }))
            .collect(),
    )
}

// ---------- tool calls ----------

async fn list_days(m: &Memex) -> Value {
    parse(&m.list_unreviewed_days(params(json!({}))).await)
}

async fn changes(m: &Memex, date: &str) -> Value {
    parse(
        &m.get_daily_note_changes(params(json!({ "date": date })))
            .await,
    )
}

async fn mark(m: &Memex, date: &str, version: i64, changes: Value) -> Value {
    parse(
        &m.mark_day_reviewed(params(json!({
            "date": date,
            "version": version,
            "changes": changes,
        })))
        .await,
    )
}

async fn mark_ok(m: &Memex, date: &str, version: i64, changes: Value) -> Value {
    let v = mark(m, date, version, changes).await;
    assert!(v.get("error").is_none(), "mark_day_reviewed failed: {v}");
    v
}

fn daily_change(id: &str) -> Value {
    json!({ "note_id": id, "bullets": ["Filed 2 blocks into Player Loop"] })
}

// ======================================================================
// AC 1 / AC 14: list_unreviewed_days shape, oldest first.
// ======================================================================

#[tokio::test]
async fn mcp_list_unreviewed_days_returns_unreviewed_and_changed_days_oldest_first() {
    let (_dir, state, memex) = fresh();
    let d07 = daily(&state, "2026-09-07", "Seventh.\n").await;
    let d05 = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    let d06 = daily(&state, "2026-09-06", "Sixth.\n").await;
    topic(&state, "Player Loop").await;

    mark_ok(&memex, "2026-09-06", 1, json!([daily_change(&d06)])).await;
    person_set_body(&state, &d06, "Sixth, edited.\n").await;

    let got = list_days(&memex).await;
    assert_eq!(
        got,
        json!({
            "vault_id": vault_id(&state).await,
            "days": [
                {
                    "date": "2026-09-05",
                    "note_id": d05,
                    "state": "Unreviewed",
                    "content_version": 1,
                    "reviewed_content_version": null,
                },
                {
                    "date": "2026-09-06",
                    "note_id": d06,
                    "state": "Changed since review",
                    "content_version": 2,
                    "reviewed_content_version": 1,
                },
                {
                    "date": "2026-09-07",
                    "note_id": d07,
                    "state": "Unreviewed",
                    "content_version": 1,
                    "reviewed_content_version": null,
                },
            ],
        })
    );
}

// ======================================================================
// AC 2: empty / whitespace-only and Reviewed days are omitted.
// ======================================================================

#[tokio::test]
async fn mcp_list_unreviewed_days_omits_empty_and_reviewed_days() {
    let (_dir, state, memex) = fresh();
    daily(&state, "2026-09-01", "").await;
    daily(&state, "2026-09-02", "  \n\n").await;
    let d03 = daily(&state, "2026-09-03", "Third.\n").await;
    daily(&state, "2026-09-04", "Fourth.\n").await;
    mark_ok(&memex, "2026-09-03", 1, json!([daily_change(&d03)])).await;

    let got = list_days(&memex).await;
    let dates: Vec<&str> = got["days"]
        .as_array()
        .unwrap_or_else(|| panic!("days array: {got}"))
        .iter()
        .map(|d| d["date"].as_str().unwrap())
        .collect();
    assert_eq!(dates, vec!["2026-09-04"]);
}

#[tokio::test]
async fn mcp_list_unreviewed_days_in_a_vault_without_days_is_empty() {
    let (_dir, state, memex) = fresh();
    topic(&state, "Player Loop").await;
    assert_eq!(
        list_days(&memex).await,
        json!({ "vault_id": vault_id(&state).await, "days": [] })
    );
}

// ======================================================================
// AC 3: a person edit after review → Changed since review, no agent action.
// ======================================================================

#[tokio::test]
async fn mcp_reviewed_day_reappears_after_a_person_edit() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    mark_ok(&memex, "2026-09-05", 1, json!([daily_change(&day)])).await;
    assert_eq!(list_days(&memex).await["days"], json!([]));

    person_set_body(&state, &day, &format!("{THREE_BLOCKS}\nAnother thought.\n")).await;
    assert_eq!(
        list_days(&memex).await["days"],
        json!([{
            "date": "2026-09-05",
            "note_id": day,
            "state": "Changed since review",
            "content_version": 2,
            "reviewed_content_version": 1,
        }])
    );
}

// ======================================================================
// AC 4 / AC 14: never-reviewed day, every block `added`.
// ======================================================================

#[tokio::test]
async fn mcp_get_daily_note_changes_for_a_never_reviewed_day_returns_every_block_added() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    let blocks = blocks_of(&state, &day).await;
    assert_eq!(blocks.len(), 3, "precondition");

    let got = changes(&memex, "2026-09-05").await;
    assert_eq!(
        got,
        json!({
            "vault_id": vault_id(&state).await,
            "date": "2026-09-05",
            "note_id": day,
            "content_version": 1,
            "added": block_json(&blocks),
            "changed": [],
            "removed": [],
        })
    );
}

// ======================================================================
// AC 5: one changed, one added, one removed after a review.
// ======================================================================

#[tokio::test]
async fn mcp_get_daily_note_changes_after_review_returns_changed_added_and_removed() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    let before = blocks_of(&state, &day).await;
    mark_ok(&memex, "2026-09-05", 1, json!([daily_change(&day)])).await;

    person_set_body(
        &state,
        &day,
        "- tried coyote time again\n\nSleep was bad.\n\n## Level ideas\n",
    )
    .await;
    let after = blocks_of(&state, &day).await;
    assert_eq!(after[0].0, before[1].0, "precondition: edit kept its id");

    let got = changes(&memex, "2026-09-05").await;
    assert_eq!(got["content_version"], json!(2), "{got}");
    assert_eq!(got["changed"], block_json(&after[..1]), "{got}");
    assert_eq!(got["added"], block_json(&after[2..]), "{got}");
    let removed = got["removed"]
        .as_array()
        .unwrap_or_else(|| panic!("removed array: {got}"));
    assert_eq!(removed.len(), 1, "{got}");
    assert_eq!(removed[0]["id"], json!(before[0].0));
    assert_eq!(removed[0]["text"], json!("Fixed the jump arc."));
}

// ======================================================================
// AC 6: invalid_date and not_found.
// ======================================================================

#[tokio::test]
async fn mcp_get_daily_note_changes_errors_with_invalid_date_and_not_found() {
    let (_dir, state, memex) = fresh();
    daily(&state, "2026-09-05", "Fifth.\n").await;
    person_create(&state, "2026-09-04", "Role-less.", json!({})).await;

    for bad in ["2026-9-5", "2026-02-30", "tomorrow"] {
        assert_c1(&changes(&memex, bad).await, "invalid_date", &[]);
    }
    for missing in ["2026-09-06", "2026-09-04"] {
        assert_c1(&changes(&memex, missing).await, "not_found", &[]);
    }
}

// ======================================================================
// AC 7 / AC 8 / AC 14: mark_day_reviewed over MCP.
// ======================================================================

#[tokio::test]
async fn mcp_mark_day_reviewed_marks_the_day_and_appends_change_entries() {
    let (_dir, state, memex) = fresh();
    let player = topic(&state, "Player Loop").await;
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;

    let start = now_unix_ms();
    let got = mark_ok(
        &memex,
        "2026-09-05",
        1,
        json!([
            { "note_id": day, "bullets": ["Filed 2 blocks into Player Loop"] },
            { "note_id": player, "bullets": ["Created topic", "Added excerpt from 2026-09-05"] },
        ]),
    )
    .await;
    let end = now_unix_ms();

    assert_eq!(
        keys(&got),
        set(&[
            "vault_id",
            "date",
            "note_id",
            "state",
            "content_version",
            "reviewed_content_version",
            "reviewed_at",
        ]),
        "{got}"
    );
    assert_eq!(got["vault_id"], json!(vault_id(&state).await));
    assert_eq!(got["date"], json!("2026-09-05"));
    assert_eq!(got["note_id"], json!(day));
    assert_eq!(got["state"], json!("Reviewed"));
    assert_eq!(got["content_version"], json!(1));
    assert_eq!(got["reviewed_content_version"], json!(1));
    let at = got["reviewed_at"]
        .as_i64()
        .unwrap_or_else(|| panic!("{got}"));
    assert!(
        (start..=end).contains(&at),
        "reviewed_at {at} in [{start}, {end}]"
    );

    assert_eq!(day_review_row(&state, &day).await, (1, Some(1), Some(at)));
    assert_eq!(snapshot_count(&state, &day).await, 3);
    let rows = change_rows(&state).await;
    assert_eq!(rows.len(), 2, "{rows:?}");
    let day_row = rows.iter().find(|r| r.0 == day).expect("daily entry row");
    assert_eq!(
        (day_row.1.as_str(), day_row.2, day_row.3.clone()),
        (
            "2026-09-05",
            at,
            vec!["Filed 2 blocks into Player Loop".to_string()]
        )
    );
    let topic_row = rows
        .iter()
        .find(|r| r.0 == player)
        .expect("topic entry row");
    assert_eq!(topic_row.1, "2026-09-05");
    assert_eq!(
        topic_row.3,
        vec![
            "Created topic".to_string(),
            "Added excerpt from 2026-09-05".to_string()
        ]
    );

    // A second call appends and keeps the first rows.
    mark_ok(
        &memex,
        "2026-09-05",
        1,
        json!([{ "note_id": day, "bullets": ["Nothing new to file"] }]),
    )
    .await;
    let after = change_rows(&state).await;
    assert_eq!(after.len(), 3);
    assert_eq!(&after[..2], &rows[..]);
}

// ======================================================================
// AC 9: review_stale over MCP, nothing written.
// ======================================================================

#[tokio::test]
async fn mcp_mark_day_reviewed_with_a_stale_version_returns_review_stale() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    person_set_body(&state, &day, "Fixed the jump arc.\n").await;

    let got = mark(&memex, "2026-09-05", 1, json!([daily_change(&day)])).await;
    assert_c1(&got, "review_stale", &["version", "current"]);
    assert_eq!(got["error"]["version"], json!(1));
    assert_eq!(got["error"]["current"], json!(2));

    assert_eq!(day_review_row(&state, &day).await, (2, None, None));
    assert_eq!(snapshot_count(&state, &day).await, 0);
    assert!(change_rows(&state).await.is_empty());
}

// ======================================================================
// AC 10: footer writes between fetch and mark do not make the call stale.
// ======================================================================

#[tokio::test]
async fn mcp_review_sequence_with_footer_writes_succeeds_with_the_fetched_version() {
    let (_dir, state, memex) = fresh();
    let player = topic(&state, "Player Loop").await;
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    person_set_body(&state, &day, &format!("{THREE_BLOCKS}\n## Level ideas\n")).await;

    let fetched = changes(&memex, "2026-09-05").await;
    let version = fetched["content_version"]
        .as_i64()
        .unwrap_or_else(|| panic!("{fetched}"));
    assert_eq!(version, 2);

    {
        let mut vault = state.vault.lock().await;
        let id = NoteId::parse(&day).unwrap();
        let notes_version = get_note(&vault, &id).unwrap().version;
        // Write 1: a footer chip, re-rendered by a save of the same person text.
        vault
            .connection_ref()
            .execute(
                "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
                 VALUES (?, ?, 'excerpt', 0)",
                params![day, player],
            )
            .unwrap();
        let body = get_note(&vault, &id).unwrap().content_md;
        update_in(
            &mut vault,
            &day,
            UpdateNote {
                content_md: Some(body),
                ..Default::default()
            },
        );
        // Write 2: frontmatter only.
        update_in(
            &mut vault,
            &day,
            UpdateNote {
                frontmatter: Some(json!({ "role": "daily", "mood": "ok" })),
                ..Default::default()
            },
        );
        assert_eq!(get_note(&vault, &id).unwrap().version, notes_version + 2);
    }

    let got = mark_ok(
        &memex,
        "2026-09-05",
        version,
        json!([
            daily_change(&day),
            { "note_id": player, "bullets": ["Added excerpt from 2026-09-05"] },
        ]),
    )
    .await;
    assert_eq!(got["state"], json!("Reviewed"));
    assert_eq!(got["reviewed_content_version"], json!(2));
    assert_eq!(day_review_row(&state, &day).await.1, Some(2));
}

// ======================================================================
// AC 11: change_entries_invalid over MCP, nothing written.
// ======================================================================

#[tokio::test]
async fn mcp_mark_day_reviewed_with_invalid_entries_returns_change_entries_invalid() {
    let (_dir, state, memex) = fresh();
    let player = topic(&state, "Player Loop").await;
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    let ok = daily_change(&day);
    let cases = [
        json!([ok, { "note_id": player, "bullets": [] }]),
        json!([ok, { "note_id": player, "bullets": ["1", "2", "3", "4"] }]),
        json!([ok, { "note_id": player, "bullets": ["a".repeat(201)] }]),
        json!([ok, { "note_id": player, "bullets": ["two\nlines"] }]),
        json!([ok, { "note_id": player, "bullets": ["- Linked to Sleep"] }]),
        json!([{ "note_id": player, "bullets": ["Added excerpt"] }]),
    ];
    for changes in cases {
        let got = mark(&memex, "2026-09-05", 1, changes.clone()).await;
        assert_c1(&got, "change_entries_invalid", &[]);
        assert_eq!(
            day_review_row(&state, &day).await,
            (1, None, None),
            "{changes}"
        );
        assert_eq!(snapshot_count(&state, &day).await, 0, "{changes}");
        assert!(change_rows(&state).await.is_empty(), "{changes}");
    }
}

// ======================================================================
// AC 12: a 200-character bullet is accepted.
// ======================================================================

#[tokio::test]
async fn mcp_mark_day_reviewed_accepts_a_200_character_bullet() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    let bullet = "b".repeat(200);
    let got = mark_ok(
        &memex,
        "2026-09-05",
        1,
        json!([{ "note_id": day, "bullets": [bullet] }]),
    )
    .await;
    assert_eq!(got["state"], json!("Reviewed"));
    assert_eq!(change_rows(&state).await[0].3, vec![bullet]);
}

// ======================================================================
// AC 14: rule errors of mark_day_reviewed use the C1 shape.
// ======================================================================

#[tokio::test]
async fn mcp_mark_day_reviewed_with_a_bad_or_missing_date_returns_c1() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    assert_c1(
        &mark(&memex, "2026-9-5", 1, json!([daily_change(&day)])).await,
        "invalid_date",
        &[],
    );
    assert_c1(
        &mark(&memex, "2026-09-06", 1, json!([daily_change(&day)])).await,
        "not_found",
        &[],
    );
    assert_eq!(day_review_row(&state, &day).await, (1, None, None));
    assert!(change_rows(&state).await.is_empty());
}

// ======================================================================
// AC 13: get_note / memex get add `review` and `latest_change` for daily notes.
// ======================================================================

#[tokio::test]
async fn mcp_get_note_on_a_daily_note_includes_review_and_latest_change() {
    let (_dir, state, memex) = fresh();
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    let fresh_day = daily(&state, "2026-09-06", "Sixth.\n").await;

    let got = mark_ok(
        &memex,
        "2026-09-05",
        1,
        json!([{ "note_id": day, "bullets": ["Filed 2 blocks into Player Loop", "Linked topics"] }]),
    )
    .await;
    let at = got["reviewed_at"].as_i64().unwrap();

    let note = parse(&memex.get_note(params(json!({ "note_id": day }))).await);
    assert_eq!(
        note["review"],
        json!({
            "state": "Reviewed",
            "content_version": 1,
            "reviewed_content_version": 1,
            "reviewed_at": at,
        }),
        "{note}"
    );
    let latest = &note["latest_change"];
    assert_eq!(
        keys(latest),
        set(&["day", "created_at", "bullets"]),
        "{note}"
    );
    assert_eq!(latest["day"], json!("2026-09-05"));
    assert!(latest["created_at"].is_i64(), "{note}");
    assert_eq!(
        latest["bullets"],
        json!(["Filed 2 blocks into Player Loop", "Linked topics"])
    );

    let note = parse(
        &memex
            .get_note(params(json!({ "note_id": fresh_day })))
            .await,
    );
    assert_eq!(
        note["review"],
        json!({
            "state": "Unreviewed",
            "content_version": 1,
            "reviewed_content_version": null,
            "reviewed_at": null,
        }),
        "{note}"
    );
    let obj = note.as_object().unwrap();
    assert!(obj.contains_key("latest_change"), "{note}");
    assert_eq!(obj["latest_change"], Value::Null, "{note}");
}

#[tokio::test]
async fn mcp_get_note_on_a_note_that_is_not_daily_has_no_review_keys() {
    let (_dir, state, memex) = fresh();
    let player = topic(&state, "Player Loop").await;
    let iso = person_create(&state, "2026-09-04", "Role-less.", json!({})).await;
    let day = daily(&state, "2026-09-05", THREE_BLOCKS).await;
    mark_ok(
        &memex,
        "2026-09-05",
        1,
        json!([daily_change(&day), { "note_id": player, "bullets": ["Added excerpt"] }]),
    )
    .await;
    for id in [&player, &iso] {
        let note = parse(&memex.get_note(params(json!({ "note_id": id }))).await);
        let obj = note.as_object().unwrap_or_else(|| panic!("{note}"));
        assert!(obj.contains_key("note_id"), "{note}");
        assert!(!obj.contains_key("review"), "{note}");
        assert!(!obj.contains_key("latest_change"), "{note}");
    }
}

fn memex_get(vault: &Path, id: &str) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["get", "--vault", vault.to_str().unwrap(), "--note-id", id])
        .output()
        .expect("run memex get");
    assert!(
        out.status.success(),
        "memex get failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("memex get prints JSON")
}

const T1: i64 = 1_759_500_000_000;

#[test]
fn cli_memex_get_on_a_daily_note_includes_review_and_latest_change() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let (day, other) = {
        let mut vault = Vault::create(&path).unwrap();
        let day = create_in(
            &mut vault,
            "2026-09-05",
            THREE_BLOCKS,
            json!({ "role": "daily" }),
        );
        let other = create_in(
            &mut vault,
            "2026-09-06",
            "Sixth.\n",
            json!({ "role": "daily" }),
        );
        review::mark_day_reviewed(
            &mut vault,
            "2026-09-05",
            1,
            &[ChangeEntry {
                note_id: day.clone(),
                bullets: vec!["Filed 2 blocks into Player Loop".into()],
            }],
            &FixedClock(T1),
        )
        .unwrap();
        (day, other)
    };

    let got = memex_get(&path, &day);
    assert_eq!(
        got["review"],
        json!({
            "state": "Reviewed",
            "content_version": 1,
            "reviewed_content_version": 1,
            "reviewed_at": T1,
        }),
        "{got}"
    );
    assert_eq!(
        got["latest_change"],
        json!({
            "day": "2026-09-05",
            "created_at": T1,
            "bullets": ["Filed 2 blocks into Player Loop"],
        }),
        "{got}"
    );

    let got = memex_get(&path, &other);
    assert_eq!(got["review"]["state"], json!("Unreviewed"), "{got}");
    assert!(
        got.as_object().unwrap().contains_key("latest_change"),
        "{got}"
    );
    assert_eq!(got["latest_change"], Value::Null, "{got}");
}

#[test]
fn cli_memex_get_on_a_note_that_is_not_daily_has_no_review_keys() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let (ids, day) = {
        let mut vault = Vault::create(&path).unwrap();
        let ids = vec![
            create_in(
                &mut vault,
                "Player Loop",
                "A topic.",
                json!({ "role": "topic" }),
            ),
            create_in(&mut vault, "2026-09-04", "Role-less.", json!({})),
        ];
        let day = create_in(
            &mut vault,
            "2026-09-05",
            "Fifth.\n",
            json!({ "role": "daily" }),
        );
        (ids, day)
    };
    // Contrast: the daily note in the same vault does carry the keys.
    let got = memex_get(&path, &day);
    assert!(got["review"].is_object(), "{got}");
    assert!(
        got.as_object().unwrap().contains_key("latest_change"),
        "{got}"
    );
    for id in ids {
        let got = memex_get(&path, &id);
        let obj = got.as_object().unwrap();
        assert_eq!(obj["note_id"], json!(id));
        assert!(!obj.contains_key("review"), "{got}");
        assert!(!obj.contains_key("latest_change"), "{got}");
    }
}

// ======================================================================
// AC 14: the three tools are registered (served over stdio).
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
                "clientInfo": { "name": "wi11-test", "version": "0" },
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

fn property_set(schema: &Value) -> BTreeSet<String> {
    schema["properties"]
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default()
}

#[test]
fn mcp_server_registers_the_three_review_tools() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = Server::start(path.to_str().unwrap());
    let resp = server.request(2, "tools/list", json!({}));
    let tools = resp["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
        .clone();
    let schema = |name: &str| -> Value {
        tools
            .iter()
            .find(|t| t["name"] == json!(name))
            .unwrap_or_else(|| panic!("tool {name} is registered"))["inputSchema"]
            .clone()
    };

    let s = schema("list_unreviewed_days");
    assert!(string_set(&s["required"]).is_empty(), "{s}");
    let s = schema("get_daily_note_changes");
    assert_eq!(property_set(&s), set(&["date"]), "{s}");
    assert_eq!(string_set(&s["required"]), set(&["date"]), "{s}");
    let s = schema("mark_day_reviewed");
    assert_eq!(
        property_set(&s),
        set(&["date", "version", "changes"]),
        "{s}"
    );
    assert_eq!(
        string_set(&s["required"]),
        set(&["date", "version", "changes"]),
        "{s}"
    );
}
