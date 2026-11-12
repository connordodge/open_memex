//! WI #12 (R9): `daily::append_to_daily_note`, the append path behind MCP
//! `append_to_daily_note` (agent) and `memex append` (quick entry).
//!
//! - The text lands verbatim at the end of the person section, above the
//!   Topics footer marker, with the C3.1 separator (`daily::append_to_person`).
//! - The day defaults to today from the injected clock (D14); a missing daily
//!   note is created; a role-less note titled with the date is adopted on the
//!   quick-entry path and a `TitleConflict` on the agent path (D15 / Q2).
//! - New blocks are stamped with the source and `created_version` = the new
//!   `notes.version`; `content_version` goes up by one (D9).
//! - `prior_state` is the review state read immediately before the write.
//! - A person save between the read and the write is absorbed by a bounded
//!   retry against the latest body (Req 31), driven here through the
//!   deterministic `append_to_daily_note_with_hook` seam, never sleeps.
//!
//! Real SQLite, real schema V5, temp vaults only.

use chrono::{Local, NaiveDate, TimeZone};
use memex_core::daily::{self, AppendOutcome, AppendSource, ReviewState};
use memex_core::error::MemexError;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::{Caller, Clock, SystemClock, Vault};
use rusqlite::params;
use serde_json::json;
use tempfile::TempDir;

const MARKER_LINE: &str = "<!-- memex:topics -->\n";

/// A clock pinned to one instant.
struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// Noon local time on `date`, so the local date is `date` in any time zone.
fn local_noon(y: i32, m: u32, d: u32) -> FixedClock {
    let at = Local
        .with_ymd_and_hms(y, m, d, 12, 0, 0)
        .single()
        .expect("unambiguous local noon");
    FixedClock(at.timestamp_millis())
}

/// The injected "today" of every test: 2026-09-05, far from the real today.
fn clock() -> FixedClock {
    local_noon(2026, 9, 5)
}

const CLOCK_DAY: &str = "2026-09-05";

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn create_daily(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(json!({ "role": "daily" })),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create daily {title}: {e}"))
}

fn create_plain(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: None,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"))
}

/// A person save of the body (as the app's editor does).
fn person_save(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
    let version = get_note(vault, id).unwrap().version;
    update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person save {id}: {e}"))
}

fn append(
    vault: &mut Vault,
    text: &str,
    date: Option<&str>,
    source: AppendSource,
) -> Result<AppendOutcome, MemexError> {
    daily::append_to_daily_note(vault, text, date, source, &clock(), None)
}

fn append_ok(vault: &mut Vault, text: &str, date: Option<&str>) -> AppendOutcome {
    append(vault, text, date, AppendSource::Agent)
        .unwrap_or_else(|e| panic!("append {text:?}: {e}"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BlockRow {
    block_id: String,
    text: String,
    source: String,
    created_version: i64,
}

/// The note's blocks in `ord` order.
fn blocks_of(vault: &Vault, id: &NoteId) -> Vec<BlockRow> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT block_id, text, source, created_version FROM blocks
             WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id.as_str()], |r| {
        Ok(BlockRow {
            block_id: r.get(0)?,
            text: r.get(1)?,
            source: r.get(2)?,
            created_version: r.get(3)?,
        })
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

fn content_version(vault: &Vault, id: &NoteId) -> Option<i64> {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .ok()
}

fn state_of(vault: &Vault, id: &NoteId) -> ReviewState {
    daily::review_state(vault.connection_ref(), id.as_str()).unwrap()
}

/// Marks the day reviewed at its current content version (what #11's
/// `mark_day_reviewed` records).
fn mark_reviewed(vault: &Vault, id: &NoteId) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE day_reviews SET reviewed_content_version = content_version, reviewed_at = 1
             WHERE note_id = ?",
            [id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "day_reviews row for {id}");
    assert_eq!(state_of(vault, id), ReviewState::Reviewed);
}

fn note_count(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

/// `(id, title, content_md, frontmatter, version)` of every note, by id.
fn snapshot(vault: &Vault) -> Vec<(String, String, String, String, i64)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT id, title, content_md, frontmatter, version FROM notes ORDER BY id")
        .unwrap();
    stmt.query_map([], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

/// `(note_id, block_id, source, created_version)` of every block.
fn all_blocks(vault: &Vault) -> Vec<(String, String, String, i64)> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT note_id, block_id, source, created_version FROM blocks
             ORDER BY note_id, ord",
        )
        .unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

/// A daily note for the injected today whose footer holds one chip.
fn daily_with_chip(vault: &mut Vault, person: &str) -> (Note, Note) {
    let topic = create_note_as(
        vault,
        CreateNote {
            title: Some("Player Loop".into()),
            content_md: "jump".into(),
            frontmatter: Some(json!({ "role": "topic" })),
        },
        Caller::Person,
    )
    .unwrap();
    let note = create_daily(vault, CLOCK_DAY, person);
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, 'person', 0)",
            params![note.id.as_str(), topic.id.as_str()],
        )
        .unwrap();
    let note = person_save(vault, &note.id, person);
    assert_eq!(
        note.content_md,
        format!("{person}{MARKER_LINE}[[Player Loop~about]]\n"),
        "fixture: footer rendered"
    );
    (note, topic)
}

// ---------- AC 1: today from the injected clock; the returned outcome ----------

#[test]
fn append_without_date_uses_the_injected_clock_and_returns_the_outcome() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    // The real today must stay untouched: the date comes from the clock.
    let real_today = daily::today_with_clock(&SystemClock).to_string();
    assert_ne!(real_today, CLOCK_DAY);
    let other = create_daily(&mut vault, &real_today, "Real today.\n");

    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    assert_eq!(out.date, NaiveDate::from_ymd_opt(2026, 9, 5).unwrap());
    assert_eq!(out.note.id, day.id);
    assert_eq!(out.note.title, CLOCK_DAY);
    let stored = get_note(&vault, &day.id).unwrap();
    assert_eq!(out.note.version, 2);
    assert_eq!(stored.version, out.note.version);
    assert_eq!(stored.content_md, out.note.content_md);
    assert_eq!(
        stored.content_md,
        format!("Morning pages\n\nBought a new keyboard.\n{MARKER_LINE}")
    );

    assert_eq!(out.block_ids.len(), 1, "{:?}", out.block_ids);
    let blocks = blocks_of(&vault, &day.id);
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[1].block_id, out.block_ids[0]);
    assert_eq!(blocks[1].text, "Bought a new keyboard.");

    assert_eq!(out.content_version, 2);
    assert_eq!(content_version(&vault, &day.id), Some(out.content_version));
    assert_eq!(out.prior_state, ReviewState::Unreviewed);

    let untouched = get_note(&vault, &other.id).unwrap();
    assert_eq!(untouched.version, 1);
    assert_eq!(untouched.content_md, format!("Real today.\n{MARKER_LINE}"));
}

#[test]
fn append_reindexes_the_daily_note_from_its_stored_content() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT ord, content FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let rows: Vec<(i64, String)> = stmt
        .query_map([day.id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    // Only the person section is chunked (WI #418, Spec #391 req 1).
    let person = memex_core::daily::split_body(&out.note.content_md).person;
    let expected: Vec<(i64, String)> = memex_core::chunker::chunk(&person)
        .into_iter()
        .map(|c| (c.ord, c.content))
        .collect();
    assert!(!expected.is_empty());
    assert_eq!(
        rows, expected,
        "chunks derive from the appended content (D8)"
    );
    assert!(
        rows.iter()
            .any(|(_, c)| c.contains("Bought a new keyboard.")),
        "{rows:?}"
    );
}

// ---------- AC 2: no daily note today → created ----------

#[test]
fn append_when_the_day_has_no_daily_note_creates_it_with_the_text_above_the_marker() {
    let (_dir, mut vault) = fresh_vault();
    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    assert_eq!(note_count(&vault), 1);
    let stored = get_note(&vault, &out.note.id).unwrap();
    assert_eq!(stored.title, CLOCK_DAY);
    assert_eq!(stored.frontmatter["role"], "daily");
    assert_eq!(
        stored.content_md,
        format!("Bought a new keyboard.\n{MARKER_LINE}")
    );
    assert_eq!(stored.version, out.note.version);
    assert_eq!(out.date.to_string(), CLOCK_DAY);

    let blocks = blocks_of(&vault, &stored.id);
    assert_eq!(blocks.len(), 1);
    assert_eq!(out.block_ids, vec![blocks[0].block_id.clone()]);
    assert_eq!(blocks[0].text, "Bought a new keyboard.");
    assert_eq!(blocks[0].source, "agent");
    assert_eq!(blocks[0].created_version, out.note.version);

    assert_eq!(out.content_version, 1);
    assert_eq!(content_version(&vault, &stored.id), Some(1));
    assert_eq!(out.prior_state, ReviewState::Unreviewed);
    assert_eq!(state_of(&vault, &stored.id), ReviewState::Unreviewed);
}

#[test]
fn quick_entry_append_creating_the_daily_note_stamps_quick_entry() {
    let (_dir, mut vault) = fresh_vault();
    let out = append(
        &mut vault,
        "Call the bank",
        Some("2026-10-01"),
        AppendSource::QuickEntry,
    )
    .unwrap();

    let stored = get_note(&vault, &out.note.id).unwrap();
    assert_eq!(stored.title, "2026-10-01");
    assert_eq!(stored.frontmatter["role"], "daily");
    assert_eq!(stored.content_md, format!("Call the bank\n{MARKER_LINE}"));
    let blocks = blocks_of(&vault, &stored.id);
    assert_eq!(blocks.len(), 1);
    assert_eq!(out.block_ids, vec![blocks[0].block_id.clone()]);
    assert_eq!(blocks[0].source, "quick-entry");
    assert_eq!(blocks[0].created_version, stored.version);
    assert_eq!(out.note.version, stored.version);
    assert_eq!(out.content_version, 1);
}

// ---------- AC 3: C3.1 separator; person bytes and footer unchanged ----------

#[test]
fn append_pads_the_person_section_with_one_blank_line_and_keeps_the_footer() {
    let (_dir, mut vault) = fresh_vault();
    let person = "Morning pages\n- buy milk\n";
    let (day, _topic) = daily_with_chip(&mut vault, person);

    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    let expected = format!(
        "Morning pages\n- buy milk\n\nBought a new keyboard.\n{MARKER_LINE}[[Player Loop~about]]\n"
    );
    assert_eq!(out.note.content_md, expected);
    assert_eq!(get_note(&vault, &day.id).unwrap().content_md, expected);
    let split = daily::split_body(&expected);
    assert!(split.person.starts_with(person), "{:?}", split.person);
    assert_eq!(split.chips, vec!["Player Loop".to_string()]);
}

#[test]
fn append_twice_separates_each_text_by_one_blank_line() {
    let (_dir, mut vault) = fresh_vault();
    let (day, _topic) = daily_with_chip(&mut vault, "Morning pages\n");

    append_ok(&mut vault, "First.", None);
    let out = append_ok(&mut vault, "Second.", None);

    assert_eq!(
        get_note(&vault, &day.id).unwrap().content_md,
        format!("Morning pages\n\nFirst.\n\nSecond.\n{MARKER_LINE}[[Player Loop~about]]\n")
    );
    assert_eq!(out.note.version, 4);
}

#[test]
fn append_to_a_person_section_already_ending_in_a_blank_line_adds_no_padding() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n\n");
    append_ok(&mut vault, "Bought a new keyboard.", None);
    assert_eq!(
        get_note(&vault, &day.id).unwrap().content_md,
        format!("Morning pages\n\nBought a new keyboard.\n{MARKER_LINE}")
    );

    // Extra trailing blank lines are the person's bytes: kept, never trimmed.
    let (_dir2, mut vault2) = fresh_vault();
    let day2 = create_daily(&mut vault2, CLOCK_DAY, "a\n\n\n");
    append_ok(&mut vault2, "b", None);
    assert_eq!(
        get_note(&vault2, &day2.id).unwrap().content_md,
        format!("a\n\n\nb\n{MARKER_LINE}")
    );
}

#[test]
fn append_to_an_empty_daily_note_adds_no_leading_blank_line() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "");
    assert_eq!(content_version(&vault, &day.id), Some(0));

    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    assert_eq!(out.note.id, day.id);
    assert_eq!(
        get_note(&vault, &day.id).unwrap().content_md,
        format!("Bought a new keyboard.\n{MARKER_LINE}")
    );
    assert_eq!(out.content_version, 1);
}

#[test]
fn append_keeps_the_text_verbatim() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    // Leading spaces, markdown, odd spacing, non-ASCII, a tab and a line
    // break: the person's words are never rewritten.
    let text = "  teh keybaord  is *great*,   honestly — café\n\tsecond line";
    append_ok(&mut vault, text, None);
    assert_eq!(
        get_note(&vault, &day.id).unwrap().content_md,
        format!("Morning pages\n\n{text}\n{MARKER_LINE}")
    );

    // A text that already ends with a newline gets no second one.
    append_ok(&mut vault, "Call the bank\n", None);
    assert_eq!(
        get_note(&vault, &day.id).unwrap().content_md,
        format!("Morning pages\n\n{text}\n\nCall the bank\n{MARKER_LINE}")
    );
}

// ---------- AC 4: two paragraphs → two blocks, in order, stamped ----------

#[test]
fn two_paragraph_text_returns_both_new_block_ids_in_order_stamped_agent() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let before = blocks_of(&vault, &day.id);
    assert_eq!(before.len(), 1);

    let out = append_ok(&mut vault, "First thought.\n\nSecond thought.", None);

    let blocks = blocks_of(&vault, &day.id);
    assert_eq!(blocks.len(), 3);
    assert_eq!(blocks[0], before[0], "the person block is unchanged");
    assert_eq!(blocks[0].source, "person");
    assert_eq!(
        out.block_ids,
        vec![blocks[1].block_id.clone(), blocks[2].block_id.clone()]
    );
    assert_ne!(out.block_ids[0], out.block_ids[1]);
    assert_eq!(blocks[1].text, "First thought.");
    assert_eq!(blocks[2].text, "Second thought.");
    for b in &blocks[1..] {
        assert_eq!(b.source, "agent", "{b:?}");
        assert_eq!(b.created_version, out.note.version, "{b:?}");
    }
    assert_eq!(out.note.version, 2);
}

#[test]
fn quick_entry_append_stamps_new_blocks_quick_entry() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let out = append(&mut vault, "Call the bank", None, AppendSource::QuickEntry).unwrap();
    let blocks = blocks_of(&vault, &day.id);
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0].source, "person");
    assert_eq!(out.block_ids, vec![blocks[1].block_id.clone()]);
    assert_eq!(blocks[1].source, "quick-entry");
    assert_eq!(blocks[1].created_version, out.note.version);
}

// ---------- AC 5: prior_state ----------

#[test]
fn prior_state_is_reviewed_for_a_reviewed_day_with_no_edits_since() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    mark_reviewed(&vault, &day.id);
    let out = append_ok(&mut vault, "Bought a new keyboard.", None);
    assert_eq!(out.prior_state, ReviewState::Reviewed);
}

#[test]
fn prior_state_is_unreviewed_for_a_never_reviewed_day() {
    let (_dir, mut vault) = fresh_vault();
    create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let out = append_ok(&mut vault, "Bought a new keyboard.", None);
    assert_eq!(out.prior_state, ReviewState::Unreviewed);
}

#[test]
fn prior_state_is_changed_since_review_for_a_reviewed_day_with_unfiled_person_edits() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    mark_reviewed(&vault, &day.id);
    person_save(
        &mut vault,
        &day.id,
        "Morning pages\n\nUnfiled person edit.\n",
    );
    assert_eq!(state_of(&vault, &day.id), ReviewState::ChangedSinceReview);

    let out = append_ok(&mut vault, "Bought a new keyboard.", None);
    assert_eq!(out.prior_state, ReviewState::ChangedSinceReview);
}

// ---------- AC 6: state after the append; content_version + 1 ----------

#[test]
fn append_to_a_reviewed_day_leaves_it_changed_since_review_with_content_version_plus_one() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    person_save(&mut vault, &day.id, "Morning pages\n\nMore.\n");
    mark_reviewed(&vault, &day.id);
    let before = content_version(&vault, &day.id).unwrap();
    assert_eq!(before, 2);

    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    assert_eq!(out.content_version, before + 1);
    assert_eq!(content_version(&vault, &day.id), Some(before + 1));
    assert_eq!(state_of(&vault, &day.id), ReviewState::ChangedSinceReview);
}

#[test]
fn append_to_a_never_reviewed_day_leaves_it_unreviewed_with_content_version_plus_one() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let before = content_version(&vault, &day.id).unwrap();
    assert_eq!(before, 1);

    let out = append_ok(&mut vault, "Bought a new keyboard.", None);

    assert_eq!(out.content_version, before + 1);
    assert_eq!(content_version(&vault, &day.id), Some(before + 1));
    assert_eq!(state_of(&vault, &day.id), ReviewState::Unreviewed);
}

// ---------- AC 7: a racing person save is absorbed by a retry ----------

#[test]
fn append_retries_after_a_person_save_between_read_and_write() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let id = day.id.clone();
    let mut attempts = Vec::new();

    let out = daily::append_to_daily_note_with_hook(
        &mut vault,
        "Bought a new keyboard.",
        None,
        AppendSource::Agent,
        &clock(),
        None,
        &mut |v: &mut Vault, attempt: u32| {
            attempts.push(attempt);
            if attempt == 1 {
                // The person's save lands after the append read the body.
                person_save(v, &id, "Morning pages\n\nPerson typed this.\n");
            }
        },
    )
    .unwrap_or_else(|e| panic!("append must absorb the race: {e}"));

    assert_eq!(attempts, vec![1, 2], "one retry");
    let stored = get_note(&vault, &day.id).unwrap();
    assert_eq!(
        stored.content_md,
        format!("Morning pages\n\nPerson typed this.\n\nBought a new keyboard.\n{MARKER_LINE}")
    );
    assert_eq!(stored.version, 3, "create, person save, append");
    assert_eq!(out.note.version, 3);
    assert_eq!(out.note.content_md, stored.content_md);

    let blocks = blocks_of(&vault, &day.id);
    assert_eq!(blocks.len(), 3);
    assert_eq!(blocks[1].text, "Person typed this.");
    assert_eq!(blocks[1].source, "person");
    assert_eq!(out.block_ids, vec![blocks[2].block_id.clone()]);
    assert_eq!(blocks[2].text, "Bought a new keyboard.");
    assert_eq!(blocks[2].source, "agent");
    assert_eq!(blocks[2].created_version, 3);
    // 1 at create, +1 person edit, +1 append.
    assert_eq!(out.content_version, 3);
    assert_eq!(content_version(&vault, &day.id), Some(3));
}

#[test]
fn append_retry_reports_the_prior_state_read_by_the_successful_attempt() {
    // A reviewed day that the person edits mid-append holds unfiled text: the
    // prior_state the capture prompt relies on must say so, not `Reviewed`.
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    mark_reviewed(&vault, &day.id);
    let id = day.id.clone();

    let out = daily::append_to_daily_note_with_hook(
        &mut vault,
        "Bought a new keyboard.",
        None,
        AppendSource::Agent,
        &clock(),
        None,
        &mut |v: &mut Vault, attempt: u32| {
            if attempt == 1 {
                person_save(v, &id, "Morning pages\n\nUnfiled.\n");
            }
        },
    )
    .unwrap();

    assert_eq!(out.prior_state, ReviewState::ChangedSinceReview);
    assert_eq!(state_of(&vault, &day.id), ReviewState::ChangedSinceReview);
}

#[test]
fn append_gives_up_with_version_conflict_after_five_attempts() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, CLOCK_DAY, "Morning pages\n");
    let id = day.id.clone();
    let mut attempts = Vec::new();

    let result = daily::append_to_daily_note_with_hook(
        &mut vault,
        "Bought a new keyboard.",
        None,
        AppendSource::Agent,
        &clock(),
        None,
        &mut |v: &mut Vault, attempt: u32| {
            attempts.push(attempt);
            person_save(v, &id, &format!("Morning pages\n\nEdit {attempt}.\n"));
        },
    );

    match result {
        Err(MemexError::VersionConflict { .. }) => {}
        other => panic!("expected VersionConflict, got {other:?}"),
    }
    assert_eq!(attempts, vec![1, 2, 3, 4, 5], "bounded at 5 attempts");
    let stored = get_note(&vault, &day.id).unwrap();
    assert_eq!(
        stored.content_md,
        format!("Morning pages\n\nEdit 5.\n{MARKER_LINE}"),
        "the append wrote nothing"
    );
    assert_eq!(stored.version, 6);
    assert!(blocks_of(&vault, &day.id)
        .iter()
        .all(|b| b.source == "person"));
}

// ---------- AC 8: explicit date; malformed date ----------

#[test]
fn append_with_an_explicit_date_targets_that_day() {
    let (_dir, mut vault) = fresh_vault();
    let today = create_daily(&mut vault, CLOCK_DAY, "Today.\n");
    let earlier = create_daily(&mut vault, "2026-10-01", "Earlier day.\n");

    let out = append_ok(&mut vault, "Bought a new keyboard.", Some("2026-10-01"));

    assert_eq!(out.note.id, earlier.id);
    assert_eq!(out.date, NaiveDate::from_ymd_opt(2026, 10, 1).unwrap());
    assert_eq!(
        get_note(&vault, &earlier.id).unwrap().content_md,
        format!("Earlier day.\n\nBought a new keyboard.\n{MARKER_LINE}")
    );
    let kept = get_note(&vault, &today.id).unwrap();
    assert_eq!(kept.version, 1);
    assert_eq!(kept.content_md, format!("Today.\n{MARKER_LINE}"));

    // A date with no daily note yet gets one.
    let out = append_ok(&mut vault, "Note for later.", Some("2026-08-31"));
    let created = get_note(&vault, &out.note.id).unwrap();
    assert_eq!(created.title, "2026-08-31");
    assert_eq!(created.frontmatter["role"], "daily");
    assert_eq!(
        created.content_md,
        format!("Note for later.\n{MARKER_LINE}")
    );
    assert_eq!(note_count(&vault), 3);
}

#[test]
fn append_with_a_malformed_date_fails_with_invalid_date_and_writes_nothing() {
    let (_dir, mut vault) = fresh_vault();
    create_daily(&mut vault, CLOCK_DAY, "Today.\n");
    create_daily(&mut vault, "2026-10-01", "Earlier day.\n");
    let notes_before = snapshot(&vault);
    let blocks_before = all_blocks(&vault);

    for bad in ["2026-10-1", "2026-02-30", "", "2026/10/01", " 2026-10-01"] {
        for source in [AppendSource::Agent, AppendSource::QuickEntry] {
            match append(&mut vault, "Bought a new keyboard.", Some(bad), source) {
                Err(e @ MemexError::InvalidDate(_)) => assert_eq!(e.code(), "invalid_date"),
                other => panic!("{bad:?} {source:?}: expected InvalidDate, got {other:?}"),
            }
        }
    }
    assert_eq!(snapshot(&vault), notes_before);
    assert_eq!(all_blocks(&vault), blocks_before);
}

// ---------- AC 9: empty or whitespace-only text ----------

#[test]
fn append_with_empty_or_whitespace_text_fails_and_writes_nothing() {
    let (_dir, mut vault) = fresh_vault();
    create_daily(&mut vault, "2026-10-01", "Earlier day.\n");
    let notes_before = snapshot(&vault);
    let blocks_before = all_blocks(&vault);

    for text in ["", " ", "\n", "\n\n", " \t\n  \r\n"] {
        for source in [AppendSource::Agent, AppendSource::QuickEntry] {
            // Today (no daily note yet) and a day that has one.
            for date in [None, Some("2026-10-01")] {
                let result = append(&mut vault, text, date, source);
                assert!(
                    result.is_err(),
                    "{text:?} {source:?} {date:?}: expected an error, got {result:?}"
                );
            }
        }
    }
    assert_eq!(snapshot(&vault), notes_before, "no note created or changed");
    assert_eq!(all_blocks(&vault), blocks_before);
}

// ---------- AC 10 / AC 14: a role-less note titled with the date (Q2) ----------

#[test]
fn agent_append_over_a_role_less_note_with_that_date_fails_with_title_conflict() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(&mut vault, "2026-10-01", "Old note body\n");
    let notes_before = snapshot(&vault);

    match append(
        &mut vault,
        "Bought a new keyboard.",
        Some("2026-10-01"),
        AppendSource::Agent,
    ) {
        Err(MemexError::TitleConflict { existing_id, .. }) => {
            assert_eq!(existing_id, old.id.as_str());
        }
        other => panic!("expected TitleConflict, got {other:?}"),
    }
    assert_eq!(
        snapshot(&vault),
        notes_before,
        "the role-less note is unchanged"
    );
    assert!(all_blocks(&vault).is_empty());
    assert!(content_version(&vault, &old.id).is_none());
}

#[test]
fn agent_append_for_today_over_a_role_less_note_fails_with_title_conflict() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(&mut vault, CLOCK_DAY, "Old note body\n");
    let notes_before = snapshot(&vault);

    match append(
        &mut vault,
        "Bought a new keyboard.",
        None,
        AppendSource::Agent,
    ) {
        Err(MemexError::TitleConflict { existing_id, .. }) => {
            assert_eq!(existing_id, old.id.as_str());
        }
        other => panic!("expected TitleConflict, got {other:?}"),
    }
    assert_eq!(snapshot(&vault), notes_before);
}

#[test]
fn quick_entry_append_adopts_a_role_less_note_with_that_date() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(&mut vault, "2026-10-01", "Old note body\n");

    let out = append(
        &mut vault,
        "Call the bank",
        Some("2026-10-01"),
        AppendSource::QuickEntry,
    )
    .unwrap();

    assert_eq!(out.note.id, old.id, "adopted, not a new note");
    assert_eq!(note_count(&vault), 1);
    let stored = get_note(&vault, &old.id).unwrap();
    assert_eq!(stored.title, "2026-10-01");
    assert_eq!(stored.frontmatter["role"], "daily");
    assert_eq!(
        stored.content_md,
        format!("Old note body\n\nCall the bank\n{MARKER_LINE}")
    );
    assert_eq!(out.note.version, stored.version);

    let blocks = blocks_of(&vault, &old.id);
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0].text, "Old note body");
    assert_eq!(out.block_ids, vec![blocks[1].block_id.clone()]);
    assert_eq!(blocks[1].text, "Call the bank");
    assert_eq!(blocks[1].source, "quick-entry");
    assert_eq!(blocks[1].created_version, stored.version);
    assert_eq!(content_version(&vault, &old.id), Some(out.content_version));
}

// ---------- WI #238 (T2): footer tag lines on the append path ----------

/// Spec #234 R12, R16: append re-renders the footer from rows like any daily
/// write, so a stale footer tag line in the stored body is dropped (never
/// moved into the person section) and the tag rows render as tag lines.
#[test]
fn append_drops_a_stale_footer_tag_line_and_keeps_tag_lines_from_rows() {
    let (_dir, mut vault) = fresh_vault();
    let (note, _topic) = daily_with_chip(&mut vault, "Morning pages\n");
    for (tag, origin) in [("work", "agent"), ("inbox", "agent"), ("mine", "person")] {
        vault
            .connection_ref()
            .execute(
                "INSERT INTO tags (note_id, tag, origin) VALUES (?, ?, ?)",
                params![note.id.as_str(), tag, origin],
            )
            .unwrap();
    }
    // The stored footer still shows `#gone`, a tag removed since it rendered.
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            params![
                format!("Morning pages\n{MARKER_LINE}[[Player Loop~about]]\n#gone\n#work\n"),
                note.id.as_str()
            ],
        )
        .unwrap();
    let cv = content_version(&vault, &note.id).unwrap();

    let out = append_ok(&mut vault, "Bought a keyboard.", None);

    let want = format!(
        "Morning pages\n\nBought a keyboard.\n{MARKER_LINE}[[Player Loop~about]]\n#mine\n#work\n"
    );
    assert_eq!(out.note.content_md, want);
    assert_eq!(get_note(&vault, &note.id).unwrap().content_md, want);
    let texts: Vec<String> = blocks_of(&vault, &note.id)
        .into_iter()
        .map(|b| b.text)
        .collect();
    assert_eq!(
        texts,
        ["Morning pages", "Bought a keyboard."],
        "no footer line became person text"
    );
    assert_eq!(content_version(&vault, &note.id), Some(cv + 1));
}
