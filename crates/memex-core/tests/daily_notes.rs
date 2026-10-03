//! WI #7 (R4): daily notes in core, end to end through the real save path.
//!
//! - D9: one daily write hook inside `create_note_as` / `update_note_as` (and
//!   the rename pass for daily linkers) normalizes the body (D10), re-syncs
//!   the `blocks` rows with #6's engine, and bumps `day_reviews.content_version`
//!   only when `person.trim_end()` changed (Req 19).
//! - D11: the footer is rendered from `footer_chips` in rowid order.
//! - D15 / Q2: one daily note per date; person paths adopt a role-less note
//!   titled with the date, agent calls get `TitleConflict`.
//! - `daily::review_state` / `daily::render_footer`.
//!
//! Real SQLite, real schema V5, temp vaults only.

use memex_core::blocks;
use memex_core::daily::{self, ReviewState};
use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::notes::{
    self, create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions,
    UpdateNote,
};
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const MARKER_LINE: &str = "<!-- memex:topics -->\n";

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn daily_input(title: &str, body: &str) -> CreateNote {
    CreateNote {
        title: Some(title.into()),
        content_md: body.into(),
        frontmatter: Some(json!({ "role": "daily" })),
    }
}

fn plain_input(title: &str, body: &str, frontmatter: Option<Value>) -> CreateNote {
    CreateNote {
        title: Some(title.into()),
        content_md: body.into(),
        frontmatter,
    }
}

fn create_daily(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_note_as(vault, daily_input(title, body), Caller::Person)
        .unwrap_or_else(|e| panic!("create daily {title}: {e}"))
}

fn create_plain(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
    create_note_as(vault, plain_input(title, body, fm), Caller::Person)
        .unwrap_or_else(|e| panic!("create {title}: {e}"))
}

/// Person update of the body only (no rename pass).
fn set_body(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
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
    .unwrap_or_else(|e| panic!("update {id}: {e}"))
}

fn retitle(vault: &mut Vault, id: &NoteId, title: &str) -> Result<Note, MemexError> {
    let version = get_note(vault, id).unwrap().version;
    update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            title: Some(title.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
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

#[derive(Debug, Clone, PartialEq, Eq)]
struct BlockRow {
    block_id: String,
    ord: i64,
    start_byte: i64,
    end_byte: i64,
    text: String,
    content_hash: String,
    source: String,
    created_version: i64,
}

fn blocks_of(vault: &Vault, id: &NoteId) -> Vec<BlockRow> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT block_id, ord, start_byte, end_byte, text, content_hash, source, created_version
             FROM blocks WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id.as_str()], |r| {
        Ok(BlockRow {
            block_id: r.get(0)?,
            ord: r.get(1)?,
            start_byte: r.get(2)?,
            end_byte: r.get(3)?,
            text: r.get(4)?,
            content_hash: r.get(5)?,
            source: r.get(6)?,
            created_version: r.get(7)?,
        })
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

fn block_texts(rows: &[BlockRow]) -> Vec<&str> {
    rows.iter().map(|b| b.text.as_str()).collect()
}

/// `(content_version, reviewed_content_version)`, or `None` without a row.
fn day_review(vault: &Vault, id: &NoteId) -> Option<(i64, Option<i64>)> {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version, reviewed_content_version FROM day_reviews WHERE note_id = ?",
            [id.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .ok()
}

fn content_version(vault: &Vault, id: &NoteId) -> i64 {
    day_review(vault, id)
        .unwrap_or_else(|| panic!("no day_reviews row for {id}"))
        .0
}

fn set_reviewed(vault: &Vault, id: &NoteId, reviewed: i64) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE day_reviews SET reviewed_content_version = ?, reviewed_at = 1 WHERE note_id = ?",
            params![reviewed, id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "day_reviews row for {id}");
}

fn state(vault: &Vault, id: &NoteId) -> ReviewState {
    daily::review_state(vault.connection_ref(), id.as_str()).unwrap()
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    get_note(vault, id).unwrap()
}

fn note_count(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

fn row_count(vault: &Vault, table: &str, id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            &format!("SELECT COUNT(*) FROM {table} WHERE note_id = ?"),
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

fn add_chip(vault: &Vault, daily_id: &NoteId, topic_id: &NoteId, origin: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, ?, 0)",
            params![daily_id.as_str(), topic_id.as_str(), origin],
        )
        .unwrap();
}

/// Every stored block row is consistent with the stored body: ords are
/// 0..n, byte ranges cut the row text out of `content_md`, hashes are #6's
/// FNV-1a-64, and the texts are exactly `blocks::split` of the person section.
fn assert_blocks_match_body(vault: &Vault, id: &NoteId) {
    let note = stored(vault, id);
    let rows = blocks_of(vault, id);
    let person = daily::split_body(&note.content_md).person;
    let want: Vec<String> = blocks::split(&person).into_iter().map(|b| b.text).collect();
    assert_eq!(
        block_texts(&rows),
        want.iter().map(String::as_str).collect::<Vec<_>>(),
        "block texts are the split of the person section of {:?}",
        note.content_md
    );
    for (i, b) in rows.iter().enumerate() {
        assert_eq!(b.ord, i as i64, "ord of {b:?}");
        assert_eq!(
            &note.content_md[b.start_byte as usize..b.end_byte as usize],
            b.text,
            "byte range of {b:?}"
        );
        assert_eq!(
            b.content_hash,
            blocks::content_hash(&b.text),
            "hash of {b:?}"
        );
    }
}

// ---------- AC 4: create normalizes, writes blocks and day_reviews ----------

#[test]
fn create_daily_note_stores_canonical_body_block_and_day_review() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "Fixed the jump arc.\n");

    let want_body = "Fixed the jump arc.\n<!-- memex:topics -->\n";
    assert_eq!(
        note.content_md, want_body,
        "returned note is normalized (D8)"
    );
    assert_eq!(stored(&vault, &note.id).content_md, want_body);
    assert_eq!(note.version, 1);
    assert_eq!(note.title, "2026-09-05");
    assert_eq!(note.frontmatter["role"], "daily");

    let rows = blocks_of(&vault, &note.id);
    assert_eq!(rows.len(), 1, "{rows:?}");
    let b = &rows[0];
    assert_eq!(b.text, "Fixed the jump arc.");
    assert_eq!(b.source, "person");
    assert_eq!(b.created_version, 1);
    assert_eq!((b.ord, b.start_byte, b.end_byte), (0, 0, 19));
    assert_eq!(b.content_hash, blocks::content_hash("Fixed the jump arc."));
    assert!(!b.block_id.is_empty());

    assert_eq!(day_review(&vault, &note.id), Some((1, None)));
    assert_eq!(state(&vault, &note.id), ReviewState::Unreviewed);
}

#[test]
fn create_daily_note_with_several_blocks_records_each_byte_range() {
    let (_dir, mut vault) = fresh_vault();
    let body = "# Saturday\n\nMorning pages.\nStill morning.\n\n- buy milk\n- fix bug\n";
    let note = create_daily(&mut vault, "2026-09-05", body);
    assert_eq!(note.content_md, format!("{body}{MARKER_LINE}"));

    let rows = blocks_of(&vault, &note.id);
    assert_eq!(
        block_texts(&rows),
        vec![
            "# Saturday",
            "Morning pages.\nStill morning.",
            "- buy milk",
            "- fix bug"
        ]
    );
    assert!(rows
        .iter()
        .all(|b| b.source == "person" && b.created_version == 1));
    let ids: std::collections::HashSet<_> = rows.iter().map(|b| b.block_id.clone()).collect();
    assert_eq!(ids.len(), rows.len(), "block ids are unique");
    assert_blocks_match_body(&vault, &note.id);
}

#[test]
fn create_daily_note_with_empty_person_has_content_version_zero_and_no_blocks() {
    let (_dir, mut vault) = fresh_vault();
    let empty = create_daily(&mut vault, "2026-09-05", "");
    assert_eq!(empty.content_md, MARKER_LINE);
    assert_eq!(stored(&vault, &empty.id).content_md, MARKER_LINE);
    assert!(blocks_of(&vault, &empty.id).is_empty());
    assert_eq!(day_review(&vault, &empty.id), Some((0, None)));
    assert_eq!(state(&vault, &empty.id), ReviewState::Unreviewed);

    // Whitespace-only person text is empty after `trim_end`.
    let blank = create_daily(&mut vault, "2026-09-06", "  \n\n");
    assert!(blocks_of(&vault, &blank.id).is_empty());
    assert_eq!(content_version(&vault, &blank.id), 0);

    // The first real text bumps 0 -> 1.
    set_body(&mut vault, &empty.id, "First words.\n");
    assert_eq!(content_version(&vault, &empty.id), 1);
}

#[test]
fn create_daily_note_moves_stray_text_and_drops_unrecorded_chips() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(
        &mut vault,
        "2026-09-05",
        "Morning.\n<!-- memex:topics -->\n[[Ghost~about]]\nlate\n",
    );
    assert_eq!(note.content_md, "Morning.\nlate\n<!-- memex:topics -->\n");
    assert_eq!(content_version(&vault, &note.id), 1);
    assert_blocks_match_body(&vault, &note.id);
}

// ---------- AC 5: one daily note per date; TitleConflict on create ----------

#[test]
fn second_daily_note_for_a_date_fails_with_daily_note_exists() {
    let (_dir, mut vault) = fresh_vault();
    let first = create_daily(&mut vault, "2026-09-05", "One.\n");

    for caller in [Caller::Person, Caller::Agent] {
        let body = if caller == Caller::Person {
            "Two.\n"
        } else {
            ""
        };
        match create_note_as(&mut vault, daily_input("2026-09-05", body), caller) {
            Err(MemexError::DailyNoteExists { date, existing_id }) => {
                assert_eq!(date, "2026-09-05");
                assert_eq!(existing_id, first.id.as_str());
            }
            other => panic!("{caller:?}: expected DailyNoteExists, got {other:?}"),
        }
    }
    assert_eq!(note_count(&vault), 1);
    let kept = stored(&vault, &first.id);
    assert_eq!(kept.content_md, "One.\n<!-- memex:topics -->\n");
    assert_eq!(kept.version, 1);
    assert_eq!(content_version(&vault, &first.id), 1);
}

#[test]
fn create_with_a_taken_title_fails_with_title_conflict_naming_the_existing_id() {
    let (_dir, mut vault) = fresh_vault();
    let groceries = create_plain(&mut vault, "Groceries", "milk", None);
    let day = create_daily(&mut vault, "2026-09-05", "One.\n");

    let cases = [
        (plain_input("Groceries", "eggs", None), &groceries.id),
        (
            plain_input("Groceries", "eggs", Some(json!({ "role": "topic" }))),
            &groceries.id,
        ),
        (plain_input("2026-09-05", "not a day", None), &day.id),
    ];
    for (input, existing) in cases {
        let attempted = input.title.clone().unwrap();
        for caller in [Caller::Person, Caller::Agent] {
            match create_note_as(&mut vault, input.clone(), caller) {
                Err(MemexError::TitleConflict {
                    existing_id,
                    attempted_title,
                }) => {
                    assert_eq!(existing_id, existing.as_str(), "{attempted}");
                    assert_eq!(attempted_title, attempted);
                }
                other => panic!("{attempted} ({caller:?}): expected TitleConflict, got {other:?}"),
            }
        }
    }
    assert_eq!(note_count(&vault), 2);
    assert_eq!(stored(&vault, &groceries.id).content_md, "milk");
}

// ---------- AC 6: ISO titles on create and retitle; retitle uniqueness ----------

#[test]
fn create_daily_note_with_a_non_iso_title_fails_with_invalid_date() {
    let (_dir, mut vault) = fresh_vault();
    for bad in ["Groceries", "2026-02-30", "2026-9-5", "2026-09-05 notes"] {
        for caller in [Caller::Person, Caller::Agent] {
            match create_note_as(&mut vault, daily_input(bad, ""), caller) {
                Err(MemexError::InvalidDate(_)) => {}
                other => panic!("{bad:?} ({caller:?}): expected InvalidDate, got {other:?}"),
            }
        }
    }
    assert_eq!(note_count(&vault), 0);
}

#[test]
fn retitling_a_daily_note_to_a_non_iso_title_fails_with_invalid_date() {
    let (_dir, mut vault) = fresh_vault();
    let day = create_daily(&mut vault, "2026-09-05", "One.\n");
    for bad in ["Groceries", "2026-02-30", "2026-9-5"] {
        match retitle(&mut vault, &day.id, bad) {
            Err(MemexError::InvalidDate(_)) => {}
            other => panic!("{bad:?}: expected InvalidDate, got {other:?}"),
        }
    }
    let kept = stored(&vault, &day.id);
    assert_eq!((kept.title.as_str(), kept.version), ("2026-09-05", 1));

    // A role-less note may still take any valid title.
    let plain = create_plain(&mut vault, "2026-09-07", "x", None);
    assert_eq!(
        retitle(&mut vault, &plain.id, "Groceries").unwrap().title,
        "Groceries"
    );
}

#[test]
fn retitling_a_daily_note_to_a_date_with_a_daily_note_fails_with_daily_note_exists() {
    let (_dir, mut vault) = fresh_vault();
    let fifth = create_daily(&mut vault, "2026-09-05", "Five.\n");
    let sixth = create_daily(&mut vault, "2026-09-06", "Six.\n");

    match retitle(&mut vault, &fifth.id, "2026-09-06") {
        Err(MemexError::DailyNoteExists { date, existing_id }) => {
            assert_eq!(date, "2026-09-06");
            assert_eq!(existing_id, sixth.id.as_str());
        }
        other => panic!("expected DailyNoteExists, got {other:?}"),
    }
    assert_eq!(stored(&vault, &fifth.id).title, "2026-09-05");

    // A free real date is fine, and the body stays canonical.
    let moved = retitle(&mut vault, &fifth.id, "2026-09-07").unwrap();
    assert_eq!(moved.title, "2026-09-07");
    assert_eq!(moved.content_md, "Five.\n<!-- memex:topics -->\n");
    assert_eq!(
        content_version(&vault, &fifth.id),
        1,
        "a retitle is not a person edit"
    );
}

// ---------- AC 7: Q2 adoption on the person path ----------

#[test]
fn person_create_daily_adopts_a_role_less_note_titled_with_the_date() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(
        &mut vault,
        "2026-09-05",
        "old\n",
        Some(json!({ "mood": "ok", "tags": ["x"] })),
    );
    assert!(blocks_of(&vault, &old.id).is_empty());
    assert_eq!(day_review(&vault, &old.id), None);

    let adopted = create_note_as(&mut vault, daily_input("2026-09-05", "new"), Caller::Person)
        .expect("person path adopts the role-less note");

    assert_eq!(adopted.id, old.id, "same note id");
    assert_eq!(note_count(&vault), 1);
    let want_body = "old\n\nnew\n<!-- memex:topics -->\n";
    assert_eq!(adopted.content_md, want_body);
    let kept = stored(&vault, &old.id);
    assert_eq!(kept.content_md, want_body);
    assert_eq!(kept.title, "2026-09-05");
    assert_eq!(
        kept.frontmatter,
        json!({ "mood": "ok", "tags": ["x"], "role": "daily" }),
        "old keys kept, role added"
    );
    assert_eq!(kept.version, 2, "adoption is a write");
    assert_eq!(adopted.version, kept.version);

    let rows = blocks_of(&vault, &old.id);
    assert_eq!(
        block_texts(&rows),
        vec!["old", "new"],
        "a block per paragraph"
    );
    assert!(
        rows.iter()
            .all(|b| b.source == "person" && b.created_version == kept.version),
        "{rows:?}"
    );
    assert_blocks_match_body(&vault, &old.id);
    assert_eq!(day_review(&vault, &old.id), Some((1, None)));
    assert_eq!(state(&vault, &old.id), ReviewState::Unreviewed);
}

#[test]
fn person_create_daily_with_empty_content_adopts_without_appending() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(&mut vault, "2026-09-05", "old\n", None);
    let adopted =
        create_note_as(&mut vault, daily_input("2026-09-05", ""), Caller::Person).unwrap();
    assert_eq!(adopted.id, old.id);
    assert_eq!(adopted.content_md, "old\n<!-- memex:topics -->\n");
    assert_eq!(
        stored(&vault, &old.id).content_md,
        "old\n<!-- memex:topics -->\n"
    );
    assert_eq!(
        stored(&vault, &old.id).frontmatter,
        json!({ "role": "daily" })
    );
    assert_eq!(block_texts(&blocks_of(&vault, &old.id)), vec!["old"]);
    assert_eq!(content_version(&vault, &old.id), 1);
}

#[test]
fn adoption_pads_a_person_section_without_trailing_newline() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(&mut vault, "2026-09-05", "old", None);
    let adopted =
        create_note_as(&mut vault, daily_input("2026-09-05", "new"), Caller::Person).unwrap();
    assert_eq!(adopted.id, old.id);
    assert_eq!(adopted.content_md, "old\n\nnew\n<!-- memex:topics -->\n");

    // An empty role-less note: no separator before the appended text.
    let blank = create_plain(&mut vault, "2026-09-06", "", None);
    let adopted =
        create_note_as(&mut vault, daily_input("2026-09-06", "new"), Caller::Person).unwrap();
    assert_eq!(adopted.id, blank.id);
    assert_eq!(adopted.content_md, "new\n<!-- memex:topics -->\n");
    assert_eq!(content_version(&vault, &blank.id), 1);
}

// ---------- AC 8: Q2 for the agent caller ----------

#[test]
fn agent_create_daily_over_a_role_less_note_fails_with_title_conflict() {
    let (_dir, mut vault) = fresh_vault();
    let old = create_plain(
        &mut vault,
        "2026-09-05",
        "old\n",
        Some(json!({ "mood": "ok" })),
    );

    for content in ["", "new"] {
        match create_note_as(
            &mut vault,
            daily_input("2026-09-05", content),
            Caller::Agent,
        ) {
            Err(MemexError::TitleConflict {
                existing_id,
                attempted_title,
            }) => {
                assert_eq!(existing_id, old.id.as_str());
                assert_eq!(attempted_title, "2026-09-05");
            }
            other => panic!("{content:?}: expected TitleConflict, got {other:?}"),
        }
    }
    let kept = stored(&vault, &old.id);
    assert_eq!(kept.content_md, "old\n");
    assert_eq!(kept.frontmatter, json!({ "mood": "ok" }));
    assert_eq!(kept.version, 1);
    assert_eq!(note_count(&vault), 1);
    assert!(blocks_of(&vault, &old.id).is_empty());
    assert_eq!(day_review(&vault, &old.id), None);
}

// ---------- AC 9: content version +1 per person edit; review states ----------

#[test]
fn person_edit_bumps_content_version_by_one_and_keeps_the_edited_block_id() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(
        &mut vault,
        "2026-09-05",
        "Fixed the jump arc.\n\nTuned gravity.\n",
    );
    let before = blocks_of(&vault, &note.id);
    assert_eq!(content_version(&vault, &note.id), 1);

    let v2 = set_body(
        &mut vault,
        &note.id,
        "Fixed the jump arc today.\n\nTuned gravity.\n",
    );
    assert_eq!(v2.version, 2);
    assert_eq!(
        v2.content_md,
        "Fixed the jump arc today.\n\nTuned gravity.\n<!-- memex:topics -->\n"
    );
    assert_eq!(content_version(&vault, &note.id), 2, "exactly +1");

    let after = blocks_of(&vault, &note.id);
    assert_eq!(
        block_texts(&after),
        vec!["Fixed the jump arc today.", "Tuned gravity."]
    );
    assert_eq!(
        after[0].block_id, before[0].block_id,
        "edited paragraph keeps its id"
    );
    assert_eq!(after[0].created_version, 1);
    assert_eq!(after[0].source, "person");
    assert_eq!(
        after[1].block_id, before[1].block_id,
        "untouched paragraph keeps its id"
    );
    assert_ne!(after[0].content_hash, before[0].content_hash);
    assert_blocks_match_body(&vault, &note.id);

    // A deletion is a person edit too.
    set_body(&mut vault, &note.id, "Tuned gravity.\n");
    assert_eq!(content_version(&vault, &note.id), 3);
    let rows = blocks_of(&vault, &note.id);
    assert_eq!(block_texts(&rows), vec!["Tuned gravity."]);
    assert_eq!(rows[0].block_id, before[1].block_id);
    assert_eq!(rows[0].ord, 0);
    assert_blocks_match_body(&vault, &note.id);
}

#[test]
fn review_state_is_reviewed_when_versions_match_and_changed_after_a_person_edit() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "Fixed the jump arc.\n");
    assert_eq!(state(&vault, &note.id), ReviewState::Unreviewed);

    set_reviewed(&vault, &note.id, 1);
    assert_eq!(state(&vault, &note.id), ReviewState::Reviewed);

    set_body(&mut vault, &note.id, "Fixed the jump arc.\n\nThen lunch.\n");
    assert_eq!(content_version(&vault, &note.id), 2);
    assert_eq!(state(&vault, &note.id), ReviewState::ChangedSinceReview);
    assert_eq!(state(&vault, &note.id).as_str(), "Changed since review");

    set_reviewed(&vault, &note.id, 2);
    assert_eq!(state(&vault, &note.id), ReviewState::Reviewed);

    // Any mismatch that is not NULL is "Changed since review", either way.
    set_reviewed(&vault, &note.id, 3);
    assert_eq!(state(&vault, &note.id), ReviewState::ChangedSinceReview);
    set_reviewed(&vault, &note.id, 0);
    assert_eq!(state(&vault, &note.id), ReviewState::ChangedSinceReview);
}

// ---------- AC 10: no bump for trailing whitespace, frontmatter, footer ----------

#[test]
fn trailing_whitespace_frontmatter_and_chip_only_changes_keep_content_version() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "Fixed the jump arc.\n");
    let ids_before = blocks_of(&vault, &note.id);
    set_reviewed(&vault, &note.id, 1);

    // Trailing whitespace only.
    let w = set_body(&mut vault, &note.id, "Fixed the jump arc.   \n\n\n");
    assert_eq!(w.version, 2, "the save itself still happens");
    assert_eq!(content_version(&vault, &note.id), 1, "trailing whitespace");
    assert_eq!(state(&vault, &note.id), ReviewState::Reviewed);

    // Frontmatter only.
    let v = stored(&vault, &note.id).version;
    let f = update_note_as(
        &mut vault,
        &note.id,
        v,
        UpdateNote {
            frontmatter: Some(json!({ "role": "daily", "mood": "good" })),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap();
    assert_eq!(f.frontmatter["mood"], "good");
    assert_eq!(content_version(&vault, &note.id), 1, "frontmatter only");

    // Chip lines below the marker only (no footer_chips record: dropped).
    let c = set_body(
        &mut vault,
        &note.id,
        "Fixed the jump arc.   \n\n\n<!-- memex:topics -->\n[[Ghost~about]]\n",
    );
    assert_eq!(
        c.content_md, "Fixed the jump arc.   \n\n\n<!-- memex:topics -->\n",
        "unrecorded chip line dropped"
    );
    assert_eq!(content_version(&vault, &note.id), 1, "footer only");
    assert_eq!(state(&vault, &note.id), ReviewState::Reviewed);

    let ids_after = blocks_of(&vault, &note.id);
    assert_eq!(ids_after.len(), 1);
    assert_eq!(ids_after[0].block_id, ids_before[0].block_id);
    assert_eq!(ids_after[0].created_version, 1);

    // A change before the trailing whitespace is a real edit.
    set_body(&mut vault, &note.id, "Fixed the jump arc!\n");
    assert_eq!(content_version(&vault, &note.id), 2);
}

#[test]
fn footer_is_rendered_from_footer_chips_in_rowid_order() {
    let (_dir, mut vault) = fresh_vault();
    let topic = Some(json!({ "role": "topic" }));
    // Alpha is created first, so it sorts first by id and by title; the chips
    // are inserted Bravo first, so only rowid order puts Bravo first.
    let alpha = create_plain(&mut vault, "Alpha", "a", topic.clone());
    let bravo = create_plain(&mut vault, "Bravo", "b", topic);
    let day = create_daily(&mut vault, "2026-09-05", "Day.\n");
    set_reviewed(&vault, &day.id, 1);
    add_chip(&vault, &day.id, &bravo.id, "excerpt");
    add_chip(&vault, &day.id, &alpha.id, "person");

    assert_eq!(
        daily::render_footer(vault.connection_ref(), day.id.as_str()).unwrap(),
        vec!["Bravo".to_string(), "Alpha".to_string()]
    );
    assert!(
        daily::render_footer(vault.connection_ref(), alpha.id.as_str())
            .unwrap()
            .is_empty()
    );

    let saved = set_body(
        &mut vault,
        &day.id,
        "Day.\n<!-- memex:topics -->\n[[Alpha~about]]\n[[Ghost~about]]\n",
    );
    let want = "Day.\n<!-- memex:topics -->\n[[Bravo~about]]\n[[Alpha~about]]\n";
    assert_eq!(saved.content_md, want);
    assert_eq!(stored(&vault, &day.id).content_md, want);
    assert_eq!(
        content_version(&vault, &day.id),
        1,
        "a footer render is not a person edit"
    );
    assert_eq!(state(&vault, &day.id), ReviewState::Reviewed);
}

// ---------- AC 11: Q1 stray text below the marker ----------

#[test]
fn stray_text_below_the_marker_moves_into_the_person_section() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "a\n");
    let saved = set_body(
        &mut vault,
        &note.id,
        "a\n<!-- memex:topics -->\nlate thought\n",
    );

    let want = "a\nlate thought\n<!-- memex:topics -->\n";
    assert_eq!(saved.content_md, want);
    assert_eq!(stored(&vault, &note.id).content_md, want);
    assert_eq!(content_version(&vault, &note.id), 2);

    // `a` and `late thought` are now consecutive lines: one paragraph block
    // (#6 grammar), new, from the person, at the new version.
    let rows = blocks_of(&vault, &note.id);
    assert_eq!(block_texts(&rows), vec!["a\nlate thought"]);
    assert_eq!(rows[0].source, "person");
    assert_eq!(rows[0].created_version, saved.version);
    assert_blocks_match_body(&vault, &note.id);
}

#[test]
fn stray_text_after_a_blank_line_becomes_its_own_person_block() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "a\n\n");
    let first = blocks_of(&vault, &note.id);
    let saved = set_body(
        &mut vault,
        &note.id,
        "a\n\n<!-- memex:topics -->\nlate thought\n",
    );

    assert_eq!(
        saved.content_md,
        "a\n\nlate thought\n<!-- memex:topics -->\n"
    );
    assert_eq!(content_version(&vault, &note.id), 2);
    let rows = blocks_of(&vault, &note.id);
    assert_eq!(block_texts(&rows), vec!["a", "late thought"]);
    assert_eq!(rows[0].block_id, first[0].block_id);
    assert_eq!(rows[0].created_version, 1);
    assert_eq!(rows[1].source, "person");
    assert_eq!(rows[1].created_version, 2);
    assert_ne!(rows[1].block_id, rows[0].block_id);
    assert_blocks_match_body(&vault, &note.id);
}

// ---------- AC 12: matched blocks keep source and created_version ----------

#[test]
fn matched_blocks_keep_source_and_created_version_and_new_blocks_get_person() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "Alpha paragraph here.\n");
    let alpha = blocks_of(&vault, &note.id)[0].clone();

    set_body(
        &mut vault,
        &note.id,
        "Alpha paragraph here.\n\nAgent line.\n",
    );
    let rows = blocks_of(&vault, &note.id);
    assert_eq!(rows[1].text, "Agent line.");
    assert_eq!(
        (rows[1].source.as_str(), rows[1].created_version),
        ("person", 2)
    );
    let agent_id = rows[1].block_id.clone();

    // Pretend an agent wrote that block.
    vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET source = 'agent', created_version = 7 WHERE note_id = ? AND block_id = ?",
            params![note.id.as_str(), agent_id],
        )
        .unwrap();

    // A person edit elsewhere.
    let v3 = set_body(
        &mut vault,
        &note.id,
        "Alpha paragraph here!\n\nAgent line.\n",
    );
    assert_eq!(v3.version, 3);
    let rows = blocks_of(&vault, &note.id);
    assert_eq!(
        block_texts(&rows),
        vec!["Alpha paragraph here!", "Agent line."]
    );
    assert_eq!(rows[0].block_id, alpha.block_id);
    assert_eq!(
        (rows[0].source.as_str(), rows[0].created_version),
        ("person", 1)
    );
    assert_eq!(rows[1].block_id, agent_id);
    assert_eq!(
        (rows[1].source.as_str(), rows[1].created_version),
        ("agent", 7),
        "matched agent block keeps its source and created_version"
    );

    // A new block gets `person` and the note's new version.
    let v4 = set_body(
        &mut vault,
        &note.id,
        "Alpha paragraph here!\n\nAgent line.\n\nThird thought.\n",
    );
    assert_eq!(v4.version, 4);
    let rows = blocks_of(&vault, &note.id);
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[1].source, "agent");
    assert_eq!(rows[2].text, "Third thought.");
    assert_eq!(
        (rows[2].source.as_str(), rows[2].created_version),
        ("person", 4)
    );
    assert_blocks_match_body(&vault, &note.id);
}

// ---------- AC 13: rename pass re-syncs daily linkers ----------

#[test]
fn rename_rewrites_daily_linker_and_bumps_its_versions() {
    let (_dir, mut vault) = fresh_vault();
    let topic = create_plain(
        &mut vault,
        "Player Loop",
        "jump, land",
        Some(json!({ "role": "topic" })),
    );
    let day = create_daily(
        &mut vault,
        "2026-09-05",
        "Worked on [[Player Loop]] today.\n",
    );
    let plain = create_plain(&mut vault, "Scratch", "see [[Player Loop]]", None);
    reindex(&mut vault, &topic);
    reindex(&mut vault, &day);
    reindex(&mut vault, &plain);
    let block_before = blocks_of(&vault, &day.id)[0].clone();
    assert_eq!(content_version(&vault, &day.id), 1);

    let renamed = retitle(&mut vault, &topic.id, "Core Loop").unwrap();
    assert_eq!(renamed.title, "Core Loop");

    let day_after = stored(&vault, &day.id);
    assert_eq!(
        day_after.content_md,
        "Worked on [[Core Loop]] today.\n<!-- memex:topics -->\n"
    );
    assert_eq!(day_after.version, 2, "daily linker's notes.version +1");
    assert_eq!(content_version(&vault, &day.id), 2, "content_version +1");
    let rows = blocks_of(&vault, &day.id);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].block_id, block_before.block_id, "same block id");
    assert_eq!(rows[0].text, "Worked on [[Core Loop]] today.");
    assert_blocks_match_body(&vault, &day.id);

    // A role-less linker is rewritten exactly as before: no version bump, no
    // blocks.
    let plain_after = stored(&vault, &plain.id);
    assert_eq!(plain_after.content_md, "see [[Core Loop]]");
    assert_eq!(plain_after.version, 1);
    assert_eq!(row_count(&vault, "blocks", &plain.id), 0);
    assert_eq!(row_count(&vault, "day_reviews", &plain.id), 0);
}

// ---------- AC 14: non-daily notes are untouched by the hook ----------

#[test]
fn non_daily_notes_are_saved_exactly_as_before() {
    let (_dir, mut vault) = fresh_vault();
    let stray = "Plain.\n<!-- memex:topics -->\nlate\n[[X~about]]\n";
    let notes = [
        create_plain(&mut vault, "Role-less", stray, None),
        create_plain(
            &mut vault,
            "A topic",
            stray,
            Some(json!({ "role": "topic" })),
        ),
        create_plain(&mut vault, "2026-09-04", stray, None),
        create_plain(
            &mut vault,
            "Odd role",
            stray,
            Some(json!({ "role": "Daily" })),
        ),
    ];
    // Control: the same body in a daily note is normalized.
    let day = create_daily(&mut vault, "2026-09-05", stray);
    assert_eq!(day.content_md, "Plain.\nlate\n<!-- memex:topics -->\n");
    assert_eq!(row_count(&vault, "blocks", &day.id), 1);
    assert_eq!(row_count(&vault, "day_reviews", &day.id), 1);

    for n in &notes {
        assert_eq!(n.content_md, stray, "{}", n.title);
        assert_eq!(stored(&vault, &n.id).content_md, stray, "{}", n.title);
        assert_eq!(row_count(&vault, "blocks", &n.id), 0, "{}", n.title);
        assert_eq!(row_count(&vault, "day_reviews", &n.id), 0, "{}", n.title);

        let updated = set_body(&mut vault, &n.id, "Plain.\n\nNo marker here");
        assert_eq!(
            updated.content_md, "Plain.\n\nNo marker here",
            "{}",
            n.title
        );
        assert_eq!(row_count(&vault, "blocks", &n.id), 0, "{}", n.title);
        assert_eq!(row_count(&vault, "day_reviews", &n.id), 0, "{}", n.title);
    }
}

// ---------- Implementer additions (lead rulings, WI #7) ----------

struct FixedClock(i64);

impl memex_core::Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// 2026-09-05T12:00Z: the same local date in every test-machine time zone.
const NOON_2026_09_05_UTC: i64 = 1_788_609_600_000;

fn plain_input_untitled(body: &str) -> CreateNote {
    CreateNote {
        title: None,
        content_md: body.into(),
        frontmatter: None,
    }
}

#[test]
fn create_daily_note_without_a_title_defaults_to_today_from_the_clock() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FixedClock(NOON_2026_09_05_UTC);
    assert_eq!(daily::today_with_clock(&clock).to_string(), "2026-09-05");

    let input = CreateNote {
        title: None,
        content_md: "Morning.\n".into(),
        frontmatter: Some(json!({ "role": "daily" })),
    };
    let outcome = notes::create_or_adopt_note(&mut vault, input, Caller::Person, &clock).unwrap();
    assert!(!outcome.adopted, "a fresh daily note is created");
    let note = outcome.note;
    assert_eq!(note.title, "2026-09-05");
    assert_eq!(note.content_md, "Morning.\n<!-- memex:topics -->\n");
    assert_eq!(
        (note.created_at, note.updated_at),
        (NOON_2026_09_05_UTC, NOON_2026_09_05_UTC)
    );
    assert_eq!(stored(&vault, &note.id).title, "2026-09-05");
    assert_eq!(content_version(&vault, &note.id), 1);

    // A role-less note without a title still derives it from the content.
    let plain = notes::create_or_adopt_note(
        &mut vault,
        plain_input_untitled("# Groceries\nmilk"),
        Caller::Person,
        &clock,
    )
    .unwrap();
    assert!(!plain.adopted);
    assert_eq!(plain.note.title, "Groceries");
}

#[test]
fn create_or_adopt_note_reports_adoption_and_trims_the_appended_input() {
    let (_dir, mut vault) = fresh_vault();
    let clock = FixedClock(NOON_2026_09_05_UTC);
    let old = create_plain(&mut vault, "2026-09-05", "old\n", None);
    let outcome = notes::create_or_adopt_note(
        &mut vault,
        daily_input("2026-09-05", "new\n\n"),
        Caller::Person,
        &clock,
    )
    .unwrap();
    assert!(outcome.adopted);
    assert_eq!(outcome.note.id, old.id);
    assert_eq!(
        outcome.note.content_md, "old\n\nnew\n<!-- memex:topics -->\n",
        "trailing whitespace of the input is trimmed before the C3.1 append"
    );
}

#[test]
fn person_create_daily_over_a_note_with_another_role_fails_with_title_conflict() {
    let (_dir, mut vault) = fresh_vault();
    let topic = create_plain(
        &mut vault,
        "2026-09-05",
        "a topic",
        Some(json!({ "role": "topic" })),
    );
    match create_note_as(&mut vault, daily_input("2026-09-05", "x"), Caller::Person) {
        Err(MemexError::TitleConflict { existing_id, .. }) => {
            assert_eq!(existing_id, topic.id.as_str())
        }
        other => panic!("expected TitleConflict, got {other:?}"),
    }
    let kept = stored(&vault, &topic.id);
    assert_eq!((kept.content_md.as_str(), kept.version), ("a topic", 1));
    assert_eq!(day_review(&vault, &topic.id), None);
}

fn set_frontmatter(
    vault: &mut Vault,
    id: &NoteId,
    title: Option<&str>,
    frontmatter: Value,
) -> Result<Note, MemexError> {
    let version = get_note(vault, id).unwrap().version;
    update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            title: title.map(Into::into),
            frontmatter: Some(frontmatter),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
}

#[test]
fn update_adding_role_daily_validates_and_canonicalizes_like_a_daily_create() {
    let (_dir, mut vault) = fresh_vault();

    // A non-ISO title cannot become a daily note.
    let groceries = create_plain(&mut vault, "Groceries", "milk\n", None);
    match set_frontmatter(&mut vault, &groceries.id, None, json!({ "role": "daily" })) {
        Err(MemexError::InvalidDate(_)) => {}
        other => panic!("expected InvalidDate, got {other:?}"),
    }
    assert_eq!(stored(&vault, &groceries.id).version, 1);
    assert_eq!(day_review(&vault, &groceries.id), None);

    // Retitling onto a date that has a daily note while becoming daily.
    let fifth = create_daily(&mut vault, "2026-09-05", "Five.\n");
    match set_frontmatter(
        &mut vault,
        &groceries.id,
        Some("2026-09-05"),
        json!({ "role": "daily" }),
    ) {
        Err(MemexError::DailyNoteExists { date, existing_id }) => {
            assert_eq!(date, "2026-09-05");
            assert_eq!(existing_id, fifth.id.as_str());
        }
        other => panic!("expected DailyNoteExists, got {other:?}"),
    }

    // An ISO-titled note becomes a daily note: canonical body, blocks, row.
    let day = create_plain(
        &mut vault,
        "2026-09-06",
        "Six.\n<!-- memex:topics -->\nlate\n",
        Some(json!({ "mood": "ok" })),
    );
    let saved = set_frontmatter(
        &mut vault,
        &day.id,
        None,
        json!({ "mood": "ok", "role": "daily" }),
    )
    .unwrap();
    assert_eq!(saved.version, 2);
    assert_eq!(saved.content_md, "Six.\nlate\n<!-- memex:topics -->\n");
    let rows = blocks_of(&vault, &day.id);
    assert_eq!(block_texts(&rows), vec!["Six.\nlate"]);
    assert_eq!(
        (rows[0].source.as_str(), rows[0].created_version),
        ("person", 2)
    );
    assert_eq!(day_review(&vault, &day.id), Some((1, None)));
    assert_blocks_match_body(&vault, &day.id);
}

#[test]
fn retitle_collisions_are_daily_note_exists_only_between_daily_notes() {
    let (_dir, mut vault) = fresh_vault();
    let fifth = create_daily(&mut vault, "2026-09-05", "Five.\n");
    let plain = create_plain(&mut vault, "Scratch", "x", None);
    let held = create_plain(&mut vault, "2026-09-06", "role-less", None);

    // A role-less note retitled onto a daily note's date.
    match retitle(&mut vault, &plain.id, "2026-09-05") {
        Err(MemexError::TitleConflict { existing_id, .. }) => {
            assert_eq!(existing_id, fifth.id.as_str())
        }
        other => panic!("expected TitleConflict, got {other:?}"),
    }
    // A daily note retitled onto a date a role-less note holds.
    match retitle(&mut vault, &fifth.id, "2026-09-06") {
        Err(MemexError::TitleConflict { existing_id, .. }) => {
            assert_eq!(existing_id, held.id.as_str())
        }
        other => panic!("expected TitleConflict, got {other:?}"),
    }
    assert_eq!(stored(&vault, &fifth.id).title, "2026-09-05");
}

#[test]
fn a_daily_note_with_a_legacy_non_iso_title_can_still_be_edited() {
    let (_dir, mut vault) = fresh_vault();
    // Written before the ISO rule existed (e.g. by an older client).
    let note = create_plain(&mut vault, "Monday", "Old day.\n", None);
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET frontmatter = '{\"role\":\"daily\"}' WHERE id = ?",
            [note.id.as_str()],
        )
        .unwrap();

    let saved = set_body(&mut vault, &note.id, "Old day.\n\nMore.\n");
    assert_eq!(saved.title, "Monday");
    assert_eq!(
        saved.content_md,
        "Old day.\n\nMore.\n<!-- memex:topics -->\n"
    );
    // The day_reviews row is created lazily at the first daily write.
    assert_eq!(day_review(&vault, &note.id), Some((1, None)));
    assert_blocks_match_body(&vault, &note.id);
}

#[test]
fn review_state_without_a_day_reviews_row_is_unreviewed() {
    let (_dir, mut vault) = fresh_vault();
    let plain = create_plain(&mut vault, "Scratch", "x", None);
    assert_eq!(state(&vault, &plain.id), ReviewState::Unreviewed);
}

#[test]
fn matched_blocks_keep_their_created_at_and_new_blocks_get_the_write_time() {
    let (_dir, mut vault) = fresh_vault();
    let note = create_daily(&mut vault, "2026-09-05", "Alpha paragraph here.\n");
    let alpha = blocks_of(&vault, &note.id)[0].block_id.clone();
    vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET created_at = 42 WHERE note_id = ?",
            [note.id.as_str()],
        )
        .unwrap();

    set_body(&mut vault, &note.id, "Alpha paragraph here!\n\nNew one.\n");
    let created: Vec<(String, i64)> = {
        let conn = vault.connection_ref();
        let mut stmt = conn
            .prepare("SELECT block_id, created_at FROM blocks WHERE note_id = ? ORDER BY ord")
            .unwrap();
        stmt.query_map([note.id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(created[0], (alpha, 42));
    assert!(created[1].1 > 42, "{created:?}");
}
