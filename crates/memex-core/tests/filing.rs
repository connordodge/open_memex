//! WI #248 (F1): `filing::day_filing`, the read model of where a day's blocks
//! are filed (Spec #233 R7, R14, R15).
//!
//! Real SQLite, temp vaults only. Days are reviewed through
//! `review::mark_day_reviewed` and edited through real person saves.

use std::cell::Cell;

use memex_core::canvas::Clock;
use memex_core::error::MemexError;
use memex_core::excerpts::{move_block, remove_excerpt_block};
use memex_core::filing::{day_filing, DayFiling, FiledBlock, FiledTopic};
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::review::{self, ChangeEntry};
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
const DAY_BODY: &str = "One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive.\n";
const DAY_BLOCKS: [&str; 5] = ["blk001", "blk002", "blk003", "blk004", "blk005"];
const OTHER_DAY: &str = "2026-09-07";

const T1: &str = "![[2026-09-05#^blk001]]";
const T2: &str = "![[2026-09-05#^blk002]]";
const T3: &str = "![[2026-09-05#^blk003]]";
const T4: &str = "![[2026-09-05#^blk004]]";
const T1_2: &str = "![[2026-09-05#^blk001..^blk002]]";

/// A clock the test sets by hand (D14).
struct FakeClock(Cell<i64>);

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.get()
    }
}

struct World {
    _dir: TempDir,
    vault: Vault,
    day: NoteId,
}

/// A vault with the five-block day `2026-09-05`.
fn world() -> World {
    world_with_day(DAY_BODY, &DAY_BLOCKS)
}

fn world_with_day(body: &str, block_ids: &[&str]) -> World {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let day = create_day(&mut vault, DAY, body, block_ids);
    World {
        _dir: dir,
        vault,
        day,
    }
}

fn create(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    reindex(vault, &note);
    note
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

/// A topic note whose body is one token per line under the day's heading.
fn create_topic(vault: &mut Vault, title: &str, tokens: &[&str]) -> NoteId {
    let body = format!("## {DAY}\n\n{}\n", tokens.join("\n\n"));
    create(vault, title, &body, Some(json!({ "role": "topic" }))).id
}

/// A daily note whose stored block ids are pinned by ord.
fn create_day(vault: &mut Vault, date: &str, body: &str, block_ids: &[&str]) -> NoteId {
    let note = create(vault, date, body, Some(json!({ "role": "daily" })));
    for (ord, id) in block_ids.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, note.id.as_str(), ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "block at ord {ord}");
    }
    note.id
}

/// Marks the day reviewed at its current content version, the real way.
fn mark_reviewed(vault: &mut Vault, date: &str) {
    let changes = review::get_daily_note_changes(vault, date).unwrap();
    let entry = ChangeEntry {
        note_id: changes.note_id.clone(),
        bullets: vec!["Filed some blocks".to_string()],
    };
    review::mark_day_reviewed(
        vault,
        date,
        changes.content_version,
        &[entry],
        &FakeClock(Cell::new(1_759_500_000_000)),
    )
    .unwrap_or_else(|e| panic!("mark_day_reviewed {date}: {e}"));
}

/// A person save of the note with `from` replaced by `to`.
fn person_replace(vault: &mut Vault, id: &NoteId, from: &str, to: &str) {
    let current = get_note(vault, id).unwrap();
    assert!(
        current.content_md.contains(from),
        "precondition: {from:?} in:\n{}",
        current.content_md
    );
    let saved = update_note_as(
        vault,
        id,
        current.version,
        UpdateNote {
            content_md: Some(current.content_md.replacen(from, to, 1)),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person save of {id}: {e}"));
    reindex(vault, &saved);
}

fn block_id_of(vault: &Vault, day: &NoteId, text: &str) -> String {
    vault
        .connection_ref()
        .query_row(
            "SELECT block_id FROM blocks WHERE note_id = ? AND text = ?",
            params![day.as_str(), text],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("no block {text:?}: {e}"))
}

fn filing(w: &World) -> DayFiling {
    day_filing(&w.vault, DAY).unwrap_or_else(|e| panic!("day_filing {DAY}: {e}"))
}

fn block(id: &str, text: &str) -> FiledBlock {
    FiledBlock {
        id: id.to_string(),
        text: text.to_string(),
    }
}

fn b1() -> FiledBlock {
    block("blk001", "One.")
}

fn b2() -> FiledBlock {
    block("blk002", "Two.")
}

fn b3() -> FiledBlock {
    block("blk003", "Three.")
}

fn b4() -> FiledBlock {
    block("blk004", "Four.")
}

fn b5() -> FiledBlock {
    block("blk005", "Five.")
}

fn filed(id: &NoteId, title: &str, blocks: &[FiledBlock]) -> FiledTopic {
    FiledTopic {
        topic_note_id: id.to_string(),
        title: title.to_string(),
        blocks: blocks.to_vec(),
    }
}

fn titles(f: &DayFiling) -> Vec<String> {
    f.topics.iter().map(|t| t.title.clone()).collect()
}

/// Every row `day_filing` could touch.
type DbState = (
    Vec<(String, String, i64, i64)>,
    Vec<(String, i64, Option<i64>, Option<i64>)>,
    Vec<(String, String, String)>,
    Vec<(String, String, String)>,
);

fn db_state(vault: &Vault) -> DbState {
    let conn = vault.connection_ref();
    let notes = conn
        .prepare("SELECT id, content_md, version, updated_at FROM notes ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let reviews = conn
        .prepare(
            "SELECT note_id, content_version, reviewed_content_version, reviewed_at
             FROM day_reviews ORDER BY note_id",
        )
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let snapshot = conn
        .prepare("SELECT note_id, block_id, text FROM day_review_blocks ORDER BY note_id, block_id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let chips = conn
        .prepare("SELECT daily_note_id, topic_note_id, origin FROM footer_chips ORDER BY rowid")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    (notes, reviews, snapshot, chips)
}

// ---------------------------------------------------------------------------
// Filed blocks
// ---------------------------------------------------------------------------

#[test]
fn day_filing_lists_each_block_under_its_topic_sorted_by_title_in_day_order_and_under_both_topics()
{
    let mut w = world();
    // Created out of title order; beta's tokens are out of day order; blk001
    // is in both Alpha and beta.
    let gamma = create_topic(&mut w.vault, "Gamma", &[T4]);
    let beta = create_topic(&mut w.vault, "beta", &[T3, T1]);
    let alpha = create_topic(&mut w.vault, "Alpha", &[T1_2]);
    mark_reviewed(&mut w.vault, DAY);

    let f = filing(&w);

    assert_eq!(f.date, DAY);
    assert_eq!(f.note_id, w.day.to_string());
    assert!(f.reviewed);
    assert_eq!(
        f.topics,
        [
            filed(&alpha, "Alpha", &[b1(), b2()]),
            filed(&beta, "beta", &[b1(), b3()]),
            filed(&gamma, "Gamma", &[b4()]),
        ]
    );
    assert_eq!(f.not_filed, [b5()]);
}

#[test]
fn day_filing_sorts_titles_by_their_unicode_lowercase() {
    let mut w = world();
    create_topic(&mut w.vault, "Élan", &[T1]);
    create_topic(&mut w.vault, "éa", &[T1]);
    create_topic(&mut w.vault, "ZETA", &[T1]);
    mark_reviewed(&mut w.vault, DAY);

    // An ASCII-only fold would put Élan (0xC3 0x89) before éa (0xC3 0xA9).
    assert_eq!(titles(&filing(&w)), ["ZETA", "éa", "Élan"]);
}

#[test]
fn day_filing_breaks_title_ties_by_note_id() {
    let mut w = world();
    let mut expected: Vec<(String, String)> = ["same", "SAME", "Same", "sAme", "saMe", "samE"]
        .iter()
        .map(|title| {
            let id = create_topic(&mut w.vault, title, &[T1]);
            (id.to_string(), title.to_string())
        })
        .collect();
    expected.sort();
    // The scan reads the notes in rowid order. Give the topics rowids that
    // run against their ids, so only the tie-break (not the order they were
    // stored in, nor the clock the ids were minted by) puts them in id order.
    for (n, (id, _)) in expected.iter().enumerate() {
        let moved = w
            .vault
            .connection_ref()
            .execute(
                "UPDATE notes SET rowid = ? WHERE id = ?",
                params![1_000_000 - n as i64, id],
            )
            .unwrap();
        assert_eq!(moved, 1, "topic {id}");
    }
    let scan: Vec<String> = w
        .vault
        .connection_ref()
        .prepare("SELECT id FROM notes WHERE title LIKE 'same' AND instr(content_md, '![[') > 0")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut descending: Vec<String> = expected.iter().map(|(id, _)| id.clone()).collect();
    descending.reverse();
    assert_eq!(scan, descending, "precondition: stored against id order");
    mark_reviewed(&mut w.vault, DAY);

    let got: Vec<(String, String)> = filing(&w)
        .topics
        .into_iter()
        .map(|t| (t.topic_note_id, t.title))
        .collect();

    assert_eq!(got, expected);
}

#[test]
fn day_filing_lists_a_block_held_by_two_tokens_of_one_topic_once() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "Loop", &[T1_2, T2]);
    mark_reviewed(&mut w.vault, DAY);

    assert_eq!(filing(&w).topics, [filed(&topic, "Loop", &[b1(), b2()])]);
}

#[test]
fn day_filing_counts_a_block_inside_a_range_as_filed_including_one_added_after_the_review() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "Loop", &[T1_2]);
    mark_reviewed(&mut w.vault, DAY);
    let day = w.day.clone();
    person_replace(&mut w.vault, &day, "One.\n\n", "One.\n\nInserted.\n\n");
    let inserted = block_id_of(&w.vault, &day, "Inserted.");

    let f = filing(&w);

    assert_eq!(
        f.topics,
        [filed(
            &topic,
            "Loop",
            &[b1(), block(&inserted, "Inserted."), b2()]
        )]
    );
    assert_eq!(f.not_filed, [b3(), b4(), b5()]);
}

#[test]
fn day_filing_covers_a_range_with_reversed_endpoints() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "Loop", &["![[2026-09-05#^blk003..^blk002]]"]);
    mark_reviewed(&mut w.vault, DAY);

    assert_eq!(filing(&w).topics, [filed(&topic, "Loop", &[b2(), b3()])]);
}

#[test]
fn day_filing_gives_no_row_for_a_token_whose_endpoints_no_longer_resolve() {
    let mut w = world();
    let good = create_topic(&mut w.vault, "Good", &[T2]);
    create_topic(
        &mut w.vault,
        "Stale",
        &[
            "![[2026-09-05#^zzzzzz]]",
            "![[2026-09-05#^blk001..^zzzzzz]]",
            "![[2026-09-05#^zzzzzz..^blk001]]",
        ],
    );
    let mixed = create_topic(
        &mut w.vault,
        "Mixed",
        &["![[2026-09-05#^zzzzzz..^blk003]]", T4],
    );
    mark_reviewed(&mut w.vault, DAY);

    let f = filing(&w);

    assert_eq!(
        f.topics,
        [
            filed(&good, "Good", &[b2()]),
            filed(&mixed, "Mixed", &[b4()]),
        ],
        "a topic with no resolving token has no entry"
    );
    assert_eq!(f.not_filed, [b1(), b3(), b5()]);
}

#[test]
fn day_filing_gives_no_row_for_a_token_of_a_block_deleted_from_the_day() {
    let mut w = world();
    create_topic(&mut w.vault, "Gone", &[T3]);
    let kept = create_topic(&mut w.vault, "Kept", &[T1]);
    mark_reviewed(&mut w.vault, DAY);
    let day = w.day.clone();
    person_replace(&mut w.vault, &day, "Three.\n\n", "");

    let f = filing(&w);

    assert_eq!(f.topics, [filed(&kept, "Kept", &[b1()])]);
    assert_eq!(f.not_filed, [b2(), b4(), b5()]);
}

#[test]
fn day_filing_ignores_tokens_of_other_dates() {
    let mut w = world();
    create_day(&mut w.vault, OTHER_DAY, "Other.\n", &["blk001"]);
    create_topic(&mut w.vault, "Elsewhere", &["![[2026-09-07#^blk001]]"]);
    let here = create_topic(&mut w.vault, "Here", &[T2]);
    mark_reviewed(&mut w.vault, DAY);

    let f = filing(&w);

    assert_eq!(f.topics, [filed(&here, "Here", &[b2()])]);
    assert_eq!(f.not_filed, [b1(), b3(), b4(), b5()]);
}

#[test]
fn day_filing_scans_only_notes_with_the_exact_topic_role() {
    let mut w = world();
    create(&mut w.vault, "Loose", T1, None);
    create(
        &mut w.vault,
        "Capital",
        T1,
        Some(json!({ "role": "Topic" })),
    );
    create(
        &mut w.vault,
        "Project",
        T1,
        Some(json!({ "role": "project" })),
    );
    let topic = create_topic(&mut w.vault, "Real", &[T2]);
    mark_reviewed(&mut w.vault, DAY);

    let f = filing(&w);

    assert_eq!(f.topics, [filed(&topic, "Real", &[b2()])]);
    assert_eq!(f.not_filed, [b1(), b3(), b4(), b5()], "blk001 is not filed");
}

#[test]
fn day_filing_skips_a_note_with_unparseable_frontmatter_instead_of_failing() {
    let mut w = world();
    let broken = create(&mut w.vault, "Broken", T1, Some(json!({ "role": "topic" })));
    w.vault
        .connection_ref()
        .execute(
            "UPDATE notes SET frontmatter = 'not json {' WHERE id = ?",
            params![broken.id.as_str()],
        )
        .unwrap();
    let topic = create_topic(&mut w.vault, "Real", &[T2]);
    mark_reviewed(&mut w.vault, DAY);

    let f = filing(&w);

    assert_eq!(f.topics, [filed(&topic, "Real", &[b2()])]);
    assert_eq!(f.not_filed, [b1(), b3(), b4(), b5()]);
}

#[test]
fn day_filing_does_not_rely_on_footer_chips() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "No chip", &[T1]);
    mark_reviewed(&mut w.vault, DAY);
    let chips: i64 = w
        .vault
        .connection_ref()
        .query_row("SELECT count(*) FROM footer_chips", [], |r| r.get(0))
        .unwrap();
    assert_eq!(chips, 0, "precondition: no chip anywhere");

    assert_eq!(filing(&w).topics, [filed(&topic, "No chip", &[b1()])]);
}

#[test]
fn day_filing_lists_a_filed_heading_under_its_topic() {
    let mut w = world_with_day("# Morning\n\nOne.\n", &["blk001", "blk002"]);
    let topic = create_topic(&mut w.vault, "Loop", &[T1]);
    mark_reviewed(&mut w.vault, DAY);

    let f = filing(&w);

    assert_eq!(
        f.topics,
        [filed(&topic, "Loop", &[block("blk001", "# Morning")])]
    );
    assert_eq!(f.not_filed, [block("blk002", "One.")]);
}

#[test]
fn day_filing_tolerates_a_gap_in_block_ords() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "Loop", &["![[2026-09-05#^blk001..^blk005]]"]);
    mark_reviewed(&mut w.vault, DAY);
    w.vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET ord = ord + 10 WHERE note_id = ? AND ord >= 3",
            [w.day.as_str()],
        )
        .unwrap();

    assert_eq!(
        filing(&w).topics,
        [filed(&topic, "Loop", &[b1(), b2(), b3(), b4(), b5()])]
    );
}

// ---------------------------------------------------------------------------
// Not filed
// ---------------------------------------------------------------------------

#[test]
fn day_filing_not_filed_holds_reviewed_unfiled_non_heading_blocks_and_omits_headings_added_and_deleted_blocks(
) {
    let mut w = world_with_day(
        "# Heading\n\nKept.\n\n## Sub\n\nDeleted.\n\nAlso kept.\n",
        &["blk001", "blk002", "blk003", "blk004", "blk005"],
    );
    mark_reviewed(&mut w.vault, DAY);
    let day = w.day.clone();
    person_replace(&mut w.vault, &day, "Deleted.\n\n", "");
    person_replace(
        &mut w.vault,
        &day,
        "Also kept.\n",
        "Also kept.\n\nAdded later.\n",
    );

    let f = filing(&w);

    assert!(f.reviewed, "an edited day was still reviewed");
    assert_eq!(f.topics, []);
    assert_eq!(
        f.not_filed,
        [block("blk002", "Kept."), block("blk005", "Also kept.")],
        "day order, without the headings, the deleted block and the added block"
    );
}

#[test]
fn day_filing_not_filed_omits_a_filed_block() {
    let mut w = world();
    create_topic(&mut w.vault, "Loop", &[T2]);
    mark_reviewed(&mut w.vault, DAY);

    assert_eq!(filing(&w).not_filed, [b1(), b3(), b4(), b5()]);
}

#[test]
fn day_filing_not_filed_follows_the_last_review() {
    let mut w = world_with_day("One.\n", &["blk001"]);
    mark_reviewed(&mut w.vault, DAY);
    let day = w.day.clone();
    person_replace(&mut w.vault, &day, "One.\n", "One.\n\nAdded.\n");
    let added = block_id_of(&w.vault, &day, "Added.");
    assert_eq!(filing(&w).not_filed, [block("blk001", "One.")]);

    mark_reviewed(&mut w.vault, DAY);

    assert_eq!(
        filing(&w).not_filed,
        [block("blk001", "One."), block(&added, "Added.")]
    );
}

#[test]
fn day_filing_shows_the_current_text_of_a_block_edited_after_the_review() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "Loop", &[T1]);
    mark_reviewed(&mut w.vault, DAY);
    let day = w.day.clone();
    // Close enough to the old text for the block to keep its id.
    person_replace(&mut w.vault, &day, "One.", "One!");
    person_replace(&mut w.vault, &day, "Two.", "Two!");

    let f = filing(&w);

    assert_eq!(
        f.topics,
        [filed(&topic, "Loop", &[block("blk001", "One!")])]
    );
    assert_eq!(f.not_filed[0], block("blk002", "Two!"));
}

#[test]
fn day_filing_not_filed_hides_only_real_headings() {
    let mut w = world_with_day(
        "# One\n\n###### Six\n\n  ## Indented\n\n####### Seven\n\n#notag\n\n#\n\nPlain.\n",
        &[
            "blk001", "blk002", "blk003", "blk004", "blk005", "blk006", "blk007",
        ],
    );
    mark_reviewed(&mut w.vault, DAY);

    let ids: Vec<String> = filing(&w).not_filed.into_iter().map(|b| b.id).collect();

    assert_eq!(
        ids,
        ["blk004", "blk005", "blk006", "blk007"],
        "seven #s, no space and a bare # are not headings"
    );
}

// ---------------------------------------------------------------------------
// Reviewed, errors, shape
// ---------------------------------------------------------------------------

#[test]
fn day_filing_for_a_day_never_reviewed_has_reviewed_false_and_empty_lists() {
    let mut w = world();
    create_topic(&mut w.vault, "Loop", &[T1]);

    let f = filing(&w);

    assert_eq!(f.date, DAY);
    assert_eq!(f.note_id, w.day.to_string());
    assert!(!f.reviewed);
    assert_eq!(f.topics, []);
    assert_eq!(f.not_filed, []);
}

#[test]
fn day_filing_counts_a_day_without_a_review_row_as_never_reviewed() {
    let mut w = world();
    create_topic(&mut w.vault, "Loop", &[T1]);
    let n = w
        .vault
        .connection_ref()
        .execute(
            "DELETE FROM day_reviews WHERE note_id = ?",
            [w.day.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "precondition: the row existed");

    let f = filing(&w);

    assert_eq!(f.note_id, w.day.to_string());
    assert!(!f.reviewed);
    assert_eq!(f.topics, []);
    assert_eq!(f.not_filed, []);
}

#[test]
fn day_filing_for_a_date_with_no_daily_note_fails_with_not_found() {
    let mut w = world();
    // A role-less note titled with the date is not a daily note.
    create(&mut w.vault, OTHER_DAY, "Text.\n", None);

    for date in ["2026-09-06", OTHER_DAY] {
        let e = day_filing(&w.vault, date).expect_err("no daily note");
        assert!(matches!(e, MemexError::NotFound(_)), "{date}: {e:?}");
        assert_eq!(e.to_error_json()["error"]["code"], json!("not_found"));
    }
}

#[test]
fn day_filing_with_a_malformed_date_fails_with_invalid_date() {
    let w = world();

    for date in ["2026-9-5", "2026-02-30", "", "2026-09-05x"] {
        let e = day_filing(&w.vault, date).expect_err("malformed");
        assert!(matches!(e, MemexError::InvalidDate(_)), "{date:?}: {e:?}");
    }
}

#[test]
fn day_filing_writes_nothing() {
    let mut w = world();
    let topic = create_topic(&mut w.vault, "Loop", &[T1]);
    mark_reviewed(&mut w.vault, DAY);
    let before = db_state(&w.vault);

    let f = filing(&w);

    assert_eq!(f.topics, [filed(&topic, "Loop", &[b1()])]);
    assert_eq!(db_state(&w.vault), before);
}

#[test]
fn day_filing_serializes_to_the_wire_field_names() {
    let mut w = world_with_day("One.\n\nTwo.\n", &["blk001", "blk002"]);
    let topic = create_topic(&mut w.vault, "Loop", &[T1]);
    mark_reviewed(&mut w.vault, DAY);

    let value = serde_json::to_value(filing(&w)).unwrap();

    assert_eq!(
        value,
        json!({
            "date": DAY,
            "note_id": w.day.to_string(),
            "reviewed": true,
            "topics": [{
                "topic_note_id": topic.to_string(),
                "title": "Loop",
                "blocks": [{ "id": "blk001", "text": "One." }],
            }],
            "not_filed": [{ "id": "blk002", "text": "Two." }],
        })
    );
}

#[test]
fn day_filing_follows_remove_excerpt_block_and_move_block() {
    let mut w = world();
    let source = create_topic(
        &mut w.vault,
        "Source",
        &["![[2026-09-05#^blk001..^blk003]]"],
    );
    let target = create_topic(&mut w.vault, "Target", &[T4]);
    mark_reviewed(&mut w.vault, DAY);

    remove_excerpt_block(&mut w.vault, &source, DAY, "blk002", Caller::Person, None).unwrap();
    move_block(
        &mut w.vault,
        DAY,
        "blk003",
        &source,
        &target,
        Caller::Person,
        None,
    )
    .unwrap();

    let f = filing(&w);
    assert!(f.reviewed);
    assert_eq!(
        f.topics,
        [
            filed(&source, "Source", &[b1()]),
            filed(&target, "Target", &[b3(), b4()]),
        ]
    );
    assert_eq!(f.not_filed, [b2(), b5()]);
}

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

#[test]
fn glossary_defines_feedback_correction_and_vault_guide() {
    let glossary =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../GLOSSARY.md")).unwrap();

    for term in ["**Feedback**:", "**Correction**:", "**Vault Guide**:"] {
        assert!(
            glossary.lines().any(|l| l == term),
            "GLOSSARY.md has no {term} entry"
        );
    }
}
