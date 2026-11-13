//! WI #8 (Spec #7 Req 9, ruling D2): the five V8 error codes at the two
//! edges of memex-mcp.
//!
//! - The vault server (`server::error::status_for_code`, and every
//!   `ApiError` built from a `MemexError`): `read_only_rule`, `excerpt_rule`,
//!   `edit_not_found` and `edit_ambiguous` are 422, `edit_invalid` is 400,
//!   and the C1 body keeps the code, the message and the `index` field.
//! - The MCP tools: a core `ReadOnlyRule` from an agent save is answered with
//!   its C1 object (`err_from`'s rule list), shown end to end with `add_link`
//!   from an Agent read-only note. The list itself is pinned for all four
//!   rule codes by the test module at the end of `src/tools.rs`.
//!
//! Nothing in WI #8 sets the flag: the MCP test sets it with raw SQL.

use std::sync::Arc;

use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::notes::{self, CreateNote};
use memex_core::{Caller, Vault};
use memex_mcp::server::error::{status_for_code, ApiError};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

/// `err` answered by the vault server: its status and C1 body.
async fn answer(err: ApiError) -> (u16, Value) {
    let resp = axum::response::IntoResponse::into_response(err);
    let status = resp.status().as_u16();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let body = serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("ApiError body is JSON ({e}): {bytes:?}"));
    (status, body)
}

// ---------- the vault server ----------

#[test]
fn v8_rule_codes_map_to_422_and_edit_invalid_to_400() {
    for (code, status) in [
        ("read_only_rule", 422),
        ("excerpt_rule", 422),
        ("edit_not_found", 422),
        ("edit_ambiguous", 422),
        ("edit_invalid", 400),
        // Codes match exactly.
        ("Read_Only_Rule", 500),
        ("read_only_rule ", 500),
        ("edit_invalid_x", 500),
    ] {
        assert_eq!(status_for_code(code).as_u16(), status, "code {code:?}");
    }
    // Every code the run kept keeps its status.
    for (code, status) in [
        ("marker_rule", 422),
        ("guide_rule", 422),
        ("role_rule", 422),
        ("change_entries_invalid", 422),
        ("invalid_argument", 400),
        ("version_conflict", 409),
        ("not_found", 404),
        ("internal", 500),
    ] {
        assert_eq!(status_for_code(code).as_u16(), status, "code {code:?}");
    }
}

#[tokio::test]
async fn v8_memex_errors_are_answered_with_their_status_code_message_and_index() {
    // Built from run-time values: the body follows the error.
    let n = std::hint::black_box(4usize);
    let title = format!("Pricing notes {n}");
    let read_only =
        format!("\"{title}\" is read-only for agents; the person can change this in the app");
    let cases: Vec<(MemexError, u16, Value)> = vec![
        (MemexError::ReadOnlyRule(read_only.clone()), 422, json!({})),
        (
            MemexError::ExcerptRule(format!("the edit drops {n} transclusions")),
            422,
            json!({}),
        ),
        (
            MemexError::EditNotFound {
                index: n,
                message: format!("edit {n}: old_text is not in the note"),
            },
            422,
            json!({"index": 4}),
        ),
        (
            MemexError::EditAmbiguous {
                index: n + 1,
                message: format!("edit {}: old_text appears twice", n + 1),
            },
            422,
            json!({"index": 5}),
        ),
        (
            MemexError::EditInvalid("give edits or content_md, not both".into()),
            400,
            json!({}),
        ),
    ];
    for (e, status, extras) in cases {
        let code = e.code();
        let mut expected = serde_json::Map::new();
        expected.insert("code".into(), json!(code));
        expected.insert("message".into(), json!(e.to_string()));
        for (k, v) in extras.as_object().unwrap() {
            expected.insert(k.clone(), v.clone());
        }
        let (got_status, got_body) = answer(e.into()).await;
        assert_eq!(
            (got_status, &got_body),
            (status, &json!({ "error": expected })),
            "{code}"
        );
    }
    assert_ne!(
        MemexError::ReadOnlyRule(read_only.clone()).code(),
        "internal",
        "read_only_rule is a C1 code"
    );
    let (_, body) = answer(MemexError::ReadOnlyRule(read_only.clone()).into()).await;
    assert_eq!(body["error"]["message"], json!(read_only), "{body}");

    // Under `.context(…)` the rule keeps its code and status.
    let wrapped = anyhow::Error::new(MemexError::ReadOnlyRule(read_only.clone()))
        .context("set the note's body");
    let (status, body) = answer(wrapped.into()).await;
    assert_eq!(status, 422, "{body}");
    assert_eq!(body["error"]["code"], json!("read_only_rule"), "{body}");
}

// ---------- the MCP tools ----------

struct Fixture {
    _dir: TempDir,
    state: Arc<AppState>,
    memex: Memex,
}

fn fresh() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    Fixture {
        _dir: dir,
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
async fn person_note(state: &AppState, title: &str, body: &str) -> String {
    let mut vault = state.vault.lock().await;
    let note = notes::create_note_as(
        &mut vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: None,
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

/// (version, content_md, updated_at, agent_read_only) of a note.
async fn stored(state: &AppState, id: &str) -> (i64, String, i64, i64) {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT version, content_md, updated_at, agent_read_only FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .unwrap()
}

/// Flags a note with raw SQL. On a build without schema V8 (the gate's
/// red-on-main run) the column is added first, so the test fails on the
/// guard and the rule list, not on the schema. A no-op at V8.
async fn set_flag(state: &AppState, id: &str) {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let has: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('notes') WHERE name = 'agent_read_only'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    if has == 0 {
        conn.execute_batch(
            "ALTER TABLE notes ADD COLUMN agent_read_only INTEGER NOT NULL DEFAULT 0;",
        )
        .unwrap();
    }
    let n = conn
        .execute("UPDATE notes SET agent_read_only = 1 WHERE id = ?", [id])
        .unwrap();
    assert_eq!(n, 1);
}

#[tokio::test]
async fn add_link_from_an_agent_read_only_note_returns_the_read_only_rule_c1_object() {
    let f = fresh();
    let topic = person_note(&f.state, "Player Loop", "Topic body.\n").await;
    let source = person_note(&f.state, "Pricing notes", "Tiers.\n").await;
    set_flag(&f.state, &source).await;
    let before = stored(&f.state, &source).await;

    // A new link saves the source through update_note_as(Agent).
    let v = parse(
        &f.memex
            .add_link(params(json!({ "from_id": source, "to_id": topic })))
            .await,
    );
    assert_eq!(
        v,
        json!({"error": {
            "code": "read_only_rule",
            "message": "\"Pricing notes\" is read-only for agents; the person can change this in the app"
        }}),
        "the C1 rule object, not the add_link.update op code"
    );
    assert_eq!(stored(&f.state, &source).await, before, "nothing written");

    // From a note that is not read-only, the same call links.
    let other = person_note(&f.state, "Roadmap", "Q1.\n").await;
    let v = parse(
        &f.memex
            .add_link(params(json!({ "from_id": other, "to_id": topic })))
            .await,
    );
    assert!(v.get("error").is_none(), "{v}");
    assert_eq!(v["was_existing"], json!(false), "{v}");
}
