//! WI #10 (Spec #7 Req 11-22, rulings D7-D10): the core edit engine's agent
//! body edit, `note_edits::edit_note`.
//!
//! - Checks run in Req 11a order and the first failure answers: input shape
//!   (`edit_invalid`, then `change_entries_invalid`), `not_found`, the agent
//!   rules (`marker_rule`, `guide_rule`, `read_only_rule`), `version_conflict`,
//!   matching (`edit_not_found`, `edit_ambiguous`, then overlaps as
//!   `edit_invalid`), `excerpt_rule`, and the no-op check.
//! - Form A pairs match byte-exactly, once each, against the person section
//!   as it was before the call; all apply or none do. Form B replaces the
//!   whole person section and needs `expected_version`.
//! - The Note footer is rebuilt from its rows; title, frontmatter and role
//!   never change; transclusion tokens must stay the same multiset; links are
//!   re-extracted; body tags are only dropped; the note is reindexed.
//!
//! Revisions and Restore are in `note_edits_revisions.rs`. Notes are flagged
//! Agent read-only with raw SQL (ruling D15). Real SQLite, temp vaults, a
//! fake clock, invented note text.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fmt::Debug;
use std::sync::atomic::{AtomicUsize, Ordering};

use memex_core::daily::{self, TOPICS_MARKER};
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::footer::{self, ChipOrigin};
use memex_core::guide;
use memex_core::indexer;
use memex_core::links::links_out_for_note;
use memex_core::note_edits::{self, EditInput, EditOutcome, EditPair};
use memex_core::notes::{self, get_note, update_note, CreateNote, Note, NoteId, UpdateNote};
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::tags;
use memex_core::{Caller, Clock, MemexError, Result, Vault};
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const T0: i64 = 1_759_500_000_000;
const DAY: &str = "2026-09-05";
const UNKNOWN_ID: &str = "01J9V6000000000000000000ZZ";
const BULLET: &str = "Updated the status line";

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

/// A real embedder fake that counts its calls.
struct CountingEmbedder {
    inner: FakeEmbedder,
    calls: AtomicUsize,
}

impl CountingEmbedder {
    fn new() -> Self {
        Self {
            inner: FakeEmbedder::new(8),
            calls: AtomicUsize::new(0),
        }
    }
    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl Embedder for CountingEmbedder {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }
    fn dimension(&self) -> usize {
        self.inner.dimension()
    }
    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.inner.embed_batch(texts)
    }
}

fn fresh() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

/// A person-created note, indexed (so its links and chunks exist).
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

/// Puts a person chip for `topic` in `host`'s Note footer.
fn chip(v: &mut Vault, host: &Note, topic: &Note) -> Note {
    footer::set_chip(v, &host.id, &topic.id, ChipOrigin::Person, None)
        .unwrap()
        .note
}

fn daily_note(v: &mut Vault) -> Note {
    note_fm(
        v,
        "2026-09-04",
        "Morning pages.\n",
        Some(json!({"role": "daily"})),
    )
}

fn guide_note(v: &mut Vault) -> Note {
    let doc = guide::get_or_create(v, &FakeClock::at(T0), None).unwrap();
    get_note(v, &NoteId::parse(&doc.note_id).unwrap()).unwrap()
}

fn current(v: &Vault, id: &NoteId) -> Note {
    get_note(v, id).unwrap()
}

/// Flags the note Agent read-only the way R2's tests must (D15): raw SQL.
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

fn read_only_message(title: &str) -> String {
    format!("\"{title}\" is read-only for agents; the person can change this in the app")
}

fn person_save(v: &mut Vault, n: &Note, body: &str) -> Note {
    update_note(
        v,
        &n.id,
        n.version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
    )
    .unwrap()
}

fn bullets(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn pair(old: &str, new: &str) -> EditPair {
    EditPair {
        old_text: old.to_string(),
        new_text: new.to_string(),
    }
}

fn form_a(id: &NoteId, pairs: Vec<EditPair>, expected_version: Option<i64>) -> EditInput {
    EditInput {
        note_id: id.clone(),
        bullets: bullets(&[BULLET]),
        edits: Some(pairs),
        content_md: None,
        expected_version,
    }
}

fn form_b(id: &NoteId, content: &str, expected_version: Option<i64>) -> EditInput {
    EditInput {
        note_id: id.clone(),
        bullets: bullets(&[BULLET]),
        edits: None,
        content_md: Some(content.to_string()),
        expected_version,
    }
}

fn edit(v: &mut Vault, input: EditInput) -> Result<EditOutcome> {
    note_edits::edit_note(v, input, DAY, &FakeClock::at(T0), None)
}

/// The person section of a non-daily body: above the Note footer marker.
fn person_of(body: &str) -> &str {
    &body[..daily::note_marker_start(body).unwrap_or(body.len())]
}

/// The Note footer of a non-daily body, marker line included.
fn footer_of(body: &str) -> &str {
    &body[daily::note_marker_start(body).unwrap_or(body.len())..]
}

fn count(v: &Vault, sql: &str) -> i64 {
    v.connection_ref().query_row(sql, [], |r| r.get(0)).unwrap()
}

/// The note's tag rows as `(tag, origin)`, by name.
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

/// The note's outgoing links as `(link_text, to_note_id)`.
fn link_set(v: &Vault, id: &NoteId) -> BTreeSet<(String, Option<String>)> {
    links_out_for_note(v, id.as_str())
        .unwrap()
        .into_iter()
        .map(|l| (l.link_text, l.to_note_id))
        .collect()
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

/// Everything a refused (or no-op) edit must leave alone.
#[derive(Debug, PartialEq)]
struct Snapshot {
    notes: Vec<(String, String, String, String, i64, i64, i64)>,
    tags: Vec<(String, String, String, Option<String>)>,
    links: Vec<(String, String, String)>,
    chips: Vec<(String, String, String)>,
    corrections: Vec<(i64, String, Option<i64>)>,
    revisions: i64,
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
        .prepare("SELECT note_id, tag, origin, first_line FROM tags ORDER BY note_id, tag")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let links = conn
        .prepare(
            "SELECT from_note_id, link_text, link_kind FROM links
             ORDER BY from_note_id, position",
        )
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let chips = conn
        .prepare("SELECT daily_note_id, topic_note_id, origin FROM footer_chips ORDER BY rowid")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let corrections = conn
        .prepare("SELECT id, tag, cleared_at FROM tag_corrections ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    Snapshot {
        notes,
        tags,
        links,
        chips,
        corrections,
        revisions: count(v, "SELECT COUNT(*) FROM note_revisions"),
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

/// Runs `input` and asserts it fails with `code` and writes nothing.
#[track_caller]
fn refused(v: &mut Vault, input: EditInput, code: &str) -> MemexError {
    let before = snapshot(v);
    let err = expect_err(edit(v, input), code);
    assert_eq!(snapshot(v), before, "a refused edit writes nothing");
    err
}

#[track_caller]
fn edit_index(err: &MemexError) -> usize {
    match err {
        MemexError::EditNotFound { index, .. } | MemexError::EditAmbiguous { index, .. } => *index,
        other => panic!("not a matching error: {other:?}"),
    }
}

/// Asserts `outcome` wrote `expected_body` at `before.version + 1` and that
/// it is what the vault stores.
#[track_caller]
fn assert_written(v: &Vault, before: &Note, outcome: &EditOutcome, expected_body: &str) {
    let stored = current(v, &before.id);
    assert_eq!(outcome.note_id, before.id);
    assert!(outcome.changed, "a writing edit reports changed");
    assert_eq!(outcome.version, before.version + 1);
    assert_eq!(stored.version, before.version + 1);
    assert_eq!(stored.content_md, expected_body);
    assert_eq!(outcome.content_md, stored.content_md);
}

// ---------------------------------------------------------------------------
// AC 1: input shape is edit_invalid
// ---------------------------------------------------------------------------

#[test]
fn both_edits_and_content_md_or_neither_is_edit_invalid_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\n");

    let mut both = form_a(&n.id, vec![pair("draft", "final")], Some(n.version));
    both.content_md = Some("Status: final.\n".into());
    refused(&mut v, both, "edit_invalid");

    let mut neither = form_a(&n.id, vec![], Some(n.version));
    neither.edits = None;
    refused(&mut v, neither, "edit_invalid");
}

#[test]
fn an_empty_edits_list_or_an_empty_old_text_is_edit_invalid_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\n");

    refused(&mut v, form_a(&n.id, vec![], None), "edit_invalid");
    refused(
        &mut v,
        form_a(&n.id, vec![pair("draft", "final"), pair("", "x")], None),
        "edit_invalid",
    );
    refused(
        &mut v,
        form_a(&n.id, vec![pair("", "Status: final.")], Some(n.version)),
        "edit_invalid",
    );
}

#[test]
fn form_b_without_expected_version_is_edit_invalid_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\n");

    refused(
        &mut v,
        form_b(&n.id, "Status: final.\n", None),
        "edit_invalid",
    );
}

#[test]
fn input_shape_errors_come_before_not_found() {
    let (_dir, mut v) = fresh();
    let unknown = NoteId::parse(UNKNOWN_ID).unwrap();

    let mut both = form_a(&unknown, vec![pair("a", "b")], Some(1));
    both.content_md = Some("x\n".into());
    refused(&mut v, both, "edit_invalid");
    let mut neither = form_a(&unknown, vec![], Some(1));
    neither.edits = None;
    refused(&mut v, neither, "edit_invalid");
    refused(&mut v, form_a(&unknown, vec![], None), "edit_invalid");
    refused(
        &mut v,
        form_a(&unknown, vec![pair("", "b")], None),
        "edit_invalid",
    );
    refused(&mut v, form_b(&unknown, "x\n", None), "edit_invalid");
}

#[test]
fn edit_invalid_comes_before_change_entries_invalid() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\n");

    let mut input = form_b(&n.id, "Status: final.\n", None);
    input.bullets = vec![];
    refused(&mut v, input, "edit_invalid");
}

// ---------------------------------------------------------------------------
// AC 2: bullets
// ---------------------------------------------------------------------------

fn bad_bullet_lists() -> Vec<(&'static str, Vec<String>)> {
    vec![
        ("zero bullets", vec![]),
        ("four bullets", bullets(&["One", "Two", "Three", "Four"])),
        ("a bullet over 200 chars", vec!["x".repeat(201)]),
        ("201 multi-byte chars", vec!["\u{e9}".repeat(201)]),
        ("an empty bullet", bullets(&["Changed it", ""])),
        ("a whitespace-only bullet", bullets(&["   "])),
        ("a tab-only bullet", bullets(&["Changed it", "\t "])),
        ("a two-line bullet", bullets(&["Changed\nit"])),
        ("a list-prefixed bullet", bullets(&["- Changed it"])),
    ]
}

#[test]
fn bad_bullets_are_change_entries_invalid_and_write_nothing() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\n");

    for (case, list) in bad_bullet_lists() {
        let mut a = form_a(&n.id, vec![pair("draft", "final")], None);
        a.bullets = list.clone();
        let before = snapshot(&v);
        let err = edit(&mut v, a);
        assert!(
            matches!(err, Err(MemexError::ChangeEntriesInvalid(_))),
            "{case}: {err:?}"
        );
        assert_eq!(snapshot(&v), before, "{case}");

        let mut b = form_b(&n.id, "Status: final.\n", Some(n.version));
        b.bullets = list;
        let err = edit(&mut v, b);
        assert!(
            matches!(err, Err(MemexError::ChangeEntriesInvalid(_))),
            "{case}: {err:?}"
        );
        assert_eq!(snapshot(&v), before, "{case}");
    }
}

#[test]
fn the_bullet_check_runs_before_not_found() {
    let (_dir, mut v) = fresh();
    let unknown = NoteId::parse(UNKNOWN_ID).unwrap();

    for (case, list) in bad_bullet_lists() {
        let mut input = form_a(&unknown, vec![pair("draft", "final")], None);
        input.bullets = list;
        let err = edit(&mut v, input);
        assert!(
            matches!(err, Err(MemexError::ChangeEntriesInvalid(_))),
            "{case}: {err:?}"
        );
    }
}

#[test]
fn one_to_three_bullets_of_up_to_200_characters_are_accepted() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\n");

    let mut one = form_a(&n.id, vec![pair("draft", "review")], None);
    one.bullets = vec!["x".repeat(200)];
    let first = edit(&mut v, one).unwrap();
    assert!(first.changed);

    let mut three = form_a(&n.id, vec![pair("review", "final")], None);
    three.bullets = vec![
        "\u{e9}".repeat(200),
        "Moved the status on".into(),
        "  Padded but not blank  ".into(),
    ];
    let second = edit(&mut v, three).unwrap();
    assert!(second.changed);
    assert_eq!(current(&v, &n.id).content_md, "Status: final.\n");
}

// ---------------------------------------------------------------------------
// AC 3: not_found
// ---------------------------------------------------------------------------

#[test]
fn an_unknown_note_id_is_not_found() {
    let (_dir, mut v) = fresh();
    note(&mut v, "Status", "Status: draft.\n");
    let unknown = NoteId::parse(UNKNOWN_ID).unwrap();

    refused(
        &mut v,
        form_a(&unknown, vec![pair("draft", "final")], None),
        "not_found",
    );
    refused(
        &mut v,
        form_b(&unknown, "Status: final.\n", Some(1)),
        "not_found",
    );
}

// ---------------------------------------------------------------------------
// AC 4: agent rules, before the version check
// ---------------------------------------------------------------------------

/// Every input shape that gets past step 1, with the current version, a
/// stale one and (Form A) none; also one that would not match and a no-op.
fn rule_inputs(n: &Note, old_text: &str) -> Vec<(&'static str, EditInput)> {
    let stale = Some(n.version + 7);
    vec![
        (
            "form A, no version",
            form_a(&n.id, vec![pair(old_text, "Changed")], None),
        ),
        (
            "form A, current version",
            form_a(&n.id, vec![pair(old_text, "Changed")], Some(n.version)),
        ),
        (
            "form A, stale version",
            form_a(&n.id, vec![pair(old_text, "Changed")], stale),
        ),
        (
            "form A, no match, stale version",
            form_a(&n.id, vec![pair("text that is not there", "x")], stale),
        ),
        (
            "form A, no-op",
            form_a(&n.id, vec![pair(old_text, old_text)], None),
        ),
        (
            "form B, current version",
            form_b(&n.id, "Changed.\n", Some(n.version)),
        ),
        ("form B, stale version", form_b(&n.id, "Changed.\n", stale)),
    ]
}

#[test]
fn a_daily_note_is_marker_rule_even_with_a_stale_version() {
    let (_dir, mut v) = fresh();
    let day = daily_note(&mut v);

    for (case, input) in rule_inputs(&day, "Morning pages.") {
        let before = snapshot(&v);
        let err = edit(&mut v, input);
        assert!(
            matches!(err, Err(MemexError::MarkerRule(_))),
            "{case}: {err:?}"
        );
        assert_eq!(snapshot(&v), before, "{case}");
    }
}

#[test]
fn the_vault_guide_is_guide_rule_even_with_a_stale_version() {
    let (_dir, mut v) = fresh();
    let g = guide_note(&mut v);

    for (case, input) in rule_inputs(&g, "## Framework") {
        let before = snapshot(&v);
        let err = edit(&mut v, input);
        assert!(
            matches!(err, Err(MemexError::GuideRule(_))),
            "{case}: {err:?}"
        );
        assert_eq!(snapshot(&v), before, "{case}");
    }
}

#[test]
fn a_flagged_note_is_read_only_rule_even_with_a_stale_version() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Pricing notes", "Tier one costs ten.\n");
    let other = note(&mut v, "Open notes", "Anyone may edit this.\n");
    flag(&v, &n.id);

    for (case, input) in rule_inputs(&n, "Tier one costs ten.") {
        let before = snapshot(&v);
        match edit(&mut v, input) {
            Err(MemexError::ReadOnlyRule(message)) => {
                assert_eq!(message, read_only_message("Pricing notes"), "{case}")
            }
            other => panic!("{case}: expected read_only_rule, got {other:?}"),
        }
        assert_eq!(snapshot(&v), before, "{case}");
    }

    // The flag guards only its own note.
    let out = edit(
        &mut v,
        form_a(&other.id, vec![pair("Anyone", "Everyone")], None),
    )
    .unwrap();
    assert!(out.changed);
}

#[test]
fn a_flagged_daily_note_is_marker_rule() {
    let (_dir, mut v) = fresh();
    let day = daily_note(&mut v);
    flag(&v, &day.id);

    let err = edit(
        &mut v,
        form_a(
            &day.id,
            vec![pair("Morning", "Evening")],
            Some(day.version + 1),
        ),
    );
    assert!(matches!(err, Err(MemexError::MarkerRule(_))), "{err:?}");
}

// ---------------------------------------------------------------------------
// AC 5: Form A replaces one match
// ---------------------------------------------------------------------------

#[test]
fn one_old_text_that_matches_once_is_replaced_and_the_result_is_the_stored_body() {
    let (_dir, mut v) = fresh();
    let n = note(
        &mut v,
        "Project status",
        "# Project status\n\nStatus: draft.\nOwner: the person.\n",
    );
    backdate(&v, &n.id);

    let out = edit(
        &mut v,
        form_a(&n.id, vec![pair("draft", "in review")], None),
    )
    .unwrap();

    assert_written(
        &v,
        &n,
        &out,
        "# Project status\n\nStatus: in review.\nOwner: the person.\n",
    );
    assert_ne!(current(&v, &n.id).updated_at, BACKDATED, "updated_at moves");
}

const BACKDATED: i64 = 1_000;

/// Sets the note's `updated_at` far in the past, so any write moves it.
fn backdate(v: &Vault, id: &NoteId) {
    v.connection_ref()
        .execute(
            "UPDATE notes SET updated_at = ? WHERE id = ?",
            rusqlite::params![BACKDATED, id.as_str()],
        )
        .unwrap();
}

#[test]
fn several_pairs_apply_together_whatever_their_order() {
    let (_dir, mut v) = fresh();
    let n = note(
        &mut v,
        "Reading list",
        "Reading list\n- First book\n- Second book\n- Third book\n",
    );

    // Pairs listed out of position order; one deletes its text.
    let out = edit(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("Third book", "Last book"),
                pair("Reading list\n", "Books to read\n"),
                pair("- Second book\n", ""),
            ],
            Some(n.version),
        ),
    )
    .unwrap();

    assert_written(&v, &n, &out, "Books to read\n- First book\n- Last book\n");
}

// ---------------------------------------------------------------------------
// AC 6: no match and many matches
// ---------------------------------------------------------------------------

#[test]
fn an_old_text_with_no_match_is_edit_not_found_with_its_index() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Status", "Status: draft.\nOwner: the person.\n");

    let err = refused(
        &mut v,
        form_a(&n.id, vec![pair("missing", "x")], None),
        "edit_not_found",
    );
    assert_eq!(edit_index(&err), 0);

    // The first pair would apply; nothing does.
    let err = refused(
        &mut v,
        form_a(
            &n.id,
            vec![pair("draft", "final"), pair("Owner: an agent", "x")],
            None,
        ),
        "edit_not_found",
    );
    assert_eq!(edit_index(&err), 1);
    assert_eq!(current(&v, &n.id).content_md, n.content_md);
}

#[test]
fn an_old_text_with_two_or_more_matches_is_edit_ambiguous_with_its_index() {
    let (_dir, mut v) = fresh();
    let n = note(
        &mut v,
        "Tasks",
        "Task: write. Task: test.\nTask: ship.\nDone: plan.\n",
    );

    let err = refused(
        &mut v,
        form_a(
            &n.id,
            vec![pair("Done: plan.", "Done: all."), pair("Task:", "Todo:")],
            None,
        ),
        "edit_ambiguous",
    );
    assert_eq!(edit_index(&err), 1, "three matches");

    let err = refused(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("plan", "scope"),
                pair("ship", "release"),
                pair("Task: w", "x"),
                pair("te", "x"),
            ],
            None,
        ),
        "edit_ambiguous",
    );
    assert_eq!(edit_index(&err), 3, "two matches");
}

#[test]
fn the_first_failing_pair_in_index_order_answers() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Pairs", "one two two three\n");

    let err = refused(
        &mut v,
        form_a(
            &n.id,
            vec![pair("one", "1"), pair("two", "2"), pair("four", "4")],
            None,
        ),
        "edit_ambiguous",
    );
    assert_eq!(edit_index(&err), 1);

    let err = refused(
        &mut v,
        form_a(&n.id, vec![pair("four", "4"), pair("two", "2")], None),
        "edit_not_found",
    );
    assert_eq!(edit_index(&err), 0);
}

// ---------------------------------------------------------------------------
// AC 7: matched against the section before the call; overlaps; all or none
// ---------------------------------------------------------------------------

#[test]
fn pairs_match_the_person_section_as_it_was_before_the_call() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Pets", "A cat and a dog.\n");

    // One after another, the second pair would see two "dog"s.
    let out = edit(
        &mut v,
        form_a(&n.id, vec![pair("cat", "dog"), pair("dog", "bird")], None),
    )
    .unwrap();
    assert_written(&v, &n, &out, "A dog and a bird.\n");

    // Text that only the first pair would write does not match the second.
    let after = current(&v, &n.id);
    let err = refused(
        &mut v,
        form_a(
            &after.id,
            vec![pair("bird", "fish"), pair("fish", "cat")],
            None,
        ),
        "edit_not_found",
    );
    assert_eq!(edit_index(&err), 1);
}

#[test]
fn two_pairs_whose_ranges_overlap_are_edit_invalid_naming_both_indexes() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Greek", "alpha beta gamma delta\n");

    let err = refused(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("delta", "omega"),
                pair("alpha beta", "A B"),
                pair("beta gamma", "B G"),
            ],
            None,
        ),
        "edit_invalid",
    );
    let message = err.to_string();
    assert!(message.contains('1') && message.contains('2'), "{message}");

    // One range inside another overlaps too.
    refused(
        &mut v,
        form_a(
            &n.id,
            vec![pair("beta", "B"), pair("alpha beta gamma", "x")],
            None,
        ),
        "edit_invalid",
    );
    // So does the same text twice.
    refused(
        &mut v,
        form_a(&n.id, vec![pair("gamma", "G"), pair("gamma", "C")], None),
        "edit_invalid",
    );
}

#[test]
fn adjacent_ranges_do_not_overlap() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Greek", "alpha beta gamma\n");

    let out = edit(
        &mut v,
        form_a(&n.id, vec![pair(" beta", "-B"), pair("alpha", "A")], None),
    )
    .unwrap();

    assert_written(&v, &n, &out, "A-B gamma\n");
}

#[test]
fn a_matching_failure_comes_before_the_overlap_check() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Greek", "alpha beta gamma\n");

    let err = refused(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("alpha beta", "x"),
                pair("beta gamma", "y"),
                pair("epsilon", "z"),
            ],
            None,
        ),
        "edit_not_found",
    );
    assert_eq!(edit_index(&err), 2);
}

// ---------------------------------------------------------------------------
// AC 8: case- and byte-exact, multi-byte text
// ---------------------------------------------------------------------------

#[test]
fn matching_is_case_and_byte_exact_on_multi_byte_text() {
    let (_dir, mut v) = fresh();
    let body = "Caf\u{e9} \u{2615} menu: cr\u{e8}me br\u{fb}l\u{e9}e costs 3 \u{20ac}.\n";
    let n = note(&mut v, "Menu", body);

    for (case, old) in [
        ("other case", "Cr\u{e8}me"),
        ("no accents", "creme brulee"),
        ("decomposed e-acute", "Cafe\u{301}"),
        ("ASCII lookalike", "Cafe"),
    ] {
        let err = refused(
            &mut v,
            form_a(&n.id, vec![pair(old, "x")], None),
            "edit_not_found",
        );
        assert_eq!(edit_index(&err), 0, "{case}");
    }
    let err = refused(
        &mut v,
        form_a(&n.id, vec![pair("\u{e9}", "e")], None),
        "edit_ambiguous",
    );
    assert_eq!(edit_index(&err), 0);

    let out = edit(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("\u{20ac}", "EUR"),
                pair("cr\u{e8}me br\u{fb}l\u{e9}e", "tarte tatin"),
                pair("\u{2615}", "\u{1f375}"),
            ],
            None,
        ),
    )
    .unwrap();

    assert_written(
        &v,
        &n,
        &out,
        "Caf\u{e9} \u{1f375} menu: tarte tatin costs 3 EUR.\n",
    );
}

// ---------------------------------------------------------------------------
// AC 9 and 10: Form A versions
// ---------------------------------------------------------------------------

#[test]
fn form_a_without_expected_version_applies_after_an_unrelated_person_save() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Project", "Status: draft.\nNotes: none yet.\n");
    let saved = person_save(
        &mut v,
        &n,
        "Status: draft.\nNotes: the person typed here.\n",
    );
    assert_eq!(saved.version, n.version + 1);

    let out = edit(&mut v, form_a(&n.id, vec![pair("draft", "final")], None)).unwrap();

    assert_written(
        &v,
        &saved,
        &out,
        "Status: final.\nNotes: the person typed here.\n",
    );
}

#[test]
fn form_a_with_a_stale_expected_version_is_version_conflict() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Project", "Status: draft.\nNotes: none yet.\n");
    let saved = person_save(&mut v, &n, "Status: draft.\nNotes: typed.\n");

    let err = refused(
        &mut v,
        form_a(&n.id, vec![pair("draft", "final")], Some(n.version)),
        "version_conflict",
    );
    assert!(
        matches!(err, MemexError::VersionConflict { expected, current }
            if expected == n.version && current == saved.version),
        "{err:?}"
    );

    let out = edit(
        &mut v,
        form_a(&n.id, vec![pair("draft", "final")], Some(saved.version)),
    )
    .unwrap();
    assert_written(&v, &saved, &out, "Status: final.\nNotes: typed.\n");
}

#[test]
fn version_conflict_comes_before_matching() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Project", "Status: draft.\n");

    refused(
        &mut v,
        form_a(
            &n.id,
            vec![pair("not in the note", "x")],
            Some(n.version + 1),
        ),
        "version_conflict",
    );
}

// ---------------------------------------------------------------------------
// AC 11: matching stops at the footer marker
// ---------------------------------------------------------------------------

#[test]
fn old_text_matches_only_above_the_footer_marker() {
    let (_dir, mut v) = fresh();
    let pricing = topic(&mut v, "Pricing");
    let n = note(&mut v, "Plan", "Plan for Pricing work.\n");
    let n = chip(&mut v, &n, &pricing);
    assert!(
        n.content_md.contains("[[Pricing~about]]"),
        "{}",
        n.content_md
    );

    for old in ["[[Pricing~about]]", "Pricing~about", TOPICS_MARKER] {
        let err = refused(
            &mut v,
            form_a(&n.id, vec![pair(old, "x")], None),
            "edit_not_found",
        );
        assert_eq!(edit_index(&err), 0, "{old}");
    }

    // "Pricing" is in the footer too, but only the person section counts.
    let out = edit(
        &mut v,
        form_a(&n.id, vec![pair("Pricing", "pricing")], None),
    )
    .unwrap();
    let expected = format!("Plan for pricing work.\n{}", footer_of(&n.content_md));
    assert_written(&v, &n, &out, &expected);
}

// ---------------------------------------------------------------------------
// AC 12: Form B
// ---------------------------------------------------------------------------

#[test]
fn form_b_replaces_the_whole_person_section() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Summary", "Old summary.\n\nOld details.\n");

    let out = edit(
        &mut v,
        form_b(&n.id, "# Summary\n\nA new summary.\n", Some(n.version)),
    )
    .unwrap();

    assert_written(&v, &n, &out, "# Summary\n\nA new summary.\n");
}

#[test]
fn form_b_with_a_stale_version_is_version_conflict() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Summary", "Old summary.\n");
    let saved = person_save(&mut v, &n, "Old summary, edited.\n");

    let err = refused(
        &mut v,
        form_b(&n.id, "New summary.\n", Some(n.version)),
        "version_conflict",
    );
    assert!(
        matches!(err, MemexError::VersionConflict { expected, current }
            if expected == n.version && current == saved.version),
        "{err:?}"
    );
}

// ---------------------------------------------------------------------------
// AC 13: footer unchanged, typed footer lines dropped
// ---------------------------------------------------------------------------

/// A note with two chips and a footer tag in its Note footer.
fn note_with_footer(v: &mut Vault) -> Note {
    let pricing = topic(v, "Pricing");
    let launch = topic(v, "Launch");
    let n = note(v, "Plan", "Plan text.\nSecond line.\n");
    chip(v, &n, &pricing);
    chip(v, &n, &launch);
    tags::person_add_tag(v, &n.id, "urgent", None).unwrap();
    let n = current(v, &n.id);
    assert_eq!(
        footer_of(&n.content_md),
        format!("{TOPICS_MARKER}\n[[Pricing~about]]\n[[Launch~about]]\n#urgent\n"),
        "fixture footer"
    );
    n
}

#[test]
fn the_footer_is_unchanged_after_either_form() {
    let (_dir, mut v) = fresh();
    let n = note_with_footer(&mut v);
    let footer = footer_of(&n.content_md).to_string();
    let chips = snapshot(&v).chips;

    let a = edit(
        &mut v,
        form_a(&n.id, vec![pair("Second line.", "Line two.")], None),
    )
    .unwrap();
    assert_written(&v, &n, &a, &format!("Plan text.\nLine two.\n{footer}"));

    let after_a = current(&v, &n.id);
    let b = edit(&mut v, form_b(&n.id, "Rewritten.\n", Some(after_a.version))).unwrap();
    assert_written(&v, &after_a, &b, &format!("Rewritten.\n{footer}"));

    // Form B text without a final newline still gets the footer on its own line.
    let after_b = current(&v, &n.id);
    let c = edit(&mut v, form_b(&n.id, "No newline", Some(after_b.version))).unwrap();
    assert_written(&v, &after_b, &c, &format!("No newline\n{footer}"));

    assert_eq!(snapshot(&v).chips, chips);
    assert_eq!(
        tag_rows(&v, &n.id),
        vec![("urgent".into(), "person".into())]
    );
}

#[test]
fn footer_lines_typed_in_content_md_or_new_text_are_not_kept() {
    let (_dir, mut v) = fresh();
    let n = note_with_footer(&mut v);
    let footer = footer_of(&n.content_md).to_string();
    let typed = format!("{TOPICS_MARKER}\n[[Invented~about]]\n#typedtag\n");

    let b = edit(
        &mut v,
        form_b(&n.id, &format!("Rewritten.\n{typed}"), Some(n.version)),
    )
    .unwrap();
    assert_written(&v, &n, &b, &format!("Rewritten.\n{footer}"));

    let after_b = current(&v, &n.id);
    let a = edit(
        &mut v,
        form_a(
            &n.id,
            vec![pair("Rewritten.\n", &format!("Edited.\n{typed}"))],
            None,
        ),
    )
    .unwrap();
    assert_written(&v, &after_b, &a, &format!("Edited.\n{footer}"));

    assert_eq!(
        tag_rows(&v, &n.id),
        vec![("urgent".into(), "person".into())]
    );
    assert_eq!(snapshot(&v).chips.len(), 2);

    // A note with no footer rows stores no footer at all.
    let bare = note(&mut v, "Bare", "Bare text.\n");
    let out = edit(
        &mut v,
        form_b(
            &bare.id,
            &format!("Bare, edited.\n{typed}"),
            Some(bare.version),
        ),
    )
    .unwrap();
    assert_written(&v, &bare, &out, "Bare, edited.\n");
}

// ---------------------------------------------------------------------------
// AC 14: title, frontmatter and role
// ---------------------------------------------------------------------------

#[test]
fn title_frontmatter_and_role_are_unchanged_after_either_form() {
    let (_dir, mut v) = fresh();
    let fm = json!({"role": "topic", "status": "draft", "aliases": ["Launch"]});
    let n = note_fm(
        &mut v,
        "Launch plan",
        "# Launch plan\n\nShip it.\n",
        Some(fm.clone()),
    );

    edit(
        &mut v,
        form_a(
            &n.id,
            vec![pair("# Launch plan", "# Retitled in text")],
            None,
        ),
    )
    .unwrap();
    let after_a = current(&v, &n.id);
    assert_eq!(after_a.title, "Launch plan");
    assert_eq!(after_a.frontmatter, fm);

    edit(
        &mut v,
        form_b(
            &n.id,
            "---\nrole: daily\ntitle: Other\n---\n# Another heading\n",
            Some(after_a.version),
        ),
    )
    .unwrap();
    let after_b = current(&v, &n.id);
    assert_eq!(after_b.title, "Launch plan");
    assert_eq!(after_b.frontmatter, fm);
    assert!(!daily::is_daily(&after_b.frontmatter));
    assert_eq!(after_b.version, n.version + 2);
}

// ---------------------------------------------------------------------------
// AC 15: no-op
// ---------------------------------------------------------------------------

#[test]
fn an_edit_whose_result_is_byte_identical_is_a_no_op() {
    let (_dir, mut v) = fresh();
    let n = note_with_footer(&mut v);
    let person = person_of(&n.content_md).to_string();

    let cases = vec![
        (
            "form A, same text",
            form_a(&n.id, vec![pair("Plan text.", "Plan text.")], None),
        ),
        (
            "form A, pairs that rebuild the same text",
            form_a(
                &n.id,
                vec![pair("Plan ", "Plan "), pair("Second line.", "Second line.")],
                Some(n.version),
            ),
        ),
        (
            "form B, the person section",
            form_b(&n.id, &person, Some(n.version)),
        ),
        (
            "form B, the whole stored body",
            form_b(&n.id, &n.content_md, Some(n.version)),
        ),
    ];
    for (case, input) in cases {
        let before = snapshot(&v);
        let out = edit(&mut v, input).unwrap_or_else(|e| panic!("{case}: {e:?}"));
        assert!(!out.changed, "{case}");
        assert_eq!(out.note_id, n.id, "{case}");
        assert_eq!(out.version, n.version, "{case}");
        assert_eq!(out.content_md, n.content_md, "{case}");
        assert_eq!(snapshot(&v), before, "{case}: a no-op writes nothing");
    }
}

// ---------------------------------------------------------------------------
// AC 16 and 17: transclusion tokens
// ---------------------------------------------------------------------------

const TOKEN_A: &str = "![[2026-09-01#^b1]]";
const TOKEN_B: &str = "![[2026-09-02#^c1..^c3]]";

fn filed_note(v: &mut Vault) -> Note {
    note(
        v,
        "Filed",
        &format!("Intro line.\n\n{TOKEN_A}\n\nMiddle line.\n\n{TOKEN_B}\n\nOutro line.\n"),
    )
}

#[test]
fn an_edit_that_removes_adds_or_changes_a_transclusion_token_is_excerpt_rule() {
    let (_dir, mut v) = fresh();
    let n = filed_note(&mut v);
    let ver = Some(n.version);

    let cases = vec![
        (
            "form A removes a token",
            form_a(&n.id, vec![pair(TOKEN_A, "")], None),
        ),
        (
            "form A adds a token",
            form_a(
                &n.id,
                vec![pair("Outro line.", "Outro line. ![[2026-09-03#^d1]]")],
                None,
            ),
        ),
        (
            "form A changes a block id",
            form_a(&n.id, vec![pair("#^b1]]", "#^b2]]")], None),
        ),
        (
            "form A changes a date",
            form_a(&n.id, vec![pair("2026-09-01", "2026-09-11")], None),
        ),
        (
            "form A drops a range end",
            form_a(&n.id, vec![pair("..^c3", "")], None),
        ),
        (
            "form A duplicates a token",
            form_a(
                &n.id,
                vec![pair("Intro line.", &format!("Intro line. {TOKEN_B}"))],
                None,
            ),
        ),
        (
            "form B drops every token",
            form_b(&n.id, "Intro line.\n\nOutro line.\n", ver),
        ),
        (
            "form B keeps one token",
            form_b(&n.id, &format!("Intro.\n\n{TOKEN_A}\n"), ver),
        ),
    ];
    for (case, input) in cases {
        let before = snapshot(&v);
        let err = edit(&mut v, input);
        assert!(
            matches!(err, Err(MemexError::ExcerptRule(_))),
            "{case}: {err:?}"
        );
        assert_eq!(snapshot(&v), before, "{case}");
    }
}

#[test]
fn removing_one_of_two_identical_tokens_is_excerpt_rule() {
    let (_dir, mut v) = fresh();
    let n = note(
        &mut v,
        "Twice",
        &format!("First: {TOKEN_A}\nSecond: {TOKEN_A}\n"),
    );

    refused(
        &mut v,
        form_a(
            &n.id,
            vec![pair(&format!("Second: {TOKEN_A}"), "Second.")],
            None,
        ),
        "excerpt_rule",
    );
    refused(
        &mut v,
        form_b(&n.id, &format!("Only once: {TOKEN_A}\n"), Some(n.version)),
        "excerpt_rule",
    );
}

#[test]
fn a_matching_failure_comes_before_excerpt_rule() {
    let (_dir, mut v) = fresh();
    let n = filed_note(&mut v);

    let err = refused(
        &mut v,
        form_a(&n.id, vec![pair(TOKEN_A, ""), pair("not here", "x")], None),
        "edit_not_found",
    );
    assert_eq!(edit_index(&err), 1);
}

#[test]
fn moving_text_around_a_token_or_the_token_itself_succeeds() {
    let (_dir, mut v) = fresh();
    let n = filed_note(&mut v);

    // Text around a token, and a pair whose text holds the token unchanged.
    let a = edit(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("Intro line.", "Intro, revised."),
                pair(
                    &format!("{TOKEN_A}\n\nMiddle line."),
                    &format!("Middle first.\n\n{TOKEN_A}"),
                ),
            ],
            None,
        ),
    )
    .unwrap();
    assert_written(
        &v,
        &n,
        &a,
        &format!("Intro, revised.\n\nMiddle first.\n\n{TOKEN_A}\n\n{TOKEN_B}\n\nOutro line.\n"),
    );

    // Both tokens swap places and move to the end.
    let after = current(&v, &n.id);
    let moved = format!("Intro.\n\nOutro.\n\n{TOKEN_B}\n{TOKEN_A}\n");
    let b = edit(&mut v, form_b(&n.id, &moved, Some(after.version))).unwrap();
    assert_written(&v, &after, &b, &moved);
}

// ---------------------------------------------------------------------------
// AC 18: wikilinks are re-extracted
// ---------------------------------------------------------------------------

#[test]
fn wikilinks_added_or_removed_are_re_extracted() {
    let (_dir, mut v) = fresh();
    let alpha = note(&mut v, "Alpha", "Alpha.\n");
    let beta = note(&mut v, "Beta", "Beta.\n");
    let gamma = note(&mut v, "Gamma", "Gamma.\n");
    let delta = note(&mut v, "Delta", "Delta.\n");
    let n = note(&mut v, "Hub", "Links: [[Alpha]] and [[Delta]].\n");
    let some = |n: &Note| Some(n.id.to_string());
    assert_eq!(
        link_set(&v, &n.id),
        BTreeSet::from([
            ("Alpha".into(), some(&alpha)),
            ("Delta".into(), some(&delta))
        ])
    );

    edit(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("[[Alpha]]", "[[Beta]]"),
                pair(" and [[Delta]]", ""),
                pair("Links:", "Links: [[Gamma~extends]]"),
            ],
            None,
        ),
    )
    .unwrap();
    assert_eq!(
        current(&v, &n.id).content_md,
        "Links: [[Gamma~extends]] [[Beta]].\n"
    );
    assert_eq!(
        link_set(&v, &n.id),
        BTreeSet::from([("Beta".into(), some(&beta)), ("Gamma".into(), some(&gamma))])
    );

    let after = current(&v, &n.id);
    edit(
        &mut v,
        form_b(&n.id, "No links now.\n", Some(after.version)),
    )
    .unwrap();
    assert!(link_set(&v, &n.id).is_empty());
}

// ---------------------------------------------------------------------------
// AC 19 and 20: body tags, removals only
// ---------------------------------------------------------------------------

#[test]
fn a_body_tag_whose_text_the_edit_removed_is_dropped() {
    let (_dir, mut v) = fresh();
    let n = note(
        &mut v,
        "Tagged",
        "Plan #pricing and #launch.\nAlso #budget here.\nEnd.\n",
    );
    let body = |name: &str| (name.to_string(), "body".to_string());
    assert_eq!(
        tag_rows(&v, &n.id),
        vec![body("budget"), body("launch"), body("pricing")]
    );

    edit(
        &mut v,
        form_a(
            &n.id,
            vec![
                pair("Plan #pricing and #launch.", "Plan and launch."),
                pair("#budget", "`#budget`"),
                pair("End.", "End #pricing."),
            ],
            None,
        ),
    )
    .unwrap();

    // #launch is gone, #budget is now a code span, #pricing only moved.
    assert_eq!(tag_rows(&v, &n.id), vec![body("pricing")]);

    let after = current(&v, &n.id);
    edit(
        &mut v,
        form_b(&n.id, "No tags at all.\n", Some(after.version)),
    )
    .unwrap();
    assert!(tag_rows(&v, &n.id).is_empty());
}

#[test]
fn a_name_the_edit_adds_is_not_a_tag() {
    let (_dir, mut v) = fresh();
    note(&mut v, "Roadmap", "The #roadmap lives here.\n");
    let n = note(&mut v, "Plan", "Plan #pricing.\n");

    edit(
        &mut v,
        form_a(
            &n.id,
            vec![pair("Plan #pricing.", "Plan #pricing #roadmap #fresh.")],
            None,
        ),
    )
    .unwrap();

    assert_eq!(
        current(&v, &n.id).content_md,
        "Plan #pricing #roadmap #fresh.\n"
    );
    assert_eq!(
        tag_rows(&v, &n.id),
        vec![("pricing".into(), "body".into())],
        "no new tag, and no inbox or agent-authored"
    );
}

#[test]
fn a_name_the_person_removed_stays_removed_after_an_agent_edit_adds_it() {
    let (_dir, mut v) = fresh();
    note(&mut v, "Roadmap", "The #roadmap lives here.\n");

    // The person removed an agent's tag: a Correction blocks it.
    let n = note(&mut v, "Plan", "Plan.\n");
    tags::agent_tag_note(&mut v, &n.id, "roadmap", None).unwrap();
    let removal = tags::person_remove_tag(&mut v, &n.id, "roadmap", None).unwrap();
    assert!(removal.correction_id.is_some());
    let corrections = snapshot(&v).corrections;

    // The person deleted a body tag's text.
    let untagged = current(&v, &n.id);
    let written = person_save(&mut v, &untagged, "Plan #ideas.\n");
    person_save(&mut v, &written, "Plan.\n");
    assert!(tag_rows(&v, &n.id).is_empty());

    edit(
        &mut v,
        form_a(&n.id, vec![pair("Plan.", "Plan #roadmap #ideas.")], None),
    )
    .unwrap();

    assert_eq!(current(&v, &n.id).content_md, "Plan #roadmap #ideas.\n");
    assert!(tag_rows(&v, &n.id).is_empty(), "{:?}", tag_rows(&v, &n.id));
    assert_eq!(
        snapshot(&v).corrections,
        corrections,
        "the block stays open"
    );
    let again = tags::agent_tag_note(&mut v, &n.id, "roadmap", None);
    assert!(matches!(again, Err(MemexError::TagRemoved(_))), "{again:?}");
}

#[test]
fn footer_tags_are_unchanged_by_an_agent_edit() {
    let (_dir, mut v) = fresh();
    note(&mut v, "Roadmap", "The #roadmap lives here.\n");
    let n = note(&mut v, "Plan", "Plan #pricing.\n");
    tags::person_add_tag(&mut v, &n.id, "urgent", None).unwrap();
    tags::agent_tag_note(&mut v, &n.id, "roadmap", None).unwrap();
    let n = current(&v, &n.id);
    let footer = footer_of(&n.content_md).to_string();
    assert_eq!(footer, format!("{TOPICS_MARKER}\n#roadmap\n#urgent\n"));

    // Writing a footer tag's name in the text does not make it a body tag.
    let out = edit(
        &mut v,
        form_b(&n.id, "Rewritten, now #urgent.\n", Some(n.version)),
    )
    .unwrap();

    assert_written(&v, &n, &out, &format!("Rewritten, now #urgent.\n{footer}"));
    assert_eq!(
        tag_rows(&v, &n.id),
        vec![
            ("roadmap".into(), "agent".into()),
            ("urgent".into(), "person".into()),
        ]
    );
}

// ---------------------------------------------------------------------------
// AC 21: reindex
// ---------------------------------------------------------------------------

#[test]
fn the_edited_note_is_reindexed() {
    let (_dir, mut v) = fresh();
    let n = note(&mut v, "Zoo plan", "Feed the quokkafile daily.\n");
    let id = n.id.to_string();
    assert!(fts_note_ids(&v, "quokkafile").contains(&id));
    let embedder = CountingEmbedder::new();

    note_edits::edit_note(
        &mut v,
        form_a(&n.id, vec![pair("quokkafile", "wombatfile")], None),
        DAY,
        &FakeClock::at(T0),
        Some(&embedder),
    )
    .unwrap();

    assert!(fts_note_ids(&v, "wombatfile").contains(&id));
    assert!(
        !fts_note_ids(&v, "quokkafile").contains(&id),
        "the old text is gone"
    );
    assert!(embedder.calls() > 0, "the embedder is used");

    let after = current(&v, &n.id);
    edit(
        &mut v,
        form_b(&n.id, "Feed the koalafile.\n", Some(after.version)),
    )
    .unwrap();
    assert!(fts_note_ids(&v, "koalafile").contains(&id));
    assert!(!fts_note_ids(&v, "wombatfile").contains(&id));
}
