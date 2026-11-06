//! WI #254 (Spec #233 US 10, R39-R41): the Feedback and block filing MCP tools,
//! over the wire: `list_open_feedback`, `resolve_feedback`, `record_feedback`,
//! `get_day_filing`, `remove_excerpt_block`, and the listing of all seven tools
//! (the Vault Guide's two are in `guide_tools.rs`).
//!
//! Shapes are the Contract in #256. The person's side is written through core
//! before the server's first call; row counts are read with raw SQL, so a listing
//! bug can't hide a recording bug. Dates of Activity rows with no Feedback date
//! are proved over `/mcp` with `X-Memex-UTC-Offset` at a date boundary.

#[path = "support/server.rs"]
mod server;

#[path = "support/feedback_mcp.rs"]
mod feedback_mcp;

#[path = "support/tool_names.rs"]
mod tool_names;

use std::collections::BTreeSet;
use std::path::Path;

use memex_core::excerpts::{add_excerpt, remove_excerpt_block};
use memex_core::feedback;
use memex_core::notes::NoteId;
use memex_core::{Caller, Vault};
use regex::Regex;
use rusqlite::params;
use serde_json::{json, Value};

use feedback_mcp::{
    activity, assert_c1, comment, count, fixture_day, keys, open_db, person_note, person_topic,
    reviewed, set, str_of, tag_correction, vault_with, FixedClock, Hosted, Stdio, B7, B7_TEXT,
    BOUNDARY_MS, BOUNDARY_UTC_DATE, BOUNDARY_WEST_DATE, C3, C3_TEXT, DAY, F6, F6_TEXT,
    FEEDBACK_KEYS, T0, TOPIC, UNKNOWN_ID, UTC, WEST,
};

const FEEDBACK_NAMES: [&str; 7] = [
    "get_day_filing",
    "get_vault_guide",
    "list_open_feedback",
    "record_feedback",
    "remove_excerpt_block",
    "resolve_feedback",
    "update_vault_guide",
];

/// Files `blocks` of [`DAY`] into `topic` as the agent (no Correction).
fn agent_files(vault: &mut Vault, topic: &str, blocks: &[&str]) {
    let blocks: Vec<String> = blocks.iter().map(|b| b.to_string()).collect();
    add_excerpt(
        vault,
        &NoteId::parse(topic).unwrap(),
        DAY,
        &blocks,
        Caller::Agent,
        None,
    )
    .unwrap_or_else(|e| panic!("agent files {blocks:?}: {e}"));
}

/// A reviewed day with a topic note and an Activity entry to comment on.
struct World {
    day: String,
    topic: String,
    change: String,
}

fn reviewed_world(vault: &mut Vault) -> World {
    let day = fixture_day(vault);
    let topic = person_topic(vault, TOPIC);
    agent_files(vault, &topic, &[B7]);
    let change = reviewed(vault, DAY, &day);
    World { day, topic, change }
}

fn open_ids(server: &mut Stdio) -> Vec<String> {
    let listed = server.call("list_open_feedback", json!({}));
    listed["feedback"]
        .as_array()
        .unwrap_or_else(|| panic!("a feedback array: {listed}"))
        .iter()
        .map(|f| str_of(f, "id").to_string())
        .collect()
}

fn feedback_count(path: &str) -> i64 {
    count(Path::new(path), "SELECT count(*) FROM feedback")
}

/// `(status, reply)` of a stored row.
fn row_state(path: &str, id: &str) -> (String, Option<String>) {
    open_db(Path::new(path))
        .query_row(
            "SELECT status, reply FROM feedback WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or_else(|e| panic!("feedback row {id}: {e}"))
}

fn change_rows(path: &str) -> i64 {
    count(Path::new(path), "SELECT count(*) FROM agent_changes")
}

// ======================================================================
// AC: tools/list holds all of them with the exact names, and tool_names.rs
// has them.
// ======================================================================

fn listed_tools() -> Vec<Value> {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Stdio::start(&path);
    server.tools()
}

fn find<'a>(tools: &'a [Value], name: &str) -> &'a Value {
    tools
        .iter()
        .find(|t| t["name"] == json!(name))
        .unwrap_or_else(|| panic!("tools/list has no `{name}`"))
}

#[test]
fn tools_list_holds_every_feedback_tool_with_its_exact_name() {
    let tools = listed_tools();
    let served: BTreeSet<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    for name in FEEDBACK_NAMES {
        assert!(served.contains(name), "tools/list must hold `{name}`");
    }
    assert_eq!(
        tool_names::FEEDBACK_TOOLS,
        FEEDBACK_NAMES,
        "the feedback block of support/tool_names.rs, sorted by name"
    );
}

#[test]
fn feedback_tools_take_exactly_their_contract_params() {
    let tools = listed_tools();
    let cases: [(&str, &[&str], &[&str]); 7] = [
        ("get_vault_guide", &[], &[]),
        (
            "update_vault_guide",
            &["version", "content_md", "bullets"],
            &["version", "content_md", "bullets"],
        ),
        ("list_open_feedback", &[], &[]),
        (
            "resolve_feedback",
            &["id", "reply", "changes"],
            &["id", "reply"],
        ),
        (
            "record_feedback",
            &["text", "note_id", "date", "reply", "changes"],
            &["text", "reply"],
        ),
        ("get_day_filing", &["date"], &["date"]),
        (
            "remove_excerpt_block",
            &["topic_note_id", "date", "block_id"],
            &["topic_note_id", "date", "block_id"],
        ),
    ];
    for (name, properties, required) in cases {
        let schema = &find(&tools, name)["inputSchema"];
        let got: BTreeSet<String> = schema
            .get("properties")
            .and_then(Value::as_object)
            .map(|p| p.keys().cloned().collect())
            .unwrap_or_default();
        assert_eq!(got, set(properties), "{name} params: {schema}");
        let got: BTreeSet<String> = schema
            .get("required")
            .and_then(Value::as_array)
            .map(|r| r.iter().map(|v| v.as_str().unwrap().to_string()).collect())
            .unwrap_or_default();
        assert_eq!(got, set(required), "{name} required params: {schema}");
    }
}

#[test]
fn feedback_tool_descriptions_use_glossary_terms_and_name_their_error_codes() {
    let tools = listed_tools();
    let avoid = Regex::new(r"(?i)\b(inbox|organi[sz]\w*|journal|day page|snippet)\b").unwrap();
    let required: [(&str, &[&str]); 7] = [
        ("get_vault_guide", &["Vault Guide"]),
        (
            "update_vault_guide",
            &[
                "Vault Guide",
                "version_conflict",
                "change_entries_invalid",
                "about 200 lines",
            ],
        ),
        ("list_open_feedback", &["Feedback", "Correction"]),
        (
            "resolve_feedback",
            &[
                "Feedback",
                "not_found",
                "deleted",
                "feedback_handled",
                "feedback_invalid",
                "change_entries_invalid",
            ],
        ),
        (
            "record_feedback",
            &["Feedback", "feedback_invalid", "invalid_date", "not_found"],
        ),
        ("get_day_filing", &["not_found", "invalid_date"]),
        (
            "remove_excerpt_block",
            &[
                "Note footer",
                "role_rule",
                "not_found",
                "block_not_found",
                "invalid_date",
                "invalid_id",
            ],
        ),
    ];
    for (name, terms) in required {
        let description = str_of(find(&tools, name), "description");
        for term in terms {
            assert!(
                description.contains(term),
                "`{name}`'s description must say `{term}`: {description}"
            );
        }
        assert!(
            !avoid.is_match(description),
            "`{name}`'s description uses an _Avoid_ term: {description}"
        );
    }
}

// ======================================================================
// AC: list_open_feedback returns Open comments and Corrections oldest first,
// including tag-<n> rows.
// ======================================================================

#[test]
fn list_open_feedback_returns_open_comments_and_corrections_oldest_first_with_tag_rows() {
    let mut w = None;
    let (mut newest, mut oldest, mut tag) = (String::new(), String::new(), String::new());
    let (_dir, path) = vault_with(|v| {
        let world = reviewed_world(v);
        // Written out of order: the list sorts by when each was made.
        newest = comment(v, &world.day, DAY, &world.change, "Newest.", T0 + 4000);
        tag = tag_correction(v, &world.topic, TOPIC, "game-feel", T0 + 3000, None);
        remove_excerpt_block(
            v,
            &NoteId::parse(&world.topic).unwrap(),
            DAY,
            B7,
            Caller::Person,
            None,
        )
        .unwrap();
        let moved = v
            .connection_ref()
            .execute(
                "UPDATE feedback SET created_at = ? WHERE kind = 'correction'",
                params![T0 + 2000],
            )
            .unwrap();
        assert_eq!(moved, 1, "the person's removal records one Correction");
        oldest = comment(v, &world.day, DAY, &world.change, "Oldest.", T0 + 1000);
        w = Some(world);
    });
    let w = w.unwrap();
    let mut server = Stdio::start(&path);

    let listed = server.call("list_open_feedback", json!({}));
    assert_eq!(keys(&listed), set(&["feedback"]), "{listed}");
    let rows = listed["feedback"].as_array().unwrap();
    for row in rows {
        assert_eq!(keys(row), set(&FEEDBACK_KEYS), "the Contract shape: {row}");
    }
    assert_eq!(rows.len(), 4, "{listed}");

    assert_eq!(
        rows[0],
        json!({
            "id": oldest,
            "kind": "comment",
            "source": "person",
            "note_id": w.day,
            "day": DAY,
            "agent_change_id": w.change,
            "text": "Oldest.",
            "correction": null,
            "status": "open",
            "reply": null,
            "created_at": T0 + 1000,
            "updated_at": T0 + 1000,
            "handled_at": null,
        })
    );

    let correction = &rows[1];
    assert_eq!(correction["kind"], json!("correction"), "{correction}");
    assert_eq!(correction["note_id"], json!(w.day), "{correction}");
    assert_eq!(correction["day"], json!(DAY), "{correction}");
    assert_eq!(correction["text"], Value::Null, "{correction}");
    assert_eq!(correction["status"], json!("open"), "{correction}");
    assert_eq!(correction["created_at"], json!(T0 + 2000), "{correction}");
    assert_eq!(
        correction["correction"],
        json!({
            "kind": "excerpt_removed",
            "date": DAY,
            "block_ids": [B7],
            "preview": B7_TEXT,
            "topic_note_id": w.topic,
            "title": TOPIC,
        }),
        "structured Correction detail: {correction}"
    );

    let tag_row = &rows[2];
    assert_eq!(tag_row["id"], json!(tag), "{tag_row}");
    assert_eq!(tag_row["kind"], json!("correction"), "{tag_row}");
    assert_eq!(tag_row["note_id"], json!(w.topic), "{tag_row}");
    assert_eq!(tag_row["day"], Value::Null, "{tag_row}");
    assert_eq!(tag_row["status"], json!("open"), "{tag_row}");
    assert_eq!(
        tag_row["correction"],
        json!({
            "kind": "tag_removed",
            "tag": "game-feel",
            "note_id": w.topic,
            "note_title": TOPIC,
        }),
        "{tag_row}"
    );

    assert_eq!(rows[3]["id"], json!(newest), "{listed}");
}

#[test]
fn list_open_feedback_leaves_out_handled_rows_and_lifted_tag_corrections() {
    let mut open = String::new();
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        open = comment(v, &w.day, DAY, &w.change, "Still open.", T0 + 1000);
        let handled = comment(v, &w.day, DAY, &w.change, "Handled.", T0 + 500);
        feedback::resolve(v, &handled, "Refiled it", &[], &FixedClock(T0 + 600)).unwrap();
        feedback::record_chat(v, "From chat.", None, None, "Noted", &[], &FixedClock(T0)).unwrap();
        tag_correction(v, &w.topic, TOPIC, "lifted", T0, Some(T0 + 1));
    });
    let mut server = Stdio::start(&path);
    assert_eq!(open_ids(&mut server), vec![open]);
}

#[test]
fn list_open_feedback_on_a_vault_with_none_is_an_empty_list() {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Stdio::start(&path);
    assert_eq!(
        server.call("list_open_feedback", json!({})),
        json!({ "feedback": [] })
    );
}

// ======================================================================
// AC: resolve_feedback returns the Handled row; already Handled, deleted and
// bad reply each have their code.
// ======================================================================

#[test]
fn resolve_feedback_returns_the_handled_row_and_it_leaves_the_open_list() {
    let mut w = None;
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let world = reviewed_world(v);
        id = comment(v, &world.day, DAY, &world.change, "Wrong topic.", T0 + 1000);
        w = Some(world);
    });
    let w = w.unwrap();
    let mut server = Stdio::start(&path);

    let handled = server.call(
        "resolve_feedback",
        json!({ "id": id, "reply": "Moved the block" }),
    );
    assert_eq!(
        keys(&handled),
        set(&FEEDBACK_KEYS),
        "a bare Feedback: {handled}"
    );
    assert_eq!(handled["id"], json!(id), "{handled}");
    assert_eq!(handled["kind"], json!("comment"), "{handled}");
    assert_eq!(handled["source"], json!("person"), "{handled}");
    assert_eq!(handled["note_id"], json!(w.day), "{handled}");
    assert_eq!(handled["day"], json!(DAY), "{handled}");
    assert_eq!(handled["agent_change_id"], json!(w.change), "{handled}");
    assert_eq!(handled["text"], json!("Wrong topic."), "{handled}");
    assert_eq!(handled["status"], json!("handled"), "{handled}");
    assert_eq!(handled["reply"], json!("Moved the block"), "{handled}");
    assert_eq!(handled["created_at"], json!(T0 + 1000), "{handled}");
    assert!(handled["handled_at"].is_i64(), "{handled}");

    assert_eq!(
        row_state(&path, &id),
        ("handled".to_string(), Some("Moved the block".to_string()))
    );
    assert_eq!(open_ids(&mut server), Vec::<String>::new());
}

#[test]
fn resolve_feedback_of_a_tag_row_returns_a_handled_row_holding_the_tag_correction() {
    let mut topic = String::new();
    let mut tag = String::new();
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        tag = tag_correction(v, &w.topic, TOPIC, "game-feel", T0 + 1000, None);
        topic = w.topic;
    });
    let mut server = Stdio::start(&path);
    assert_eq!(open_ids(&mut server), vec![tag.clone()]);

    let handled = server.call(
        "resolve_feedback",
        json!({ "id": tag, "reply": "Stopped using that tag" }),
    );
    assert_eq!(keys(&handled), set(&FEEDBACK_KEYS), "{handled}");
    assert!(
        !str_of(&handled, "id").starts_with("tag-"),
        "the Handled row has its own id: {handled}"
    );
    assert_eq!(handled["kind"], json!("correction"), "{handled}");
    assert_eq!(handled["status"], json!("handled"), "{handled}");
    assert_eq!(
        handled["reply"],
        json!("Stopped using that tag"),
        "{handled}"
    );
    assert_eq!(handled["note_id"], json!(topic), "{handled}");
    assert_eq!(
        handled["correction"],
        json!({
            "kind": "tag_removed",
            "tag": "game-feel",
            "note_id": topic,
            "note_title": TOPIC,
        }),
        "{handled}"
    );
    assert_eq!(open_ids(&mut server), Vec::<String>::new());
}

#[test]
fn resolve_feedback_on_an_already_handled_id_returns_feedback_handled() {
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        id = comment(v, &w.day, DAY, &w.change, "Wrong topic.", T0 + 1000);
    });
    let mut server = Stdio::start(&path);
    server.call("resolve_feedback", json!({ "id": id, "reply": "First" }));

    let again = server.call_raw("resolve_feedback", json!({ "id": id, "reply": "Second" }));
    assert_c1(&again, "feedback_handled", "resolving twice");
    assert_eq!(
        row_state(&path, &id),
        ("handled".to_string(), Some("First".to_string())),
        "the first reply stands"
    );
}

#[test]
fn resolve_feedback_on_a_deleted_id_returns_not_found() {
    let (mut deleted, mut lifted) = (String::new(), String::new());
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        deleted = comment(v, &w.day, DAY, &w.change, "Never mind.", T0 + 1000);
        feedback::delete(v, &deleted).unwrap();
        lifted = tag_correction(v, &w.topic, TOPIC, "lifted", T0, Some(T0 + 1));
    });
    let mut server = Stdio::start(&path);

    for (what, id) in [
        ("a comment the person deleted", deleted.as_str()),
        ("an id nothing has", UNKNOWN_ID),
        ("a tag Correction lifted first", lifted.as_str()),
    ] {
        let v = server.call_raw("resolve_feedback", json!({ "id": id, "reply": "Done" }));
        assert_c1(&v, "not_found", what);
    }
    assert_eq!(feedback_count(&path), 0, "nothing was recorded");
}

#[test]
fn resolve_feedback_with_a_bad_reply_returns_feedback_invalid_and_the_row_stays_open() {
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        id = comment(v, &w.day, DAY, &w.change, "Wrong topic.", T0 + 1000);
    });
    let mut server = Stdio::start(&path);

    let too_long = "x".repeat(201);
    for (what, reply) in [
        ("an empty reply", ""),
        ("a blank reply", "   "),
        ("a two-line reply", "One\nTwo"),
        ("a reply over 200 characters", too_long.as_str()),
    ] {
        let v = server.call_raw("resolve_feedback", json!({ "id": id, "reply": reply }));
        assert_c1(&v, "feedback_invalid", what);
    }
    assert_eq!(row_state(&path, &id), ("open".to_string(), None));
    assert_eq!(open_ids(&mut server), vec![id]);
}

#[test]
fn resolve_feedback_with_invalid_changes_writes_nothing_and_the_row_stays_open() {
    let mut w = None;
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let world = reviewed_world(v);
        id = comment(v, &world.day, DAY, &world.change, "Wrong topic.", T0 + 1000);
        w = Some(world);
    });
    let w = w.unwrap();
    let before = change_rows(&path);
    let mut server = Stdio::start(&path);

    let v = server.call_raw(
        "resolve_feedback",
        json!({
            "id": id,
            "reply": "Moved it",
            "changes": [
                { "note_id": w.topic, "bullets": ["Fine"] },
                { "note_id": w.day, "bullets": [] },
            ],
        }),
    );
    assert_c1(&v, "change_entries_invalid", "an entry with no bullets");

    let v = server.call_raw(
        "resolve_feedback",
        json!({
            "id": id,
            "reply": "Moved it",
            "changes": [{ "note_id": UNKNOWN_ID, "bullets": ["Fine"] }],
        }),
    );
    assert_c1(&v, "not_found", "an entry naming no note");

    assert_eq!(row_state(&path, &id), ("open".to_string(), None));
    assert_eq!(change_rows(&path), before, "all or nothing");
}

// ======================================================================
// AC: resolve_feedback and record_feedback with changes write Activity rows
// visible through get_note and agent-changes.
// ======================================================================

#[tokio::test]
async fn resolve_feedback_with_changes_writes_activity_rows_visible_through_get_note_and_agent_changes(
) {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let mut w = None;
    let mut id = String::new();
    srv.vault("v", |v| {
        let world = reviewed_world(v);
        id = comment(v, &world.day, DAY, &world.change, "Wrong topic.", T0 + 1000);
        w = Some(world);
    });
    let w = w.unwrap();

    // The row's date wins over the caller's today, and a topic note needs no
    // daily-note entry beside it (R40).
    let handled = srv
        .call(
            "v",
            Some(WEST),
            "resolve_feedback",
            json!({
                "id": id,
                "reply": "Moved the block",
                "changes": [
                    { "note_id": w.day, "bullets": ["Refiled the jump arc"] },
                    { "note_id": w.topic, "bullets": ["Took out a block", "Fixed a heading"] },
                ],
            }),
        )
        .await;
    assert_eq!(handled["handled_at"], json!(BOUNDARY_MS), "{handled}");

    let note = srv
        .call("v", None, "get_note", json!({ "note_id": w.day }))
        .await;
    assert_eq!(
        note["latest_change"],
        json!({
            "day": DAY,
            "created_at": BOUNDARY_MS,
            "bullets": ["Refiled the jump arc"],
        }),
        "{note}"
    );

    let hosted = srv.agent_changes("v", &w.topic).await;
    assert_eq!(hosted.len(), 1, "one row per entry: {hosted:?}");
    assert_eq!(hosted[0]["note_id"], json!(w.topic), "{hosted:?}");
    assert_eq!(hosted[0]["day"], json!(DAY), "{hosted:?}");
    assert_eq!(
        hosted[0]["bullets"],
        json!(["Took out a block", "Fixed a heading"]),
        "{hosted:?}"
    );
}

#[tokio::test]
async fn record_feedback_with_changes_writes_activity_rows_visible_through_get_note_and_agent_changes(
) {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let mut w = None;
    srv.vault("v", |v| {
        w = Some(reviewed_world(v));
    });
    let w = w.unwrap();

    let recorded = srv
        .call(
            "v",
            Some(WEST),
            "record_feedback",
            json!({
                "text": "Sleep doesn't go in Player Loop.",
                "note_id": w.day,
                "date": DAY,
                "reply": "Refiled it",
                "changes": [
                    { "note_id": w.day, "bullets": ["Refiled a block"] },
                    { "note_id": w.topic, "bullets": ["Took out a block"] },
                ],
            }),
        )
        .await;
    assert_eq!(recorded["day"], json!(DAY), "{recorded}");
    assert_eq!(recorded["created_at"], json!(BOUNDARY_MS), "{recorded}");
    assert_eq!(recorded["handled_at"], json!(BOUNDARY_MS), "{recorded}");

    let note = srv
        .call("v", None, "get_note", json!({ "note_id": w.day }))
        .await;
    assert_eq!(
        note["latest_change"],
        json!({
            "day": DAY,
            "created_at": BOUNDARY_MS,
            "bullets": ["Refiled a block"],
        }),
        "{note}"
    );

    let hosted = srv.agent_changes("v", &w.topic).await;
    assert_eq!(hosted.len(), 1, "{hosted:?}");
    assert_eq!(hosted[0]["day"], json!(DAY), "{hosted:?}");
    assert_eq!(
        hosted[0]["bullets"],
        json!(["Took out a block"]),
        "{hosted:?}"
    );
}

#[tokio::test]
async fn resolve_feedback_on_a_row_with_no_day_dates_changes_today_in_the_callers_time_zone() {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let mut w = None;
    let (mut first, mut second) = (String::new(), String::new());
    let path = srv.vault("v", |v| {
        let world = reviewed_world(v);
        first = tag_correction(v, &world.topic, TOPIC, "first", T0, None);
        second = tag_correction(v, &world.topic, TOPIC, "second", T0, None);
        w = Some(world);
    });
    let topic = w.unwrap().topic;

    for (offset, id, bullet) in [(WEST, &first, "West"), (UTC, &second, "Utc")] {
        srv.call(
            "v",
            Some(offset),
            "resolve_feedback",
            json!({
                "id": id,
                "reply": "Dropped the tag",
                "changes": [{ "note_id": topic, "bullets": [bullet] }],
            }),
        )
        .await;
    }

    assert_eq!(
        activity(&path, &topic),
        vec![
            (BOUNDARY_WEST_DATE.to_string(), BOUNDARY_MS, json!(["West"])),
            (BOUNDARY_UTC_DATE.to_string(), BOUNDARY_MS, json!(["Utc"])),
        ],
        "each entry is dated in that call's offset, on the call's clock"
    );
}

#[tokio::test]
async fn record_feedback_with_no_date_dates_changes_today_in_the_callers_time_zone() {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let mut topic = String::new();
    let path = srv.vault("v", |v| {
        topic = person_topic(v, TOPIC);
    });

    for (offset, bullet) in [(WEST, "West"), (UTC, "Utc")] {
        let recorded = srv
            .call(
                "v",
                Some(offset),
                "record_feedback",
                json!({
                    "text": "Keep topics broad.",
                    "reply": "Noted in the Vault Guide",
                    "changes": [{ "note_id": topic, "bullets": [bullet] }],
                }),
            )
            .await;
        assert_eq!(
            recorded["day"],
            Value::Null,
            "the row has no date of its own: {recorded}"
        );
    }

    assert_eq!(
        activity(&path, &topic),
        vec![
            (BOUNDARY_WEST_DATE.to_string(), BOUNDARY_MS, json!(["West"])),
            (BOUNDARY_UTC_DATE.to_string(), BOUNDARY_MS, json!(["Utc"])),
        ]
    );
}

#[test]
fn resolve_and_record_feedback_without_changes_write_no_activity_rows() {
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        id = comment(v, &w.day, DAY, &w.change, "Wrong topic.", T0 + 1000);
    });
    let before = change_rows(&path);
    let mut server = Stdio::start(&path);

    server.call("resolve_feedback", json!({ "id": id, "reply": "Done" }));
    server.call(
        "record_feedback",
        json!({ "text": "Keep topics broad.", "reply": "Noted" }),
    );
    server.call(
        "record_feedback",
        json!({ "text": "Keep them short.", "reply": "Noted", "changes": [] }),
    );
    assert_eq!(change_rows(&path), before);
}

// ======================================================================
// AC: record_feedback stores the text verbatim, Handled, source: chat.
// ======================================================================

#[test]
fn record_feedback_stores_the_text_verbatim_handled_with_source_chat() {
    let mut w = None;
    let (_dir, path) = vault_with(|v| {
        w = Some(reviewed_world(v));
    });
    let w = w.unwrap();
    let mut server = Stdio::start(&path);

    let text = "  Don't *ever* file sleep here.\n\n- it's 日本語 too  \n";
    let recorded = server.call(
        "record_feedback",
        json!({ "text": text, "note_id": w.day, "date": DAY, "reply": "Refiled the sleep block" }),
    );
    assert_eq!(
        keys(&recorded),
        set(&FEEDBACK_KEYS),
        "a bare Feedback: {recorded}"
    );
    assert_eq!(recorded["kind"], json!("comment"), "{recorded}");
    assert_eq!(recorded["source"], json!("chat"), "{recorded}");
    assert_eq!(recorded["status"], json!("handled"), "{recorded}");
    assert_eq!(recorded["text"], json!(text), "verbatim: {recorded}");
    assert_eq!(recorded["note_id"], json!(w.day), "{recorded}");
    assert_eq!(recorded["day"], json!(DAY), "{recorded}");
    assert_eq!(recorded["agent_change_id"], Value::Null, "{recorded}");
    assert_eq!(recorded["correction"], Value::Null, "{recorded}");
    assert_eq!(
        recorded["reply"],
        json!("Refiled the sleep block"),
        "{recorded}"
    );
    assert!(recorded["handled_at"].is_i64(), "{recorded}");

    let stored: String = open_db(Path::new(&path))
        .query_row(
            "SELECT text FROM feedback WHERE id = ?",
            [str_of(&recorded, "id")],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stored, text, "verbatim on disk");
    assert_eq!(
        open_ids(&mut server),
        Vec::<String>::new(),
        "stored Handled, so the agent never has to act on it"
    );

    // A chat comment naming no note.
    let bare = server.call(
        "record_feedback",
        json!({ "text": "Keep topics broad.", "reply": "Noted" }),
    );
    assert_eq!(bare["note_id"], Value::Null, "{bare}");
    assert_eq!(bare["day"], Value::Null, "{bare}");
    assert_eq!(bare["source"], json!("chat"), "{bare}");
    assert_eq!(bare["status"], json!("handled"), "{bare}");
}

#[test]
fn record_feedback_with_bad_input_returns_its_code_and_stores_nothing() {
    let mut day = String::new();
    let (_dir, path) = vault_with(|v| {
        day = fixture_day(v);
    });
    let mut server = Stdio::start(&path);

    let too_long = "x".repeat(2001);
    let cases = [
        (
            "feedback_invalid",
            json!({ "text": "", "reply": "Noted" }),
            "empty text",
        ),
        (
            "feedback_invalid",
            json!({ "text": "  \n ", "reply": "Noted" }),
            "blank text",
        ),
        (
            "feedback_invalid",
            json!({ "text": too_long, "reply": "Noted" }),
            "text over 2,000 characters",
        ),
        (
            "feedback_invalid",
            json!({ "text": "Fine.", "reply": "" }),
            "an empty reply",
        ),
        (
            "invalid_date",
            json!({ "text": "Fine.", "date": "2026-13-45", "reply": "Noted" }),
            "a date that isn't one",
        ),
        (
            "not_found",
            json!({ "text": "Fine.", "note_id": UNKNOWN_ID, "reply": "Noted" }),
            "a note that doesn't exist",
        ),
        (
            "change_entries_invalid",
            json!({
                "text": "Fine.",
                "reply": "Noted",
                "changes": [{ "note_id": day, "bullets": ["- marked"] }],
            }),
            "an invalid change entry",
        ),
    ];
    for (code, args, what) in cases {
        let v = server.call_raw("record_feedback", args);
        assert_c1(&v, code, what);
    }
    assert_eq!(feedback_count(&path), 0);
    assert_eq!(change_rows(&path), 0);
}

// ======================================================================
// AC: get_day_filing returns the Contract shape; an unknown date is not_found.
// ======================================================================

#[test]
fn get_day_filing_returns_the_contract_shape() {
    let (mut day, mut first, mut second, mut vault_id) =
        (String::new(), String::new(), String::new(), String::new());
    let (_dir, path) = vault_with(|v| {
        vault_id = v.vault_id().to_string();
        day = fixture_day(v);
        first = person_topic(v, TOPIC);
        second = person_topic(v, "Level Design");
        agent_files(v, &first, &[B7]);
        agent_files(v, &second, &[C3]);
        reviewed(v, DAY, &day);
    });
    let mut server = Stdio::start(&path);

    assert_eq!(
        server.call("get_day_filing", json!({ "date": DAY })),
        json!({
            "vault_id": vault_id,
            "date": DAY,
            "note_id": day,
            "reviewed": true,
            "topics": [
                {
                    "topic_note_id": second,
                    "title": "Level Design",
                    "blocks": [{ "id": C3, "text": C3_TEXT }],
                },
                {
                    "topic_note_id": first,
                    "title": TOPIC,
                    "blocks": [{ "id": B7, "text": B7_TEXT }],
                },
            ],
            "not_filed": [{ "id": F6, "text": F6_TEXT }],
        })
    );
}

#[test]
fn get_day_filing_of_a_day_never_reviewed_is_not_reviewed_with_empty_lists() {
    let (mut day, mut vault_id) = (String::new(), String::new());
    let (_dir, path) = vault_with(|v| {
        vault_id = v.vault_id().to_string();
        day = fixture_day(v);
    });
    let mut server = Stdio::start(&path);
    assert_eq!(
        server.call("get_day_filing", json!({ "date": DAY })),
        json!({
            "vault_id": vault_id,
            "date": DAY,
            "note_id": day,
            "reviewed": false,
            "topics": [],
            "not_filed": [],
        })
    );
}

#[test]
fn get_day_filing_on_an_unknown_date_returns_not_found() {
    let (_dir, path) = vault_with(|v| {
        fixture_day(v);
    });
    let mut server = Stdio::start(&path);
    let v = server.call_raw("get_day_filing", json!({ "date": "2026-09-06" }));
    assert_c1(&v, "not_found", "a date with no daily note");
}

#[test]
fn get_day_filing_on_a_malformed_date_returns_invalid_date() {
    let (_dir, path) = vault_with(|v| {
        fixture_day(v);
    });
    let mut server = Stdio::start(&path);
    let v = server.call_raw("get_day_filing", json!({ "date": "2026-13-45" }));
    assert_c1(&v, "invalid_date", "a date that isn't one");
}

// ======================================================================
// AC: remove_excerpt_block splits a joined excerpt; remove_excerpt on the same
// range still needs exact endpoints.
// ======================================================================

/// A reviewed day whose three blocks are one joined excerpt of the topic note.
/// Returns `(day, topic, vault_id)`.
fn joined_excerpt(vault: &mut Vault) -> (String, String, String) {
    let day = fixture_day(vault);
    let topic = person_topic(vault, TOPIC);
    agent_files(vault, &topic, &[B7, C3, F6]);
    reviewed(vault, DAY, &day);
    (day, topic, vault.vault_id().to_string())
}

fn transclusion_ends(note: &Value) -> Vec<(String, Option<String>)> {
    note["transclusions"]
        .as_array()
        .unwrap_or_else(|| panic!("transclusions: {note}"))
        .iter()
        .map(|t| {
            (
                str_of(t, "from").to_string(),
                t["to"].as_str().map(str::to_string),
            )
        })
        .collect()
}

#[test]
fn remove_excerpt_block_splits_a_joined_excerpt() {
    let mut world = None;
    let (_dir, path) = vault_with(|v| {
        world = Some(joined_excerpt(v));
    });
    let (_day, topic, vault_id) = world.unwrap();
    let mut server = Stdio::start(&path);

    let before = server.call("get_note", json!({ "note_id": topic }));
    assert_eq!(
        transclusion_ends(&before),
        vec![(B7.to_string(), Some(F6.to_string()))],
        "one joined excerpt: {before}"
    );

    let removed = server.call(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": C3 }),
    );
    let after = server.call("get_note", json!({ "note_id": topic }));
    assert_eq!(
        removed,
        json!({
            "vault_id": vault_id,
            "topic_note_id": topic,
            "version": after["version"],
        }),
        "exactly vault_id, topic_note_id and the topic's new version"
    );
    assert!(
        after["version"].as_i64() > before["version"].as_i64(),
        "{after}"
    );
    assert_eq!(
        transclusion_ends(&after),
        vec![(B7.to_string(), None), (F6.to_string(), None)],
        "the range splits around the block: {after}"
    );

    let filing = server.call("get_day_filing", json!({ "date": DAY }));
    assert_eq!(
        filing["topics"][0]["blocks"],
        json!([{ "id": B7, "text": B7_TEXT }, { "id": F6, "text": F6_TEXT }]),
        "{filing}"
    );
    assert_eq!(
        filing["not_filed"],
        json!([{ "id": C3, "text": C3_TEXT }]),
        "{filing}"
    );
}

#[test]
fn remove_excerpt_refuses_a_range_that_remove_excerpt_block_splits() {
    let mut world = None;
    let (_dir, path) = vault_with(|v| {
        world = Some(joined_excerpt(v));
    });
    let (_day, topic, _vault_id) = world.unwrap();
    let mut server = Stdio::start(&path);
    let before = server.call("get_note", json!({ "note_id": topic }));

    for (what, block_ids) in [
        ("a block inside the range", json!([C3])),
        ("the range's first block alone", json!([B7])),
        ("part of the range", json!([B7, C3])),
    ] {
        let v = server.call_raw(
            "remove_excerpt",
            json!({ "topic_note_id": topic, "date": DAY, "block_ids": block_ids }),
        );
        assert_c1(&v, "not_found", what);
    }
    assert_eq!(
        server.call("get_note", json!({ "note_id": topic }))["version"],
        before["version"],
        "remove_excerpt wrote nothing"
    );

    // The same block out of the same range is what remove_excerpt_block is for.
    let split = server.call(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": C3 }),
    );
    assert_eq!(split["topic_note_id"], json!(topic), "{split}");

    // Exact endpoints still work, on what the split left.
    let exact = server.call(
        "remove_excerpt",
        json!({ "topic_note_id": topic, "date": DAY, "block_ids": [F6] }),
    );
    assert_eq!(exact["topic_note_id"], json!(topic), "{exact}");
    let after = server.call("get_note", json!({ "note_id": topic }));
    assert_eq!(
        transclusion_ends(&after),
        vec![(B7.to_string(), None)],
        "{after}"
    );
}

#[test]
fn remove_excerpt_block_failures_are_their_c1_codes_and_write_nothing() {
    let (mut day, mut topic, mut plain) = (String::new(), String::new(), String::new());
    let (_dir, path) = vault_with(|v| {
        day = fixture_day(v);
        topic = person_topic(v, TOPIC);
        plain = person_note(v, "Plain", "A note.\n", json!({}))
            .id
            .to_string();
        agent_files(v, &topic, &[B7]);
        reviewed(v, DAY, &day);
    });
    let mut server = Stdio::start(&path);
    let before = server.call("get_note", json!({ "note_id": topic }));

    let cases = [
        ("invalid_id", "not-a-ulid", DAY, B7, "a malformed topic id"),
        ("not_found", UNKNOWN_ID, DAY, B7, "an unknown topic"),
        (
            "invalid_date",
            topic.as_str(),
            "2026-13-45",
            B7,
            "a bad date",
        ),
        (
            "not_found",
            topic.as_str(),
            "2026-09-07",
            B7,
            "a day with no note",
        ),
        (
            "block_not_found",
            topic.as_str(),
            DAY,
            "zzzzzz",
            "no such block",
        ),
        (
            "not_found",
            topic.as_str(),
            DAY,
            F6,
            "a block no token covers",
        ),
        (
            "role_rule",
            day.as_str(),
            DAY,
            B7,
            "a daily note as the target",
        ),
        (
            "role_rule",
            plain.as_str(),
            DAY,
            B7,
            "a note with no role as the target",
        ),
    ];
    for (code, target, date, block, what) in cases {
        let v = server.call_raw(
            "remove_excerpt_block",
            json!({ "topic_note_id": target, "date": date, "block_id": block }),
        );
        assert_c1(&v, code, what);
    }
    assert_eq!(
        server.call("get_note", json!({ "note_id": topic }))["version"],
        before["version"]
    );
    assert_eq!(feedback_count(&path), 0);
}

// ======================================================================
// AC: no tool call records a Correction.
// ======================================================================

#[test]
fn remove_excerpt_block_over_mcp_leaves_zero_correction_rows() {
    let mut world = None;
    let (_dir, path) = vault_with(|v| {
        world = Some(joined_excerpt(v));
    });
    let (_day, topic, _vault_id) = world.unwrap();
    let mut server = Stdio::start(&path);

    // As `Caller::Person`, this same call records one `excerpt_removed`.
    let removed = server.call(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": C3 }),
    );
    assert_eq!(removed["topic_note_id"], json!(topic), "{removed}");
    assert_eq!(feedback_count(&path), 0);
}

#[test]
fn no_feedback_or_excerpt_tool_records_a_correction() {
    let mut world = None;
    let mut open = String::new();
    let (_dir, path) = vault_with(|v| {
        let (day, topic, vault_id) = joined_excerpt(v);
        let change: String = v
            .connection_ref()
            .query_row(
                "SELECT id FROM agent_changes WHERE note_id = ?",
                [&day],
                |r| r.get(0),
            )
            .unwrap();
        open = comment(v, &day, DAY, &change, "Wrong topic.", T0 + 1000);
        world = Some((day, topic, vault_id));
    });
    let (day, topic, _vault_id) = world.unwrap();
    let mut server = Stdio::start(&path);

    let guide = server.call("get_vault_guide", json!({}));
    server.call(
        "update_vault_guide",
        json!({ "version": guide["version"], "content_md": "text", "bullets": ["Wrote it"] }),
    );
    server.call("list_open_feedback", json!({}));
    server.call("get_day_filing", json!({ "date": DAY }));
    server.call(
        "resolve_feedback",
        json!({
            "id": open,
            "reply": "Moved it",
            "changes": [{ "note_id": day, "bullets": ["Moved a block"] }],
        }),
    );
    server.call(
        "record_feedback",
        json!({ "text": "Keep topics broad.", "note_id": day, "date": DAY, "reply": "Noted" }),
    );
    server.call(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": C3 }),
    );
    server.call(
        "remove_excerpt",
        json!({ "topic_note_id": topic, "date": DAY, "block_ids": [B7] }),
    );
    server.call(
        "add_excerpt",
        json!({ "topic_note_id": topic, "date": DAY, "block_ids": [C3] }),
    );

    assert_eq!(
        count(
            Path::new(&path),
            "SELECT count(*) FROM feedback WHERE kind = 'correction'"
        ),
        0
    );
}

#[test]
fn remove_excerpt_block_adds_nothing_beside_the_persons_correction() {
    // The Correction a person's removal recorded is the one row the agent sees;
    // the agent's own removal of another block adds none beside it.
    let mut world = None;
    let (_dir, path) = vault_with(|v| {
        let (day, topic, vault_id) = joined_excerpt(v);
        remove_excerpt_block(
            v,
            &NoteId::parse(&topic).unwrap(),
            DAY,
            B7,
            Caller::Person,
            None,
        )
        .unwrap();
        world = Some((day, topic, vault_id));
    });
    let (_day, topic, _vault_id) = world.unwrap();
    let mut server = Stdio::start(&path);

    server.call(
        "remove_excerpt_block",
        json!({ "topic_note_id": topic, "date": DAY, "block_id": F6 }),
    );
    let listed = server.call("list_open_feedback", json!({}));
    let rows = listed["feedback"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{listed}");
    assert_eq!(rows[0]["source"], json!("person"), "{listed}");
    assert_eq!(rows[0]["correction"]["block_ids"], json!([B7]), "{listed}");
    assert_eq!(feedback_count(&path), 1);
}

// ======================================================================
// Verify-mode pins for contracts the tool descriptions promise.
// ======================================================================

/// `(topic_note_id, origin)` of a daily note's footer chips, oldest first.
fn v254_chips(path: &str, day: &str) -> Vec<(String, String)> {
    let db = open_db(Path::new(path));
    let mut stmt = db
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap();
    let rows = stmt
        .query_map([day], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    rows
}

#[test]
fn remove_excerpt_block_takes_the_date_heading_and_the_excerpt_chip_but_keeps_a_person_chip() {
    // The description promises both: "The `## <date>` heading goes when nothing
    // else is under it, and the topic's chip ... once no excerpt of the day
    // remains (a chip the user added stays)."
    for person_chip in [false, true] {
        let mut world = None;
        let (_dir, path) = vault_with(|v| {
            let day = fixture_day(v);
            let topic = person_topic(v, TOPIC);
            agent_files(v, &topic, &[B7]);
            if person_chip {
                memex_core::footer::set_chip(
                    v,
                    &NoteId::parse(&day).unwrap(),
                    &NoteId::parse(&topic).unwrap(),
                    memex_core::footer::ChipOrigin::Person,
                    None,
                )
                .unwrap();
            }
            world = Some((day, topic));
        });
        let (day, topic) = world.unwrap();
        let mut server = Stdio::start(&path);

        let before = server.call("get_note", json!({ "note_id": topic }));
        let heading = format!("## {DAY}");
        assert!(
            str_of(&before, "content_md").contains(&heading),
            "the day's excerpt sits under its heading: {before}"
        );
        let chips_before = v254_chips(&path, &day);
        assert_eq!(
            chips_before.len(),
            1,
            "one chip for the topic: {chips_before:?}"
        );

        let removed = server.call(
            "remove_excerpt_block",
            json!({ "topic_note_id": topic, "date": DAY, "block_id": B7 }),
        );
        assert_eq!(removed["topic_note_id"], json!(topic), "{removed}");

        let after = server.call("get_note", json!({ "note_id": topic }));
        let content = str_of(&after, "content_md");
        assert!(
            !content.contains(&heading) && !content.contains(B7),
            "the heading and the token went with the last block: {after}"
        );
        let chips_after = v254_chips(&path, &day);
        if person_chip {
            assert_eq!(
                chips_after,
                vec![(topic.clone(), "person".to_string())],
                "a chip the person added stays"
            );
        } else {
            assert_eq!(
                chips_after,
                vec![],
                "the excerpt chip went with the last block"
            );
        }
    }
}

#[test]
fn resolve_feedback_not_found_says_which_thing_is_missing() {
    // The description: a not_found for the Feedback means the person deleted
    // it; for a `changes` entry it names a note. "The message says which."
    let (mut id, mut gone) = (String::new(), String::new());
    let (_dir, path) = vault_with(|v| {
        let w = reviewed_world(v);
        id = comment(v, &w.day, DAY, &w.change, "Wrong topic.", T0 + 1000);
        gone = comment(v, &w.day, DAY, &w.change, "Never mind.", T0 + 2000);
        feedback::delete(v, &gone).unwrap();
    });
    let mut server = Stdio::start(&path);

    let missing_feedback =
        server.call_raw("resolve_feedback", json!({ "id": gone, "reply": "Done" }));
    assert_c1(&missing_feedback, "not_found", "a deleted Feedback");
    let message = str_of(&missing_feedback["error"], "message").to_string();
    assert!(
        message.contains("Feedback") && message.contains(&gone),
        "names the Feedback: {message}"
    );

    let missing_note = server.call_raw(
        "resolve_feedback",
        json!({
            "id": id,
            "reply": "Done",
            "changes": [{ "note_id": UNKNOWN_ID, "bullets": ["Fine"] }],
        }),
    );
    assert_c1(&missing_note, "not_found", "a change naming no note");
    let message = str_of(&missing_note["error"], "message").to_string();
    assert!(
        message.contains(UNKNOWN_ID) && !message.contains(&format!("Feedback {id}")),
        "names the note, not the Feedback: {message}"
    );
}
