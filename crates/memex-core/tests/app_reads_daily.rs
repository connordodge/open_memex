//! WI #82 (V2): the daily reads of the app API (`app_reads::daily`) hold the
//! rules of the app's local `DailyReads` (app/lib/src/db/daily_reads.dart):
//!
//! - a daily note is a note whose frontmatter is valid JSON with `role`
//!   exactly `daily`;
//! - `preview` is the first block's text (by `ord`) up to its first `\n`;
//! - review state comes from the `day_reviews` row: no row, or a NULL
//!   `reviewed_content_version`, is `Unreviewed`; `reviewed_at` is the row's
//!   value as stored;
//! - `daily_note_for_date` is a plain title match with no date validation;
//! - blocks come in `ord` order, footer chips in rowid order.
//!
//! The vault server's fixture rows (`crates/memex-mcp/tests/api_daily.rs`)
//! check the same reads on #74's seed; these cases add the edge rows the seed
//! has no room for, written straight into a fresh vault's tables.
//!
//! API under test (memex_core::app_reads::daily):
//!   daily_notes(&Vault) -> Result<Vec<DailyNoteRow>>
//!   daily_note_for_date(&Vault, &str) -> Result<Option<DailyNoteRow>>
//!   review_info(&Vault, &str) -> Result<ReviewInfo>
//!   blocks_for_note(&Vault, &str) -> Result<Vec<BlockRow>>
//!   footer_chips(&Vault, &str) -> Result<Vec<FooterChipRow>>

use memex_core::app_reads::daily::{
    blocks_for_note, daily_note_for_date, daily_notes, footer_chips, review_info, BlockRow,
    DailyNoteRow, FooterChipRow, ReviewInfo,
};
use memex_core::Vault;
use rusqlite::params;
use tempfile::TempDir;

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn note(vault: &Vault, id: &str, title: &str, frontmatter: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES (?, ?, '', ?, 1, 1760000000000, 1760000000000)",
            params![id, title, frontmatter],
        )
        .unwrap();
}

fn block(vault: &Vault, note_id: &str, block_id: &str, ord: i64, text: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text,
                                 content_hash, source, created_version, created_at)
             VALUES (?, ?, ?, ?, ?, ?, 'hash', 'agent', ?, ?)",
            params![
                note_id,
                block_id,
                ord,
                ord * 100,
                ord * 100 + text.len() as i64,
                text,
                ord + 1,
                1760000000000 + ord
            ],
        )
        .unwrap();
}

fn review_row(vault: &Vault, note_id: &str, current: i64, reviewed: Option<i64>, at: Option<i64>) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO day_reviews (note_id, content_version, reviewed_content_version, reviewed_at)
             VALUES (?, ?, ?, ?)",
            params![note_id, current, reviewed, at],
        )
        .unwrap();
}

fn chip(vault: &Vault, daily: &str, topic: &str, origin: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, ?, 1760000000000)",
            params![daily, topic, origin],
        )
        .unwrap();
}

fn row(date: &str, note_id: &str, preview: &str, state: &str) -> DailyNoteRow {
    DailyNoteRow {
        date: date.into(),
        note_id: note_id.into(),
        preview: preview.into(),
        review_state: state.into(),
    }
}

const DAILY: &str = r#"{"role":"daily"}"#;

/// A vault with three daily notes in every review state, plus notes that
/// only look daily.
fn mixed_vault() -> (TempDir, Vault) {
    let (dir, vault) = fresh_vault();
    note(&vault, "D01", "2026-10-01", DAILY);
    note(
        &vault,
        "D03",
        "2026-10-03",
        r#"{"role":"daily","tags":["x"]}"#,
    );
    note(&vault, "D02", "2026-10-02", DAILY);
    // Invalid JSON frontmatter: role-less for every reader.
    note(&vault, "BAD", "2026-10-04", r#"{"role": "daily""#);
    // The role match is exact.
    note(&vault, "CAP", "2026-10-05", r#"{"role":"Daily"}"#);
    note(&vault, "TOP", "Topic", r#"{"role":"topic"}"#);
    note(&vault, "NONE", "2026-10-06", "{}");
    review_row(&vault, "D03", 2, Some(2), Some(1760000300000));
    review_row(&vault, "D02", 3, Some(2), Some(1760000200000));
    block(&vault, "D01", "aaaaaa", 0, "First day.");
    block(&vault, "D02", "bbbbbb", 0, "Second day.");
    block(&vault, "D03", "cccccc", 0, "Third day.");
    block(&vault, "BAD", "dddddd", 0, "Not a day.");
    (dir, vault)
}

#[test]
fn daily_notes_lists_valid_json_role_daily_notes_newest_title_first() {
    let (_dir, vault) = mixed_vault();
    assert_eq!(
        daily_notes(&vault).unwrap(),
        vec![
            row("2026-10-03", "D03", "Third day.", "Reviewed"),
            row("2026-10-02", "D02", "Second day.", "Changed since review"),
            row("2026-10-01", "D01", "First day.", "Unreviewed"),
        ]
    );
}

#[test]
fn daily_notes_is_empty_on_a_vault_without_daily_notes() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "TOP", "Topic", r#"{"role":"topic"}"#);
    assert_eq!(daily_notes(&vault).unwrap(), Vec::<DailyNoteRow>::new());
}

#[test]
fn preview_is_the_first_block_by_ord_cut_at_its_first_newline() {
    let (_dir, vault) = fresh_vault();
    // Inserted out of ord order: the preview follows ord, not rowid.
    note(&vault, "A", "2026-10-01", DAILY);
    block(&vault, "A", "a1a1a1", 1, "Later block.");
    block(&vault, "A", "a0a0a0", 0, "Opening line\nsecond line\nthird");
    // A first block that starts with a newline previews as empty.
    note(&vault, "B", "2026-10-02", DAILY);
    block(&vault, "B", "b0b0b0", 0, "\nhidden");
    // Only `\n` cuts: a `\r` before it stays, as in the app.
    note(&vault, "C", "2026-10-03", DAILY);
    block(&vault, "C", "c0c0c0", 0, "windows line\r\nnext");
    // No blocks (a pre-V5 daily): empty preview.
    note(&vault, "D", "2026-10-04", DAILY);
    // Multi-byte text before the cut.
    note(&vault, "E", "2026-10-05", DAILY);
    block(&vault, "E", "e0e0e0", 0, "caf\u{e9} \u{1F3B2}\nrest");

    let previews: Vec<(String, String)> = daily_notes(&vault)
        .unwrap()
        .into_iter()
        .map(|r| (r.date, r.preview))
        .collect();
    assert_eq!(
        previews,
        vec![
            ("2026-10-05".into(), "caf\u{e9} \u{1F3B2}".into()),
            ("2026-10-04".into(), String::new()),
            ("2026-10-03".into(), "windows line\r".into()),
            ("2026-10-02".into(), String::new()),
            ("2026-10-01".into(), "Opening line".into()),
        ]
    );
}

#[test]
fn daily_note_for_date_is_a_plain_title_match_without_date_validation() {
    let (_dir, vault) = mixed_vault();
    // A daily note whose title is not a date is still found by its title.
    note(&vault, "ODD", "someday", DAILY);
    block(&vault, "ODD", "ffffff", 0, "Odd title.\nmore");

    assert_eq!(
        daily_note_for_date(&vault, "2026-10-02").unwrap(),
        Some(row(
            "2026-10-02",
            "D02",
            "Second day.",
            "Changed since review"
        ))
    );
    assert_eq!(
        daily_note_for_date(&vault, "someday").unwrap(),
        Some(row("someday", "ODD", "Odd title.", "Unreviewed"))
    );
    for miss in [
        "2026-10-09",
        "2026-10-04", // invalid JSON frontmatter
        "2026-10-05", // role "Daily"
        "2026-10-06", // no role
        "Topic",
        "not-a-date",
        "",
        "2026-10-0", // a prefix of a real title
    ] {
        assert_eq!(daily_note_for_date(&vault, miss).unwrap(), None, "{miss:?}");
    }
}

#[test]
fn review_info_maps_every_day_reviews_row_shape() {
    let (_dir, vault) = fresh_vault();
    for (i, id) in ["NOROW", "NULLS", "SAME", "DIFF", "STAMPED"]
        .iter()
        .enumerate()
    {
        note(&vault, id, &format!("2026-10-1{i}"), DAILY);
    }
    review_row(&vault, "NULLS", 1, None, None);
    review_row(&vault, "SAME", 4, Some(4), Some(1760000400000));
    review_row(&vault, "DIFF", 5, Some(4), Some(1760000500000));
    // A stamp without a reviewed version: still Unreviewed, and the stamp is
    // returned as stored (the app reads the column as is).
    review_row(&vault, "STAMPED", 1, None, Some(1760000600000));

    let info = |state: &str, at: Option<i64>| ReviewInfo {
        state: state.into(),
        reviewed_at: at,
    };
    assert_eq!(
        review_info(&vault, "NOROW").unwrap(),
        info("Unreviewed", None)
    );
    assert_eq!(
        review_info(&vault, "NULLS").unwrap(),
        info("Unreviewed", None)
    );
    assert_eq!(
        review_info(&vault, "SAME").unwrap(),
        info("Reviewed", Some(1760000400000))
    );
    assert_eq!(
        review_info(&vault, "DIFF").unwrap(),
        info("Changed since review", Some(1760000500000))
    );
    assert_eq!(
        review_info(&vault, "STAMPED").unwrap(),
        info("Unreviewed", Some(1760000600000))
    );
    // An id no note has: no row, so Unreviewed (as the local read).
    assert_eq!(
        review_info(&vault, "01J9Z8Y7X6W5V4T3S2R1Q0P9N8").unwrap(),
        info("Unreviewed", None)
    );
}

#[test]
fn blocks_for_note_returns_all_eight_fields_in_ord_order() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "A", "2026-10-01", DAILY);
    note(&vault, "B", "2026-10-02", DAILY);
    block(&vault, "A", "k2k2k2", 2, "Third.");
    block(&vault, "A", "k0k0k0", 0, "First.\nwith a second line");
    block(&vault, "B", "zzzzzz", 0, "Other note.");
    block(&vault, "A", "k1k1k1", 1, "Second.");

    let want = |id: &str, ord: i64, text: &str| BlockRow {
        block_id: id.into(),
        ord,
        text: text.into(),
        source: "agent".into(),
        created_version: ord + 1,
        created_at: 1760000000000 + ord,
        start_byte: ord * 100,
        end_byte: ord * 100 + text.len() as i64,
    };
    assert_eq!(
        blocks_for_note(&vault, "A").unwrap(),
        vec![
            want("k0k0k0", 0, "First.\nwith a second line"),
            want("k1k1k1", 1, "Second."),
            want("k2k2k2", 2, "Third."),
        ]
    );
    assert_eq!(
        blocks_for_note(&vault, "NOPE").unwrap(),
        Vec::<BlockRow>::new()
    );
}

#[test]
fn footer_chips_come_in_rowid_order_with_their_topic_titles() {
    let (_dir, vault) = fresh_vault();
    note(&vault, "DAY", "2026-10-01", DAILY);
    note(&vault, "OTHERDAY", "2026-10-02", DAILY);
    // Ids and titles both sort opposite to insertion order.
    note(&vault, "T9", "Alpha", r#"{"role":"topic"}"#);
    note(&vault, "T5", "Middle", r#"{"role":"topic"}"#);
    note(&vault, "T1", "Zeta", r#"{"role":"topic"}"#);
    chip(&vault, "DAY", "T1", "person");
    chip(&vault, "OTHERDAY", "T5", "person");
    chip(&vault, "DAY", "T9", "excerpt");
    chip(&vault, "DAY", "T5", "excerpt");

    let c = |id: &str, title: &str, origin: &str| FooterChipRow {
        topic_note_id: id.into(),
        topic_title: title.into(),
        origin: origin.into(),
    };
    assert_eq!(
        footer_chips(&vault, "DAY").unwrap(),
        vec![
            c("T1", "Zeta", "person"),
            c("T9", "Alpha", "excerpt"),
            c("T5", "Middle", "excerpt"),
        ]
    );
    assert_eq!(
        footer_chips(&vault, "OTHERDAY").unwrap(),
        vec![c("T5", "Middle", "person")]
    );
    assert_eq!(
        footer_chips(&vault, "NOPE").unwrap(),
        Vec::<FooterChipRow>::new()
    );
}

#[test]
fn daily_rows_serialize_with_the_dart_model_field_names() {
    let (_dir, vault) = mixed_vault();
    note(&vault, "TOPIC2", "Topic Two", r#"{"role":"topic"}"#);
    chip(&vault, "D01", "TOPIC2", "person");
    let json = |v: &dyn erased::Ser| v.value();
    assert_eq!(
        json(&daily_note_for_date(&vault, "2026-10-03").unwrap().unwrap()),
        serde_json::json!({
            "date": "2026-10-03",
            "note_id": "D03",
            "preview": "Third day.",
            "review_state": "Reviewed",
        })
    );
    assert_eq!(
        json(&review_info(&vault, "D01").unwrap()),
        serde_json::json!({"state": "Unreviewed", "reviewed_at": null})
    );
    assert_eq!(
        json(&blocks_for_note(&vault, "D01").unwrap()[0]),
        serde_json::json!({
            "block_id": "aaaaaa",
            "ord": 0,
            "text": "First day.",
            "source": "agent",
            "created_version": 1,
            "created_at": 1760000000000_i64,
            "start_byte": 0,
            "end_byte": 10,
        })
    );
    assert_eq!(
        json(&footer_chips(&vault, "D01").unwrap()[0]),
        serde_json::json!({
            "topic_note_id": "TOPIC2",
            "topic_title": "Topic Two",
            "origin": "person",
        })
    );
}

/// `serde_json::to_value` behind a trait object, so one helper takes every
/// row type.
mod erased {
    pub trait Ser {
        fn value(&self) -> serde_json::Value;
    }

    impl<T: serde::Serialize> Ser for T {
        fn value(&self) -> serde_json::Value {
            serde_json::to_value(self).expect("row serializes")
        }
    }
}
