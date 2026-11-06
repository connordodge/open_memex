//! WI #10 (R7): excerpts — `excerpts::add_excerpt`, `excerpts::remove_excerpt`
//! and `excerpts::note_transclusion_fields` (Req 14, 19, 31; D8, D9, D11, D13).
//!
//! - `add_excerpt(topic, date, block_ids)` writes one transclusion token per
//!   maximal consecutive (by `ord`) run of the blocks, in ord order, under a
//!   `## <date>` heading (created at the end when absent, reused otherwise),
//!   never filing a block the topic already holds for that day, and adds an
//!   `excerpt` chip for the topic to that day's Topics footer.
//! - `remove_excerpt` removes every token whose endpoints are `block_ids`
//!   (first id = `from`, last id = `to` or the only id), the heading when
//!   nothing else is under it, and the chip when the topic holds no other
//!   excerpt from that day and the chip's origin is `excerpt`.
//! - Both return the topic note as stored (its new version), retry when a
//!   person save races them (the `*_with_hook` seam runs once per attempt,
//!   between the read and the write), and never move the daily note's content
//!   version or review state. Failures write nothing.
//! - Agent calls go through: the footer write is the D9 internal path, so the
//!   marker rule does not apply (`Caller::Agent` is used throughout).
//!
//! Real SQLite, real schema V5, temp vaults only. Block ids are pinned to the
//! CONTRACTS C4 fixture ids.

use std::sync::atomic::{AtomicUsize, Ordering};

use memex_core::daily::{self, ReviewState};
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::error::MemexError;
use memex_core::excerpts::{
    add_excerpt, add_excerpt_with_hook, move_block, move_block_with_hook, note_transclusion_fields,
    remove_excerpt, remove_excerpt_block, remove_excerpt_block_with_hook, remove_excerpt_with_hook,
    MovedBlock,
};
use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, delete_note_checked, get_note, update_note_as, CreateNote, Note, NoteId,
    RenameOptions, UpdateNote,
};
use memex_core::transclusion::parse_transclusions;
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const DAY: &str = "2026-09-05";
/// The C4 render-fixture daily note: blocks (0, b7k2m9), (1, c3d4e5), (2, f6g7h8).
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const DAY_BLOCKS: [(&str, &str); 3] = [
    ("b7k2m9", "Fixed the jump arc."),
    ("c3d4e5", "- tried coyote time"),
    ("f6g7h8", "Sleep was bad."),
];

/// A second day with five blocks `blk001`..`blk005` (ord 0..4).
const DAY2: &str = "2026-09-07";
const DAY2_BODY: &str = "One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive.\n";
const DAY2_BLOCKS: [(&str, &str); 5] = [
    ("blk001", "One."),
    ("blk002", "Two."),
    ("blk003", "Three."),
    ("blk004", "Four."),
    ("blk005", "Five."),
];

const TOPIC_TITLE: &str = "Player Loop";
const TOPIC_BODY: &str = "All about the player loop.\n";

const T_B7: &str = "![[2026-09-05#^b7k2m9]]";
const T_C3: &str = "![[2026-09-05#^c3d4e5]]";
const T_F6: &str = "![[2026-09-05#^f6g7h8]]";
const T_B7_C3: &str = "![[2026-09-05#^b7k2m9..^c3d4e5]]";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct World {
    _dir: TempDir,
    vault: Vault,
    day: NoteId,
    topic: NoteId,
}

/// A vault with the C4 fixture day `2026-09-05` and the topic `Player Loop`.
fn world() -> World {
    world_with_topic_body(TOPIC_BODY)
}

fn world_with_topic_body(topic_body: &str) -> World {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let day = create_day(&mut vault, DAY, DAY_BODY, &DAY_BLOCKS);
    let topic = create_topic(&mut vault, TOPIC_TITLE, topic_body);
    World {
        _dir: dir,
        vault,
        day,
        topic,
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

fn create_topic(vault: &mut Vault, title: &str, body: &str) -> NoteId {
    create(vault, title, body, Some(json!({ "role": "topic" }))).id
}

/// A daily note whose stored block ids are pinned to `blocks` by ord.
fn create_day(vault: &mut Vault, date: &str, body: &str, blocks: &[(&str, &str)]) -> NoteId {
    let note = create(vault, date, body, Some(json!({ "role": "daily" })));
    let texts: Vec<String> = blocks_of(vault, &note.id)
        .into_iter()
        .map(|(_, t)| t)
        .collect();
    let expected: Vec<&str> = blocks.iter().map(|(_, t)| *t).collect();
    assert_eq!(texts, expected, "precondition: {date} splits into blocks");
    for (ord, (id, _)) in blocks.iter().enumerate() {
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

fn reindex(vault: &mut Vault, note: &Note) {
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
}

/// `(block_id, text)` of a note's stored blocks, in ord order.
fn blocks_of(vault: &Vault, id: &NoteId) -> Vec<(String, String)> {
    vault
        .connection_ref()
        .prepare("SELECT block_id, text FROM blocks WHERE note_id = ? ORDER BY ord")
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn ids(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn add(w: &mut World, date: &str, block_ids: &[&str]) -> Note {
    add_excerpt(
        &mut w.vault,
        &w.topic,
        date,
        &ids(block_ids),
        Caller::Agent,
        None,
    )
    .unwrap_or_else(|e| panic!("add_excerpt {date} {block_ids:?}: {e}"))
}

fn add_err(w: &mut World, topic: &NoteId, date: &str, block_ids: &[&str]) -> MemexError {
    match add_excerpt(
        &mut w.vault,
        topic,
        date,
        &ids(block_ids),
        Caller::Agent,
        None,
    ) {
        Ok(n) => panic!(
            "add_excerpt {date} {block_ids:?} should fail, stored:\n{}",
            n.content_md
        ),
        Err(e) => e,
    }
}

fn remove(w: &mut World, date: &str, block_ids: &[&str]) -> Note {
    remove_excerpt(
        &mut w.vault,
        &w.topic,
        date,
        &ids(block_ids),
        Caller::Agent,
        None,
    )
    .unwrap_or_else(|e| panic!("remove_excerpt {date} {block_ids:?}: {e}"))
}

fn remove_err(w: &mut World, topic: &NoteId, date: &str, block_ids: &[&str]) -> MemexError {
    match remove_excerpt(
        &mut w.vault,
        topic,
        date,
        &ids(block_ids),
        Caller::Agent,
        None,
    ) {
        Ok(n) => panic!(
            "remove_excerpt {date} {block_ids:?} should fail, stored:\n{}",
            n.content_md
        ),
        Err(e) => e,
    }
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    get_note(vault, id).unwrap()
}

fn body(w: &World) -> String {
    stored(&w.vault, &w.topic).content_md
}

/// Non-blank lines with trailing whitespace trimmed.
fn content_lines(body: &str) -> Vec<String> {
    body.lines()
        .map(|l| l.trim_end().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

/// The non-blank lines under `## <date>`, up to the next `## ` heading.
fn section(body: &str, date: &str) -> Vec<String> {
    let heading = format!("## {date}");
    let lines = content_lines(body);
    let start = lines
        .iter()
        .position(|l| *l == heading)
        .unwrap_or_else(|| panic!("no {heading} in:\n{body}"));
    lines[start + 1..]
        .iter()
        .take_while(|l| !l.starts_with("## "))
        .cloned()
        .collect()
}

fn heading_count(body: &str, date: &str) -> usize {
    let heading = format!("## {date}");
    content_lines(body)
        .iter()
        .filter(|l| **l == heading)
        .count()
}

/// The literal transclusion tokens of `body`, in order.
fn tokens(body: &str) -> Vec<String> {
    parse_transclusions(body)
        .iter()
        .map(|t| body[t.start..t.end].to_string())
        .collect()
}

/// `(topic_note_id, origin)` of a daily note's chips, in rowid order.
fn chip_rows(vault: &Vault, day: &NoteId) -> Vec<(String, String)> {
    vault
        .connection_ref()
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap()
        .query_map([day.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn chip(topic: &NoteId, origin: &str) -> (String, String) {
    (topic.to_string(), origin.to_string())
}

fn person_text(vault: &Vault, day: &NoteId) -> String {
    daily::split_body(&stored(vault, day).content_md).person
}

fn footer_titles(vault: &Vault, day: &NoteId) -> Vec<String> {
    daily::split_body(&stored(vault, day).content_md).chips
}

fn content_version(vault: &Vault, day: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [day.as_str()],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("no day_reviews row for {day}: {e}"))
}

fn mark_reviewed(vault: &Vault, day: &NoteId) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE day_reviews SET reviewed_content_version = content_version, reviewed_at = 1
             WHERE note_id = ?",
            [day.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1);
    assert_eq!(review_state(vault, day), ReviewState::Reviewed);
}

fn review_state(vault: &Vault, day: &NoteId) -> ReviewState {
    daily::review_state(vault.connection_ref(), day.as_str()).unwrap()
}

/// `to_note_id` of every `from-day` link out of `id`, in position order.
fn from_day_links(vault: &Vault, id: &NoteId) -> Vec<Option<String>> {
    vault
        .connection_ref()
        .prepare(
            "SELECT to_note_id FROM links WHERE from_note_id = ? AND link_kind = 'from-day'
             ORDER BY position",
        )
        .unwrap()
        .query_map([id.as_str()], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// A person save of `id` with `text` appended (as the app would), reindexed.
fn person_append(vault: &mut Vault, id: &NoteId, text: &str) -> Note {
    let current = get_note(vault, id).unwrap();
    let saved = update_note_as(
        vault,
        id,
        current.version,
        UpdateNote {
            content_md: Some(format!("{}{text}", current.content_md)),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person save of {id}: {e}"));
    reindex(vault, &saved);
    saved
}

/// Everything a failed call must leave untouched.
#[derive(Debug, PartialEq)]
struct Snapshot {
    notes: Vec<(String, String, String, i64, i64)>,
    chips: Vec<(String, String, String)>,
    reviews: Vec<(String, i64, Option<i64>)>,
    links: Vec<(String, String, Option<String>, i64)>,
}

fn snapshot(vault: &Vault) -> Snapshot {
    let conn = vault.connection_ref();
    let notes = conn
        .prepare("SELECT id, content_md, frontmatter, version, updated_at FROM notes ORDER BY id")
        .unwrap()
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })
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
    let reviews = conn
        .prepare(
            "SELECT note_id, content_version, reviewed_content_version FROM day_reviews
             ORDER BY note_id",
        )
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let links = conn
        .prepare(
            "SELECT from_note_id, link_kind, to_note_id, position FROM links
             ORDER BY from_note_id, position",
        )
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    Snapshot {
        notes,
        chips,
        reviews,
        links,
    }
}

fn code(e: &MemexError) -> String {
    e.to_error_json()["error"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("no code for {e:?}"))
        .to_string()
}

fn assert_role_rule(e: &MemexError) {
    assert!(matches!(e, MemexError::RoleRule(_)), "RoleRule: {e:?}");
    let v = e.to_error_json();
    assert_eq!(v["error"]["code"], json!("role_rule"), "{v}");
    let message = v["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("role"), "message names the role rule: {v}");
}

// ===========================================================================
// AC 1: a new `## <date>` heading and token appended; rest byte-identical;
// returns the topic note's new version.
// ===========================================================================

#[test]
fn add_excerpt_appends_a_new_date_heading_and_token_and_returns_the_new_version() {
    let mut w = world();
    let before = stored(&w.vault, &w.topic);

    let returned = add(&mut w, DAY, &["b7k2m9"]);

    let after = stored(&w.vault, &w.topic);
    assert_eq!(returned.id, w.topic, "returns the topic note");
    assert_eq!(
        returned.version,
        before.version + 1,
        "one write: new version"
    );
    assert_eq!(returned.version, after.version, "returned = stored version");
    assert_eq!(returned.content_md, after.content_md);
    assert!(
        after.content_md.starts_with(TOPIC_BODY),
        "the existing body is kept byte-identical:\n{}",
        after.content_md
    );
    assert_eq!(
        content_lines(&after.content_md),
        ["All about the player loop.", "## 2026-09-05", T_B7],
        "{}",
        after.content_md
    );
    assert_eq!(after.title, before.title);
    assert_eq!(after.frontmatter, before.frontmatter);
}

#[test]
fn add_excerpt_puts_the_heading_on_its_own_line_after_an_unterminated_body() {
    let original = "Intro line.\n\nLast line with no newline";
    let mut w = world_with_topic_body(original);

    add(&mut w, DAY, &["b7k2m9"]);

    let after = body(&w);
    assert!(after.starts_with(original), "{after}");
    assert_eq!(
        content_lines(&after),
        [
            "Intro line.",
            "Last line with no newline",
            "## 2026-09-05",
            T_B7
        ],
        "{after}"
    );
}

#[test]
fn add_excerpt_into_an_empty_topic_body_writes_heading_then_token() {
    let mut w = world_with_topic_body("");

    add(&mut w, DAY, &["c3d4e5"]);

    assert_eq!(content_lines(&body(&w)), ["## 2026-09-05", T_C3]);
}

// ===========================================================================
// AC 2: consecutive ids → one range token.
// ===========================================================================

#[test]
fn add_excerpt_writes_one_range_token_for_consecutive_blocks() {
    let mut w = world();

    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);

    let b = body(&w);
    assert_eq!(tokens(&b), [T_B7_C3], "{b}");
    assert_eq!(section(&b, DAY), [T_B7_C3], "{b}");
}

#[test]
fn add_excerpt_orders_range_endpoints_by_ord() {
    let mut w = world();

    add(&mut w, DAY, &["c3d4e5", "b7k2m9"]);

    assert_eq!(tokens(&body(&w)), [T_B7_C3]);
}

#[test]
fn add_excerpt_merges_three_consecutive_blocks_into_one_range() {
    let mut w = world();

    add(&mut w, DAY, &["f6g7h8", "b7k2m9", "c3d4e5"]);

    assert_eq!(tokens(&body(&w)), ["![[2026-09-05#^b7k2m9..^f6g7h8]]"]);
}

// ===========================================================================
// AC 3: non-consecutive ids → one token per consecutive run, in ord order.
// ===========================================================================

#[test]
fn add_excerpt_writes_one_token_per_consecutive_run_in_ord_order() {
    let mut w = world();

    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);

    let b = body(&w);
    assert_eq!(section(&b, DAY), [T_B7, T_F6], "{b}");
    assert_eq!(heading_count(&b, DAY), 1);
}

#[test]
fn add_excerpt_sorts_non_consecutive_ids_by_ord() {
    let mut w = world();

    add(&mut w, DAY, &["f6g7h8", "b7k2m9"]);

    assert_eq!(section(&body(&w), DAY), [T_B7, T_F6]);
}

#[test]
fn add_excerpt_splits_mixed_runs_into_single_and_range_tokens() {
    let mut w = world();
    create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);

    add(&mut w, DAY2, &["blk005", "blk001", "blk004", "blk003"]);

    assert_eq!(
        section(&body(&w), DAY2),
        [
            "![[2026-09-07#^blk001]]",
            "![[2026-09-07#^blk003..^blk005]]"
        ]
    );
}

#[test]
fn add_excerpt_writes_two_ranges_around_a_gap() {
    let mut w = world();
    create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);

    add(&mut w, DAY2, &["blk001", "blk002", "blk004", "blk005"]);

    assert_eq!(
        section(&body(&w), DAY2),
        [
            "![[2026-09-07#^blk001..^blk002]]",
            "![[2026-09-07#^blk004..^blk005]]"
        ]
    );
}

// ===========================================================================
// AC 4: a second add for the same date reuses the heading and appends under it.
// Idempotence: a block the topic already holds is not filed twice.
// ===========================================================================

#[test]
fn second_add_excerpt_for_the_same_date_reuses_the_heading() {
    let mut w = world();

    add(&mut w, DAY, &["b7k2m9"]);
    add(&mut w, DAY, &["f6g7h8"]);

    let b = body(&w);
    assert_eq!(heading_count(&b, DAY), 1, "no duplicate heading:\n{b}");
    assert_eq!(section(&b, DAY), [T_B7, T_F6], "{b}");
    assert_eq!(
        content_lines(&b),
        ["All about the player loop.", "## 2026-09-05", T_B7, T_F6]
    );
}

#[test]
fn add_excerpt_appends_under_an_existing_heading_before_the_next_section() {
    let head = "Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n";
    let tail = "## Later\n\nKeep me.\n";
    let mut w = world_with_topic_body(&format!("{head}\n{tail}"));

    add(&mut w, DAY, &["f6g7h8"]);

    let b = body(&w);
    assert_eq!(
        content_lines(&b),
        [
            "Intro.",
            "## 2026-09-05",
            T_B7,
            T_F6,
            "## Later",
            "Keep me."
        ],
        "{b}"
    );
    assert!(b.starts_with(head), "text before the insert is kept:\n{b}");
    assert!(b.ends_with(tail), "text after the insert is kept:\n{b}");
}

#[test]
fn add_excerpt_for_another_date_adds_its_own_heading() {
    let mut w = world();
    create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);

    add(&mut w, DAY, &["b7k2m9"]);
    add(&mut w, DAY2, &["blk002"]);

    let b = body(&w);
    assert_eq!(
        content_lines(&b),
        [
            "All about the player loop.",
            "## 2026-09-05",
            T_B7,
            "## 2026-09-07",
            "![[2026-09-07#^blk002]]"
        ],
        "{b}"
    );
}

#[test]
fn add_excerpt_twice_with_the_same_block_files_it_once() {
    let mut w = world();

    let first = add(&mut w, DAY, &["b7k2m9"]);
    let second = add(&mut w, DAY, &["b7k2m9"]);

    let b = body(&w);
    assert_eq!(tokens(&b), [T_B7], "{b}");
    assert_eq!(heading_count(&b, DAY), 1);
    assert_eq!(second.version, first.version, "nothing to write");
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
}

#[test]
fn add_excerpt_skips_a_block_already_inside_a_range_token() {
    let mut w = world();

    let first = add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);
    let second = add(&mut w, DAY, &["c3d4e5"]);

    assert_eq!(tokens(&body(&w)), [T_B7_C3]);
    assert_eq!(second.version, first.version, "nothing to write");
}

#[test]
fn add_excerpt_files_only_the_blocks_the_topic_does_not_hold_yet() {
    let mut w = world();

    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);
    add(&mut w, DAY, &["c3d4e5", "f6g7h8"]);

    assert_eq!(section(&body(&w), DAY), [T_B7_C3, T_F6]);
}

// ===========================================================================
// AC 5: an `excerpt` chip on the day's footer; the day's text above the
// marker and its content version unchanged.
// ===========================================================================

#[test]
fn add_excerpt_adds_an_excerpt_chip_and_keeps_the_day_text_and_content_version() {
    let mut w = world();
    let person_before = person_text(&w.vault, &w.day);
    let cv_before = content_version(&w.vault, &w.day);
    assert_eq!(chip_rows(&w.vault, &w.day), []);

    add(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
    assert_eq!(footer_titles(&w.vault, &w.day), [TOPIC_TITLE]);
    let day_body = stored(&w.vault, &w.day).content_md;
    assert!(
        day_body
            .lines()
            .any(|l| l.trim_end() == "[[Player Loop~about]]"),
        "{day_body}"
    );
    assert_eq!(
        person_text(&w.vault, &w.day),
        person_before,
        "the text above the marker is byte-identical"
    );
    assert!(day_body.starts_with(DAY_BODY), "{day_body}");
    assert_eq!(content_version(&w.vault, &w.day), cv_before);
    assert_eq!(
        blocks_of(&w.vault, &w.day)
            .into_iter()
            .map(|(id, _)| id)
            .collect::<Vec<_>>(),
        ["b7k2m9", "c3d4e5", "f6g7h8"],
        "the day keeps its block ids"
    );
}

#[test]
fn add_excerpt_chips_only_the_day_of_the_excerpt() {
    let mut w = world();
    let day2 = create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);

    add(&mut w, DAY2, &["blk003"]);

    assert_eq!(chip_rows(&w.vault, &day2), [chip(&w.topic, "excerpt")]);
    assert_eq!(chip_rows(&w.vault, &w.day), []);
}

#[test]
fn add_excerpt_keeps_a_person_chip_as_person() {
    let mut w = world();
    footer::set_chip(&mut w.vault, &w.day, &w.topic, ChipOrigin::Person, None).unwrap();

    add(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "person")]);
    assert_eq!(footer_titles(&w.vault, &w.day), [TOPIC_TITLE]);
}

// ===========================================================================
// AC 6: a Reviewed day stays Reviewed after add_excerpt and remove_excerpt.
// ===========================================================================

#[test]
fn reviewed_day_stays_reviewed_after_add_and_remove_excerpt() {
    let mut w = world();
    mark_reviewed(&w.vault, &w.day);
    let cv = content_version(&w.vault, &w.day);

    add(&mut w, DAY, &["b7k2m9"]);
    assert_eq!(review_state(&w.vault, &w.day), ReviewState::Reviewed);
    assert_eq!(content_version(&w.vault, &w.day), cv);

    remove(&mut w, DAY, &["b7k2m9"]);
    assert_eq!(review_state(&w.vault, &w.day), ReviewState::Reviewed);
    assert_eq!(content_version(&w.vault, &w.day), cv);
    assert_eq!(chip_rows(&w.vault, &w.day), [], "the chip went away");
}

// ===========================================================================
// AC 7: a target note without `role: topic` → role_rule, nothing written.
// ===========================================================================

#[test]
fn add_excerpt_rejects_a_roleless_note_with_role_rule_and_writes_nothing() {
    let mut w = world();
    let plain = create(&mut w.vault, "Loose note", "Just text.\n", None).id;
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &plain, DAY, &["b7k2m9"]);

    assert_role_rule(&e);
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn add_excerpt_rejects_a_daily_note_target_with_role_rule_and_writes_nothing() {
    let mut w = world();
    let other_day = create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &other_day, DAY, &["b7k2m9"]);
    assert_role_rule(&e);
    let day = w.day.clone();
    let e = add_err(&mut w, &day, DAY, &["b7k2m9"]);
    assert_role_rule(&e);

    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn add_excerpt_requires_the_exact_topic_role() {
    let mut w = world();
    let capital = create(
        &mut w.vault,
        "Capital",
        "Text.\n",
        Some(json!({ "role": "Topic" })),
    )
    .id;
    let other = create(
        &mut w.vault,
        "Other",
        "Text.\n",
        Some(json!({ "role": "project" })),
    )
    .id;
    let before = snapshot(&w.vault);

    assert_role_rule(&add_err(&mut w, &capital, DAY, &["b7k2m9"]));
    assert_role_rule(&add_err(&mut w, &other, DAY, &["b7k2m9"]));
    assert_eq!(snapshot(&w.vault), before);
}

// ===========================================================================
// AC 8: block_not_found, not_found, invalid_date; nothing written.
// ===========================================================================

#[test]
fn add_excerpt_with_an_unknown_block_id_fails_with_block_not_found_and_writes_nothing() {
    let mut w = world();
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &topic, DAY, &["zzzzzz"]);
    assert!(matches!(e, MemexError::BlockNotFound(_)), "{e:?}");
    assert_eq!(code(&e), "block_not_found");

    // One unknown id among known ones: still nothing written.
    let e = add_err(&mut w, &topic, DAY, &["b7k2m9", "zzzzzz"]);
    assert_eq!(code(&e), "block_not_found");
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn add_excerpt_with_a_block_of_another_day_fails_with_block_not_found() {
    let mut w = world();
    create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &topic, DAY, &["blk001"]);

    assert_eq!(code(&e), "block_not_found", "{e:?}");
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn add_excerpt_for_a_date_without_a_daily_note_fails_with_not_found() {
    let mut w = world();
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &topic, "2026-09-06", &["b7k2m9"]);

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(code(&e), "not_found");
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn add_excerpt_with_a_malformed_date_fails_with_invalid_date() {
    let mut w = world();
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    for date in [
        "2026-9-5",
        "2026-02-30",
        "",
        "05-09-2026",
        "2026-09-05x",
        " 2026-09-05",
    ] {
        let e = add_err(&mut w, &topic, date, &["b7k2m9"]);
        assert!(matches!(e, MemexError::InvalidDate(_)), "{date:?}: {e:?}");
        assert_eq!(code(&e), "invalid_date", "{date:?}");
    }
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn add_excerpt_on_an_unknown_topic_fails_with_not_found() {
    let mut w = world();
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &NoteId::new(), DAY, &["b7k2m9"]);

    assert_eq!(code(&e), "not_found", "{e:?}");
    assert_eq!(snapshot(&w.vault), before);
}

// ===========================================================================
// AC 9: a person save between read and write → retry against the latest
// version; both the person's text and the token are kept.
// ===========================================================================

#[test]
fn add_excerpt_retries_when_a_person_save_lands_between_read_and_write() {
    let mut w = world();
    let topic = w.topic.clone();
    let v0 = stored(&w.vault, &topic).version;
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        if calls == 1 {
            person_append(v, &topic, "A person thought.\n");
        }
    };

    let returned = add_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
        &mut hook,
    )
    .unwrap_or_else(|e| panic!("add_excerpt after a race: {e}"));

    assert_eq!(calls, 2, "one retry after the conflicting save");
    let after = stored(&w.vault, &w.topic);
    assert_eq!(returned.version, after.version);
    assert_eq!(after.version, v0 + 2, "the person save, then the excerpt");
    assert!(
        after.content_md.starts_with(TOPIC_BODY),
        "{}",
        after.content_md
    );
    assert_eq!(
        content_lines(&after.content_md),
        [
            "All about the player loop.",
            "A person thought.",
            "## 2026-09-05",
            T_B7
        ],
        "{}",
        after.content_md
    );
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
}

#[test]
fn add_excerpt_gives_up_with_version_conflict_when_every_attempt_races() {
    let mut w = world();
    let topic = w.topic.clone();
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        person_append(v, &topic, &format!("Edit {calls}.\n"));
    };

    let result = add_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
        &mut hook,
    );

    let e = result.expect_err("every attempt raced");
    assert!(matches!(e, MemexError::VersionConflict { .. }), "{e:?}");
    assert_eq!(code(&e), "version_conflict");
    assert!(
        (2..=10).contains(&calls),
        "bounded retries, more than one attempt: {calls}"
    );
    let b = body(&w);
    assert_eq!(tokens(&b), Vec::<String>::new(), "no token written:\n{b}");
    assert_eq!(heading_count(&b, DAY), 0, "{b}");
    assert_eq!(chip_rows(&w.vault, &w.day), [], "no chip written");
}

#[test]
fn remove_excerpt_retries_when_a_person_save_lands_between_read_and_write() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let v0 = stored(&w.vault, &topic).version;
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        if calls == 1 {
            person_append(v, &topic, "Later note.\n");
        }
    };

    let returned = remove_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
        &mut hook,
    )
    .unwrap_or_else(|e| panic!("remove_excerpt after a race: {e}"));

    assert_eq!(calls, 2, "one retry after the conflicting save");
    let after = stored(&w.vault, &w.topic);
    assert_eq!(returned.version, after.version);
    assert_eq!(after.version, v0 + 2);
    assert_eq!(tokens(&after.content_md), Vec::<String>::new());
    assert!(
        after.content_md.contains("Later note."),
        "{}",
        after.content_md
    );
    assert_eq!(chip_rows(&w.vault, &w.day), []);
}

// ===========================================================================
// AC 10: exactly one `from-day` link to the daily note per written token,
// reindexed from the returned content.
// ===========================================================================

#[test]
fn add_excerpt_reindexes_one_from_day_link_per_written_token() {
    let mut w = world();
    let day_id = Some(w.day.to_string());
    assert_eq!(
        from_day_links(&w.vault, &w.topic),
        Vec::<Option<String>>::new()
    );

    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);
    assert_eq!(
        from_day_links(&w.vault, &w.topic),
        [day_id.clone(), day_id.clone()],
        "two tokens, two from-day links to the day"
    );

    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    assert_eq!(
        from_day_links(&w.vault, &w.topic),
        [day_id.clone(), day_id.clone(), day_id],
        "the newly filed block added one more token and link"
    );
}

#[test]
fn remove_excerpt_reindexes_the_topic_links() {
    let mut w = world();
    let day_id = Some(w.day.to_string());
    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);

    remove(&mut w, DAY, &["f6g7h8"]);
    assert_eq!(from_day_links(&w.vault, &w.topic), [day_id]);

    remove(&mut w, DAY, &["b7k2m9"]);
    assert_eq!(
        from_day_links(&w.vault, &w.topic),
        Vec::<Option<String>>::new()
    );
}

// ===========================================================================
// AC 11: remove the matching range token and its empty heading; return the
// topic note's new version.
// ===========================================================================

#[test]
fn remove_excerpt_removes_the_range_token_and_its_empty_heading() {
    let mut w = world();
    let added = add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);

    let returned = remove(&mut w, DAY, &["b7k2m9", "c3d4e5"]);

    let after = stored(&w.vault, &w.topic);
    assert_eq!(returned.id, w.topic);
    assert_eq!(
        returned.version,
        added.version + 1,
        "one write: new version"
    );
    assert_eq!(returned.version, after.version);
    assert_eq!(returned.content_md, after.content_md);
    assert_eq!(
        after.content_md.trim_end(),
        TOPIC_BODY.trim_end(),
        "token and heading gone:\n{}",
        after.content_md
    );
}

#[test]
fn remove_excerpt_keeps_the_heading_while_another_token_remains() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);

    remove(&mut w, DAY, &["f6g7h8"]);

    let b = body(&w);
    assert_eq!(heading_count(&b, DAY), 1, "{b}");
    assert_eq!(section(&b, DAY), [T_B7], "{b}");
}

#[test]
fn remove_excerpt_keeps_the_heading_while_person_text_remains_under_it() {
    let mut w = world_with_topic_body(
        "Intro.\n\n## 2026-09-05\n\nWhy this matters.\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    let b = body(&w);
    assert_eq!(
        content_lines(&b),
        ["Intro.", "## 2026-09-05", "Why this matters."],
        "{b}"
    );
}

#[test]
fn remove_excerpt_leaves_other_dates_alone() {
    let mut w = world_with_topic_body(
        "## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n\n## 2026-09-06\n\n![[2026-09-06#^b7k2m9]]\n",
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    let b = body(&w);
    assert_eq!(
        content_lines(&b),
        ["## 2026-09-06", "![[2026-09-06#^b7k2m9]]"],
        "{b}"
    );
}

#[test]
fn remove_excerpt_removes_every_copy_of_the_matching_token() {
    let mut w = world_with_topic_body(
        "Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n\n![[2026-09-05#^b7k2m9]]\n",
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    let b = body(&w);
    assert_eq!(content_lines(&b), ["Intro."], "{b}");
}

#[test]
fn remove_excerpt_removes_a_token_whose_daily_note_was_deleted() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let day_version = stored(&w.vault, &w.day).version;
    delete_note_checked(&mut w.vault, &w.day, day_version, None).unwrap();

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(body(&w).trim_end(), TOPIC_BODY.trim_end());
}

#[test]
fn remove_excerpt_removes_a_token_whose_block_no_longer_exists() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let day = w.day.clone();
    let current = stored(&w.vault, &day);
    let saved = update_note_as(
        &mut w.vault,
        &day,
        current.version,
        UpdateNote {
            content_md: Some(current.content_md.replace("Fixed the jump arc.\n\n", "")),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap();
    reindex(&mut w.vault, &saved);
    assert!(
        !blocks_of(&w.vault, &day)
            .iter()
            .any(|(id, _)| id == "b7k2m9"),
        "precondition: the block is gone"
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(tokens(&body(&w)), Vec::<String>::new());
    assert_eq!(chip_rows(&w.vault, &day), []);
}

#[test]
fn remove_excerpt_works_on_the_person_path() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);

    remove_excerpt(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9", "c3d4e5"]),
        Caller::Person,
        None,
    )
    .unwrap_or_else(|e| panic!("person remove_excerpt: {e}"));

    assert_eq!(tokens(&body(&w)), Vec::<String>::new());
    assert_eq!(chip_rows(&w.vault, &w.day), []);
}

// ===========================================================================
// AC 12: the excerpt chip goes with the topic's last excerpt from that day.
// ===========================================================================

#[test]
fn remove_excerpt_removes_the_excerpt_chip_with_the_last_excerpt_of_the_day() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);
    let person_before = person_text(&w.vault, &w.day);
    let cv = content_version(&w.vault, &w.day);

    remove(&mut w, DAY, &["b7k2m9"]);
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [chip(&w.topic, "excerpt")],
        "another excerpt from the day remains"
    );
    assert_eq!(footer_titles(&w.vault, &w.day), [TOPIC_TITLE]);

    remove(&mut w, DAY, &["f6g7h8"]);
    assert_eq!(chip_rows(&w.vault, &w.day), []);
    assert_eq!(
        footer_titles(&w.vault, &w.day),
        Vec::<String>::new(),
        "{}",
        stored(&w.vault, &w.day).content_md
    );
    assert_eq!(person_text(&w.vault, &w.day), person_before);
    assert_eq!(content_version(&w.vault, &w.day), cv);
}

#[test]
fn remove_excerpt_ignores_excerpts_from_other_days_when_removing_the_chip() {
    let mut w = world();
    let day2 = create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);
    add(&mut w, DAY, &["b7k2m9"]);
    add(&mut w, DAY2, &["blk001"]);

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(chip_rows(&w.vault, &w.day), [], "no excerpt of DAY remains");
    assert_eq!(chip_rows(&w.vault, &day2), [chip(&w.topic, "excerpt")]);
    assert_eq!(section(&body(&w), DAY2), ["![[2026-09-07#^blk001]]"]);
}

#[test]
fn remove_excerpt_leaves_other_topics_chips_alone() {
    let mut w = world();
    let other = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["b7k2m9"]);
    add_excerpt(
        &mut w.vault,
        &other,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
    )
    .unwrap();

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&other, "excerpt")]);
    assert_eq!(footer_titles(&w.vault, &w.day), ["Sleep"]);
    assert_eq!(tokens(&stored(&w.vault, &other).content_md), [T_B7]);
}

// ===========================================================================
// AC 13: a `person` chip stays even without any excerpt left.
// ===========================================================================

#[test]
fn remove_excerpt_keeps_a_person_chip_after_the_last_excerpt() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    footer::set_chip(&mut w.vault, &w.day, &w.topic, ChipOrigin::Person, None).unwrap();

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(tokens(&body(&w)), Vec::<String>::new());
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "person")]);
    assert_eq!(footer_titles(&w.vault, &w.day), [TOPIC_TITLE]);
}

// ===========================================================================
// AC 14: endpoints that match no token → not_found, nothing written.
// ===========================================================================

#[test]
fn remove_excerpt_with_unmatched_endpoints_fails_with_not_found_and_writes_nothing() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = remove_err(&mut w, &topic, DAY, &["c3d4e5"]);
    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(code(&e), "not_found");
    let e = remove_err(&mut w, &topic, "2026-09-06", &["b7k2m9"]);
    assert_eq!(code(&e), "not_found", "same ids, other date: {e:?}");

    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn remove_excerpt_single_id_does_not_match_a_range_token() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    assert_eq!(
        code(&remove_err(&mut w, &topic, DAY, &["b7k2m9"])),
        "not_found"
    );
    assert_eq!(
        code(&remove_err(&mut w, &topic, DAY, &["c3d4e5"])),
        "not_found"
    );
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn remove_excerpt_range_ids_do_not_match_a_single_token() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = remove_err(&mut w, &topic, DAY, &["b7k2m9", "c3d4e5"]);

    assert_eq!(code(&e), "not_found", "{e:?}");
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn remove_excerpt_range_ids_must_match_the_token_end() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = remove_err(&mut w, &topic, DAY, &["b7k2m9", "f6g7h8"]);

    assert_eq!(code(&e), "not_found", "{e:?}");
    assert_eq!(snapshot(&w.vault), before);
}

// ===========================================================================
// AC 15 (core side): remove_excerpt rule errors carry the C1 rule code.
// ===========================================================================

#[test]
fn remove_excerpt_rule_errors_carry_their_codes_and_write_nothing() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let plain = create(
        &mut w.vault,
        "Loose note",
        "![[2026-09-05#^b7k2m9]]\n",
        None,
    )
    .id;
    let topic = w.topic.clone();
    let day = w.day.clone();
    let before = snapshot(&w.vault);

    assert_role_rule(&remove_err(&mut w, &plain, DAY, &["b7k2m9"]));
    assert_role_rule(&remove_err(&mut w, &day, DAY, &["b7k2m9"]));
    let e = remove_err(&mut w, &topic, "2026-9-5", &["b7k2m9"]);
    assert!(matches!(e, MemexError::InvalidDate(_)), "{e:?}");
    assert_eq!(code(&e), "invalid_date");
    assert_eq!(
        code(&remove_err(&mut w, &NoteId::new(), DAY, &["b7k2m9"])),
        "not_found"
    );

    assert_eq!(snapshot(&w.vault), before);
}

// ===========================================================================
// AC 18 (core side): `transclusions` rendered per C4, X1–X5; absent without
// any token.
// ===========================================================================

#[test]
fn note_transclusion_fields_render_the_c4_fixtures_x1_to_x5() {
    let body = "## 2026-09-05\n\n\
                ![[2026-09-05#^b7k2m9]]\n\n\
                ![[2026-09-05#^b7k2m9..^c3d4e5]]\n\n\
                ![[2026-09-05#^zzzzzz]]\n\n\
                ![[2026-09-05#^b7k2m9..^zzzzzz]]\n\n\
                ![[2026-09-06#^b7k2m9]]\n";
    let w = world_with_topic_body(body);
    let note = stored(&w.vault, &w.topic);

    let fields = note_transclusion_fields(&w.vault, &note).unwrap();

    assert_eq!(
        Value::Object(fields),
        json!({
            "transclusions": [
                { "date": "2026-09-05", "from": "b7k2m9", "to": null,
                  "text": "Fixed the jump arc." },
                { "date": "2026-09-05", "from": "b7k2m9", "to": "c3d4e5",
                  "text": "Fixed the jump arc.\n- tried coyote time" },
                { "date": "2026-09-05", "from": "zzzzzz", "to": null,
                  "text": "removed from 2026-09-05" },
                { "date": "2026-09-05", "from": "b7k2m9", "to": "zzzzzz",
                  "text": "removed from 2026-09-05" },
                { "date": "2026-09-06", "from": "b7k2m9", "to": null,
                  "text": "removed from 2026-09-06" },
            ]
        })
    );
}

#[test]
fn note_transclusion_fields_follow_an_added_excerpt_and_vanish_after_removal() {
    let mut w = world();
    let plain = stored(&w.vault, &w.topic);
    assert!(
        note_transclusion_fields(&w.vault, &plain)
            .unwrap()
            .is_empty(),
        "no transclusions key for a note without tokens"
    );

    let added = add(&mut w, DAY, &["c3d4e5", "f6g7h8"]);
    assert_eq!(
        Value::Object(note_transclusion_fields(&w.vault, &added).unwrap()),
        json!({
            "transclusions": [
                { "date": "2026-09-05", "from": "c3d4e5", "to": "f6g7h8",
                  "text": "- tried coyote time\nSleep was bad." },
            ]
        })
    );

    let removed = remove(&mut w, DAY, &["c3d4e5", "f6g7h8"]);
    let fields = note_transclusion_fields(&w.vault, &removed).unwrap();
    assert!(
        !fields.contains_key("transclusions"),
        "the key is absent once the last token is gone: {fields:?}"
    );
}

// ===========================================================================
// Implementer additions (#10): lead rulings for untested cases and the exact
// layout of the topic body around inserted and removed tokens.
// ===========================================================================

/// Lead ruling: an empty `block_ids` is an error and writes nothing (AC 8).
#[test]
fn add_and_remove_excerpt_with_no_block_ids_fail_and_write_nothing() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &topic, DAY, &[]);
    assert!(matches!(e, MemexError::Io(_)), "{e:?}");
    let e = remove_err(&mut w, &topic, DAY, &[]);
    assert!(matches!(e, MemexError::Io(_)), "{e:?}");

    assert_eq!(snapshot(&w.vault), before);
}

/// Lead ruling: a repeated id counts once, as if listed once (AC 2).
#[test]
fn add_excerpt_counts_a_repeated_block_id_once() {
    let mut w = world();

    add(&mut w, DAY, &["b7k2m9", "b7k2m9", "c3d4e5", "b7k2m9"]);

    assert_eq!(tokens(&body(&w)), [T_B7_C3]);
}

/// Lead ruling: repeated ids name the same endpoints as listing each once
/// (AC 11).
#[test]
fn remove_excerpt_counts_a_repeated_block_id_once() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);

    remove(&mut w, DAY, &["b7k2m9", "b7k2m9"]);

    assert_eq!(body(&w).trim_end(), TOPIC_BODY.trim_end());
}

/// Lead ruling: a role-less note titled with the date is not a daily note,
/// so the date has none (AC 8).
#[test]
fn add_excerpt_ignores_a_roleless_note_titled_with_the_date() {
    let mut w = world();
    let loose = create(&mut w.vault, "2026-09-06", "Fixed the jump arc.\n", None);
    assert!(loose.frontmatter.get("role").is_none(), "role-less");
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = add_err(&mut w, &topic, "2026-09-06", &["b7k2m9"]);

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(snapshot(&w.vault), before);
}

/// The retry bound is five attempts (AC 9).
#[test]
fn add_excerpt_gives_up_after_exactly_five_attempts() {
    let mut w = world();
    let topic = w.topic.clone();
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        person_append(v, &topic, &format!("Edit {calls}.\n"));
    };

    let e = add_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("every attempt raced");

    assert_eq!(code(&e), "version_conflict");
    assert_eq!(calls, 5);
}

/// An exhausted remove keeps the token and the chip (AC 9).
#[test]
fn remove_excerpt_gives_up_after_exactly_five_attempts_and_keeps_the_excerpt() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        person_append(v, &topic, &format!("Edit {calls}.\n"));
    };

    let e = remove_excerpt_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("every attempt raced");

    assert_eq!(code(&e), "version_conflict");
    assert_eq!(calls, 5);
    assert_eq!(tokens(&body(&w)), [T_B7]);
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
}

/// An empty `## <date>` heading gets the token right under it, before the
/// next section (AC 4).
#[test]
fn add_excerpt_fills_an_empty_date_heading_before_the_next_section() {
    let mut w = world_with_topic_body("Intro.\n\n## 2026-09-05\n\n## Later\n");

    add(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(
        body(&w),
        "Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n\n## Later\n"
    );
}

/// A date heading on the last line without a newline (AC 4).
#[test]
fn add_excerpt_under_an_unterminated_date_heading() {
    let mut w = world_with_topic_body("Intro.\n\n## 2026-09-05");

    add(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(
        body(&w),
        "Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n"
    );
}

/// The surrounding text stays byte-identical when a token line goes (AC 11).
#[test]
fn remove_excerpt_keeps_the_text_around_the_token_byte_identical() {
    let mut w = world_with_topic_body(
        "Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\nRight after.\n\n## Later\n\nKeep.\n",
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(
        body(&w),
        "Intro.\n\n## 2026-09-05\n\nRight after.\n\n## Later\n\nKeep.\n"
    );
}

/// An emptied date section goes, the next section stays as it was (AC 11).
#[test]
fn remove_excerpt_drops_an_emptied_section_before_the_next_one() {
    let mut w = world_with_topic_body(
        "Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]\n\n## Later\n\nKeep.\n",
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(body(&w), "Intro.\n\n## Later\n\nKeep.\n");
}

/// A token on the last line without a newline (AC 11).
#[test]
fn remove_excerpt_removes_an_unterminated_last_token() {
    let mut w = world_with_topic_body("Intro.\n\n## 2026-09-05\n\n![[2026-09-05#^b7k2m9]]");

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(body(&w), "Intro.\n");
}

/// A token inside a line of text: only the token goes (AC 11).
#[test]
fn remove_excerpt_removes_an_inline_token_and_keeps_its_line() {
    let mut w = world_with_topic_body(
        "Intro.\n\n## 2026-09-05\n\nSee ![[2026-09-05#^b7k2m9]] here.\n\nEnd.\n",
    );

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(body(&w), "Intro.\n\n## 2026-09-05\n\nSee  here.\n\nEnd.\n");
}

/// A token on the first line takes the blank line after it along (AC 11).
#[test]
fn remove_excerpt_removes_a_leading_token_and_the_blank_line_after_it() {
    let mut w = world_with_topic_body("![[2026-09-05#^b7k2m9]]\n\nText.\n");

    remove(&mut w, DAY, &["b7k2m9"]);

    assert_eq!(body(&w), "Text.\n");
}

// ===========================================================================
// WI #248 (F1): `remove_excerpt_block` and `move_block` (Spec #233 R11, R12,
// R13). Coverage is by ord between a token's endpoints; every token of the
// date that covers the block is rewritten; failures write nothing.
// ===========================================================================

const T_B7_F6: &str = "![[2026-09-05#^b7k2m9..^f6g7h8]]";
const T_C3_F6: &str = "![[2026-09-05#^c3d4e5..^f6g7h8]]";

fn world_with_day2(topic_body: &str) -> (World, NoteId) {
    let mut w = world_with_topic_body(topic_body);
    let day2 = create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);
    (w, day2)
}

fn remove_block(w: &mut World, date: &str, block_id: &str) -> Note {
    remove_excerpt_block(&mut w.vault, &w.topic, date, block_id, Caller::Agent, None)
        .unwrap_or_else(|e| panic!("remove_excerpt_block {date} {block_id}: {e}"))
}

fn remove_block_err(w: &mut World, topic: &NoteId, date: &str, block_id: &str) -> MemexError {
    match remove_excerpt_block(&mut w.vault, topic, date, block_id, Caller::Agent, None) {
        Ok(n) => panic!(
            "remove_excerpt_block {date} {block_id} should fail, stored:\n{}",
            n.content_md
        ),
        Err(e) => e,
    }
}

fn move_ok(w: &mut World, block_id: &str, from: &NoteId, to: &NoteId) -> MovedBlock {
    move_block(&mut w.vault, DAY, block_id, from, to, Caller::Agent, None)
        .unwrap_or_else(|e| panic!("move_block {block_id}: {e}"))
}

fn move_err(w: &mut World, date: &str, block_id: &str, from: &NoteId, to: &NoteId) -> MemexError {
    match move_block(&mut w.vault, date, block_id, from, to, Caller::Agent, None) {
        Ok(m) => panic!(
            "move_block {date} {block_id} should fail, source:\n{}\ntarget:\n{}",
            m.from.content_md, m.to.content_md
        ),
        Err(e) => e,
    }
}

/// `## <date>` with the given tokens, one per line and a blank line between.
fn date_section(date: &str, tokens: &[&str]) -> String {
    format!("## {date}\n\n{}\n", tokens.join("\n\n"))
}

/// A person save of `id` with `from` replaced by `to`, reindexed.
fn person_replace(vault: &mut Vault, id: &NoteId, from: &str, to: &str) -> Note {
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
    saved
}

/// The stored id of the block of `day` whose text is `text`.
fn block_id_of(vault: &Vault, day: &NoteId, text: &str) -> String {
    blocks_of(vault, day)
        .into_iter()
        .find(|(_, t)| t == text)
        .unwrap_or_else(|| panic!("no block {text:?}"))
        .0
}

fn assert_invalid_input(e: &MemexError) {
    match e {
        MemexError::Io(io) => assert_eq!(io.kind(), std::io::ErrorKind::InvalidInput, "{e:?}"),
        other => panic!("expected Io(InvalidInput), got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// remove_excerpt_block: splitting and shrinking
// ---------------------------------------------------------------------------

#[test]
fn remove_excerpt_block_from_the_middle_of_a_three_block_range_leaves_two_tokens_in_place() {
    let mut w = world();
    let added = add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    assert_eq!(tokens(&added.content_md), [T_B7_F6], "precondition");

    let returned = remove_block(&mut w, DAY, "c3d4e5");

    let after = stored(&w.vault, &w.topic);
    assert_eq!(
        after.content_md,
        format!("{TOPIC_BODY}\n{}", date_section(DAY, &[T_B7, T_F6])),
        "the two tokens replace the range in place, in order"
    );
    assert_eq!(returned.id, w.topic, "returns the topic note");
    assert_eq!(returned.version, added.version + 1, "one write");
    assert_eq!(returned.version, after.version);
    assert_eq!(returned.content_md, after.content_md);
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [chip(&w.topic, "excerpt")],
        "the topic still holds blocks of the day"
    );
}

#[test]
fn remove_excerpt_block_rewrites_a_five_block_range_for_every_position() {
    let cases: [(&str, &[&str]); 5] = [
        ("blk001", &["![[2026-09-07#^blk002..^blk005]]"]),
        (
            "blk002",
            &[
                "![[2026-09-07#^blk001]]",
                "![[2026-09-07#^blk003..^blk005]]",
            ],
        ),
        (
            "blk003",
            &[
                "![[2026-09-07#^blk001..^blk002]]",
                "![[2026-09-07#^blk004..^blk005]]",
            ],
        ),
        (
            "blk004",
            &[
                "![[2026-09-07#^blk001..^blk003]]",
                "![[2026-09-07#^blk005]]",
            ],
        ),
        ("blk005", &["![[2026-09-07#^blk001..^blk004]]"]),
    ];
    for (block, expected) in cases {
        let (mut w, _) = world_with_day2(TOPIC_BODY);
        add(
            &mut w,
            DAY2,
            &["blk001", "blk002", "blk003", "blk004", "blk005"],
        );

        remove_block(&mut w, DAY2, block);

        let b = body(&w);
        assert_eq!(section(&b, DAY2), expected, "removing {block}:\n{b}");
        assert_eq!(heading_count(&b, DAY2), 1, "removing {block}:\n{b}");
    }
}

#[test]
fn remove_excerpt_block_at_either_end_of_a_range_shrinks_it() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    remove_block(&mut w, DAY, "b7k2m9");
    assert_eq!(section(&body(&w), DAY), [T_C3_F6], "first block removed");

    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    remove_block(&mut w, DAY, "f6g7h8");
    assert_eq!(section(&body(&w), DAY), [T_B7_C3], "last block removed");
}

#[test]
fn remove_excerpt_block_from_a_two_block_range_leaves_a_single_block_token() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);
    remove_block(&mut w, DAY, "b7k2m9");
    assert_eq!(section(&body(&w), DAY), [T_C3], "first of two removed");

    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);
    remove_block(&mut w, DAY, "c3d4e5");
    assert_eq!(section(&body(&w), DAY), [T_B7], "second of two removed");
}

#[test]
fn remove_excerpt_block_keeps_every_byte_around_the_split_token() {
    let head = "Intro.\n\n## 2026-09-07\n\nBefore.\n\n";
    let tail = "\n\nAfter.\n\n## Later\n\nKeep.\n";
    let (mut w, _) = world_with_day2(&format!("{head}![[2026-09-07#^blk001..^blk003]]{tail}"));

    remove_block(&mut w, DAY2, "blk002");

    assert_eq!(
        body(&w),
        format!("{head}![[2026-09-07#^blk001]]\n\n![[2026-09-07#^blk003]]{tail}")
    );
}

/// A split removes no token, so an unrelated empty `## <date>` heading of the
/// body stays; only a token with nothing left triggers the heading cleanup.
#[test]
fn remove_excerpt_block_keeps_an_unrelated_empty_date_heading_when_a_range_is_split() {
    let head = "## 2026-09-07\n\n## Notes\n\nText.\n\n## 2026-09-07\n\n";
    let (mut w, _) = world_with_day2(&format!("{head}![[2026-09-07#^blk001..^blk003]]\n"));

    remove_block(&mut w, DAY2, "blk002");

    assert_eq!(
        body(&w),
        format!("{head}![[2026-09-07#^blk001]]\n\n![[2026-09-07#^blk003]]\n")
    );
}

#[test]
fn remove_excerpt_block_splits_an_inline_token_in_place() {
    let (mut w, _) = world_with_day2("See ![[2026-09-07#^blk001..^blk003]] here.\n");

    remove_block(&mut w, DAY2, "blk002");

    assert_eq!(
        body(&w),
        "See ![[2026-09-07#^blk001]]\n\n![[2026-09-07#^blk003]] here.\n"
    );
}

#[test]
fn remove_excerpt_block_keeps_the_other_tokens_of_the_section_in_order() {
    let (mut w, _) = world_with_day2(&date_section(
        DAY2,
        &[
            "![[2026-09-07#^blk001..^blk003]]",
            "![[2026-09-07#^blk005]]",
        ],
    ));

    remove_block(&mut w, DAY2, "blk002");

    assert_eq!(
        section(&body(&w), DAY2),
        [
            "![[2026-09-07#^blk001]]",
            "![[2026-09-07#^blk003]]",
            "![[2026-09-07#^blk005]]",
        ]
    );
}

#[test]
fn remove_excerpt_block_leaves_tokens_of_other_dates_alone() {
    let other_date = "![[2026-09-07#^c3d4e5]]";
    let topic_body = format!(
        "{}\n{}",
        date_section(DAY, &[T_B7_F6]),
        date_section(DAY2, &[other_date])
    );
    let mut w = world_with_topic_body(&topic_body);

    remove_block(&mut w, DAY, "c3d4e5");

    let b = body(&w);
    assert_eq!(section(&b, DAY), [T_B7, T_F6], "{b}");
    assert_eq!(section(&b, DAY2), [other_date], "{b}");
}

// ---------------------------------------------------------------------------
// remove_excerpt_block: coverage (lead decisions 3, 4)
// ---------------------------------------------------------------------------

#[test]
fn remove_excerpt_block_rewrites_every_token_of_the_date_that_covers_the_block() {
    let topic_body = date_section(DAY, &[T_B7_C3, T_C3, T_C3_F6]);
    let mut w = world_with_topic_body(&topic_body);

    remove_block(&mut w, DAY, "c3d4e5");

    assert_eq!(body(&w), date_section(DAY, &[T_B7, T_F6]));
}

#[test]
fn remove_excerpt_block_removes_every_copy_of_a_single_block_token() {
    let mut w = world_with_topic_body(&format!(
        "{TOPIC_BODY}\n{}",
        date_section(DAY, &[T_C3, T_C3])
    ));

    remove_block(&mut w, DAY, "c3d4e5");

    assert_eq!(body(&w), TOPIC_BODY);
}

#[test]
fn remove_excerpt_block_normalizes_reversed_endpoints() {
    let reversed = "![[2026-09-07#^blk003..^blk001]]";
    let cases: [(&str, &[&str]); 3] = [
        ("blk001", &["![[2026-09-07#^blk002..^blk003]]"]),
        (
            "blk002",
            &["![[2026-09-07#^blk001]]", "![[2026-09-07#^blk003]]"],
        ),
        ("blk003", &["![[2026-09-07#^blk001..^blk002]]"]),
    ];
    for (block, expected) in cases {
        let (mut w, _) = world_with_day2(&date_section(DAY2, &[reversed]));

        remove_block(&mut w, DAY2, block);

        assert_eq!(section(&body(&w), DAY2), expected, "removing {block}");
    }
}

#[test]
fn remove_excerpt_block_finds_neighbours_across_a_gap_in_block_ords() {
    let cases: [(&str, &[&str]); 2] = [
        (
            "blk003",
            &[
                "![[2026-09-07#^blk001..^blk002]]",
                "![[2026-09-07#^blk004..^blk005]]",
            ],
        ),
        (
            "blk004",
            &[
                "![[2026-09-07#^blk001..^blk003]]",
                "![[2026-09-07#^blk005]]",
            ],
        ),
    ];
    for (block, expected) in cases {
        let (mut w, day2) =
            world_with_day2(&date_section(DAY2, &["![[2026-09-07#^blk001..^blk005]]"]));
        w.vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET ord = ord + 10 WHERE note_id = ? AND ord >= 3",
                [day2.as_str()],
            )
            .unwrap();

        remove_block(&mut w, DAY2, block);

        assert_eq!(section(&body(&w), DAY2), expected, "removing {block}");
    }
}

#[test]
fn remove_excerpt_block_covers_a_block_added_inside_a_range_later() {
    let (mut w, day2) = world_with_day2(&date_section(DAY2, &["![[2026-09-07#^blk001..^blk002]]"]));
    person_replace(&mut w.vault, &day2, "One.\n\n", "One.\n\nInserted.\n\n");
    let inserted = block_id_of(&w.vault, &day2, "Inserted.");

    remove_block(&mut w, DAY2, &inserted);

    assert_eq!(
        section(&body(&w), DAY2),
        ["![[2026-09-07#^blk001]]", "![[2026-09-07#^blk002]]"]
    );
}

#[test]
fn remove_excerpt_block_names_a_later_block_as_the_new_endpoint() {
    let (mut w, day2) = world_with_day2(&date_section(DAY2, &["![[2026-09-07#^blk001..^blk003]]"]));
    person_replace(&mut w.vault, &day2, "Two.\n\n", "Inserted.\n\nTwo.\n\n");
    let inserted = block_id_of(&w.vault, &day2, "Inserted.");

    remove_block(&mut w, DAY2, "blk002");

    assert_eq!(
        section(&body(&w), DAY2),
        [
            format!("![[2026-09-07#^blk001..^{inserted}]]"),
            "![[2026-09-07#^blk003]]".to_string()
        ]
    );
}

// ---------------------------------------------------------------------------
// remove_excerpt_block: heading and chip
// ---------------------------------------------------------------------------

#[test]
fn remove_excerpt_block_of_the_last_single_token_removes_the_heading_and_the_excerpt_chip() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
    let person_before = person_text(&w.vault, &w.day);
    let cv = content_version(&w.vault, &w.day);

    remove_block(&mut w, DAY, "b7k2m9");

    assert_eq!(body(&w), TOPIC_BODY, "token and heading gone");
    assert_eq!(chip_rows(&w.vault, &w.day), []);
    assert_eq!(footer_titles(&w.vault, &w.day), Vec::<String>::new());
    assert_eq!(person_text(&w.vault, &w.day), person_before);
    assert_eq!(content_version(&w.vault, &w.day), cv);
}

#[test]
fn remove_excerpt_block_of_the_last_single_token_keeps_a_person_chip() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    footer::set_chip(&mut w.vault, &w.day, &w.topic, ChipOrigin::Person, None).unwrap();

    remove_block(&mut w, DAY, "b7k2m9");

    assert_eq!(body(&w), TOPIC_BODY, "token and heading gone");
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "person")]);
    assert_eq!(footer_titles(&w.vault, &w.day), [TOPIC_TITLE]);
}

#[test]
fn remove_excerpt_block_keeps_the_heading_while_person_text_remains_under_it() {
    let mut w = world_with_topic_body(
        "Intro.\n\n## 2026-09-05\n\nWhy this matters.\n\n![[2026-09-05#^b7k2m9]]\n",
    );
    footer::set_chip(&mut w.vault, &w.day, &w.topic, ChipOrigin::Excerpt, None).unwrap();

    remove_block(&mut w, DAY, "b7k2m9");

    assert_eq!(body(&w), "Intro.\n\n## 2026-09-05\n\nWhy this matters.\n");
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [],
        "no token of the day remains"
    );
}

#[test]
fn remove_excerpt_block_keeps_the_excerpt_chip_while_a_token_of_the_day_remains() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);
    remove_block(&mut w, DAY, "b7k2m9");
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);

    // A remaining token counts even when it no longer resolves: the same rule
    // as remove_excerpt.
    let mut w = world_with_topic_body(&date_section(DAY, &[T_B7, "![[2026-09-05#^zzzzzz]]"]));
    footer::set_chip(&mut w.vault, &w.day, &w.topic, ChipOrigin::Excerpt, None).unwrap();
    remove_block(&mut w, DAY, "b7k2m9");
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
    assert_eq!(tokens(&body(&w)), ["![[2026-09-05#^zzzzzz]]"]);
}

#[test]
fn remove_excerpt_block_ignores_excerpts_from_other_days_when_removing_the_chip() {
    let (mut w, day2) = world_with_day2(TOPIC_BODY);
    add(&mut w, DAY, &["b7k2m9"]);
    add(&mut w, DAY2, &["blk001"]);

    remove_block(&mut w, DAY, "b7k2m9");

    assert_eq!(chip_rows(&w.vault, &w.day), []);
    assert_eq!(chip_rows(&w.vault, &day2), [chip(&w.topic, "excerpt")]);
    assert_eq!(section(&body(&w), DAY2), ["![[2026-09-07#^blk001]]"]);
}

#[test]
fn remove_excerpt_block_leaves_other_topics_chips_alone() {
    let mut w = world();
    let other = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["b7k2m9"]);
    add_excerpt(
        &mut w.vault,
        &other,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        None,
    )
    .unwrap();

    remove_block(&mut w, DAY, "b7k2m9");

    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&other, "excerpt")]);
    assert_eq!(tokens(&stored(&w.vault, &other).content_md), [T_B7]);
}

// ---------------------------------------------------------------------------
// remove_excerpt_block: errors write nothing (lead decision 2)
// ---------------------------------------------------------------------------

#[test]
fn remove_excerpt_block_no_token_of_that_date_covers_fails_with_not_found_and_writes_nothing() {
    let topic_bodies = [
        // Another block of the day is held, this one is not.
        date_section(DAY, &[T_B7]),
        // The topic holds nothing at all.
        TOPIC_BODY.to_string(),
        // The same id under another date.
        date_section(DAY2, &["![[2026-09-07#^c3d4e5]]"]),
        // A range with an endpoint that no longer resolves covers nothing.
        date_section(DAY, &["![[2026-09-05#^zzzzzz..^c3d4e5]]"]),
        date_section(DAY, &["![[2026-09-05#^c3d4e5..^zzzzzz]]"]),
    ];
    for topic_body in topic_bodies {
        let mut w = world_with_topic_body(&topic_body);
        let topic = w.topic.clone();
        let before = snapshot(&w.vault);

        let e = remove_block_err(&mut w, &topic, DAY, "c3d4e5");

        assert!(matches!(e, MemexError::NotFound(_)), "{topic_body}: {e:?}");
        assert_eq!(code(&e), "not_found", "{topic_body}");
        assert_eq!(snapshot(&w.vault), before, "{topic_body}");
    }
}

#[test]
fn remove_excerpt_block_with_an_id_that_is_not_a_block_of_the_day_fails_with_block_not_found() {
    // A token still names the deleted block, so the id check comes first.
    let mut w = world_with_topic_body(&date_section(DAY, &[T_B7, "![[2026-09-05#^zzzzzz]]"]));
    create_day(&mut w.vault, DAY2, DAY2_BODY, &DAY2_BLOCKS);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    for block in ["zzzzzz", "blk001"] {
        let e = remove_block_err(&mut w, &topic, DAY, block);
        assert!(matches!(e, MemexError::BlockNotFound(_)), "{block}: {e:?}");
        assert_eq!(code(&e), "block_not_found", "{block}");
    }

    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn remove_excerpt_block_rule_errors_carry_their_codes_and_write_nothing() {
    let mut w = world_with_topic_body(&date_section("2026-09-06", &["![[2026-09-06#^b7k2m9]]"]));
    let plain = create(
        &mut w.vault,
        "Loose note",
        "![[2026-09-05#^b7k2m9]]\n",
        None,
    )
    .id;
    let topic = w.topic.clone();
    let day = w.day.clone();
    let before = snapshot(&w.vault);

    assert_role_rule(&remove_block_err(&mut w, &plain, DAY, "b7k2m9"));
    assert_role_rule(&remove_block_err(&mut w, &day, DAY, "b7k2m9"));
    let e = remove_block_err(&mut w, &topic, "2026-9-5", "b7k2m9");
    assert!(matches!(e, MemexError::InvalidDate(_)), "{e:?}");
    assert_eq!(
        code(&remove_block_err(&mut w, &NoteId::new(), DAY, "b7k2m9")),
        "not_found",
        "unknown topic"
    );
    let e = remove_block_err(&mut w, &topic, "2026-09-06", "b7k2m9");
    assert!(matches!(e, MemexError::NotFound(_)), "no daily note: {e:?}");

    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn remove_excerpt_block_checks_the_date_then_the_topic_then_the_day_then_the_block() {
    let mut w = world();
    let plain = create(&mut w.vault, "Loose note", "Text.\n", None).id;
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    let e = remove_block_err(&mut w, &plain, "2026-9-5", "zzzzzz");
    assert!(matches!(e, MemexError::InvalidDate(_)), "date first: {e:?}");
    let e = remove_block_err(&mut w, &plain, "2026-09-06", "zzzzzz");
    assert!(matches!(e, MemexError::RoleRule(_)), "then the role: {e:?}");
    let e = remove_block_err(&mut w, &topic, "2026-09-06", "zzzzzz");
    assert!(matches!(e, MemexError::NotFound(_)), "then the day: {e:?}");
    let e = remove_block_err(&mut w, &NoteId::new(), DAY, "zzzzzz");
    assert!(
        matches!(e, MemexError::NotFound(_)),
        "topic before block: {e:?}"
    );

    assert_eq!(snapshot(&w.vault), before);
}

// ---------------------------------------------------------------------------
// remove_excerpt_block: races, indexing, callers
// ---------------------------------------------------------------------------

#[test]
fn remove_excerpt_block_retries_when_a_person_save_lands_between_read_and_write() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    let topic = w.topic.clone();
    let v0 = stored(&w.vault, &topic).version;
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        if calls == 1 {
            person_append(v, &topic, "Later note.\n");
        }
    };

    let returned = remove_excerpt_block_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        "c3d4e5",
        Caller::Agent,
        None,
        &mut hook,
    )
    .unwrap_or_else(|e| panic!("remove_excerpt_block after a race: {e}"));

    assert_eq!(calls, 2, "one retry after the conflicting save");
    let after = stored(&w.vault, &w.topic);
    assert_eq!(returned.version, after.version);
    assert_eq!(after.version, v0 + 2);
    assert_eq!(tokens(&after.content_md), [T_B7, T_F6]);
    assert!(
        after.content_md.contains("Later note."),
        "{}",
        after.content_md
    );
}

#[test]
fn remove_excerpt_block_recomputes_the_split_from_the_body_a_retry_reads() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    let topic = w.topic.clone();
    let mut calls = 0;
    // The race moves the token's bytes and narrows it.
    let mut hook = |v: &mut Vault| {
        calls += 1;
        if calls == 1 {
            person_replace(
                v,
                &topic,
                T_B7_F6,
                &format!("A person thought.\n\n{T_B7_C3}"),
            );
        }
    };

    remove_excerpt_block_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        "c3d4e5",
        Caller::Agent,
        None,
        &mut hook,
    )
    .unwrap_or_else(|e| panic!("remove_excerpt_block after a race: {e}"));

    assert_eq!(
        section(&body(&w), DAY),
        ["A person thought.", T_B7],
        "f6g7h8 was out of the token by then, so it stays out"
    );
}

#[test]
fn remove_excerpt_block_fails_with_not_found_when_a_race_drops_the_token() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let mut hook = |v: &mut Vault| {
        person_replace(v, &topic, T_B7, "Written out by hand.");
    };

    let e = remove_excerpt_block_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        "b7k2m9",
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("the token is gone on the retry");

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert!(body(&w).contains("Written out by hand."), "{}", body(&w));
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [chip(&w.topic, "excerpt")],
        "a failed call leaves the chip"
    );
}

#[test]
fn remove_excerpt_block_gives_up_after_exactly_five_attempts_and_keeps_the_excerpt() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let topic = w.topic.clone();
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        person_append(v, &topic, &format!("Edit {calls}.\n"));
    };

    let e = remove_excerpt_block_with_hook(
        &mut w.vault,
        &w.topic,
        DAY,
        "b7k2m9",
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("every attempt raced");

    assert_eq!(code(&e), "version_conflict");
    assert_eq!(calls, 5);
    assert_eq!(tokens(&body(&w)), [T_B7]);
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&w.topic, "excerpt")]);
}

#[test]
fn remove_excerpt_block_reindexes_the_topic_links() {
    let mut w = world();
    let day_id = Some(w.day.to_string());
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    assert_eq!(from_day_links(&w.vault, &w.topic), vec![day_id.clone()]);

    remove_block(&mut w, DAY, "c3d4e5");
    assert_eq!(
        from_day_links(&w.vault, &w.topic),
        [day_id.clone(), day_id.clone()],
        "two tokens, two from-day links"
    );

    remove_block(&mut w, DAY, "b7k2m9");
    assert_eq!(from_day_links(&w.vault, &w.topic), [day_id]);
}

#[test]
fn remove_excerpt_block_works_on_the_person_path() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9", "c3d4e5"]);

    remove_excerpt_block(&mut w.vault, &w.topic, DAY, "b7k2m9", Caller::Person, None)
        .unwrap_or_else(|e| panic!("person remove_excerpt_block: {e}"));

    assert_eq!(tokens(&body(&w)), [T_C3]);
}

// ---------------------------------------------------------------------------
// move_block
// ---------------------------------------------------------------------------

#[test]
fn move_block_leaves_the_block_held_by_the_target_and_not_the_source_with_both_versions_bumped_once(
) {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let source_before = stored(&w.vault, &source);
    let target_before = stored(&w.vault, &target);

    let moved = move_ok(&mut w, "f6g7h8", &source, &target);

    let source_after = stored(&w.vault, &source);
    let target_after = stored(&w.vault, &target);
    assert_eq!(section(&target_after.content_md, DAY), [T_F6]);
    assert_eq!(tokens(&source_after.content_md), Vec::<String>::new());
    assert_eq!(heading_count(&source_after.content_md, DAY), 0);
    assert_eq!(source_after.version, source_before.version + 1);
    assert_eq!(target_after.version, target_before.version + 1);
    assert_eq!(moved.from.id, source);
    assert_eq!(moved.from.version, source_after.version);
    assert_eq!(moved.from.content_md, source_after.content_md);
    assert_eq!(moved.to.id, target);
    assert_eq!(moved.to.version, target_after.version);
    assert_eq!(moved.to.content_md, target_after.content_md);
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [chip(&target, "excerpt")],
        "the chip follows the excerpt"
    );
}

#[test]
fn move_block_out_of_a_range_splits_the_source_and_keeps_its_chip() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);

    move_ok(&mut w, "c3d4e5", &source, &target);

    assert_eq!(section(&body(&w), DAY), [T_B7, T_F6]);
    assert_eq!(tokens(&stored(&w.vault, &target).content_md), [T_C3]);
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [chip(&source, "excerpt"), chip(&target, "excerpt")]
    );
}

#[test]
fn move_block_adds_to_the_target_before_it_removes_from_the_source() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let mut seen: Vec<(Vec<String>, Vec<String>)> = Vec::new();
    let mut hook = |v: &mut Vault| {
        seen.push((
            tokens(&get_note(v, &source).unwrap().content_md),
            tokens(&get_note(v, &target).unwrap().content_md),
        ));
    };

    move_block_with_hook(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        None,
        &mut hook,
    )
    .unwrap_or_else(|e| panic!("move_block: {e}"));

    assert_eq!(
        seen,
        [(vec![T_F6.to_string()], vec![T_F6.to_string()])],
        "the hook runs once, in the write to the source, with the target already filed"
    );
}

#[test]
fn move_block_with_a_failing_remove_leaves_the_block_in_both_and_returns_the_error() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        person_append(v, &source, &format!("Edit {calls}.\n"));
    };

    let e = move_block_with_hook(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("every write to the source raced");

    assert_eq!(code(&e), "version_conflict", "{e:?}");
    assert_eq!(calls, 5);
    assert_eq!(tokens(&body(&w)), [T_F6], "still in the source");
    assert_eq!(
        tokens(&stored(&w.vault, &target).content_md),
        [T_F6],
        "and in the target"
    );
    assert_eq!(
        chip_rows(&w.vault, &w.day),
        [chip(&source, "excerpt"), chip(&target, "excerpt")]
    );
}

#[test]
fn move_block_with_the_source_deleted_during_the_remove_returns_not_found_and_keeps_the_target() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let mut hook = |v: &mut Vault| {
        let version = get_note(v, &source).unwrap().version;
        delete_note_checked(v, &source, version, None).unwrap();
    };

    let e = move_block_with_hook(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("the source is gone");

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(tokens(&stored(&w.vault, &target).content_md), [T_F6]);
}

#[test]
fn move_block_can_be_retried_after_a_failed_remove() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        person_append(v, &source, &format!("Edit {calls}.\n"));
    };
    move_block_with_hook(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        None,
        &mut hook,
    )
    .expect_err("every write to the source raced");
    let target_version = stored(&w.vault, &target).version;

    let moved = move_ok(&mut w, "f6g7h8", &source, &target);

    assert_eq!(tokens(&moved.from.content_md), Vec::<String>::new());
    assert_eq!(tokens(&moved.to.content_md), [T_F6]);
    assert_eq!(moved.to.version, target_version, "already there");
}

#[test]
fn move_block_retries_when_a_person_save_races_the_remove() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let target_v0 = stored(&w.vault, &target).version;
    let mut calls = 0;
    let mut hook = |v: &mut Vault| {
        calls += 1;
        if calls == 1 {
            person_append(v, &source, "Later note.\n");
        }
    };

    let moved = move_block_with_hook(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        None,
        &mut hook,
    )
    .unwrap_or_else(|e| panic!("move_block after a race: {e}"));

    assert_eq!(calls, 2);
    assert_eq!(tokens(&moved.from.content_md), Vec::<String>::new());
    assert!(moved.from.content_md.contains("Later note."));
    assert_eq!(
        moved.to.version,
        target_v0 + 1,
        "the target is written once"
    );
}

#[test]
fn move_block_with_equal_source_and_target_fails_with_invalid_input_and_writes_nothing() {
    let mut w = world();
    add(&mut w, DAY, &["f6g7h8"]);
    let topic = w.topic.clone();
    let before = snapshot(&w.vault);

    assert_invalid_input(&move_err(&mut w, DAY, "f6g7h8", &topic, &topic));
    // The equal check comes first: nothing else about the call matters.
    assert_invalid_input(&move_err(&mut w, "2026-9-5", "zzzzzz", &topic, &topic));
    let unknown = NoteId::new();
    assert_invalid_input(&move_err(&mut w, DAY, "f6g7h8", &unknown, &unknown));

    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn move_block_to_a_target_already_holding_the_block_writes_nothing_to_it_and_still_removes_from_the_source(
) {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    add_excerpt(
        &mut w.vault,
        &target,
        DAY,
        &ids(&["f6g7h8"]),
        Caller::Agent,
        None,
    )
    .unwrap();
    let source_before = stored(&w.vault, &source);
    let target_before = stored(&w.vault, &target);

    let moved = move_ok(&mut w, "f6g7h8", &source, &target);

    let target_after = stored(&w.vault, &target);
    assert_eq!(target_after.version, target_before.version, "not written");
    assert_eq!(target_after.content_md, target_before.content_md);
    assert_eq!(moved.to.version, target_before.version);
    assert_eq!(moved.to.content_md, target_before.content_md);
    let source_after = stored(&w.vault, &source);
    assert_eq!(tokens(&source_after.content_md), Vec::<String>::new());
    assert_eq!(source_after.version, source_before.version + 1);
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&target, "excerpt")]);
}

#[test]
fn move_block_to_a_target_holding_the_block_inside_a_range_writes_nothing_to_it() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["c3d4e5"]);
    add_excerpt(
        &mut w.vault,
        &target,
        DAY,
        &ids(&["b7k2m9", "c3d4e5", "f6g7h8"]),
        Caller::Agent,
        None,
    )
    .unwrap();
    let target_version = stored(&w.vault, &target).version;

    let moved = move_ok(&mut w, "c3d4e5", &source, &target);

    assert_eq!(moved.to.version, target_version);
    assert_eq!(tokens(&moved.to.content_md), [T_B7_F6]);
    assert_eq!(tokens(&moved.from.content_md), Vec::<String>::new());
}

#[test]
fn move_block_from_a_source_not_holding_the_block_fails_with_not_found_and_leaves_the_target_alone()
{
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["b7k2m9"]);
    let before = snapshot(&w.vault);

    let e = move_err(&mut w, DAY, "f6g7h8", &source, &target);

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(code(&e), "not_found");
    assert_eq!(snapshot(&w.vault), before, "no new excerpt in the target");
}

#[test]
fn move_block_with_a_failing_source_or_day_writes_nothing() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    let plain = create(&mut w.vault, "Loose note", T_F6, None).id;
    add(&mut w, DAY, &["f6g7h8"]);
    let before = snapshot(&w.vault);

    assert_role_rule(&move_err(&mut w, DAY, "f6g7h8", &plain, &target));
    let e = move_err(&mut w, DAY, "f6g7h8", &NoteId::new(), &target);
    assert_eq!(code(&e), "not_found", "unknown source: {e:?}");
    let e = move_err(&mut w, "2026-9-5", "f6g7h8", &source, &target);
    assert!(matches!(e, MemexError::InvalidDate(_)), "{e:?}");
    let e = move_err(&mut w, "2026-09-06", "f6g7h8", &source, &target);
    assert!(matches!(e, MemexError::NotFound(_)), "no daily note: {e:?}");
    let e = move_err(&mut w, DAY, "zzzzzz", &source, &target);
    assert!(matches!(e, MemexError::BlockNotFound(_)), "{e:?}");

    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn move_block_with_a_failing_target_writes_nothing() {
    let mut w = world();
    let source = w.topic.clone();
    let plain = create(&mut w.vault, "Loose note", "Text.\n", None).id;
    add(&mut w, DAY, &["f6g7h8"]);
    let before = snapshot(&w.vault);

    assert_role_rule(&move_err(&mut w, DAY, "f6g7h8", &source, &plain));
    let e = move_err(&mut w, DAY, "f6g7h8", &source, &NoteId::new());
    assert_eq!(code(&e), "not_found", "unknown target: {e:?}");

    assert_eq!(snapshot(&w.vault), before);
    assert_eq!(tokens(&body(&w)), [T_F6], "the source keeps the block");
}

#[test]
fn move_block_checks_the_source_before_the_target() {
    let mut w = world();
    let source = w.topic.clone();
    let plain = create(&mut w.vault, "Loose note", "Text.\n", None).id;
    add(&mut w, DAY, &["b7k2m9"]);
    let before = snapshot(&w.vault);

    // The source does not hold f6g7h8, and the target is not a topic note.
    let e = move_err(&mut w, DAY, "f6g7h8", &source, &plain);

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(snapshot(&w.vault), before);
}

#[test]
fn move_block_reindexes_both_topics() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    let day_id = Some(w.day.to_string());
    add(&mut w, DAY, &["b7k2m9", "f6g7h8"]);

    move_ok(&mut w, "f6g7h8", &source, &target);

    assert_eq!(from_day_links(&w.vault, &source), vec![day_id.clone()]);
    assert_eq!(from_day_links(&w.vault, &target), [day_id]);
}

#[test]
fn move_block_works_on_the_person_path() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);

    let moved = move_block(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Person,
        None,
    )
    .unwrap_or_else(|e| panic!("person move_block: {e}"));

    assert_eq!(tokens(&moved.to.content_md), [T_F6]);
    assert_eq!(tokens(&moved.from.content_md), Vec::<String>::new());
}

#[test]
fn reviewed_day_stays_reviewed_after_remove_excerpt_block_and_move_block() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["b7k2m9", "c3d4e5", "f6g7h8"]);
    mark_reviewed(&w.vault, &w.day);
    let cv = content_version(&w.vault, &w.day);
    let person_before = person_text(&w.vault, &w.day);

    remove_block(&mut w, DAY, "b7k2m9");
    move_ok(&mut w, "c3d4e5", &source, &target);

    assert_eq!(review_state(&w.vault, &w.day), ReviewState::Reviewed);
    assert_eq!(content_version(&w.vault, &w.day), cv);
    assert_eq!(person_text(&w.vault, &w.day), person_before);
    assert_eq!(
        blocks_of(&w.vault, &w.day)
            .into_iter()
            .map(|(id, _)| id)
            .collect::<Vec<_>>(),
        ["b7k2m9", "c3d4e5", "f6g7h8"],
        "the day keeps its block ids"
    );
}

// ---------------------------------------------------------------------------
// WI #248: the embedder reaches every write, and what a failure after the
// topic's save does to the call
// ---------------------------------------------------------------------------

/// A [`FakeEmbedder`] that fails the calls numbered in `failing` (1-based) with
/// `EmbedderInfer` and counts every call. Each reindex of a note with chunks
/// is one call.
struct Wi248FlakyEmbedder {
    inner: FakeEmbedder,
    failing: Vec<usize>,
    calls: AtomicUsize,
}

impl Wi248FlakyEmbedder {
    fn failing_calls(failing: &[usize]) -> Self {
        Self {
            inner: FakeEmbedder::new(8),
            failing: failing.to_vec(),
            calls: AtomicUsize::new(0),
        }
    }

    fn working() -> Self {
        Self::failing_calls(&[])
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl Embedder for Wi248FlakyEmbedder {
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

/// The `embed_model_version` of every chunk row of the note; empty when it
/// has no chunks.
fn chunk_versions(vault: &Vault, id: &NoteId) -> Vec<Option<String>> {
    vault
        .connection_ref()
        .prepare("SELECT embed_model_version FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap()
        .query_map([id.as_str()], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Asserts the note has chunks and every one carries the fake's version.
fn assert_embedded(vault: &Vault, id: &NoteId, what: &str) {
    let versions = chunk_versions(vault, id);
    assert!(!versions.is_empty(), "{what}: has chunks");
    assert!(
        versions.iter().all(|v| v.as_deref() == Some("fake-v1")),
        "{what}: reindexed with the embedder, got {versions:?}"
    );
}

/// Asserts the note has chunks and none was embedded.
fn assert_not_embedded(vault: &Vault, id: &NoteId, what: &str) {
    let versions = chunk_versions(vault, id);
    assert!(!versions.is_empty(), "{what}: has chunks");
    assert!(
        versions.iter().all(Option::is_none),
        "{what}: not reindexed with the embedder, got {versions:?}"
    );
}

#[test]
fn remove_excerpt_block_reindexes_the_topic_and_the_day_note_with_the_embedder() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    assert_not_embedded(&w.vault, &w.topic, "precondition: topic");
    assert_not_embedded(&w.vault, &w.day, "precondition: day");
    let embedder = Wi248FlakyEmbedder::working();

    remove_excerpt_block(
        &mut w.vault,
        &w.topic,
        DAY,
        "b7k2m9",
        Caller::Agent,
        Some(&embedder),
    )
    .unwrap();

    assert_eq!(chip_rows(&w.vault, &w.day), [], "the chip went with it");
    assert_embedded(&w.vault, &w.topic, "topic note");
    assert_embedded(&w.vault, &w.day, "day note after the chip removal");
    assert_eq!(embedder.calls(), 2, "one reindex per written note");
}

#[test]
fn move_block_reindexes_the_source_the_target_and_the_day_note_with_the_embedder() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    assert_not_embedded(&w.vault, &source, "precondition: source");
    assert_not_embedded(&w.vault, &target, "precondition: target");
    let embedder = Wi248FlakyEmbedder::working();

    move_block(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        Some(&embedder),
    )
    .unwrap();

    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&target, "excerpt")]);
    assert_embedded(&w.vault, &target, "target note");
    assert_embedded(&w.vault, &source, "source note");
    assert_embedded(&w.vault, &w.day, "day note after the chip removal");
    assert_eq!(
        embedder.calls(),
        4,
        "target, day (chip added), source, day (chip removed)"
    );
}

#[test]
fn remove_excerpt_block_succeeds_when_the_reindex_after_the_save_fails() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let before = stored(&w.vault, &w.topic);
    let embedder = Wi248FlakyEmbedder::failing_calls(&[1]);

    let saved = remove_excerpt_block(
        &mut w.vault,
        &w.topic,
        DAY,
        "b7k2m9",
        Caller::Agent,
        Some(&embedder),
    )
    .expect("the save committed, so the call succeeds");

    let now = stored(&w.vault, &w.topic);
    assert_eq!(now.content_md, TOPIC_BODY);
    assert_eq!(now.version, before.version + 1);
    assert_eq!(saved.version, now.version);
    assert_eq!(saved.content_md, now.content_md);
    assert_eq!(chip_rows(&w.vault, &w.day), [], "the chip step still ran");
    assert_eq!(embedder.calls(), 2, "the day note was reindexed after it");
}

#[test]
fn remove_excerpt_block_succeeds_when_the_footer_chip_removal_fails() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let before = stored(&w.vault, &w.topic);
    let embedder = Wi248FlakyEmbedder::failing_calls(&[2]);

    let saved = remove_excerpt_block(
        &mut w.vault,
        &w.topic,
        DAY,
        "b7k2m9",
        Caller::Agent,
        Some(&embedder),
    )
    .expect("the save committed, so the call succeeds");

    let now = stored(&w.vault, &w.topic);
    assert_eq!(now.content_md, TOPIC_BODY);
    assert_eq!(now.version, before.version + 1);
    assert_eq!(saved.version, now.version);
    assert_eq!(embedder.calls(), 2, "the chip removal reached the day note");
    assert_embedded(&w.vault, &w.topic, "topic note");
}

#[test]
fn remove_excerpt_block_that_fails_before_the_save_still_returns_its_error() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let before = stored(&w.vault, &w.topic);
    let embedder = Wi248FlakyEmbedder::working();

    let e = remove_excerpt_block(
        &mut w.vault,
        &w.topic,
        DAY,
        "c3d4e5",
        Caller::Agent,
        Some(&embedder),
    )
    .expect_err("no token covers the block");

    assert!(matches!(e, MemexError::NotFound(_)), "{e:?}");
    assert_eq!(stored(&w.vault, &w.topic).version, before.version);
    assert_eq!(embedder.calls(), 0);
}

#[test]
fn add_excerpt_returns_the_reindex_error_after_its_save_commits() {
    let mut w = world();
    let before = stored(&w.vault, &w.topic);
    let embedder = Wi248FlakyEmbedder::failing_calls(&[1]);

    let e = add_excerpt(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        Some(&embedder),
    )
    .expect_err("the reindex fails");

    assert!(matches!(e, MemexError::EmbedderInfer(_)), "{e:?}");
    let now = stored(&w.vault, &w.topic);
    assert_eq!(now.version, before.version + 1, "the save had committed");
    assert_eq!(tokens(&now.content_md), [T_B7]);
}

#[test]
fn remove_excerpt_returns_the_reindex_error_after_its_save_commits() {
    let mut w = world();
    add(&mut w, DAY, &["b7k2m9"]);
    let before = stored(&w.vault, &w.topic);
    let embedder = Wi248FlakyEmbedder::failing_calls(&[1]);

    let e = remove_excerpt(
        &mut w.vault,
        &w.topic,
        DAY,
        &ids(&["b7k2m9"]),
        Caller::Agent,
        Some(&embedder),
    )
    .expect_err("the reindex fails");

    assert!(matches!(e, MemexError::EmbedderInfer(_)), "{e:?}");
    let now = stored(&w.vault, &w.topic);
    assert_eq!(now.version, before.version + 1, "the save had committed");
    assert_eq!(tokens(&now.content_md), Vec::<String>::new());
}

#[test]
fn move_block_succeeds_when_the_source_reindex_fails_after_its_save() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let source_before = stored(&w.vault, &source);
    let target_before = stored(&w.vault, &target);
    // Calls: 1 target, 2 day (chip added), 3 source, 4 day (chip removed).
    let embedder = Wi248FlakyEmbedder::failing_calls(&[3]);

    let moved = move_block(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        Some(&embedder),
    )
    .expect("the source's save committed, so the block has moved");

    let source_after = stored(&w.vault, &source);
    let target_after = stored(&w.vault, &target);
    assert_eq!(tokens(&source_after.content_md), Vec::<String>::new());
    assert_eq!(tokens(&target_after.content_md), [T_F6]);
    assert_eq!(source_after.version, source_before.version + 1);
    assert_eq!(target_after.version, target_before.version + 1);
    assert_eq!(moved.from.version, source_after.version);
    assert_eq!(moved.to.version, target_after.version);
    assert_eq!(chip_rows(&w.vault, &w.day), [chip(&target, "excerpt")]);
    assert_eq!(embedder.calls(), 4);
}

#[test]
fn move_block_succeeds_when_the_footer_chip_removal_fails_after_the_source_save() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let embedder = Wi248FlakyEmbedder::failing_calls(&[4]);

    let moved = move_block(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        Some(&embedder),
    )
    .expect("the source's save committed, so the block has moved");

    assert_eq!(tokens(&moved.from.content_md), Vec::<String>::new());
    assert_eq!(tokens(&moved.to.content_md), [T_F6]);
    assert_eq!(
        tokens(&stored(&w.vault, &source).content_md),
        Vec::<String>::new()
    );
    assert_eq!(embedder.calls(), 4);
}

#[test]
fn move_block_with_a_failing_target_reindex_returns_the_error_and_can_be_retried() {
    let mut w = world();
    let source = w.topic.clone();
    let target = create_topic(&mut w.vault, "Sleep", "Rest.\n");
    add(&mut w, DAY, &["f6g7h8"]);
    let broken = Wi248FlakyEmbedder::failing_calls(&[1]);

    let e = move_block(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        Some(&broken),
    )
    .expect_err("the add leg's reindex fails");

    assert!(matches!(e, MemexError::EmbedderInfer(_)), "{e:?}");
    assert_eq!(tokens(&body(&w)), [T_F6], "still in the source");
    assert_eq!(
        tokens(&stored(&w.vault, &target).content_md),
        [T_F6],
        "and in the target, whose save had committed"
    );
    let target_version = stored(&w.vault, &target).version;
    let working = Wi248FlakyEmbedder::working();

    let moved = move_block(
        &mut w.vault,
        DAY,
        "f6g7h8",
        &source,
        &target,
        Caller::Agent,
        Some(&working),
    )
    .expect("the retry moves it");

    assert_eq!(tokens(&moved.from.content_md), Vec::<String>::new());
    assert_eq!(moved.to.version, target_version, "already there");
    assert_embedded(&w.vault, &source, "source note after the retry");
}
