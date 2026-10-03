//! WI #7 (R4): MCP `create_note` with `role: "daily"` (D16 / Q4, D15 / Q2).
//!
//! - Allowed only with empty content (after trim) and an ISO title, which
//!   defaults to today (local time). Non-empty content is `marker_rule`.
//! - A non-ISO title is `invalid_date`; a role-less note holding the date is
//!   `title_conflict` with `existing_id` (agents never adopt); an existing
//!   daily note is `daily_note_exists`. Every failure creates nothing.
//!
//! Params are built with `serde_json::from_value(json!(…))` (D23).

use std::sync::Arc;

use memex_core::canvas::SystemClock;
use memex_core::notes::{self, CreateNote};
use memex_core::{daily, MemexError, Vault};
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

async fn create(memex: &Memex, args: Value) -> Value {
    let resp = memex.create_note(params(args)).await;
    serde_json::from_str(&resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
}

async fn create_ok(memex: &Memex, args: Value) -> String {
    let v = create(memex, args).await;
    v["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note failed: {v}"))
        .to_string()
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

async fn note_count(state: &AppState) -> i64 {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
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

/// A role-less note created on the person path, as the app would.
async fn person_note(state: &AppState, title: &str, body: &str) -> String {
    let mut vault = state.vault.lock().await;
    notes::create_note(
        &mut vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: None,
        },
    )
    .unwrap()
    .id
    .to_string()
}

// ---------- AC 19 ----------

#[tokio::test]
async fn create_daily_with_empty_content_creates_the_daily_note() {
    let (_dir, state, memex) = fresh();
    let v = create(
        &memex,
        json!({ "content_md": "", "title": "2026-09-05", "role": "daily", "agent_id": "a1" }),
    )
    .await;
    let id = v["note_id"]
        .as_str()
        .unwrap_or_else(|| panic!("create_note failed: {v}"))
        .to_string();
    assert_eq!(v["version"], 1);

    let s = stored(&state, &id).await;
    assert_eq!(s.title, "2026-09-05");
    assert_eq!(s.content_md, "<!-- memex:topics -->\n");
    assert_eq!(s.frontmatter["role"], "daily");
    assert_eq!(s.frontmatter["source"], "agent");
    assert_eq!(s.frontmatter["agent_id"], "a1");
    assert_eq!(s.version, 1);
    assert_eq!(content_version(&state, &id).await, Some(0));

    // Whitespace-only content is empty after trim.
    let id2 = create_ok(
        &memex,
        json!({ "content_md": "  \n\t\n", "title": "2026-09-06", "role": "daily" }),
    )
    .await;
    let s2 = stored(&state, &id2).await;
    assert_eq!(s2.title, "2026-09-06");
    assert_eq!(s2.frontmatter["role"], "daily");
    assert!(
        s2.content_md.ends_with("<!-- memex:topics -->\n"),
        "{:?}",
        s2.content_md
    );
    assert_eq!(content_version(&state, &id2).await, Some(0));
}

#[tokio::test]
async fn create_daily_with_non_empty_content_returns_marker_rule_and_creates_nothing() {
    let (_dir, state, memex) = fresh();
    for content in [
        "Fixed the jump arc.",
        "  x  ",
        "<!-- memex:topics -->\n[[X~about]]\n",
    ] {
        let v = create(
            &memex,
            json!({ "content_md": content, "title": "2026-09-05", "role": "daily" }),
        )
        .await;
        assert_eq!(v["error"]["code"], "marker_rule", "{content:?}: {v}");
        assert!(v["error"]["message"].is_string(), "{v}");
        assert!(v.get("note_id").is_none(), "{v}");
    }
    assert_eq!(note_count(&state).await, 0);

    // A non-daily create with the same content is unaffected.
    create_ok(
        &memex,
        json!({ "content_md": "Fixed the jump arc.", "title": "Jump", "role": "topic" }),
    )
    .await;
    assert_eq!(note_count(&state).await, 1);
}

#[tokio::test]
async fn create_daily_without_a_title_creates_todays_daily_note() {
    let (_dir, state, memex) = fresh();
    let before = daily::today_with_clock(&SystemClock).to_string();
    let id = create_ok(&memex, json!({ "content_md": "", "role": "daily" })).await;
    let after = daily::today_with_clock(&SystemClock).to_string();

    let s = stored(&state, &id).await;
    assert!(
        s.title == before || s.title == after,
        "title {:?} is not today ({before}/{after})",
        s.title
    );
    assert_eq!(s.content_md, "<!-- memex:topics -->\n");
    assert_eq!(s.frontmatter["role"], "daily");
}

#[tokio::test]
async fn create_daily_with_a_non_iso_title_returns_invalid_date() {
    let (_dir, state, memex) = fresh();
    for bad in ["Groceries", "2026-02-30", "2026-9-5"] {
        let v = create(
            &memex,
            json!({ "content_md": "", "title": bad, "role": "daily" }),
        )
        .await;
        assert_eq!(v["error"]["code"], "invalid_date", "{bad}: {v}");
    }
    assert_eq!(note_count(&state).await, 0);
}

#[tokio::test]
async fn create_daily_over_a_role_less_note_returns_title_conflict_with_existing_id() {
    let (_dir, state, memex) = fresh();
    let old = person_note(&state, "2026-09-05", "old\n").await;

    let v = create(
        &memex,
        json!({ "content_md": "", "title": "2026-09-05", "role": "daily" }),
    )
    .await;
    let want = MemexError::TitleConflict {
        existing_id: old.clone(),
        attempted_title: "2026-09-05".into(),
    }
    .to_error_json();
    assert_eq!(v, want);
    assert_eq!(v["error"]["code"], "title_conflict");
    assert_eq!(v["error"]["existing_id"], old.as_str());

    // The agent never adopts: the role-less note is unchanged.
    let s = stored(&state, &old).await;
    assert_eq!(s.content_md, "old\n");
    assert_eq!(s.frontmatter.get("role"), None);
    assert_eq!(s.version, 1);
    assert_eq!(content_version(&state, &old).await, None);
    assert_eq!(note_count(&state).await, 1);
}

#[tokio::test]
async fn create_daily_for_a_date_with_a_daily_note_returns_daily_note_exists() {
    let (_dir, state, memex) = fresh();
    let first = create_ok(
        &memex,
        json!({ "content_md": "", "title": "2026-09-05", "role": "daily" }),
    )
    .await;

    let v = create(
        &memex,
        json!({ "content_md": "", "title": "2026-09-05", "role": "daily" }),
    )
    .await;
    let want = MemexError::DailyNoteExists {
        date: "2026-09-05".into(),
        existing_id: first.clone(),
    }
    .to_error_json();
    assert_eq!(v, want);
    assert_eq!(note_count(&state).await, 1);
}
