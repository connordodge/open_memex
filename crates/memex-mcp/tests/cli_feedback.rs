//! WI #256: `memex feedback add|edit|rm|ls` (the frozen Contract). Drives the
//! real `memex` binary against temp vaults; fixtures are built through core
//! with a stopped clock so row order is exact.
//!
//! - `memex feedback add --vault V --note-id N --date D --change-id C --text TEXT` -> Feedback
//! - `memex feedback edit --vault V --id F --text TEXT` -> Feedback
//! - `memex feedback rm --vault V --id F` -> `{vault_id, id}`
//! - `memex feedback ls --vault V (--note-id N | --no-note)` -> `{vault_id, feedback: [Feedback]}`,
//!   all statuses, newest first
//!
//! Feedback carries no `vault_id` (lead decision 1). Failures exit 1 with one C1
//! JSON line on stderr; a clap usage error exits 2.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::feedback::{self, Feedback};
use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::review::{self, ChangeEntry};
use memex_core::smart_folders::{self as sf, FolderUpdate};
use memex_core::{excerpts, Caller, Clock, Vault};
use regex::Regex;
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const T0: i64 = 1_790_000_000_000;
const HOUR: i64 = 3_600_000;
/// A valid ULID no note, entry or Feedback has.
const NO_SUCH_ID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

struct StoppedClock(i64);

impl Clock for StoppedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

struct World {
    _dir: TempDir,
    path: PathBuf,
    day: String,
    topic: String,
    other: String,
    /// The Activity entry on `day`.
    change: String,
    /// The Activity entry on `other`.
    other_change: String,
}

impl World {
    fn vault(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn open(&self) -> Vault {
        Vault::open(Path::new(&self.path)).unwrap()
    }

    fn vault_id(&self) -> String {
        self.open().vault_id().to_string()
    }

    /// An Open comment on the day's Activity entry, created at `at`.
    fn comment(&self, text: &str, at: i64) -> Feedback {
        feedback::add(
            &mut self.open(),
            &self.day,
            DAY,
            &self.change,
            text,
            &StoppedClock(at),
        )
        .unwrap()
    }

    fn handled(&self, id: &str) {
        feedback::resolve(&mut self.open(), id, "Done.", &[], &StoppedClock(T0 + HOUR)).unwrap();
    }

    /// A person's Correction on the day; its `created_at` is the wall clock.
    fn correction(&self) -> Feedback {
        let block: String = self
            .open()
            .connection_ref()
            .query_row(
                "SELECT block_id FROM blocks WHERE note_id = ? AND ord = 0",
                [self.day.as_str()],
                |r| r.get(0),
            )
            .unwrap();
        excerpts::add_excerpt_noted(
            &mut self.open(),
            &NoteId::parse(&self.topic).unwrap(),
            DAY,
            &[block],
            Caller::Person,
            None,
            Some("Why."),
        )
        .unwrap();
        let rows = feedback::list_for_note(&self.open(), Some(&self.day)).unwrap();
        rows.into_iter().find(|r| r.kind == "correction").unwrap()
    }

    /// An open tag Correction; returns its `tag-<n>` id.
    fn tag_correction(&self, note: Option<&str>, created_at: i64) -> String {
        let vault = self.open();
        vault
            .connection_ref()
            .execute(
                "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at, cleared_at)
                 VALUES (?, 'Gone', 'game-feel', 'removed', ?, NULL)",
                params![note, created_at],
            )
            .unwrap();
        format!("tag-{}", vault.connection_ref().last_insert_rowid())
    }
}

fn create(vault: &mut Vault, title: &str, body: &str, role: &str) -> String {
    let note = notes::create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(json!({ "role": role })),
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

/// A vault with a reviewed day, a topic and another topic, with one Activity
/// entry each on the day and on the other topic.
fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let mut vault = Vault::create(&path).unwrap();
    let day = create(&mut vault, DAY, DAY_BODY, "daily");
    let topic = create(&mut vault, "Player Loop", "The loop.\n", "topic");
    let other = create(&mut vault, "Economy Design", "Sinks.\n", "topic");
    let version: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [day.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    review::mark_day_reviewed(
        &mut vault,
        DAY,
        version,
        &[
            ChangeEntry {
                note_id: day.clone(),
                bullets: vec!["Filed the jump notes".into()],
            },
            ChangeEntry {
                note_id: other.clone(),
                bullets: vec!["Linked the sinks".into()],
            },
        ],
        &StoppedClock(T0),
    )
    .unwrap();
    let change_of = |note: &str| -> String {
        vault
            .connection_ref()
            .query_row(
                "SELECT id FROM agent_changes WHERE note_id = ?",
                [note],
                |r| r.get(0),
            )
            .unwrap()
    };
    let change = change_of(&day);
    let other_change = change_of(&other);
    drop(vault);
    World {
        _dir: dir,
        path,
        day,
        topic,
        other,
        change,
        other_change,
    }
}

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Exit 0 and exactly one JSON line on stdout.
fn ok_json(out: Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "exit 0; {}", describe(&out));
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

/// Exit 1, nothing on stdout and one C1 JSON line on stderr with `code`.
fn assert_c1_failure(out: &Output, code: &str) {
    assert_eq!(out.status.code(), Some(1), "exits 1; {}", describe(out));
    assert!(out.stdout.is_empty(), "no output; {}", describe(out));
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be one line; {}",
        describe(out)
    );
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)));
    assert_eq!(v["error"]["code"], json!(code), "{v}");
    assert!(v["error"]["message"].is_string(), "{v}");
}

fn add(w: &World, note: &str, date: &str, change: &str, text: &str) -> Output {
    run(&[
        "feedback",
        "add",
        "--vault",
        w.vault(),
        "--note-id",
        note,
        "--date",
        date,
        "--change-id",
        change,
        "--text",
        text,
    ])
}

fn edit(w: &World, id: &str, text: &str) -> Output {
    run(&[
        "feedback",
        "edit",
        "--vault",
        w.vault(),
        "--id",
        id,
        "--text",
        text,
    ])
}

fn rm(w: &World, id: &str) -> Output {
    run(&["feedback", "rm", "--vault", w.vault(), "--id", id])
}

fn ls_note(w: &World, note: &str) -> Output {
    run(&["feedback", "ls", "--vault", w.vault(), "--note-id", note])
}

fn ls_no_note(w: &World) -> Output {
    run(&["feedback", "ls", "--vault", w.vault(), "--no-note"])
}

/// Every Feedback row in the store, as `(id, text, status)`.
fn stored(w: &World) -> Vec<(String, Option<String>, String)> {
    w.open()
        .connection_ref()
        .prepare("SELECT id, text, status FROM feedback ORDER BY rowid")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// The `id`s of a `feedback ls` output, in order, after checking its envelope.
fn listed_ids(w: &World, got: &Value) -> Vec<String> {
    let keys: Vec<&String> = got.as_object().expect("an object").keys().collect();
    assert_eq!(keys, ["feedback", "vault_id"], "{got}");
    assert_eq!(got["vault_id"], json!(w.vault_id()), "{got}");
    got["feedback"]
        .as_array()
        .expect("a list")
        .iter()
        .map(|r| r["id"].as_str().expect("a string id").to_string())
        .collect()
}

// ---------- AC 1: the output objects ----------

#[test]
fn feedback_add_prints_the_contract_object() {
    let w = world();
    let before = memex_core::now_unix_ms();

    let got = ok_json(add(&w, &w.day, DAY, &w.change, "  Wrong topic, this.\n"));

    let after = memex_core::now_unix_ms();
    let id = got["id"].as_str().expect("an id").to_string();
    let ulid = Regex::new(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$").unwrap();
    assert!(ulid.is_match(&id), "the id is a ULID: {id}");
    let created = got["created_at"].as_i64().expect("created_at is a number");
    assert!(
        (before..=after).contains(&created),
        "{before} <= {created} <= {after}"
    );
    assert_eq!(
        got,
        json!({
            "id": id,
            "kind": "comment",
            "source": "person",
            "note_id": w.day,
            "day": DAY,
            "agent_change_id": w.change,
            "text": "  Wrong topic, this.\n",
            "correction": null,
            "status": "open",
            "reply": null,
            "created_at": created,
            "updated_at": created,
            "handled_at": null,
        })
    );
    assert_eq!(stored(&w).len(), 1, "one row stored");
}

#[test]
fn feedback_edit_prints_the_contract_object_with_the_new_text() {
    let w = world();
    let row = w.comment("First words.", T0);

    let got = ok_json(edit(&w, &row.id, "Better words."));

    let updated = got["updated_at"].as_i64().expect("updated_at is a number");
    assert_ne!(updated, T0, "the edit stamps the wall clock: {got}");
    assert_eq!(
        got,
        json!({
            "id": row.id,
            "kind": "comment",
            "source": "person",
            "note_id": w.day,
            "day": DAY,
            "agent_change_id": w.change,
            "text": "Better words.",
            "correction": null,
            "status": "open",
            "reply": null,
            "created_at": T0,
            "updated_at": updated,
            "handled_at": null,
        })
    );
    assert_eq!(
        stored(&w)[0].1.as_deref(),
        Some("Better words."),
        "the store has the new text"
    );
}

#[test]
fn feedback_rm_prints_vault_id_and_id_and_deletes_the_row() {
    let w = world();
    let keep = w.comment("Keep me.", T0);
    let row = w.comment("Remove me.", T0 + 1);

    let got = ok_json(rm(&w, &row.id));

    assert_eq!(got, json!({ "vault_id": w.vault_id(), "id": row.id }));
    let left: Vec<String> = stored(&w).into_iter().map(|r| r.0).collect();
    assert_eq!(left, [keep.id]);
}

#[test]
fn feedback_ls_prints_vault_id_and_full_feedback_rows() {
    let w = world();
    let open = w.comment("An open comment.", T0);

    let got = ok_json(ls_note(&w, &w.day));

    assert_eq!(
        got,
        json!({
            "vault_id": w.vault_id(),
            "feedback": [{
                "id": open.id,
                "kind": "comment",
                "source": "person",
                "note_id": w.day,
                "day": DAY,
                "agent_change_id": w.change,
                "text": "An open comment.",
                "correction": null,
                "status": "open",
                "reply": null,
                "created_at": T0,
                "updated_at": T0,
                "handled_at": null,
            }],
        })
    );
}

/// The Contract: `correction` is the parsed object, never a JSON string, and a
/// Handled row carries its reply and `handled_at`.
#[test]
fn feedback_ls_shows_a_correction_as_an_object_and_a_handled_row_with_its_reply() {
    let w = world();
    let correction = w.correction();
    let handled = w.comment("Handle me.", T0);
    w.handled(&handled.id);

    let got = ok_json(ls_note(&w, &w.day));

    let rows = got["feedback"].as_array().expect("a list");
    let row = |id: &str| rows.iter().find(|r| r["id"] == json!(id)).unwrap();
    let c = row(&correction.id);
    assert_eq!(c["kind"], json!("correction"), "{c}");
    assert_eq!(c["text"], json!("Why."), "{c}");
    assert_eq!(c["correction"]["kind"], json!("excerpt_added"), "{c}");
    assert_eq!(c["correction"]["title"], json!("Player Loop"), "{c}");
    let h = row(&handled.id);
    assert_eq!(h["status"], json!("handled"), "{h}");
    assert_eq!(h["reply"], json!("Done."), "{h}");
    assert_eq!(h["handled_at"], json!(T0 + HOUR), "{h}");
}

// ---------- AC 2: failures ----------

#[test]
fn feedback_add_failures_exit_nonzero_with_their_c1_codes() {
    let w = world();
    let long = "x".repeat(2001);

    assert_c1_failure(&add(&w, &w.day, DAY, &w.change, ""), "feedback_invalid");
    assert_c1_failure(
        &add(&w, &w.day, DAY, &w.change, " \n\t "),
        "feedback_invalid",
    );
    assert_c1_failure(&add(&w, &w.day, DAY, &w.change, &long), "feedback_invalid");
    assert_c1_failure(
        &add(&w, &w.day, "2026-13-01", &w.change, "Text."),
        "invalid_date",
    );
    assert_c1_failure(&add(&w, NO_SUCH_ID, DAY, &w.change, "Text."), "not_found");
    assert_c1_failure(&add(&w, &w.day, DAY, NO_SUCH_ID, "Text."), "not_found");
    // An Activity entry of another note is no entry of this one.
    assert_c1_failure(&add(&w, &w.day, DAY, &w.other_change, "Text."), "not_found");

    assert!(stored(&w).is_empty(), "no failure stored anything");
}

#[test]
fn feedback_add_takes_exactly_the_longest_allowed_comment() {
    let w = world();
    let longest = "\u{2603}".repeat(2000);

    let got = ok_json(add(&w, &w.day, DAY, &w.change, &longest));

    assert_eq!(got["text"], json!(longest));
}

#[test]
fn feedback_edit_failures_exit_nonzero_with_their_c1_codes() {
    let w = world();
    let open = w.comment("Open.", T0);
    let handled = w.comment("Handled.", T0 + 1);
    w.handled(&handled.id);
    let correction = w.correction();
    let tag = w.tag_correction(Some(&w.day), T0 + 2);
    let before = stored(&w);

    assert_c1_failure(&edit(&w, NO_SUCH_ID, "New."), "not_found");
    assert_c1_failure(&edit(&w, &handled.id, "New."), "feedback_handled");
    assert_c1_failure(&edit(&w, &correction.id, "New."), "feedback_invalid");
    assert_c1_failure(&edit(&w, &tag, "New."), "feedback_invalid");
    assert_c1_failure(&edit(&w, &open.id, "  "), "feedback_invalid");
    assert_c1_failure(&edit(&w, &open.id, &"x".repeat(2001)), "feedback_invalid");

    assert_eq!(stored(&w), before, "no failure changed anything");
}

#[test]
fn feedback_rm_failures_exit_nonzero_with_their_c1_codes() {
    let w = world();
    let handled = w.comment("Handled.", T0);
    w.handled(&handled.id);
    let correction = w.correction();
    let tag = w.tag_correction(Some(&w.day), T0 + 2);
    let before = stored(&w);

    assert_c1_failure(&rm(&w, NO_SUCH_ID), "not_found");
    assert_c1_failure(&rm(&w, &handled.id), "feedback_handled");
    assert_c1_failure(&rm(&w, &correction.id), "feedback_invalid");
    assert_c1_failure(&rm(&w, &tag), "feedback_invalid");

    assert_eq!(stored(&w), before, "no failure changed anything");
}

#[test]
fn feedback_rm_of_a_removed_comment_is_not_found() {
    let w = world();
    let row = w.comment("Remove me.", T0);

    ok_json(rm(&w, &row.id));

    assert_c1_failure(&rm(&w, &row.id), "not_found");
}

// ---------- AC 4: `feedback ls` ----------

#[test]
fn feedback_ls_note_id_returns_that_notes_rows_newest_first_with_all_statuses() {
    let w = world();
    let now = memex_core::now_unix_ms();
    // Oldest first: a handled comment, a person's Correction (wall clock), an
    // open comment, a chat comment, an open tag Correction.
    let handled = w.comment("Handled.", now - 3 * HOUR);
    w.handled(&handled.id);
    let correction = w.correction();
    let open = w.comment("Open.", now + HOUR);
    let chat = feedback::record_chat(
        &mut w.open(),
        "Said in chat.",
        Some(&w.day),
        Some(DAY),
        "Fixed it.",
        &[],
        &StoppedClock(now + 2 * HOUR),
    )
    .unwrap();
    let tag = w.tag_correction(Some(&w.day), now + 3 * HOUR);
    // None of these are the day's.
    feedback::add(
        &mut w.open(),
        &w.other,
        DAY,
        &w.other_change,
        "On another note.",
        &StoppedClock(now + 4 * HOUR),
    )
    .unwrap();
    feedback::record_chat(
        &mut w.open(),
        "On no note.",
        None,
        None,
        "Noted.",
        &[],
        &StoppedClock(now + 5 * HOUR),
    )
    .unwrap();
    w.tag_correction(Some(&w.other), now + 6 * HOUR);

    let got = ok_json(ls_note(&w, &w.day));

    assert_eq!(
        listed_ids(&w, &got),
        [tag, chat.id, open.id, correction.id, handled.id]
    );
    let statuses: Vec<&str> = got["feedback"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["status"].as_str().unwrap())
        .collect();
    assert_eq!(statuses, ["open", "handled", "open", "open", "handled"]);
}

#[test]
fn feedback_ls_no_note_returns_only_rows_with_no_note_newest_first() {
    let w = world();
    let now = memex_core::now_unix_ms();
    // Feedback whose note was deleted lists here, with its row intact.
    let orphan = feedback::add(
        &mut w.open(),
        &w.other,
        DAY,
        &w.other_change,
        "On a note about to go.",
        &StoppedClock(now - 3 * HOUR),
    )
    .unwrap();
    let orphan_tag = w.tag_correction(Some(&w.other), now - 2 * HOUR);
    let version: i64 = w
        .open()
        .connection_ref()
        .query_row(
            "SELECT version FROM notes WHERE id = ?",
            [w.other.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    ok_json(run(&[
        "rm",
        "--vault",
        w.vault(),
        "--note-id",
        &w.other,
        "--expected-version",
        &version.to_string(),
    ]));
    // A person renaming a folder the agent made: a Correction with no note.
    let folder = sf::create_folder(
        &mut w.open(),
        "Inbox",
        None,
        Caller::Agent,
        &StoppedClock(T0),
    )
    .unwrap();
    sf::update_folder(
        &mut w.open(),
        &folder.id,
        FolderUpdate {
            name: Some("Outbox".into()),
            ..Default::default()
        },
        Caller::Person,
        &StoppedClock(now - HOUR),
    )
    .unwrap();
    let chat = feedback::record_chat(
        &mut w.open(),
        "On no note.",
        None,
        None,
        "Noted.",
        &[],
        &StoppedClock(now + HOUR),
    )
    .unwrap();
    // These have a note.
    w.comment("On the day.", now + 2 * HOUR);
    w.tag_correction(Some(&w.day), now + 3 * HOUR);

    let got = ok_json(ls_no_note(&w));

    let ids = listed_ids(&w, &got);
    assert_eq!(ids.len(), 4, "{got}");
    assert_eq!(ids[0], chat.id, "{got}");
    assert_eq!(
        got["feedback"][1]["correction"]["kind"],
        json!("folder_renamed"),
        "{got}"
    );
    assert_eq!(ids[2], orphan_tag, "{got}");
    assert_eq!(ids[3], orphan.id, "{got}");
    assert_eq!(got["feedback"][3]["note_id"], Value::Null, "{got}");
    assert_eq!(
        got["feedback"][3]["text"],
        json!("On a note about to go."),
        "{got}"
    );
    assert_eq!(got["feedback"][2]["note_id"], Value::Null, "{got}");
}

#[test]
fn feedback_ls_of_a_note_with_no_rows_is_an_empty_list() {
    let w = world();
    w.comment("On the day.", T0);

    assert_eq!(
        ok_json(ls_note(&w, &w.topic)),
        json!({ "vault_id": w.vault_id(), "feedback": [] })
    );
}

/// Lead decision 8b: an id no note has lists nothing, as core's read does.
#[test]
fn feedback_ls_of_an_unknown_note_id_is_an_empty_list() {
    let w = world();
    w.comment("On the day.", T0);

    assert_eq!(
        ok_json(ls_note(&w, NO_SUCH_ID)),
        json!({ "vault_id": w.vault_id(), "feedback": [] })
    );
}

/// Lead decision 8b: an empty `--note-id` is refused, never the no-note list.
#[test]
fn feedback_ls_with_an_empty_note_id_is_invalid_argument() {
    let w = world();
    feedback::record_chat(
        &mut w.open(),
        "On no note.",
        None,
        None,
        "Noted.",
        &[],
        &StoppedClock(T0),
    )
    .unwrap();
    assert_eq!(
        listed_ids(&w, &ok_json(ls_no_note(&w))).len(),
        1,
        "precondition: a no-note row to leak"
    );

    assert_c1_failure(&ls_note(&w, ""), "invalid_argument");
}

/// Lead decision 2: exactly one of `--note-id` and `--no-note`.
#[test]
fn feedback_ls_needs_exactly_one_of_note_id_and_no_note() {
    let w = world();
    ok_json(ls_no_note(&w));

    let neither = run(&["feedback", "ls", "--vault", w.vault()]);
    assert_eq!(neither.status.code(), Some(2), "{}", describe(&neither));
    let both = run(&[
        "feedback",
        "ls",
        "--vault",
        w.vault(),
        "--note-id",
        &w.day,
        "--no-note",
    ]);
    assert_eq!(both.status.code(), Some(2), "{}", describe(&both));
}
