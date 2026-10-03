//! WI #8 (R5): footer chips (D11) and the person-only checked delete (D24).
//!
//! - `footer::set_chip` / `footer::remove_chip` maintain `footer_chips`
//!   (origin precedence person > excerpt; an upgrade keeps the rowid) and
//!   re-render the daily note's Topics footer from those rows in rowid order.
//!   They bump `notes.version` and `updated_at`, never
//!   `day_reviews.content_version` or the review state (Req 19), and reindex
//!   the daily note from the stored body (D8).
//! - `daily_note_id` must be `role: daily`, `topic_note_id` `role: topic`,
//!   else `RoleRule`; unknown ids are `NotFound`.
//! - A person save with a stale footer stores the footer rendered from the
//!   records (AC 11).
//! - `notes::delete_note_checked` (D24): `expected_version` check, search
//!   indexes purged before the delete, cascades, and every daily footer that
//!   showed a deleted topic re-rendered.
//!
//! Real SQLite, real schema V5, temp vaults only.

use memex_core::canvas::SystemClock;
use memex_core::daily::{self, ReviewState};
use memex_core::error::MemexError;
use memex_core::footer::{self, ChipOrigin, FooterWrite, RemoveMode};
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, delete_note_checked, get_note, update_note_as, CreateNote, Note, NoteId,
    RenameOptions, UpdateNote,
};
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::smart_folders;
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
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
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note
}

fn create_daily(vault: &mut Vault, date: &str, body: &str) -> Note {
    create(vault, date, body, Some(json!({ "role": "daily" })))
}

fn create_topic(vault: &mut Vault, title: &str) -> Note {
    create(
        vault,
        title,
        &format!("All about {title}.\n"),
        Some(json!({ "role": "topic" })),
    )
}

fn set(vault: &mut Vault, daily: &NoteId, topic: &NoteId, origin: ChipOrigin) -> FooterWrite {
    footer::set_chip(vault, daily, topic, origin, None)
        .unwrap_or_else(|e| panic!("set_chip {daily} {topic} {origin:?}: {e}"))
}

fn remove(vault: &mut Vault, daily: &NoteId, topic: &NoteId, mode: RemoveMode) -> FooterWrite {
    footer::remove_chip(vault, daily, topic, mode, None)
        .unwrap_or_else(|e| panic!("remove_chip {daily} {topic} {mode:?}: {e}"))
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    get_note(vault, id).unwrap()
}

/// `(topic_note_id, origin)` of a daily note's chips, in rowid order.
fn chip_rows(vault: &Vault, daily: &NoteId) -> Vec<(String, String)> {
    vault
        .connection_ref()
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap()
        .query_map([daily.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn chip_rowid(vault: &Vault, daily: &NoteId, topic: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT rowid FROM footer_chips WHERE daily_note_id = ? AND topic_note_id = ?",
            [daily.as_str(), topic.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

fn all_chip_count(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM footer_chips", [], |r| r.get(0))
        .unwrap()
}

/// The chip titles in the stored body's footer.
fn footer_titles(vault: &Vault, id: &NoteId) -> Vec<String> {
    daily::split_body(&stored(vault, id).content_md).chips
}

fn content_version(vault: &Vault, id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("no day_reviews row for {id}: {e}"))
}

fn mark_reviewed(vault: &Vault, id: &NoteId) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE day_reviews SET reviewed_content_version = content_version, reviewed_at = 1
             WHERE note_id = ?",
            [id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1);
    assert_eq!(review_state(vault, id), ReviewState::Reviewed);
}

fn review_state(vault: &Vault, id: &NoteId) -> ReviewState {
    daily::review_state(vault.connection_ref(), id.as_str()).unwrap()
}

/// Moves `updated_at` into the past so "advances" is deterministic.
fn age(vault: &Vault, id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET updated_at = updated_at - 60000 WHERE id = ?",
            [id.as_str()],
        )
        .unwrap();
    stored(vault, id).updated_at
}

/// `(block_id, text, source, created_version)` in ord order.
fn blocks_of(vault: &Vault, id: &NoteId) -> Vec<(String, String, String, i64)> {
    vault
        .connection_ref()
        .prepare(
            "SELECT block_id, text, source, created_version FROM blocks WHERE note_id = ? ORDER BY ord",
        )
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// `(link_text, link_kind, to_note_id)` of a note's outgoing links.
fn links_from(vault: &Vault, id: &NoteId) -> Vec<(String, String, Option<String>)> {
    vault
        .connection_ref()
        .prepare(
            "SELECT link_text, link_kind, to_note_id FROM links WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn count_where(vault: &Vault, table: &str, column: &str, id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            &format!("SELECT COUNT(*) FROM {table} WHERE {column} = ?"),
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

fn fts_hits(vault: &Vault, word: &str) -> Vec<String> {
    search(
        vault.connection_ref(),
        SearchOptions {
            query: word,
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

fn add_agent_change(vault: &Vault, id: &NoteId) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES (?, ?, '2026-10-01', 1, '[\"Added a section\"]')",
            params![NoteId::new().as_str(), id.as_str()],
        )
        .unwrap();
}

fn add_review_snapshot(vault: &Vault, id: &NoteId) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
             SELECT note_id, block_id, content_hash, text FROM blocks WHERE note_id = ?",
            [id.as_str()],
        )
        .unwrap();
}

fn person_save(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
    let version = stored(vault, id).version;
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

// ---------- AC 6: set_chip records the chip and re-renders the footer ----------

#[test]
fn set_chip_excerpt_records_the_chip_and_renders_the_footer_line() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n\n- buy milk\n");
    mark_reviewed(&v, &daily.id);
    let cv = content_version(&v, &daily.id);
    let blocks_before = blocks_of(&v, &daily.id);
    let aged = age(&v, &daily.id);

    let out = set(&mut v, &daily.id, &topic.id, ChipOrigin::Excerpt);

    assert_eq!(out.origin, Some(ChipOrigin::Excerpt));
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(topic.id.to_string(), "excerpt".to_string())]
    );
    let note = stored(&v, &daily.id);
    assert_eq!(
        note.content_md,
        "Morning pages.\n\n- buy milk\n<!-- memex:topics -->\n[[Player Loop~about]]\n"
    );
    assert!(note
        .content_md
        .ends_with("<!-- memex:topics -->\n[[Player Loop~about]]\n"));
    assert_eq!(
        note.version,
        daily.version + 1,
        "notes.version goes up by 1"
    );
    assert!(note.updated_at > aged, "updated_at advances");
    assert_eq!(
        out.note.version, note.version,
        "the returned note is the stored one"
    );
    assert_eq!(out.note.content_md, note.content_md);
    assert_eq!(
        content_version(&v, &daily.id),
        cv,
        "content_version unchanged"
    );
    assert_eq!(
        review_state(&v, &daily.id),
        ReviewState::Reviewed,
        "a Reviewed day stays Reviewed"
    );
    assert_eq!(
        blocks_of(&v, &daily.id),
        blocks_before,
        "the person section and its blocks are untouched"
    );
    // The topic note itself is not written.
    assert_eq!(stored(&v, &topic.id).version, topic.version);
}

#[test]
fn set_chip_and_remove_chip_reindex_the_daily_note_from_the_stored_body() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");
    assert!(links_from(&v, &daily.id).is_empty());

    set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);
    assert_eq!(
        links_from(&v, &daily.id),
        vec![(
            "Player Loop".to_string(),
            "about".to_string(),
            Some(topic.id.to_string())
        )],
        "the footer chip is indexed as an about link (D8)"
    );

    remove(&mut v, &daily.id, &topic.id, RemoveMode::AnyOrigin);
    assert!(
        links_from(&v, &daily.id).is_empty(),
        "the removed chip is no longer indexed: {:?}",
        links_from(&v, &daily.id)
    );
}

// ---------- AC 7: rowid order; an upgrade keeps its position ----------

#[test]
fn chips_render_in_insertion_order_and_a_person_upgrade_keeps_its_position() {
    let (_dir, mut v) = fresh_vault();
    let a = create_topic(&mut v, "Alpha");
    let b = create_topic(&mut v, "Bravo");
    let c = create_topic(&mut v, "Charlie");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");

    set(&mut v, &daily.id, &a.id, ChipOrigin::Excerpt);
    let a_rowid = chip_rowid(&v, &daily.id, &a.id);
    set(&mut v, &daily.id, &b.id, ChipOrigin::Excerpt);
    assert_eq!(footer_titles(&v, &daily.id), ["Alpha", "Bravo"]);

    let out = set(&mut v, &daily.id, &a.id, ChipOrigin::Person);
    assert_eq!(out.origin, Some(ChipOrigin::Person));
    assert_eq!(footer_titles(&v, &daily.id), ["Alpha", "Bravo"]);
    assert_eq!(
        stored(&v, &daily.id).content_md,
        "Day.\n<!-- memex:topics -->\n[[Alpha~about]]\n[[Bravo~about]]\n"
    );
    assert_eq!(
        chip_rowid(&v, &daily.id, &a.id),
        a_rowid,
        "upgrade keeps the rowid"
    );
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![
            (a.id.to_string(), "person".to_string()),
            (b.id.to_string(), "excerpt".to_string()),
        ]
    );

    set(&mut v, &daily.id, &c.id, ChipOrigin::Person);
    assert_eq!(footer_titles(&v, &daily.id), ["Alpha", "Bravo", "Charlie"]);
}

// ---------- AC 8: origin precedence ----------

#[test]
fn excerpt_then_person_stores_person() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");

    set(&mut v, &daily.id, &topic.id, ChipOrigin::Excerpt);
    let out = set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);

    assert_eq!(out.origin, Some(ChipOrigin::Person));
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(topic.id.to_string(), "person".to_string())]
    );
    assert_eq!(footer_titles(&v, &daily.id), ["Player Loop"]);
}

#[test]
fn person_then_excerpt_stays_person() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");

    set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);
    let out = set(&mut v, &daily.id, &topic.id, ChipOrigin::Excerpt);

    assert_eq!(out.origin, Some(ChipOrigin::Person));
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(topic.id.to_string(), "person".to_string())]
    );
    assert_eq!(footer_titles(&v, &daily.id), ["Player Loop"]);
}

#[test]
fn setting_the_same_chip_twice_keeps_one_row_and_one_footer_line() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");

    for origin in [ChipOrigin::Person, ChipOrigin::Person, ChipOrigin::Excerpt] {
        let out = set(&mut v, &daily.id, &topic.id, origin);
        assert_eq!(out.origin, Some(ChipOrigin::Person));
        assert_eq!(out.note.version, stored(&v, &daily.id).version);
    }
    assert_eq!(chip_rows(&v, &daily.id).len(), 1);
    let body = stored(&v, &daily.id).content_md;
    assert_eq!(body.matches("[[Player Loop~about]]").count(), 1, "{body:?}");
}

// ---------- AC 9: remove_chip modes ----------

#[test]
fn remove_chip_excerpt_only_keeps_a_person_chip_and_removes_an_excerpt_chip() {
    let (_dir, mut v) = fresh_vault();
    let kept = create_topic(&mut v, "Kept");
    let gone = create_topic(&mut v, "Gone");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &kept.id, ChipOrigin::Person);
    set(&mut v, &daily.id, &gone.id, ChipOrigin::Excerpt);
    mark_reviewed(&v, &daily.id);
    let cv = content_version(&v, &daily.id);

    let out = remove(&mut v, &daily.id, &kept.id, RemoveMode::ExcerptOnly);
    assert_eq!(
        out.origin,
        Some(ChipOrigin::Person),
        "the person chip stays"
    );
    assert_eq!(footer_titles(&v, &daily.id), ["Kept", "Gone"]);

    let before = stored(&v, &daily.id).version;
    let out = remove(&mut v, &daily.id, &gone.id, RemoveMode::ExcerptOnly);
    assert_eq!(out.origin, None, "the excerpt chip is removed");
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(kept.id.to_string(), "person".to_string())]
    );
    let note = stored(&v, &daily.id);
    assert_eq!(
        note.content_md, "Day.\n<!-- memex:topics -->\n[[Kept~about]]\n",
        "the footer is re-rendered"
    );
    assert_eq!(note.version, before + 1);
    assert_eq!(out.note.version, note.version);
    assert_eq!(
        content_version(&v, &daily.id),
        cv,
        "content_version unchanged"
    );
    assert_eq!(review_state(&v, &daily.id), ReviewState::Reviewed);
}

#[test]
fn remove_chip_any_origin_removes_person_and_excerpt_chips() {
    let (_dir, mut v) = fresh_vault();
    let p = create_topic(&mut v, "Personal");
    let e = create_topic(&mut v, "Excerpted");
    let other = create_topic(&mut v, "Other");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &p.id, ChipOrigin::Person);
    set(&mut v, &daily.id, &e.id, ChipOrigin::Excerpt);
    set(&mut v, &daily.id, &other.id, ChipOrigin::Person);
    let cv = content_version(&v, &daily.id);

    let before = stored(&v, &daily.id).version;
    let out = remove(&mut v, &daily.id, &p.id, RemoveMode::AnyOrigin);
    assert_eq!(out.origin, None);
    assert_eq!(footer_titles(&v, &daily.id), ["Excerpted", "Other"]);
    assert_eq!(stored(&v, &daily.id).version, before + 1);

    let out = remove(&mut v, &daily.id, &e.id, RemoveMode::AnyOrigin);
    assert_eq!(out.origin, None);
    assert_eq!(
        stored(&v, &daily.id).content_md,
        "Day.\n<!-- memex:topics -->\n[[Other~about]]\n"
    );
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(other.id.to_string(), "person".to_string())]
    );
    assert_eq!(
        content_version(&v, &daily.id),
        cv,
        "content_version unchanged"
    );
}

// ---------- AC 10: role checks ----------

#[test]
fn set_chip_with_a_non_daily_daily_note_id_fails_with_role_rule_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let other_topic = create_topic(&mut v, "Sleep");
    let role_less = create(&mut v, "Loose", "Loose body.\n", None);
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");

    for not_daily in [&other_topic, &role_less] {
        for origin in [ChipOrigin::Person, ChipOrigin::Excerpt] {
            let err = footer::set_chip(&mut v, &not_daily.id, &topic.id, origin, None)
                .map(|_| ())
                .unwrap_err();
            assert!(
                matches!(err, MemexError::RoleRule(_)),
                "{} as the daily note: {err:?}",
                not_daily.title
            );
            assert_eq!(err.code(), "role_rule");
            assert!(err.to_string().contains("role"), "{err}");
        }
        assert_eq!(stored(&v, &not_daily.id).version, not_daily.version);
        assert_eq!(stored(&v, &not_daily.id).content_md, not_daily.content_md);
    }
    assert_eq!(all_chip_count(&v), 0, "nothing recorded");
    assert_eq!(stored(&v, &topic.id).version, topic.version);

    // The same topic on a real daily note is fine.
    set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);
    assert_eq!(all_chip_count(&v), 1);
}

#[test]
fn set_chip_with_a_non_topic_topic_note_id_fails_with_role_rule_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let role_less = create(&mut v, "Loose", "Loose body.\n", None);
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let other_daily = create_daily(&mut v, "2026-10-02", "Next day.\n");
    let topic = create_topic(&mut v, "Player Loop");

    for not_topic in [&role_less, &other_daily] {
        let err = footer::set_chip(&mut v, &daily.id, &not_topic.id, ChipOrigin::Person, None)
            .map(|_| ())
            .unwrap_err();
        assert!(
            matches!(err, MemexError::RoleRule(_)),
            "{} as the topic: {err:?}",
            not_topic.title
        );
        assert_eq!(err.code(), "role_rule");
        assert!(err.to_string().contains("role"), "{err}");
        assert_eq!(stored(&v, &not_topic.id).version, not_topic.version);
    }
    assert_eq!(all_chip_count(&v), 0, "nothing recorded");
    let note = stored(&v, &daily.id);
    assert_eq!(note.version, daily.version, "the daily note is not written");
    assert_eq!(note.content_md, daily.content_md);

    set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);
    assert_eq!(footer_titles(&v, &daily.id), ["Player Loop"]);
}

#[test]
fn set_chip_with_an_unknown_id_fails_with_not_found_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let ghost = NoteId::new();

    for (d, t) in [(&ghost, &topic.id), (&daily.id, &ghost)] {
        let err = footer::set_chip(&mut v, d, t, ChipOrigin::Person, None)
            .map(|_| ())
            .unwrap_err();
        assert!(matches!(err, MemexError::NotFound(_)), "{d} {t}: {err:?}");
        assert_eq!(err.code(), "not_found");
    }
    assert_eq!(all_chip_count(&v), 0);
    assert_eq!(stored(&v, &daily.id).version, daily.version);
}

// ---------- AC 11: person save with a stale footer ----------

#[test]
fn person_save_with_a_stale_footer_stores_the_footer_rendered_from_records() {
    let (_dir, mut v) = fresh_vault();
    let recorded = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &recorded.id, ChipOrigin::Person);
    let cv = content_version(&v, &daily.id);

    // The app submits a body whose footer is stale: the recorded chip is
    // missing and an unrecorded chip line is present.
    let saved = person_save(
        &mut v,
        &daily.id,
        "Day.\n\nMore.\n<!-- memex:topics -->\n[[Unrecorded~about]]\n",
    );

    let want = "Day.\n\nMore.\n<!-- memex:topics -->\n[[Player Loop~about]]\n";
    assert_eq!(saved.content_md, want);
    assert_eq!(stored(&v, &daily.id).content_md, want);
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(recorded.id.to_string(), "person".to_string())],
        "a footer line in the body never creates a record"
    );
    assert_eq!(
        content_version(&v, &daily.id),
        cv + 1,
        "the person text changed"
    );
}

// ---------- AC 14-16 in core: notes::delete_note_checked (D24) ----------

#[test]
fn delete_note_checked_of_a_topic_rerenders_every_daily_footer_that_showed_it() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let other = create_topic(&mut v, "Sleep");
    let d1 = create_daily(&mut v, "2026-10-01", "Day one.\n");
    let d2 = create_daily(&mut v, "2026-10-02", "Day two.\n");
    let untouched = create_daily(&mut v, "2026-10-03", "Day three.\n");
    set(&mut v, &d1.id, &topic.id, ChipOrigin::Person);
    set(&mut v, &d1.id, &other.id, ChipOrigin::Excerpt);
    set(&mut v, &d2.id, &other.id, ChipOrigin::Person);
    set(&mut v, &d2.id, &topic.id, ChipOrigin::Excerpt);
    set(&mut v, &untouched.id, &other.id, ChipOrigin::Person);
    mark_reviewed(&v, &d1.id);
    let before: Vec<(NoteId, i64, i64)> = [&d1, &d2, &untouched]
        .iter()
        .map(|d| {
            (
                d.id.clone(),
                stored(&v, &d.id).version,
                content_version(&v, &d.id),
            )
        })
        .collect();

    let topic_version = stored(&v, &topic.id).version;
    delete_note_checked(&mut v, &topic.id, topic_version, None).expect("delete topic");

    assert!(matches!(
        get_note(&v, &topic.id),
        Err(MemexError::NotFound(_))
    ));
    assert_eq!(
        count_where(&v, "footer_chips", "topic_note_id", &topic.id),
        0
    );
    assert_eq!(
        stored(&v, &d1.id).content_md,
        "Day one.\n<!-- memex:topics -->\n[[Sleep~about]]\n"
    );
    assert_eq!(
        stored(&v, &d2.id).content_md,
        "Day two.\n<!-- memex:topics -->\n[[Sleep~about]]\n"
    );
    for (id, version, cv) in &before[..2] {
        assert_eq!(stored(&v, id).version, version + 1, "{id}: version + 1");
        assert_eq!(
            content_version(&v, id),
            *cv,
            "{id}: content_version unchanged"
        );
        assert!(
            !links_from(&v, id).iter().any(|l| l.0 == "Player Loop"),
            "{id} is reindexed: no link to the deleted topic remains: {:?}",
            links_from(&v, id)
        );
    }
    assert_eq!(review_state(&v, &d1.id), ReviewState::Reviewed);
    let (id, version, _) = &before[2];
    assert_eq!(
        stored(&v, id).version,
        *version,
        "a daily note without the chip is not written"
    );
    assert_eq!(footer_titles(&v, id), ["Sleep"]);
}

#[test]
fn delete_note_checked_of_a_topic_removes_memberships_and_change_entries() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let keep = create_topic(&mut v, "Sleep");
    let folder =
        smart_folders::create_folder(&mut v, "Games", None, Caller::Person, &SystemClock).unwrap();
    for t in [&topic, &keep] {
        smart_folders::add_member(
            &mut v,
            &folder.id,
            t.id.as_str(),
            None,
            Caller::Person,
            None,
        )
        .unwrap();
        add_agent_change(&v, &t.id);
    }
    assert_eq!(
        count_where(&v, "smart_folder_members", "note_id", &topic.id),
        1
    );
    assert_eq!(count_where(&v, "agent_changes", "note_id", &topic.id), 1);

    let version = stored(&v, &topic.id).version;
    delete_note_checked(&mut v, &topic.id, version, None).expect("delete topic");

    assert_eq!(
        count_where(&v, "smart_folder_members", "note_id", &topic.id),
        0
    );
    assert_eq!(count_where(&v, "agent_changes", "note_id", &topic.id), 0);
    assert_eq!(
        count_where(&v, "smart_folder_members", "note_id", &keep.id),
        1
    );
    assert_eq!(count_where(&v, "agent_changes", "note_id", &keep.id), 1);
}

#[test]
fn delete_note_checked_of_a_daily_note_purges_search_indexes_and_dependent_rows() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(
        &mut v,
        "2026-10-01",
        "Saw a quokka at dawn.\n\nSecond thought.\n",
    );
    let neighbour = create_daily(&mut v, "2026-10-02", "Nothing unusual.\n");
    set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);
    add_review_snapshot(&v, &daily.id);
    add_agent_change(&v, &daily.id);
    let tables = [
        ("blocks", "note_id"),
        ("day_reviews", "note_id"),
        ("day_review_blocks", "note_id"),
        ("footer_chips", "daily_note_id"),
        ("agent_changes", "note_id"),
        ("chunks", "note_id"),
        ("chunk_fts", "note_id"),
    ];
    for (table, column) in tables {
        assert!(
            count_where(&v, table, column, &daily.id) > 0,
            "setup: {table} has rows for the daily note"
        );
    }
    assert_eq!(fts_hits(&v, "quokka"), [daily.id.to_string()]);

    let version = stored(&v, &daily.id).version;
    delete_note_checked(&mut v, &daily.id, version, None).expect("delete daily");

    assert!(matches!(
        get_note(&v, &daily.id),
        Err(MemexError::NotFound(_))
    ));
    for (table, column) in tables {
        assert_eq!(
            count_where(&v, table, column, &daily.id),
            0,
            "{table} rows of the deleted note"
        );
    }
    assert!(fts_hits(&v, "quokka").is_empty());
    // Other notes keep their rows.
    assert!(count_where(&v, "chunk_fts", "note_id", &neighbour.id) > 0);
    assert!(count_where(&v, "blocks", "note_id", &neighbour.id) > 0);
    assert_eq!(stored(&v, &topic.id).version, topic.version);
}

#[test]
fn delete_note_checked_with_a_stale_version_fails_with_version_conflict_and_keeps_the_note() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &topic.id, ChipOrigin::Person);
    let current = stored(&v, &topic.id).version;

    for stale in [current - 1, current + 1] {
        let err = delete_note_checked(&mut v, &topic.id, stale, None).unwrap_err();
        match err {
            MemexError::VersionConflict {
                expected,
                current: c,
            } => {
                assert_eq!(expected, stale);
                assert_eq!(c, current);
            }
            other => panic!("expected VersionConflict, got {other:?}"),
        }
    }
    assert_eq!(
        stored(&v, &topic.id).version,
        current,
        "the note still exists"
    );
    assert_eq!(footer_titles(&v, &daily.id), ["Player Loop"]);
    assert!(count_where(&v, "chunk_fts", "note_id", &topic.id) > 0);
}

#[test]
fn delete_note_checked_of_an_unknown_id_fails_with_not_found() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let err = delete_note_checked(&mut v, &NoteId::new(), 1, None).unwrap_err();
    assert!(matches!(err, MemexError::NotFound(_)), "{err:?}");
    assert_eq!(err.code(), "not_found");
    assert_eq!(stored(&v, &topic.id).version, topic.version);
}
