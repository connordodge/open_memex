//! WI #8 (R5): footer chips (D11) and the person-only checked delete (D24).
//!
//! - `footer::set_chip` / `footer::remove_chip` maintain `footer_chips`
//!   (origin precedence person > excerpt; an upgrade keeps the rowid) and
//!   re-render the daily note's Topics footer from those rows in rowid order.
//!   They bump `notes.version` and `updated_at`, never
//!   `day_reviews.content_version` or the review state (Req 19), and reindex
//!   the daily note from the stored body (D8).
//! - `topic_note_id` must be `role: topic`, else `RoleRule`; unknown ids are
//!   `NotFound`. Since WI #238 the host may be any note but a guide (see the
//!   WI #238 section at the end).
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

/// Lead ruling: a set that changes nothing (the same origin again, or
/// `excerpt` over `person`) writes nothing and returns the effective origin.
#[test]
fn setting_a_chip_that_is_already_stored_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let p = create_topic(&mut v, "Personal");
    let e = create_topic(&mut v, "Excerpted");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &p.id, ChipOrigin::Person);
    set(&mut v, &daily.id, &e.id, ChipOrigin::Excerpt);
    let aged = age(&v, &daily.id);
    let before = stored(&v, &daily.id);

    for (topic, origin, want) in [
        (&p, ChipOrigin::Person, ChipOrigin::Person),
        (&p, ChipOrigin::Excerpt, ChipOrigin::Person),
        (&e, ChipOrigin::Excerpt, ChipOrigin::Excerpt),
    ] {
        let out = set(&mut v, &daily.id, &topic.id, origin);
        assert_eq!(out.origin, Some(want), "{} {origin:?}", topic.title);
        assert_eq!(out.note.version, before.version, "no version bump");
        assert_eq!(out.note.content_md, before.content_md);
        let now = stored(&v, &daily.id);
        assert_eq!(now.version, before.version, "{} {origin:?}", topic.title);
        assert_eq!(now.updated_at, aged, "not written");
    }
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![
            (p.id.to_string(), "person".to_string()),
            (e.id.to_string(), "excerpt".to_string()),
        ]
    );
}

/// Lead ruling: removing a chip that is not there, or one `ExcerptOnly`
/// keeps, writes nothing and returns the origin that remains.
#[test]
fn remove_chip_that_removes_nothing_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let p = create_topic(&mut v, "Personal");
    let absent = create_topic(&mut v, "Absent");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &p.id, ChipOrigin::Person);
    let aged = age(&v, &daily.id);
    let before = stored(&v, &daily.id);

    for (topic, mode, want) in [
        (&absent, RemoveMode::AnyOrigin, None),
        (&absent, RemoveMode::ExcerptOnly, None),
        (&p, RemoveMode::ExcerptOnly, Some(ChipOrigin::Person)),
    ] {
        let out = remove(&mut v, &daily.id, &topic.id, mode);
        assert_eq!(out.origin, want, "{} {mode:?}", topic.title);
        assert_eq!(out.note.version, before.version);
        let now = stored(&v, &daily.id);
        assert_eq!(now.version, before.version, "{} {mode:?}", topic.title);
        assert_eq!(now.updated_at, aged, "not written");
        assert_eq!(now.content_md, before.content_md);
    }
    assert_eq!(
        chip_rows(&v, &daily.id),
        vec![(p.id.to_string(), "person".to_string())]
    );

    // WI #238: any note but a guide may hold chips, so removing a chip a
    // plain note doesn't hold is a no-op too.
    let plain = create(&mut v, "Loose", "Loose body.\n", None);
    let out = remove(&mut v, &plain.id, &p.id, RemoveMode::AnyOrigin);
    assert_eq!(out.origin, None);
    assert_eq!(stored(&v, &plain.id).version, plain.version);
    assert_eq!(stored(&v, &plain.id).content_md, plain.content_md);
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

// ===========================================================================
// WI #238 (T2): the Note footer on every note (Spec #234 R10-R17, R53;
// rulings D10, D13, D14, D15, D18).
//
// - Any note but `role: guide` may hold chips (`guide_rule`); the target must
//   be `role: topic` (`role_rule`); a note can't chip itself
//   (`Io(InvalidInput)`, the core's invalid-argument error).
// - The footer is rendered from rows: chip lines in rowid order, then one
//   `#name` line per non-system `tags` row with origin `agent` or `person`,
//   sorted by name. Footer tag lines in a saved body are dropped.
// - A non-daily note has a marker only while its footer has content.
// ===========================================================================

const M: &str = "<!-- memex:topics -->";

fn create_plain(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, None)
}

fn create_guide(vault: &mut Vault, body: &str) -> Note {
    create(vault, "Vault Guide", body, Some(json!({ "role": "guide" })))
}

/// A `tags` row written straight to the table, as T3's write paths do. It
/// replaces the row a person save already derived from the note's text.
fn tag_row(vault: &Vault, id: &NoteId, tag: &str, origin: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tags (note_id, tag, origin) VALUES (?, ?, ?)
             ON CONFLICT (note_id, tag) DO UPDATE SET origin = excluded.origin",
            params![id.as_str(), tag, origin],
        )
        .unwrap();
}

fn drop_tag_row(vault: &Vault, id: &NoteId, tag: &str) {
    let n = vault
        .connection_ref()
        .execute(
            "DELETE FROM tags WHERE note_id = ? AND tag = ?",
            params![id.as_str(), tag],
        )
        .unwrap();
    assert_eq!(n, 1, "setup: {tag} was a row");
}

/// `(tag, origin)` of a note's `tags` rows, by tag.
fn tag_rows(vault: &Vault, id: &NoteId) -> Vec<(String, String)> {
    vault
        .connection_ref()
        .prepare("SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// A `footer_chips` row written straight to the table (no re-render).
fn chip_row(vault: &Vault, host: &NoteId, topic: &NoteId, origin: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, ?, 0)",
            params![host.as_str(), topic.as_str(), origin],
        )
        .unwrap();
}

/// The body holds only the person text `person`, with no marker (a final
/// newline may remain or go, R11).
fn assert_person_only(body: &str, person: &str, what: &str) {
    assert!(!body.contains(M), "{what}: no marker left: {body:?}");
    assert_eq!(
        body.trim_end_matches('\n'),
        person.trim_end_matches('\n'),
        "{what}: the person text is kept"
    );
}

fn assert_guide_rule(result: Result<FooterWrite, MemexError>, what: &str) {
    let err = result.map(|_| ()).unwrap_err();
    assert!(matches!(err, MemexError::GuideRule(_)), "{what}: {err:?}");
    assert_eq!(err.code(), "guide_rule", "{what}");
}

// ---------- AC 7: set_chip on any note but a guide ----------

#[test]
fn set_chip_works_on_a_topic_note_and_a_plain_note_and_upgrades_in_place() {
    let (_dir, mut v) = fresh_vault();
    let target = create_topic(&mut v, "Player Loop");
    let other = create_topic(&mut v, "Sleep");
    let host_topic = create_topic(&mut v, "Game Design");
    let plain = create_plain(&mut v, "Loose", "Loose body.\n");

    // A topic note holds chips: an excerpt chip, then a person chip.
    let out = set(&mut v, &host_topic.id, &target.id, ChipOrigin::Excerpt);
    assert_eq!(out.origin, Some(ChipOrigin::Excerpt));
    let first = stored(&v, &host_topic.id);
    assert_eq!(
        first.content_md,
        format!("All about Game Design.\n{M}\n[[Player Loop~about]]\n")
    );
    assert_eq!(first.version, host_topic.version + 1);
    assert_eq!(
        out.note.content_md, first.content_md,
        "returns the stored note"
    );
    let rowid = chip_rowid(&v, &host_topic.id, &target.id);
    set(&mut v, &host_topic.id, &other.id, ChipOrigin::Person);

    // excerpt -> person upgrades in place and keeps its position.
    let out = set(&mut v, &host_topic.id, &target.id, ChipOrigin::Person);
    assert_eq!(out.origin, Some(ChipOrigin::Person));
    assert_eq!(chip_rowid(&v, &host_topic.id, &target.id), rowid);
    assert_eq!(
        chip_rows(&v, &host_topic.id),
        vec![
            (target.id.to_string(), "person".to_string()),
            (other.id.to_string(), "person".to_string()),
        ]
    );
    assert_eq!(
        stored(&v, &host_topic.id).content_md,
        format!("All about Game Design.\n{M}\n[[Player Loop~about]]\n[[Sleep~about]]\n")
    );
    // person over person, excerpt over person: nothing written.
    let before = stored(&v, &host_topic.id).version;
    for origin in [ChipOrigin::Person, ChipOrigin::Excerpt] {
        let out = set(&mut v, &host_topic.id, &target.id, origin);
        assert_eq!(out.origin, Some(ChipOrigin::Person));
        assert_eq!(stored(&v, &host_topic.id).version, before, "{origin:?}");
    }

    // A plain (role-less) note holds chips too, and is reindexed (D8).
    let out = set(&mut v, &plain.id, &target.id, ChipOrigin::Person);
    assert_eq!(out.origin, Some(ChipOrigin::Person));
    let note = stored(&v, &plain.id);
    assert_eq!(
        note.content_md,
        format!("Loose body.\n{M}\n[[Player Loop~about]]\n")
    );
    assert_eq!(note.version, plain.version + 1);
    assert_eq!(
        links_from(&v, &plain.id),
        vec![(
            "Player Loop".to_string(),
            "about".to_string(),
            Some(target.id.to_string())
        )]
    );

    // The targets are not written, and no review rows appear.
    assert_eq!(stored(&v, &target.id).version, target.version);
    for id in [&host_topic.id, &plain.id] {
        assert_eq!(count_where(&v, "day_reviews", "note_id", id), 0);
    }
}

#[test]
fn set_chip_and_remove_chip_on_a_guide_note_fail_with_guide_rule_and_write_nothing() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let held = create_topic(&mut v, "Sleep");
    let guide = create_guide(&mut v, "How this vault works.\n");
    // A chip row left on the guide from before (no path writes one now).
    chip_row(&v, &guide.id, &held.id, "person");

    for origin in [ChipOrigin::Person, ChipOrigin::Excerpt] {
        assert_guide_rule(
            footer::set_chip(&mut v, &guide.id, &topic.id, origin, None),
            &format!("set_chip {origin:?}"),
        );
    }
    for mode in [RemoveMode::AnyOrigin, RemoveMode::ExcerptOnly] {
        assert_guide_rule(
            footer::remove_chip(&mut v, &guide.id, &held.id, mode, None),
            &format!("remove_chip {mode:?}"),
        );
    }
    let after = stored(&v, &guide.id);
    assert_eq!(after.content_md, "How this vault works.\n");
    assert_eq!(after.version, guide.version);
    assert_eq!(
        chip_rows(&v, &guide.id),
        vec![(held.id.to_string(), "person".to_string())],
        "nothing recorded or removed"
    );
}

#[test]
fn set_chip_with_a_non_topic_target_fails_with_role_rule_on_any_host() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let other_daily = create_daily(&mut v, "2026-10-02", "Next.\n");
    let host_topic = create_topic(&mut v, "Game Design");
    let plain = create_plain(&mut v, "Loose", "Loose body.\n");
    let other_plain = create_plain(&mut v, "Other", "Other body.\n");

    for host in [&daily, &host_topic, &plain] {
        for target in [&other_plain, &other_daily] {
            let err = footer::set_chip(&mut v, &host.id, &target.id, ChipOrigin::Person, None)
                .map(|_| ())
                .unwrap_err();
            assert!(
                matches!(err, MemexError::RoleRule(_)),
                "{} <- {}: {err:?}",
                host.title,
                target.title
            );
            assert_eq!(err.code(), "role_rule");
        }
        let after = stored(&v, &host.id);
        assert_eq!(after.version, host.version, "{} not written", host.title);
        assert_eq!(after.content_md, host.content_md);
    }
    assert_eq!(all_chip_count(&v), 0, "nothing recorded");
}

#[test]
fn set_chip_of_a_note_on_itself_fails_with_invalid_input_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let other = create_topic(&mut v, "Sleep");

    for origin in [ChipOrigin::Person, ChipOrigin::Excerpt] {
        let err = footer::set_chip(&mut v, &topic.id, &topic.id, origin, None)
            .map(|_| ())
            .unwrap_err();
        match &err {
            MemexError::Io(io) => assert_eq!(
                io.kind(),
                std::io::ErrorKind::InvalidInput,
                "{origin:?}: {err:?}"
            ),
            other => panic!("{origin:?}: expected Io(InvalidInput), got {other:?}"),
        }
    }
    assert_eq!(all_chip_count(&v), 0, "nothing recorded");
    let after = stored(&v, &topic.id);
    assert_eq!(after.version, topic.version);
    assert_eq!(after.content_md, topic.content_md);

    // The same topic chips another topic fine.
    set(&mut v, &topic.id, &other.id, ChipOrigin::Person);
    assert_eq!(all_chip_count(&v), 1);
}

// ---------- AC 8: footer writes move version + updated_at only ----------

#[test]
fn footer_writes_on_any_note_move_version_and_updated_at_but_never_content_version_or_review_state()
{
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n\n- buy milk\n");
    let host_topic = create_topic(&mut v, "Game Design");
    let plain = create_plain(&mut v, "Loose", "Loose body.\n");
    mark_reviewed(&v, &daily.id);
    let cv = content_version(&v, &daily.id);
    let blocks = blocks_of(&v, &daily.id);

    for host in [&daily, &host_topic, &plain] {
        for step in ["set", "remove"] {
            let aged = age(&v, &host.id);
            let version = stored(&v, &host.id).version;
            let out = if step == "set" {
                set(&mut v, &host.id, &topic.id, ChipOrigin::Person)
            } else {
                remove(&mut v, &host.id, &topic.id, RemoveMode::AnyOrigin)
            };
            let after = stored(&v, &host.id);
            let what = format!("{} {step}", host.title);
            assert_eq!(after.version, version + 1, "{what}: version + 1");
            assert!(after.updated_at > aged, "{what}: updated_at advances");
            assert_eq!(out.note.version, after.version, "{what}");
        }
    }
    assert_eq!(content_version(&v, &daily.id), cv, "content_version kept");
    assert_eq!(review_state(&v, &daily.id), ReviewState::Reviewed);
    assert_eq!(blocks_of(&v, &daily.id), blocks);
    for id in [&host_topic.id, &plain.id] {
        assert_eq!(
            count_where(&v, "day_reviews", "note_id", id),
            0,
            "a non-daily note gets no review row"
        );
    }
}

// ---------- AC 14: tag rows render as footer tag lines ----------

/// Rows of every origin: only `alpha`, `mid` and `zeta` render.
fn tag_rows_of_every_kind(vault: &Vault, id: &NoteId) {
    tag_row(vault, id, "zeta", "agent");
    tag_row(vault, id, "alpha", "person");
    tag_row(vault, id, "mid", "agent");
    tag_row(vault, id, "written", "body");
    tag_row(vault, id, "inbox", "agent");
    tag_row(vault, id, "agent-authored", "person");
}

#[test]
fn footer_renders_agent_and_person_tag_rows_sorted_by_name_and_never_body_or_system_rows() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day #written.\n");
    let host_topic = create_topic(&mut v, "Game Design");
    let plain = create_plain(&mut v, "Loose", "Loose body.\n");
    let quiet = create_plain(&mut v, "Quiet", "Quiet body.\n");
    for host in [&daily, &host_topic, &plain] {
        tag_rows_of_every_kind(&v, &host.id);
    }
    tag_row(&v, &quiet.id, "written", "body");
    tag_row(&v, &quiet.id, "inbox", "agent");
    tag_row(&v, &quiet.id, "agent-authored", "person");

    // A chip write renders chips first, then the tag lines.
    set(&mut v, &daily.id, &topic.id, ChipOrigin::Excerpt);
    assert_eq!(
        stored(&v, &daily.id).content_md,
        format!("Day #written.\n{M}\n[[Player Loop~about]]\n#alpha\n#mid\n#zeta\n")
    );
    set(&mut v, &host_topic.id, &topic.id, ChipOrigin::Person);
    assert_eq!(
        stored(&v, &host_topic.id).content_md,
        format!("All about Game Design.\n{M}\n[[Player Loop~about]]\n#alpha\n#mid\n#zeta\n")
    );

    // Tags alone are footer content on a non-daily note.
    let saved = person_save(&mut v, &plain.id, "Loose body.\n");
    assert_eq!(
        saved.content_md,
        format!("Loose body.\n{M}\n#alpha\n#mid\n#zeta\n")
    );
    // Only body and system rows: no footer, no marker.
    let saved = person_save(&mut v, &quiet.id, "Quiet body.\n");
    assert_eq!(saved.content_md, "Quiet body.\n");

    // A legacy row outside the grammar still renders as stored.
    tag_row(&v, &plain.id, "Legacy Name", "person");
    let saved = person_save(&mut v, &plain.id, "Loose body.\n");
    assert!(
        saved.content_md.contains("\n#Legacy Name\n"),
        "{:?}",
        saved.content_md
    );
    assert_eq!(
        daily::split_note_body(&saved.content_md).person,
        "Loose body.\n"
    );
}

// ---------- AC 2: a stale footer tag line can't bring a tag back ----------

#[test]
fn person_save_with_a_stale_footer_tag_line_does_not_bring_back_a_removed_tag() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let plain = create_plain(&mut v, "Loose", "Notes.\n");
    for (host, person) in [(&daily, "Day.\n"), (&plain, "Notes.\n")] {
        tag_row(&v, &host.id, "x", "agent");
        tag_row(&v, &host.id, "y", "agent");
        // The client loads the footer as rendered from the rows ...
        let loaded = person_save(&mut v, &host.id, person).content_md;
        assert_eq!(
            loaded,
            format!("{person}{M}\n#x\n#y\n"),
            "{}: rendered",
            host.title
        );
        // ... then `x` is removed while the client still shows it.
        drop_tag_row(&v, &host.id, "x");
        let stale = format!("{person}\nMore.\n{M}\n#x\n#y\n");
        let saved = person_save(&mut v, &host.id, &stale);
        assert_eq!(
            saved.content_md,
            format!("{person}\nMore.\n{M}\n#y\n"),
            "{}: the stale #x line is dropped, not moved",
            host.title
        );
        assert!(
            !saved.content_md.contains("#x"),
            "{}: {:?}",
            host.title,
            saved.content_md
        );
        assert_eq!(
            tag_rows(&v, &host.id),
            vec![("y".to_string(), "agent".to_string())],
            "{}: x stays removed",
            host.title
        );
    }

    // The last footer item gone: the non-daily note loses its marker, the
    // daily note keeps it.
    for host in [&daily, &plain] {
        drop_tag_row(&v, &host.id, "y");
    }
    let saved = person_save(&mut v, &daily.id, &format!("Day.\n\nMore.\n{M}\n#y\n"));
    assert_eq!(saved.content_md, format!("Day.\n\nMore.\n{M}\n"));
    let saved = person_save(&mut v, &plain.id, &format!("Notes.\n\nMore.\n{M}\n#y\n"));
    assert_person_only(&saved.content_md, "Notes.\n\nMore.\n", "plain");
    assert!(tag_rows(&v, &plain.id).is_empty());
}

// ---------- AC 3: `#x` typed below the marker ----------

#[test]
fn typed_tag_line_below_the_marker_is_dropped_and_other_stray_lines_move_to_the_person_section() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let plain = create_plain(&mut v, "Loose", "Notes.\n");
    for (host, person) in [(&daily, "Day.\n"), (&plain, "Notes.\n")] {
        chip_row(&v, &host.id, &topic.id, "person");
        let typed =
            format!("{person}{M}\n[[Player Loop~about]]\n#typed\nstray words\n# Heading\n##x\n#\n");
        let saved = person_save(&mut v, &host.id, &typed);
        assert_eq!(
            saved.content_md,
            format!("{person}stray words\n# Heading\n##x\n#\n{M}\n[[Player Loop~about]]\n"),
            "{}",
            host.title
        );
        assert!(
            tag_rows(&v, &host.id).is_empty(),
            "{}: a typed footer line never makes a tag: {:?}",
            host.title,
            tag_rows(&v, &host.id)
        );
    }
}

// ---------- AC 4: a person save keeps the footer rendered from rows ----------

#[test]
fn person_save_keeps_the_footer_rendered_from_rows_on_daily_and_non_daily_notes() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let host_topic = create_topic(&mut v, "Game Design");
    let plain = create_plain(&mut v, "Loose", "Notes.\n");
    for host in [&daily, &host_topic, &plain] {
        chip_row(&v, &host.id, &topic.id, "excerpt");
        tag_row(&v, &host.id, "work", "agent");
        let want = format!("Edited.\n{M}\n[[Player Loop~about]]\n#work\n");
        // Source mode deleted the footer and its marker ...
        let saved = person_save(&mut v, &host.id, "Edited.\n");
        assert_eq!(saved.content_md, want, "{}: footer restored", host.title);
        // ... or sends a stale one: rows win either way.
        let stale = format!("Edited.\n{M}\n[[Ghost~about]]\n#ghost\n");
        let saved = person_save(&mut v, &host.id, &stale);
        assert_eq!(saved.content_md, want, "{}: rows win", host.title);
        assert_eq!(stored(&v, &host.id).content_md, want);
        assert_eq!(
            chip_rows(&v, &host.id),
            vec![(topic.id.to_string(), "excerpt".to_string())],
            "{}: footer text never creates a chip",
            host.title
        );
        assert_eq!(
            tag_rows(&v, &host.id),
            vec![("work".to_string(), "agent".to_string())],
            "{}: footer text never creates a tag",
            host.title
        );
    }
}

// ---------- AC 5: the non-daily marker lifecycle ----------

#[test]
fn non_daily_marker_is_inserted_by_the_first_footer_item_and_removed_with_the_last() {
    let (_dir, mut v) = fresh_vault();
    let alpha = create_topic(&mut v, "Alpha");
    let bravo = create_topic(&mut v, "Bravo");
    let plain = create_plain(&mut v, "Loose", "Notes.");
    assert!(!stored(&v, &plain.id).content_md.contains(M));

    set(&mut v, &plain.id, &alpha.id, ChipOrigin::Person);
    assert_eq!(
        stored(&v, &plain.id).content_md,
        format!("Notes.\n{M}\n[[Alpha~about]]\n"),
        "the first item inserts the marker"
    );
    set(&mut v, &plain.id, &bravo.id, ChipOrigin::Excerpt);
    assert_eq!(
        stored(&v, &plain.id).content_md,
        format!("Notes.\n{M}\n[[Alpha~about]]\n[[Bravo~about]]\n")
    );
    remove(&mut v, &plain.id, &alpha.id, RemoveMode::AnyOrigin);
    assert_eq!(
        stored(&v, &plain.id).content_md,
        format!("Notes.\n{M}\n[[Bravo~about]]\n"),
        "an item left keeps the marker"
    );
    remove(&mut v, &plain.id, &bravo.id, RemoveMode::ExcerptOnly);
    assert_person_only(
        &stored(&v, &plain.id).content_md,
        "Notes.",
        "the last chip removed",
    );

    // A tag line is footer content too: the marker stays while it is there.
    let topic_host = create_topic(&mut v, "Game Design");
    tag_row(&v, &topic_host.id, "x", "agent");
    set(&mut v, &topic_host.id, &alpha.id, ChipOrigin::Person);
    remove(&mut v, &topic_host.id, &alpha.id, RemoveMode::AnyOrigin);
    assert_eq!(
        stored(&v, &topic_host.id).content_md,
        format!("All about Game Design.\n{M}\n#x\n")
    );
    drop_tag_row(&v, &topic_host.id, "x");
    let current = stored(&v, &topic_host.id).content_md;
    let saved = person_save(&mut v, &topic_host.id, &current);
    assert_person_only(
        &saved.content_md,
        "All about Game Design.\n",
        "last tag gone",
    );

    // A daily note keeps its canonical marker.
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    set(&mut v, &daily.id, &alpha.id, ChipOrigin::Person);
    remove(&mut v, &daily.id, &alpha.id, RemoveMode::AnyOrigin);
    assert_eq!(stored(&v, &daily.id).content_md, format!("Day.\n{M}\n"));
}

// ---------- AC 6: a fenced marker on a non-daily note is body text ----------

#[test]
fn non_daily_note_with_a_fenced_marker_and_no_footer_is_unchanged_by_saves() {
    let (_dir, mut v) = fresh_vault();
    let alpha = create_topic(&mut v, "Alpha");
    let fenced = format!("Code:\n```\n{M}\n[[Alpha~about]]\n#not-a-tag\n```\nAfter.\n");
    let plain = create_plain(&mut v, "Snippet", &fenced);

    let saved = person_save(&mut v, &plain.id, &fenced);
    assert_eq!(saved.content_md, fenced, "a save keeps it byte for byte");
    let edited = format!("{fenced}\nMore.\n");
    let saved = person_save(&mut v, &plain.id, &edited);
    assert_eq!(saved.content_md, edited);

    // Notes without a marker are unchanged too, final newline or not.
    let bare = create_plain(&mut v, "Bare", "Last line");
    let saved = person_save(&mut v, &bare.id, "Last line");
    assert_eq!(saved.content_md, "Last line");

    // A footer goes after the fence, and leaves with the last item.
    set(&mut v, &plain.id, &alpha.id, ChipOrigin::Person);
    let with_footer = stored(&v, &plain.id).content_md;
    assert_eq!(with_footer, format!("{edited}{M}\n[[Alpha~about]]\n"));
    assert_eq!(daily::split_note_body(&with_footer).person, edited);
    remove(&mut v, &plain.id, &alpha.id, RemoveMode::AnyOrigin);
    assert_eq!(stored(&v, &plain.id).content_md, edited);
}

// ---------- AC 12: deleting a topic re-renders every note that chips it ----------

#[test]
fn deleting_a_topic_rerenders_every_note_that_chips_it_daily_or_not() {
    let (_dir, mut v) = fresh_vault();
    let gone = create_topic(&mut v, "Player Loop");
    let kept = create_topic(&mut v, "Sleep");
    let daily = create_daily(&mut v, "2026-10-01", "Day.\n");
    let plain = create_plain(&mut v, "Loose", "Notes.\n");
    let host_topic = create_topic(&mut v, "Game Design");
    let untouched = create_plain(&mut v, "Other", "Other.\n");
    set(&mut v, &daily.id, &gone.id, ChipOrigin::Person);
    set(&mut v, &plain.id, &gone.id, ChipOrigin::Excerpt);
    set(&mut v, &host_topic.id, &gone.id, ChipOrigin::Person);
    set(&mut v, &host_topic.id, &kept.id, ChipOrigin::Person);
    set(&mut v, &untouched.id, &kept.id, ChipOrigin::Person);
    mark_reviewed(&v, &daily.id);
    let cv = content_version(&v, &daily.id);
    let versions: Vec<i64> = [&daily, &plain, &host_topic, &untouched]
        .iter()
        .map(|n| stored(&v, &n.id).version)
        .collect();

    let version = stored(&v, &gone.id).version;
    delete_note_checked(&mut v, &gone.id, version, None).expect("delete the topic");

    assert_eq!(stored(&v, &daily.id).content_md, format!("Day.\n{M}\n"));
    assert_person_only(&stored(&v, &plain.id).content_md, "Notes.\n", "plain");
    assert_eq!(
        stored(&v, &host_topic.id).content_md,
        format!("All about Game Design.\n{M}\n[[Sleep~about]]\n")
    );
    for (n, (note, before)) in [&daily, &plain, &host_topic]
        .iter()
        .zip(&versions)
        .enumerate()
    {
        assert_eq!(
            stored(&v, &note.id).version,
            before + 1,
            "{n}: {} re-rendered",
            note.title
        );
        assert!(
            !links_from(&v, &note.id)
                .iter()
                .any(|l| l.0 == "Player Loop"),
            "{} is reindexed",
            note.title
        );
    }
    assert_eq!(content_version(&v, &daily.id), cv);
    assert_eq!(review_state(&v, &daily.id), ReviewState::Reviewed);
    assert_eq!(
        stored(&v, &untouched.id).version,
        versions[3],
        "a note without the chip is not written"
    );
}

// ---------- AC 13: a guide note never gets a footer ----------

#[test]
fn guide_note_gets_no_footer_rendered_or_inserted_on_any_path() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop");
    let other = create_topic(&mut v, "Sleep");
    let guide = create_guide(&mut v, "How this vault works.\n");
    // Rows a footer would render from, were the guide any other note.
    tag_row(&v, &guide.id, "work", "agent");
    tag_row(&v, &guide.id, "mine", "person");
    chip_row(&v, &guide.id, &topic.id, "person");

    // A person save stores the body as given.
    let edited = "How this vault works.\n\nMore rules.\n";
    let saved = person_save(&mut v, &guide.id, edited);
    assert_eq!(saved.content_md, edited);

    // A footer write is refused.
    assert_guide_rule(
        footer::set_chip(&mut v, &guide.id, &other.id, ChipOrigin::Person, None),
        "set_chip",
    );
    assert_eq!(stored(&v, &guide.id).content_md, edited);

    // Deleting a topic the guide has a row for re-renders nothing there.
    let version = stored(&v, &topic.id).version;
    delete_note_checked(&mut v, &topic.id, version, None).expect("delete the topic");
    assert_eq!(stored(&v, &guide.id).content_md, edited);
    assert!(!stored(&v, &guide.id).content_md.contains(M));
}
