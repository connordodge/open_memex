//! WI #11 (R8): the review workflow in core.
//!
//! - `review::list_unreviewed_days` (Req 25): days not `Reviewed`, oldest
//!   first, without days whose person section is empty.
//! - `review::get_daily_note_changes` (Req 26): `blocks::diff` of the current
//!   blocks against the `day_review_blocks` snapshot (D12).
//! - `review::mark_day_reviewed` (Req 21, 22): strict content version check,
//!   change-entry validation before any write, then snapshot, `day_reviews`
//!   and `agent_changes` in one transaction, times from the injected clock
//!   (D14).
//! - `review::note_review_fields` (Req 24): `review` and `latest_change` for
//!   daily notes only.
//!
//! Real SQLite, real schema V5, temp vaults only. Notes are written through
//! the person path (`update_note_as`, `Caller::Person`), as the app does.

use std::cell::Cell;

use memex_core::blocks::{Block, SnapshotBlock};
use memex_core::canvas::Clock;
use memex_core::daily::ReviewState;
use memex_core::error::MemexError;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::review::{self, ChangeEntry, DayReview, UnreviewedDay};
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const T1: i64 = 1_759_500_000_000;
const T2: i64 = 1_759_586_400_000;

/// A clock the test sets by hand (D14).
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

// ---------- setup ----------

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn create(vault: &mut Vault, title: &str, body: &str, frontmatter: Value) -> Note {
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
}

fn create_daily(vault: &mut Vault, date: &str, body: &str) -> Note {
    create(vault, date, body, json!({ "role": "daily" }))
}

fn create_topic(vault: &mut Vault, title: &str) -> Note {
    create(vault, title, "A topic.", json!({ "role": "topic" }))
}

fn person_update(vault: &mut Vault, id: &NoteId, patch: UpdateNote) -> Note {
    let version = get_note(vault, id).unwrap().version;
    update_note_as(
        vault,
        id,
        version,
        patch,
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("update {id}: {e}"))
}

/// A person edit of the whole body (what an app save sends).
fn set_body(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
    person_update(
        vault,
        id,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
    )
}

fn entry(note_id: &NoteId, bullets: &[&str]) -> ChangeEntry {
    ChangeEntry {
        note_id: note_id.to_string(),
        bullets: bullets.iter().map(|b| b.to_string()).collect(),
    }
}

fn daily_entry(daily: &Note) -> ChangeEntry {
    entry(&daily.id, &["Filed 2 blocks into Player Loop"])
}

fn mark(
    vault: &mut Vault,
    date: &str,
    version: i64,
    changes: &[ChangeEntry],
    clock: &FakeClock,
) -> DayReview {
    review::mark_day_reviewed(vault, date, version, changes, clock)
        .unwrap_or_else(|e| panic!("mark_day_reviewed {date} v{version}: {e}"))
}

// ---------- reads ----------

fn content_version(vault: &Vault, id: &NoteId) -> i64 {
    day_review_row(vault, id).0
}

/// `(content_version, reviewed_content_version, reviewed_at)`.
fn day_review_row(vault: &Vault, id: &NoteId) -> (i64, Option<i64>, Option<i64>) {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version, reviewed_content_version, reviewed_at
             FROM day_reviews WHERE note_id = ?",
            [id.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap()
}

/// `(block_id, content_hash, text)` of the current blocks, in `ord` order.
fn current_blocks(vault: &Vault, id: &NoteId) -> Vec<(String, String, String)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT block_id, content_hash, text FROM blocks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    stmt.query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

/// `(block_id, content_hash, text)` of the review snapshot, by block id.
fn snapshot(vault: &Vault, id: &NoteId) -> Vec<(String, String, String)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT block_id, content_hash, text FROM day_review_blocks
             WHERE note_id = ? ORDER BY block_id",
        )
        .unwrap();
    stmt.query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

fn sorted(mut rows: Vec<(String, String, String)>) -> Vec<(String, String, String)> {
    rows.sort();
    rows
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ChangeRow {
    id: String,
    note_id: String,
    day: String,
    created_at: i64,
    bullets: Vec<String>,
}

/// Every `agent_changes` row, oldest first.
fn change_rows(vault: &Vault) -> Vec<ChangeRow> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, note_id, day, created_at, bullets_json FROM agent_changes
             ORDER BY created_at, rowid",
        )
        .unwrap();
    stmt.query_map([], |r| {
        let json: String = r.get(4)?;
        Ok(ChangeRow {
            id: r.get(0)?,
            note_id: r.get(1)?,
            day: r.get(2)?,
            created_at: r.get(3)?,
            bullets: serde_json::from_str(&json).expect("bullets_json is a JSON string array"),
        })
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

/// Everything `mark_day_reviewed` may write, to prove a rejected call wrote nothing.
#[derive(Debug, PartialEq, Eq)]
struct ReviewTables {
    day_review: (i64, Option<i64>, Option<i64>),
    snapshot: Vec<(String, String, String)>,
    changes: Vec<ChangeRow>,
}

fn review_tables(vault: &Vault, id: &NoteId) -> ReviewTables {
    ReviewTables {
        day_review: day_review_row(vault, id),
        snapshot: snapshot(vault, id),
        changes: change_rows(vault),
    }
}

fn block_text(blocks: &[Block]) -> Vec<&str> {
    blocks.iter().map(|b| b.text.as_str()).collect()
}

fn listed(days: &[UnreviewedDay]) -> Vec<&str> {
    days.iter().map(|d| d.date.as_str()).collect()
}

const THREE_BLOCKS: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";

// ======================================================================
// AC 1: one entry per Unreviewed / Changed since review day, oldest first.
// ======================================================================

#[test]
fn list_unreviewed_days_lists_unreviewed_and_changed_days_oldest_first() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    // Created out of date order.
    let d07 = create_daily(&mut vault, "2026-09-07", "Seventh.\n");
    let d05 = create_daily(&mut vault, "2026-09-05", "Fifth.\n\nMore on the fifth.\n");
    let d06 = create_daily(&mut vault, "2026-09-06", "Sixth.\n");
    // Not daily notes: never listed.
    create_topic(&mut vault, "Player Loop");
    create(&mut vault, "2026-09-04", "Role-less, ISO title.", json!({}));

    // 2026-09-06 reviewed at v1, then edited by the person: v2.
    mark(&mut vault, "2026-09-06", 1, &[daily_entry(&d06)], &clock);
    set_body(&mut vault, &d06.id, "Sixth, edited.\n");
    // 2026-09-05 edited once before any review: v2, never reviewed.
    set_body(
        &mut vault,
        &d05.id,
        "Fifth.\n\nMore on the fifth, edited.\n",
    );

    let days = review::list_unreviewed_days(&vault).unwrap();
    assert_eq!(
        days,
        vec![
            UnreviewedDay {
                date: "2026-09-05".into(),
                note_id: d05.id.to_string(),
                state: ReviewState::Unreviewed,
                content_version: 2,
                reviewed_content_version: None,
            },
            UnreviewedDay {
                date: "2026-09-06".into(),
                note_id: d06.id.to_string(),
                state: ReviewState::ChangedSinceReview,
                content_version: 2,
                reviewed_content_version: Some(1),
            },
            UnreviewedDay {
                date: "2026-09-07".into(),
                note_id: d07.id.to_string(),
                state: ReviewState::Unreviewed,
                content_version: 1,
                reviewed_content_version: None,
            },
        ]
    );
}

#[test]
fn list_unreviewed_days_is_empty_for_a_vault_without_daily_notes() {
    let (_dir, mut vault) = fresh_vault();
    create_topic(&mut vault, "Player Loop");
    assert_eq!(review::list_unreviewed_days(&vault).unwrap(), vec![]);
}

#[test]
fn list_unreviewed_days_orders_by_date_across_months_and_years() {
    let (_dir, mut vault) = fresh_vault();
    for date in ["2026-10-01", "2025-12-31", "2026-09-30", "2026-01-02"] {
        create_daily(&mut vault, date, &format!("Text of {date}.\n"));
    }
    let days = review::list_unreviewed_days(&vault).unwrap();
    assert_eq!(
        listed(&days),
        vec!["2025-12-31", "2026-01-02", "2026-09-30", "2026-10-01"]
    );
}

// ======================================================================
// AC 2: empty / whitespace-only person sections and Reviewed days omitted.
// ======================================================================

#[test]
fn list_unreviewed_days_omits_empty_and_whitespace_only_days() {
    let (_dir, mut vault) = fresh_vault();
    create_daily(&mut vault, "2026-09-01", "");
    create_daily(&mut vault, "2026-09-02", "   \n\n\t\n");
    // Text typed then cleared: content_version moved on, person is empty.
    let cleared = create_daily(&mut vault, "2026-09-03", "Gone soon.\n");
    set_body(&mut vault, &cleared.id, "");
    assert!(content_version(&vault, &cleared.id) > 0);
    // An empty person section with footer chips is still empty.
    let topic = create_topic(&mut vault, "Sleep");
    let chips_only = create_daily(&mut vault, "2026-09-04", "");
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, 'person', 0)",
            params![chips_only.id.as_str(), topic.id.as_str()],
        )
        .unwrap();
    set_body(&mut vault, &chips_only.id, "");
    create_daily(&mut vault, "2026-09-05", "Kept.\n");

    let days = review::list_unreviewed_days(&vault).unwrap();
    assert_eq!(listed(&days), vec!["2026-09-05"]);
}

#[test]
fn list_unreviewed_days_omits_reviewed_days() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let d05 = create_daily(&mut vault, "2026-09-05", "Fifth.\n");
    create_daily(&mut vault, "2026-09-06", "Sixth.\n");
    let d07 = create_daily(&mut vault, "2026-09-07", "Seventh.\n");
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&d05)], &clock);
    mark(&mut vault, "2026-09-07", 1, &[daily_entry(&d07)], &clock);

    let days = review::list_unreviewed_days(&vault).unwrap();
    assert_eq!(listed(&days), vec!["2026-09-06"]);
}

// ======================================================================
// AC 3: a person edit above the marker makes a Reviewed day reappear.
// ======================================================================

#[test]
fn reviewed_day_edited_by_the_person_reappears_as_changed_since_review() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&day)], &clock);
    assert_eq!(review::list_unreviewed_days(&vault).unwrap(), vec![]);

    // The person types one more line above the marker; no agent action.
    set_body(
        &mut vault,
        &day.id,
        &format!("{THREE_BLOCKS}\nAnother thought.\n"),
    );

    let days = review::list_unreviewed_days(&vault).unwrap();
    assert_eq!(
        days,
        vec![UnreviewedDay {
            date: "2026-09-05".into(),
            note_id: day.id.to_string(),
            state: ReviewState::ChangedSinceReview,
            content_version: 2,
            reviewed_content_version: Some(1),
        }]
    );
}

#[test]
fn footer_and_frontmatter_only_writes_keep_a_reviewed_day_off_the_list() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&day)], &clock);

    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, 'excerpt', 0)",
            params![day.id.as_str(), topic.id.as_str()],
        )
        .unwrap();
    let current = get_note(&vault, &day.id).unwrap().content_md;
    set_body(&mut vault, &day.id, &current);
    person_update(
        &mut vault,
        &day.id,
        UpdateNote {
            frontmatter: Some(json!({ "role": "daily", "mood": "ok" })),
            ..Default::default()
        },
    );

    assert_eq!(review::list_unreviewed_days(&vault).unwrap(), vec![]);
}

// ======================================================================
// AC 4: never-reviewed day: every block is `added`.
// ======================================================================

#[test]
fn get_daily_note_changes_for_a_never_reviewed_day_returns_every_block_as_added() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    set_body(
        &mut vault,
        &day.id,
        &format!("{THREE_BLOCKS}\n## Level ideas\n"),
    );
    let stored = current_blocks(&vault, &day.id);
    assert_eq!(stored.len(), 4, "precondition: four blocks stored");

    let changes = review::get_daily_note_changes(&vault, "2026-09-05").unwrap();
    assert_eq!(changes.date, "2026-09-05");
    assert_eq!(changes.note_id, day.id.to_string());
    assert_eq!(changes.content_version, 2);
    assert_eq!(changes.content_version, content_version(&vault, &day.id));
    assert_eq!(
        changes
            .added
            .iter()
            .map(|b| (b.block_id.clone(), b.content_hash.clone(), b.text.clone()))
            .collect::<Vec<_>>(),
        stored,
        "every current block, in order"
    );
    assert_eq!(
        block_text(&changes.added),
        vec![
            "Fixed the jump arc.",
            "- tried coyote time",
            "Sleep was bad.",
            "## Level ideas"
        ]
    );
    assert!(changes.added.iter().all(|b| b.source == "person"));
    assert_eq!(changes.changed, vec![]);
    assert_eq!(changes.removed, vec![]);
}

#[test]
fn get_daily_note_changes_for_an_empty_never_reviewed_day_returns_no_blocks() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, "2026-09-05", "");
    let changes = review::get_daily_note_changes(&vault, "2026-09-05").unwrap();
    assert_eq!(changes.note_id, day.id.to_string());
    assert_eq!(changes.content_version, 0);
    assert_eq!(changes.added, vec![]);
    assert_eq!(changes.changed, vec![]);
    assert_eq!(changes.removed, vec![]);
}

// ======================================================================
// AC 5: diff after a review: one changed, one added, one removed.
// ======================================================================

#[test]
fn get_daily_note_changes_after_review_returns_one_changed_one_added_one_removed() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    let before = current_blocks(&vault, &day.id);
    let (jump_id, coyote_id, sleep_id) = (
        before[0].0.clone(),
        before[1].0.clone(),
        before[2].0.clone(),
    );
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&day)], &clock);

    // Delete the first block, edit the second, keep the third, add a fourth.
    set_body(
        &mut vault,
        &day.id,
        "- tried coyote time again\n\nSleep was bad.\n\n## Level ideas\n",
    );
    let after = current_blocks(&vault, &day.id);
    assert_eq!(after[0].0, coyote_id, "precondition: the edit kept its id");
    assert_eq!(after[1].0, sleep_id, "precondition: unchanged block kept");

    let changes = review::get_daily_note_changes(&vault, "2026-09-05").unwrap();
    assert_eq!(changes.content_version, 2);

    assert_eq!(changes.changed.len(), 1, "{changes:?}");
    assert_eq!(changes.changed[0].block_id, coyote_id);
    assert_eq!(
        changes.changed[0].text, "- tried coyote time again",
        "changed carries the current text"
    );
    assert_eq!(changes.changed[0].source, "person");

    assert_eq!(changes.added.len(), 1, "{changes:?}");
    assert_eq!(changes.added[0].block_id, after[2].0);
    assert_eq!(changes.added[0].text, "## Level ideas");
    assert_eq!(changes.added[0].source, "person");

    assert_eq!(
        changes.removed,
        vec![SnapshotBlock {
            block_id: jump_id,
            content_hash: before[0].1.clone(),
            text: "Fixed the jump arc.".into(),
        }],
        "removed carries its snapshot text"
    );
    let listed: Vec<&str> = changes
        .added
        .iter()
        .chain(&changes.changed)
        .map(|b| b.block_id.as_str())
        .collect();
    assert!(
        !listed.contains(&sleep_id.as_str()),
        "unchanged not returned"
    );
}

#[test]
fn get_daily_note_changes_right_after_a_review_returns_nothing() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&day)], &clock);
    // A footer write after the review changes no block.
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, 'excerpt', 0)",
            params![day.id.as_str(), topic.id.as_str()],
        )
        .unwrap();
    let current = get_note(&vault, &day.id).unwrap().content_md;
    set_body(&mut vault, &day.id, &current);

    let changes = review::get_daily_note_changes(&vault, "2026-09-05").unwrap();
    assert_eq!(changes.content_version, 1);
    assert_eq!(changes.added, vec![]);
    assert_eq!(changes.changed, vec![]);
    assert_eq!(changes.removed, vec![]);
}

// ======================================================================
// AC 6: malformed date → invalid_date; no daily note → not_found.
// ======================================================================

#[test]
fn get_daily_note_changes_with_a_malformed_date_fails_with_invalid_date() {
    let (_dir, mut vault) = fresh_vault();
    create_daily(&mut vault, "2026-09-05", "Fifth.\n");
    for bad in [
        "2026-9-5",
        "2026-02-30",
        "05-09-2026",
        "yesterday",
        "",
        "2026-09-05 ",
    ] {
        match review::get_daily_note_changes(&vault, bad) {
            Err(e @ MemexError::InvalidDate(_)) => assert_eq!(e.code(), "invalid_date"),
            other => panic!("expected InvalidDate for {bad:?}, got {other:?}"),
        }
    }
}

#[test]
fn get_daily_note_changes_for_a_date_without_a_daily_note_fails_with_not_found() {
    let (_dir, mut vault) = fresh_vault();
    create_daily(&mut vault, "2026-09-05", "Fifth.\n");
    // A role-less note titled with a date is not that day's daily note (Req 1).
    create(&mut vault, "2026-09-04", "Role-less.", json!({}));
    for missing in ["2026-09-06", "2026-09-04"] {
        match review::get_daily_note_changes(&vault, missing) {
            Err(e @ MemexError::NotFound(_)) => assert_eq!(e.code(), "not_found"),
            other => panic!("expected NotFound for {missing}, got {other:?}"),
        }
    }
}

// ======================================================================
// AC 7: a valid mark makes the day Reviewed and replaces the snapshot.
// ======================================================================

#[test]
fn mark_day_reviewed_records_the_version_clock_time_and_snapshot() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    set_body(
        &mut vault,
        &day.id,
        &format!("{THREE_BLOCKS}\n## Level ideas\n"),
    );
    assert_eq!(content_version(&vault, &day.id), 2);

    let result = mark(&mut vault, "2026-09-05", 2, &[daily_entry(&day)], &clock);
    assert_eq!(
        result,
        DayReview {
            date: "2026-09-05".into(),
            note_id: day.id.to_string(),
            state: ReviewState::Reviewed,
            content_version: 2,
            reviewed_content_version: Some(2),
            reviewed_at: Some(T1),
        }
    );
    assert_eq!(day_review_row(&vault, &day.id), (2, Some(2), Some(T1)));
    assert_eq!(
        memex_core::daily::review_state(vault.connection_ref(), day.id.as_str()).unwrap(),
        ReviewState::Reviewed
    );
    assert_eq!(
        snapshot(&vault, &day.id),
        sorted(current_blocks(&vault, &day.id)),
        "snapshot = current blocks (id, content hash, text)"
    );
    assert_eq!(snapshot(&vault, &day.id).len(), 4);
}

#[test]
fn mark_day_reviewed_replaces_the_previous_snapshot() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&day)], &clock);
    let first = snapshot(&vault, &day.id);
    assert_eq!(first.len(), 3);

    // Remove one block and edit another, then review again.
    set_body(
        &mut vault,
        &day.id,
        "Fixed the jump arc for real.\n\nSleep was bad.\n",
    );
    clock.set(T2);
    let result = mark(&mut vault, "2026-09-05", 2, &[daily_entry(&day)], &clock);
    assert_eq!(result.reviewed_content_version, Some(2));
    assert_eq!(result.reviewed_at, Some(T2));
    assert_eq!(day_review_row(&vault, &day.id), (2, Some(2), Some(T2)));

    let second = snapshot(&vault, &day.id);
    assert_eq!(second, sorted(current_blocks(&vault, &day.id)));
    assert_eq!(second.len(), 2, "the removed block left the snapshot");
    assert!(second
        .iter()
        .all(|(_, _, text)| text != "- tried coyote time"));

    let changes = review::get_daily_note_changes(&vault, "2026-09-05").unwrap();
    assert_eq!(changes.added, vec![]);
    assert_eq!(changes.changed, vec![]);
    assert_eq!(
        changes.removed,
        vec![],
        "diff runs against the new snapshot"
    );
}

#[test]
fn mark_day_reviewed_snapshot_is_per_note() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let d05 = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    let d06 = create_daily(&mut vault, "2026-09-06", "Sixth.\n");
    mark(&mut vault, "2026-09-06", 1, &[daily_entry(&d06)], &clock);
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&d05)], &clock);
    // Reviewing 2026-09-05 again leaves 2026-09-06's snapshot alone.
    mark(&mut vault, "2026-09-05", 1, &[daily_entry(&d05)], &clock);
    assert_eq!(
        snapshot(&vault, &d06.id),
        sorted(current_blocks(&vault, &d06.id))
    );
    assert_eq!(
        snapshot(&vault, &d05.id),
        sorted(current_blocks(&vault, &d05.id))
    );
}

// ======================================================================
// AC 8: one agent_changes row per entry; later calls append.
// ======================================================================

#[test]
fn mark_day_reviewed_appends_one_agent_changes_row_per_entry() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic_a = create_topic(&mut vault, "Player Loop");
    let topic_b = create_topic(&mut vault, "Sleep");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);

    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[
            entry(
                &day.id,
                &[
                    "Filed 2 blocks into Player Loop",
                    "Filed 1 block into Sleep",
                ],
            ),
            entry(
                &topic_a.id,
                &[
                    "Created topic",
                    "Added excerpt from 2026-09-05",
                    "Linked to Sleep",
                ],
            ),
            entry(&topic_b.id, &["Added excerpt from 2026-09-05"]),
        ],
        &clock,
    );

    let rows = change_rows(&vault);
    assert_eq!(rows.len(), 3, "{rows:?}");
    let by_note = |id: &NoteId| {
        rows.iter()
            .find(|r| r.note_id == id.as_str())
            .unwrap_or_else(|| panic!("row for {id}: {rows:?}"))
            .clone()
    };
    let d = by_note(&day.id);
    assert_eq!(d.day, "2026-09-05");
    assert_eq!(d.created_at, T1);
    assert_eq!(
        d.bullets,
        vec![
            "Filed 2 blocks into Player Loop",
            "Filed 1 block into Sleep"
        ]
    );
    let a = by_note(&topic_a.id);
    assert_eq!((a.day.as_str(), a.created_at), ("2026-09-05", T1));
    assert_eq!(
        a.bullets,
        vec![
            "Created topic",
            "Added excerpt from 2026-09-05",
            "Linked to Sleep"
        ]
    );
    let b = by_note(&topic_b.id);
    assert_eq!((b.day.as_str(), b.created_at), ("2026-09-05", T1));
    assert_eq!(b.bullets, vec!["Added excerpt from 2026-09-05"]);
    let ids: std::collections::BTreeSet<&str> = rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids.len(), 3, "each row has its own id");
}

#[test]
fn second_mark_day_reviewed_appends_new_rows_and_keeps_the_old_ones() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[
            entry(&day.id, &["Filed 2 blocks into Player Loop"]),
            entry(&topic.id, &["Added excerpt from 2026-09-05"]),
        ],
        &clock,
    );
    let first = change_rows(&vault);
    assert_eq!(first.len(), 2);

    set_body(
        &mut vault,
        &day.id,
        &format!("{THREE_BLOCKS}\nAnother thought.\n"),
    );
    clock.set(T2);
    mark(
        &mut vault,
        "2026-09-05",
        2,
        &[entry(&day.id, &["Nothing new to file"])],
        &clock,
    );

    let rows = change_rows(&vault);
    assert_eq!(rows.len(), 3, "{rows:?}");
    assert_eq!(&rows[..2], &first[..], "old rows kept unchanged");
    assert_eq!(rows[2].note_id, day.id.to_string());
    assert_eq!(rows[2].day, "2026-09-05");
    assert_eq!(rows[2].created_at, T2);
    assert_eq!(rows[2].bullets, vec!["Nothing new to file"]);

    // Re-marking at the same, still current version also appends.
    mark(
        &mut vault,
        "2026-09-05",
        2,
        &[entry(&day.id, &["Checked again"])],
        &clock,
    );
    assert_eq!(change_rows(&vault).len(), 4);
}

// ======================================================================
// AC 9: a stale version fails with review_stale and writes nothing.
// ======================================================================

#[test]
fn mark_day_reviewed_with_an_older_version_fails_with_review_stale_and_writes_nothing() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    set_body(&mut vault, &day.id, "Fixed the jump arc.\n");
    set_body(&mut vault, &day.id, "Fixed the jump arc twice.\n");
    assert_eq!(content_version(&vault, &day.id), 3);
    let before = review_tables(&vault, &day.id);
    assert_eq!(before.day_review, (3, None, None));

    for stale in [2, 1, 0] {
        match review::mark_day_reviewed(
            &mut vault,
            "2026-09-05",
            stale,
            &[daily_entry(&day)],
            &clock,
        ) {
            Err(MemexError::ReviewStale { version, current }) => {
                assert_eq!((version, current), (stale, 3));
            }
            other => panic!("expected ReviewStale for v{stale}, got {other:?}"),
        }
        assert_eq!(
            review_tables(&vault, &day.id),
            before,
            "nothing written (v{stale})"
        );
    }
}

#[test]
fn mark_day_reviewed_stale_after_a_review_keeps_the_old_review_intact() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[daily_entry(&day), entry(&topic.id, &["Added excerpt"])],
        &clock,
    );
    set_body(&mut vault, &day.id, "Fixed the jump arc.\n\nNew line.\n");
    let before = review_tables(&vault, &day.id);
    assert_eq!(before.day_review, (2, Some(1), Some(T1)));
    assert_eq!(before.snapshot.len(), 3);
    assert_eq!(before.changes.len(), 2);

    clock.set(T2);
    let err = review::mark_day_reviewed(
        &mut vault,
        "2026-09-05",
        1,
        &[daily_entry(&day), entry(&topic.id, &["Added excerpt"])],
        &clock,
    )
    .unwrap_err();
    assert_eq!(err.code(), "review_stale");
    assert_eq!(
        err.to_error_json()["error"],
        json!({
            "code": "review_stale",
            "message": err.to_string(),
            "version": 1,
            "current": 2,
        })
    );
    assert_eq!(review_tables(&vault, &day.id), before, "nothing written");
}

// ======================================================================
// AC 10: footer-style writes between fetch and mark do not make it stale.
// ======================================================================

#[test]
fn review_sequence_with_footer_writes_between_fetch_and_mark_succeeds() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    set_body(
        &mut vault,
        &day.id,
        &format!("{THREE_BLOCKS}\n## Level ideas\n"),
    );

    let fetched = review::get_daily_note_changes(&vault, "2026-09-05").unwrap();
    assert_eq!(fetched.content_version, 2);
    let notes_version = get_note(&vault, &day.id).unwrap().version;

    // Write 1: a footer chip, re-rendered by a save of the unchanged person text.
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, 'excerpt', 0)",
            params![day.id.as_str(), topic.id.as_str()],
        )
        .unwrap();
    let body = get_note(&vault, &day.id).unwrap().content_md;
    let saved = set_body(&mut vault, &day.id, &body);
    assert!(saved.content_md.ends_with("[[Player Loop~about]]\n"));
    // Write 2: frontmatter only.
    person_update(
        &mut vault,
        &day.id,
        UpdateNote {
            frontmatter: Some(json!({ "role": "daily", "mood": "ok" })),
            ..Default::default()
        },
    );
    assert_eq!(
        get_note(&vault, &day.id).unwrap().version,
        notes_version + 2,
        "precondition: both writes bumped notes.version"
    );
    assert_eq!(
        content_version(&vault, &day.id),
        2,
        "but not content_version"
    );

    let result = mark(
        &mut vault,
        "2026-09-05",
        fetched.content_version,
        &[
            entry(&day.id, &["Filed 4 blocks into Player Loop"]),
            entry(&topic.id, &["Added excerpt from 2026-09-05"]),
        ],
        &clock,
    );
    assert_eq!(result.state, ReviewState::Reviewed);
    assert_eq!(day_review_row(&vault, &day.id), (2, Some(2), Some(T1)));
    assert_eq!(review::list_unreviewed_days(&vault).unwrap(), vec![]);
}

// ======================================================================
// AC 11: change-entry validation rejects the whole call and writes nothing.
// ======================================================================

/// Asserts `changes` is rejected with `ChangeEntriesInvalid` whose message
/// names the rule (`rule` is a lowercase phrase of it), and nothing is written.
fn assert_rejected(vault: &mut Vault, day: &Note, changes: &[ChangeEntry], rule: &str) {
    let clock = FakeClock::at(T2);
    let before = review_tables(vault, &day.id);
    let version = before.day_review.0;
    match review::mark_day_reviewed(vault, &day.title, version, changes, &clock) {
        Err(e @ MemexError::ChangeEntriesInvalid(_)) => {
            assert_eq!(e.code(), "change_entries_invalid");
            let message = e.to_string().to_lowercase();
            assert!(
                message.contains(rule),
                "message {message:?} should state the rule ({rule:?})"
            );
            assert_eq!(
                e.to_error_json()["error"],
                json!({ "code": "change_entries_invalid", "message": e.to_string() })
            );
        }
        other => panic!("expected ChangeEntriesInvalid ({rule}), got {other:?}"),
    }
    assert_eq!(
        review_tables(vault, &day.id),
        before,
        "nothing written ({rule})"
    );
}

fn rejection_fixture() -> (TempDir, Vault, Note, Note) {
    let (dir, mut vault) = fresh_vault();
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    (dir, vault, day, topic)
}

#[test]
fn mark_day_reviewed_rejects_an_entry_with_zero_bullets() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[daily_entry(&day), entry(&topic.id, &[])],
        "1 to 3",
    );
    assert_rejected(&mut vault, &day, &[entry(&day.id, &[])], "1 to 3");
}

#[test]
fn mark_day_reviewed_rejects_an_entry_with_four_bullets() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[
            daily_entry(&day),
            entry(&topic.id, &["One", "Two", "Three", "Four"]),
        ],
        "1 to 3",
    );
}

#[test]
fn mark_day_reviewed_rejects_a_201_character_bullet() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    let long = "a".repeat(201);
    assert_rejected(
        &mut vault,
        &day,
        &[daily_entry(&day), entry(&topic.id, &["Fine", &long])],
        "200",
    );
    let long = format!("Filed {}", "é".repeat(195));
    assert_eq!(long.chars().count(), 201);
    assert_rejected(&mut vault, &day, &[entry(&day.id, &[&long])], "200");
}

#[test]
fn mark_day_reviewed_rejects_a_bullet_containing_a_newline() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[
            daily_entry(&day),
            entry(&topic.id, &["Filed 2 blocks\ninto Player Loop"]),
        ],
        "newline",
    );
    assert_rejected(
        &mut vault,
        &day,
        &[entry(&day.id, &["Filed 2 blocks into Player Loop\n"])],
        "newline",
    );
}

#[test]
fn mark_day_reviewed_rejects_a_bullet_starting_with_dash_space() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[
            daily_entry(&day),
            entry(&topic.id, &["Added excerpt", "- Linked to Sleep"]),
        ],
        "leading",
    );
}

#[test]
fn mark_day_reviewed_rejects_changes_without_the_daily_note_entry() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[entry(&topic.id, &["Added excerpt from 2026-09-05"])],
        "daily note",
    );
    assert_rejected(&mut vault, &day, &[], "daily note");
    // Another day's daily note does not stand in for this one.
    let other = create_daily(&mut vault, "2026-09-06", "Sixth.\n");
    assert_rejected(&mut vault, &day, &[daily_entry(&other)], "daily note");
}

#[test]
fn mark_day_reviewed_accepts_one_and_three_bullets_and_a_dash_without_space() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    let clock = FakeClock::at(T1);
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[
            entry(&day.id, &["-3 blocks left unfiled"]),
            entry(
                &topic.id,
                &["Created topic", "Added excerpt", "Linked to Sleep"],
            ),
        ],
        &clock,
    );
    let rows = change_rows(&vault);
    assert_eq!(rows.len(), 2);
    assert_eq!(day_review_row(&vault, &day.id), (1, Some(1), Some(T1)));
}

// ======================================================================
// AC 12: a 200-character bullet is accepted.
// ======================================================================

#[test]
fn mark_day_reviewed_accepts_a_bullet_of_exactly_200_characters() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    let clock = FakeClock::at(T1);
    let ascii = "a".repeat(200);
    // 200 characters but 400 bytes: the limit counts characters.
    let wide = "é".repeat(200);
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[entry(&day.id, &[&ascii]), entry(&topic.id, &[&wide])],
        &clock,
    );
    let rows = change_rows(&vault);
    let bullets: Vec<&str> = rows.iter().map(|r| r.bullets[0].as_str()).collect();
    assert!(bullets.contains(&ascii.as_str()), "{bullets:?}");
    assert!(bullets.contains(&wide.as_str()), "{bullets:?}");
    assert_eq!(day_review_row(&vault, &day.id), (1, Some(1), Some(T1)));
}

// ======================================================================
// AC 13: note_review_fields: `review` and `latest_change` for daily notes.
// ======================================================================

fn fields(vault: &Vault, note: &Note) -> Value {
    let note = get_note(vault, &note.id).unwrap();
    Value::Object(review::note_review_fields(vault, &note).unwrap())
}

#[test]
fn note_review_fields_for_a_never_reviewed_daily_note() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    assert_eq!(
        fields(&vault, &day),
        json!({
            "review": {
                "state": "Unreviewed",
                "content_version": 1,
                "reviewed_content_version": null,
                "reviewed_at": null,
            },
            "latest_change": null,
        })
    );
}

#[test]
fn note_review_fields_show_the_review_state_and_latest_change_entry() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[
            entry(&day.id, &["Filed 2 blocks into Player Loop"]),
            entry(&topic.id, &["Added excerpt from 2026-09-05"]),
        ],
        &clock,
    );
    assert_eq!(
        fields(&vault, &day),
        json!({
            "review": {
                "state": "Reviewed",
                "content_version": 1,
                "reviewed_content_version": 1,
                "reviewed_at": T1,
            },
            "latest_change": {
                "day": "2026-09-05",
                "created_at": T1,
                "bullets": ["Filed 2 blocks into Player Loop"],
            },
        })
    );

    // The person edits; a second review appends a newer entry.
    set_body(&mut vault, &day.id, "Fixed the jump arc.\n");
    assert_eq!(
        fields(&vault, &day)["review"],
        json!({
            "state": "Changed since review",
            "content_version": 2,
            "reviewed_content_version": 1,
            "reviewed_at": T1,
        })
    );
    clock.set(T2);
    mark(
        &mut vault,
        "2026-09-05",
        2,
        &[entry(
            &day.id,
            &["Nothing new to file", "Checked removed blocks"],
        )],
        &clock,
    );
    assert_eq!(
        fields(&vault, &day)["latest_change"],
        json!({
            "day": "2026-09-05",
            "created_at": T2,
            "bullets": ["Nothing new to file", "Checked removed blocks"],
        })
    );
}

#[test]
fn note_review_fields_are_absent_for_notes_that_are_not_daily() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let plain = create(&mut vault, "Loose idea", "Text.", json!({}));
    let iso = create(&mut vault, "2026-09-04", "Role-less.", json!({}));
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    // The topic note has a change entry, but it is still not a daily note.
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[daily_entry(&day), entry(&topic.id, &["Added excerpt"])],
        &clock,
    );
    for note in [&topic, &plain, &iso] {
        assert_eq!(fields(&vault, note), json!({}), "{}", note.title);
    }
    assert!(fields(&vault, &day)["review"].is_object());
}

// ======================================================================
// Implementer tests for the lead rulings (WI #11).
// ======================================================================

/// AC 9 (lead ruling): `version` must equal the current content version; a
/// newer one is stale too and writes nothing.
#[test]
fn mark_day_reviewed_with_a_newer_version_fails_with_review_stale_and_writes_nothing() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    set_body(&mut vault, &day.id, "Fixed the jump arc.\n");
    assert_eq!(content_version(&vault, &day.id), 2);
    let before = review_tables(&vault, &day.id);

    for newer in [3, 4, 100] {
        match review::mark_day_reviewed(
            &mut vault,
            "2026-09-05",
            newer,
            &[daily_entry(&day)],
            &clock,
        ) {
            Err(MemexError::ReviewStale { version, current }) => {
                assert_eq!((version, current), (newer, 2));
            }
            other => panic!("expected ReviewStale for v{newer}, got {other:?}"),
        }
        assert_eq!(
            review_tables(&vault, &day.id),
            before,
            "nothing written (v{newer})"
        );
    }
}

/// AC 11 (lead ruling): two entries for one note reject the whole call.
#[test]
fn mark_day_reviewed_rejects_duplicate_entries_for_one_note() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[
            daily_entry(&day),
            entry(&topic.id, &["Created topic"]),
            entry(&topic.id, &["Added excerpt"]),
        ],
        "duplicate",
    );
    assert_rejected(
        &mut vault,
        &day,
        &[daily_entry(&day), daily_entry(&day)],
        "duplicate",
    );
}

/// AC 11 (lead ruling): an entry naming a note that does not exist fails with
/// `not_found` (never a foreign-key error) and writes nothing.
#[test]
fn mark_day_reviewed_with_an_entry_for_a_missing_note_fails_with_not_found() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    let clock = FakeClock::at(T2);
    let before = review_tables(&vault, &day.id);
    let missing = NoteId::new();
    for ghost in [missing.as_str(), "not-a-note-id"] {
        let changes = [
            daily_entry(&day),
            entry(&topic.id, &["Added excerpt"]),
            ChangeEntry {
                note_id: ghost.to_string(),
                bullets: vec!["Created topic".into()],
            },
        ];
        match review::mark_day_reviewed(&mut vault, "2026-09-05", 1, &changes, &clock) {
            Err(e @ MemexError::NotFound(_)) => {
                assert_eq!(e.code(), "not_found");
                assert!(e.to_string().contains(ghost), "{e}");
            }
            other => panic!("expected NotFound for {ghost}, got {other:?}"),
        }
        assert_eq!(
            review_tables(&vault, &day.id),
            before,
            "nothing written ({ghost})"
        );
    }
}

/// AC 11: a carriage return also breaks the one-line rule.
#[test]
fn mark_day_reviewed_rejects_a_bullet_containing_a_carriage_return() {
    let (_dir, mut vault, day, topic) = rejection_fixture();
    assert_rejected(
        &mut vault,
        &day,
        &[
            daily_entry(&day),
            entry(&topic.id, &["Filed 2 blocks\rinto Sleep"]),
        ],
        "newline",
    );
}

/// AC 13: `latest_change` is the newest row for the note, also when two
/// reviews share one clock time.
#[test]
fn note_review_fields_latest_change_is_the_newest_row_for_the_note() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FakeClock::at(T1);
    let topic = create_topic(&mut vault, "Player Loop");
    let day = create_daily(&mut vault, "2026-09-05", THREE_BLOCKS);
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[entry(&day.id, &["First pass"])],
        &clock,
    );
    mark(
        &mut vault,
        "2026-09-05",
        1,
        &[
            entry(&topic.id, &["Added excerpt"]),
            entry(&day.id, &["Second pass"]),
        ],
        &clock,
    );
    assert_eq!(
        fields(&vault, &day)["latest_change"],
        json!({ "day": "2026-09-05", "created_at": T1, "bullets": ["Second pass"] })
    );
}
