//! WI #10 (Spec #7 Req 23-25, 27, 28; rulings D7, D11): agent-edit
//! revisions and the person's Restore, `note_edits::{edit_note, revisions,
//! restore}`.
//!
//! - Each writing edit stores one `note_revisions` row (the previous person
//!   section, `previous_version`, `new_version`) linked to one `agent_changes`
//!   row dated `day` with the bullets, in the note's transaction. The newest
//!   20 per note are kept, by `new_version`; pruning keeps the `agent_changes`
//!   rows.
//! - Person saves keep no revision; Vault Guide revisions are unchanged.
//! - `restore` is a person write: it puts a revision's text back, keeps the
//!   replaced text as a new revision with the bullet `Restored an earlier
//!   version`, works on an Agent read-only note and re-derives body tags.
//!   Unknown, pruned or foreign revisions are `not_found`.
//!
//! Notes are flagged with raw SQL (ruling D15). Real SQLite, temp vaults, a
//! fake clock, invented note text.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fmt::Debug;

use memex_core::daily::{self, TOPICS_MARKER};
use memex_core::embedder::FakeEmbedder;
use memex_core::footer::{self, ChipOrigin};
use memex_core::guide;
use memex_core::indexer;
use memex_core::note_edits::{self, EditInput, EditOutcome, EditPair, NoteRevision};
use memex_core::notes::{self, get_note, update_note, CreateNote, Note, NoteId, UpdateNote};
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::{Caller, Clock, MemexError, Result, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const T0: i64 = 1_759_500_000_000;
const DAY: &str = "2026-09-05";
const RESTORE_DAY: &str = "2026-09-06";
const RESTORE_BULLET: &str = "Restored an earlier version";
const UNKNOWN_ID: &str = "01J9V6000000000000000000ZZ";
const UNKNOWN_REVISION: &str = "01J9V6000000000000000000RV";

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

fn fresh() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

fn note_fm(v: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
    let created = notes::create_note_as(
        v,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    indexer::reindex_note(
        v.connection_mut(),
        created.id.as_str(),
        &created.content_md,
        None,
    )
    .unwrap();
    get_note(v, &created.id).unwrap()
}

fn note(v: &mut Vault, title: &str, body: &str) -> Note {
    note_fm(v, title, body, None)
}

fn topic(v: &mut Vault, title: &str) -> Note {
    note_fm(
        v,
        title,
        &format!("{title} topic.\n"),
        Some(json!({"role": "topic"})),
    )
}

fn chip(v: &mut Vault, host: &Note, topic: &Note) -> Note {
    footer::set_chip(v, &host.id, &topic.id, ChipOrigin::Person, None)
        .unwrap()
        .note
}

fn current(v: &Vault, id: &NoteId) -> Note {
    get_note(v, id).unwrap()
}

fn flag(v: &Vault, id: &NoteId) {
    let n = v
        .connection_ref()
        .execute(
            "UPDATE notes SET agent_read_only = 1 WHERE id = ?",
            [id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "the note exists");
}

fn bullets(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn form_b(id: &NoteId, content: &str, version: i64, bullet: &str) -> EditInput {
    EditInput {
        note_id: id.clone(),
        bullets: bullets(&[bullet]),
        edits: None,
        content_md: Some(content.to_string()),
        expected_version: Some(version),
    }
}

/// A Form B edit of `id` to `content` at `now`, on the note's current version.
fn rewrite_at(v: &mut Vault, id: &NoteId, content: &str, now: i64) -> EditOutcome {
    let version = current(v, id).version;
    note_edits::edit_note(
        v,
        form_b(id, content, version, "Rewrote the note"),
        DAY,
        &FakeClock::at(now),
        None,
    )
    .unwrap()
}

fn rewrite(v: &mut Vault, id: &NoteId, content: &str) -> EditOutcome {
    rewrite_at(v, id, content, T0)
}

fn restore_at(
    v: &mut Vault,
    revision_id: &str,
    note_id: Option<&NoteId>,
    now: i64,
) -> Result<note_edits::RestoreOutcome> {
    note_edits::restore(
        v,
        revision_id,
        note_id,
        RESTORE_DAY,
        &FakeClock::at(now),
        None,
    )
}

fn person_of(body: &str) -> &str {
    &body[..daily::note_marker_start(body).unwrap_or(body.len())]
}

fn footer_of(body: &str) -> &str {
    &body[daily::note_marker_start(body).unwrap_or(body.len())..]
}

fn count(v: &Vault, sql: &str) -> i64 {
    v.connection_ref().query_row(sql, [], |r| r.get(0)).unwrap()
}

fn revision_count(v: &Vault, id: &NoteId) -> i64 {
    v.connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM note_revisions WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

fn change_count(v: &Vault, id: &NoteId) -> i64 {
    v.connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM agent_changes WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RevisionRow {
    id: String,
    note_id: String,
    previous_md: String,
    previous_version: i64,
    new_version: i64,
    agent_change_id: Option<String>,
    created_at: i64,
}

/// The note's revision rows, by `new_version` ascending.
fn revision_rows(v: &Vault, id: &NoteId) -> Vec<RevisionRow> {
    let conn = v.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, note_id, previous_md, previous_version, new_version, agent_change_id,
                    created_at
             FROM note_revisions WHERE note_id = ? ORDER BY new_version",
        )
        .unwrap();
    let rows = stmt
        .query_map([id.as_str()], |r| {
            Ok(RevisionRow {
                id: r.get(0)?,
                note_id: r.get(1)?,
                previous_md: r.get(2)?,
                previous_version: r.get(3)?,
                new_version: r.get(4)?,
                agent_change_id: r.get(5)?,
                created_at: r.get(6)?,
            })
        })
        .unwrap();
    rows.collect::<rusqlite::Result<_>>().unwrap()
}

/// The note's revision number `i` (0 = oldest kept), which must exist.
#[track_caller]
fn revision_at(v: &Vault, id: &NoteId, i: usize) -> RevisionRow {
    let rows = revision_rows(v, id);
    assert!(
        i < rows.len(),
        "expected revision {i} of the note, found {} revisions",
        rows.len()
    );
    rows[i].clone()
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ChangeRow {
    id: String,
    note_id: String,
    day: String,
    created_at: i64,
    bullets: Vec<String>,
}

fn change_row(v: &Vault, change_id: &str) -> ChangeRow {
    v.connection_ref()
        .query_row(
            "SELECT id, note_id, day, created_at, bullets_json FROM agent_changes WHERE id = ?",
            [change_id],
            |r| {
                let json: String = r.get(4)?;
                Ok(ChangeRow {
                    id: r.get(0)?,
                    note_id: r.get(1)?,
                    day: r.get(2)?,
                    created_at: r.get(3)?,
                    bullets: serde_json::from_str(&json).unwrap(),
                })
            },
        )
        .unwrap()
}

fn tag_rows(v: &Vault, id: &NoteId) -> Vec<(String, String)> {
    let conn = v.connection_ref();
    let mut stmt = conn
        .prepare("SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap();
    let rows = stmt
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap();
    rows.collect::<rusqlite::Result<_>>().unwrap()
}

fn fts_note_ids(v: &Vault, query: &str) -> BTreeSet<String> {
    search(
        v.connection_ref(),
        SearchOptions {
            query,
            k: 10,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap()
    .hits
    .into_iter()
    .map(|h| h.note_id)
    .collect()
}

/// Everything a refused write must leave alone.
#[derive(Debug, PartialEq)]
struct Snapshot {
    notes: Vec<(String, String, String, String, i64, i64, i64)>,
    tags: Vec<(String, String, String)>,
    revisions: Vec<(String, String, i64)>,
    changes: i64,
    content_revision: i64,
}

fn snapshot(v: &Vault) -> Snapshot {
    let conn = v.connection_ref();
    let notes = conn
        .prepare(
            "SELECT id, title, content_md, frontmatter, version, updated_at, agent_read_only
             FROM notes ORDER BY id",
        )
        .unwrap()
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let tags = conn
        .prepare("SELECT note_id, tag, origin FROM tags ORDER BY note_id, tag")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let revisions = conn
        .prepare("SELECT id, note_id, new_version FROM note_revisions ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    Snapshot {
        notes,
        tags,
        revisions,
        changes: count(v, "SELECT COUNT(*) FROM agent_changes"),
        content_revision: count(v, "SELECT n FROM content_revision WHERE id = 1"),
    }
}

#[track_caller]
fn expect_err<T: Debug>(result: Result<T>, code: &str) -> MemexError {
    match result {
        Err(e) => {
            assert_eq!(e.code(), code, "wrong error: {e:?}");
            e
        }
        Ok(ok) => panic!("expected {code}, got Ok({ok:?})"),
    }
}

/// `n` edited by `count` Form B rewrites, the clock moving back one second
/// per edit (a backward clock), so only `new_version` orders the revisions.
fn edited_times(v: &mut Vault, n: &Note, count: usize) {
    for i in 1..=count {
        rewrite_at(
            v,
            &n.id,
            &format!("Text number {i}.\n"),
            T0 - (i as i64) * 1_000,
        );
    }
}

/// Writes a revision row directly, for notes the engine never edits.
fn raw_revision(v: &Vault, id: &str, note_id: &NoteId, previous_md: &str, version: i64) {
    v.connection_ref()
        .execute(
            "INSERT INTO note_revisions
                 (id, note_id, previous_md, previous_version, new_version, agent_change_id,
                  created_at)
             VALUES (?, ?, ?, ?, ?, NULL, ?)",
            params![id, note_id.as_str(), previous_md, version - 1, version, T0],
        )
        .unwrap();
}

const FORCED_FAILURES: [&str; 3] = [
    "CREATE TRIGGER forced_failure BEFORE INSERT ON note_revisions
     BEGIN SELECT RAISE(ABORT, 'forced'); END;",
    "CREATE TRIGGER forced_failure BEFORE INSERT ON agent_changes
     BEGIN SELECT RAISE(ABORT, 'forced'); END;",
    "CREATE TRIGGER forced_failure BEFORE UPDATE OF content_md ON notes
     BEGIN SELECT RAISE(ABORT, 'forced'); END;",
];

// ---------------------------------------------------------------------------
// AC 22: one revision and one agent change per writing edit
// ---------------------------------------------------------------------------

#[test]
fn each_writing_edit_stores_one_revision_and_one_linked_agent_change() {
    let (_dir, mut v) = fresh();
    let pricing = topic(&mut v, "Pricing");
    let n = note(&mut v, "Plan", "Status: draft.\nOwner: the person.\n");
    let n = chip(&mut v, &n, &pricing);
    let clock = FakeClock::at(T0 + 42_000);

    let out = note_edits::edit_note(
        &mut v,
        EditInput {
            note_id: n.id.clone(),
            bullets: bullets(&["Moved the status to final", "Kept the owner"]),
            edits: Some(vec![EditPair {
                old_text: "draft".into(),
                new_text: "final".into(),
            }]),
            content_md: None,
            expected_version: None,
        },
        DAY,
        &clock,
        None,
    )
    .unwrap();

    let rows = revision_rows(&v, &n.id);
    assert_eq!(rows.len(), 1, "{rows:?}");
    let rev = &rows[0];
    assert_eq!(rev.note_id, n.id.as_str());
    assert_eq!(rev.previous_md, "Status: draft.\nOwner: the person.\n");
    assert_eq!(
        rev.previous_md,
        person_of(&n.content_md),
        "person section only"
    );
    assert_eq!(rev.previous_version, n.version);
    assert_eq!(rev.new_version, out.version);
    assert_eq!(out.version, n.version + 1);
    assert_eq!(rev.created_at, T0 + 42_000);
    assert_eq!(rev.id.len(), 26, "a ULID: {}", rev.id);

    let change_id = rev
        .agent_change_id
        .clone()
        .expect("linked to its agent change");
    assert_eq!(
        change_row(&v, &change_id),
        ChangeRow {
            id: change_id.clone(),
            note_id: n.id.to_string(),
            day: DAY.into(),
            created_at: T0 + 42_000,
            bullets: bullets(&["Moved the status to final", "Kept the owner"]),
        }
    );
    assert_eq!(change_count(&v, &n.id), 1);

    // A second edit adds one more of each.
    rewrite(&mut v, &n.id, "Status: shipped.\n");
    let rows = revision_rows(&v, &n.id);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].previous_md, "Status: final.\nOwner: the person.\n");
    assert_eq!(rows[1].previous_version, out.version);
    assert_ne!(rows[1].agent_change_id, rows[0].agent_change_id);
    assert_eq!(change_count(&v, &n.id), 2);
}

#[test]
fn the_revision_agent_change_and_note_commit_in_one_transaction() {
    for trigger in FORCED_FAILURES {
        let (_dir, mut v) = fresh();
        let n = note(&mut v, "Plan", "Plan #pricing.\n");
        let before = snapshot(&v);
        v.connection_ref().execute_batch(trigger).unwrap();

        // The edit also drops the #pricing body tag: that rolls back too.
        let result = note_edits::edit_note(
            &mut v,
            form_b(&n.id, "Plan without tags.\n", n.version, "Rewrote it"),
            DAY,
            &FakeClock::at(T0),
            None,
        );

        assert!(result.is_err(), "{trigger}: {result:?}");
        assert_eq!(snapshot(&v), before, "{trigger}");
    }
}

// ---------------------------------------------------------------------------
// AC 23: 20 revisions per note
// ---------------------------------------------------------------------------

#[test]
fn the_21st_revision_deletes_the_oldest_so_20_remain() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");

    edited_times(&mut v, &n, 20);
    let twenty = revision_rows(&v, &n.id);
    assert_eq!(twenty.len(), 20, "20 revisions prune nothing");
    assert_eq!(twenty[0].previous_md, "Text number 0.\n");

    edited_times_from(&mut v, &n, 21);
    let rows = revision_rows(&v, &n.id);
    assert_eq!(rows.len(), 20);
    let ids = |rows: &[RevisionRow]| rows.iter().map(|r| r.id.clone()).collect::<Vec<_>>();
    assert_eq!(
        ids(&rows[..19]),
        ids(&twenty[1..]),
        "the oldest by new_version went, though its clock time is the newest"
    );
    assert_eq!(rows[0].previous_md, "Text number 1.\n");
    assert_eq!(rows[19].previous_md, "Text number 20.\n");
}

/// One more rewrite, numbered `i`, on the backward clock of [`edited_times`].
fn edited_times_from(v: &mut Vault, n: &Note, i: i64) {
    rewrite_at(v, &n.id, &format!("Text number {i}.\n"), T0 - i * 1_000);
}

#[test]
fn an_agent_change_whose_revision_was_pruned_remains() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");
    edited_times(&mut v, &n, 20);
    let oldest = revision_at(&v, &n.id, 0);

    edited_times_from(&mut v, &n, 21);
    edited_times_from(&mut v, &n, 22);

    assert_eq!(revision_count(&v, &n.id), 20);
    assert_eq!(change_count(&v, &n.id), 22);
    let change_id = oldest.agent_change_id.unwrap();
    assert_eq!(
        change_row(&v, &change_id).bullets,
        bullets(&["Rewrote the note"])
    );
}

#[test]
fn pruning_counts_revisions_per_note() {
    let (_dir, mut v) = fresh();
    let a = note(&mut v, "Alpha plan", "Alpha.\n");
    let b = note(&mut v, "Beta plan", "Beta.\n");
    edited_times(&mut v, &a, 20);
    edited_times(&mut v, &b, 5);

    assert_eq!(revision_count(&v, &a.id), 20);
    assert_eq!(revision_count(&v, &b.id), 5);
    assert_eq!(count(&v, "SELECT COUNT(*) FROM note_revisions"), 25);

    edited_times_from(&mut v, &b, 6);
    assert_eq!(
        revision_count(&v, &a.id),
        20,
        "another note's edit prunes nothing here"
    );
    assert_eq!(revision_count(&v, &b.id), 6);
}

#[test]
fn pruning_runs_in_the_edit_transaction() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");
    edited_times(&mut v, &n, 20);
    v.connection_ref()
        .execute_batch(
            "CREATE TRIGGER forced_failure BEFORE DELETE ON note_revisions
             BEGIN SELECT RAISE(ABORT, 'forced'); END;",
        )
        .unwrap();
    let before = snapshot(&v);
    let version = current(&v, &n.id).version;

    let result = note_edits::edit_note(
        &mut v,
        form_b(&n.id, "Text number 21.\n", version, "Rewrote the note"),
        DAY,
        &FakeClock::at(T0),
        None,
    );

    assert!(result.is_err(), "{result:?}");
    assert_eq!(snapshot(&v), before);
}

// ---------------------------------------------------------------------------
// AC 24: person saves and the Vault Guide
// ---------------------------------------------------------------------------

#[test]
fn person_saves_create_no_revision_and_guide_revisions_stay_unlimited() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");
    rewrite(&mut v, &n.id, "Agent text.\n");
    let after_agent = current(&v, &n.id);
    let saved = update_note(
        &mut v,
        &n.id,
        after_agent.version,
        UpdateNote {
            content_md: Some("Person text.\n".into()),
            ..Default::default()
        },
    )
    .unwrap();
    update_note(
        &mut v,
        &n.id,
        saved.version,
        UpdateNote {
            content_md: Some("Person text, again.\n".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(revision_count(&v, &n.id), 1, "only the agent edit");

    let clock = FakeClock::at(T0);
    let mut doc = guide::get_or_create(&mut v, &clock, None).unwrap();
    for i in 0..22 {
        doc = guide::update(
            &mut v,
            doc.version,
            &format!("## Framework\n\nRule {i}.\n"),
            &bullets(&["Changed the guide"]),
            DAY,
            &clock,
            None,
        )
        .unwrap();
    }
    assert_eq!(count(&v, "SELECT COUNT(*) FROM vault_guide_revisions"), 22);
    let guide_id = NoteId::parse(&doc.note_id).unwrap();
    assert_eq!(revision_count(&v, &guide_id), 0);

    edited_times(&mut v, &n, 21);
    assert_eq!(revision_count(&v, &n.id), 20);
    assert_eq!(count(&v, "SELECT COUNT(*) FROM vault_guide_revisions"), 22);
}

// ---------------------------------------------------------------------------
// AC 25 and 26: Restore and its round-trip
// ---------------------------------------------------------------------------

#[test]
fn restore_replaces_the_person_section_and_keeps_the_replaced_text_as_a_new_revision() {
    let (_dir, mut v) = fresh();
    let pricing = topic(&mut v, "Pricing");
    let n = note(&mut v, "Plan", "The person's text.\n");
    let n = chip(&mut v, &n, &pricing);
    let edited = rewrite(&mut v, &n.id, "The agent's text.\n");
    let rev = revision_at(&v, &n.id, 0);
    v.connection_ref()
        .execute(
            "UPDATE notes SET updated_at = 1000 WHERE id = ?",
            [n.id.as_str()],
        )
        .unwrap();

    let out = restore_at(&mut v, &rev.id, None, T0 + 9_000).unwrap();

    let stored = current(&v, &n.id);
    let footer = footer_of(&n.content_md);
    assert_eq!(stored.content_md, format!("The person's text.\n{footer}"));
    assert_ne!(stored.updated_at, 1000, "updated_at moves");
    assert_eq!(out.note_id, n.id);
    assert_eq!(out.version, edited.version + 1);
    assert_eq!(stored.version, out.version);
    assert_eq!(out.content_md, stored.content_md);

    let rows = revision_rows(&v, &n.id);
    assert_eq!(rows.len(), 2);
    let kept = &rows[1];
    assert_eq!(kept.previous_md, "The agent's text.\n");
    assert_eq!(kept.previous_version, edited.version);
    assert_eq!(kept.new_version, out.version);
    assert_eq!(kept.created_at, T0 + 9_000);
    let change_id = kept.agent_change_id.clone().expect("linked");
    assert_ne!(Some(change_id.clone()), rev.agent_change_id);
    assert_eq!(
        change_row(&v, &change_id),
        ChangeRow {
            id: change_id.clone(),
            note_id: n.id.to_string(),
            day: RESTORE_DAY.into(),
            created_at: T0 + 9_000,
            bullets: bullets(&[RESTORE_BULLET]),
        }
    );
    assert_eq!(change_count(&v, &n.id), 2);
}

#[test]
fn restoring_the_restore_revision_brings_back_the_replaced_text() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "First text.\n");
    rewrite(&mut v, &n.id, "Second text.\n");
    let first_rev = revision_at(&v, &n.id, 0).id.clone();
    restore_at(&mut v, &first_rev, Some(&n.id), T0 + 1_000).unwrap();
    assert_eq!(current(&v, &n.id).content_md, "First text.\n");

    let restore_rev = revision_at(&v, &n.id, 1).id.clone();
    let out = restore_at(&mut v, &restore_rev, Some(&n.id), T0 + 2_000).unwrap();

    assert_eq!(out.content_md, "Second text.\n");
    assert_eq!(current(&v, &n.id).content_md, "Second text.\n");
    let rows = revision_rows(&v, &n.id);
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[2].previous_md, "First text.\n");
}

#[test]
fn restore_revisions_count_toward_the_20() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");
    edited_times(&mut v, &n, 20);
    let newest = revision_at(&v, &n.id, 19);
    let second = revision_at(&v, &n.id, 1);

    restore_at(&mut v, &newest.id, Some(&n.id), T0).unwrap();

    let after = revision_rows(&v, &n.id);
    assert_eq!(after.len(), 20);
    assert_eq!(after[0].id, second.id, "the oldest went");
    assert_eq!(after[19].previous_md, "Text number 20.\n");
}

#[test]
fn restore_commits_in_one_transaction() {
    for trigger in FORCED_FAILURES {
        let (_dir, mut v) = fresh();
        let n = note(&mut v, "Plan", "First text.\n");
        rewrite(&mut v, &n.id, "Second text.\n");
        let rev = revision_at(&v, &n.id, 0).id.clone();
        let before = snapshot(&v);
        v.connection_ref().execute_batch(trigger).unwrap();

        let result = restore_at(&mut v, &rev, Some(&n.id), T0);

        assert!(result.is_err(), "{trigger}: {result:?}");
        assert_eq!(snapshot(&v), before, "{trigger}");
    }
}

#[test]
fn restore_reindexes_the_restored_text() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Zoo plan", "Feed the quokkafile.\n");
    rewrite(&mut v, &n.id, "Feed the wombatfile.\n");
    let id = n.id.to_string();
    assert!(!fts_note_ids(&v, "quokkafile").contains(&id));
    let rev = revision_at(&v, &n.id, 0).id.clone();
    let embedder = FakeEmbedder::new(8);

    note_edits::restore(
        &mut v,
        &rev,
        None,
        RESTORE_DAY,
        &FakeClock::at(T0),
        Some(&embedder),
    )
    .unwrap();

    assert!(fts_note_ids(&v, "quokkafile").contains(&id));
    assert!(!fts_note_ids(&v, "wombatfile").contains(&id));
    let embedded = count(
        &v,
        &format!(
            "SELECT COUNT(*) FROM chunks WHERE note_id = '{id}' AND embed_model_version IS NOT NULL"
        ),
    );
    assert!(embedded > 0, "the embedder is used");
}

// ---------------------------------------------------------------------------
// AC 27: Restore is a person write
// ---------------------------------------------------------------------------

#[test]
fn restore_works_on_a_flagged_note() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Pricing notes", "Tier one costs ten.\n");
    rewrite(&mut v, &n.id, "Tier one costs twelve.\n");
    flag(&v, &n.id);
    let rev = revision_at(&v, &n.id, 0).id.clone();

    let out = restore_at(&mut v, &rev, Some(&n.id), T0).unwrap();

    assert_eq!(out.content_md, "Tier one costs ten.\n");
    assert_eq!(current(&v, &n.id).content_md, "Tier one costs ten.\n");
    let flag: i64 = v
        .connection_ref()
        .query_row(
            "SELECT agent_read_only FROM notes WHERE id = ?",
            [n.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(flag, 1, "Restore leaves the flag alone");
}

#[test]
fn restore_re_derives_body_tags_and_keeps_footer_and_title() {
    let (_dir, mut v) = fresh();
    let launch = topic(&mut v, "Launch");
    let fm = json!({"status": "draft"});
    let n = note_fm(&mut v, "Plan", "Plan #pricing.\n", Some(fm.clone()));
    let n = chip(&mut v, &n, &launch);
    let footer = footer_of(&n.content_md).to_string();
    assert!(footer.starts_with(TOPICS_MARKER));

    // The agent adds #roadmap (not a tag yet), then drops #pricing.
    rewrite(&mut v, &n.id, "Plan #pricing and #roadmap.\n");
    assert_eq!(tag_rows(&v, &n.id), vec![("pricing".into(), "body".into())]);
    rewrite(&mut v, &n.id, "Plan only.\n");
    assert!(tag_rows(&v, &n.id).is_empty());

    let rev = revision_at(&v, &n.id, 1);
    assert_eq!(rev.previous_md, "Plan #pricing and #roadmap.\n");
    restore_at(&mut v, &rev.id, Some(&n.id), T0).unwrap();

    let stored = current(&v, &n.id);
    assert_eq!(
        stored.content_md,
        format!("Plan #pricing and #roadmap.\n{footer}")
    );
    assert_eq!(stored.title, "Plan");
    assert_eq!(stored.frontmatter, fm);
    assert_eq!(
        tag_rows(&v, &n.id),
        vec![
            ("pricing".into(), "body".into()),
            ("roadmap".into(), "body".into()),
        ],
        "a person write re-derives every body tag"
    );
}

#[test]
fn restore_rebuilds_the_footer_from_the_current_rows() {
    let (_dir, mut v) = fresh();
    let pricing = topic(&mut v, "Pricing");
    let launch = topic(&mut v, "Launch");
    let n = note(&mut v, "Plan", "First text.\n");
    let n = chip(&mut v, &n, &pricing);
    rewrite(&mut v, &n.id, "Second text.\n");
    let edited = current(&v, &n.id);
    let with_two = chip(&mut v, &edited, &launch);
    let rev = revision_at(&v, &n.id, 0).id.clone();

    restore_at(&mut v, &rev, None, T0).unwrap();

    assert_eq!(
        current(&v, &n.id).content_md,
        format!("First text.\n{}", footer_of(&with_two.content_md))
    );
    assert!(footer_of(&with_two.content_md).contains("[[Launch~about]]"));
}

#[test]
fn restore_of_a_daily_note_or_guide_revision_is_refused() {
    let (_dir, mut v) = fresh();
    let day = note_fm(
        &mut v,
        "2026-09-04",
        "Morning pages.\n",
        Some(json!({"role": "daily"})),
    );
    raw_revision(
        &v,
        "01J9V60000000000000000DAY1",
        &day.id,
        "Old page.\n",
        day.version,
    );
    let doc = guide::get_or_create(&mut v, &FakeClock::at(T0), None).unwrap();
    let guide_id = NoteId::parse(&doc.note_id).unwrap();
    raw_revision(
        &v,
        "01J9V60000000000000000GDE1",
        &guide_id,
        "Old guide.\n",
        doc.version,
    );
    let before = snapshot(&v);

    let err = restore_at(&mut v, "01J9V60000000000000000DAY1", None, T0);
    assert!(matches!(err, Err(MemexError::RoleRule(_))), "{err:?}");
    assert_eq!(snapshot(&v), before);

    let err = restore_at(&mut v, "01J9V60000000000000000GDE1", Some(&guide_id), T0);
    assert!(matches!(err, Err(MemexError::GuideRule(_))), "{err:?}");
    assert_eq!(snapshot(&v), before);
}

// ---------------------------------------------------------------------------
// AC 28: unknown, pruned or foreign revisions
// ---------------------------------------------------------------------------

#[test]
fn restore_of_an_unknown_or_pruned_revision_is_not_found_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");
    edited_times(&mut v, &n, 20);
    let oldest = revision_at(&v, &n.id, 0).id.clone();
    edited_times_from(&mut v, &n, 21);
    let before = snapshot(&v);

    expect_err(restore_at(&mut v, UNKNOWN_REVISION, None, T0), "not_found");
    assert_eq!(snapshot(&v), before);
    expect_err(restore_at(&mut v, &oldest, None, T0), "not_found");
    assert_eq!(snapshot(&v), before);
    expect_err(restore_at(&mut v, &oldest, Some(&n.id), T0), "not_found");
    assert_eq!(snapshot(&v), before);
}

#[test]
fn restore_with_another_notes_id_is_not_found_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let owner = note(&mut v, "Owner", "Owner text.\n");
    let other = note(&mut v, "Other", "Other text.\n");
    rewrite(&mut v, &owner.id, "Owner text, edited.\n");
    let rev = revision_at(&v, &owner.id, 0).id.clone();
    let before = snapshot(&v);

    expect_err(restore_at(&mut v, &rev, Some(&other.id), T0), "not_found");
    assert_eq!(snapshot(&v), before);
    let unknown = NoteId::parse(UNKNOWN_ID).unwrap();
    expect_err(restore_at(&mut v, &rev, Some(&unknown), T0), "not_found");
    assert_eq!(snapshot(&v), before);

    let out = restore_at(&mut v, &rev, Some(&owner.id), T0).unwrap();
    assert_eq!(out.content_md, "Owner text.\n");
    assert_eq!(current(&v, &other.id).content_md, "Other text.\n");
}

// ---------------------------------------------------------------------------
// AC 29: listing
// ---------------------------------------------------------------------------

#[test]
fn revisions_lists_a_notes_revisions_newest_first() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "Text number 0.\n");
    let quiet = note(&mut v, "Quiet", "Never edited.\n");
    let other = note(&mut v, "Other", "Other text.\n");
    edited_times(&mut v, &n, 3);
    rewrite(&mut v, &other.id, "Other, edited.\n");

    let listed = note_edits::revisions(&v, &n.id).unwrap();

    let mut rows = revision_rows(&v, &n.id);
    rows.reverse();
    let expected: Vec<NoteRevision> = rows
        .iter()
        .map(|r| NoteRevision {
            id: r.id.clone(),
            agent_change_id: r.agent_change_id.clone(),
            created_at: r.created_at,
        })
        .collect();
    assert_eq!(listed.len(), 3);
    assert_eq!(
        listed, expected,
        "newest new_version first, whatever the clock"
    );
    assert!(listed.iter().all(|r| r.agent_change_id.is_some()));
    assert!(
        listed[0].created_at < listed[2].created_at,
        "the backward clock makes created_at disagree with the order"
    );

    assert!(note_edits::revisions(&v, &quiet.id).unwrap().is_empty());
}

#[test]
fn a_revision_whose_agent_change_is_gone_lists_no_agent_change_id() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Plan", "First text.\n");
    rewrite(&mut v, &n.id, "Second text.\n");
    let rev = revision_at(&v, &n.id, 0);
    v.connection_ref()
        .execute(
            "DELETE FROM agent_changes WHERE id = ?",
            [rev.agent_change_id.clone().unwrap()],
        )
        .unwrap();

    let listed = note_edits::revisions(&v, &n.id).unwrap();

    assert_eq!(
        listed,
        vec![NoteRevision {
            id: rev.id,
            agent_change_id: None,
            created_at: rev.created_at,
        }]
    );
}

#[test]
fn revisions_of_an_unknown_note_is_not_found() {
    let (_dir, v) = fresh();
    let unknown = NoteId::parse(UNKNOWN_ID).unwrap();

    expect_err(note_edits::revisions(&v, &unknown), "not_found");
}
