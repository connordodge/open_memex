//! WI #241 (T4a): the MCP tools for tags and footer topics (Spec #234 R38-R40,
//! D10, D16, D18, D21).
//!
//! - `list_tags`, `tag_note`, `untag_note` and `add_footer_topic` are thin over
//!   core; a rule failure is a C1 error object with the rule's code.
//! - `get_note` gains `agent_tags`, `tags` stays as it is.
//! - `create_note` stores its tags agent-origin, with footer text in the same
//!   call for every non-system tag, and never scans its body.
//!
//! The tools are called in process; person-side state goes through core with
//! `Caller::Person`, as the CLI and the app do. Params are built with
//! `serde_json::from_value(json!(…))`, never struct literals (D23). The tests
//! at the end drive the built binary over JSON-RPC. Temp vaults only.

#[path = "support/tool_names.rs"]
mod tool_names;

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use memex_core::canvas::SystemClock;
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::footer::{self, ChipOrigin};
use memex_core::guide;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, NoteId, RenameOptions, UpdateNote,
};
use memex_core::tags;
use memex_core::{Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use regex::Regex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params as sql_params;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

const MARKER: &str = "<!-- memex:topics -->";
const DAY: &str = "2026-09-05";
/// A well-formed ULID no note has.
const NO_SUCH_NOTE: &str = "01J9ZZZZZZZZZZZZZZZZZZZZZZ";

// ---------- setup ----------

fn fresh() -> (TempDir, Arc<AppState>, Memex) {
    fresh_with(None)
}

fn fresh_with(embedder: Option<Arc<dyn Embedder>>) -> (TempDir, Arc<AppState>, Memex) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, embedder));
    let memex = Memex::new(state.clone());
    (dir, state, memex)
}

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("tool returned non-JSON ({e}): {resp}"))
}

fn id_of(id: &str) -> NoteId {
    NoteId::parse(id).unwrap()
}

// ---------- the person's writes and the rows they leave (through core) ----------

fn person_note_in(vault: &mut Vault, title: &str, body: &str, frontmatter: Value) -> String {
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

async fn person_note(state: &AppState, title: &str, body: &str) -> String {
    let mut vault = state.vault.lock().await;
    person_note_in(&mut vault, title, body, json!({}))
}

async fn daily(state: &AppState, body: &str) -> String {
    let mut vault = state.vault.lock().await;
    person_note_in(&mut vault, DAY, body, json!({ "role": "daily" }))
}

async fn topic(state: &AppState, title: &str) -> String {
    let mut vault = state.vault.lock().await;
    person_note_in(&mut vault, title, "A topic.\n", json!({ "role": "topic" }))
}

/// The vault's real guide, built the only way D10 allows: `guide::get_or_create`
/// (`create_note_as` rejects `role: guide` for every caller), then
/// `guide::update` to a body of its own.
async fn guide(state: &AppState) -> String {
    let mut vault = state.vault.lock().await;
    let seeded = guide::get_or_create(&mut vault, &SystemClock, None).expect("create the guide");
    guide::update(
        &mut vault,
        seeded.version,
        "How to.\n",
        &["Set up the guide".to_string()],
        DAY,
        &SystemClock,
        None,
    )
    .expect("write the guide body")
    .note_id
}

/// A person's note that writes each name as `#name`, so each is vocabulary.
async fn vocabulary(state: &AppState, names: &[&str]) -> String {
    let body: Vec<String> = names.iter().map(|n| format!("#{n}")).collect();
    person_note(state, "Vocabulary", &format!("{}\n", body.join(" "))).await
}

/// Puts a row on a note the way only old data or a bug could, for the rules
/// that must hold whatever the rows say.
async fn seed_row(state: &AppState, id: &str, tag: &str, origin: &str) {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tags (note_id, tag, origin) VALUES (?, ?, ?)",
            sql_params![id, tag, origin],
        )
        .unwrap();
}

async fn core_agent_tag(state: &AppState, id: &str, tag: &str) {
    let mut vault = state.vault.lock().await;
    tags::agent_tag_note(&mut vault, &id_of(id), tag, None)
        .unwrap_or_else(|e| panic!("agent_tag_note {tag}: {e}"));
}

async fn core_person_tag(state: &AppState, id: &str, tag: &str) {
    let mut vault = state.vault.lock().await;
    tags::person_add_tag(&mut vault, &id_of(id), tag, None)
        .unwrap_or_else(|e| panic!("person_add_tag {tag}: {e}"));
}

async fn core_person_untag(state: &AppState, id: &str, tag: &str) {
    let mut vault = state.vault.lock().await;
    tags::person_remove_tag(&mut vault, &id_of(id), tag, None)
        .unwrap_or_else(|e| panic!("person_remove_tag {tag}: {e}"));
}

async fn person_set_body(state: &AppState, id: &str, body: &str) {
    let mut vault = state.vault.lock().await;
    let id = id_of(id);
    let version = get_note(&vault, &id).unwrap().version;
    update_note_as(
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
    .unwrap_or_else(|e| panic!("update {id}: {e}"));
}

// ---------- reads ----------

/// `(tag, origin)` of a note's rows, sorted by tag.
async fn rows(state: &AppState, id: &str) -> Vec<(String, String)> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap();
    let out = stmt
        .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    out
}

fn pairs(items: &[(&str, &str)]) -> Vec<(String, String)> {
    items
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

async fn correction_count(state: &AppState, id: &str) -> i64 {
    let vault = state.vault.lock().await;
    vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM tag_corrections WHERE note_id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

/// `(topic_note_id, origin)` of a note's chips, in footer order.
async fn chips(state: &AppState, id: &str) -> Vec<(String, String)> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap();
    let out = stmt
        .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    out
}

/// A note's `(version, updated_at, content_md)` as stored.
async fn stored(state: &AppState, id: &str) -> (i64, i64, String) {
    let vault = state.vault.lock().await;
    let note = get_note(&vault, &id_of(id)).unwrap();
    (note.version, note.updated_at, note.content_md)
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

/// `embed_model_version` of each chunk of the note, in order.
async fn chunk_versions(state: &AppState, id: &str) -> Vec<Option<String>> {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT embed_model_version FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let out = stmt
        .query_map([id], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    out
}

async fn chunk_text(state: &AppState, id: &str) -> String {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT content FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let out: Vec<String> = stmt
        .query_map([id], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    out.join("\n")
}

/// The lines below the marker, or nothing when the body has no marker.
fn footer_lines(body: &str) -> Vec<&str> {
    match body.split_once(MARKER) {
        Some((_, below)) => below.lines().filter(|l| !l.trim().is_empty()).collect(),
        None => Vec::new(),
    }
}

/// The text above the marker: all of it when there's no marker.
fn person_text(body: &str) -> &str {
    body.split_once(MARKER).map_or(body, |(above, _)| above)
}

// ---------- tool calls ----------

async fn list_tags(m: &Memex) -> Value {
    parse(&m.list_tags(params(json!({}))).await)
}

async fn tag_note(m: &Memex, id: &str, tag: &str) -> Value {
    parse(
        &m.tag_note(params(json!({ "note_id": id, "tag": tag })))
            .await,
    )
}

async fn untag_note(m: &Memex, id: &str, tag: &str) -> Value {
    parse(
        &m.untag_note(params(json!({ "note_id": id, "tag": tag })))
            .await,
    )
}

async fn add_footer_topic(m: &Memex, id: &str, topic: &str) -> Value {
    parse(
        &m.add_footer_topic(params(json!({ "note_id": id, "topic_note_id": topic })))
            .await,
    )
}

async fn tool_get_note(m: &Memex, id: &str) -> Value {
    parse(&m.get_note(params(json!({ "note_id": id }))).await)
}

/// `create_note`'s `(note_id, version)` for `args`.
async fn tool_create_note(m: &Memex, args: Value) -> (String, i64) {
    let v = parse(&m.create_note(params(args)).await);
    assert!(v.get("error").is_none(), "create_note failed: {v}");
    (
        v["note_id"].as_str().expect("note_id").to_string(),
        v["version"].as_i64().expect("version"),
    )
}

async fn mark_reviewed(m: &Memex, id: &str) {
    let changes = parse(
        &m.get_daily_note_changes(params(json!({ "date": DAY })))
            .await,
    );
    let version = changes["content_version"]
        .as_i64()
        .expect("content_version");
    let v = parse(
        &m.mark_day_reviewed(params(json!({
            "date": DAY,
            "version": version,
            "changes": [{ "note_id": id, "bullets": ["Reviewed"] }],
        })))
        .await,
    );
    assert!(v.get("error").is_none(), "mark_day_reviewed failed: {v}");
}

async fn unreviewed_days(m: &Memex) -> Vec<String> {
    let v = parse(&m.list_unreviewed_days(params(json!({}))).await);
    v["days"]
        .as_array()
        .unwrap_or_else(|| panic!("a days array: {v}"))
        .iter()
        .map(|d| d["date"].as_str().unwrap().to_string())
        .collect()
}

// ---------- shapes ----------

/// A C1 error object with exactly `code` and `message`.
fn assert_c1(v: &Value, code: &str) {
    assert!(v["error"].is_object(), "expected an error object, got {v}");
    assert_eq!(v["error"]["code"], json!(code), "{v}");
    assert!(v["error"]["message"].is_string(), "message: {v}");
    let fields: BTreeSet<&str> = v["error"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(fields, BTreeSet::from(["code", "message"]), "{v}");
}

/// The output has the contract's fields; a `vault_id` beside them is the shape
/// other tools have, and the only other field allowed.
fn assert_output_fields(v: &Value, fields: &[&str]) {
    assert!(v.get("error").is_none(), "unexpected error: {v}");
    let got: BTreeSet<&str> = v
        .as_object()
        .unwrap_or_else(|| panic!("expected an object: {v}"))
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "vault_id")
        .collect();
    let want: BTreeSet<&str> = fields.iter().copied().collect();
    assert_eq!(got, want, "{v}");
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap_or_else(|| panic!("expected an array: {v}"))
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

// ======================================================================
// AC 1: list_tags is the vocabulary with counts.
// ======================================================================

#[tokio::test]
async fn list_tags_returns_each_vocabulary_tag_with_its_note_count_from_any_origin() {
    let (_dir, state, m) = fresh();
    person_note(&state, "Zebra first", "#work and #alpha\n").await;
    person_note(&state, "Second", "More #work\n").await;
    let plain = person_note(&state, "Agent tagged", "Plain.\n").await;
    core_agent_tag(&state, &plain, "work").await;
    let labelled = person_note(&state, "Person tagged", "Plain too.\n").await;
    core_person_tag(&state, &labelled, "work").await;

    let v = list_tags(&m).await;

    assert_output_fields(&v, &["tags"]);
    assert_eq!(
        v["tags"],
        json!([
            { "tag": "alpha", "note_count": 1 },
            { "tag": "work", "note_count": 4 },
        ]),
        "alphabetical, each with only `tag` and `note_count`"
    );
}

#[tokio::test]
async fn list_tags_on_a_vault_without_tags_is_an_empty_list() {
    let (_dir, state, m) = fresh();
    person_note(&state, "Plain", "No tags here.\n").await;

    assert_eq!(list_tags(&m).await["tags"], json!([]));
}

#[tokio::test]
async fn list_tags_leaves_out_system_tags_even_when_a_person_wrote_them() {
    let (_dir, state, m) = fresh();
    person_note(&state, "Written", "#inbox #agent-authored #kept\n").await;
    tool_create_note(&m, json!({ "title": "Auto", "content_md": "Auto tags.\n" })).await;

    assert_eq!(
        list_tags(&m).await["tags"],
        json!([{ "tag": "kept", "note_count": 1 }])
    );
}

#[tokio::test]
async fn list_tags_leaves_out_tags_written_only_on_a_guide_note() {
    let (_dir, state, m) = fresh();
    let id = guide(&state).await;
    person_set_body(&state, &id, "How to use #secret.\n").await;
    seed_row(&state, &id, "buried", "body").await;
    person_note(&state, "Other", "#visible\n").await;

    assert_eq!(
        list_tags(&m).await["tags"],
        json!([{ "tag": "visible", "note_count": 1 }])
    );
}

#[tokio::test]
async fn list_tags_leaves_out_tags_no_person_wrote_in_a_body() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Labelled", "#written\n").await;
    core_person_tag(&state, &id, "labelled").await;
    tool_create_note(
        &m,
        json!({ "title": "Gap", "content_md": "Agent.\n", "tags": ["gap"] }),
    )
    .await;

    assert_eq!(
        list_tags(&m).await["tags"],
        json!([{ "tag": "written", "note_count": 1 }])
    );
}

// ======================================================================
// AC 2: tag_note applies a vocabulary tag.
// ======================================================================

#[tokio::test]
async fn tag_note_applies_a_vocabulary_tag_and_shows_it_in_tags_agent_tags_and_footer_text() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let (before, _, _) = stored(&state, &id).await;

    let v = tag_note(&m, &id, "work").await;

    assert_output_fields(&v, &["note_id", "tag", "applied", "version"]);
    assert_eq!(v["note_id"], json!(id));
    assert_eq!(v["tag"], json!("work"));
    assert_eq!(v["applied"], json!(true));
    let (version, _, body) = stored(&state, &id).await;
    assert!(version > before, "the footer write moves the version");
    assert_eq!(v["version"], json!(version), "the version after the call");

    let note = tool_get_note(&m, &id).await;
    assert_eq!(strings(&note["tags"]), ["work"]);
    assert_eq!(strings(&note["agent_tags"]), ["work"]);
    assert_eq!(footer_lines(&body), ["#work"], "footer text: {body:?}");
    assert_eq!(
        person_text(&body).trim_end(),
        "Person text.",
        "the person's text stays above the marker"
    );
    assert_eq!(rows(&state, &id).await, pairs(&[("work", "agent")]));
}

// ======================================================================
// AC 3: tag_note's structured errors.
// ======================================================================

#[tokio::test]
async fn tag_note_returns_unknown_tag_for_a_name_outside_the_vocabulary() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let before = stored(&state, &id).await;

    for tag in ["stranger", "not a tag!", "inbox"] {
        assert_c1(&tag_note(&m, &id, tag).await, "unknown_tag");
    }

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[]));
}

#[tokio::test]
async fn tag_note_returns_tag_removed_after_the_person_removed_it_from_that_note() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let other = person_note(&state, "Other", "Other text.\n").await;
    core_agent_tag(&state, &id, "work").await;
    core_person_untag(&state, &id, "work").await;
    let before = stored(&state, &id).await;

    assert_c1(&tag_note(&m, &id, "work").await, "tag_removed");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[]));
    assert_eq!(
        tag_note(&m, &other, "work").await["applied"],
        json!(true),
        "the block holds on that note only"
    );
}

#[tokio::test]
async fn tag_note_returns_guide_rule_on_a_guide_note() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = guide(&state).await;
    let before = stored(&state, &id).await;

    assert_c1(&tag_note(&m, &id, "work").await, "guide_rule");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[]));
}

#[tokio::test]
async fn tag_note_returns_not_found_for_an_unknown_note() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;

    assert_c1(&tag_note(&m, NO_SUCH_NOTE, "work").await, "not_found");
}

#[tokio::test]
async fn tag_note_returns_invalid_id_for_a_malformed_note_id() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;

    assert_c1(&tag_note(&m, "not-a-ulid", "work").await, "invalid_id");
}

// ======================================================================
// AC 4: repeating tag_note writes nothing.
// ======================================================================

#[tokio::test]
async fn tag_note_repeated_returns_applied_false_and_keeps_the_version() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;

    let first = tag_note(&m, &id, "work").await;
    assert_eq!(first["applied"], json!(true), "{first}");
    let before = stored(&state, &id).await;

    let again = tag_note(&m, &id, "work").await;

    assert_output_fields(&again, &["note_id", "tag", "applied", "version"]);
    assert_eq!(again["applied"], json!(false));
    assert_eq!(again["version"], first["version"]);
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
}

#[tokio::test]
async fn tag_note_on_a_tag_written_in_the_body_returns_applied_false_and_keeps_its_origin() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Written", "About #work.\n").await;
    let before = stored(&state, &id).await;

    let v = tag_note(&m, &id, "work").await;

    assert_eq!(v["applied"], json!(false), "{v}");
    assert_eq!(v["version"], json!(before.0));
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[("work", "body")]));
}

#[tokio::test]
async fn tag_note_on_a_system_tag_the_note_has_returns_applied_false() {
    let (_dir, state, m) = fresh();
    let (id, _) = tool_create_note(&m, json!({ "title": "Auto", "content_md": "Text.\n" })).await;
    let before = stored(&state, &id).await;

    let v = tag_note(&m, &id, "inbox").await;

    assert_eq!(v["applied"], json!(false), "{v}");
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
}

// ======================================================================
// AC 5: tag inputs: the stored name first, then lowercased (R38).
// ======================================================================

#[tokio::test]
async fn tag_note_with_a_capitalized_name_applies_the_lowercase_tag() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["pricing"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;

    let v = tag_note(&m, &id, "Pricing").await;

    assert_eq!(v["applied"], json!(true), "{v}");
    assert_eq!(v["tag"], json!("pricing"), "the name applied: {v}");
    assert_eq!(rows(&state, &id).await, pairs(&[("pricing", "agent")]));
    assert_eq!(
        strings(&tool_get_note(&m, &id).await["tags"]),
        ["pricing"],
        "get_note shows the stored name"
    );
    let (_, _, body) = stored(&state, &id).await;
    assert_eq!(footer_lines(&body), ["#pricing"]);
}

#[tokio::test]
async fn tag_note_with_a_leading_hash_applies_the_bare_lowercase_tag() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["pricing"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;

    let v = tag_note(&m, &id, "#Pricing").await;

    assert_eq!(v["applied"], json!(true), "{v}");
    assert_eq!(v["tag"], json!("pricing"), "the name applied: {v}");
    assert_eq!(rows(&state, &id).await, pairs(&[("pricing", "agent")]));
}

#[tokio::test]
async fn tag_note_matching_a_legacy_capitalized_row_writes_nothing() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["pricing"]).await;
    let id = person_note(&state, "Legacy", "Person text.\n").await;
    seed_row(&state, &id, "Pricing", "person").await;
    let before = stored(&state, &id).await;

    let v = tag_note(&m, &id, "Pricing").await;

    assert_eq!(v["applied"], json!(false), "{v}");
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[("Pricing", "person")]));
}

// ======================================================================
// AC 6: tag_note on a daily note.
// ======================================================================

#[tokio::test]
async fn tag_note_on_a_daily_note_leaves_its_review_state_and_content_version_unchanged() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = daily(&state, "Today's words.\n").await;
    mark_reviewed(&m, &id).await;
    let review = day_review_row(&state, &id).await;
    assert!(review.2.is_some(), "the day is reviewed: {review:?}");
    assert!(!unreviewed_days(&m).await.contains(&DAY.to_string()));
    let (version, _, _) = stored(&state, &id).await;

    let v = tag_note(&m, &id, "work").await;

    assert_eq!(v["applied"], json!(true), "{v}");
    let (after, _, body) = stored(&state, &id).await;
    assert!(after > version, "the footer write moves the note's version");
    assert_eq!(footer_lines(&body), ["#work"], "footer text: {body:?}");
    assert_eq!(person_text(&body).trim_end(), "Today's words.");
    assert_eq!(
        day_review_row(&state, &id).await,
        review,
        "content_version and the review stay"
    );
    assert!(
        !unreviewed_days(&m).await.contains(&DAY.to_string()),
        "the day stays reviewed"
    );
}

// ======================================================================
// AC 7: untag_note removes an agent tag.
// ======================================================================

#[tokio::test]
async fn untag_note_removes_an_agent_tag_and_adds_no_correction() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    core_agent_tag(&state, &id, "work").await;
    let (tagged, _, _) = stored(&state, &id).await;

    let v = untag_note(&m, &id, "work").await;

    assert_output_fields(&v, &["note_id", "tag", "removed", "version"]);
    assert_eq!(v["note_id"], json!(id));
    assert_eq!(v["tag"], json!("work"));
    assert_eq!(v["removed"], json!(true));
    let (version, _, body) = stored(&state, &id).await;
    assert!(version > tagged, "the footer write moves the version");
    assert_eq!(v["version"], json!(version), "the version after the call");
    assert_eq!(rows(&state, &id).await, pairs(&[]));
    assert_eq!(correction_count(&state, &id).await, 0, "no correction");
    assert!(!body.contains("#work"), "the footer line went: {body:?}");
    assert!(
        !body.contains(MARKER),
        "the last footer item takes the marker with it: {body:?}"
    );
    let note = tool_get_note(&m, &id).await;
    assert_eq!(note["tags"], json!([]));
    assert_eq!(note["agent_tags"], json!([]));
}

#[tokio::test]
async fn untag_note_leaves_the_tag_free_to_apply_again() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    core_agent_tag(&state, &id, "work").await;

    let v = untag_note(&m, &id, "work").await;
    assert_eq!(v["removed"], json!(true), "{v}");

    let again = tag_note(&m, &id, "work").await;
    assert_eq!(again["applied"], json!(true), "no block follows: {again}");
}

#[tokio::test]
async fn untag_note_with_a_capitalized_name_removes_the_lowercase_tag() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    core_agent_tag(&state, &id, "work").await;

    let v = untag_note(&m, &id, "#Work").await;

    assert_eq!(v["removed"], json!(true), "{v}");
    assert_eq!(v["tag"], json!("work"), "the name removed: {v}");
    assert_eq!(rows(&state, &id).await, pairs(&[]));
}

#[tokio::test]
async fn untag_note_for_a_tag_the_note_lacks_returns_removed_false_and_keeps_the_version() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let before = stored(&state, &id).await;

    let v = untag_note(&m, &id, "work").await;

    assert_output_fields(&v, &["note_id", "tag", "removed", "version"]);
    assert_eq!(v["removed"], json!(false));
    assert_eq!(v["version"], json!(before.0));
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
}

#[tokio::test]
async fn untag_note_echoes_an_input_outside_the_grammar_without_its_leading_hash() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let before = stored(&state, &id).await;

    let v = untag_note(&m, &id, "#not a tag!").await;

    assert_output_fields(&v, &["note_id", "tag", "removed", "version"]);
    assert_eq!(v["tag"], json!("not a tag!"), "{v}");
    assert_eq!(v["removed"], json!(false), "{v}");
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
}

#[tokio::test]
async fn untag_note_on_a_daily_note_leaves_its_review_state_and_content_version_unchanged() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["work"]).await;
    let id = daily(&state, "Today's words.\n").await;
    core_agent_tag(&state, &id, "work").await;
    mark_reviewed(&m, &id).await;
    let review = day_review_row(&state, &id).await;
    assert!(review.2.is_some(), "the day is reviewed: {review:?}");

    let v = untag_note(&m, &id, "work").await;

    assert_eq!(v["removed"], json!(true), "{v}");
    let (_, _, body) = stored(&state, &id).await;
    assert!(footer_lines(&body).is_empty(), "footer text gone: {body:?}");
    assert_eq!(day_review_row(&state, &id).await, review);
    assert!(!unreviewed_days(&m).await.contains(&DAY.to_string()));
}

// ======================================================================
// AC 8: untag_note fails on every other origin and on a guide.
// ======================================================================

#[tokio::test]
async fn untag_note_on_a_body_tag_fails_and_changes_nothing() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Written", "About #work.\n").await;
    let before = stored(&state, &id).await;

    assert_c1(&untag_note(&m, &id, "work").await, "invalid_argument");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[("work", "body")]));
    assert_eq!(correction_count(&state, &id).await, 0);
}

#[tokio::test]
async fn untag_note_on_a_person_tag_fails_and_changes_nothing() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Labelled", "Person text.\n").await;
    core_person_tag(&state, &id, "work").await;
    let before = stored(&state, &id).await;

    assert_c1(&untag_note(&m, &id, "work").await, "invalid_argument");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[("work", "person")]));
    assert_eq!(correction_count(&state, &id).await, 0);
}

#[tokio::test]
async fn untag_note_on_a_system_tag_fails_and_changes_nothing() {
    let (_dir, state, m) = fresh();
    let (id, _) = tool_create_note(&m, json!({ "title": "Auto", "content_md": "Text.\n" })).await;
    let before_rows = rows(&state, &id).await;
    let before = stored(&state, &id).await;

    for tag in ["inbox", "agent-authored"] {
        assert_c1(&untag_note(&m, &id, tag).await, "invalid_argument");
    }

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, before_rows);
}

#[tokio::test]
async fn untag_note_returns_guide_rule_on_a_guide_note() {
    let (_dir, state, m) = fresh();
    let id = guide(&state).await;
    seed_row(&state, &id, "buried", "agent").await;
    let before = stored(&state, &id).await;

    for tag in ["buried", "missing"] {
        assert_c1(&untag_note(&m, &id, tag).await, "guide_rule");
    }

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(rows(&state, &id).await, pairs(&[("buried", "agent")]));
}

#[tokio::test]
async fn untag_note_returns_not_found_for_an_unknown_note() {
    let (_dir, _state, m) = fresh();

    assert_c1(&untag_note(&m, NO_SUCH_NOTE, "work").await, "not_found");
}

#[tokio::test]
async fn untag_note_returns_invalid_id_for_a_malformed_note_id() {
    let (_dir, _state, m) = fresh();

    assert_c1(&untag_note(&m, "not-a-ulid", "work").await, "invalid_id");
}

// ======================================================================
// AC 9: add_footer_topic.
// ======================================================================

#[tokio::test]
async fn add_footer_topic_adds_a_chip_with_origin_excerpt_on_a_plain_note() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let (before, _, _) = stored(&state, &id).await;

    let v = add_footer_topic(&m, &id, &target).await;

    assert_output_fields(
        &v,
        &["note_id", "topic_note_id", "origin", "version", "changed"],
    );
    assert_eq!(v["note_id"], json!(id));
    assert_eq!(v["topic_note_id"], json!(target));
    assert_eq!(v["origin"], json!("excerpt"));
    let (version, _, body) = stored(&state, &id).await;
    assert!(version > before, "the footer write moves the version");
    assert_eq!(v["version"], json!(version), "the version after the call");
    assert_eq!(
        chips(&state, &id).await,
        pairs(&[(target.as_str(), "excerpt")])
    );
    assert_eq!(footer_lines(&body), ["[[Player Loop~about]]"], "{body:?}");
    assert_eq!(person_text(&body).trim_end(), "Person text.");
}

#[tokio::test]
async fn add_footer_topic_returns_guide_rule_on_a_guide_note() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = guide(&state).await;
    let before = stored(&state, &id).await;

    assert_c1(&add_footer_topic(&m, &id, &target).await, "guide_rule");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(chips(&state, &id).await, pairs(&[]));
}

#[tokio::test]
async fn add_footer_topic_returns_role_rule_for_a_target_that_is_not_a_topic() {
    let (_dir, state, m) = fresh();
    let plain_target = person_note(&state, "Not a topic", "Text.\n").await;
    let day_target = daily(&state, "Today.\n").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let before = stored(&state, &id).await;

    for target in [&plain_target, &day_target] {
        assert_c1(&add_footer_topic(&m, &id, target).await, "role_rule");
    }

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(chips(&state, &id).await, pairs(&[]));
}

#[tokio::test]
async fn add_footer_topic_returns_invalid_argument_for_a_self_chip() {
    let (_dir, state, m) = fresh();
    let id = topic(&state, "Player Loop").await;
    let before = stored(&state, &id).await;

    assert_c1(&add_footer_topic(&m, &id, &id).await, "invalid_argument");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(chips(&state, &id).await, pairs(&[]));
}

#[tokio::test]
async fn add_footer_topic_returns_not_found_for_an_unknown_note_or_target() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    let before = stored(&state, &id).await;

    assert_c1(
        &add_footer_topic(&m, NO_SUCH_NOTE, &target).await,
        "not_found",
    );
    assert_c1(&add_footer_topic(&m, &id, NO_SUCH_NOTE).await, "not_found");

    assert_eq!(stored(&state, &id).await, before, "nothing is written");
}

#[tokio::test]
async fn add_footer_topic_returns_invalid_id_for_a_malformed_note_or_target_id() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;

    assert_c1(
        &add_footer_topic(&m, "not-a-ulid", &target).await,
        "invalid_id",
    );
    assert_c1(&add_footer_topic(&m, &id, "not-a-ulid").await, "invalid_id");
}

#[tokio::test]
async fn add_footer_topic_repeated_keeps_the_version() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;

    let first = add_footer_topic(&m, &id, &target).await;
    assert_eq!(first["origin"], json!("excerpt"), "{first}");
    let before = stored(&state, &id).await;

    let again = add_footer_topic(&m, &id, &target).await;

    assert_eq!(again["origin"], json!("excerpt"));
    assert_eq!(again["version"], first["version"]);
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
}

#[tokio::test]
async fn add_footer_topic_over_a_person_chip_reports_and_keeps_origin_person() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;
    {
        let mut vault = state.vault.lock().await;
        footer::set_chip(
            &mut vault,
            &id_of(&id),
            &id_of(&target),
            ChipOrigin::Person,
            None,
        )
        .unwrap();
    }
    let before = stored(&state, &id).await;

    let v = add_footer_topic(&m, &id, &target).await;

    assert_eq!(v["origin"], json!("person"), "the origin stored: {v}");
    assert_eq!(v["version"], json!(before.0));
    assert_eq!(stored(&state, &id).await, before, "nothing is written");
    assert_eq!(
        chips(&state, &id).await,
        pairs(&[(target.as_str(), "person")])
    );
}

#[tokio::test]
async fn add_footer_topic_on_a_daily_note_leaves_its_review_state_and_content_version_unchanged() {
    let (_dir, state, m) = fresh();
    let target = topic(&state, "Player Loop").await;
    let id = daily(&state, "Today's words.\n").await;
    mark_reviewed(&m, &id).await;
    let review = day_review_row(&state, &id).await;
    assert!(review.2.is_some(), "the day is reviewed: {review:?}");

    let v = add_footer_topic(&m, &id, &target).await;

    assert_eq!(v["origin"], json!("excerpt"), "{v}");
    let (_, _, body) = stored(&state, &id).await;
    assert_eq!(footer_lines(&body), ["[[Player Loop~about]]"], "{body:?}");
    assert_eq!(day_review_row(&state, &id).await, review);
    assert!(!unreviewed_days(&m).await.contains(&DAY.to_string()));
}

// ======================================================================
// AC 10: create_note stores its tags agent-origin with footer text.
// ======================================================================

#[tokio::test]
async fn create_note_stores_its_tags_as_agent_with_footer_text_and_leaves_body_hashes_untagged() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Captured", "content_md": "About #y here.\n", "tags": ["x"] }),
    )
    .await;

    assert_eq!(
        rows(&state, &id).await,
        pairs(&[
            ("agent-authored", "agent"),
            ("inbox", "agent"),
            ("x", "agent"),
        ]),
        "`y` stays untagged"
    );
    let (_, _, body) = stored(&state, &id).await;
    assert_eq!(
        footer_lines(&body),
        ["#x"],
        "only `x` has footer text: {body:?}"
    );
    assert_eq!(person_text(&body).trim_end(), "About #y here.");
}

#[tokio::test]
async fn create_note_without_tags_stores_the_auto_tags_as_agent_and_writes_no_footer() {
    let (_dir, state, m) = fresh();

    let (id, version) =
        tool_create_note(&m, json!({ "title": "Auto", "content_md": "Text.\n" })).await;

    assert_eq!(
        rows(&state, &id).await,
        pairs(&[("agent-authored", "agent"), ("inbox", "agent")])
    );
    let (stored_version, _, body) = stored(&state, &id).await;
    assert_eq!(version, stored_version);
    assert_eq!(version, 1, "system tags write no footer");
    assert!(!body.contains(MARKER), "no footer: {body:?}");
}

#[tokio::test]
async fn create_note_with_a_system_tag_in_its_input_stores_it_once_with_no_footer_text() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Listed", "content_md": "Text.\n", "tags": ["Inbox", "agent-authored"] }),
    )
    .await;

    assert_eq!(
        rows(&state, &id).await,
        pairs(&[("agent-authored", "agent"), ("inbox", "agent")])
    );
    let (_, _, body) = stored(&state, &id).await;
    assert!(!body.contains(MARKER), "no footer: {body:?}");
}

#[tokio::test]
async fn create_note_with_a_capitalized_or_repeated_tag_stores_one_lowercase_row() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Twice", "content_md": "Text.\n", "tags": ["Work", "work", "#WORK"] }),
    )
    .await;

    assert_eq!(
        rows(&state, &id).await,
        pairs(&[
            ("agent-authored", "agent"),
            ("inbox", "agent"),
            ("work", "agent"),
        ])
    );
    let (_, _, body) = stored(&state, &id).await;
    assert_eq!(footer_lines(&body), ["#work"], "{body:?}");
}

#[tokio::test]
async fn create_note_with_a_tag_outside_the_vocabulary_still_succeeds_and_stays_out_of_it() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["known"]).await;
    let other = person_note(&state, "Other", "Other text.\n").await;

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Gap", "content_md": "Text.\n", "tags": ["brand-new"] }),
    )
    .await;

    assert_eq!(
        strings(&tool_get_note(&m, &id).await["agent_tags"]),
        ["brand-new"],
        "the known gap (R40)"
    );
    assert_eq!(
        list_tags(&m).await["tags"],
        json!([{ "tag": "known", "note_count": 1 }])
    );
    assert_c1(&tag_note(&m, &other, "brand-new").await, "unknown_tag");
}

/// `(notes, tags, footer_chips, chunks)` row counts: a rejected `create_note`
/// leaves all four as they were.
async fn store_counts(state: &AppState) -> (i64, i64, i64, i64) {
    let vault = state.vault.lock().await;
    let conn = vault.connection_ref();
    let count = |table: &str| -> i64 {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    };
    (
        count("notes"),
        count("tags"),
        count("footer_chips"),
        count("chunks"),
    )
}

async fn create_note_raw(m: &Memex, args: Value) -> Value {
    parse(&m.create_note(params(args)).await)
}

#[tokio::test]
async fn create_note_with_a_bad_tag_name_among_good_ones_is_invalid_argument_and_writes_nothing() {
    let (_dir, state, m) = fresh();
    person_note(&state, "Existing", "Existing text.\n").await;
    let before = store_counts(&state).await;

    let reply = create_note_raw(
        &m,
        json!({ "title": "Bad", "content_md": "Text.\n", "tags": ["good", "not a tag!", "fine"] }),
    )
    .await;

    assert_c1(&reply, "invalid_argument");
    let message = reply["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("\"not a tag!\""),
        "the message names the offending tag: {message:?}"
    );
    assert_eq!(
        store_counts(&state).await,
        before,
        "no note, tag row, chip or chunk"
    );
}

#[tokio::test]
async fn create_note_rejects_a_bad_tag_name_in_any_position_and_of_any_kind() {
    let (_dir, state, m) = fresh();
    let before = store_counts(&state).await;

    for (name, tags) in [
        ("first", json!(["not a tag!", "good"])),
        ("middle", json!(["good", "not a tag!", "fine"])),
        ("last", json!(["good", "fine", "not a tag!"])),
        ("only", json!(["not a tag!"])),
        ("double hash", json!(["good", "##x"])),
        ("lone hash", json!(["#"])),
        ("empty", json!(["good", ""])),
        ("space inside", json!(["two words"])),
        ("hash then space", json!(["# x"])),
    ] {
        let reply = create_note_raw(
            &m,
            json!({ "title": "Bad", "content_md": "Text.\n", "tags": tags }),
        )
        .await;
        assert_c1(&reply, "invalid_argument");
        assert_eq!(
            store_counts(&state).await,
            before,
            "{name}: nothing written"
        );
    }
}

#[tokio::test]
async fn create_note_names_the_first_bad_tag_name_as_given() {
    let (_dir, _state, m) = fresh();

    let reply = create_note_raw(
        &m,
        json!({ "title": "Bad", "content_md": "Text.\n", "tags": ["good", "#First Bad", "second bad!"] }),
    )
    .await;

    assert_c1(&reply, "invalid_argument");
    let message = reply["error"]["message"].as_str().unwrap();
    assert!(message.contains("\"#First Bad\""), "{message:?}");
    assert!(!message.contains("second bad!"), "{message:?}");
}

#[tokio::test]
async fn create_note_accepts_a_leading_hash_on_a_tag_name() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Hashed", "content_md": "Text.\n", "tags": ["#good"] }),
    )
    .await;

    assert_eq!(
        rows(&state, &id).await,
        pairs(&[
            ("agent-authored", "agent"),
            ("good", "agent"),
            ("inbox", "agent"),
        ])
    );
    let (_, _, body) = stored(&state, &id).await;
    assert_eq!(footer_lines(&body), ["#good"], "{body:?}");
}

#[tokio::test]
async fn create_note_with_an_empty_tags_list_still_creates_with_the_auto_tags() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Empty", "content_md": "Text.\n", "tags": [] }),
    )
    .await;

    assert_eq!(
        rows(&state, &id).await,
        pairs(&[("agent-authored", "agent"), ("inbox", "agent")])
    );
}

#[tokio::test]
async fn create_note_checks_the_tag_names_before_the_role_the_marker_and_the_title() {
    let (_dir, state, m) = fresh();
    person_note(&state, "Taken", "Text.\n").await;
    let before = store_counts(&state).await;
    let bad = json!(["not a tag!"]);

    for (rule, args) in [
        (
            "role_rule",
            json!({ "title": "T", "content_md": "x\n", "tags": bad, "role": "weekly" }),
        ),
        (
            "marker_rule",
            json!({ "title": DAY, "content_md": "not empty\n", "tags": bad, "role": "daily" }),
        ),
        (
            "title_conflict",
            json!({ "title": "Taken", "content_md": "x\n", "tags": bad }),
        ),
    ] {
        let reply = create_note_raw(&m, args).await;
        assert_c1(&reply, "invalid_argument");
        assert_eq!(
            store_counts(&state).await,
            before,
            "{rule}: nothing written"
        );
    }
}

#[tokio::test]
async fn create_note_returns_the_version_after_its_footer_write_so_a_save_at_it_succeeds() {
    let (_dir, state, m) = fresh();

    let (id, version) = tool_create_note(
        &m,
        json!({ "title": "Saved", "content_md": "Text.\n", "tags": ["x"] }),
    )
    .await;

    let (stored_version, _, body) = stored(&state, &id).await;
    assert!(body.contains(MARKER), "the footer is written: {body:?}");
    assert_eq!(
        version, stored_version,
        "the version after the footer write"
    );
    let mut vault = state.vault.lock().await;
    update_note_as(
        &mut vault,
        &id_of(&id),
        version,
        UpdateNote {
            content_md: Some("Edited.\n".into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .expect("a save at the returned version doesn't conflict");
}

#[tokio::test]
async fn create_note_indexes_the_body_without_its_footer_text() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Indexed", "content_md": "Text.\n", "tags": ["zebra"] }),
    )
    .await;

    let (_, _, body) = stored(&state, &id).await;
    assert_eq!(footer_lines(&body), ["#zebra"], "{body:?}");
    let indexed = chunk_text(&state, &id).await;
    // Only the person section is chunked (WI #418, Spec #391 req 1).
    assert!(
        !indexed.contains("#zebra"),
        "footer tag lines are in no chunk: {indexed:?}"
    );
    assert!(
        indexed.contains("Text."),
        "the body is indexed: {indexed:?}"
    );
}

#[tokio::test]
async fn create_note_daily_with_tags_gets_footer_text_and_keeps_the_days_content_version() {
    let (_dir, state, m) = fresh();
    let (bare, _) = tool_create_note(
        &m,
        json!({ "title": "2026-09-04", "content_md": "", "role": "daily" }),
    )
    .await;
    let bare_review = day_review_row(&state, &bare).await;

    let (id, version) = tool_create_note(
        &m,
        json!({ "title": DAY, "content_md": "", "role": "daily", "tags": ["x"] }),
    )
    .await;

    let (stored_version, _, body) = stored(&state, &id).await;
    assert_eq!(version, stored_version);
    assert_eq!(footer_lines(&body), ["#x"], "{body:?}");
    assert_eq!(
        day_review_row(&state, &id).await.0,
        bare_review.0,
        "footer text doesn't move content_version"
    );
}

#[tokio::test]
async fn create_note_body_tags_stay_out_of_the_vocabulary_until_a_person_saves_the_note() {
    let (_dir, state, m) = fresh();

    let (id, _) = tool_create_note(
        &m,
        json!({ "title": "Scan", "content_md": "About #scanned here.\n" }),
    )
    .await;
    assert_eq!(
        list_tags(&m).await["tags"],
        json!([]),
        "the agent's body adds no vocabulary"
    );

    person_set_body(&state, &id, "About #scanned here.\n").await;

    assert_eq!(
        list_tags(&m).await["tags"],
        json!([{ "tag": "scanned", "note_count": 1 }]),
        "a person's save scans it"
    );
}

// ======================================================================
// AC 11: get_note's agent_tags.
// ======================================================================

#[tokio::test]
async fn get_note_on_a_note_with_no_agent_tags_has_an_empty_agent_tags_list() {
    let (_dir, state, m) = fresh();
    let id = person_note(&state, "Written", "About #work.\n").await;
    core_person_tag(&state, &id, "label").await;

    let note = tool_get_note(&m, &id).await;

    assert_eq!(note["agent_tags"], json!([]), "present and empty: {note}");
    assert_eq!(strings(&note["tags"]), ["label", "work"], "`tags` stays");
}

#[tokio::test]
async fn get_note_agent_tags_leave_out_system_tags_while_tags_keeps_them() {
    let (_dir, _state, m) = fresh();
    let (id, _) = tool_create_note(&m, json!({ "title": "Auto", "content_md": "Text.\n" })).await;

    let note = tool_get_note(&m, &id).await;

    assert_eq!(note["agent_tags"], json!([]), "{note}");
    assert_eq!(strings(&note["tags"]), ["agent-authored", "inbox"]);
}

#[tokio::test]
async fn get_note_agent_tags_lists_only_agent_origin_tags_sorted() {
    let (_dir, state, m) = fresh();
    vocabulary(&state, &["beta", "alpha"]).await;
    let id = person_note(&state, "Mixed", "About #written.\n").await;
    core_person_tag(&state, &id, "label").await;
    core_agent_tag(&state, &id, "beta").await;
    core_agent_tag(&state, &id, "alpha").await;

    let note = tool_get_note(&m, &id).await;

    assert_eq!(strings(&note["agent_tags"]), ["alpha", "beta"]);
    assert_eq!(
        strings(&note["tags"]),
        ["alpha", "beta", "label", "written"]
    );
}

// ======================================================================
// Every write reindexes with the server's embedder, as other write tools do.
// ======================================================================

#[tokio::test]
async fn tag_tools_reindex_with_the_servers_embedder() {
    let embedder: Arc<dyn Embedder> = Arc::new(FakeEmbedder::new(8));
    let version = embedder.model_version().to_string();
    let (_dir, state, m) = fresh_with(Some(embedder));
    vocabulary(&state, &["work"]).await;
    let target = topic(&state, "Player Loop").await;
    let id = person_note(&state, "Plain", "Person text.\n").await;

    let assert_embedded = |versions: Vec<Option<String>>, what: &str| {
        assert!(!versions.is_empty(), "{what}: the note has chunks");
        assert!(
            versions.iter().all(|v| v.as_deref() == Some(&version)),
            "{what}: every chunk is embedded: {versions:?}"
        );
    };

    let v = tag_note(&m, &id, "work").await;
    assert_eq!(v["applied"], json!(true), "{v}");
    assert_embedded(chunk_versions(&state, &id).await, "tag_note");

    let v = untag_note(&m, &id, "work").await;
    assert_eq!(v["removed"], json!(true), "{v}");
    assert_embedded(chunk_versions(&state, &id).await, "untag_note");

    let v = add_footer_topic(&m, &id, &target).await;
    assert_eq!(v["origin"], json!("excerpt"), "{v}");
    assert_embedded(chunk_versions(&state, &id).await, "add_footer_topic");
}

// ======================================================================
// AC 12: the shared tool list, the README count and the served router.
// ======================================================================

/// A `memex serve` subprocess spoken to over newline-delimited JSON-RPC.
struct TagToolsServer {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl TagToolsServer {
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
                "clientInfo": { "name": "wi241-test", "version": "0" },
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

    /// `tools/call`, with the tool's JSON text parsed.
    fn call(&mut self, id: i64, name: &str, arguments: Value) -> Value {
        let resp = self.request(
            id,
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} over JSON-RPC: {resp}"));
        parse(text)
    }
}

impl Drop for TagToolsServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn repo_file(rel: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn name_set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn schema_names(v: &Value) -> BTreeSet<String> {
    match v {
        Value::Array(items) => items
            .iter()
            .filter_map(|i| i.as_str().map(str::to_string))
            .collect(),
        Value::Object(map) => map.keys().cloned().collect(),
        _ => BTreeSet::new(),
    }
}

#[test]
fn tool_names_and_the_readme_count_include_the_tag_tools() {
    const TAG_TOOLS: [&str; 4] = ["add_footer_topic", "list_tags", "tag_note", "untag_note"];
    assert_eq!(tool_names::TAG_TOOLS, TAG_TOOLS, "#241's block, sorted");

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = TagToolsServer::start(path.to_str().unwrap());
    let served: BTreeSet<String> = server
        .tools()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    for tool in TAG_TOOLS {
        assert!(served.contains(tool), "{tool} is served: {served:?}");
    }

    let readme = repo_file("README.md");
    let count_line = Regex::new(r"(?m)^- (\d+) MCP tools:[ \t]*$").unwrap();
    let caps = count_line
        .captures(&readme)
        .expect("README.md has a line that is only `- <n> MCP tools:`");
    assert_eq!(
        caps[1].parse::<usize>().unwrap(),
        tool_names::TOOL_COUNT,
        "the README's count includes the tag tools"
    );
    for tool in TAG_TOOLS {
        assert!(
            readme.contains(&format!("`{tool}`")),
            "README.md names `{tool}`"
        );
    }
}

#[test]
fn served_tag_tools_take_the_inputs_the_contract_names() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = TagToolsServer::start(path.to_str().unwrap());
    let tools = server.tools();

    for (name, inputs) in [
        ("list_tags", vec![]),
        ("tag_note", vec!["note_id", "tag"]),
        ("untag_note", vec!["note_id", "tag"]),
        ("add_footer_topic", vec!["note_id", "topic_note_id"]),
    ] {
        let tool = tools
            .iter()
            .find(|t| t["name"] == json!(name))
            .unwrap_or_else(|| panic!("{name} is listed"));
        let schema = &tool["inputSchema"];
        assert_eq!(
            schema_names(&schema["properties"]),
            name_set(&inputs),
            "{name}: properties"
        );
        assert_eq!(
            schema_names(&schema["required"]),
            name_set(&inputs),
            "{name}: required"
        );
        assert!(
            tool["description"].as_str().is_some_and(|d| !d.is_empty()),
            "{name} has a description"
        );
    }
}

#[test]
fn served_tag_tools_answer_tools_call_with_their_outputs() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let (id, target) = {
        let mut vault = Vault::create(&path).unwrap();
        person_note_in(&mut vault, "Vocabulary", "#work\n", json!({}));
        (
            person_note_in(&mut vault, "Plain", "Person text.\n", json!({})),
            person_note_in(
                &mut vault,
                "Player Loop",
                "A topic.\n",
                json!({ "role": "topic" }),
            ),
        )
    };
    let mut server = TagToolsServer::start(path.to_str().unwrap());

    let listed = server.call(10, "list_tags", json!({}));
    assert_eq!(listed["tags"], json!([{ "tag": "work", "note_count": 1 }]));

    let tagged = server.call(11, "tag_note", json!({ "note_id": id, "tag": "work" }));
    assert_eq!(tagged["applied"], json!(true), "{tagged}");

    let blocked = server.call(12, "tag_note", json!({ "note_id": id, "tag": "nope" }));
    assert_c1(&blocked, "unknown_tag");

    let untagged = server.call(13, "untag_note", json!({ "note_id": id, "tag": "work" }));
    assert_eq!(untagged["removed"], json!(true), "{untagged}");

    let chip = server.call(
        14,
        "add_footer_topic",
        json!({ "note_id": id, "topic_note_id": target }),
    );
    assert_eq!(chip["origin"], json!("excerpt"), "{chip}");
}
