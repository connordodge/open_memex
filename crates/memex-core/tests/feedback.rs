//! WI #250 (F2): the Feedback store and the Correction hooks in core.
//!
//! Spec #233 R1-R5a, R12, R13, R18-R23, R40, R41, TD1-TD3, TD7; rulings D4-D7a,
//! D14; correction shapes in the Contract of #256.
//!
//! The hook tests read `feedback` with raw SQL and assert `count(*)`, so a
//! listing bug can't hide a recording bug and an extra row always fails. Real
//! SQLite, real schema V6, temp vaults only. Tag fixtures are raw SQL: #234's
//! write path has no hook into Feedback (D4).

use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{DateTime, FixedOffset};
use memex_core::daily::{self, ReviewState};
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::excerpts::{
    add_excerpt, add_excerpt_noted, add_excerpt_with_hook, move_block, move_block_noted,
    move_block_with_hook, remove_excerpt, remove_excerpt_block, remove_excerpt_block_noted,
    remove_excerpt_block_with_hook, remove_excerpt_with_hook,
};
use memex_core::feedback::{self, Feedback};
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, delete_note_checked, get_note, update_note_as, CreateNote, Note, NoteId,
    RenameOptions, UpdateNote,
};
use memex_core::review::{self, ChangeEntry};
use memex_core::smart_folders::{self as sf, FolderUpdate, NewParent};
use memex_core::{Caller, CallerClock, Clock, MemexError, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const DAY: &str = "2026-09-05";
/// The C4 fixture day: blocks (0, b7k2m9), (1, c3d4e5), (2, f6g7h8).
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const B7: &str = "b7k2m9";
const C3: &str = "c3d4e5";
const F6: &str = "f6g7h8";
const B7_TEXT: &str = "Fixed the jump arc.";
const C3_TEXT: &str = "- tried coyote time";
const F6_TEXT: &str = "Sleep was bad.";

const TOPIC: &str = "Player Loop";
const OTHER: &str = "Sleep";

const T0: i64 = 1_759_500_000_000;
/// A well-formed id nothing in a fresh vault has.
const UNKNOWN: &str = "01ARZ3NDEKTSV4RRFFQ69G5FAV";

struct FakeClock(Cell<i64>);

impl FakeClock {
    fn at(ms: i64) -> Self {
        Self(Cell::new(ms))
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.get()
    }
}

struct World {
    _dir: TempDir,
    vault: Vault,
    day: NoteId,
    topic: NoteId,
    other: NoteId,
}

/// A vault with the fixture day and the topic notes `Player Loop` and `Sleep`.
fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let day = create_day(&mut vault, DAY, DAY_BODY, &[B7, C3, F6]);
    let topic = create_topic(&mut vault, TOPIC);
    let other = create_topic(&mut vault, OTHER);
    World {
        _dir: dir,
        vault,
        day,
        topic,
        other,
    }
}

fn create(vault: &mut Vault, title: &str, body: &str, fm: Value) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(fm),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    reindex(vault, &note);
    note
}

fn create_topic(vault: &mut Vault, title: &str) -> NoteId {
    let body = format!("About {title}.\n");
    create(vault, title, &body, json!({ "role": "topic" })).id
}

/// A daily note whose stored block ids are pinned to `ids` by ord.
fn create_day(vault: &mut Vault, date: &str, body: &str, ids: &[&str]) -> NoteId {
    let note = create(vault, date, body, json!({ "role": "daily" }));
    for (ord, id) in ids.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, note.id.as_str(), ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "{date}: block at ord {ord}");
    }
    note.id
}

fn reindex(vault: &mut Vault, note: &Note) {
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
}

fn ids(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// `add_excerpt`, which must succeed.
fn file(v: &mut Vault, topic: &NoteId, blocks: &[&str], caller: Caller) {
    add_excerpt(v, topic, DAY, &ids(blocks), caller, None)
        .unwrap_or_else(|e| panic!("add_excerpt {blocks:?}: {e}"));
}

/// `remove_excerpt`, which must succeed.
fn unfile(v: &mut Vault, topic: &NoteId, blocks: &[&str], caller: Caller) {
    remove_excerpt(v, topic, DAY, &ids(blocks), caller, None)
        .unwrap_or_else(|e| panic!("remove_excerpt {blocks:?}: {e}"));
}

/// `remove_excerpt_block`, which must succeed.
fn unfile_block(v: &mut Vault, topic: &NoteId, block: &str, caller: Caller) {
    remove_excerpt_block(v, topic, DAY, block, caller, None)
        .unwrap_or_else(|e| panic!("remove_excerpt_block {block}: {e}"));
}

/// `move_block`, which must succeed.
fn shift(v: &mut Vault, block: &str, from: &NoteId, to: &NoteId, caller: Caller) {
    move_block(v, DAY, block, from, to, caller, None)
        .unwrap_or_else(|e| panic!("move_block {block}: {e}"));
}

/// A person save of `id`'s body, mapped through `edit`, reindexed.
fn person_write(v: &mut Vault, id: &NoteId, edit: impl FnOnce(&str) -> String) -> Note {
    let current = get_note(v, id).unwrap();
    let saved = update_note_as(
        v,
        id,
        current.version,
        UpdateNote {
            content_md: Some(edit(&current.content_md)),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person save of {id}: {e}"));
    reindex(v, &saved);
    saved
}

/// A person save that makes a racing excerpt write's expected version stale.
fn race(v: &mut Vault, id: &NoteId, n: usize) {
    person_write(v, id, |body| format!("{body}Edit {n}.\n"));
}

fn rename_note(v: &mut Vault, id: &NoteId, title: &str) {
    let current = get_note(v, id).unwrap();
    update_note_as(
        v,
        id,
        current.version,
        UpdateNote {
            title: Some(title.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("rename {id}: {e}"));
}

fn delete_note(v: &mut Vault, id: &NoteId) {
    let version = get_note(v, id).unwrap().version;
    delete_note_checked(v, id, version, None).unwrap_or_else(|e| panic!("delete {id}: {e}"));
}

/// One `feedback` row, read with raw SQL.
#[derive(Debug, Clone, PartialEq)]
struct Row {
    id: String,
    kind: String,
    source: String,
    note_id: Option<String>,
    day: Option<String>,
    agent_change_id: Option<String>,
    text: Option<String>,
    correction: Option<Value>,
    status: String,
    reply: Option<String>,
    tag_correction_id: Option<i64>,
    created_at: i64,
    updated_at: i64,
    handled_at: Option<i64>,
}

/// Every `feedback` row in insertion order.
fn rows(v: &Vault) -> Vec<Row> {
    v.connection_ref()
        .prepare(
            "SELECT id, kind, source, note_id, day, agent_change_id, text, correction_json,
                    status, reply, tag_correction_id, created_at, updated_at, handled_at
             FROM feedback ORDER BY rowid",
        )
        .unwrap()
        .query_map([], |r| {
            let json: Option<String> = r.get(7)?;
            Ok(Row {
                id: r.get(0)?,
                kind: r.get(1)?,
                source: r.get(2)?,
                note_id: r.get(3)?,
                day: r.get(4)?,
                agent_change_id: r.get(5)?,
                text: r.get(6)?,
                correction: json.map(|j| serde_json::from_str(&j).unwrap()),
                status: r.get(8)?,
                reply: r.get(9)?,
                tag_correction_id: r.get(10)?,
                created_at: r.get(11)?,
                updated_at: r.get(12)?,
                handled_at: r.get(13)?,
            })
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn count(v: &Vault) -> i64 {
    v.connection_ref()
        .query_row("SELECT count(*) FROM feedback", [], |r| r.get(0))
        .unwrap()
}

/// The `correction.kind` of every row in insertion order.
fn kinds(v: &Vault) -> Vec<String> {
    rows(v)
        .iter()
        .map(|r| {
            r.correction.as_ref().expect("a Correction")["kind"]
                .as_str()
                .expect("a kind")
                .to_string()
        })
        .collect()
}

/// The only row, which must be an Open person Correction.
fn only_correction(v: &Vault) -> Row {
    let all = rows(v);
    assert_eq!(all.len(), 1, "exactly one row: {all:?}");
    let row = all.into_iter().next().unwrap();
    assert_open_correction(&row);
    row
}

fn assert_open_correction(row: &Row) {
    assert_eq!(row.kind, "correction", "{row:?}");
    assert_eq!(row.source, "person", "{row:?}");
    assert_eq!(row.status, "open", "{row:?}");
    assert_eq!(row.reply, None, "{row:?}");
    assert_eq!(row.handled_at, None, "{row:?}");
    assert_eq!(row.tag_correction_id, None, "{row:?}");
    assert_eq!(row.created_at, row.updated_at, "{row:?}");
    assert!(row.created_at > 0, "{row:?}");
    assert!(ulid::Ulid::from_string(&row.id).is_ok(), "{row:?}");
}

/// Marks every Open row Handled with raw SQL, so the hook tests don't depend
/// on `feedback::resolve`.
fn handle_all(v: &Vault) {
    v.connection_ref()
        .execute(
            "UPDATE feedback SET status = 'handled', reply = 'Noted.', handled_at = updated_at
             WHERE status = 'open'",
            [],
        )
        .unwrap();
}

fn handle(v: &Vault, id: &str) {
    let n = v
        .connection_ref()
        .execute(
            "UPDATE feedback SET status = 'handled', reply = 'Noted.', handled_at = updated_at
             WHERE id = ?",
            [id],
        )
        .unwrap();
    assert_eq!(n, 1, "handle {id}");
}

/// Inserts an `agent_changes` row; returns `id`.
fn change(v: &Vault, id: &str, note: &str, day: &str, created_at: i64) -> String {
    v.connection_ref()
        .execute(
            "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES (?, ?, ?, ?, '[\"Filed\"]')",
            params![id, note, day, created_at],
        )
        .unwrap();
    id.to_string()
}

/// `(note_id, day, created_at, bullets)` of every `agent_changes` row.
fn agent_changes(v: &Vault) -> Vec<(String, String, i64, Vec<String>)> {
    v.connection_ref()
        .prepare("SELECT note_id, day, created_at, bullets_json FROM agent_changes ORDER BY rowid")
        .unwrap()
        .query_map([], |r| {
            let bullets: String = r.get(3)?;
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                serde_json::from_str(&bullets).unwrap(),
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn entry(note: &NoteId, bullets: &[&str]) -> ChangeEntry {
    ChangeEntry {
        note_id: note.as_str().to_string(),
        bullets: bullets.iter().map(|b| b.to_string()).collect(),
    }
}

/// An Open comment on the day note, on a fresh Activity entry, at `at`.
fn comment_at(w: &mut World, text: &str, at: i64) -> Feedback {
    let change_id = ulid::Ulid::new().to_string();
    change(&w.vault, &change_id, w.day.as_str(), DAY, at);
    feedback::add(
        &mut w.vault,
        w.day.as_str(),
        DAY,
        &change_id,
        text,
        &FakeClock::at(at),
    )
    .unwrap_or_else(|e| panic!("add: {e}"))
}

/// Inserts a `tag_corrections` row; returns its id.
fn tag_correction(
    v: &Vault,
    note: Option<&str>,
    title: &str,
    tag: &str,
    created_at: i64,
    cleared_at: Option<i64>,
) -> i64 {
    v.connection_ref()
        .execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at, cleared_at)
             VALUES (?, ?, ?, 'removed', ?, ?)",
            params![note, title, tag, created_at, cleared_at],
        )
        .unwrap();
    v.connection_ref().last_insert_rowid()
}

fn clear_tag(v: &Vault, id: i64, at: i64) {
    v.connection_ref()
        .execute(
            "UPDATE tag_corrections SET cleared_at = ? WHERE id = ?",
            params![at, id],
        )
        .unwrap();
}

fn folder(v: &mut Vault, name: &str, parent: Option<&str>, caller: Caller) -> String {
    sf::create_folder(v, name, parent, caller, &FakeClock::at(T0))
        .unwrap_or_else(|e| panic!("create_folder {name}: {e}"))
        .id
}

fn rename_update(name: &str) -> FolderUpdate {
    FolderUpdate {
        name: Some(name.into()),
        ..Default::default()
    }
}

fn move_update(parent: NewParent) -> FolderUpdate {
    FolderUpdate {
        parent: Some(parent),
        ..Default::default()
    }
}

fn pin_update(pinned: bool) -> FolderUpdate {
    FolderUpdate {
        pinned: Some(pinned),
        ..Default::default()
    }
}

/// `update_folder` at `T0`, which must succeed.
fn update(v: &mut Vault, id: &str, u: FolderUpdate, caller: Caller) {
    sf::update_folder(v, id, u, caller, &FakeClock::at(T0))
        .unwrap_or_else(|e| panic!("update_folder {id}: {e}"));
}

fn member(v: &mut Vault, folder: &str, note: &NoteId, caller: Caller) {
    sf::add_member(v, folder, note.as_str(), None, caller, None)
        .unwrap_or_else(|e| panic!("add_member {note}: {e}"));
}

fn code_of<T: std::fmt::Debug>(r: memex_core::Result<T>, what: &str) -> String {
    match r {
        Ok(v) => panic!("{what}: should fail, returned {v:?}"),
        Err(e) => e.code().to_string(),
    }
}

/// Makes every later INSERT into `table` fail.
fn fail_inserts_into(v: &Vault, table: &str) {
    v.connection_ref()
        .execute_batch(&format!(
            "CREATE TRIGGER fail_{table} BEFORE INSERT ON {table}
             BEGIN SELECT RAISE(ABORT, 'injected failure'); END;"
        ))
        .unwrap();
}

/// An RFC 3339 instant as Unix milliseconds.
fn instant(rfc3339: &str) -> i64 {
    DateTime::parse_from_rfc3339(rfc3339)
        .unwrap()
        .timestamp_millis()
}

/// A [`FakeEmbedder`] that fails the calls numbered in `failing` (1-based).
struct FlakyEmbedder {
    inner: FakeEmbedder,
    failing: Vec<usize>,
    calls: AtomicUsize,
}

impl FlakyEmbedder {
    fn failing_calls(failing: &[usize]) -> Self {
        Self {
            inner: FakeEmbedder::new(8),
            failing: failing.to_vec(),
            calls: AtomicUsize::new(0),
        }
    }
}

impl Embedder for FlakyEmbedder {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        if self.failing.contains(&call) {
            return Err(MemexError::EmbedderInfer(format!("call {call} fails")));
        }
        self.inner.embed_batch(texts)
    }
}

// ---------------------------------------------------------------------------
// AC 1: remove_excerpt, remove_excerpt_block and person file
// ---------------------------------------------------------------------------

#[test]
fn person_remove_and_file_record_one_correction_each_and_an_agent_records_zero() {
    // A person's file.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);
    assert_eq!(count(&w.vault), 1);

    // A person's remove_excerpt of the agent's excerpt.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    assert_eq!(count(&w.vault), 0, "the agent's file records nothing");
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_removed"]);
    assert_eq!(count(&w.vault), 1);

    // A person's remove_excerpt_block of the agent's excerpt.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_removed"]);
    assert_eq!(count(&w.vault), 1);

    // The agent making the same calls.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Agent);
    assert_eq!(count(&w.vault), 0, "an agent caller never records");
}

#[test]
fn person_file_stores_the_excerpt_added_shape() {
    let mut w = world();

    file(&mut w.vault, &w.topic, &[B7], Caller::Person);

    let row = only_correction(&w.vault);
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(row.text, None);
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_added",
            "date": DAY,
            "block_id": B7,
            "preview": B7_TEXT,
            "topic_note_id": w.topic.as_str(),
            "title": TOPIC,
        }))
    );
}

#[test]
fn person_file_records_one_row_per_newly_filed_block_with_its_own_preview() {
    let mut w = world();

    file(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);

    let all = rows(&w.vault);
    assert_eq!(all.len(), 2, "{all:?}");
    let by_block: Vec<(String, String)> = all
        .iter()
        .map(|r| {
            let c = r.correction.as_ref().unwrap();
            (
                c["block_id"].as_str().unwrap().to_string(),
                c["preview"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert!(by_block.contains(&(B7.to_string(), B7_TEXT.to_string())));
    assert!(by_block.contains(&(C3.to_string(), C3_TEXT.to_string())));
}

#[test]
fn person_file_of_held_blocks_records_only_the_new_ones() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);

    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(count(&w.vault), 0, "a no-op file records no Correction");

    file(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);
    let row = only_correction(&w.vault);
    assert_eq!(row.correction.unwrap()["block_id"], C3);
}

#[test]
fn person_file_with_repeated_ids_records_once() {
    let mut w = world();

    file(&mut w.vault, &w.topic, &[B7, B7], Caller::Person);

    assert_eq!(count(&w.vault), 1);
}

#[test]
fn failed_person_writes_record_zero() {
    let mut w = world();
    let (topic, other) = (w.topic.clone(), w.other.clone());

    let unknown_block = add_excerpt(
        &mut w.vault,
        &topic,
        DAY,
        &ids(&["nope00"]),
        Caller::Person,
        None,
    );
    assert_eq!(code_of(unknown_block, "unknown block"), "block_not_found");
    let no_day = add_excerpt(
        &mut w.vault,
        &topic,
        "2026-01-01",
        &ids(&[B7]),
        Caller::Person,
        None,
    );
    assert_eq!(code_of(no_day, "no day"), "not_found");
    let day_note = w.day.clone();
    let not_topic = add_excerpt(
        &mut w.vault,
        &day_note,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
    );
    assert_eq!(code_of(not_topic, "not a topic"), "role_rule");
    let no_token = remove_excerpt(&mut w.vault, &topic, DAY, &ids(&[B7]), Caller::Person, None);
    assert_eq!(code_of(no_token, "no token"), "not_found");
    let not_held = remove_excerpt_block(&mut w.vault, &topic, DAY, B7, Caller::Person, None);
    assert_eq!(code_of(not_held, "not held"), "not_found");
    let move_not_held = move_block(&mut w.vault, DAY, B7, &topic, &other, Caller::Person, None);
    assert_eq!(code_of(move_not_held, "move not held"), "not_found");
    let same_topic = move_block(&mut w.vault, DAY, B7, &topic, &topic, Caller::Person, None);
    assert!(same_topic.is_err(), "a move onto itself fails");

    assert_eq!(count(&w.vault), 0);

    // The same call succeeding does record, so these zeros aren't a dead hook.
    file(&mut w.vault, &topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);
}

#[test]
fn a_racing_write_records_once_after_the_retry_and_never_before_the_write() {
    // add_excerpt
    let mut w = world();
    let topic = w.topic.clone();
    let mut seen = Vec::new();
    let mut hook = |v: &mut Vault| {
        seen.push(count(v));
        if seen.len() == 1 {
            race(v, &topic, 1);
        }
    };
    add_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
        &mut hook,
    )
    .unwrap();
    assert_eq!(seen, [0, 0], "no row exists while the write is pending");
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);

    // remove_excerpt
    let mut w = world();
    let topic = w.topic.clone();
    file(&mut w.vault, &topic, &[B7], Caller::Agent);
    let mut seen = Vec::new();
    let mut hook = |v: &mut Vault| {
        seen.push(count(v));
        if seen.len() == 1 {
            race(v, &topic, 1);
        }
    };
    remove_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
        &mut hook,
    )
    .unwrap();
    assert_eq!(seen, [0, 0]);
    assert_eq!(kinds(&w.vault), ["excerpt_removed"]);

    // remove_excerpt_block
    let mut w = world();
    let topic = w.topic.clone();
    file(&mut w.vault, &topic, &[B7], Caller::Agent);
    let mut seen = Vec::new();
    let mut hook = |v: &mut Vault| {
        seen.push(count(v));
        if seen.len() == 1 {
            race(v, &topic, 1);
        }
    };
    remove_excerpt_block_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        B7,
        Caller::Person,
        None,
        &mut hook,
    )
    .unwrap();
    assert_eq!(seen, [0, 0]);
    assert_eq!(kinds(&w.vault), ["excerpt_removed"]);
}

#[test]
fn a_write_that_every_retry_loses_records_zero_then_a_later_call_records_one() {
    // add_excerpt
    let mut w = world();
    let topic = w.topic.clone();
    let mut n = 0;
    let mut hook = |v: &mut Vault| {
        n += 1;
        race(v, &topic, n);
    };
    let lost = add_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
        &mut hook,
    );
    assert_eq!(code_of(lost, "add raced"), "version_conflict");
    assert_eq!(count(&w.vault), 0);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(count(&w.vault), 1);
    handle_all(&w.vault);

    // remove_excerpt_block of an agent's block
    file(&mut w.vault, &w.topic, &[C3], Caller::Agent);
    let topic = w.topic.clone();
    let mut n = 100;
    let mut hook = |v: &mut Vault| {
        n += 1;
        race(v, &topic, n);
    };
    let lost = remove_excerpt_block_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        C3,
        Caller::Person,
        None,
        &mut hook,
    );
    assert_eq!(code_of(lost, "remove raced"), "version_conflict");
    assert_eq!(count(&w.vault), 1, "still only the filing row");
}

#[test]
fn remove_excerpt_block_stores_the_excerpt_removed_shape_once_when_it_splits_a_range() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3, F6], Caller::Agent);

    unfile_block(&mut w.vault, &w.topic, C3, Caller::Person);

    let row = only_correction(&w.vault);
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_removed",
            "date": DAY,
            "block_ids": [C3],
            "preview": C3_TEXT,
            "topic_note_id": w.topic.as_str(),
            "title": TOPIC,
        }))
    );
}

#[test]
fn remove_excerpt_names_every_block_its_token_covers_by_ord() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3, F6], Caller::Agent);

    unfile(&mut w.vault, &w.topic, &[B7, F6], Caller::Person);

    let row = only_correction(&w.vault);
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_removed",
            "date": DAY,
            "block_ids": [B7, C3, F6],
            "preview": B7_TEXT,
            "topic_note_id": w.topic.as_str(),
            "title": TOPIC,
        }))
    );
}

#[test]
fn remove_excerpt_records_one_row_for_a_token_written_twice() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    let token = format!("![[{DAY}#^{B7}]]");
    person_write(&mut w.vault, &w.topic, |body| format!("{body}\n{token}\n"));

    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);

    let row = only_correction(&w.vault);
    assert_eq!(row.correction.unwrap()["block_ids"], json!([B7]));
}

#[test]
fn remove_excerpt_of_a_deleted_day_names_the_token_endpoints_with_no_home() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3, F6], Caller::Agent);
    let day = w.day.clone();
    delete_note(&mut w.vault, &day);

    unfile(&mut w.vault, &w.topic, &[B7, F6], Caller::Person);

    let row = only_correction(&w.vault);
    assert_eq!(row.note_id, None, "the day note is gone");
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(row.agent_change_id, None);
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_removed",
            "date": DAY,
            "block_ids": [B7, F6],
            "preview": "",
            "topic_note_id": w.topic.as_str(),
            "title": TOPIC,
        }))
    );
}

#[test]
fn remove_excerpt_with_a_gone_endpoint_names_the_endpoints_and_previews_the_first() {
    // The first endpoint is gone: nothing to preview.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3, F6], Caller::Agent);
    let day = w.day.clone();
    person_write(&mut w.vault, &day, |body| {
        body.replace("Fixed the jump arc.\n\n", "")
    });
    unfile(&mut w.vault, &w.topic, &[B7, F6], Caller::Person);
    let row = only_correction(&w.vault);
    let correction = row.correction.unwrap();
    assert_eq!(correction["block_ids"], json!([B7, F6]));
    assert_eq!(correction["preview"], "");
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));

    // The last endpoint is gone: the first block's preview stands.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3, F6], Caller::Agent);
    let day = w.day.clone();
    person_write(&mut w.vault, &day, |body| {
        body.replace("\n\nSleep was bad.", "")
    });
    unfile(&mut w.vault, &w.topic, &[B7, F6], Caller::Person);
    let correction = only_correction(&w.vault).correction.unwrap();
    assert_eq!(correction["block_ids"], json!([B7, F6]));
    assert_eq!(correction["preview"], B7_TEXT);
}

#[test]
fn preview_is_the_first_line_trimmed() {
    let mut w = world();
    let date = "2026-09-08";
    let day = create_day(
        &mut w.vault,
        date,
        "  First line here  \nSecond line\n\nOther.\n",
        &["mln001", "mln002"],
    );

    add_excerpt(
        &mut w.vault,
        &w.topic,
        date,
        &ids(&["mln001"]),
        Caller::Person,
        None,
    )
    .unwrap();

    let row = only_correction(&w.vault);
    assert_eq!(row.note_id.as_deref(), Some(day.as_str()));
    assert_eq!(row.correction.unwrap()["preview"], "First line here");
}

#[test]
fn preview_holds_at_most_80_chars_by_char_with_no_ellipsis() {
    let exactly = "a".repeat(80);
    let over = "b".repeat(81);
    let wide = "é".repeat(81);
    let mut w = world();
    let date = "2026-09-09";
    let body = format!("{exactly}\n\n{over}\n\n{wide}\n");
    create_day(&mut w.vault, date, &body, &["len080", "len081", "wid081"]);

    add_excerpt(
        &mut w.vault,
        &w.topic,
        date,
        &ids(&["len080", "len081", "wid081"]),
        Caller::Person,
        None,
    )
    .unwrap();

    let previews: Vec<(String, String)> = rows(&w.vault)
        .iter()
        .map(|r| {
            let c = r.correction.as_ref().unwrap();
            (
                c["block_id"].as_str().unwrap().to_string(),
                c["preview"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert_eq!(previews.len(), 3, "{previews:?}");
    let preview_of = |id: &str| {
        previews
            .iter()
            .find(|(b, _)| b == id)
            .map(|(_, p)| p.clone())
            .unwrap()
    };
    assert_eq!(preview_of("len080"), exactly, "exactly 80 is kept whole");
    assert_eq!(preview_of("len081"), "b".repeat(80), "81 is cut to 80");
    assert_eq!(preview_of("wid081"), "é".repeat(80), "chars, never bytes");
}

// ---------------------------------------------------------------------------
// AC 2: moves
// ---------------------------------------------------------------------------

#[test]
fn move_records_one_excerpt_moved_only_after_both_writes_and_a_partial_failure_records_zero() {
    // A move: nothing exists while the source write is pending, one row after.
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[F6], Caller::Agent);
    let mut seen = Vec::new();
    let mut hook = |v: &mut Vault| seen.push(count(v));
    move_block_with_hook(
        &mut w.vault,
        DAY,
        F6,
        &source,
        &target,
        Caller::Person,
        None,
        &mut hook,
    )
    .unwrap();
    assert_eq!(seen, [0], "the target is written; the source is not yet");
    assert_eq!(kinds(&w.vault), ["excerpt_moved"], "once, not three times");

    // A failing removal: the block stays in both and nothing is recorded.
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[F6], Caller::Agent);
    let mut n = 0;
    let mut hook = |v: &mut Vault| {
        n += 1;
        race(v, &source, n);
    };
    let lost = move_block_with_hook(
        &mut w.vault,
        DAY,
        F6,
        &source,
        &target,
        Caller::Person,
        None,
        &mut hook,
    );
    assert_eq!(code_of(lost, "move raced"), "version_conflict");
    assert_eq!(count(&w.vault), 0, "a partial failure records nothing");

    // Retrying finishes the move and records exactly one.
    shift(&mut w.vault, F6, &source, &target, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_moved"]);
}

#[test]
fn move_stores_the_excerpt_moved_shape() {
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[F6], Caller::Agent);

    shift(&mut w.vault, F6, &source, &target, Caller::Person);

    let row = only_correction(&w.vault);
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(row.text, None);
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_moved",
            "date": DAY,
            "block_id": F6,
            "preview": F6_TEXT,
            "from_topic_note_id": source.as_str(),
            "from_title": TOPIC,
            "to_topic_note_id": target.as_str(),
            "to_title": OTHER,
        }))
    );
}

#[test]
fn move_into_a_target_already_holding_the_block_still_records_one() {
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[F6], Caller::Agent);
    file(&mut w.vault, &target, &[F6], Caller::Agent);

    shift(&mut w.vault, F6, &source, &target, Caller::Person);

    assert_eq!(kinds(&w.vault), ["excerpt_moved"]);
}

#[test]
fn an_agent_move_records_zero() {
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[F6], Caller::Agent);

    shift(&mut w.vault, F6, &source, &target, Caller::Agent);

    assert_eq!(count(&w.vault), 0);

    // The person making the same call does record.
    shift(&mut w.vault, F6, &target, &source, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_moved"]);
}

#[test]
fn writes_whose_reindex_fails_after_the_save_still_record_their_correction() {
    // remove_excerpt_block: the call succeeds, so the Correction must exist.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    let embedder = FlakyEmbedder::failing_calls(&[1]);
    remove_excerpt_block(
        &mut w.vault,
        &w.topic,
        DAY,
        B7,
        Caller::Person,
        Some(&embedder),
    )
    .expect("the save committed");
    assert_eq!(kinds(&w.vault), ["excerpt_removed"]);

    // move_block. Calls: 1 target, 2 day (chip added), 3 source, 4 day (chip
    // removed).
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[F6], Caller::Agent);
    let embedder = FlakyEmbedder::failing_calls(&[3]);
    move_block(
        &mut w.vault,
        DAY,
        F6,
        &source,
        &target,
        Caller::Person,
        Some(&embedder),
    )
    .expect("the source's save committed");
    assert_eq!(kinds(&w.vault), ["excerpt_moved"]);
}

// ---------------------------------------------------------------------------
// AC 3: provenance (R5, TD7)
// ---------------------------------------------------------------------------

#[test]
fn removing_a_person_filed_block_records_zero_when_handled_and_one_when_open() {
    // Open: a retraction records a new Correction.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_removed"]);

    // Handled: the person's own block, so nothing is recorded.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);
    handle_all(&w.vault);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);
    assert_eq!(count(&w.vault), 1);
}

#[test]
fn remove_excerpt_of_a_person_filed_block_follows_the_filing_status() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"], "Handled: nothing");

    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_removed"]);
}

#[test]
fn moving_a_person_filed_block_follows_the_filing_status() {
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[B7], Caller::Person);
    handle_all(&w.vault);
    shift(&mut w.vault, B7, &source, &target, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added"], "Handled: nothing");

    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[B7], Caller::Person);
    shift(&mut w.vault, B7, &source, &target, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_moved"]);
}

#[test]
fn a_block_moved_in_by_the_person_counts_as_person_filed_in_its_target() {
    // Handled move: the block in the target is the person's.
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[B7], Caller::Agent);
    shift(&mut w.vault, B7, &source, &target, Caller::Person);
    handle_all(&w.vault);
    unfile_block(&mut w.vault, &target, B7, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_moved"]);

    // Open move: a retraction records.
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[B7], Caller::Agent);
    shift(&mut w.vault, B7, &source, &target, Caller::Person);
    unfile_block(&mut w.vault, &target, B7, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_moved", "excerpt_removed"]);
}

#[test]
fn a_block_moved_out_is_agent_work_again_in_its_source() {
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[B7], Caller::Agent);
    shift(&mut w.vault, B7, &source, &target, Caller::Person);
    handle_all(&w.vault);

    // The agent files it back; the newest row naming the source moved it out.
    file(&mut w.vault, &source, &[B7], Caller::Agent);
    unfile_block(&mut w.vault, &source, B7, Caller::Person);

    assert_eq!(kinds(&w.vault), ["excerpt_moved", "excerpt_removed"]);
}

#[test]
fn a_block_removed_by_the_person_is_agent_work_when_the_agent_refiles_it() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_removed"]);
    handle_all(&w.vault);

    // The newest row names the block through `block_ids` and removed it.
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);

    assert_eq!(
        kinds(&w.vault),
        ["excerpt_added", "excerpt_removed", "excerpt_removed"]
    );
}

#[test]
fn provenance_is_per_block_and_per_topic() {
    // A filing of the same block into another topic doesn't count here.
    let mut w = world();
    let (topic, other) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &other, &[B7], Caller::Person);
    handle_all(&w.vault);
    file(&mut w.vault, &topic, &[B7], Caller::Agent);
    unfile_block(&mut w.vault, &topic, B7, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_removed"]);

    // A filing of another block into this topic doesn't count either.
    let mut w = world();
    let topic = w.topic.clone();
    file(&mut w.vault, &topic, &[C3], Caller::Person);
    handle_all(&w.vault);
    file(&mut w.vault, &topic, &[F6], Caller::Agent);
    unfile_block(&mut w.vault, &topic, F6, Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_removed"]);
}

#[test]
fn a_move_that_records_nothing_leaves_no_trace_in_its_target() {
    let mut w = world();
    let (source, target) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &source, &[B7], Caller::Person);
    handle_all(&w.vault);
    shift(&mut w.vault, B7, &source, &target, Caller::Person);
    assert_eq!(count(&w.vault), 1);

    unfile_block(&mut w.vault, &target, B7, Caller::Person);

    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_removed"]);
}

#[test]
fn provenance_reads_the_status_of_the_newest_row_only() {
    // An older Handled filing doesn't hide a newer Open one.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    assert_eq!(count(&w.vault), 1, "Handled: nothing");
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(kinds(&w.vault), ["excerpt_added", "excerpt_added"]);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    assert_eq!(
        kinds(&w.vault),
        ["excerpt_added", "excerpt_added", "excerpt_removed"]
    );

    // An older Open row doesn't outweigh a newer Handled filing.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let newest = rows(&w.vault)[2].id.clone();
    handle(&w.vault, &newest);
    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);
    assert_eq!(
        kinds(&w.vault),
        ["excerpt_added", "excerpt_removed", "excerpt_added"]
    );
}

/// The accepted limit in the lead's decision 3 (TD7, L11): agent writes leave
/// no trace, so the newest Correction still reads as the person's filing.
#[test]
fn a_person_filed_block_refiled_by_the_agent_stays_person_filed() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    assert_eq!(kinds(&w.vault), ["excerpt_added"]);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);

    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);

    assert_eq!(count(&w.vault), 1);
}

#[test]
fn provenance_breaks_a_same_millisecond_tie_by_insertion_order() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);
    w.vault
        .connection_ref()
        .execute("UPDATE feedback SET created_at = ?", [T0])
        .unwrap();
    handle_all(&w.vault);
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);

    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);

    assert_eq!(count(&w.vault), 3, "the removal is the newest row");
}

#[test]
fn provenance_follows_insertion_order_when_the_wall_clock_jumped_back() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);
    assert_eq!(count(&w.vault), 2);
    // NTP stepped the clock back between the two rows.
    let all = rows(&w.vault);
    w.vault
        .connection_ref()
        .execute(
            "UPDATE feedback SET created_at = ? WHERE id = ?",
            params![all[0].created_at - 60_000, all[1].id],
        )
        .unwrap();
    handle_all(&w.vault);
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);

    unfile_block(&mut w.vault, &w.topic, B7, Caller::Person);

    assert_eq!(count(&w.vault), 3, "the removal is still the newest row");
}

#[test]
fn a_multi_block_remove_drops_person_filed_handled_ids() {
    // B7 person-filed and Handled, C3 person-filed and Open.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);
    let filed = rows(&w.vault);
    let b7_row = filed
        .iter()
        .find(|r| r.correction.as_ref().unwrap()["block_id"] == B7)
        .unwrap();
    handle(&w.vault, &b7_row.id);

    unfile(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);

    let all = rows(&w.vault);
    assert_eq!(all.len(), 3, "{all:?}");
    let removed = all[2].correction.as_ref().unwrap();
    assert_eq!(removed["kind"], "excerpt_removed");
    assert_eq!(removed["block_ids"], json!([C3]));
    assert_eq!(removed["preview"], C3_TEXT, "the first block it names");
}

#[test]
fn a_multi_block_remove_keeps_agent_ids_beside_person_filed_handled_ones() {
    // B7 person-filed and Handled; C3 the agent's, joined by hand into a range.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    file(&mut w.vault, &w.topic, &[C3], Caller::Agent);
    let single_b7 = format!("![[{DAY}#^{B7}]]");
    let single_c3 = format!("![[{DAY}#^{C3}]]");
    let range = format!("![[{DAY}#^{B7}..^{C3}]]");
    person_write(&mut w.vault, &w.topic, |body| {
        body.replace(&format!("{single_b7}\n\n{single_c3}"), &range)
    });

    unfile(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);

    let all = rows(&w.vault);
    assert_eq!(all.len(), 2, "{all:?}");
    assert_eq!(
        all[1].correction.as_ref().unwrap()["block_ids"],
        json!([C3])
    );
}

#[test]
fn a_multi_block_remove_of_only_person_filed_handled_ids_records_nothing() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);
    handle_all(&w.vault);

    unfile(&mut w.vault, &w.topic, &[B7, C3], Caller::Person);

    assert_eq!(count(&w.vault), 2, "only the two filing rows");
}

#[test]
fn remove_excerpt_of_a_deleted_day_still_honours_provenance() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    let day = w.day.clone();
    delete_note(&mut w.vault, &day);

    unfile(&mut w.vault, &w.topic, &[B7], Caller::Person);

    assert_eq!(count(&w.vault), 1, "the person's own block: nothing new");
}

// ---------------------------------------------------------------------------
// The Why? note
// ---------------------------------------------------------------------------

#[test]
fn noted_functions_store_the_why_note_as_text() {
    let mut w = world();
    let (topic, other) = (w.topic.clone(), w.other.clone());

    add_excerpt_noted(
        &mut w.vault,
        &topic,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
        Some("  Belongs here.\n"),
    )
    .unwrap();
    let row = only_correction(&w.vault);
    assert_eq!(row.text.as_deref(), Some("  Belongs here.\n"), "verbatim");
    handle_all(&w.vault);

    file(&mut w.vault, &topic, &[C3], Caller::Agent);
    remove_excerpt_block_noted(
        &mut w.vault,
        &topic,
        DAY,
        C3,
        Caller::Person,
        None,
        Some("Not this one."),
    )
    .unwrap();
    assert_eq!(rows(&w.vault)[1].text.as_deref(), Some("Not this one."));
    handle_all(&w.vault);

    file(&mut w.vault, &topic, &[F6], Caller::Agent);
    move_block_noted(
        &mut w.vault,
        DAY,
        F6,
        &topic,
        &other,
        Caller::Person,
        None,
        Some("Sleep, not play."),
    )
    .unwrap();
    assert_eq!(rows(&w.vault)[2].text.as_deref(), Some("Sleep, not play."));
    assert_eq!(
        kinds(&w.vault),
        ["excerpt_added", "excerpt_removed", "excerpt_moved"]
    );
}

#[test]
fn a_noted_file_stores_the_note_on_every_row() {
    let mut w = world();
    add_excerpt_noted(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7, C3]),
        Caller::Person,
        None,
        Some("Both."),
    )
    .unwrap();

    let all = rows(&w.vault);
    assert_eq!(all.len(), 2);
    assert!(all.iter().all(|r| r.text.as_deref() == Some("Both.")));
}

#[test]
fn noted_functions_with_no_note_store_no_text() {
    let mut w = world();
    let (topic, other) = (w.topic.clone(), w.other.clone());
    add_excerpt_noted(
        &mut w.vault,
        &topic,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
        None,
    )
    .unwrap();
    move_block_noted(
        &mut w.vault,
        DAY,
        B7,
        &topic,
        &other,
        Caller::Person,
        None,
        None,
    )
    .unwrap();
    remove_excerpt_block_noted(&mut w.vault, &other, DAY, B7, Caller::Person, None, None).unwrap();

    let all = rows(&w.vault);
    assert_eq!(all.len(), 3, "{all:?}");
    assert!(all.iter().all(|r| r.text.is_none()), "{all:?}");
}

#[test]
fn noted_functions_follow_the_recording_rule() {
    // An agent caller never records, note or not.
    let mut w = world();
    let (topic, other) = (w.topic.clone(), w.other.clone());
    add_excerpt_noted(
        &mut w.vault,
        &topic,
        DAY,
        &ids(&[B7]),
        Caller::Agent,
        None,
        Some("x"),
    )
    .unwrap();
    move_block_noted(
        &mut w.vault,
        DAY,
        B7,
        &topic,
        &other,
        Caller::Agent,
        None,
        Some("x"),
    )
    .unwrap();
    remove_excerpt_block_noted(
        &mut w.vault,
        &other,
        DAY,
        B7,
        Caller::Agent,
        None,
        Some("x"),
    )
    .unwrap();
    assert_eq!(count(&w.vault), 0);

    // A person-filed Handled block records nothing, and so loses the note.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    remove_excerpt_block_noted(
        &mut w.vault,
        &w.topic,
        DAY,
        B7,
        Caller::Person,
        None,
        Some("x"),
    )
    .unwrap();
    assert_eq!(count(&w.vault), 1);
}

// ---------------------------------------------------------------------------
// AC 4: memberships
// ---------------------------------------------------------------------------

#[test]
fn removing_an_agent_placed_membership_records_it_and_a_pinned_one_records_zero() {
    // Agent-placed, unpinned.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    let row = only_correction(&w.vault);
    assert_eq!(row.note_id.as_deref(), Some(w.topic.as_str()));
    assert_eq!(row.day, None);
    assert_eq!(row.agent_change_id, None);
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "membership_removed",
            "note_id": w.topic.as_str(),
            "note_title": TOPIC,
            "smart_folder_id": f,
            "folder_name": "Games",
        }))
    );

    // Pinned: the person's own placement.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    member(&mut w.vault, &f, &w.topic, Caller::Person);
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    assert_eq!(count(&w.vault), 0);
}

#[test]
fn membership_recording_reads_the_row_not_who_placed_it_or_the_folder() {
    // An agent's membership the person later pinned.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    sf::add_member(
        &mut w.vault,
        &f,
        w.topic.as_str(),
        Some(true),
        Caller::Person,
        None,
    )
    .unwrap();
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    assert_eq!(count(&w.vault), 0, "pinned before the write");

    // A person's membership left unpinned.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Person);
    sf::add_member(
        &mut w.vault,
        &f,
        w.topic.as_str(),
        Some(false),
        Caller::Person,
        None,
    )
    .unwrap();
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    assert_eq!(kinds(&w.vault), ["membership_removed"], "pinned = 0");

    // An agent's membership in a pinned folder: the folder's pin doesn't count.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Person);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    assert_eq!(kinds(&w.vault), ["membership_removed"]);
}

#[test]
fn an_agent_removing_a_membership_or_a_person_removing_no_membership_records_zero() {
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);

    let missing = sf::remove_member(&mut w.vault, &f, w.other.as_str(), Caller::Person);
    assert_eq!(code_of(missing, "not a member"), "not_found");
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Agent).unwrap();

    assert_eq!(count(&w.vault), 0);

    // The person making the same call does record.
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    assert_eq!(kinds(&w.vault), ["membership_removed"]);
}

#[test]
fn a_membership_correction_keeps_its_names_after_they_change() {
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Person);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    let before = only_correction(&w.vault).correction;

    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    let topic = w.topic.clone();
    rename_note(&mut w.vault, &topic, "Core Loop");

    assert_eq!(rows(&w.vault)[0].correction, before);
    assert_eq!(before.unwrap()["note_title"], TOPIC);
}

// ---------------------------------------------------------------------------
// AC 5: folders
// ---------------------------------------------------------------------------

#[test]
fn renaming_moving_or_deleting_an_unpinned_folder_records_it_pinned_or_pin_only_records_zero() {
    // Each kind on an unpinned folder.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);

    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(
        &mut w.vault,
        &f,
        move_update(NewParent::Folder(parent)),
        Caller::Person,
    );
    assert_eq!(kinds(&w.vault), ["folder_moved"]);

    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    sf::delete_folder(&mut w.vault, &f, Caller::Person).unwrap();
    assert_eq!(kinds(&w.vault), ["folder_deleted"]);

    // A pinned folder records nothing.
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let f = folder(&mut w.vault, "Games", None, Caller::Person);
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    update(
        &mut w.vault,
        &f,
        move_update(NewParent::Folder(parent)),
        Caller::Person,
    );
    sf::delete_folder(&mut w.vault, &f, Caller::Person).unwrap();
    assert_eq!(count(&w.vault), 0);

    // A pin-only update records nothing.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(&mut w.vault, &f, pin_update(true), Caller::Person);
    update(&mut w.vault, &f, pin_update(false), Caller::Person);
    assert_eq!(count(&w.vault), 0);
}

#[test]
fn folder_corrections_store_their_shape_with_no_home() {
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let renamed = folder(&mut w.vault, "Games", None, Caller::Agent);
    let moved = folder(&mut w.vault, "Sports", None, Caller::Agent);
    let moved_out = folder(&mut w.vault, "Chess", Some(&parent), Caller::Agent);
    let deleted = folder(&mut w.vault, "Old", None, Caller::Agent);

    update(
        &mut w.vault,
        &renamed,
        rename_update("Play"),
        Caller::Person,
    );
    update(
        &mut w.vault,
        &moved,
        move_update(NewParent::Folder(parent.clone())),
        Caller::Person,
    );
    update(
        &mut w.vault,
        &moved_out,
        move_update(NewParent::Root),
        Caller::Person,
    );
    sf::delete_folder(&mut w.vault, &deleted, Caller::Person).unwrap();

    let all = rows(&w.vault);
    assert_eq!(all.len(), 4, "{all:?}");
    for row in &all {
        assert_open_correction(row);
        assert_eq!(row.note_id, None, "{row:?}");
        assert_eq!(row.day, None, "{row:?}");
        assert_eq!(row.agent_change_id, None, "{row:?}");
        assert_eq!(row.text, None, "{row:?}");
    }
    assert_eq!(
        all[0].correction,
        Some(json!({
            "kind": "folder_renamed",
            "smart_folder_id": renamed,
            "old_name": "Games",
            "new_name": "Play",
        }))
    );
    assert_eq!(
        all[1].correction,
        Some(json!({
            "kind": "folder_moved",
            "smart_folder_id": moved,
            "name": "Sports",
            "old_parent_id": null,
            "new_parent_id": parent,
        }))
    );
    assert_eq!(
        all[2].correction,
        Some(json!({
            "kind": "folder_moved",
            "smart_folder_id": moved_out,
            "name": "Chess",
            "old_parent_id": parent,
            "new_parent_id": null,
        }))
    );
    assert_eq!(
        all[3].correction,
        Some(json!({
            "kind": "folder_deleted",
            "smart_folder_id": deleted,
            "name": "Old",
        }))
    );
    assert_eq!(all[0].created_at, T0, "update_folder uses its clock");
}

#[test]
fn a_rename_and_move_together_record_one_row_per_kind() {
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);

    update(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Play".into()),
            parent: Some(NewParent::Folder(parent.clone())),
            pinned: None,
        },
        Caller::Person,
    );

    let all = rows(&w.vault);
    assert_eq!(all.len(), 2, "{all:?}");
    let renamed = all
        .iter()
        .find_map(|r| {
            let c = r.correction.as_ref().unwrap();
            (c["kind"] == "folder_renamed").then_some(c)
        })
        .expect("a folder_renamed row");
    assert_eq!(renamed["old_name"], "Games");
    assert_eq!(renamed["new_name"], "Play");
    let moved = all
        .iter()
        .find_map(|r| {
            let c = r.correction.as_ref().unwrap();
            (c["kind"] == "folder_moved").then_some(c)
        })
        .expect("a folder_moved row");
    assert_eq!(moved["old_parent_id"], Value::Null);
    assert_eq!(moved["new_parent_id"], json!(parent));
}

#[test]
fn a_rename_and_move_record_each_kind_on_its_own_flag() {
    // Same name, new parent: only the move.
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Games".into()),
            parent: Some(NewParent::Folder(parent)),
            pinned: None,
        },
        Caller::Person,
    );
    assert_eq!(kinds(&w.vault), ["folder_moved"]);

    // New name, same parent: only the rename.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Play".into()),
            parent: Some(NewParent::Root),
            pinned: None,
        },
        Caller::Person,
    );
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);
}

#[test]
fn a_no_op_rename_or_move_records_zero() {
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let root = folder(&mut w.vault, "Games", None, Caller::Agent);
    let child = folder(&mut w.vault, "Chess", Some(&parent), Caller::Agent);

    update(&mut w.vault, &root, rename_update("Games"), Caller::Person);
    assert_eq!(count(&w.vault), 0, "a rename to the same name");

    let child_stays = world_with_child_and_same_parent_move();
    assert_eq!(child_stays, 0, "a move to the same parent");

    // A rename that changes only the case is still a rename.
    update(&mut w.vault, &child, rename_update("CHESS"), Caller::Person);
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);
}

/// The rows after a person "moves" unpinned folders to where they already are.
fn world_with_child_and_same_parent_move() -> i64 {
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let root = folder(&mut w.vault, "Games", None, Caller::Agent);
    let child = folder(&mut w.vault, "Chess", Some(&parent), Caller::Agent);
    update(
        &mut w.vault,
        &root,
        move_update(NewParent::Root),
        Caller::Person,
    );
    update(
        &mut w.vault,
        &child,
        move_update(NewParent::Folder(parent)),
        Caller::Person,
    );
    count(&w.vault)
}

#[test]
fn folder_recording_reads_pinned_before_the_write() {
    // The first rename pins the folder, so the second is the person's own.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    update(&mut w.vault, &f, rename_update("Fun"), Caller::Person);
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);

    // A rename that also pins records: it was unpinned before the write.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Play".into()),
            pinned: Some(true),
            ..Default::default()
        },
        Caller::Person,
    );
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);

    // A rename that keeps it unpinned leaves the next rename recording.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    for name in ["Play", "Fun"] {
        update(
            &mut w.vault,
            &f,
            FolderUpdate {
                name: Some(name.into()),
                pinned: Some(false),
                ..Default::default()
            },
            Caller::Person,
        );
    }
    assert_eq!(kinds(&w.vault), ["folder_renamed", "folder_renamed"]);

    // Unpinned by the person first: the folder counts as unpinned again.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Person);
    update(&mut w.vault, &f, pin_update(false), Caller::Person);
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);

    // A rename that also unpins records nothing: it was pinned before the write.
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Person);
    update(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Play".into()),
            pinned: Some(false),
            ..Default::default()
        },
        Caller::Person,
    );
    assert_eq!(count(&w.vault), 0);
}

#[test]
fn delete_folder_records_only_folder_deleted() {
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Agent);
    let child = folder(&mut w.vault, "Chess", Some(&parent), Caller::Agent);
    member(&mut w.vault, &parent, &w.topic, Caller::Agent);
    member(&mut w.vault, &child, &w.other, Caller::Agent);

    sf::delete_folder(&mut w.vault, &parent, Caller::Person).unwrap();

    assert_eq!(kinds(&w.vault), ["folder_deleted"]);
}

#[test]
fn agent_or_failed_folder_writes_record_zero() {
    // The agent on an unpinned folder.
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Agent);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(&mut w.vault, &f, rename_update("Play"), Caller::Agent);
    update(
        &mut w.vault,
        &f,
        move_update(NewParent::Folder(parent)),
        Caller::Agent,
    );
    sf::delete_folder(&mut w.vault, &f, Caller::Agent).unwrap();
    assert_eq!(count(&w.vault), 0);

    // Failures of a person's write.
    let mut w = world();
    folder(&mut w.vault, "Taken", None, Caller::Agent);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    let clock = FakeClock::at(T0);
    let clash = sf::update_folder(
        &mut w.vault,
        &f,
        rename_update("Taken"),
        Caller::Person,
        &clock,
    );
    assert_eq!(code_of(clash, "name clash"), "name_conflict");
    let cycle = sf::update_folder(
        &mut w.vault,
        &f,
        move_update(NewParent::Folder(f.clone())),
        Caller::Person,
        &clock,
    );
    assert_eq!(code_of(cycle, "cycle"), "folder_cycle");
    let partly = sf::update_folder(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Play".into()),
            parent: Some(NewParent::Folder(UNKNOWN.into())),
            pinned: None,
        },
        Caller::Person,
        &clock,
    );
    assert_eq!(code_of(partly, "unknown parent"), "not_found");
    let gone = sf::delete_folder(&mut w.vault, UNKNOWN, Caller::Person);
    assert_eq!(code_of(gone, "unknown folder"), "not_found");
    assert_eq!(count(&w.vault), 0);

    // The same update succeeding does record, so these zeros aren't a dead hook.
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    assert_eq!(kinds(&w.vault), ["folder_renamed"]);
}

// ---------------------------------------------------------------------------
// A recording failure is the call's error
// ---------------------------------------------------------------------------

#[test]
fn a_failing_record_is_the_calls_error_on_every_hook() {
    let mut w = world();
    let (topic, other) = (w.topic.clone(), w.other.clone());
    file(&mut w.vault, &topic, &[C3, F6], Caller::Agent);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Agent);
    let g = folder(&mut w.vault, "Sports", None, Caller::Agent);
    member(&mut w.vault, &f, &topic, Caller::Agent);
    fail_inserts_into(&w.vault, "feedback");

    let filed = add_excerpt(&mut w.vault, &topic, DAY, &ids(&[B7]), Caller::Person, None);
    assert!(filed.is_err(), "add_excerpt");
    let removed = remove_excerpt_block(&mut w.vault, &topic, DAY, C3, Caller::Person, None);
    assert!(removed.is_err(), "remove_excerpt_block");
    let moved = move_block(&mut w.vault, DAY, F6, &topic, &other, Caller::Person, None);
    assert!(moved.is_err(), "move_block");
    let unmembered = sf::remove_member(&mut w.vault, &f, topic.as_str(), Caller::Person);
    assert!(unmembered.is_err(), "remove_member");
    let renamed = sf::update_folder(
        &mut w.vault,
        &f,
        rename_update("Play"),
        Caller::Person,
        &FakeClock::at(T0),
    );
    assert!(renamed.is_err(), "update_folder rename");
    let reparented = sf::update_folder(
        &mut w.vault,
        &g,
        move_update(NewParent::Folder(parent)),
        Caller::Person,
        &FakeClock::at(T0),
    );
    assert!(reparented.is_err(), "update_folder move");

    // remove_excerpt, on its own day of agent work.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    fail_inserts_into(&w.vault, "feedback");
    let unfiled = remove_excerpt(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7]),
        Caller::Person,
        None,
    );
    let token = format!("![[{DAY}#^{B7}]]");
    assert!(unfiled.is_err(), "remove_excerpt");
    assert!(
        !get_note(&w.vault, &w.topic)
            .unwrap()
            .content_md
            .contains(&token),
        "the error comes from recording, after the write"
    );

    // An agent's call never reaches the failing insert.
    file(&mut w.vault, &w.topic, &[B7], Caller::Agent);
    unfile(&mut w.vault, &w.topic, &[B7], Caller::Agent);
}

#[test]
fn a_failing_record_rolls_back_delete_folder() {
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    fail_inserts_into(&w.vault, "feedback");

    let result = sf::delete_folder(&mut w.vault, &f, Caller::Person);

    assert!(result.is_err());
    let list = sf::list_folders(&w.vault).unwrap();
    assert_eq!(list.folders.len(), 1, "the folder stays");
    assert_eq!(list.folders[0].members.len(), 1, "its member stays");
}

// ---------------------------------------------------------------------------
// AC 6: correction_json is frozen when recorded
// ---------------------------------------------------------------------------

#[test]
fn correction_json_keeps_preview_and_titles_after_block_text_and_topic_title_change() {
    let mut w = world();
    let (topic, other, day) = (w.topic.clone(), w.other.clone(), w.day.clone());
    file(&mut w.vault, &topic, &[B7], Caller::Person);
    file(&mut w.vault, &topic, &[C3, F6], Caller::Agent);
    unfile_block(&mut w.vault, &topic, C3, Caller::Person);
    shift(&mut w.vault, F6, &topic, &other, Caller::Person);
    let before: Vec<Value> = rows(&w.vault)
        .into_iter()
        .map(|r| r.correction.unwrap())
        .collect();
    assert_eq!(before.len(), 3, "{before:?}");

    person_write(&mut w.vault, &day, |body| {
        body.replace(B7_TEXT, "Rewritten.")
            .replace(C3_TEXT, "Also rewritten.")
            .replace(F6_TEXT, "Slept well.")
    });
    rename_note(&mut w.vault, &topic, "Core Loop");
    rename_note(&mut w.vault, &other, "Rest");

    let after: Vec<Value> = rows(&w.vault)
        .into_iter()
        .map(|r| r.correction.unwrap())
        .collect();
    assert_eq!(after, before);
    assert_eq!(after[0]["preview"], B7_TEXT);
    assert_eq!(after[0]["title"], TOPIC);
    assert_eq!(after[1]["preview"], C3_TEXT);
    assert_eq!(after[1]["title"], TOPIC);
    assert_eq!(after[2]["preview"], F6_TEXT);
    assert_eq!(after[2]["from_title"], TOPIC);
    assert_eq!(after[2]["to_title"], OTHER);

    let listed: Vec<Value> = feedback::list_open(&w.vault)
        .unwrap()
        .into_iter()
        .map(|f| f.correction.unwrap())
        .collect();
    assert_eq!(listed.len(), 3, "the listing parses the stored JSON");
    for correction in &before {
        assert!(listed.contains(correction), "{correction:?} in {listed:?}");
    }
}

// ---------------------------------------------------------------------------
// AC 7: the home of an excerpt Correction
// ---------------------------------------------------------------------------

#[test]
fn excerpt_correction_home_is_the_daily_note_anchored_to_its_newest_entry_or_unanchored() {
    // No agent entry for the day: unanchored.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let row = only_correction(&w.vault);
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(row.agent_change_id, None);

    // Anchored to the newest entry for that day on that note.
    let mut w = world();
    let day = w.day.as_str().to_string();
    let topic_id = w.topic.as_str().to_string();
    change(&w.vault, "old", &day, DAY, T0);
    let newest = change(&w.vault, "newest", &day, DAY, T0 + 10);
    change(&w.vault, "other-day", &day, "2026-09-06", T0 + 20);
    change(&w.vault, "other-note", &topic_id, DAY, T0 + 30);

    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    file(&mut w.vault, &w.topic, &[C3, F6], Caller::Agent);
    unfile_block(&mut w.vault, &w.topic, C3, Caller::Person);
    let (topic, other) = (w.topic.clone(), w.other.clone());
    shift(&mut w.vault, F6, &topic, &other, Caller::Person);

    let all = rows(&w.vault);
    assert_eq!(all.len(), 3, "{all:?}");
    for row in &all {
        assert_eq!(row.agent_change_id.as_deref(), Some(newest.as_str()));
        assert_eq!(row.note_id.as_deref(), Some(day.as_str()));
    }
}

#[test]
fn the_anchor_orders_by_created_at_then_insertion() {
    // A higher created_at wins over a later insertion.
    let mut w = world();
    let day = w.day.as_str().to_string();
    let newest = change(&w.vault, "aaa-newest", &day, DAY, T0 + 100);
    change(&w.vault, "zzz-older", &day, DAY, T0 + 50);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let row = only_correction(&w.vault);
    assert_eq!(row.agent_change_id.as_deref(), Some(newest.as_str()));

    // In the same millisecond the later insertion wins, whatever its id.
    let mut w = world();
    let day = w.day.as_str().to_string();
    change(&w.vault, "zzz-first", &day, DAY, T0);
    let later = change(&w.vault, "aaa-later", &day, DAY, T0);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let row = only_correction(&w.vault);
    assert_eq!(row.agent_change_id.as_deref(), Some(later.as_str()));
}

#[test]
fn an_anchor_is_the_entry_newest_when_recorded() {
    let mut w = world();
    let day = w.day.as_str().to_string();
    let anchor = change(&w.vault, "before", &day, DAY, T0);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);

    change(&w.vault, "after", &day, DAY, T0 + 10);

    let row = only_correction(&w.vault);
    assert_eq!(row.agent_change_id.as_deref(), Some(anchor.as_str()));
}

// ---------------------------------------------------------------------------
// AC 8: add
// ---------------------------------------------------------------------------

#[test]
fn add_stores_an_open_comment_and_invalid_text_fails_and_stores_nothing() {
    let mut w = world();
    let day = w.day.as_str().to_string();
    let change_id = change(&w.vault, "entry", &day, DAY, T0);
    let clock = FakeClock::at(T0 + 5);

    for bad in ["", "   ", " \n\t ", &"x".repeat(2001)] {
        let result = feedback::add(&mut w.vault, &day, DAY, &change_id, bad, &clock);
        assert_eq!(code_of(result, "bad text"), "feedback_invalid", "{bad:?}");
    }
    assert_eq!(count(&w.vault), 0, "nothing stored");

    let text = "  Not this topic.\n\nTry Sleep.  ";
    let got = feedback::add(&mut w.vault, &day, DAY, &change_id, text, &clock).unwrap();

    let all = rows(&w.vault);
    assert_eq!(all.len(), 1, "{all:?}");
    let row = &all[0];
    assert!(ulid::Ulid::from_string(&row.id).is_ok(), "{row:?}");
    assert_eq!(row.kind, "comment");
    assert_eq!(row.source, "person");
    assert_eq!(row.note_id.as_deref(), Some(day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(row.agent_change_id.as_deref(), Some(change_id.as_str()));
    assert_eq!(row.text.as_deref(), Some(text), "stored verbatim");
    assert_eq!(row.correction, None);
    assert_eq!(row.status, "open");
    assert_eq!(row.reply, None);
    assert_eq!(row.created_at, T0 + 5);
    assert_eq!(row.updated_at, T0 + 5);
    assert_eq!(row.handled_at, None);
    assert_eq!(
        got,
        Feedback {
            id: row.id.clone(),
            kind: "comment".into(),
            source: "person".into(),
            note_id: Some(day.clone()),
            day: Some(DAY.into()),
            agent_change_id: Some(change_id.clone()),
            text: Some(text.into()),
            correction: None,
            status: "open".into(),
            reply: None,
            created_at: T0 + 5,
            updated_at: T0 + 5,
            handled_at: None,
        }
    );
}

#[test]
fn add_text_limit_is_2000_chars_counted_as_chars() {
    let mut w = world();
    let day = w.day.as_str().to_string();
    let change_id = change(&w.vault, "entry", &day, DAY, T0);
    let clock = FakeClock::at(T0);

    for ok in ["x".repeat(2000), "é".repeat(2000)] {
        feedback::add(&mut w.vault, &day, DAY, &change_id, &ok, &clock)
            .unwrap_or_else(|e| panic!("{} chars: {e}", ok.chars().count()));
    }
    assert_eq!(count(&w.vault), 2);

    let over = feedback::add(
        &mut w.vault,
        &day,
        DAY,
        &change_id,
        &"é".repeat(2001),
        &clock,
    );
    assert_eq!(code_of(over, "2001 wide chars"), "feedback_invalid");
    assert_eq!(count(&w.vault), 2);
}

#[test]
fn add_rejects_an_unknown_note_or_change_and_a_malformed_date() {
    let mut w = world();
    let day = w.day.as_str().to_string();
    let change_id = change(&w.vault, "entry", &day, DAY, T0);
    let clock = FakeClock::at(T0);

    let cases = [
        (UNKNOWN, DAY, change_id.as_str(), "not_found"),
        (day.as_str(), DAY, UNKNOWN, "not_found"),
        (
            day.as_str(),
            "2026-13-40",
            change_id.as_str(),
            "invalid_date",
        ),
        (
            day.as_str(),
            "09/05/2026",
            change_id.as_str(),
            "invalid_date",
        ),
    ];
    for (note, date, entry, expected) in cases {
        let result = feedback::add(&mut w.vault, note, date, entry, "A comment.", &clock);
        assert_eq!(code_of(result, date), expected, "{note} {date} {entry}");
    }
    assert_eq!(count(&w.vault), 0);
}

// ---------------------------------------------------------------------------
// AC 9: edit and delete
// ---------------------------------------------------------------------------

#[test]
fn edit_and_delete_work_on_open_comments_and_fail_on_handled_and_corrections() {
    // Open: edit replaces the text verbatim; delete removes the row.
    let mut w = world();
    let c = comment_at(&mut w, "First.", T0);
    let text = "  Second.\n";
    let edited = feedback::edit(&mut w.vault, &c.id, text, &FakeClock::at(T0 + 9)).unwrap();
    assert_eq!(edited.id, c.id);
    assert_eq!(edited.text.as_deref(), Some(text));
    assert_eq!(edited.created_at, T0);
    assert_eq!(edited.updated_at, T0 + 9);
    let row = &rows(&w.vault)[0];
    assert_eq!(row.text.as_deref(), Some(text));
    assert_eq!(row.created_at, T0);
    assert_eq!(row.updated_at, T0 + 9);
    assert_eq!(row.status, "open");
    feedback::delete(&mut w.vault, &c.id).unwrap();
    assert_eq!(count(&w.vault), 0);

    // Handled comment: feedback_handled, unchanged.
    let mut w = world();
    let c = comment_at(&mut w, "First.", T0);
    handle(&w.vault, &c.id);
    let before = rows(&w.vault);
    let edit = feedback::edit(&mut w.vault, &c.id, "Second.", &FakeClock::at(T0 + 9));
    assert_eq!(code_of(edit, "edit handled"), "feedback_handled");
    let delete = feedback::delete(&mut w.vault, &c.id);
    assert_eq!(code_of(delete, "delete handled"), "feedback_handled");
    assert_eq!(rows(&w.vault), before);

    // A Correction: feedback_invalid, unchanged.
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let before = rows(&w.vault);
    let id = before[0].id.clone();
    let edit = feedback::edit(&mut w.vault, &id, "Second.", &FakeClock::at(T0 + 9));
    assert_eq!(code_of(edit, "edit correction"), "feedback_invalid");
    let delete = feedback::delete(&mut w.vault, &id);
    assert_eq!(code_of(delete, "delete correction"), "feedback_invalid");
    assert_eq!(rows(&w.vault), before);
}

#[test]
fn edit_validates_text_like_add_and_changes_nothing_on_failure() {
    let mut w = world();
    let c = comment_at(&mut w, "First.", T0);
    let before = rows(&w.vault);
    let clock = FakeClock::at(T0 + 9);

    for bad in ["", "  \n ", &"x".repeat(2001)] {
        let result = feedback::edit(&mut w.vault, &c.id, bad, &clock);
        assert_eq!(code_of(result, "bad edit"), "feedback_invalid", "{bad:?}");
    }
    assert_eq!(rows(&w.vault), before);

    feedback::edit(&mut w.vault, &c.id, &"x".repeat(2000), &clock).expect("2000 chars fit");
}

#[test]
fn edit_and_delete_of_an_unknown_id_are_not_found() {
    let mut w = world();
    let clock = FakeClock::at(T0);

    for id in [UNKNOWN, "nope"] {
        let edit = feedback::edit(&mut w.vault, id, "Text.", &clock);
        assert_eq!(code_of(edit, "edit unknown"), "not_found");
        let delete = feedback::delete(&mut w.vault, id);
        assert_eq!(code_of(delete, "delete unknown"), "not_found");
    }

    let c = comment_at(&mut w, "First.", T0);
    feedback::delete(&mut w.vault, &c.id).unwrap();
    let again = feedback::delete(&mut w.vault, &c.id);
    assert_eq!(code_of(again, "second delete"), "not_found");
}

#[test]
fn edit_and_delete_of_a_chat_comment_are_feedback_handled() {
    let mut w = world();
    let clock = FakeClock::at(T0);
    let chat =
        feedback::record_chat(&mut w.vault, "Words.", None, None, "Did it.", &[], &clock).unwrap();
    assert_eq!(chat.status, "handled");

    let edit = feedback::edit(&mut w.vault, &chat.id, "Other.", &clock);
    assert_eq!(code_of(edit, "edit chat"), "feedback_handled");
    let delete = feedback::delete(&mut w.vault, &chat.id);
    assert_eq!(code_of(delete, "delete chat"), "feedback_handled");
    assert_eq!(count(&w.vault), 1);
}

#[test]
fn edit_and_delete_of_a_handled_correction_fail_and_change_nothing() {
    let mut w = world();
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    let before = rows(&w.vault);
    let id = before[0].id.clone();

    // Both rules apply to this row, and either code is a refusal.
    let refusals = ["feedback_invalid", "feedback_handled"];
    let edit = feedback::edit(&mut w.vault, &id, "Text.", &FakeClock::at(T0));
    assert!(refusals.contains(&code_of(edit, "edit").as_str()));
    let delete = feedback::delete(&mut w.vault, &id);
    assert!(refusals.contains(&code_of(delete, "delete").as_str()));
    assert_eq!(rows(&w.vault), before);
}

#[test]
fn edit_and_delete_of_an_open_tag_correction_are_feedback_invalid() {
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    let id = format!("tag-{n}");

    let edit = feedback::edit(&mut w.vault, &id, "Text.", &FakeClock::at(T0));
    assert_eq!(code_of(edit, "edit tag"), "feedback_invalid");
    let delete = feedback::delete(&mut w.vault, &id);
    assert_eq!(code_of(delete, "delete tag"), "feedback_invalid");

    assert_eq!(count(&w.vault), 0);
    let listed = feedback::list_open(&w.vault).unwrap();
    assert_eq!(listed.len(), 1, "still open");
    assert_eq!(listed[0].id, id);
}

// ---------------------------------------------------------------------------
// AC 10, 11: resolve
// ---------------------------------------------------------------------------

#[test]
fn resolve_sets_handled_and_writes_one_change_per_entry_then_refuses_twice_and_unknown() {
    let mut w = world();
    let c = comment_at(&mut w, "Wrong topic.", T0);
    let changes_before = agent_changes(&w.vault).len();
    let changes = [
        entry(&w.day, &["Moved the block"]),
        entry(&w.topic, &["Removed the excerpt", "Kept the rest"]),
    ];
    let clock = FakeClock::at(T0 + 100);

    let got = feedback::resolve(&mut w.vault, &c.id, "Moved it.", &changes, &clock).unwrap();

    assert_eq!(got.id, c.id);
    assert_eq!(got.status, "handled");
    assert_eq!(got.reply.as_deref(), Some("Moved it."));
    assert_eq!(got.handled_at, Some(T0 + 100));
    let row = &rows(&w.vault)[0];
    assert_eq!(row.status, "handled");
    assert_eq!(row.reply.as_deref(), Some("Moved it."));
    assert_eq!(row.handled_at, Some(T0 + 100));
    assert_eq!(row.created_at, T0, "created_at stays");
    assert_eq!(row.text.as_deref(), Some("Wrong topic."));

    let written = agent_changes(&w.vault);
    assert_eq!(written.len(), changes_before + 2, "one per entry");
    assert_eq!(
        written[changes_before..],
        [
            (
                w.day.as_str().to_string(),
                DAY.to_string(),
                T0 + 100,
                vec!["Moved the block".to_string()],
            ),
            (
                w.topic.as_str().to_string(),
                DAY.to_string(),
                T0 + 100,
                vec![
                    "Removed the excerpt".to_string(),
                    "Kept the rest".to_string()
                ],
            ),
        ]
    );

    let before = rows(&w.vault);
    let again = feedback::resolve(&mut w.vault, &c.id, "Again.", &changes, &clock);
    assert_eq!(code_of(again, "second resolve"), "feedback_handled");
    assert_eq!(rows(&w.vault), before);
    assert_eq!(agent_changes(&w.vault).len(), changes_before + 2);

    for id in [UNKNOWN, "nope"] {
        let unknown = feedback::resolve(&mut w.vault, id, "Reply.", &[], &clock);
        assert_eq!(code_of(unknown, "unknown"), "not_found");
    }
}

#[test]
fn an_invalid_reply_fails_with_feedback_invalid_and_changes_nothing() {
    let mut w = world();
    let c = comment_at(&mut w, "Wrong topic.", T0);
    let before = rows(&w.vault);
    let changes_before = agent_changes(&w.vault);
    let changes = [entry(&w.day, &["Moved the block"])];
    let clock = FakeClock::at(T0 + 100);

    let over = "x".repeat(201);
    for bad in ["", "   ", "Two\nlines", "Two\r\nlines", "Cr\ronly", &over] {
        let result = feedback::resolve(&mut w.vault, &c.id, bad, &changes, &clock);
        assert_eq!(code_of(result, "bad reply"), "feedback_invalid", "{bad:?}");
    }

    assert_eq!(rows(&w.vault), before);
    assert_eq!(agent_changes(&w.vault), changes_before);
}

#[test]
fn a_reply_of_exactly_200_chars_is_accepted_counted_as_chars() {
    let mut w = world();
    let clock = FakeClock::at(T0);
    let wide = "é".repeat(200);

    let a = comment_at(&mut w, "One.", T0);
    feedback::resolve(&mut w.vault, &a.id, &"x".repeat(200), &[], &clock).expect("200 fits");
    let b = comment_at(&mut w, "Two.", T0);
    let got = feedback::resolve(&mut w.vault, &b.id, &wide, &[], &clock).expect("200 wide fit");
    assert_eq!(got.reply.as_deref(), Some(wide.as_str()));

    let c = comment_at(&mut w, "Three.", T0);
    let over = feedback::resolve(&mut w.vault, &c.id, &"é".repeat(201), &[], &clock);
    assert_eq!(code_of(over, "201 wide"), "feedback_invalid");
}

#[test]
fn resolve_checks_in_order_not_found_handled_then_reply_then_changes() {
    let mut w = world();
    let clock = FakeClock::at(T0);
    let bad_changes = [entry(&w.day, &["a", "b", "c", "d"])];

    let unknown = feedback::resolve(&mut w.vault, UNKNOWN, "", &bad_changes, &clock);
    assert_eq!(code_of(unknown, "unknown first"), "not_found");

    let c = comment_at(&mut w, "Handled.", T0);
    handle(&w.vault, &c.id);
    let handled = feedback::resolve(&mut w.vault, &c.id, "", &bad_changes, &clock);
    assert_eq!(code_of(handled, "handled next"), "feedback_handled");

    let open = comment_at(&mut w, "Open.", T0);
    let reply = feedback::resolve(&mut w.vault, &open.id, "", &bad_changes, &clock);
    assert_eq!(code_of(reply, "reply next"), "feedback_invalid");
    let entries = feedback::resolve(&mut w.vault, &open.id, "Fine.", &bad_changes, &clock);
    assert_eq!(code_of(entries, "changes last"), "change_entries_invalid");
}

#[test]
fn resolve_with_bad_changes_fails_and_changes_nothing() {
    let mut w = world();
    let c = comment_at(&mut w, "Wrong topic.", T0);
    let before = rows(&w.vault);
    let changes_before = agent_changes(&w.vault);
    let clock = FakeClock::at(T0 + 1);
    let good = entry(&w.day, &["Fine"]);

    let cases: [(Vec<ChangeEntry>, &str); 4] = [
        (
            vec![good.clone(), entry(&w.topic, &[])],
            "change_entries_invalid",
        ),
        (
            vec![good.clone(), entry(&w.topic, &["Two\nlines"])],
            "change_entries_invalid",
        ),
        (vec![good.clone(), good.clone()], "change_entries_invalid"),
        (
            vec![
                good.clone(),
                ChangeEntry {
                    note_id: UNKNOWN.into(),
                    bullets: vec!["Gone".into()],
                },
            ],
            "not_found",
        ),
    ];
    for (changes, expected) in cases {
        let result = feedback::resolve(&mut w.vault, &c.id, "Reply.", &changes, &clock);
        assert_eq!(code_of(result, expected), expected, "{changes:?}");
    }

    assert_eq!(rows(&w.vault), before);
    assert_eq!(agent_changes(&w.vault), changes_before);
}

#[test]
fn resolve_with_no_changes_writes_no_agent_changes_row() {
    let mut w = world();
    let c = comment_at(&mut w, "Wrong topic.", T0);
    let changes_before = agent_changes(&w.vault).len();

    feedback::resolve(&mut w.vault, &c.id, "Could not.", &[], &FakeClock::at(T0)).unwrap();

    assert_eq!(agent_changes(&w.vault).len(), changes_before);
    assert_eq!(rows(&w.vault)[0].status, "handled");
}

#[test]
fn resolve_is_one_transaction() {
    let mut w = world();
    let c = comment_at(&mut w, "Wrong topic.", T0);
    let before = rows(&w.vault);
    let changes = [entry(&w.day, &["Fine"])];
    fail_inserts_into(&w.vault, "agent_changes");

    let result = feedback::resolve(&mut w.vault, &c.id, "Reply.", &changes, &FakeClock::at(T0));

    assert!(result.is_err());
    assert_eq!(rows(&w.vault), before, "the status change rolled back");
}

#[test]
fn resolve_dates_a_change_with_the_rows_day_else_today_in_the_clocks_zone() {
    // A row with a day: that day, even with another date on the clock.
    let mut w = world();
    let c = comment_at(&mut w, "Wrong topic.", T0);
    let base = agent_changes(&w.vault).len();
    let later = FakeClock::at(instant("2026-12-25T12:00:00Z"));
    let changes = [entry(&w.topic, &["Fine"])];
    feedback::resolve(&mut w.vault, &c.id, "Reply.", &changes, &later).unwrap();
    assert_eq!(agent_changes(&w.vault)[base].1, DAY);

    // A row with no day: the caller's today at this instant.
    let at = instant("2026-09-06T02:00:00Z");
    for (east_secs, expected) in [(-5 * 3600, "2026-09-05"), (9 * 3600, "2026-09-06")] {
        let mut w = world();
        let f = folder(&mut w.vault, "Games", None, Caller::Agent);
        update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
        let id = rows(&w.vault)[0].id.clone();
        assert_eq!(rows(&w.vault)[0].day, None);
        let clock = CallerClock {
            offset: FixedOffset::east_opt(east_secs).unwrap(),
            base: FakeClock::at(at),
        };
        let changes = [entry(&w.topic, &["Fine"])];
        feedback::resolve(&mut w.vault, &id, "Reply.", &changes, &clock).unwrap();
        let written = agent_changes(&w.vault);
        assert_eq!(written.len(), 1);
        assert_eq!(written[0].1, expected, "offset {east_secs}");
        assert_eq!(written[0].2, at);
    }
}

/// New York around the end of DST on 2026-11-01: the offset depends on the
/// instant asked about.
struct NewYorkClock(i64);

impl Clock for NewYorkClock {
    fn now_ms(&self) -> i64 {
        self.0
    }

    fn utc_offset_at(&self, now_ms: i64) -> FixedOffset {
        let hours = if now_ms < instant("2026-11-01T06:00:00Z") {
            -4
        } else {
            -5
        };
        FixedOffset::east_opt(hours * 3600).unwrap()
    }
}

#[test]
fn today_uses_the_offset_at_the_current_instant_across_dst() {
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    let id = rows(&w.vault)[0].id.clone();
    // 23:30 EST on Nov 1, an hour past the switch; at the EDT offset it would
    // be 00:30 on Nov 2.
    let clock = NewYorkClock(instant("2026-11-02T04:30:00Z"));
    let changes = [entry(&w.topic, &["Fine"])];

    feedback::resolve(&mut w.vault, &id, "Reply.", &changes, &clock).unwrap();

    assert_eq!(agent_changes(&w.vault)[0].1, "2026-11-01");
}

#[test]
fn resolve_handles_a_correction_and_keeps_its_details() {
    let mut w = world();
    let day = w.day.as_str().to_string();
    let anchor = change(&w.vault, "entry", &day, DAY, T0);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let before = only_correction(&w.vault);

    let got =
        feedback::resolve(&mut w.vault, &before.id, "Noted.", &[], &FakeClock::at(T0)).unwrap();

    assert_eq!(got.status, "handled");
    assert_eq!(got.correction, before.correction);
    assert_eq!(got.agent_change_id.as_deref(), Some(anchor.as_str()));
    let row = &rows(&w.vault)[0];
    assert_eq!(row.correction, before.correction);
    assert_eq!(row.created_at, before.created_at);
}

// ---------------------------------------------------------------------------
// AC 12: record_chat
// ---------------------------------------------------------------------------

#[test]
fn record_chat_stores_text_verbatim_as_chat_already_handled_with_its_reply() {
    let mut w = world();
    let base = agent_changes(&w.vault).len();
    let text = "  File sleep notes under Health.\n";
    let changes = [entry(&w.topic, &["Moved a block"])];
    let clock = FakeClock::at(T0 + 7);

    let got = feedback::record_chat(
        &mut w.vault,
        text,
        Some(w.day.as_str()),
        Some(DAY),
        "Moved them to Health.",
        &changes,
        &clock,
    )
    .unwrap();

    let all = rows(&w.vault);
    assert_eq!(all.len(), 1, "{all:?}");
    let row = &all[0];
    assert!(ulid::Ulid::from_string(&row.id).is_ok(), "{row:?}");
    assert_eq!(row.kind, "comment");
    assert_eq!(row.source, "chat");
    assert_eq!(row.status, "handled");
    assert_eq!(row.text.as_deref(), Some(text), "verbatim");
    assert_eq!(row.reply.as_deref(), Some("Moved them to Health."));
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(row.agent_change_id, None);
    assert_eq!(row.correction, None);
    assert_eq!(row.created_at, T0 + 7);
    assert_eq!(row.updated_at, T0 + 7);
    assert_eq!(row.handled_at, Some(T0 + 7));
    assert_eq!(got.id, row.id);
    assert_eq!(got.source, "chat");
    assert_eq!(got.status, "handled");

    let written = agent_changes(&w.vault);
    assert_eq!(written.len(), base + 1);
    assert_eq!(
        written[base],
        (
            w.topic.as_str().to_string(),
            DAY.to_string(),
            T0 + 7,
            vec!["Moved a block".to_string()],
        )
    );
    assert_eq!(feedback::list_open(&w.vault).unwrap(), vec![], "not open");
}

#[test]
fn record_chat_with_no_note_or_date_uses_today_and_lists_under_no_note() {
    let mut w = world();
    let at = instant("2026-09-06T02:00:00Z");
    let clock = CallerClock {
        offset: FixedOffset::west_opt(5 * 3600).unwrap(),
        base: FakeClock::at(at),
    };
    let changes = [entry(&w.topic, &["Fine"])];

    let got = feedback::record_chat(
        &mut w.vault,
        "Words.",
        None,
        None,
        "Did it.",
        &changes,
        &clock,
    )
    .unwrap();

    let row = &rows(&w.vault)[0];
    assert_eq!(row.note_id, None);
    assert_eq!(row.day, None);
    assert_eq!(
        agent_changes(&w.vault)[0].1,
        "2026-09-05",
        "the caller's today"
    );
    let listed = feedback::list_for_note(&w.vault, None).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, got.id);
}

#[test]
fn record_chat_with_a_date_and_no_note_dates_its_changes_with_that_date() {
    let mut w = world();
    let changes = [entry(&w.topic, &["Fine"])];
    let clock = FakeClock::at(instant("2026-12-25T12:00:00Z"));

    feedback::record_chat(
        &mut w.vault,
        "Words.",
        None,
        Some(DAY),
        "Done.",
        &changes,
        &clock,
    )
    .unwrap();

    assert_eq!(rows(&w.vault)[0].day.as_deref(), Some(DAY));
    assert_eq!(agent_changes(&w.vault)[0].1, DAY);
}

#[test]
fn record_chat_with_a_note_and_no_date_dates_its_changes_today() {
    let mut w = world();
    let changes = [entry(&w.topic, &["Fine"])];
    let clock = CallerClock {
        offset: FixedOffset::west_opt(5 * 3600).unwrap(),
        base: FakeClock::at(instant("2026-09-06T02:00:00Z")),
    };

    let got = feedback::record_chat(
        &mut w.vault,
        "Words.",
        Some(w.day.as_str()),
        None,
        "Done.",
        &changes,
        &clock,
    )
    .unwrap();

    let row = &rows(&w.vault)[0];
    assert_eq!(row.note_id.as_deref(), Some(w.day.as_str()));
    assert_eq!(row.day, None, "no date was given");
    assert_eq!(agent_changes(&w.vault)[0].1, "2026-09-05");
    let listed = feedback::list_for_note(&w.vault, Some(w.day.as_str())).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, got.id);
}

#[test]
fn record_chat_with_empty_changes_is_fine() {
    let mut w = world();

    feedback::record_chat(
        &mut w.vault,
        "Words.",
        None,
        None,
        "Did it.",
        &[],
        &FakeClock::at(T0),
    )
    .unwrap();

    assert_eq!(count(&w.vault), 1);
    assert_eq!(agent_changes(&w.vault), vec![]);
}

#[test]
fn record_chat_validates_everything_and_stores_nothing_on_failure() {
    let mut w = world();
    let day = w.day.as_str().to_string();
    let clock = FakeClock::at(T0);
    let good = [entry(&w.topic, &["Fine"])];
    let bad = [entry(&w.topic, &["a", "b", "c", "d"])];
    let long_text = "x".repeat(2001);
    let long_reply = "x".repeat(201);

    type Case<'a> = (
        &'a str,
        Option<&'a str>,
        Option<&'a str>,
        &'a str,
        &'a [ChangeEntry],
        &'a str,
    );
    let cases: [Case; 10] = [
        ("", None, None, "Reply.", &good, "feedback_invalid"),
        ("  \n ", None, None, "Reply.", &good, "feedback_invalid"),
        (&long_text, None, None, "Reply.", &good, "feedback_invalid"),
        ("Text.", None, None, "", &good, "feedback_invalid"),
        ("Text.", None, None, "Two\nlines", &good, "feedback_invalid"),
        ("Text.", None, None, &long_reply, &good, "feedback_invalid"),
        ("Text.", Some(UNKNOWN), None, "Reply.", &good, "not_found"),
        (
            "Text.",
            Some(day.as_str()),
            Some("2026-13-40"),
            "Reply.",
            &good,
            "invalid_date",
        ),
        (
            "Text.",
            None,
            None,
            "Reply.",
            &bad,
            "change_entries_invalid",
        ),
        (
            "Text.",
            None,
            None,
            "Reply.",
            &[ChangeEntry {
                note_id: UNKNOWN.into(),
                bullets: vec!["Gone".into()],
            }],
            "not_found",
        ),
    ];
    for (text, note, date, reply, changes, expected) in cases {
        let result = feedback::record_chat(&mut w.vault, text, note, date, reply, changes, &clock);
        assert_eq!(code_of(result, expected), expected, "{text:?} {reply:?}");
    }

    assert_eq!(count(&w.vault), 0);
    assert_eq!(agent_changes(&w.vault), vec![]);

    feedback::record_chat(
        &mut w.vault,
        &"x".repeat(2000),
        None,
        None,
        &"y".repeat(200),
        &[],
        &clock,
    )
    .expect("the limits fit");
    assert_eq!(count(&w.vault), 1);
}

#[test]
fn record_chat_is_one_transaction() {
    let mut w = world();
    let changes = [entry(&w.topic, &["Fine"])];
    fail_inserts_into(&w.vault, "agent_changes");

    let result = feedback::record_chat(
        &mut w.vault,
        "Words.",
        None,
        None,
        "Did it.",
        &changes,
        &FakeClock::at(T0),
    );

    assert!(result.is_err());
    assert_eq!(count(&w.vault), 0, "the row rolled back");
}

// ---------------------------------------------------------------------------
// AC 13: list_open
// ---------------------------------------------------------------------------

#[test]
fn list_open_returns_open_rows_oldest_first_with_tag_corrections() {
    let mut w = world();
    let late = comment_at(&mut w, "Late.", T0 + 3000);
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0 + 2000,
        None,
    );
    let early = comment_at(&mut w, "Early.", T0 + 1000);
    let handled = comment_at(&mut w, "Handled.", T0 + 500);
    handle(&w.vault, &handled.id);
    tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "cleared",
        T0 + 600,
        Some(T0 + 700),
    );
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    sf::update_folder(
        &mut w.vault,
        &f,
        rename_update("Play"),
        Caller::Person,
        &FakeClock::at(T0 + 2500),
    )
    .unwrap();

    let listed = feedback::list_open(&w.vault).unwrap();

    let tag_id = format!("tag-{n}");
    let order: Vec<&str> = listed.iter().map(|f| f.id.as_str()).collect();
    assert_eq!(listed.len(), 4, "{listed:?}");
    assert_eq!(order[0], early.id);
    assert_eq!(order[1], tag_id);
    assert_eq!(
        listed[2].correction.as_ref().unwrap()["kind"],
        "folder_renamed"
    );
    assert_eq!(order[3], late.id);
    assert_eq!(
        listed[1],
        Feedback {
            id: tag_id,
            kind: "correction".into(),
            source: "person".into(),
            note_id: Some(w.topic.as_str().to_string()),
            day: None,
            agent_change_id: None,
            text: None,
            correction: Some(json!({
                "kind": "tag_removed",
                "tag": "game-feel",
                "note_id": w.topic.as_str(),
                "note_title": TOPIC,
            })),
            status: "open".into(),
            reply: None,
            created_at: T0 + 2000,
            updated_at: T0 + 2000,
            handled_at: None,
        }
    );
    assert_eq!(listed[0].text.as_deref(), Some("Early."));
    assert_eq!(listed[0].status, "open");
}

#[test]
fn same_millisecond_rows_list_in_insertion_order() {
    let mut w = world();
    let inserted: Vec<String> = (0..6)
        .map(|i| comment_at(&mut w, &format!("Comment {i}."), T0).id)
        .collect();

    let open: Vec<String> = feedback::list_open(&w.vault)
        .unwrap()
        .into_iter()
        .map(|f| f.id)
        .collect();
    assert_eq!(open, inserted, "oldest first");

    let mut newest_first = inserted.clone();
    newest_first.reverse();
    let for_note: Vec<String> = feedback::list_for_note(&w.vault, Some(w.day.as_str()))
        .unwrap()
        .into_iter()
        .map(|f| f.id)
        .collect();
    assert_eq!(for_note, newest_first, "newest first");
}

// ---------------------------------------------------------------------------
// AC 14: resolving a tag Correction
// ---------------------------------------------------------------------------

#[test]
fn resolve_tag_inserts_a_handled_row_with_the_copied_correction_and_closes_it() {
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    let id = format!("tag-{n}");
    let changes = [entry(&w.topic, &["Noted the tag"])];
    let at = instant("2026-09-06T02:00:00Z");
    let clock = CallerClock {
        offset: FixedOffset::west_opt(5 * 3600).unwrap(),
        base: FakeClock::at(at),
    };

    let got =
        feedback::resolve(&mut w.vault, &id, "Stopped tagging it.", &changes, &clock).unwrap();

    let all = rows(&w.vault);
    assert_eq!(all.len(), 1, "{all:?}");
    let row = &all[0];
    assert!(ulid::Ulid::from_string(&row.id).is_ok(), "{row:?}");
    assert_eq!(row.kind, "correction");
    assert_eq!(row.source, "person");
    assert_eq!(row.status, "handled");
    assert_eq!(row.reply.as_deref(), Some("Stopped tagging it."));
    assert_eq!(row.tag_correction_id, Some(n));
    assert_eq!(row.note_id.as_deref(), Some(w.topic.as_str()));
    assert_eq!(row.day, None);
    assert_eq!(row.text, None);
    assert_eq!(row.agent_change_id, None);
    assert_eq!(row.created_at, T0, "keeps the correction's created_at");
    assert_eq!(row.handled_at, Some(at));
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "tag_removed",
            "tag": "game-feel",
            "note_id": w.topic.as_str(),
            "note_title": TOPIC,
        }))
    );
    assert_eq!(got.id, row.id);
    assert_eq!(got.status, "handled");

    let written = agent_changes(&w.vault);
    assert_eq!(written.len(), 1);
    assert_eq!(written[0].0, w.topic.as_str());
    assert_eq!(written[0].1, "2026-09-05", "today in the caller's zone");

    assert_eq!(feedback::list_open(&w.vault).unwrap(), vec![], "closed");
    let history = feedback::list_for_note(&w.vault, Some(w.topic.as_str())).unwrap();
    assert_eq!(history.len(), 1, "one row, not joined again: {history:?}");
    assert_eq!(history[0].id, row.id);

    let again = feedback::resolve(&mut w.vault, &id, "Again.", &[], &clock);
    assert_eq!(code_of(again, "second resolve"), "feedback_handled");
    assert_eq!(count(&w.vault), 1);
}

#[test]
fn resolve_of_an_unknown_malformed_or_cleared_tag_id_is_not_found() {
    let mut w = world();
    let clock = FakeClock::at(T0);
    let cleared = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        Some(T0 + 1),
    );
    let cleared_id = format!("tag-{cleared}");

    for id in [
        "tag-",
        "tag-abc",
        "tag-0",
        "tag-99999",
        "tag-1x",
        cleared_id.as_str(),
    ] {
        let result = feedback::resolve(&mut w.vault, id, "Reply.", &[], &clock);
        assert_eq!(code_of(result, id), "not_found", "{id}");
    }
    assert_eq!(count(&w.vault), 0);
}

#[test]
fn resolve_of_a_tag_checks_its_reply_and_changes_and_inserts_nothing_on_failure() {
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    let id = format!("tag-{n}");
    let clock = FakeClock::at(T0);

    let reply = feedback::resolve(&mut w.vault, &id, "", &[], &clock);
    assert_eq!(code_of(reply, "reply"), "feedback_invalid");
    let bad = [entry(&w.topic, &["a", "b", "c", "d"])];
    let entries = feedback::resolve(&mut w.vault, &id, "Reply.", &bad, &clock);
    assert_eq!(code_of(entries, "changes"), "change_entries_invalid");
    assert_eq!(count(&w.vault), 0);
    assert_eq!(
        feedback::list_open(&w.vault).unwrap().len(),
        1,
        "still open"
    );

    // A handled tag row always reports feedback_handled, whatever the reply.
    feedback::resolve(&mut w.vault, &id, "Reply.", &[], &clock).unwrap();
    let handled = feedback::resolve(&mut w.vault, &id, "", &bad, &clock);
    assert_eq!(code_of(handled, "handled"), "feedback_handled");
}

#[test]
fn a_new_correction_of_the_same_tag_is_separate() {
    let mut w = world();
    let clock = FakeClock::at(T0);
    let first = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    feedback::resolve(&mut w.vault, &format!("tag-{first}"), "One.", &[], &clock).unwrap();

    let second = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0 + 1,
        None,
    );

    let open = feedback::list_open(&w.vault).unwrap();
    assert_eq!(open.len(), 1, "{open:?}");
    assert_eq!(open[0].id, format!("tag-{second}"));
}

// ---------------------------------------------------------------------------
// AC 15: a tag Correction whose note was deleted
// ---------------------------------------------------------------------------

#[test]
fn open_tag_correction_of_a_deleted_note_stays_open_and_lists_under_no_note() {
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    let topic = w.topic.clone();
    delete_note(&mut w.vault, &topic);

    let expected = Feedback {
        id: format!("tag-{n}"),
        kind: "correction".into(),
        source: "person".into(),
        note_id: None,
        day: None,
        agent_change_id: None,
        text: None,
        correction: Some(json!({
            "kind": "tag_removed",
            "tag": "game-feel",
            "note_id": null,
            "note_title": TOPIC,
        })),
        status: "open".into(),
        reply: None,
        created_at: T0,
        updated_at: T0,
        handled_at: None,
    };
    assert_eq!(
        feedback::list_open(&w.vault).unwrap(),
        vec![expected.clone()]
    );
    assert_eq!(
        feedback::list_for_note(&w.vault, None).unwrap(),
        vec![expected]
    );

    // Resolving it keeps the stored title in the copied correction.
    feedback::resolve(
        &mut w.vault,
        &format!("tag-{n}"),
        "Noted.",
        &[],
        &FakeClock::at(T0),
    )
    .unwrap();
    let row = &rows(&w.vault)[0];
    assert_eq!(row.note_id, None);
    assert_eq!(row.tag_correction_id, Some(n));
    assert_eq!(row.correction.as_ref().unwrap()["note_title"], TOPIC);
}

#[test]
fn handled_tag_history_outlives_its_note() {
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    feedback::resolve(
        &mut w.vault,
        &format!("tag-{n}"),
        "Noted.",
        &[],
        &FakeClock::at(T0 + 1),
    )
    .unwrap();
    let before = rows(&w.vault)[0].correction.clone();
    let topic = w.topic.clone();
    let topic_id = topic.as_str().to_string();

    delete_note(&mut w.vault, &topic);

    let listed = feedback::list_for_note(&w.vault, None).unwrap();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0].note_id, None, "the row's note is gone");
    assert_eq!(listed[0].status, "handled");
    assert_eq!(listed[0].correction, before, "the copied JSON stays");
    assert_eq!(before.unwrap()["note_id"], json!(topic_id));
}

// ---------------------------------------------------------------------------
// AC 16: cleared tag Corrections
// ---------------------------------------------------------------------------

#[test]
fn cleared_tag_correction_is_omitted_when_unhandled_and_unchanged_when_handled() {
    // Cleared before Handled: omitted from every listing.
    let w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    assert_eq!(
        feedback::list_open(&w.vault).unwrap().len(),
        1,
        "precondition: it lists while uncleared"
    );
    clear_tag(&w.vault, n, T0 + 1);
    assert_eq!(feedback::list_open(&w.vault).unwrap(), vec![]);
    assert_eq!(
        feedback::list_for_note(&w.vault, Some(w.topic.as_str())).unwrap(),
        vec![]
    );
    assert_eq!(count(&w.vault), 0, "nothing recorded");

    // Cleared after Handled: history unchanged, nothing new recorded.
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    feedback::resolve(
        &mut w.vault,
        &format!("tag-{n}"),
        "Noted.",
        &[],
        &FakeClock::at(T0 + 1),
    )
    .unwrap();
    let before_rows = rows(&w.vault);
    let before_list = feedback::list_for_note(&w.vault, Some(w.topic.as_str())).unwrap();
    assert_eq!(before_list.len(), 1);
    clear_tag(&w.vault, n, T0 + 2);
    assert_eq!(rows(&w.vault), before_rows);
    assert_eq!(
        feedback::list_for_note(&w.vault, Some(w.topic.as_str())).unwrap(),
        before_list
    );
    assert_eq!(feedback::list_open(&w.vault).unwrap(), vec![]);
    let again = feedback::resolve(
        &mut w.vault,
        &format!("tag-{n}"),
        "Again.",
        &[],
        &FakeClock::at(T0 + 3),
    );
    assert_eq!(code_of(again, "handled, then cleared"), "feedback_handled");
    assert_eq!(rows(&w.vault), before_rows);
}

// ---------------------------------------------------------------------------
// AC 17: list_for_note and deleted notes
// ---------------------------------------------------------------------------

#[test]
fn feedback_whose_note_was_deleted_lists_under_no_note_intact() {
    let mut w = world();
    let c = comment_at(&mut w, "On the day.", T0);
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let before = rows(&w.vault);
    assert_eq!(before.len(), 2, "{before:?}");
    let day = w.day.clone();
    let day_id = day.as_str().to_string();

    delete_note(&mut w.vault, &day);

    let listed = feedback::list_for_note(&w.vault, None).unwrap();
    assert_eq!(listed.len(), 2, "{listed:?}");
    let comment = listed.iter().find(|f| f.id == c.id).expect("the comment");
    assert_eq!(comment.note_id, None);
    assert_eq!(comment.text.as_deref(), Some("On the day."));
    assert_eq!(comment.day.as_deref(), Some(DAY), "keeps its day");
    assert_eq!(comment.status, "open");
    assert_eq!(
        comment.agent_change_id, None,
        "the entry went with the note"
    );
    assert_eq!(comment.created_at, T0);
    let correction = listed.iter().find(|f| f.id == before[1].id).unwrap();
    assert_eq!(correction.note_id, None);
    assert_eq!(correction.correction, before[1].correction, "JSON intact");
    assert_eq!(
        feedback::list_for_note(&w.vault, Some(&day_id)).unwrap_or_default(),
        vec![]
    );
    assert_eq!(count(&w.vault), 2);
    assert_eq!(
        feedback::list_open(&w.vault).unwrap().len(),
        2,
        "still open"
    );
}

#[test]
fn list_for_note_returns_all_statuses_newest_first_with_its_open_tag_rows() {
    let mut w = world();
    let open = comment_at(&mut w, "Open.", T0 + 10);
    let handled = comment_at(&mut w, "Handled.", T0 + 30);
    handle(&w.vault, &handled.id);
    let n = tag_correction(
        &w.vault,
        Some(w.day.as_str()),
        DAY,
        "game-feel",
        T0 + 20,
        None,
    );
    let chat = feedback::record_chat(
        &mut w.vault,
        "Chat.",
        Some(w.day.as_str()),
        Some(DAY),
        "Reply.",
        &[],
        &FakeClock::at(T0 + 40),
    )
    .unwrap();

    // Rows elsewhere stay out.
    let topic = w.topic.as_str().to_string();
    let elsewhere = change(&w.vault, "elsewhere", &topic, DAY, T0);
    feedback::add(
        &mut w.vault,
        &topic,
        DAY,
        &elsewhere,
        "On the topic.",
        &FakeClock::at(T0 + 50),
    )
    .unwrap();
    tag_correction(&w.vault, Some(&topic), TOPIC, "other", T0 + 60, None);
    feedback::record_chat(
        &mut w.vault,
        "No note.",
        None,
        None,
        "Reply.",
        &[],
        &FakeClock::at(T0 + 70),
    )
    .unwrap();

    let ids: Vec<String> = feedback::list_for_note(&w.vault, Some(w.day.as_str()))
        .unwrap()
        .into_iter()
        .map(|f| f.id)
        .collect();

    assert_eq!(
        ids,
        [chat.id, handled.id, format!("tag-{n}"), open.id],
        "newest first"
    );
}

#[test]
fn list_for_note_none_holds_folder_corrections_noteless_chat_and_noteless_tag_rows() {
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    sf::update_folder(
        &mut w.vault,
        &f,
        rename_update("Play"),
        Caller::Person,
        &FakeClock::at(T0 + 10),
    )
    .unwrap();
    let folder_row = rows(&w.vault)[0].id.clone();
    let chat = feedback::record_chat(
        &mut w.vault,
        "No note.",
        None,
        None,
        "Reply.",
        &[],
        &FakeClock::at(T0 + 20),
    )
    .unwrap();
    let n = tag_correction(&w.vault, None, "Gone Note", "game-feel", T0 + 30, None);
    comment_at(&mut w, "On the day.", T0 + 40);
    tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "other",
        T0 + 50,
        None,
    );

    let ids: Vec<String> = feedback::list_for_note(&w.vault, None)
        .unwrap()
        .into_iter()
        .map(|f| f.id)
        .collect();

    assert_eq!(ids, [format!("tag-{n}"), chat.id, folder_row]);
}

#[test]
fn feedback_serializes_to_the_contract_shape() {
    let mut w = world();
    let c = comment_at(&mut w, "Text.", T0);

    assert_eq!(
        serde_json::to_value(&c).unwrap(),
        json!({
            "id": c.id,
            "kind": "comment",
            "source": "person",
            "note_id": w.day.as_str(),
            "day": DAY,
            "agent_change_id": c.agent_change_id,
            "text": "Text.",
            "correction": null,
            "status": "open",
            "reply": null,
            "created_at": T0,
            "updated_at": T0,
            "handled_at": null,
        })
    );

    // `correction` is the parsed object, never the stored JSON string.
    file(&mut w.vault, &w.topic, &[B7], Caller::Person);
    let listed = feedback::list_open(&w.vault).unwrap();
    let correction = listed.iter().find(|f| f.kind == "correction").unwrap();
    let value = serde_json::to_value(correction).unwrap();
    assert_eq!(value["correction"]["kind"], "excerpt_added");
    assert_eq!(value["correction"]["block_id"], B7);
}

// ---------------------------------------------------------------------------
// AC 18: review state
// ---------------------------------------------------------------------------

/// What a day's review must keep: the `day_reviews` row and the snapshot size.
fn review_snapshot(v: &Vault, day: &NoteId) -> (i64, Option<i64>, Option<i64>, i64) {
    let conn = v.connection_ref();
    let (content, reviewed, at) = conn
        .query_row(
            "SELECT content_version, reviewed_content_version, reviewed_at
             FROM day_reviews WHERE note_id = ?",
            [day.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    let blocks = conn
        .query_row(
            "SELECT count(*) FROM day_review_blocks WHERE note_id = ?",
            [day.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    (content, reviewed, at, blocks)
}

#[test]
fn no_feedback_operation_changes_review_state_or_content_version() {
    let mut w = world();
    let (day, topic, other) = (w.day.clone(), w.topic.clone(), w.other.clone());
    let version: i64 = w
        .vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [day.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    review::mark_day_reviewed(
        &mut w.vault,
        DAY,
        version,
        &[entry(&day, &["Reviewed"])],
        &FakeClock::at(T0),
    )
    .unwrap();
    let before = review_snapshot(&w.vault, &day);
    let check = |v: &Vault, step: &str| {
        assert_eq!(review_snapshot(v, &day), before, "after {step}");
        assert_eq!(
            daily::review_state(v.connection_ref(), day.as_str()).unwrap(),
            ReviewState::Reviewed,
            "after {step}"
        );
    };
    let clock = FakeClock::at(T0 + 1);

    let c = comment_at(&mut w, "A comment.", T0 + 1);
    check(&w.vault, "add");
    feedback::edit(&mut w.vault, &c.id, "Edited.", &clock).unwrap();
    check(&w.vault, "edit");
    feedback::delete(&mut w.vault, &c.id).unwrap();
    check(&w.vault, "delete");
    let c = comment_at(&mut w, "Again.", T0 + 1);
    feedback::resolve(
        &mut w.vault,
        &c.id,
        "Done.",
        &[entry(&day, &["Fixed it"])],
        &clock,
    )
    .unwrap();
    check(&w.vault, "resolve");
    feedback::record_chat(
        &mut w.vault,
        "Chat.",
        Some(day.as_str()),
        Some(DAY),
        "Done.",
        &[entry(&day, &["Fixed it"])],
        &clock,
    )
    .unwrap();
    check(&w.vault, "record_chat");
    let n = tag_correction(&w.vault, Some(day.as_str()), DAY, "game-feel", T0, None);
    feedback::resolve(&mut w.vault, &format!("tag-{n}"), "Done.", &[], &clock).unwrap();
    check(&w.vault, "resolve tag");

    file(&mut w.vault, &topic, &[B7], Caller::Person);
    check(&w.vault, "person file");
    unfile_block(&mut w.vault, &topic, B7, Caller::Person);
    check(&w.vault, "person remove block");
    file(&mut w.vault, &topic, &[C3], Caller::Agent);
    unfile(&mut w.vault, &topic, &[C3], Caller::Person);
    check(&w.vault, "person remove");
    file(&mut w.vault, &topic, &[F6], Caller::Agent);
    shift(&mut w.vault, F6, &topic, &other, Caller::Person);
    check(&w.vault, "person move");

    assert_eq!(
        count(&w.vault),
        7,
        "comment, chat, tag, added, removed, removed, moved"
    );
}

// ---------------------------------------------------------------------------
// Verify round: contracts the implementer's handoff listed as unpinned
// ---------------------------------------------------------------------------

#[test]
fn a_failing_record_rolls_back_update_folder_and_remove_member_so_a_retry_records() {
    let mut w = world();
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);
    member(&mut w.vault, &f, &w.topic, Caller::Agent);
    fail_inserts_into(&w.vault, "feedback");

    let renamed = sf::update_folder(
        &mut w.vault,
        &f,
        rename_update("Play"),
        Caller::Person,
        &FakeClock::at(T0),
    );
    assert!(renamed.is_err(), "update_folder");
    let unmembered = sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person);
    assert!(unmembered.is_err(), "remove_member");

    let list = sf::list_folders(&w.vault).unwrap();
    assert_eq!(
        list.folders[0].folder.name, "Games",
        "the rename rolled back"
    );
    assert!(
        !list.folders[0].folder.pinned,
        "the pin the rename would set rolled back too"
    );
    assert_eq!(list.folders[0].members.len(), 1, "the member stays");
    assert_eq!(count(&w.vault), 0);

    // The retry finds the folder unpinned and the member there, so it records.
    w.vault
        .connection_ref()
        .execute_batch("DROP TRIGGER fail_feedback")
        .unwrap();
    update(&mut w.vault, &f, rename_update("Play"), Caller::Person);
    sf::remove_member(&mut w.vault, &f, w.topic.as_str(), Caller::Person).unwrap();
    assert_eq!(kinds(&w.vault), ["folder_renamed", "membership_removed"]);
}

#[test]
fn a_multi_block_file_whose_second_record_fails_records_none() {
    let mut w = world();
    w.vault
        .connection_ref()
        .execute_batch(&format!(
            "CREATE TRIGGER fail_second BEFORE INSERT ON feedback
             WHEN NEW.correction_json LIKE '%{C3}%'
             BEGIN SELECT RAISE(ABORT, 'injected failure'); END;"
        ))
        .unwrap();

    let filed = add_excerpt(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7, C3]),
        Caller::Person,
        None,
    );

    assert!(filed.is_err());
    assert_eq!(count(&w.vault), 0, "all or none: the first row is undone");
}

#[test]
fn add_with_an_activity_entry_of_another_note_is_not_found() {
    let mut w = world();
    let other_notes_entry = change(&w.vault, UNKNOWN, w.topic.as_str(), DAY, T0);

    let result = feedback::add(
        &mut w.vault,
        w.day.as_str(),
        DAY,
        &other_notes_entry,
        "Why?",
        &FakeClock::at(T0),
    );

    assert_eq!(code_of(result, "add"), "not_found");
    assert_eq!(count(&w.vault), 0);
}

#[test]
fn provenance_ignores_the_same_block_id_on_another_day() {
    const DAY2: &str = "2026-09-06";
    let mut w = world();
    create_day(&mut w.vault, DAY2, DAY_BODY, &[B7, C3, F6]);
    let topic = w.topic.clone();

    // Day one: the person filed B7, and its Correction is Handled.
    file(&mut w.vault, &topic, &[B7], Caller::Person);
    handle_all(&w.vault);
    // Day two: the same block id is a different block, filed by the agent.
    add_excerpt(&mut w.vault, &topic, DAY2, &ids(&[B7]), Caller::Agent, None).unwrap();

    remove_excerpt_block(&mut w.vault, &topic, DAY2, B7, Caller::Person, None).unwrap();

    assert_eq!(count(&w.vault), 2, "day two's block was the agent's");
    let last = rows(&w.vault).pop().unwrap();
    assert_eq!(last.day.as_deref(), Some(DAY2));
    assert_eq!(last.correction.unwrap()["kind"], "excerpt_removed");

    // The same holds for remove_excerpt.
    file(&mut w.vault, &topic, &[C3], Caller::Person);
    handle_all(&w.vault);
    add_excerpt(&mut w.vault, &topic, DAY2, &ids(&[C3]), Caller::Agent, None).unwrap();
    let before = count(&w.vault);
    remove_excerpt(
        &mut w.vault,
        &topic,
        DAY2,
        &ids(&[C3]),
        Caller::Person,
        None,
    )
    .unwrap();
    assert_eq!(count(&w.vault), before + 1, "remove_excerpt");
}

#[test]
fn a_noncanonical_tag_id_is_not_found_and_leaves_the_tag_open() {
    let mut w = world();
    let n = tag_correction(
        &w.vault,
        Some(w.topic.as_str()),
        TOPIC,
        "game-feel",
        T0,
        None,
    );
    let clock = FakeClock::at(T0);

    for id in [
        format!("tag-0{n}"),
        format!("tag-+{n}"),
        format!("tag- {n}"),
    ] {
        let resolved = feedback::resolve(&mut w.vault, &id, "Reply.", &[], &clock);
        assert_eq!(code_of(resolved, &id), "not_found", "resolve {id}");
        let edited = feedback::edit(&mut w.vault, &id, "Text.", &clock);
        assert_eq!(code_of(edited, &id), "not_found", "edit {id}");
        let deleted = feedback::delete(&mut w.vault, &id);
        assert_eq!(code_of(deleted, &id), "not_found", "delete {id}");
    }
    let missing = format!("tag-{}", n + 998);
    let edited = feedback::edit(&mut w.vault, &missing, "Text.", &clock);
    assert_eq!(code_of(edited, "edit missing tag"), "not_found");
    let deleted = feedback::delete(&mut w.vault, &missing);
    assert_eq!(code_of(deleted, "delete missing tag"), "not_found");

    assert_eq!(count(&w.vault), 0);
    let open = feedback::list_open(&w.vault).unwrap();
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].id, format!("tag-{n}"));
}

#[test]
fn a_rename_and_move_name_the_folder_by_its_new_name_in_the_moved_row() {
    let mut w = world();
    let parent = folder(&mut w.vault, "Hobbies", None, Caller::Person);
    let f = folder(&mut w.vault, "Games", None, Caller::Agent);

    update(
        &mut w.vault,
        &f,
        FolderUpdate {
            name: Some("Play".into()),
            parent: Some(NewParent::Folder(parent)),
            pinned: None,
        },
        Caller::Person,
    );

    assert_eq!(kinds(&w.vault), ["folder_renamed", "folder_moved"]);
    let moved = rows(&w.vault)[1].correction.clone().unwrap();
    assert_eq!(moved["name"], "Play");
}

#[test]
fn a_racing_save_that_files_a_block_first_leaves_it_out_of_the_recorded_blocks() {
    let mut w = world();
    let topic = w.topic.clone();
    let mut attempts = 0;
    let mut hook = |v: &mut Vault| {
        attempts += 1;
        if attempts == 1 {
            // The agent files B7 between the person's read and write.
            add_excerpt(v, &topic, DAY, &ids(&[B7]), Caller::Agent, None).unwrap();
        }
    };

    add_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&[B7, F6]),
        Caller::Person,
        None,
        &mut hook,
    )
    .unwrap();

    assert_eq!(attempts, 2, "the first attempt lost the race");
    let all = rows(&w.vault);
    assert_eq!(all.len(), 1, "{all:?}");
    assert_eq!(all[0].correction.as_ref().unwrap()["block_id"], F6);
}

// ---------------------------------------------------------------------------
// AC 19: no path writes an Open row tied to a tag Correction
// ---------------------------------------------------------------------------

/// How many `feedback` rows are tied to a tag Correction yet still Open.
fn open_tag_linked(v: &Vault) -> i64 {
    v.connection_ref()
        .query_row(
            "SELECT count(*) FROM feedback
             WHERE tag_correction_id IS NOT NULL AND status = 'open'",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

#[test]
fn no_path_writes_a_tag_linked_feedback_row_that_is_open() {
    let mut w = world();
    let clock = FakeClock::at(T0);
    let topic = w.topic.clone();
    let a = tag_correction(&w.vault, Some(topic.as_str()), TOPIC, "one", T0, None);
    let b = tag_correction(&w.vault, Some(topic.as_str()), TOPIC, "two", T0 + 1, None);
    let lifted = tag_correction(&w.vault, Some(topic.as_str()), TOPIC, "three", T0 + 2, None);
    clear_tag(&w.vault, lifted, T0 + 3);

    // Reading and refused resolves write nothing.
    feedback::list_open(&w.vault).unwrap();
    feedback::list_for_note(&w.vault, Some(topic.as_str())).unwrap();
    let bad_reply = feedback::resolve(&mut w.vault, &format!("tag-{a}"), "", &[], &clock);
    assert_eq!(code_of(bad_reply, "bad reply"), "feedback_invalid");
    let too_many = [entry(&topic, &["a", "b", "c", "d"])];
    let bad_changes =
        feedback::resolve(&mut w.vault, &format!("tag-{a}"), "Ok.", &too_many, &clock);
    assert!(bad_changes.is_err());
    let lifted_id = format!("tag-{lifted}");
    let lifted_resolve = feedback::resolve(&mut w.vault, &lifted_id, "Ok.", &[], &clock);
    assert_eq!(code_of(lifted_resolve, "lifted"), "not_found");
    assert_eq!(count(&w.vault), 0);

    // Resolving writes a Handled row, never an Open one.
    let resolved = feedback::resolve(&mut w.vault, &format!("tag-{a}"), "Done.", &[], &clock)
        .expect("resolve tag");
    assert_eq!(resolved.status, "handled");
    let tied: Vec<Row> = rows(&w.vault)
        .into_iter()
        .filter(|r| r.tag_correction_id.is_some())
        .collect();
    assert_eq!(tied.len(), 1, "{tied:?}");
    assert_eq!(tied[0].tag_correction_id, Some(a));
    assert_eq!(tied[0].status, "handled");
    assert_eq!(tied[0].handled_at, Some(T0));

    // Every other operation, with the tags still around.
    let again = feedback::resolve(&mut w.vault, &format!("tag-{a}"), "Again.", &[], &clock);
    assert_eq!(code_of(again, "again"), "feedback_handled");
    let edited = feedback::edit(&mut w.vault, &resolved.id, "x", &clock);
    assert_eq!(code_of(edited, "edit"), "feedback_invalid");
    let deleted = feedback::delete(&mut w.vault, &resolved.id);
    assert_eq!(code_of(deleted, "delete"), "feedback_invalid");
    let c = comment_at(&mut w, "A comment.", T0 + 10);
    feedback::edit(&mut w.vault, &c.id, "Edited.", &clock).unwrap();
    feedback::resolve(&mut w.vault, &c.id, "Fixed.", &[], &clock).unwrap();
    feedback::record_chat(&mut w.vault, "Chat.", None, None, "Ok.", &[], &clock).unwrap();
    file(&mut w.vault, &topic, &[B7], Caller::Person);
    unfile_block(&mut w.vault, &topic, B7, Caller::Person);
    file(&mut w.vault, &topic, &[C3], Caller::Agent);
    unfile_block(&mut w.vault, &topic, C3, Caller::Person);

    assert_eq!(open_tag_linked(&w.vault), 0);
    let still_tied = rows(&w.vault)
        .iter()
        .filter(|r| r.tag_correction_id.is_some())
        .count();
    assert_eq!(still_tied, 1, "only the one resolve tied a row to a tag");
    let open_ids: Vec<String> = feedback::list_open(&w.vault)
        .unwrap()
        .into_iter()
        .map(|f| f.id)
        .filter(|id| id.starts_with("tag-"))
        .collect();
    assert_eq!(open_ids, [format!("tag-{b}")]);
}
