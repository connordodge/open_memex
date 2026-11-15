//! WI #11 (Spec #7 Req 11, 18, 30; ruling D12): the `edit_note` MCP tool, a
//! thin wrapper over `memex_core::note_edits::edit_note`.
//!
//! - Parameters: `note_id`, `bullets`, `edits` (`[{old_text, new_text}]`) or
//!   `content_md`, and an optional `expected_version`.
//! - A success answers `{vault_id, note_id, version, content_md, changed}`:
//!   the new version and the stored body (Note footer included).
//! - Every failure is the C1 object (`to_error_json`), never an `op.sub`
//!   code, with the engine's code and, for `edit_not_found` and
//!   `edit_ambiguous`, the failing edit's `index`. A failure writes nothing.
//! - The Activity entry is dated the caller's day on the call's clock
//!   (`call_clock`), and a successful edit adds no tag and changes no review
//!   state.
//! - It works over stdio (`memex serve`) and the vault server's MCP HTTP.
//!
//! Every engine rule is R2's (#10) and pinned in memex-core; these tests show
//! each one reaches the agent through the tool. Notes are flagged Agent
//! read-only with raw SQL (ruling D15). The person's side is written through
//! core before the server's first call; the tool is driven over the wire
//! only. Invented note text throughout.

#[path = "support/server.rs"]
mod server;

#[path = "support/feedback_mcp.rs"]
mod feedback_mcp;

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Arc;

use memex_core::daily::{today_with_clock, TOPICS_MARKER};
use memex_core::footer::{self, ChipOrigin};
use memex_core::guide;
use memex_core::{SystemClock, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::model::CallToolRequestParams;
use rmcp::service::RunningService;
use rmcp::{RoleClient, ServiceExt};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::task::JoinHandle;

use feedback_mcp::{
    activity, assert_c1, count, fixture_day, keys, open_db, person_note, reviewed, set, str_of,
    vault_with, FixedClock, Hosted, Stdio, BOUNDARY_MS, BOUNDARY_UTC_DATE, BOUNDARY_WEST_DATE, DAY,
    T0, UNKNOWN_ID, UTC, WEST,
};

const TOOL: &str = "edit_note";
const STATUS_TITLE: &str = "Project Status";
const STATUS_BODY: &str = "Status: draft.\n\nOwner: Sam.\n";
const BULLET: &str = "Marked the project shipped";
const TOKEN: &str = "![[2026-09-01#^b1]]";
/// Every key of a successful result (Req 18 plus `vault_id` and `changed`).
const RESULT_KEYS: [&str; 5] = ["vault_id", "note_id", "version", "content_md", "changed"];

// ======================================================================
// Harness: a vault served in process over an rmcp duplex.
// ======================================================================

struct World {
    _dir: TempDir,
    path: String,
    state: Arc<AppState>,
    client: RunningService<RoleClient, ()>,
    server: JoinHandle<()>,
}

impl Drop for World {
    fn drop(&mut self) {
        self.server.abort();
    }
}

/// A temp vault seeded by `setup` (closed), then served over a duplex.
async fn world(setup: impl FnOnce(&mut Vault)) -> World {
    let (dir, path) = vault_with(setup);
    let vault = Vault::open(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path.clone().into(), None));
    let memex = Memex::new(state.clone());
    let (server_io, client_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(async move {
        let running = memex.serve(server_io).await.expect("serve over duplex");
        let _ = running.waiting().await;
    });
    let client = ().serve(client_io).await.expect("client over duplex");
    World {
        _dir: dir,
        path,
        state,
        client,
        server,
    }
}

impl World {
    /// Calls `tool` through the rmcp client; its JSON payload, errors included.
    async fn call(&self, tool: &str, args: Value) -> Value {
        let Value::Object(arguments) = args else {
            panic!("tool arguments are an object");
        };
        let result = self
            .client
            .call_tool(CallToolRequestParams::new(tool.to_string()).with_arguments(arguments))
            .await
            .unwrap_or_else(|e| panic!("call {tool}: {e}"));
        let result = serde_json::to_value(result).expect("serialize CallToolResult");
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{tool}: a text content: {result}"));
        serde_json::from_str(text).unwrap_or_else(|e| panic!("{tool}: not JSON ({e}): {text}"))
    }

    /// [`Self::call`], asserting the call succeeded.
    async fn ok(&self, tool: &str, args: Value) -> Value {
        let v = self.call(tool, args).await;
        assert!(v.get("error").is_none(), "{tool} failed: {v}");
        v
    }

    async fn vault_id(&self) -> String {
        self.state.vault.lock().await.vault_id().to_string()
    }

    fn db(&self) -> rusqlite::Connection {
        open_db(Path::new(&self.path))
    }

    /// `edit_note` with Form A pairs `(old_text, new_text)`.
    async fn form_a(&self, id: &str, pairs: &[(&str, &str)], expected: Option<i64>) -> Value {
        let edits: Vec<Value> = pairs
            .iter()
            .map(|(old, new)| json!({ "old_text": old, "new_text": new }))
            .collect();
        let mut args = json!({ "note_id": id, "bullets": [BULLET], "edits": edits });
        if let Some(v) = expected {
            args["expected_version"] = json!(v);
        }
        self.call(TOOL, args).await
    }

    /// `edit_note` with Form B `content_md`.
    async fn form_b(&self, id: &str, content_md: &str, expected: Option<i64>) -> Value {
        let mut args = json!({ "note_id": id, "bullets": [BULLET], "content_md": content_md });
        if let Some(v) = expected {
            args["expected_version"] = json!(v);
        }
        self.call(TOOL, args).await
    }
}

/// The stored row of a note: `(title, content_md, frontmatter, version)`.
fn stored(conn: &rusqlite::Connection, id: &str) -> (String, String, String, i64) {
    conn.query_row(
        "SELECT title, content_md, frontmatter, version FROM notes WHERE id = ?",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    )
    .unwrap_or_else(|e| panic!("note {id}: {e}"))
}

/// How many rows of `table` belong to note `id` (by its `note_id` column).
fn rows_of(conn: &rusqlite::Connection, table: &str, id: &str) -> i64 {
    conn.query_row(
        &format!("SELECT count(*) FROM {table} WHERE note_id = ?"),
        [id],
        |r| r.get(0),
    )
    .unwrap()
}

/// Flags the note Agent read-only the way R3's tests must (D15): raw SQL.
fn flag_read_only(vault: &Vault, id: &str) {
    let n = vault
        .connection_ref()
        .execute("UPDATE notes SET agent_read_only = 1 WHERE id = ?", [id])
        .unwrap();
    assert_eq!(n, 1, "the note exists");
}

/// The person's plain note [`STATUS_TITLE`]; its id.
fn status_note(vault: &mut Vault) -> String {
    person_note(vault, STATUS_TITLE, STATUS_BODY, json!({}))
        .id
        .to_string()
}

/// Asserts the failed call wrote nothing: the note's row as it was, and no
/// Activity entry or revision for it.
fn assert_unwritten(w: &World, id: &str, before: &(String, String, String, i64), what: &str) {
    let conn = w.db();
    assert_eq!(&stored(&conn, id), before, "{what}: the note is unchanged");
    assert_eq!(
        rows_of(&conn, "agent_changes", id),
        0,
        "{what}: no Activity entry"
    );
    assert_eq!(
        rows_of(&conn, "note_revisions", id),
        0,
        "{what}: no revision"
    );
}

/// A world with the plain status note; `(world, id, stored row)`.
async fn status_world() -> (World, String, (String, String, String, i64)) {
    let mut id = String::new();
    let w = world(|v| id = status_note(v)).await;
    let before = stored(&w.db(), &id);
    (w, id, before)
}

// ======================================================================
// AC 1: registered, with its parameters and its rules in the description.
// ======================================================================

#[tokio::test]
async fn edit_note_is_listed_with_its_parameters_and_its_rules_in_the_description() {
    let w = world(|_| {}).await;
    let tools = w.client.list_all_tools().await.expect("tools/list");
    let tool = tools
        .iter()
        .find(|t| t.name == TOOL)
        .unwrap_or_else(|| panic!("{TOOL} is listed"));

    let schema = Value::Object((*tool.input_schema).clone());
    let props: BTreeSet<String> = schema["properties"]
        .as_object()
        .unwrap_or_else(|| panic!("an input schema with properties: {schema}"))
        .keys()
        .cloned()
        .collect();
    assert_eq!(
        props,
        set(&[
            "note_id",
            "bullets",
            "edits",
            "content_md",
            "expected_version"
        ]),
        "{schema}"
    );
    let required: BTreeSet<String> = schema["required"]
        .as_array()
        .unwrap_or_else(|| panic!("required params: {schema}"))
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        required,
        set(&["note_id", "bullets"]),
        "edits, content_md and expected_version are optional: {schema}"
    );
    assert!(
        schema["properties"]["expected_version"]
            .to_string()
            .contains("integer"),
        "expected_version is an integer: {schema}"
    );

    let description = tool
        .description
        .as_deref()
        .unwrap_or_else(|| panic!("{TOOL} has a description"));
    // What the agent must know before it edits (Spec #7 Req 1, 5, 11-19).
    for needle in [
        "daily",
        "Vault Guide",
        "read_only_rule",
        "excerpt_rule",
        "![[",
        "add_excerpt",
        "remove_excerpt",
        "remove_excerpt_block",
        "footer",
        "title",
        "frontmatter",
        "edits",
        "old_text",
        "new_text",
        "exactly once",
        "content_md",
        "expected_version",
        "bullets",
        "1 to 3",
        "200",
        // Ruling D25: an unclosed code fence above the footer, and
        // overlapping occurrences.
        "leaves a code fence open above the footer is edit_invalid",
        "close the fence",
        "overlapping occurrences",
        "\"aa\" in \"aaa\" is edit_ambiguous",
    ] {
        assert!(
            description.contains(needle),
            "the description says `{needle}`: {description}"
        );
    }
}

// ======================================================================
// AC 2: Form A replaces the text and answers the result fields.
// ======================================================================

#[tokio::test]
async fn form_a_replaces_the_text_and_returns_the_result_with_changed_true() {
    let (w, id, before) = status_world().await;
    let (title, _, frontmatter, version) = before.clone();

    let v = w
        .form_a(&id, &[("draft", "shipped"), ("Sam", "Alex")], None)
        .await;

    assert_eq!(
        keys(&v),
        set(&RESULT_KEYS),
        "exactly the result fields: {v}"
    );
    let (now_title, content, now_fm, now_version) = stored(&w.db(), &id);
    assert_eq!(
        content, "Status: shipped.\n\nOwner: Alex.\n",
        "both pairs applied"
    );
    assert_eq!(
        v,
        json!({
            "vault_id": w.vault_id().await,
            "note_id": id,
            "version": version + 1,
            "content_md": content,
            "changed": true,
        })
    );
    assert_eq!(now_version, version + 1);
    assert_eq!(now_title, title, "the title is never changed");
    assert_eq!(now_fm, frontmatter, "the frontmatter is never changed");
    let conn = w.db();
    assert_eq!(
        rows_of(&conn, "agent_changes", &id),
        1,
        "one Activity entry"
    );
    assert_eq!(rows_of(&conn, "note_revisions", &id), 1, "one revision");
}

#[tokio::test]
async fn form_a_with_the_current_expected_version_applies() {
    let (w, id, before) = status_world().await;
    let version = before.3;

    let v = w
        .form_a(&id, &[("draft", "in review")], Some(version))
        .await;

    assert_eq!(v["changed"], json!(true), "{v}");
    assert_eq!(v["version"], json!(version + 1), "{v}");
    assert_eq!(
        stored(&w.db(), &id).1,
        "Status: in review.\n\nOwner: Sam.\n"
    );
}

// ======================================================================
// AC 3: Form B with the current expected_version replaces the person
// section; the answer is the stored body, footer included.
// ======================================================================

#[tokio::test]
async fn form_b_with_the_current_expected_version_replaces_the_person_section() {
    let mut id = String::new();
    let w = world(|v| {
        let topic = person_note(v, "Pricing", "Pricing topic.\n", json!({"role": "topic"}));
        let plan = person_note(v, "Launch Plan", "Plan text.\nSecond line.\n", json!({}));
        footer::set_chip(v, &plan.id, &topic.id, ChipOrigin::Person, None).unwrap();
        id = plan.id.to_string();
    })
    .await;
    let (title, body, frontmatter, version) = stored(&w.db(), &id);
    let footer = &body[body.find(TOPICS_MARKER).expect("the fixture has a footer")..];
    assert!(footer.contains("[[Pricing~about]]"), "fixture: {body:?}");

    let v = w
        .form_b(&id, "Rewritten plan.\n\nNew second part.\n", Some(version))
        .await;

    assert_eq!(keys(&v), set(&RESULT_KEYS), "the same result fields: {v}");
    let (now_title, content, now_fm, now_version) = stored(&w.db(), &id);
    assert_eq!(
        content,
        format!("Rewritten plan.\n\nNew second part.\n{footer}"),
        "the person section is replaced and the footer kept"
    );
    assert_eq!(
        v,
        json!({
            "vault_id": w.vault_id().await,
            "note_id": id,
            "version": version + 1,
            "content_md": content,
            "changed": true,
        }),
        "content_md is the stored body, footer included"
    );
    assert_eq!(now_version, version + 1);
    assert_eq!(now_title, title);
    assert_eq!(now_fm, frontmatter);
}

// ======================================================================
// AC 4: each engine error reaches the agent as the C1 object with its code.
// ======================================================================

#[tokio::test]
async fn edit_note_with_a_bad_input_shape_answers_edit_invalid_and_writes_nothing() {
    let (w, id, before) = status_world().await;
    let version = before.3;
    let cases = [
        (
            "both edits and content_md",
            json!({
                "note_id": id,
                "bullets": [BULLET],
                "edits": [{ "old_text": "draft", "new_text": "shipped" }],
                "content_md": "Whole new text.\n",
                "expected_version": version,
            }),
        ),
        (
            "neither edits nor content_md",
            json!({ "note_id": id, "bullets": [BULLET], "expected_version": version }),
        ),
        (
            "an empty edits list",
            json!({ "note_id": id, "bullets": [BULLET], "edits": [] }),
        ),
        (
            "an empty old_text",
            json!({
                "note_id": id,
                "bullets": [BULLET],
                "edits": [{ "old_text": "", "new_text": "x" }],
            }),
        ),
        (
            "Form B without expected_version",
            json!({ "note_id": id, "bullets": [BULLET], "content_md": "Whole new text.\n" }),
        ),
    ];
    for (what, args) in cases {
        let v = w.call(TOOL, args).await;
        assert_c1(&v, "edit_invalid", what);
        assert_unwritten(&w, &id, &before, what);
    }
}

#[tokio::test]
async fn edit_note_whose_old_text_has_no_match_answers_edit_not_found_with_its_index() {
    let (w, id, before) = status_world().await;

    let v = w
        .form_a(
            &id,
            &[("draft", "shipped"), ("Owner: Kim", "Owner: Alex")],
            None,
        )
        .await;

    assert_eq!(v["error"]["code"], json!("edit_not_found"), "{v}");
    assert_eq!(v["error"]["index"], json!(1), "the second edit fails: {v}");
    assert!(
        v["error"]["message"]
            .as_str()
            .is_some_and(|m| !m.is_empty()),
        "{v}"
    );
    assert_eq!(
        keys(&v),
        set(&["error"]),
        "the C1 object, nothing else: {v}"
    );
    assert_unwritten(&w, &id, &before, "edit_not_found");
}

#[tokio::test]
async fn edit_note_whose_old_text_matches_twice_answers_edit_ambiguous_with_its_index() {
    let mut id = String::new();
    let w = world(|v| {
        id = person_note(
            v,
            "Reading List",
            "Next: a novel.\nLater: a novel.\nDone: nothing yet.\n",
            json!({}),
        )
        .id
        .to_string();
    })
    .await;
    let before = stored(&w.db(), &id);

    let v = w
        .form_a(
            &id,
            &[
                ("Next:", "Now:"),
                ("Done:", "Finished:"),
                ("a novel", "a poem"),
            ],
            None,
        )
        .await;

    assert_eq!(v["error"]["code"], json!("edit_ambiguous"), "{v}");
    assert_eq!(v["error"]["index"], json!(2), "the third edit fails: {v}");
    assert!(
        v["error"]["message"]
            .as_str()
            .is_some_and(|m| !m.is_empty()),
        "{v}"
    );
    assert_eq!(keys(&v), set(&["error"]), "{v}");
    assert_unwritten(&w, &id, &before, "edit_ambiguous");
}

#[tokio::test]
async fn edit_note_that_drops_a_transclusion_token_answers_excerpt_rule() {
    let mut id = String::new();
    let w = world(|v| {
        id = person_note(
            v,
            "Jump Arc",
            &format!("About jumps.\n\n{TOKEN}\n\nMore later.\n"),
            json!({"role": "topic"}),
        )
        .id
        .to_string();
    })
    .await;
    let before = stored(&w.db(), &id);

    let a = w.form_a(&id, &[(TOKEN, "")], None).await;
    assert_c1(&a, "excerpt_rule", "Form A dropping the token");
    let b = w.form_b(&id, "About jumps.\n", Some(before.3)).await;
    assert_c1(&b, "excerpt_rule", "Form B without the token");
    assert_unwritten(&w, &id, &before, "excerpt_rule");
}

#[tokio::test]
async fn edit_note_on_an_agent_read_only_note_answers_read_only_rule() {
    let mut id = String::new();
    let w = world(|v| {
        id = status_note(v);
        flag_read_only(v, &id);
    })
    .await;
    let before = stored(&w.db(), &id);

    let a = w.form_a(&id, &[("draft", "shipped")], None).await;
    assert_c1(&a, "read_only_rule", "Form A");
    assert_eq!(
        a["error"]["message"],
        json!(format!(
            "\"{STATUS_TITLE}\" is read-only for agents; the person can change this in the app"
        )),
        "{a}"
    );
    // A stale version never hides the rule (Req 10).
    let b = w.form_b(&id, "Whole new text.\n", Some(before.3 + 5)).await;
    assert_c1(&b, "read_only_rule", "Form B with a stale version");
    assert_unwritten(&w, &id, &before, "read_only_rule");
}

#[tokio::test]
async fn edit_note_on_a_daily_note_answers_marker_rule() {
    let mut id = String::new();
    let w = world(|v| id = fixture_day(v)).await;
    let before = stored(&w.db(), &id);

    let v = w
        .form_a(&id, &[("Sleep was bad.", "Sleep was fine.")], None)
        .await;

    assert_c1(&v, "marker_rule", "a daily note");
    assert_unwritten(&w, &id, &before, "marker_rule");
}

#[tokio::test]
async fn edit_note_on_the_vault_guide_answers_guide_rule() {
    let mut id = String::new();
    let w = world(|v| {
        id = guide::get_or_create(v, &FixedClock(T0), None)
            .unwrap()
            .note_id;
    })
    .await;
    let before = stored(&w.db(), &id);

    let a = w
        .form_a(&id, &[("## Framework", "## Framework, revised")], None)
        .await;
    assert_c1(&a, "guide_rule", "Form A on the guide");
    let b = w.form_b(&id, "## Framework\n", Some(before.3)).await;
    assert_c1(&b, "guide_rule", "Form B on the guide");
    let conn = w.db();
    assert_eq!(stored(&conn, &id), before, "the guide is unchanged");
    assert_eq!(rows_of(&conn, "note_revisions", &id), 0);
    assert_eq!(
        count(
            Path::new(&w.path),
            "SELECT count(*) FROM vault_guide_revisions"
        ),
        0
    );
}

#[tokio::test]
async fn edit_note_with_a_stale_expected_version_answers_version_conflict() {
    let (w, id, before) = status_world().await;
    let version = before.3;
    let stale = version + 3;

    let a = w.form_a(&id, &[("draft", "shipped")], Some(stale)).await;
    assert_c1(&a, "version_conflict", "Form A with a stale version");
    assert_eq!(a["error"]["expected"], json!(stale), "{a}");
    assert_eq!(a["error"]["current"], json!(version), "{a}");

    let b = w.form_b(&id, "Whole new text.\n", Some(stale)).await;
    assert_c1(&b, "version_conflict", "Form B with a stale version");
    assert_eq!(b["error"]["expected"], json!(stale), "{b}");
    assert_eq!(b["error"]["current"], json!(version), "{b}");
    assert_unwritten(&w, &id, &before, "version_conflict");
}

#[tokio::test]
async fn edit_note_with_invalid_bullets_answers_change_entries_invalid() {
    let (w, id, before) = status_world().await;
    let long = "x".repeat(201);
    for (what, bullets) in [
        ("no bullet", json!([])),
        ("four bullets", json!(["One", "Two", "Three", "Four"])),
        ("a bullet over 200 characters", json!([long])),
    ] {
        let v = w
            .call(
                TOOL,
                json!({
                    "note_id": id,
                    "bullets": bullets,
                    "edits": [{ "old_text": "draft", "new_text": "shipped" }],
                }),
            )
            .await;
        assert_c1(&v, "change_entries_invalid", what);
        assert_unwritten(&w, &id, &before, what);
    }
}

#[tokio::test]
async fn edit_note_on_an_unknown_note_answers_not_found() {
    let w = world(|_| {}).await;
    let notes_before = count(Path::new(&w.path), "SELECT count(*) FROM notes");

    let v = w.form_a(UNKNOWN_ID, &[("draft", "shipped")], None).await;

    assert_c1(&v, "not_found", "an unknown note");
    assert_eq!(
        count(Path::new(&w.path), "SELECT count(*) FROM notes"),
        notes_before
    );
    assert_eq!(
        count(Path::new(&w.path), "SELECT count(*) FROM agent_changes"),
        0
    );
}

#[tokio::test]
async fn edit_note_with_a_malformed_note_id_answers_invalid_id() {
    let w = world(|_| {}).await;

    let v = w
        .form_a("not-a-note-id", &[("draft", "shipped")], None)
        .await;

    assert_c1(&v, "invalid_id", "a malformed note id");
    assert_eq!(
        count(Path::new(&w.path), "SELECT count(*) FROM agent_changes"),
        0
    );
}

// ======================================================================
// AC 6: a no-op answers changed false and writes nothing.
// ======================================================================

#[tokio::test]
async fn a_no_op_edit_returns_changed_false_and_writes_nothing() {
    let (w, id, before) = status_world().await;
    let (_, content, _, version) = before.clone();

    let a = w.form_a(&id, &[("draft", "draft")], None).await;
    assert_eq!(
        a,
        json!({
            "vault_id": w.vault_id().await,
            "note_id": id,
            "version": version,
            "content_md": content,
            "changed": false,
        }),
        "Form A replacing a text with itself returns the note unchanged"
    );
    let b = w.form_b(&id, STATUS_BODY, Some(version)).await;
    assert_eq!(b["changed"], json!(false), "Form B with the same text: {b}");
    assert_eq!(b["version"], json!(version), "{b}");
    assert_unwritten(&w, &id, &before, "a no-op");
}

// ======================================================================
// AC 7: no tag added, no review state changed.
// ======================================================================

/// Every `tags` row as `(note_id, tag, origin)`, and every `day_reviews` and
/// `day_review_blocks` row, as text.
fn tags_and_reviews(conn: &rusqlite::Connection) -> (Vec<(String, String, String)>, Vec<String>) {
    let mut stmt = conn
        .prepare("SELECT note_id, tag, origin FROM tags ORDER BY note_id, tag")
        .unwrap();
    let tags = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    let mut reviews = Vec::new();
    for sql in [
        "SELECT note_id || '|' || content_version || '|' || ifnull(reviewed_content_version, '-')
             || '|' || ifnull(reviewed_at, '-') FROM day_reviews ORDER BY note_id",
        "SELECT note_id || '|' || block_id || '|' || content_hash FROM day_review_blocks
             ORDER BY note_id, block_id",
    ] {
        let mut stmt = conn.prepare(sql).unwrap();
        reviews.extend(
            stmt.query_map([], |r| r.get::<_, String>(0))
                .unwrap()
                .map(Result::unwrap),
        );
    }
    (tags, reviews)
}

#[tokio::test]
async fn a_successful_edit_adds_no_tag_and_changes_no_review_state() {
    let mut person = String::new();
    let w = world(|v| {
        let day = fixture_day(v);
        reviewed(v, DAY, &day);
        person = person_note(v, "Work Log", "Status: draft. #work\n", json!({}))
            .id
            .to_string();
    })
    .await;
    // An agent-created note carries `inbox` and `agent-authored`.
    let agent = str_of(
        &w.ok(
            "create_note",
            json!({ "title": "Agent Draft", "content_md": "First take.\n" }),
        )
        .await,
        "note_id",
    )
    .to_string();
    let (tags_before, reviews_before) = tags_and_reviews(&w.db());
    assert!(
        tags_before
            .iter()
            .any(|(n, t, _)| *n == agent && t == "inbox"),
        "fixture: the agent note is in the inbox: {tags_before:?}"
    );
    assert!(
        tags_before
            .iter()
            .any(|(n, t, _)| *n == person && t == "work"),
        "fixture: the person note has #work: {tags_before:?}"
    );
    assert!(!reviews_before.is_empty(), "fixture: a reviewed day");

    let p = w.form_a(&person, &[("draft", "shipped")], None).await;
    assert_eq!(p["changed"], json!(true), "{p}");
    let a = w
        .form_a(&agent, &[("First take.", "Second take.")], None)
        .await;
    assert_eq!(a["changed"], json!(true), "{a}");

    let (tags_after, reviews_after) = tags_and_reviews(&w.db());
    assert_eq!(
        tags_after, tags_before,
        "no tag added (no inbox, no agent-authored) and none removed"
    );
    assert_eq!(reviews_after, reviews_before, "no review state changed");
}

// ======================================================================
// AC 1 and Req 23: the vault server's MCP HTTP, on the call's clock and in
// the caller's time zone; and stdio `memex serve`.
// ======================================================================

#[tokio::test]
async fn edit_note_over_the_vault_servers_mcp_dates_its_entry_in_the_callers_time_zone() {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let mut id = String::new();
    let path = srv.vault("v", |v| id = status_note(v));

    let first = srv
        .call(
            "v",
            Some(WEST),
            TOOL,
            json!({
                "note_id": id,
                "bullets": ["From the west", "Second bullet"],
                "edits": [{ "old_text": "draft", "new_text": "shipped" }],
            }),
        )
        .await;
    assert_eq!(keys(&first), set(&RESULT_KEYS), "{first}");
    assert_eq!(first["changed"], json!(true), "{first}");
    let second = srv
        .call(
            "v",
            Some(UTC),
            TOOL,
            json!({
                "note_id": id,
                "bullets": ["From UTC"],
                "content_md": "Status: archived.\n",
                "expected_version": first["version"],
            }),
        )
        .await;
    assert_eq!(second["changed"], json!(true), "{second}");

    let rows = activity(&path, &id);
    assert_eq!(
        rows,
        vec![
            (
                BOUNDARY_WEST_DATE.to_string(),
                BOUNDARY_MS,
                json!(["From the west", "Second bullet"])
            ),
            (
                BOUNDARY_UTC_DATE.to_string(),
                BOUNDARY_MS,
                json!(["From UTC"])
            ),
        ],
        "each entry holds its bullets, dated in that call's offset on the call's clock"
    );
    let updated_at: i64 = open_db(&path)
        .query_row("SELECT updated_at FROM notes WHERE id = ?", [&id], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(updated_at, BOUNDARY_MS, "the write is on the call's clock");
    let (_, content, _, version) = stored(&open_db(&path), &id);
    assert_eq!(content, "Status: archived.\n");
    assert_eq!(second["version"], json!(version));
    assert_eq!(second["content_md"], json!(content));
}

#[tokio::test]
async fn edit_note_errors_over_the_vault_servers_mcp_are_c1_objects() {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let mut id = String::new();
    srv.vault("v", |v| id = status_note(v));

    let v = srv
        .call_raw(
            "v",
            None,
            TOOL,
            json!({
                "note_id": id,
                "bullets": [BULLET],
                "edits": [{ "old_text": "absent text", "new_text": "x" }],
            }),
        )
        .await;
    assert_eq!(v["error"]["code"], json!("edit_not_found"), "{v}");
    assert_eq!(v["error"]["index"], json!(0), "{v}");
}

#[test]
fn edit_note_over_stdio_memex_serve_edits_the_note() {
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| id = status_note(v));
    let mut server = Stdio::start(&path);
    assert!(
        server.tools().iter().any(|t| t["name"] == json!(TOOL)),
        "memex serve lists {TOOL}"
    );

    let before = today_with_clock(&SystemClock).to_string();
    let v = server.call(
        TOOL,
        json!({
            "note_id": id,
            "bullets": [BULLET],
            "edits": [{ "old_text": "Sam", "new_text": "Alex" }],
        }),
    );
    let after = today_with_clock(&SystemClock).to_string();

    assert_eq!(keys(&v), set(&RESULT_KEYS), "{v}");
    let (_, content, _, version) = stored(&open_db(Path::new(&path)), &id);
    assert_eq!(content, "Status: draft.\n\nOwner: Alex.\n");
    assert_eq!(v["note_id"], json!(id), "{v}");
    assert_eq!(v["version"], json!(version), "{v}");
    assert_eq!(v["content_md"], json!(content), "{v}");
    assert_eq!(v["changed"], json!(true), "{v}");
    let rows = activity(Path::new(&path), &id);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert!(
        rows[0].0 == before || rows[0].0 == after,
        "dated with the machine's date: {} is neither {before} nor {after}",
        rows[0].0
    );

    let err = server.call_raw(
        TOOL,
        json!({
            "note_id": id,
            "bullets": [BULLET],
            "content_md": "No version given.\n",
        }),
    );
    assert_c1(
        &err,
        "edit_invalid",
        "Form B without expected_version over stdio",
    );
}
