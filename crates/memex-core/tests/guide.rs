//! WI #252 (F3, Spec #233 R24-R31, rulings D5, D6, D7, D10, D15): the Vault
//! Guide core and `guide_rule`.
//!
//! - `guide::get_or_create` creates the one `role: guide` note on first read;
//!   two racing first reads leave one guide and both return it. Races are driven
//!   by two `Vault` handles on one directory and the `get_or_create_with_hook`
//!   seam, which runs between picking the free title and creating the note.
//! - `guide::update` is the agent's one write path and `guide::restore` a person
//!   write. Each commits the note, one `vault_guide_revisions` row and one
//!   `agent_changes` row in one transaction, then reindexes.
//! - `notes::check_agent_write` and the person guards in `update_note_as`,
//!   `delete_note_checked`, `create_or_adopt_note` and `add_member` fail with
//!   `guide_rule`.
//! - The guide is out of Unsorted and the graph, and in search.
//!
//! Real SQLite, real V6 schema, temp vaults, a fake clock. Fixtures that only
//! need a guide to exist write its row directly, so those tests fail on their
//! own assertion before the seed path exists.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fmt::Debug;
use std::sync::atomic::{AtomicUsize, Ordering};

use memex_core::app_reads::graph::{agent_changes, graph_links, graph_notes};
use memex_core::app_reads::topics::unsorted_notes;
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::graph::neighbors;
use memex_core::guide::{self, GuideDoc};
use memex_core::links::{links_out_for_note, update_link_as, LinkKind, UpdateLink};
use memex_core::notes::{
    self, check_agent_write, create_note_as, create_or_adopt_note, delete_note_checked, get_note,
    update_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::review::{self, ChangeEntry};
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::smart_folders as sf;
use memex_core::{indexer, Caller, Clock, MemexError, Result, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const T0: i64 = 1_759_500_000_000;
const DAY: &str = "2026-09-05";
const SEED_BODY: &str = "## Framework\n\n## Decisions\n";
const RESTORE_BULLET: &str = "Restored an earlier version";
const GUIDE_ID: &str = "01J9V6000000000000000000G1";
const UNKNOWN_ID: &str = "01J9V6000000000000000000ZZ";

struct FakeClock(Cell<i64>);

impl FakeClock {
    fn at(ms: i64) -> Self {
        Self(Cell::new(ms))
    }
    fn set(&self, ms: i64) {
        self.0.set(ms);
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

/// An embedder that always fails, so a reindex fails after the commit.
struct FailingEmbedder;

impl Embedder for FailingEmbedder {
    fn model_version(&self) -> &str {
        "failing-v1"
    }
    fn dimension(&self) -> usize {
        8
    }
    fn embed_batch(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>> {
        Err(MemexError::EmbedderInfer("forced".into()))
    }
}

fn fresh() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

/// A second handle on the vault, as another process would hold.
fn other_handle(dir: &TempDir) -> Vault {
    Vault::open(dir.path().join("vault")).unwrap()
}

fn clock() -> FakeClock {
    FakeClock::at(T0)
}

fn bullets(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// Writes a note row directly, so frontmatter may be anything.
fn row(vault: &Vault, id: &str, title: &str, body: &str, frontmatter: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES (?, ?, ?, ?, 1, ?, ?)",
            params![id, title, body, frontmatter, T0, T0],
        )
        .unwrap();
}

/// A guide that exists without the seed path having run.
fn guide_row(vault: &Vault) -> NoteId {
    row(
        vault,
        GUIDE_ID,
        "Vault Guide",
        SEED_BODY,
        r#"{"role":"guide"}"#,
    );
    NoteId::parse(GUIDE_ID).unwrap()
}

fn plain(vault: &mut Vault, title: &str) -> Note {
    notes::create_note(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: format!("{title} body.\n"),
            frontmatter: None,
        },
    )
    .unwrap()
}

fn seeded(vault: &mut Vault) -> GuideDoc {
    guide::get_or_create(vault, &clock(), None).unwrap()
}

fn note_of(vault: &Vault, doc: &GuideDoc) -> Note {
    get_note(vault, &NoteId::parse(&doc.note_id).unwrap()).unwrap()
}

fn count(vault: &Vault, sql: &str) -> i64 {
    vault
        .connection_ref()
        .query_row(sql, [], |r| r.get(0))
        .unwrap()
}

fn note_count(vault: &Vault) -> i64 {
    count(vault, "SELECT COUNT(*) FROM notes")
}

fn guide_count(vault: &Vault) -> i64 {
    count(
        vault,
        "SELECT COUNT(*) FROM notes
         WHERE CASE WHEN json_valid(frontmatter)
                    THEN json_extract(frontmatter, '$.role') END = 'guide'",
    )
}

fn revision_count(vault: &Vault) -> i64 {
    count(vault, "SELECT COUNT(*) FROM vault_guide_revisions")
}

fn change_count(vault: &Vault) -> i64 {
    count(vault, "SELECT COUNT(*) FROM agent_changes")
}

fn embedded_chunks(vault: &Vault, note_id: &str) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM chunks WHERE note_id = ? AND embed_model_version IS NOT NULL",
            [note_id],
            |r| r.get(0),
        )
        .unwrap()
}

#[derive(Debug, PartialEq, Eq)]
struct RevisionRow {
    id: String,
    note_id: String,
    previous_md: String,
    previous_version: i64,
    new_version: i64,
    agent_change_id: Option<String>,
    created_at: i64,
}

/// Every revision row, oldest written first.
fn revision_rows(vault: &Vault) -> Vec<RevisionRow> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, note_id, previous_md, previous_version, new_version, agent_change_id,
                    created_at
             FROM vault_guide_revisions ORDER BY rowid",
        )
        .unwrap();
    let rows = stmt
        .query_map([], |r| {
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

/// Everything a failed write must leave alone.
#[derive(Debug, PartialEq, Eq)]
struct Snapshot {
    notes: Vec<(String, String, String, String, i64, i64)>,
    revisions: i64,
    changes: i64,
}

fn snapshot(vault: &Vault) -> Snapshot {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, title, content_md, frontmatter, version, updated_at
             FROM notes ORDER BY id",
        )
        .unwrap();
    let notes = stmt
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    Snapshot {
        notes,
        revisions: revision_count(vault),
        changes: change_count(vault),
    }
}

fn fts_note_ids(vault: &Vault, query: &str) -> BTreeSet<String> {
    search(
        vault.connection_ref(),
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

#[track_caller]
fn assert_guide_rule<T: Debug>(result: Result<T>) {
    match result {
        Err(MemexError::GuideRule(_)) => {}
        other => panic!("expected guide_rule, got {other:?}"),
    }
}

fn body_patch(body: &str) -> UpdateNote {
    UpdateNote {
        content_md: Some(body.into()),
        ..Default::default()
    }
}

fn title_patch(title: &str) -> UpdateNote {
    UpdateNote {
        title: Some(title.into()),
        ..Default::default()
    }
}

fn frontmatter_patch(frontmatter: Value) -> UpdateNote {
    UpdateNote {
        frontmatter: Some(frontmatter),
        ..Default::default()
    }
}

fn guide_create_input(title: &str) -> CreateNote {
    CreateNote {
        title: Some(title.into()),
        content_md: "Mine.\n".into(),
        frontmatter: Some(json!({"role": "guide"})),
    }
}

/// The first of `Vault Guide`, `Vault Guide 2`, ... no note holds.
fn first_free_title(vault: &Vault) -> String {
    let taken = |title: &str| {
        vault
            .connection_ref()
            .query_row("SELECT COUNT(*) FROM notes WHERE title = ?", [title], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap()
            > 0
    };
    if !taken("Vault Guide") {
        return "Vault Guide".into();
    }
    (2..)
        .map(|n| format!("Vault Guide {n}"))
        .find(|title| !taken(title))
        .unwrap()
}

// ---------------------------------------------------------------------------
// AC 1: first read creates, later reads return
// ---------------------------------------------------------------------------

#[test]
fn first_get_or_create_creates_one_guide_titled_vault_guide_with_two_empty_sections() {
    let (_dir, mut v) = fresh();
    let doc = guide::get_or_create(&mut v, &FakeClock::at(T0), None).unwrap();

    assert_eq!(doc.content_md, SEED_BODY);
    assert_eq!(doc.version, 1);
    let note = note_of(&v, &doc);
    assert_eq!(note.title, "Vault Guide");
    assert!(notes::is_guide(&note.frontmatter), "{:?}", note.frontmatter);
    assert_eq!(note.content_md, SEED_BODY);
    assert_eq!(note.version, 1);
    assert_eq!(
        note.created_at, T0,
        "the seed takes its time from the clock"
    );
    assert_eq!(note.updated_at, T0);
    assert_eq!(note_count(&v), 1);
    assert_eq!(revision_count(&v), 0, "the seed is not a revision");
    assert_eq!(change_count(&v), 0, "the seed is not an agent change");
}

#[test]
fn later_get_or_create_returns_the_guide_unchanged_and_creates_nothing() {
    let (_dir, mut v) = fresh();
    let first = guide::get_or_create(&mut v, &FakeClock::at(T0), None).unwrap();
    let before = snapshot(&v);

    let embedder = CountingEmbedder::new();
    let later = guide::get_or_create(&mut v, &FakeClock::at(T0 + 60_000), Some(&embedder)).unwrap();

    assert_eq!(later, first);
    assert_eq!(snapshot(&v), before);
    assert_eq!(embedder.calls(), 0, "a read does not reindex");
}

#[test]
fn get_or_create_returns_the_current_text_after_later_writes() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let id = NoteId::parse(&seed.note_id).unwrap();

    update_note(&mut v, &id, seed.version, body_patch("Person text.\n")).unwrap();
    let after_person = seeded(&mut v);
    assert_eq!(after_person.note_id, seed.note_id);
    assert_eq!(after_person.version, seed.version + 1);
    assert_eq!(after_person.content_md, "Person text.\n");

    guide::update(
        &mut v,
        after_person.version,
        "Agent text.\n",
        &bullets(&["Rewrote it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    let after_agent = seeded(&mut v);
    assert_eq!(after_agent.note_id, seed.note_id);
    assert_eq!(after_agent.version, seed.version + 2);
    assert_eq!(after_agent.content_md, "Agent text.\n");
    assert_eq!(guide_count(&v), 1);
}

#[test]
fn get_or_create_finds_an_existing_guide_under_any_title() {
    let (_dir, mut v) = fresh();
    row(
        &v,
        GUIDE_ID,
        "Vault Guide 7",
        "Kept.\n",
        r#"{"role":"guide"}"#,
    );

    let doc = seeded(&mut v);

    assert_eq!(doc.note_id, GUIDE_ID);
    assert_eq!(doc.content_md, "Kept.\n");
    assert_eq!(note_count(&v), 1);
}

#[test]
fn get_or_create_matches_role_guide_exactly_and_survives_malformed_frontmatter() {
    let (_dir, mut v) = fresh();
    row(
        &v,
        "01J9V6000000000000000000A1",
        "Other case",
        "x\n",
        r#"{"role":"Guide"}"#,
    );
    row(
        &v,
        "01J9V6000000000000000000A2",
        "Array role",
        "x\n",
        r#"{"role":["guide"]}"#,
    );
    row(
        &v,
        "01J9V6000000000000000000A3",
        "Broken",
        "x\n",
        "not json",
    );

    let doc = seeded(&mut v);

    assert_ne!(doc.note_id, "01J9V6000000000000000000A1");
    assert_eq!(doc.content_md, SEED_BODY);
    assert_eq!(guide_count(&v), 1);
    assert_eq!(note_count(&v), 4);
}

#[test]
fn get_or_create_indexes_the_seed_with_the_embedder() {
    let (_dir, mut v) = fresh();
    let embedder = CountingEmbedder::new();

    let doc = guide::get_or_create(&mut v, &clock(), Some(&embedder)).unwrap();

    assert!(embedder.calls() > 0, "the seed is embedded");
    assert!(embedded_chunks(&v, &doc.note_id) > 0);
    assert!(fts_note_ids(&v, "Framework").contains(&doc.note_id));
}

#[test]
fn get_or_create_propagates_a_reindex_failure_without_retrying() {
    let (_dir, mut v) = fresh();
    let mut attempts = 0;

    let result =
        guide::get_or_create_with_hook(&mut v, &clock(), Some(&FailingEmbedder), &mut |_| {
            attempts += 1
        });

    assert!(
        matches!(result, Err(MemexError::EmbedderInfer(_))),
        "{result:?}"
    );
    assert_eq!(attempts, 1);
    assert_eq!(
        guide_count(&v),
        1,
        "the create committed before the reindex"
    );
    assert_eq!(seeded(&mut v).content_md, SEED_BODY);
    assert_eq!(guide_count(&v), 1);
}

// ---------------------------------------------------------------------------
// AC 2: the race
// ---------------------------------------------------------------------------

#[test]
fn two_racing_first_reads_create_exactly_one_guide_and_both_return_it() {
    let (dir, mut v) = fresh();
    let mut other = other_handle(&dir);
    let clock = clock();
    let mut winner = None;
    let mut hook_runs = 0;

    let loser = guide::get_or_create_with_hook(&mut v, &clock, None, &mut |_| {
        hook_runs += 1;
        winner = Some(guide::get_or_create(&mut other, &clock, None).unwrap());
    })
    .unwrap();

    let winner = winner.expect("the seam ran");
    assert_eq!(
        hook_runs, 1,
        "the loser finds the guide and creates nothing"
    );
    assert_eq!(loser, winner, "both handles return the same note");
    assert_eq!(guide_count(&v), 1);
    assert_eq!(note_count(&v), 1, "no `Vault Guide 2` is left behind");
    assert_eq!(note_of(&v, &loser).title, "Vault Guide");
    assert_eq!(
        guide::get_or_create(&mut other, &clock, None).unwrap(),
        winner
    );
}

#[test]
fn a_loser_on_the_guide_index_returns_the_winners_note() {
    let (dir, mut v) = fresh();
    let other = other_handle(&dir);
    let mut hook_runs = 0;

    // The winner holds a different title, so only `idx_notes_guide` can reject
    // the loser's create.
    let loser = guide::get_or_create_with_hook(&mut v, &clock(), None, &mut |_| {
        hook_runs += 1;
        row(
            &other,
            GUIDE_ID,
            "Winner",
            "Winner text.\n",
            r#"{"role":"guide"}"#,
        );
    })
    .unwrap();

    assert_eq!(hook_runs, 1);
    assert_eq!(loser.note_id, GUIDE_ID);
    assert_eq!(loser.content_md, "Winner text.\n");
    assert_eq!(note_count(&v), 1);
}

#[test]
fn a_title_taken_during_the_first_read_moves_the_guide_to_the_next_free_title() {
    let (dir, mut v) = fresh();
    let mut other = other_handle(&dir);
    let mut hook_runs = 0;

    let doc = guide::get_or_create_with_hook(&mut v, &clock(), None, &mut |_| {
        hook_runs += 1;
        if hook_runs == 1 {
            plain(&mut other, "Vault Guide");
        }
    })
    .unwrap();

    assert_eq!(hook_runs, 2, "one attempt per picked title");
    assert_eq!(note_of(&v, &doc).title, "Vault Guide 2");
    assert_eq!(guide_count(&v), 1);
    assert_eq!(note_count(&v), 2);
}

#[test]
fn get_or_create_gives_up_after_bounded_retries_with_the_last_error() {
    let (dir, mut v) = fresh();
    let mut other = other_handle(&dir);
    let mut hook_runs = 0;

    let result = guide::get_or_create_with_hook(&mut v, &clock(), None, &mut |_| {
        hook_runs += 1;
        assert!(hook_runs <= 1_000, "get_or_create retries without a bound");
        let title = first_free_title(&other);
        plain(&mut other, &title);
    });

    assert!(
        matches!(result, Err(MemexError::TitleConflict { .. })),
        "{result:?}"
    );
    // Five create attempts in all (`CREATE_ATTEMPTS`): the bound is exact, so an
    // off-by-one in the retry check shows here.
    assert_eq!(hook_runs, 5, "create attempts before giving up");
    assert_eq!(guide_count(&v), 0);
}

#[test]
fn get_or_create_returns_any_other_create_failure_without_retrying() {
    let (_dir, mut v) = fresh();
    v.connection_ref()
        .execute_batch(
            "CREATE TRIGGER forced_failure BEFORE INSERT ON notes
             BEGIN SELECT RAISE(ABORT, 'forced'); END;",
        )
        .unwrap();
    let mut hook_runs = 0;

    let result = guide::get_or_create_with_hook(&mut v, &clock(), None, &mut |_| hook_runs += 1);

    assert!(result.is_err(), "{result:?}");
    assert_eq!(hook_runs, 1);
    assert_eq!(note_count(&v), 0);
}

// ---------------------------------------------------------------------------
// AC 3: seed title
// ---------------------------------------------------------------------------

#[test]
fn a_note_already_titled_vault_guide_seeds_the_guide_as_vault_guide_2() {
    let (_dir, mut v) = fresh();
    let existing = plain(&mut v, "Vault Guide");

    let doc = seeded(&mut v);

    let note = note_of(&v, &doc);
    assert_eq!(note.title, "Vault Guide 2");
    assert!(notes::is_guide(&note.frontmatter));
    assert_ne!(doc.note_id, existing.id.as_str());
    let kept = get_note(&v, &existing.id).unwrap();
    assert_eq!(kept.title, "Vault Guide");
    assert_eq!(kept.content_md, existing.content_md);
    assert_eq!(kept.version, existing.version);
    assert!(!notes::is_guide(&kept.frontmatter));
}

#[test]
fn the_seed_title_is_the_first_free_one() {
    let (_dir, mut v) = fresh();
    plain(&mut v, "Vault Guide");
    plain(&mut v, "Vault Guide 2");
    let third = seeded(&mut v);
    assert_eq!(note_of(&v, &third).title, "Vault Guide 3");

    // A gap is filled from the bare title up, and `Vault Guide 1` is never used.
    let (_dir, mut v) = fresh();
    plain(&mut v, "Vault Guide 2");
    let bare = seeded(&mut v);
    assert_eq!(note_of(&v, &bare).title, "Vault Guide");
}

// ---------------------------------------------------------------------------
// AC 4-6: update
// ---------------------------------------------------------------------------

#[test]
fn update_with_the_current_version_writes_text_one_revision_and_one_agent_change() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let later = T0 + 5_000;

    let doc = guide::update(
        &mut v,
        seed.version,
        "## Framework\n\nUse zebrafile.\n",
        &bullets(&["Added a rule", "Reworded a section"]),
        DAY,
        &FakeClock::at(later),
        None,
    )
    .unwrap();

    // The note.
    assert_eq!(doc.note_id, seed.note_id);
    assert_eq!(doc.version, seed.version + 1);
    assert_eq!(doc.content_md, "## Framework\n\nUse zebrafile.\n");
    let note = note_of(&v, &doc);
    assert_eq!(note.content_md, doc.content_md);
    assert_eq!(note.version, doc.version);
    assert_eq!(
        note.updated_at, later,
        "the write takes its time from the clock"
    );
    assert_eq!(note.created_at, T0);

    // Exactly one agent_changes row.
    assert_eq!(change_count(&v), 1);
    let changes = agent_changes(&v, &doc.note_id).unwrap();
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].day, DAY, "the given day, not the clock's");
    assert_eq!(changes[0].created_at, later);
    assert_eq!(changes[0].bullets, ["Added a rule", "Reworded a section"]);

    // Exactly one revision, holding the previous text and versions, linked to it.
    let revisions = revision_rows(&v);
    assert_eq!(revisions.len(), 1);
    assert_eq!(revisions[0].note_id, doc.note_id);
    assert_eq!(revisions[0].previous_md, SEED_BODY);
    assert_eq!(revisions[0].previous_version, seed.version);
    assert_eq!(revisions[0].new_version, doc.version);
    assert_eq!(
        revisions[0].agent_change_id.as_deref(),
        Some(changes[0].id.as_str())
    );
    assert_eq!(revisions[0].created_at, later);
}

#[test]
fn each_update_writes_one_revision_and_one_agent_change() {
    let (_dir, mut v) = fresh();
    let mut doc = seeded(&mut v);

    for (n, text) in ["One.\n", "Two.\n", "Three.\n"].into_iter().enumerate() {
        let previous = doc.clone();
        doc = guide::update(
            &mut v,
            doc.version,
            text,
            &bullets(&["Changed it"]),
            DAY,
            &clock(),
            None,
        )
        .unwrap();
        let written = n as i64 + 1;
        assert_eq!(revision_count(&v), written);
        assert_eq!(change_count(&v), written);
        let newest = revision_rows(&v).pop().unwrap();
        assert_eq!(newest.previous_md, previous.content_md);
        assert_eq!(newest.previous_version, previous.version);
        assert_eq!(newest.new_version, doc.version);
    }
    assert_eq!(note_count(&v), 1);
}

#[test]
fn update_keeps_the_guides_title_and_frontmatter() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let id = NoteId::parse(&seed.note_id).unwrap();
    let frontmatter = json!({"role": "guide", "kept": true});
    let saved = update_note(
        &mut v,
        &id,
        seed.version,
        frontmatter_patch(frontmatter.clone()),
    )
    .unwrap();

    let doc = guide::update(
        &mut v,
        saved.version,
        "# A heading that is not the title\n",
        &bullets(&["Rewrote it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();

    let note = note_of(&v, &doc);
    assert_eq!(note.title, "Vault Guide");
    assert_eq!(note.frontmatter, frontmatter);
}

#[test]
fn update_with_a_stale_version_fails_with_version_conflict_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let current = guide::update(
        &mut v,
        seed.version,
        "Current.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    let before = snapshot(&v);

    // Older than current, and newer than current.
    for expected in [current.version - 1, current.version + 1] {
        let result = guide::update(
            &mut v,
            expected,
            "Clobbered.\n",
            &bullets(&["Changed it"]),
            DAY,
            &FakeClock::at(T0 + 1_000),
            None,
        );
        match result {
            Err(MemexError::VersionConflict {
                expected: e,
                current: c,
            }) => {
                assert_eq!(e, expected);
                assert_eq!(c, current.version);
            }
            other => panic!("expected version_conflict for {expected}, got {other:?}"),
        }
        assert_eq!(snapshot(&v), before);
    }
}

#[test]
fn update_with_invalid_bullets_fails_with_change_entries_invalid_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let before = snapshot(&v);
    let too_long = "x".repeat(201);

    let cases: Vec<(&str, Vec<String>)> = vec![
        ("no bullets", bullets(&[])),
        ("four bullets", bullets(&["a", "b", "c", "d"])),
        ("a newline", bullets(&["one\ntwo"])),
        ("a carriage return", bullets(&["one\rtwo"])),
        ("201 characters", vec![too_long]),
        ("a list prefix", bullets(&["- did a thing"])),
    ];
    for (why, items) in cases {
        let result = guide::update(
            &mut v,
            seed.version,
            "Changed.\n",
            &items,
            DAY,
            &clock(),
            None,
        );
        assert!(
            matches!(result, Err(MemexError::ChangeEntriesInvalid(_))),
            "{why}: {result:?}"
        );
        assert_eq!(snapshot(&v), before, "{why}");
    }
}

#[test]
fn update_accepts_one_to_three_bullets_of_up_to_200_characters() {
    let (_dir, mut v) = fresh();
    let mut doc = seeded(&mut v);
    let longest = "é".repeat(200);

    let cases: Vec<Vec<String>> = vec![
        bullets(&["one"]),
        bullets(&["one", "two", "three"]),
        vec![longest],
    ];
    for items in cases {
        doc = guide::update(
            &mut v,
            doc.version,
            "Changed.\n",
            &items,
            DAY,
            &clock(),
            None,
        )
        .unwrap();
        let changes = agent_changes(&v, &doc.note_id).unwrap();
        assert!(changes.iter().any(|c| c.bullets == items), "{items:?}");
    }
}

#[test]
fn update_before_the_guide_exists_fails_and_creates_nothing() {
    let (_dir, mut v) = fresh();

    let result = guide::update(
        &mut v,
        1,
        "Text.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    );

    assert!(result.is_err(), "{result:?}");
    assert_eq!(note_count(&v), 0);
    assert_eq!(revision_count(&v), 0);
    assert_eq!(change_count(&v), 0);
}

/// Each of the three writes fails in turn: nothing of the others may remain.
const FORCED_FAILURES: [&str; 3] = [
    "CREATE TRIGGER forced_failure BEFORE UPDATE OF content_md ON notes
     BEGIN SELECT RAISE(ABORT, 'forced'); END;",
    "CREATE TRIGGER forced_failure BEFORE INSERT ON vault_guide_revisions
     BEGIN SELECT RAISE(ABORT, 'forced'); END;",
    "CREATE TRIGGER forced_failure BEFORE INSERT ON agent_changes
     BEGIN SELECT RAISE(ABORT, 'forced'); END;",
];

#[test]
fn update_commits_the_note_revision_and_agent_change_in_one_transaction() {
    for trigger in FORCED_FAILURES {
        let (_dir, mut v) = fresh();
        let seed = seeded(&mut v);
        let before = snapshot(&v);
        v.connection_ref().execute_batch(trigger).unwrap();

        let result = guide::update(
            &mut v,
            seed.version,
            "Changed.\n",
            &bullets(&["Changed it"]),
            DAY,
            &FakeClock::at(T0 + 1_000),
            None,
        );

        assert!(result.is_err(), "{trigger}: {result:?}");
        assert_eq!(snapshot(&v), before, "{trigger}");
    }
}

#[test]
fn update_reindexes_the_new_text() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let embedder = CountingEmbedder::new();

    let first = guide::update(
        &mut v,
        seed.version,
        "Use zebrafile here.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        Some(&embedder),
    )
    .unwrap();
    assert!(embedder.calls() > 0);
    assert!(embedded_chunks(&v, &first.note_id) > 0);
    assert!(fts_note_ids(&v, "zebrafile").contains(&first.note_id));

    guide::update(
        &mut v,
        first.version,
        "Use quokkafile here.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    assert!(fts_note_ids(&v, "quokkafile").contains(&first.note_id));
    assert!(
        fts_note_ids(&v, "zebrafile").is_empty(),
        "the old text is gone"
    );
}

#[test]
fn update_propagates_a_reindex_failure_after_the_commit() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);

    let result = guide::update(
        &mut v,
        seed.version,
        "Committed.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        Some(&FailingEmbedder),
    );

    assert!(
        matches!(result, Err(MemexError::EmbedderInfer(_))),
        "{result:?}"
    );
    let doc = seeded(&mut v);
    assert_eq!(doc.content_md, "Committed.\n");
    assert_eq!(doc.version, seed.version + 1);
    assert_eq!(revision_count(&v), 1);
    assert_eq!(change_count(&v), 1);
}

// ---------------------------------------------------------------------------
// AC 7: restore
// ---------------------------------------------------------------------------

/// A guide at `Second.\n`, with one revision holding `First.\n`.
fn guide_with_a_revision(v: &mut Vault) -> (GuideDoc, String) {
    let seed = seeded(v);
    let first = guide::update(
        v,
        seed.version,
        "First.\n",
        &bullets(&["Wrote first"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    let second = guide::update(
        v,
        first.version,
        "Second.\n",
        &bullets(&["Wrote second"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    let revision = revision_rows(v)
        .into_iter()
        .find(|r| r.previous_md == "First.\n")
        .unwrap();
    (second, revision.id)
}

#[test]
fn restore_replaces_the_text_keeps_the_replaced_text_and_writes_one_agent_change() {
    let (_dir, mut v) = fresh();
    let (current, revision_id) = guide_with_a_revision(&mut v);
    let revisions_before = revision_count(&v);
    let changes_before = change_count(&v);
    let later = T0 + 9_000;
    let restore_day = "2026-09-07";

    let doc = guide::restore(
        &mut v,
        &revision_id,
        restore_day,
        &FakeClock::at(later),
        None,
    )
    .unwrap();

    // The text is the revision's.
    assert_eq!(doc.note_id, current.note_id);
    assert_eq!(doc.content_md, "First.\n");
    assert_eq!(doc.version, current.version + 1);
    let note = note_of(&v, &doc);
    assert_eq!(note.content_md, "First.\n");
    assert_eq!(note.version, doc.version);
    assert_eq!(note.updated_at, later);
    assert_eq!(note.title, "Vault Guide");
    assert!(notes::is_guide(&note.frontmatter));

    // One new agent_changes row with the restore bullet.
    assert_eq!(change_count(&v), changes_before + 1);
    let changes = agent_changes(&v, &doc.note_id).unwrap();
    let change = changes.iter().find(|c| c.day == restore_day).unwrap();
    assert_eq!(change.bullets, [RESTORE_BULLET]);
    assert_eq!(change.created_at, later);

    // One new revision, keeping the replaced text and linking its own row.
    assert_eq!(revision_count(&v), revisions_before + 1);
    let newest = revision_rows(&v).pop().unwrap();
    assert_eq!(newest.note_id, doc.note_id);
    assert_eq!(newest.previous_md, "Second.\n");
    assert_eq!(newest.previous_version, current.version);
    assert_eq!(newest.new_version, doc.version);
    assert_eq!(newest.agent_change_id.as_deref(), Some(change.id.as_str()));
    assert_eq!(newest.created_at, later);
    // The restored revision stays.
    assert!(revision_rows(&v).iter().any(|r| r.id == revision_id));
}

#[test]
fn restore_of_an_unknown_revision_fails_with_not_found_and_writes_nothing() {
    let (_dir, mut v) = fresh();
    guide_with_a_revision(&mut v);
    let before = snapshot(&v);

    for id in [UNKNOWN_ID, "", "not-a-revision"] {
        let result = guide::restore(&mut v, id, DAY, &FakeClock::at(T0 + 1_000), None);
        assert!(
            matches!(result, Err(MemexError::NotFound(_))),
            "{id:?}: {result:?}"
        );
        assert_eq!(snapshot(&v), before, "{id:?}");
    }
}

#[test]
fn restore_on_a_vault_without_a_guide_fails_with_not_found_and_creates_nothing() {
    let (_dir, mut v) = fresh();

    let result = guide::restore(&mut v, UNKNOWN_ID, DAY, &clock(), None);

    assert!(matches!(result, Err(MemexError::NotFound(_))), "{result:?}");
    assert_eq!(note_count(&v), 0);
}

#[test]
fn restore_takes_the_current_version_after_a_person_save() {
    let (_dir, mut v) = fresh();
    let (current, revision_id) = guide_with_a_revision(&mut v);
    let id = NoteId::parse(&current.note_id).unwrap();
    let saved = update_note(&mut v, &id, current.version, body_patch("Person text.\n")).unwrap();

    let doc = guide::restore(&mut v, &revision_id, DAY, &clock(), None).unwrap();

    assert_eq!(doc.content_md, "First.\n");
    assert_eq!(doc.version, saved.version + 1);
    let newest = revision_rows(&v).pop().unwrap();
    assert_eq!(
        newest.previous_md, "Person text.\n",
        "the person's text is kept"
    );
    assert_eq!(newest.previous_version, saved.version);
}

#[test]
fn each_restore_writes_one_revision_and_one_agent_change() {
    let (_dir, mut v) = fresh();
    let (_, revision_id) = guide_with_a_revision(&mut v);
    let revisions_before = revision_count(&v);
    let changes_before = change_count(&v);

    guide::restore(&mut v, &revision_id, DAY, &clock(), None).unwrap();
    let doc = guide::restore(&mut v, &revision_id, DAY, &clock(), None).unwrap();

    assert_eq!(doc.content_md, "First.\n");
    assert_eq!(revision_count(&v), revisions_before + 2);
    assert_eq!(change_count(&v), changes_before + 2);
}

#[test]
fn restore_commits_the_note_revision_and_agent_change_in_one_transaction() {
    for trigger in FORCED_FAILURES {
        let (_dir, mut v) = fresh();
        let (_, revision_id) = guide_with_a_revision(&mut v);
        let before = snapshot(&v);
        v.connection_ref().execute_batch(trigger).unwrap();

        let result = guide::restore(&mut v, &revision_id, DAY, &FakeClock::at(T0 + 1_000), None);

        assert!(result.is_err(), "{trigger}: {result:?}");
        assert_eq!(snapshot(&v), before, "{trigger}");
    }
}

#[test]
fn restore_reindexes_the_restored_text() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let first = guide::update(
        &mut v,
        seed.version,
        "Use zebrafile here.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    guide::update(
        &mut v,
        first.version,
        "Use quokkafile here.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    let revision = revision_rows(&v)
        .into_iter()
        .find(|r| r.previous_md.contains("zebrafile"))
        .unwrap();
    let embedder = CountingEmbedder::new();

    let doc = guide::restore(&mut v, &revision.id, DAY, &clock(), Some(&embedder)).unwrap();

    assert!(embedder.calls() > 0);
    assert!(embedded_chunks(&v, &doc.note_id) > 0);
    assert!(fts_note_ids(&v, "zebrafile").contains(&doc.note_id));
    assert!(
        fts_note_ids(&v, "quokkafile").is_empty(),
        "the replaced text is gone"
    );
}

#[test]
fn restore_propagates_a_reindex_failure_after_the_commit() {
    let (_dir, mut v) = fresh();
    let (current, revision_id) = guide_with_a_revision(&mut v);

    let result = guide::restore(&mut v, &revision_id, DAY, &clock(), Some(&FailingEmbedder));

    assert!(
        matches!(result, Err(MemexError::EmbedderInfer(_))),
        "{result:?}"
    );
    let doc = seeded(&mut v);
    assert_eq!(doc.content_md, "First.\n");
    assert_eq!(doc.version, current.version + 1);
}

// ---------------------------------------------------------------------------
// AC 8: revisions
// ---------------------------------------------------------------------------

/// A revision row and, when `change` is set, the `agent_changes` row it links.
fn revision_row(v: &Vault, id: &str, change: Option<&str>, new_version: i64, created_at: i64) {
    if let Some(change) = change {
        v.connection_ref()
            .execute(
                "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
                 VALUES (?, ?, ?, ?, '[\"Changed it\"]')",
                params![change, GUIDE_ID, DAY, created_at],
            )
            .unwrap();
    }
    v.connection_ref()
        .execute(
            "INSERT INTO vault_guide_revisions
                 (id, note_id, previous_md, previous_version, new_version, agent_change_id,
                  created_at)
             VALUES (?, ?, 'Earlier.', ?, ?, ?, ?)",
            params![
                id,
                GUIDE_ID,
                new_version - 1,
                new_version,
                change,
                created_at
            ],
        )
        .unwrap();
}

#[test]
fn revisions_lists_newest_first_each_with_its_agent_change_id() {
    let (_dir, v) = fresh();
    guide_row(&v);
    revision_row(&v, "rev-a", Some("change-a"), 2, T0);
    revision_row(&v, "rev-b", Some("change-b"), 3, T0 + 1_000);
    revision_row(&v, "rev-c", None, 4, T0 + 2_000);

    let listed = guide::revisions(&v).unwrap();

    let got: Vec<(&str, Option<&str>, i64)> = listed
        .iter()
        .map(|r| (r.id.as_str(), r.agent_change_id.as_deref(), r.created_at))
        .collect();
    assert_eq!(
        got,
        [
            ("rev-c", None, T0 + 2_000),
            ("rev-b", Some("change-b"), T0 + 1_000),
            ("rev-a", Some("change-a"), T0),
        ]
    );
}

#[test]
fn revisions_keep_their_row_when_the_agent_change_is_deleted() {
    let (_dir, v) = fresh();
    guide_row(&v);
    revision_row(&v, "rev-a", Some("change-a"), 2, T0);

    v.connection_ref()
        .execute("DELETE FROM agent_changes WHERE id = 'change-a'", [])
        .unwrap();

    let listed = guide::revisions(&v).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, "rev-a");
    assert_eq!(listed[0].agent_change_id, None, "ON DELETE SET NULL (D7)");
}

#[test]
fn revisions_of_real_writes_are_newest_first_and_link_their_own_change() {
    let (_dir, mut v) = fresh();
    let (_, revision_id) = guide_with_a_revision(&mut v);
    guide::restore(&mut v, &revision_id, DAY, &clock(), None).unwrap();

    let listed = guide::revisions(&v).unwrap();
    let mut rows = revision_rows(&v);
    rows.reverse();

    assert_eq!(listed.len(), 3);
    for (revision, stored) in listed.iter().zip(&rows) {
        assert_eq!(revision.id, stored.id);
        assert_eq!(revision.agent_change_id, stored.agent_change_id);
        assert!(revision.agent_change_id.is_some());
        assert_eq!(revision.created_at, stored.created_at);
    }
    assert_eq!(rows[0].previous_md, "Second.\n");
}

#[test]
fn revisions_stay_newest_first_within_one_millisecond() {
    let (_dir, mut v) = fresh();
    let mut doc = seeded(&mut v);
    for text in ["One.\n", "Two.\n", "Three.\n", "Four.\n", "Five.\n"] {
        doc = guide::update(
            &mut v,
            doc.version,
            text,
            &bullets(&["Changed it"]),
            DAY,
            &clock(),
            None,
        )
        .unwrap();
    }

    let listed: Vec<String> = guide::revisions(&v)
        .unwrap()
        .into_iter()
        .map(|r| r.id)
        .collect();

    let mut written: Vec<String> = revision_rows(&v).into_iter().map(|r| r.id).collect();
    written.reverse();
    assert_eq!(listed, written);
}

#[test]
fn revisions_stay_newest_first_when_the_clock_jumps_backward() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let clock = FakeClock::at(T0 + 10_000);
    let first = guide::update(
        &mut v,
        seed.version,
        "One.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock,
        None,
    )
    .unwrap();
    clock.set(T0); // NTP or a manual clock change
    guide::update(
        &mut v,
        first.version,
        "Two.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock,
        None,
    )
    .unwrap();

    let listed = guide::revisions(&v).unwrap();

    assert_eq!(listed.len(), 2);
    let newest_written = revision_rows(&v).pop().unwrap();
    assert_eq!(listed[0].id, newest_written.id);
    assert_eq!(listed[0].created_at, T0);
}

#[test]
fn revisions_on_a_vault_without_a_guide_is_empty_and_creates_nothing() {
    let (_dir, v) = fresh();
    assert!(guide::revisions(&v).unwrap().is_empty());
    assert_eq!(note_count(&v), 0);
}

#[test]
fn guide_doc_and_revision_serialize_with_the_contract_field_names() {
    let (_dir, mut v) = fresh();
    let (doc, _) = guide_with_a_revision(&mut v);

    assert_eq!(
        serde_json::to_value(&doc).unwrap(),
        json!({
            "note_id": doc.note_id,
            "version": doc.version,
            "content_md": doc.content_md,
        })
    );
    let revision = guide::revisions(&v).unwrap().remove(0);
    assert_eq!(
        serde_json::to_value(&revision).unwrap(),
        json!({
            "id": revision.id,
            "agent_change_id": revision.agent_change_id,
            "created_at": revision.created_at,
        })
    );
}

// ---------------------------------------------------------------------------
// AC 9: check_agent_write
// ---------------------------------------------------------------------------

#[test]
fn check_agent_write_fails_with_guide_rule_for_a_guide_target_and_passes_a_topic_note() {
    let guide = json!({"role": "guide"});
    let topic = json!({"role": "topic"});

    check_agent_write(Caller::Agent, &topic, None).expect("a topic note passes");
    check_agent_write(Caller::Agent, &topic, Some(&topic)).expect("a topic note stays a topic");

    assert_guide_rule(check_agent_write(Caller::Agent, &guide, None));
    assert_guide_rule(check_agent_write(Caller::Agent, &guide, Some(&guide)));
    assert_guide_rule(check_agent_write(Caller::Agent, &guide, Some(&topic)));
}

#[test]
fn check_agent_write_fails_with_guide_rule_for_a_write_making_a_note_role_guide() {
    let guide = json!({"role": "guide"});

    assert_guide_rule(check_agent_write(
        Caller::Agent,
        &json!({"role": "topic"}),
        Some(&guide),
    ));
    assert_guide_rule(check_agent_write(Caller::Agent, &json!({}), Some(&guide)));
    assert_guide_rule(check_agent_write(Caller::Agent, &Value::Null, Some(&guide)));
}

#[test]
fn check_agent_write_stays_a_no_op_for_the_person_and_matches_the_role_exactly() {
    let guide = json!({"role": "guide"});
    check_agent_write(Caller::Person, &guide, None).unwrap();
    check_agent_write(Caller::Person, &json!({}), Some(&guide)).unwrap();

    let other_case = json!({"role": "Guide"});
    check_agent_write(Caller::Agent, &other_case, None).unwrap();
    check_agent_write(Caller::Agent, &json!({}), Some(&other_case)).unwrap();
}

#[test]
fn agent_saves_on_the_guide_fail_with_guide_rule() {
    let (_dir, mut v) = fresh();
    let id = guide_row(&v);
    plain(&mut v, "Target");
    let saved = update_note(&mut v, &id, 1, body_patch("See [[Target]].\n")).unwrap();
    indexer::reindex_note(v.connection_mut(), GUIDE_ID, &saved.content_md, None).unwrap();
    let before = snapshot(&v);

    let result = update_note_as(
        &mut v,
        &id,
        saved.version,
        body_patch("Agent text.\n"),
        RenameOptions::default(),
        Caller::Agent,
    );
    assert_guide_rule(result);

    // The guard wins over a stale version: a retry can't help.
    let stale = update_note_as(
        &mut v,
        &id,
        saved.version + 9,
        body_patch("Agent text.\n"),
        RenameOptions::default(),
        Caller::Agent,
    );
    assert_guide_rule(stale);

    // `update_link_as` saves the source note the same way.
    let link = links_out_for_note(&v, GUIDE_ID).unwrap().remove(0);
    let edited = update_link_as(
        &mut v,
        &link.id,
        UpdateLink {
            new_kind: Some(LinkKind::new("about").unwrap()),
            new_label: None,
        },
        Caller::Agent,
    );
    assert_guide_rule(edited);

    assert_eq!(snapshot(&v), before);
}

#[test]
fn an_agent_making_a_note_role_guide_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();
    let note = plain(&mut v, "Plain");
    let before = snapshot(&v);

    let result = update_note_as(
        &mut v,
        &note.id,
        note.version,
        frontmatter_patch(json!({"role": "guide"})),
        RenameOptions::default(),
        Caller::Agent,
    );

    assert_guide_rule(result);
    assert_eq!(snapshot(&v), before);
}

#[test]
fn an_agent_may_still_write_a_topic_note_when_a_guide_exists() {
    let (_dir, mut v) = fresh();
    guide_row(&v);
    let note = plain(&mut v, "Plain");

    let saved = update_note_as(
        &mut v,
        &note.id,
        note.version,
        body_patch("Agent text.\n"),
        RenameOptions::default(),
        Caller::Agent,
    )
    .unwrap();

    assert_eq!(saved.content_md, "Agent text.\n");
}

// ---------------------------------------------------------------------------
// AC 10: person guards
// ---------------------------------------------------------------------------

#[test]
fn person_changing_the_guides_title_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();
    let id = guide_row(&v);
    let before = snapshot(&v);

    assert_guide_rule(update_note(&mut v, &id, 1, title_patch("Renamed")));

    // Alongside a body save, and whatever the version: a retry can't help.
    let both = UpdateNote {
        title: Some("Renamed".into()),
        content_md: Some("Text.\n".into()),
        frontmatter: None,
    };
    assert_guide_rule(update_note(&mut v, &id, 1, both));
    assert_guide_rule(update_note(&mut v, &id, 9, title_patch("Renamed")));

    assert_eq!(snapshot(&v), before);
}

#[test]
fn person_changing_the_guides_role_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();
    let id = guide_row(&v);
    let before = snapshot(&v);

    for frontmatter in [
        json!({}),
        json!({"role": "topic"}),
        json!({"role": "daily"}),
        json!({"role": "Guide"}),
        json!({"role": null}),
        Value::Null,
    ] {
        let result = update_note(&mut v, &id, 1, frontmatter_patch(frontmatter.clone()));
        assert_guide_rule(result);
        assert_eq!(snapshot(&v), before, "{frontmatter}");
    }
    assert_guide_rule(update_note(&mut v, &id, 9, frontmatter_patch(json!({}))));
}

#[test]
fn person_deleting_the_guide_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();
    let id = guide_row(&v);
    let before = snapshot(&v);

    assert_guide_rule(delete_note_checked(&mut v, &id, 1, None));
    // Always `guide_rule`, never `version_conflict`.
    assert_guide_rule(delete_note_checked(&mut v, &id, 9, None));

    assert_eq!(snapshot(&v), before);
}

#[test]
fn person_deleting_the_guide_keeps_its_index() {
    let (_dir, mut v) = fresh();
    let id = guide_row(&v);
    indexer::reindex_note(v.connection_mut(), GUIDE_ID, SEED_BODY, None).unwrap();

    assert_guide_rule(delete_note_checked(&mut v, &id, 1, None));

    assert!(
        fts_note_ids(&v, "Framework").contains(GUIDE_ID),
        "the guard runs before the purge"
    );
}

#[test]
fn creating_a_second_guide_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();
    guide_row(&v);
    let before = snapshot(&v);

    assert_guide_rule(notes::create_note(&mut v, guide_create_input("Second")));
    assert_guide_rule(create_note_as(
        &mut v,
        guide_create_input("Second"),
        Caller::Agent,
    ));
    assert_guide_rule(create_or_adopt_note(
        &mut v,
        guide_create_input("Second"),
        Caller::Person,
        &clock(),
    ));
    // A title conflict does not hide the rule.
    assert_guide_rule(notes::create_note(
        &mut v,
        guide_create_input("Vault Guide"),
    ));

    assert_eq!(snapshot(&v), before);
}

#[test]
fn creating_the_first_guide_outside_the_seed_path_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();

    assert_guide_rule(notes::create_note(&mut v, guide_create_input("Mine")));
    assert_guide_rule(create_note_as(
        &mut v,
        guide_create_input("Mine"),
        Caller::Agent,
    ));

    assert_eq!(note_count(&v), 0);
}

#[test]
fn giving_another_note_role_guide_fails_with_guide_rule() {
    // With no guide yet, and with one.
    for guide_exists in [false, true] {
        let (_dir, mut v) = fresh();
        if guide_exists {
            guide_row(&v);
        }
        let note = plain(&mut v, "Plain");
        let before = snapshot(&v);

        let result = update_note(
            &mut v,
            &note.id,
            note.version,
            frontmatter_patch(json!({"role": "guide"})),
        );
        assert_guide_rule(result);
        // Whatever the version.
        let stale = update_note(
            &mut v,
            &note.id,
            note.version + 9,
            frontmatter_patch(json!({"role": "guide"})),
        );
        assert_guide_rule(stale);

        assert_eq!(snapshot(&v), before);
    }
}

#[test]
fn add_member_on_the_guide_fails_with_guide_rule() {
    let (_dir, mut v) = fresh();
    let id = guide_row(&v);
    let folder = sf::create_folder(&mut v, "Folder", None, Caller::Person, &clock()).unwrap();
    let before = snapshot(&v);

    for (caller, pinned) in [
        (Caller::Person, None),
        (Caller::Person, Some(true)),
        (Caller::Agent, None),
    ] {
        assert_guide_rule(sf::add_member(
            &mut v,
            &folder.id,
            id.as_str(),
            pinned,
            caller,
            None,
        ));
    }

    assert_eq!(count(&v, "SELECT COUNT(*) FROM smart_folder_members"), 0);
    assert_eq!(snapshot(&v), before);
}

#[test]
fn the_person_guards_leave_other_notes_alone() {
    let (_dir, mut v) = fresh();
    guide_row(&v);
    let note = plain(&mut v, "Plain");

    let renamed = update_note(&mut v, &note.id, note.version, title_patch("Renamed")).unwrap();
    assert_eq!(renamed.title, "Renamed");
    let topic = update_note(
        &mut v,
        &note.id,
        renamed.version,
        frontmatter_patch(json!({"role": "topic"})),
    )
    .unwrap();
    assert_eq!(topic.frontmatter, json!({"role": "topic"}));
    // `role: Guide` is not the guide.
    let other_case = update_note(
        &mut v,
        &note.id,
        topic.version,
        frontmatter_patch(json!({"role": "Guide"})),
    )
    .unwrap();

    delete_note_checked(&mut v, &note.id, other_case.version, None).unwrap();
    assert!(matches!(
        get_note(&v, &note.id),
        Err(MemexError::NotFound(_))
    ));
}

// ---------------------------------------------------------------------------
// AC 11: a person's body save
// ---------------------------------------------------------------------------

#[test]
fn a_person_saving_the_guides_body_succeeds_and_writes_no_revision() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let id = NoteId::parse(&seed.note_id).unwrap();

    let saved = update_note(&mut v, &id, seed.version, body_patch("Person text.\n")).unwrap();

    assert_eq!(saved.content_md, "Person text.\n");
    assert_eq!(saved.version, seed.version + 1);
    assert_eq!(saved.title, "Vault Guide");
    assert!(notes::is_guide(&saved.frontmatter));
    assert_eq!(revision_count(&v), 0);
    assert_eq!(change_count(&v), 0);

    // The next agent write holds the person's text and needs the new version.
    let stale = guide::update(
        &mut v,
        seed.version,
        "Agent text.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    );
    assert!(
        matches!(stale, Err(MemexError::VersionConflict { .. })),
        "{stale:?}"
    );
    guide::update(
        &mut v,
        saved.version,
        "Agent text.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    assert_eq!(revision_rows(&v)[0].previous_md, "Person text.\n");
}

#[test]
fn a_person_passing_the_same_title_and_keeping_the_role_succeeds_with_no_revision() {
    let (_dir, mut v) = fresh();
    let seed = seeded(&mut v);
    let id = NoteId::parse(&seed.note_id).unwrap();

    let patch = UpdateNote {
        title: Some("Vault Guide".into()),
        content_md: Some("Person text.\n".into()),
        frontmatter: Some(json!({"role": "guide", "kept": true})),
    };
    let saved = update_note(&mut v, &id, seed.version, patch).unwrap();

    assert_eq!(saved.title, "Vault Guide");
    assert_eq!(saved.content_md, "Person text.\n");
    assert_eq!(saved.frontmatter, json!({"role": "guide", "kept": true}));
    assert_eq!(revision_count(&v), 0);
    assert_eq!(change_count(&v), 0);
}

// ---------------------------------------------------------------------------
// AC 12: Unsorted, graph, search
// ---------------------------------------------------------------------------

/// A guide next to one note of each kind Unsorted has to tell it from.
fn unsorted_fixture(v: &Vault) -> Vec<&'static str> {
    guide_row(v);
    row(v, "01J9V6000000000000000000B1", "Plain", "x\n", "{}");
    row(
        v,
        "01J9V6000000000000000000B2",
        "Topic",
        "x\n",
        r#"{"role":"topic"}"#,
    );
    row(
        v,
        "01J9V6000000000000000000B3",
        "Other case",
        "x\n",
        r#"{"role":"Guide"}"#,
    );
    row(v, "01J9V6000000000000000000B5", "Broken", "x\n", "not json");
    row(
        v,
        "01J9V6000000000000000000B6",
        "2026-09-05",
        "x\n",
        r#"{"role":"daily"}"#,
    );
    vec!["Broken", "Other case", "Plain", "Topic"]
}

#[test]
fn the_guide_is_absent_from_list_folders_unsorted() {
    let (_dir, v) = fresh();
    let expected = unsorted_fixture(&v);

    let listed = sf::list_folders(&v).unwrap();

    let titles: Vec<&str> = listed.unsorted.iter().map(|n| n.title.as_str()).collect();
    assert_eq!(titles, expected);
}

#[test]
fn list_folders_unsorted_keeps_a_note_with_a_non_text_role() {
    let (_dir, v) = fresh();
    row(
        &v,
        "01J9V6000000000000000000B4",
        "Number role",
        "x\n",
        r#"{"role":1}"#,
    );

    let listed = sf::list_folders(&v).unwrap();

    let titles: Vec<&str> = listed.unsorted.iter().map(|n| n.title.as_str()).collect();
    assert_eq!(titles, ["Number role"]);
}

#[test]
fn the_guide_is_absent_from_the_hosted_unsorted_read() {
    let (_dir, v) = fresh();
    let expected = unsorted_fixture(&v);

    let rows = unsorted_notes(&v).unwrap();

    let titles: BTreeSet<&str> = rows.iter().map(|n| n.title.as_str()).collect();
    assert_eq!(titles, expected.into_iter().collect::<BTreeSet<_>>());
}

const ALPHA: &str = "01J9V6000000000000000000C1";
const BETA: &str = "01J9V6000000000000000000C2";
const GAMMA: &str = "01J9V6000000000000000000C3";
const DELTA: &str = "01J9V6000000000000000000C4";
const BROKEN: &str = "01J9V6000000000000000000C5";
const OTHER_CASE: &str = "01J9V6000000000000000000C6";

/// `guide -> alpha, beta`; `gamma -> guide`; `alpha -> delta, broken, other`.
fn graph_fixture(v: &mut Vault) {
    let notes = [
        (
            GUIDE_ID,
            "Vault Guide",
            "[[Alpha]] and [[Beta]].\n",
            r#"{"role":"guide"}"#,
        ),
        (
            ALPHA,
            "Alpha",
            "[[Delta]], [[Broken]], [[Other case]].\n",
            "{}",
        ),
        (BETA, "Beta", "Beta.\n", "{}"),
        (GAMMA, "Gamma", "[[Vault Guide]].\n", "{}"),
        (DELTA, "Delta", "Delta.\n", "{}"),
        (BROKEN, "Broken", "Broken.\n", "not json"),
        (OTHER_CASE, "Other case", "Other.\n", r#"{"role":"Guide"}"#),
    ];
    for (id, title, body, frontmatter) in notes {
        row(v, id, title, body, frontmatter);
    }
    for (id, _, body, _) in notes {
        indexer::reindex_note(v.connection_mut(), id, body, None).unwrap();
    }
}

#[test]
fn the_guide_is_absent_from_the_whole_vault_graph() {
    let (_dir, mut v) = fresh();
    graph_fixture(&mut v);

    let ids: Vec<String> = graph_notes(&v).unwrap().into_iter().map(|n| n.id).collect();
    assert_eq!(ids, [ALPHA, BETA, GAMMA, DELTA, BROKEN, OTHER_CASE]);

    let links: Vec<(String, String)> = graph_links(&v)
        .unwrap()
        .into_iter()
        .map(|l| (l.from, l.to))
        .collect();
    let expected: Vec<(String, String)> = [DELTA, BROKEN, OTHER_CASE]
        .iter()
        .map(|to| (ALPHA.to_string(), to.to_string()))
        .collect();
    assert_eq!(links, expected, "no link starts or ends at the guide");
}

#[test]
fn the_guide_is_absent_from_neighbors() {
    let (_dir, mut v) = fresh();
    graph_fixture(&mut v);
    let ids = |conn, root, depth| -> BTreeSet<String> {
        neighbors(conn, root, depth, None)
            .unwrap()
            .into_iter()
            .map(|hit| hit.note_id)
            .collect()
    };
    let conn = v.connection_ref();

    // Not a neighbor, and no path runs through it: alpha never reaches beta or
    // gamma, and its real neighbors stay, malformed frontmatter included.
    let from_alpha = ids(conn, ALPHA, 3);
    for gone in [GUIDE_ID, BETA, GAMMA] {
        assert!(!from_alpha.contains(gone), "{gone}: {from_alpha:?}");
    }
    for kept in [DELTA, BROKEN, OTHER_CASE] {
        assert!(from_alpha.contains(kept), "{kept}: {from_alpha:?}");
    }
    assert!(ids(conn, BETA, 3).is_empty());
    assert!(ids(conn, GAMMA, 3).is_empty());
}

#[test]
fn the_guide_is_found_by_search() {
    let (_dir, mut v) = fresh();

    let seed = seeded(&mut v);
    assert!(fts_note_ids(&v, "Framework").contains(&seed.note_id));

    let doc = guide::update(
        &mut v,
        seed.version,
        "Prefer zebrafile for design notes.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    )
    .unwrap();
    assert!(fts_note_ids(&v, "zebrafile").contains(&doc.note_id));

    // A person save is reindexed by its caller from the stored body (D8).
    let id = NoteId::parse(&doc.note_id).unwrap();
    let saved = update_note(&mut v, &id, doc.version, body_patch("Prefer quokkafile.\n")).unwrap();
    indexer::reindex_note(v.connection_mut(), id.as_str(), &saved.content_md, None).unwrap();
    assert!(fts_note_ids(&v, "quokkafile").contains(&doc.note_id));
}

// ---------------------------------------------------------------------------
// Contracts the doc comments promise (verify mode)
// ---------------------------------------------------------------------------

#[test]
fn update_before_the_guide_exists_fails_with_not_found() {
    let (_dir, mut v) = fresh();

    let result = guide::update(
        &mut v,
        1,
        "Text.\n",
        &bullets(&["Changed it"]),
        DAY,
        &clock(),
        None,
    );

    match result {
        Err(e @ MemexError::NotFound(_)) => assert_eq!(e.code(), "not_found"),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

/// The review's own rule order survives the shared validation: the missing
/// daily entry is `change_entries_invalid` ahead of an unknown note's
/// `not_found`, and nothing is written.
#[test]
fn mark_day_reviewed_answers_the_missing_daily_entry_before_an_unknown_note() {
    let (_dir, mut v) = fresh();
    let daily = create_note_as(
        &mut v,
        CreateNote {
            title: Some(DAY.into()),
            content_md: "Fifth.\n".into(),
            frontmatter: Some(json!({ "role": "daily" })),
        },
        Caller::Person,
    )
    .unwrap();
    let changes = [ChangeEntry {
        note_id: UNKNOWN_ID.into(),
        bullets: bullets(&["Created topic"]),
    }];

    let result = review::mark_day_reviewed(&mut v, DAY, daily.version, &changes, &clock());

    match result {
        Err(e @ MemexError::ChangeEntriesInvalid(_)) => {
            assert_eq!(e.code(), "change_entries_invalid")
        }
        other => panic!("expected ChangeEntriesInvalid, got {other:?}"),
    }
    assert_eq!(change_count(&v), 0);
}
