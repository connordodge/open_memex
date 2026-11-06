//! WI #17 (D1): the cross-tool review and capture sequences (TS2) and the
//! final MCP tool list.
//!
//! Each test starts `memex serve` as a subprocess over a temp vault and drives
//! it over newline-delimited JSON-RPC, calling the tools in the order the
//! `review_daily_notes` and `capture` prompts describe (crates/memex-mcp/src/
//! prompts.rs):
//!
//! - review: `list_unreviewed_days` → `get_daily_note_changes` → `search` →
//!   `create_note` (`role: topic`) → `add_excerpt` → `add_link` →
//!   `create_smart_folder` / `add_to_smart_folder` → `mark_day_reviewed` →
//!   the day leaves the list;
//! - capture: `append_to_daily_note` → `add_excerpt` the returned blocks →
//!   `mark_day_reviewed` with the returned content version, but only when
//!   `prior_state` was `Reviewed`.
//!
//! The person's daily notes are written through core with `Caller::Person`
//! before the server starts (an agent cannot create a daily note with
//! content). No embedding model is used; JSON is compared as parsed values.

#[path = "support/tool_names.rs"]
mod tool_names;

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use memex_core::canvas::Clock;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, NoteId, RenameOptions, UpdateNote,
};
use memex_core::review::{self, ChangeEntry};
use memex_core::{indexer, Caller, Vault};
use regex::Regex;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
/// Three blocks: "Fixed the jump arc.", "- tried coyote time", "Sleep was bad."
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const REVIEWED_AT: i64 = 1_759_500_000_000;

// ---------- harness: `memex serve` over stdio ----------

/// A `memex serve` subprocess spoken to over newline-delimited JSON-RPC.
struct Server {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: i64,
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
            next_id: 1,
        };
        let init = server.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi17-test", "version": "0" },
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

    /// Sends a request and returns the whole JSON-RPC response object.
    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
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

    fn tool_names(&mut self) -> Vec<String> {
        let resp = self.request("tools/list", json!({}));
        resp["result"]["tools"]
            .as_array()
            .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
            .iter()
            .map(|t| t["name"].as_str().expect("tool name").to_string())
            .collect()
    }

    /// Calls a tool and parses the JSON string it returns, rule errors
    /// (`{"error": …}`) included.
    fn call_raw(&mut self, name: &str, arguments: Value) -> Value {
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

    /// Like `call_raw`, but fails the test on an error object.
    fn call(&mut self, name: &str, arguments: Value) -> Value {
        let v = self.call_raw(name, arguments);
        assert!(v.get("error").is_none(), "{name} errored: {v}");
        v
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---------- the person's writes, through core before the server starts ----------

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// A person-written daily note, indexed as the app would.
fn person_daily(vault: &mut Vault, date: &str, body: &str) -> String {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(date.into()),
            content_md: body.into(),
            frontmatter: Some(json!({ "role": "daily" })),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create daily {date}: {e}"));
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note.id.to_string()
}

/// The person edits a daily note's body (a new content version).
fn person_edit(vault: &mut Vault, id: &str, body: &str) {
    let id = NoteId::parse(id).unwrap();
    let version = get_note(vault, &id).unwrap().version;
    update_note_as(
        vault,
        &id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person edit {id}: {e}"));
}

/// A review already done: the day is `Reviewed` at `version`.
fn person_reviewed(vault: &mut Vault, date: &str, id: &str, version: i64) {
    review::mark_day_reviewed(
        vault,
        date,
        version,
        &[ChangeEntry {
            note_id: id.to_string(),
            bullets: vec!["Filed 2 blocks into Player Loop".into()],
        }],
        &FixedClock(REVIEWED_AT),
    )
    .unwrap_or_else(|e| panic!("review {date}: {e}"));
}

/// Creates a temp vault, runs `setup` on it, closes it and returns its path.
fn vault_with(setup: impl FnOnce(&mut Vault)) -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    {
        let mut vault = Vault::create(&path).unwrap();
        setup(&mut vault);
    }
    let path = path.to_str().unwrap().to_string();
    (dir, path)
}

// ---------- small helpers over tool results ----------

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

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("`{key}` is not a string in {v}"))
}

fn ids_of(blocks: &Value) -> Vec<String> {
    blocks
        .as_array()
        .unwrap_or_else(|| panic!("expected a block array: {blocks}"))
        .iter()
        .map(|b| str_of(b, "id").to_string())
        .collect()
}

fn texts_of(blocks: &Value) -> Vec<String> {
    blocks
        .as_array()
        .unwrap_or_else(|| panic!("expected a block array: {blocks}"))
        .iter()
        .map(|b| str_of(b, "text").to_string())
        .collect()
}

fn create_topic(server: &mut Server, title: &str, summary: &str) -> String {
    let v = server.call(
        "create_note",
        json!({ "title": title, "content_md": summary, "role": "topic" }),
    );
    str_of(&v, "note_id").to_string()
}

fn list_dates(server: &mut Server) -> Vec<String> {
    let v = server.call("list_unreviewed_days", json!({}));
    v["days"]
        .as_array()
        .unwrap_or_else(|| panic!("days array: {v}"))
        .iter()
        .map(|d| str_of(d, "date").to_string())
        .collect()
}

/// What a finished review leaves behind.
struct Reviewed {
    daily_id: String,
    player_loop: String,
    level_design: String,
    day_bullets: Vec<String>,
    block_ids: Vec<String>,
}

/// The `review_daily_notes` prompt, step by step, on a person-written day.
/// Asserts each step's result on the way and returns the ids it touched.
fn run_review_sequence(server: &mut Server, daily_id: &str, vault_id_out: &mut String) -> Reviewed {
    // 1. list_unreviewed_days
    let listed = server.call("list_unreviewed_days", json!({}));
    *vault_id_out = str_of(&listed, "vault_id").to_string();
    assert_eq!(
        listed["days"],
        json!([{
            "date": DAY,
            "note_id": daily_id,
            "state": "Unreviewed",
            "content_version": 1,
            "reviewed_content_version": null,
        }]),
        "{listed}"
    );

    // 2. get_daily_note_changes
    let changes = server.call("get_daily_note_changes", json!({ "date": DAY }));
    assert_eq!(str_of(&changes, "note_id"), daily_id, "{changes}");
    assert_eq!(changes["content_version"], json!(1), "{changes}");
    assert_eq!(
        texts_of(&changes["added"]),
        vec![
            "Fixed the jump arc.".to_string(),
            "- tried coyote time".to_string(),
            "Sleep was bad.".to_string(),
        ],
        "a day never reviewed lists every block as added: {changes}"
    );
    assert_eq!(changes["changed"], json!([]), "{changes}");
    assert_eq!(changes["removed"], json!([]), "{changes}");
    let ids = ids_of(&changes["added"]);
    assert_eq!(ids.len(), 3, "{changes}");

    // 3. search before creating a topic note: nothing is a topic note yet.
    let found = server.call(
        "search",
        json!({ "query": "jump arc", "mode": "fts", "k": 5 }),
    );
    let hit_titles = found.to_string();
    assert!(
        !hit_titles.contains("Player Loop"),
        "no topic note exists before the review creates one: {found}"
    );

    // 4. create_note with role topic, twice.
    let player_loop = create_topic(
        server,
        "Player Loop",
        "The core movement loop of the player.",
    );
    let level_design = create_topic(server, "Level Design", "How levels are laid out.");
    assert_ne!(player_loop, level_design);

    // 5. add_excerpt into both topics (blocks 0..=1 as one range, block 2).
    let first = server.call(
        "add_excerpt",
        json!({ "topic_note_id": player_loop, "date": DAY, "block_ids": [ids[0], ids[1]] }),
    );
    assert_eq!(
        keys(&first),
        set(&["vault_id", "topic_note_id", "version"]),
        "{first}"
    );
    assert_eq!(str_of(&first, "topic_note_id"), player_loop, "{first}");
    let second = server.call(
        "add_excerpt",
        json!({ "topic_note_id": level_design, "date": DAY, "block_ids": [ids[2]] }),
    );
    assert_eq!(str_of(&second, "topic_note_id"), level_design, "{second}");

    // 6. add_link between the topics with kind extends.
    let link = server.call(
        "add_link",
        json!({ "from_id": player_loop, "to_id": level_design, "kind": "extends" }),
    );
    assert_eq!(str_of(&link, "from_id"), player_loop, "{link}");
    assert_eq!(str_of(&link, "to_id"), level_design, "{link}");

    // 7. create_smart_folder + add_to_smart_folder (both topics).
    let folder = server.call("create_smart_folder", json!({ "name": "Games" }));
    let folder_id = str_of(&folder, "id").to_string();
    assert_eq!(folder["pinned"], json!(false), "{folder}");
    for topic in [&player_loop, &level_design] {
        let added = server.call(
            "add_to_smart_folder",
            json!({ "topic_note_id": topic, "smart_folder_id": folder_id }),
        );
        assert_eq!(str_of(&added, "note_id"), topic.as_str(), "{added}");
    }

    // 8. mark_day_reviewed with the fetched version, one entry per touched
    // note including the daily note.
    let day_bullets = vec![
        "Filed 2 blocks into Player Loop".to_string(),
        "Filed 1 block into Level Design".to_string(),
    ];
    let marked = server.call(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [
                { "note_id": daily_id, "bullets": day_bullets },
                { "note_id": player_loop, "bullets": ["Linked to Level Design (extends)"] },
                { "note_id": level_design, "bullets": ["Added to Games"] },
            ],
        }),
    );
    assert_eq!(
        keys(&marked),
        set(&[
            "vault_id",
            "date",
            "note_id",
            "state",
            "content_version",
            "reviewed_content_version",
            "reviewed_at",
        ]),
        "{marked}"
    );
    assert_eq!(marked["state"], json!("Reviewed"), "{marked}");
    assert_eq!(marked["date"], json!(DAY), "{marked}");
    assert_eq!(str_of(&marked, "note_id"), daily_id, "{marked}");
    assert_eq!(marked["content_version"], json!(1), "{marked}");
    assert_eq!(marked["reviewed_content_version"], json!(1), "{marked}");

    Reviewed {
        daily_id: daily_id.to_string(),
        player_loop,
        level_design,
        day_bullets,
        block_ids: ids,
    }
}

fn day_vault() -> (TempDir, String, String) {
    let mut id = String::new();
    let (dir, path) = vault_with(|v| {
        id = person_daily(v, DAY, DAY_BODY);
    });
    (dir, path, id)
}

// ======================================================================
// The exact final tool list: every block of `support/tool_names.rs`, each once.
// ======================================================================

#[test]
fn server_lists_exactly_the_tools_in_the_shared_list_with_no_duplicates() {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Server::start(&path);
    let names = server.tool_names();

    let unique: BTreeSet<String> = names.iter().cloned().collect();
    assert_eq!(names.len(), unique.len(), "no duplicate tools: {names:?}");

    let expected: BTreeSet<String> = tool_names::all_tool_names()
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(
        expected.len(),
        tool_names::TOOL_COUNT,
        "the expected names are distinct"
    );
    assert_eq!(unique, expected, "the exact final tool list");
    assert_eq!(names.len(), tool_names::TOOL_COUNT, "{names:?}");

    // Prompts are not tools, and the Spec adds no MCP update or delete tool.
    for forbidden in [
        "review_daily_notes",
        "capture",
        "update_note",
        "delete_note",
        "merge_note",
    ] {
        assert!(!unique.contains(forbidden), "{forbidden} is not a tool");
    }
}

// ======================================================================
// AC 1: the review sequence over the served tools.
// ======================================================================

#[test]
fn review_sequence_files_excerpts_links_folders_and_the_day_leaves_the_list() {
    let (_dir, path, daily_id) = day_vault();
    let mut server = Server::start(&path);
    let mut vault_id = String::new();
    run_review_sequence(&mut server, &daily_id, &mut vault_id);

    assert_eq!(
        list_dates(&mut server),
        Vec::<String>::new(),
        "a Reviewed day no longer appears in list_unreviewed_days"
    );
    let after = server.call("list_unreviewed_days", json!({}));
    assert_eq!(after, json!({ "vault_id": vault_id, "days": [] }));
}

#[test]
fn review_sequence_puts_both_topics_in_the_smart_folder_and_links_them() {
    let (_dir, path, daily_id) = day_vault();
    let mut server = Server::start(&path);
    let mut vault_id = String::new();
    let done = run_review_sequence(&mut server, &daily_id, &mut vault_id);

    let folders = server.call("list_smart_folders", json!({}));
    let list = folders["folders"]
        .as_array()
        .unwrap_or_else(|| panic!("folders array: {folders}"));
    assert_eq!(list.len(), 1, "{folders}");
    assert_eq!(list[0]["name"], json!("Games"), "{folders}");
    let members = list[0]["members"].to_string();
    assert!(members.contains(&done.player_loop), "{folders}");
    assert!(members.contains(&done.level_design), "{folders}");
    let unsorted = folders["unsorted"].to_string();
    assert!(
        !unsorted.contains(&done.player_loop) && !unsorted.contains(&done.level_design),
        "both topic notes are placed: {folders}"
    );

    // The extends link is written into the source topic note as an `extends`
    // frontmatter shortcut naming the target.
    let topic = server.call("get_note", json!({ "note_id": done.player_loop }));
    let body = str_of(&topic, "content_md");
    assert!(
        body.contains("extends:") && body.contains("[[Level Design]]"),
        "{topic}"
    );
}

// ======================================================================
// AC 2: what get_note shows after the review.
// ======================================================================

#[test]
fn after_review_the_daily_note_shows_review_state_latest_change_and_topics_footer() {
    let (_dir, path, daily_id) = day_vault();
    let mut server = Server::start(&path);
    let mut vault_id = String::new();
    let done = run_review_sequence(&mut server, &daily_id, &mut vault_id);

    let note = server.call("get_note", json!({ "note_id": done.daily_id }));

    let review = &note["review"];
    assert_eq!(review["state"], json!("Reviewed"), "{note}");
    assert_eq!(review["content_version"], json!(1), "{note}");
    assert_eq!(review["reviewed_content_version"], json!(1), "{note}");
    assert!(review["reviewed_at"].is_i64(), "{note}");

    let latest = &note["latest_change"];
    assert_eq!(latest["day"], json!(DAY), "{note}");
    assert!(latest["created_at"].is_i64(), "{note}");
    assert_eq!(
        latest["bullets"],
        json!(done.day_bullets),
        "latest_change carries the daily note's own entry: {note}"
    );

    // The Topics footer: marker line, then one chip per topic, in filing order.
    let body = str_of(&note, "content_md");
    let marker = "<!-- memex:topics -->";
    let (person, footer) = body
        .split_once(marker)
        .unwrap_or_else(|| panic!("daily note carries the Topics marker: {body:?}"));
    assert_eq!(
        person, DAY_BODY,
        "the person section is untouched: {body:?}"
    );
    let chips: Vec<&str> = footer.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(
        chips,
        vec!["[[Player Loop~about]]", "[[Level Design~about]]"],
        "{body:?}"
    );
}

#[test]
fn after_review_the_topic_notes_render_the_excerpt_text() {
    let (_dir, path, daily_id) = day_vault();
    let mut server = Server::start(&path);
    let mut vault_id = String::new();
    let done = run_review_sequence(&mut server, &daily_id, &mut vault_id);

    let first = server.call("get_note", json!({ "note_id": done.player_loop }));
    let t1 = first["transclusions"]
        .as_array()
        .unwrap_or_else(|| panic!("transclusions: {first}"));
    assert_eq!(t1.len(), 1, "{first}");
    assert_eq!(t1[0]["date"], json!(DAY), "{first}");
    assert!(
        t1[0]["to"].is_string(),
        "two blocks join into one range: {first}"
    );
    assert_eq!(
        t1[0]["text"],
        json!("Fixed the jump arc.\n- tried coyote time"),
        "{first}"
    );
    let token = Regex::new(r"!\[\[2026-09-05#\^\w+\.\.\^\w+\]\]").unwrap();
    assert!(
        token.is_match(str_of(&first, "content_md")),
        "the topic body holds a transclusion, not a copy: {first}"
    );
    assert!(
        !str_of(&first, "content_md").contains("Fixed the jump arc."),
        "the person's text is not copied into the topic note: {first}"
    );

    let second = server.call("get_note", json!({ "note_id": done.level_design }));
    assert_eq!(
        second["transclusions"],
        json!([{
            "date": DAY,
            "from": done.block_ids[2],
            "to": null,
            "text": "Sleep was bad.",
        }]),
        "{second}"
    );
}

// ======================================================================
// AC 3: capture sequence on a Reviewed day.
// ======================================================================

#[test]
fn capture_on_a_reviewed_day_files_the_blocks_and_marks_the_day_reviewed() {
    let mut daily_id = String::new();
    let (_dir, path) = vault_with(|v| {
        daily_id = person_daily(v, DAY, DAY_BODY);
        person_reviewed(v, DAY, &daily_id, 1);
    });
    let mut server = Server::start(&path);
    assert_eq!(
        list_dates(&mut server),
        Vec::<String>::new(),
        "the day starts Reviewed"
    );

    // 1. append_to_daily_note.
    let appended = server.call(
        "append_to_daily_note",
        json!({ "text": "Idea: wall jump needs a longer grace window.", "date": DAY }),
    );
    assert_eq!(
        keys(&appended),
        set(&[
            "vault_id",
            "note_id",
            "date",
            "block_ids",
            "content_version",
            "version",
            "prior_state",
        ]),
        "{appended}"
    );
    assert_eq!(appended["prior_state"], json!("Reviewed"), "{appended}");
    assert_eq!(str_of(&appended, "note_id"), daily_id, "{appended}");
    assert_eq!(appended["date"], json!(DAY), "{appended}");
    assert_eq!(appended["content_version"], json!(2), "{appended}");
    let block_ids = appended["block_ids"].clone();
    assert_eq!(
        block_ids.as_array().map(|a| a.len()),
        Some(1),
        "one appended block: {appended}"
    );

    // The appended day is unreviewed again until the agent marks it.
    assert_eq!(list_dates(&mut server), vec![DAY.to_string()]);

    // 2. add_excerpt files the returned blocks into a topic note.
    let topic = create_topic(&mut server, "Player Loop", "The core movement loop.");
    let filed = server.call(
        "add_excerpt",
        json!({ "topic_note_id": topic, "date": appended["date"], "block_ids": block_ids }),
    );
    assert_eq!(str_of(&filed, "topic_note_id"), topic, "{filed}");

    // 3. prior_state was Reviewed: mark with the returned content version.
    let marked = server.call(
        "mark_day_reviewed",
        json!({
            "date": appended["date"],
            "version": appended["content_version"],
            "changes": [
                { "note_id": daily_id, "bullets": ["Filed 1 block into Player Loop"] },
                { "note_id": topic, "bullets": ["Filed 1 block"] },
            ],
        }),
    );
    assert_eq!(marked["state"], json!("Reviewed"), "{marked}");
    assert_eq!(marked["content_version"], json!(2), "{marked}");
    assert_eq!(marked["reviewed_content_version"], json!(2), "{marked}");

    let note = server.call("get_note", json!({ "note_id": daily_id }));
    assert_eq!(note["review"]["state"], json!("Reviewed"), "{note}");
    assert_eq!(
        list_dates(&mut server),
        Vec::<String>::new(),
        "the captured day is Reviewed"
    );
    let topic_note = server.call("get_note", json!({ "note_id": topic }));
    assert_eq!(
        topic_note["transclusions"][0]["text"],
        json!("Idea: wall jump needs a longer grace window."),
        "{topic_note}"
    );
}

// ======================================================================
// AC 4: capture sequence on a day with unfiled person edits.
// ======================================================================

/// A day reviewed at version 1, then edited by the person: block 3 now reads
/// "Sleep was fine." (content version 2, `Changed since review`).
fn changed_day_vault() -> (TempDir, String, String) {
    let mut daily_id = String::new();
    let (dir, path) = vault_with(|v| {
        daily_id = person_daily(v, DAY, DAY_BODY);
        person_reviewed(v, DAY, &daily_id, 1);
        person_edit(
            v,
            &daily_id,
            "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was fine.\n",
        );
    });
    (dir, path, daily_id)
}

#[test]
fn capture_on_a_day_with_unfiled_edits_reports_changed_since_review_and_lists_both_blocks() {
    let (_dir, path, daily_id) = changed_day_vault();
    let mut server = Server::start(&path);

    let listed = server.call("list_unreviewed_days", json!({}));
    assert_eq!(listed["days"][0]["state"], json!("Changed since review"));

    let appended = server.call(
        "append_to_daily_note",
        json!({ "text": "Coyote time at 6 frames felt right.", "date": DAY }),
    );
    assert_eq!(
        appended["prior_state"],
        json!("Changed since review"),
        "{appended}"
    );
    assert_eq!(str_of(&appended, "note_id"), daily_id, "{appended}");
    let appended_ids: Vec<String> = appended["block_ids"]
        .as_array()
        .unwrap_or_else(|| panic!("block_ids: {appended}"))
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(appended_ids.len(), 1, "{appended}");

    let changes = server.call("get_daily_note_changes", json!({ "date": DAY }));
    assert_eq!(
        changes["content_version"], appended["content_version"],
        "{changes}"
    );
    assert_eq!(
        ids_of(&changes["added"]),
        appended_ids,
        "the appended block is added: {changes}"
    );
    assert_eq!(
        texts_of(&changes["added"]),
        vec!["Coyote time at 6 frames felt right.".to_string()],
        "{changes}"
    );
    assert_eq!(
        texts_of(&changes["changed"]),
        vec!["Sleep was fine.".to_string()],
        "the person's edited block is listed with its current text: {changes}"
    );
    assert_eq!(changes["removed"], json!([]), "{changes}");
}

#[test]
fn capture_on_a_changed_day_runs_a_full_review_and_marks_with_the_changes_version() {
    let (_dir, path, daily_id) = changed_day_vault();
    let mut server = Server::start(&path);

    let appended = server.call(
        "append_to_daily_note",
        json!({ "text": "Coyote time at 6 frames felt right.", "date": DAY }),
    );
    assert_eq!(appended["prior_state"], json!("Changed since review"));

    // prior_state was not Reviewed, so the capture prompt runs a full review:
    // file every added and changed block, then mark with the version that
    // get_daily_note_changes returned.
    let changes = server.call("get_daily_note_changes", json!({ "date": DAY }));
    let mut to_file = ids_of(&changes["changed"]);
    to_file.extend(ids_of(&changes["added"]));
    assert_eq!(to_file.len(), 2, "{changes}");

    let topic = create_topic(&mut server, "Sleep", "Notes on sleep and the loop.");
    server.call(
        "add_excerpt",
        json!({ "topic_note_id": topic, "date": DAY, "block_ids": to_file }),
    );
    let marked = server.call(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [
                { "note_id": daily_id, "bullets": ["Filed 2 blocks into Sleep"] },
                { "note_id": topic, "bullets": ["Filed 2 blocks"] },
            ],
        }),
    );
    assert_eq!(marked["state"], json!("Reviewed"), "{marked}");
    assert_eq!(list_dates(&mut server), Vec::<String>::new());
}

// ======================================================================
// Error path inside the sequence: a stale version is rejected and the day
// stays unreviewed (the capture and review prompts both tell the agent to
// fetch the changes again).
// ======================================================================

#[test]
fn marking_with_a_version_older_than_the_appended_day_is_review_stale() {
    let mut daily_id = String::new();
    let (_dir, path) = vault_with(|v| {
        daily_id = person_daily(v, DAY, DAY_BODY);
        person_reviewed(v, DAY, &daily_id, 1);
    });
    let mut server = Server::start(&path);
    let appended = server.call(
        "append_to_daily_note",
        json!({ "text": "One more thought.", "date": DAY }),
    );
    assert_eq!(appended["content_version"], json!(2), "{appended}");

    // Version 1 is the reviewed version, not the appended day's.
    let stale = server.call_raw(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": 1,
            "changes": [{ "note_id": daily_id, "bullets": ["Nothing new to file"] }],
        }),
    );
    assert_eq!(stale["error"]["code"], json!("review_stale"), "{stale}");
    assert_eq!(stale["error"]["current"], json!(2), "{stale}");
    assert_eq!(list_dates(&mut server), vec![DAY.to_string()]);
}
