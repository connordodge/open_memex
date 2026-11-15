//! WI #9 (Spec #7 Req 2, 5, 6; ruling D4): Agent read-only binds at every
//! agent write path in core, including the paths that answer without writing.
//!
//! - `tags::agent_tag_note` / `agent_untag_note` on a flagged note are
//!   `ReadOnlyRule` and write nothing, the "already tagged" and "not tagged"
//!   answers included. The check runs after the note lookup (`NotFound`,
//!   `GuideRule`) and before every tag rule.
//! - `footer::agent_set_chip` (new) refuses a flagged note, the chip that is
//!   already there included, and is otherwise `set_chip(.., Excerpt, ..)`.
//!   The person's `set_chip` still writes a flagged note.
//! - `excerpts::add_excerpt` / `remove_excerpt` / `remove_excerpt_block` as
//!   the agent on a flagged topic note are `ReadOnlyRule`: no topic write and
//!   no chip on the daily note, blocks that are already filed included.
//! - Req 6: reads, links TO a flagged note, Smart Folder membership and
//!   canvas writes still work for the agent.
//!
//! Notes are flagged with raw SQL (D15 style) so these tests do not lean on
//! the setter, which `read_only_setter.rs` pins. Real SQLite, temp vaults.

use memex_core::canvas;
use memex_core::error::MemexError;
use memex_core::excerpts::{add_excerpt, remove_excerpt, remove_excerpt_block};
use memex_core::footer::{self, ChipOrigin, RemoveMode};
use memex_core::graph;
use memex_core::indexer;
use memex_core::links::{self, LinkKind, UpdateLink};
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::smart_folders;
use memex_core::tags;
use memex_core::{search, Caller, SearchFilters, SearchMode, SearchOptions, SystemClock, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
/// Three blocks, pinned to `b7k2m9`, `c3d4e5`, `f6g7h8` by [`create_day`].
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const DAY_BLOCKS: [&str; 3] = ["b7k2m9", "c3d4e5", "f6g7h8"];
const B7: &str = "b7k2m9";
const C3: &str = "c3d4e5";

// ---------- setup ----------

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

fn topic(vault: &mut Vault, title: &str) -> NoteId {
    let body = format!("All about {title}.\n");
    create(vault, title, &body, Some(json!({ "role": "topic" }))).id
}

/// The daily note [`DAY`] with its block ids pinned by ord.
fn create_day(vault: &mut Vault) -> NoteId {
    let note = create(vault, DAY, DAY_BODY, Some(json!({ "role": "daily" })));
    for (ord, id) in DAY_BLOCKS.iter().enumerate() {
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

/// Sets or clears the flag with raw SQL.
fn set_flag(vault: &Vault, id: &NoteId, on: bool) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE notes SET agent_read_only = ?1 WHERE id = ?2",
            params![i64::from(on), id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "the note exists");
}

fn read_only_message(title: &str) -> String {
    format!("\"{title}\" is read-only for agents; the person can change this in the app")
}

/// `result` is `ReadOnlyRule`, code `read_only_rule`, with the Req 9 message.
fn assert_read_only_rule<T: std::fmt::Debug>(
    result: Result<T, MemexError>,
    title: &str,
    what: &str,
) {
    match result {
        Err(e @ MemexError::ReadOnlyRule(_)) => {
            assert_eq!(e.code(), "read_only_rule", "{what}");
            assert_eq!(e.to_string(), read_only_message(title), "{what}");
        }
        other => panic!("{what}: expected ReadOnlyRule, got {other:?}"),
    }
}

/// Everything an agent write could touch on one note.
#[derive(Debug, PartialEq)]
struct Snapshot {
    title: String,
    content_md: String,
    frontmatter: Value,
    version: i64,
    updated_at: i64,
    agent_read_only: i64,
    tags: Vec<(String, String)>,
    links: Vec<(String, String, Option<String>)>,
    chips: Vec<(String, String)>,
    tag_corrections: i64,
}

fn snapshot(vault: &Vault, id: &NoteId) -> Snapshot {
    let note = get_note(vault, id).unwrap();
    let conn = vault.connection_ref();
    let tags = conn
        .prepare("SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let links = conn
        .prepare(
            "SELECT link_text, link_kind, label FROM links WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let chips = conn
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let tag_corrections = conn
        .query_row(
            "SELECT COUNT(*) FROM tag_corrections WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    let agent_read_only = conn
        .query_row(
            "SELECT agent_read_only FROM notes WHERE id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    Snapshot {
        title: note.title,
        content_md: note.content_md,
        frontmatter: note.frontmatter,
        version: note.version,
        updated_at: note.updated_at,
        agent_read_only,
        tags,
        links,
        chips,
        tag_corrections,
    }
}

fn content_revision(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
            r.get(0)
        })
        .unwrap()
}

fn chip_origin(vault: &Vault, host: &NoteId, topic: &NoteId) -> Option<String> {
    vault
        .connection_ref()
        .query_row(
            "SELECT origin FROM footer_chips WHERE daily_note_id = ? AND topic_note_id = ?",
            [host.as_str(), topic.as_str()],
            |r| r.get(0),
        )
        .ok()
}

fn tag_rows(vault: &Vault, id: &NoteId) -> Vec<(String, String)> {
    snapshot(vault, id).tags
}

/// A vault where `#games` is in the vocabulary (a body tag on another note)
/// and "Pricing notes" carries the body tag `#pricing`.
struct TagWorld {
    _dir: TempDir,
    vault: Vault,
    note: NoteId,
}

fn tag_world() -> TagWorld {
    let (dir, mut vault) = fresh_vault();
    create(
        &mut vault,
        "Game ideas",
        "Ideas for #games and #draft.\n",
        None,
    );
    let note = create(&mut vault, "Pricing notes", "Tiers and #pricing.\n", None).id;
    TagWorld {
        _dir: dir,
        vault,
        note,
    }
}

// ---------- tag_note / untag_note ----------

#[test]
fn agent_tag_note_on_a_flagged_note_is_read_only_rule_and_writes_nothing() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    set_flag(&vault, &note, true);
    let before = snapshot(&vault, &note);
    let revision = content_revision(&vault);

    // `games` is in the vocabulary, so an unflagged note would take it.
    assert_read_only_rule(
        tags::agent_tag_note(&mut vault, &note, "games", None),
        "Pricing notes",
        "a new vocabulary tag",
    );
    assert_eq!(snapshot(&vault, &note), before, "nothing written");
    assert_eq!(content_revision(&vault), revision, "no row moved anywhere");

    // Cleared, the same call applies the tag (the boundary both ways).
    set_flag(&vault, &note, false);
    let write = tags::agent_tag_note(&mut vault, &note, "games", None)
        .expect("an agent tags a note that is not read-only");
    assert!(write.changed);
    assert!(tag_rows(&vault, &note).contains(&("games".into(), "agent".into())));
}

#[test]
fn agent_tag_note_already_tagged_on_a_flagged_note_is_read_only_rule() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    tags::agent_tag_note(&mut vault, &note, "games", None).expect("tag before the flag");
    set_flag(&vault, &note, true);
    let before = snapshot(&vault, &note);

    // The agent-origin tag, the body tag, and a spelling that resolves to it:
    // each is today's "already tagged" no-op answer.
    for tag in ["games", "pricing", "#Pricing"] {
        assert_read_only_rule(
            tags::agent_tag_note(&mut vault, &note, tag, None),
            "Pricing notes",
            &format!("already tagged {tag:?}"),
        );
        assert_eq!(snapshot(&vault, &note), before, "{tag}: nothing written");
    }

    set_flag(&vault, &note, false);
    let again = tags::agent_tag_note(&mut vault, &note, "games", None)
        .expect("cleared: the no-op answer again");
    assert!(!again.changed, "already tagged writes nothing");
}

#[test]
fn agent_tag_note_on_a_flagged_note_is_read_only_rule_before_the_tag_rules() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    // An open block on `draft` for this note (the person removed it).
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at)
             VALUES (?, 'Pricing notes', 'draft', 'removed', 1)",
            [note.as_str()],
        )
        .unwrap();
    set_flag(&vault, &note, true);
    let before = snapshot(&vault, &note);
    for (what, tag) in [
        ("unknown tag", "not-in-the-vocabulary"),
        ("outside the grammar", "two words"),
        ("blocked tag", "draft"),
    ] {
        assert_read_only_rule(
            tags::agent_tag_note(&mut vault, &note, tag, None),
            "Pricing notes",
            what,
        );
        assert_eq!(snapshot(&vault, &note), before, "{what}");
    }

    // Unflagged, the tag rules answer as before.
    set_flag(&vault, &note, false);
    let err = tags::agent_tag_note(&mut vault, &note, "not-in-the-vocabulary", None)
        .expect_err("unknown tag");
    assert_eq!(err.code(), "unknown_tag", "{err:?}");
    let err = tags::agent_tag_note(&mut vault, &note, "draft", None).expect_err("blocked");
    assert_eq!(err.code(), "tag_removed", "{err:?}");
}

#[test]
fn agent_tag_and_untag_keep_not_found_and_guide_rule_before_read_only_rule() {
    let (_dir, mut vault) = fresh_vault();
    let missing = NoteId::new();
    let err = tags::agent_tag_note(&mut vault, &missing, "games", None).expect_err("missing");
    assert_eq!(err.code(), "not_found", "{err:?}");
    let err = tags::agent_untag_note(&mut vault, &missing, "games", None).expect_err("missing");
    assert_eq!(err.code(), "not_found", "{err:?}");

    let doc = memex_core::guide::get_or_create(&mut vault, &SystemClock, None).unwrap();
    let guide = NoteId::parse(&doc.note_id).unwrap();
    set_flag(&vault, &guide, true);
    let err = tags::agent_tag_note(&mut vault, &guide, "games", None).expect_err("guide");
    assert_eq!(err.code(), "guide_rule", "{err:?}");
    let err = tags::agent_untag_note(&mut vault, &guide, "games", None).expect_err("guide");
    assert_eq!(err.code(), "guide_rule", "{err:?}");
}

#[test]
fn agent_untag_note_on_a_flagged_note_is_read_only_rule_and_keeps_the_agent_tag() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    tags::agent_tag_note(&mut vault, &note, "games", None).expect("tag before the flag");
    set_flag(&vault, &note, true);
    let before = snapshot(&vault, &note);
    assert!(before.tags.contains(&("games".into(), "agent".into())));
    let revision = content_revision(&vault);

    assert_read_only_rule(
        tags::agent_untag_note(&mut vault, &note, "games", None),
        "Pricing notes",
        "an agent tag the note has",
    );
    assert_eq!(
        snapshot(&vault, &note),
        before,
        "the tag and its footer line stay"
    );
    assert_eq!(content_revision(&vault), revision);

    set_flag(&vault, &note, false);
    let removal = tags::agent_untag_note(&mut vault, &note, "games", None)
        .expect("cleared, the agent removes its tag");
    assert!(removal.removed);
    assert!(!tag_rows(&vault, &note).contains(&("games".into(), "agent".into())));
}

#[test]
fn agent_untag_note_not_tagged_on_a_flagged_note_is_read_only_rule() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    set_flag(&vault, &note, true);
    let before = snapshot(&vault, &note);
    // A tag the note doesn't have (today's `removed: false`), and the body
    // tag it does have (today's invalid_argument): the flag answers first.
    for tag in ["games", "pricing"] {
        assert_read_only_rule(
            tags::agent_untag_note(&mut vault, &note, tag, None),
            "Pricing notes",
            &format!("untag {tag:?}"),
        );
        assert_eq!(snapshot(&vault, &note), before, "{tag}");
    }

    set_flag(&vault, &note, false);
    let removal = tags::agent_untag_note(&mut vault, &note, "games", None)
        .expect("cleared: not tagged is removed=false again");
    assert!(!removal.removed);
}

#[test]
fn person_tag_writes_on_a_flagged_note_still_work() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    tags::agent_tag_note(&mut vault, &note, "games", None).expect("agent tag before the flag");
    set_flag(&vault, &note, true);
    // The agent is refused first, so the boundary is proven both ways.
    assert_read_only_rule(
        tags::agent_tag_note(&mut vault, &note, "draft", None),
        "Pricing notes",
        "agent",
    );

    let add = tags::person_add_tag(&mut vault, &note, "draft", None)
        .expect("a person adds a tag to a flagged note");
    assert!(add.changed);
    let removal = tags::person_remove_tag(&mut vault, &note, "games", None)
        .expect("a person removes the agent tag from a flagged note");
    assert!(removal.removed);
    let after = snapshot(&vault, &note);
    assert!(after.tags.contains(&("draft".into(), "person".into())));
    assert!(!after.tags.iter().any(|(t, _)| t == "games"));
    assert_eq!(after.agent_read_only, 1, "person writes keep the flag");
}

// ---------- add_footer_topic (footer::agent_set_chip) ----------

/// "Pricing notes" (plain) and two topic notes.
struct ChipWorld {
    _dir: TempDir,
    vault: Vault,
    host: NoteId,
    loop_topic: NoteId,
    economy: NoteId,
}

fn chip_world() -> ChipWorld {
    let (dir, mut vault) = fresh_vault();
    let host = create(&mut vault, "Pricing notes", "Tiers.\n", None).id;
    let loop_topic = topic(&mut vault, "Player Loop");
    let economy = topic(&mut vault, "Economy Design");
    ChipWorld {
        _dir: dir,
        vault,
        host,
        loop_topic,
        economy,
    }
}

#[test]
fn agent_set_chip_on_a_flagged_note_is_read_only_rule_and_writes_no_chip() {
    let ChipWorld {
        _dir,
        mut vault,
        host,
        loop_topic,
        ..
    } = chip_world();
    set_flag(&vault, &host, true);
    let before = snapshot(&vault, &host);
    let revision = content_revision(&vault);
    assert_read_only_rule(
        footer::agent_set_chip(&mut vault, &host, &loop_topic, None),
        "Pricing notes",
        "a new chip",
    );
    assert_eq!(snapshot(&vault, &host), before, "no chip, no footer");
    assert_eq!(chip_origin(&vault, &host, &loop_topic), None);
    assert_eq!(content_revision(&vault), revision);
}

#[test]
fn agent_set_chip_with_the_chip_already_there_on_a_flagged_note_is_read_only_rule() {
    let ChipWorld {
        _dir,
        mut vault,
        host,
        loop_topic,
        economy,
    } = chip_world();
    footer::set_chip(&mut vault, &host, &loop_topic, ChipOrigin::Excerpt, None).unwrap();
    footer::set_chip(&mut vault, &host, &economy, ChipOrigin::Person, None).unwrap();
    set_flag(&vault, &host, true);
    let before = snapshot(&vault, &host);
    for (what, t) in [("excerpt chip", &loop_topic), ("person chip", &economy)] {
        assert_read_only_rule(
            footer::agent_set_chip(&mut vault, &host, t, None),
            "Pricing notes",
            what,
        );
        assert_eq!(snapshot(&vault, &host), before, "{what}");
    }
}

#[test]
fn agent_set_chip_on_a_flagged_note_is_read_only_rule_before_the_chip_rules() {
    let ChipWorld {
        _dir,
        mut vault,
        host,
        ..
    } = chip_world();
    let plain = create(&mut vault, "Roadmap", "Q1.\n", None).id;
    set_flag(&vault, &host, true);
    let before = snapshot(&vault, &host);
    for (what, target) in [
        ("target not a topic", plain.clone()),
        ("self chip", host.clone()),
        ("unknown target", NoteId::new()),
    ] {
        assert_read_only_rule(
            footer::agent_set_chip(&mut vault, &host, &target, None),
            "Pricing notes",
            what,
        );
        assert_eq!(snapshot(&vault, &host), before, "{what}");
    }
}

#[test]
fn agent_set_chip_on_an_unflagged_note_adds_an_excerpt_chip_like_set_chip() {
    let ChipWorld {
        _dir,
        mut vault,
        host,
        loop_topic,
        economy,
    } = chip_world();
    // A flagged TOPIC does not block a chip for it on another note: the
    // chip writes only the host.
    set_flag(&vault, &loop_topic, true);
    let topic_before = snapshot(&vault, &loop_topic);
    let v0 = get_note(&vault, &host).unwrap().version;

    let write = footer::agent_set_chip(&mut vault, &host, &loop_topic, None)
        .expect("an agent adds a chip to a note that is not read-only");
    assert_eq!(
        write.origin,
        Some(ChipOrigin::Excerpt),
        "an agent chip is excerpt"
    );
    assert_eq!(write.note.version, v0 + 1, "the footer was written");
    assert!(write.note.content_md.contains("<!-- memex:topics -->"));
    assert_eq!(
        chip_origin(&vault, &host, &loop_topic).as_deref(),
        Some("excerpt")
    );
    assert_eq!(
        snapshot(&vault, &loop_topic),
        topic_before,
        "topic untouched"
    );

    // Again: the chip is there, nothing written.
    let again = footer::agent_set_chip(&mut vault, &host, &loop_topic, None).unwrap();
    assert_eq!(again.note.version, v0 + 1);
    assert_eq!(again.origin, Some(ChipOrigin::Excerpt));

    // Over a person chip it keeps `person` (excerpt never upgrades).
    footer::set_chip(&mut vault, &host, &economy, ChipOrigin::Person, None).unwrap();
    let kept = footer::agent_set_chip(&mut vault, &host, &economy, None).unwrap();
    assert_eq!(kept.origin, Some(ChipOrigin::Person));
}

#[test]
fn agent_set_chip_keeps_set_chip_errors_on_an_unflagged_note() {
    let ChipWorld {
        _dir,
        mut vault,
        host,
        loop_topic,
        ..
    } = chip_world();
    let plain = create(&mut vault, "Roadmap", "Q1.\n", None).id;
    let err = footer::agent_set_chip(&mut vault, &host, &plain, None).expect_err("not a topic");
    assert_eq!(err.code(), "role_rule", "{err:?}");
    let err = footer::agent_set_chip(&mut vault, &NoteId::new(), &loop_topic, None)
        .expect_err("unknown host");
    assert_eq!(err.code(), "not_found", "{err:?}");
    let doc = memex_core::guide::get_or_create(&mut vault, &SystemClock, None).unwrap();
    let guide = NoteId::parse(&doc.note_id).unwrap();
    let err =
        footer::agent_set_chip(&mut vault, &guide, &loop_topic, None).expect_err("guide host");
    assert_eq!(err.code(), "guide_rule", "{err:?}");
    assert_eq!(chip_origin(&vault, &host, &plain), None);
}

#[test]
fn person_set_chip_on_a_flagged_note_still_writes_the_chip() {
    let ChipWorld {
        _dir,
        mut vault,
        host,
        loop_topic,
        economy,
    } = chip_world();
    set_flag(&vault, &host, true);
    assert_read_only_rule(
        footer::agent_set_chip(&mut vault, &host, &economy, None),
        "Pricing notes",
        "agent",
    );
    let v0 = get_note(&vault, &host).unwrap().version;

    // `memex footer add` is set_chip with the person origin.
    let write = footer::set_chip(&mut vault, &host, &loop_topic, ChipOrigin::Person, None)
        .expect("a person adds a chip to a flagged note");
    assert_eq!(write.origin, Some(ChipOrigin::Person));
    assert_eq!(write.note.version, v0 + 1);
    assert_eq!(
        chip_origin(&vault, &host, &loop_topic).as_deref(),
        Some("person")
    );
    // And removes it.
    let removed = footer::remove_chip(&mut vault, &host, &loop_topic, RemoveMode::AnyOrigin, None)
        .expect("a person removes a chip from a flagged note");
    assert_eq!(removed.origin, None);
    assert_eq!(snapshot(&vault, &host).agent_read_only, 1, "flag kept");
}

// ---------- excerpts into a flagged topic note ----------

struct ExcerptWorld {
    _dir: TempDir,
    vault: Vault,
    day: NoteId,
    topic: NoteId,
}

fn excerpt_world() -> ExcerptWorld {
    let (dir, mut vault) = fresh_vault();
    let day = create_day(&mut vault);
    let topic = topic(&mut vault, "Player Loop");
    ExcerptWorld {
        _dir: dir,
        vault,
        day,
        topic,
    }
}

fn ids(blocks: &[&str]) -> Vec<String> {
    blocks.iter().map(|b| b.to_string()).collect()
}

#[test]
fn agent_add_excerpt_into_a_flagged_topic_is_read_only_rule_and_writes_neither_note() {
    let ExcerptWorld {
        _dir,
        mut vault,
        day,
        topic,
    } = excerpt_world();
    set_flag(&vault, &topic, true);
    let topic_before = snapshot(&vault, &topic);
    let day_before = snapshot(&vault, &day);
    assert_read_only_rule(
        add_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Agent, None),
        "Player Loop",
        "new blocks",
    );
    assert_eq!(snapshot(&vault, &topic), topic_before, "no topic write");
    assert_eq!(snapshot(&vault, &day), day_before, "no chip on the day");
}

#[test]
fn agent_add_excerpt_of_blocks_already_filed_in_a_flagged_topic_is_read_only_rule() {
    let ExcerptWorld {
        _dir,
        mut vault,
        day,
        topic,
    } = excerpt_world();
    add_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Person, None).unwrap();
    assert_eq!(
        chip_origin(&vault, &day, &topic).as_deref(),
        Some("excerpt")
    );
    set_flag(&vault, &topic, true);

    // The chip is there: today this answers Ok without a write.
    let topic_before = snapshot(&vault, &topic);
    let day_before = snapshot(&vault, &day);
    assert_read_only_rule(
        add_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Agent, None),
        "Player Loop",
        "already filed, chip there",
    );
    assert_eq!(snapshot(&vault, &topic), topic_before);
    assert_eq!(snapshot(&vault, &day), day_before);

    // The chip is gone: today this answers Ok and puts the chip back on the
    // daily note. Flagged, it must write neither note.
    footer::remove_chip(&mut vault, &day, &topic, RemoveMode::AnyOrigin, None).unwrap();
    assert_eq!(chip_origin(&vault, &day, &topic), None);
    let topic_before = snapshot(&vault, &topic);
    let day_before = snapshot(&vault, &day);
    let revision = content_revision(&vault);
    assert_read_only_rule(
        add_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Agent, None),
        "Player Loop",
        "already filed, chip missing",
    );
    assert_eq!(snapshot(&vault, &topic), topic_before, "no topic write");
    assert_eq!(
        snapshot(&vault, &day),
        day_before,
        "no chip on the daily note"
    );
    assert_eq!(chip_origin(&vault, &day, &topic), None);
    assert_eq!(content_revision(&vault), revision);

    // Cleared, the agent's already-filed call restores the chip as today.
    set_flag(&vault, &topic, false);
    add_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Agent, None)
        .expect("cleared: already filed is a no-op on the topic");
    assert_eq!(
        chip_origin(&vault, &day, &topic).as_deref(),
        Some("excerpt")
    );
}

#[test]
fn agent_remove_excerpt_from_a_flagged_topic_is_read_only_rule_and_writes_neither_note() {
    let ExcerptWorld {
        _dir,
        mut vault,
        day,
        topic,
    } = excerpt_world();
    add_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Person, None).unwrap();
    set_flag(&vault, &topic, true);
    let topic_before = snapshot(&vault, &topic);
    let day_before = snapshot(&vault, &day);
    assert_read_only_rule(
        remove_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Agent, None),
        "Player Loop",
        "a filed excerpt",
    );
    assert_eq!(snapshot(&vault, &topic), topic_before, "excerpt kept");
    assert_eq!(snapshot(&vault, &day), day_before, "chip kept");

    // The check runs before the topic is read for a matching token: an
    // excerpt the topic does not hold is read_only_rule too, not not_found.
    assert_read_only_rule(
        remove_excerpt(&mut vault, &topic, DAY, &ids(&[C3]), Caller::Agent, None),
        "Player Loop",
        "no such excerpt",
    );
    assert_eq!(snapshot(&vault, &topic), topic_before);

    set_flag(&vault, &topic, false);
    let err = remove_excerpt(&mut vault, &topic, DAY, &ids(&[C3]), Caller::Agent, None)
        .expect_err("cleared: no such excerpt");
    assert_eq!(err.code(), "not_found", "{err:?}");
}

#[test]
fn agent_remove_excerpt_block_from_a_flagged_topic_is_read_only_rule_and_writes_neither_note() {
    let ExcerptWorld {
        _dir,
        mut vault,
        day,
        topic,
    } = excerpt_world();
    add_excerpt(
        &mut vault,
        &topic,
        DAY,
        &ids(&[B7, C3]),
        Caller::Person,
        None,
    )
    .unwrap();
    set_flag(&vault, &topic, true);
    let topic_before = snapshot(&vault, &topic);
    let day_before = snapshot(&vault, &day);
    assert_read_only_rule(
        remove_excerpt_block(&mut vault, &topic, DAY, C3, Caller::Agent, None),
        "Player Loop",
        "a filed block",
    );
    assert_eq!(snapshot(&vault, &topic), topic_before);
    assert_eq!(snapshot(&vault, &day), day_before);
}

#[test]
fn person_excerpt_writes_into_a_flagged_topic_still_work() {
    let ExcerptWorld {
        _dir,
        mut vault,
        day,
        topic,
    } = excerpt_world();
    set_flag(&vault, &topic, true);
    assert_read_only_rule(
        add_excerpt(&mut vault, &topic, DAY, &ids(&[C3]), Caller::Agent, None),
        "Player Loop",
        "agent",
    );
    let v0 = get_note(&vault, &topic).unwrap().version;

    let filed = add_excerpt(
        &mut vault,
        &topic,
        DAY,
        &ids(&[B7, C3]),
        Caller::Person,
        None,
    )
    .expect("a person files into a flagged topic");
    assert_eq!(filed.version, v0 + 1);
    assert!(filed
        .content_md
        .contains("![[2026-09-05#^b7k2m9..^c3d4e5]]"));
    assert_eq!(
        chip_origin(&vault, &day, &topic).as_deref(),
        Some("excerpt")
    );

    let split = remove_excerpt_block(&mut vault, &topic, DAY, C3, Caller::Person, None)
        .expect("a person removes a block from a flagged topic");
    assert!(split.content_md.contains("![[2026-09-05#^b7k2m9]]"));
    let gone = remove_excerpt(&mut vault, &topic, DAY, &ids(&[B7]), Caller::Person, None)
        .expect("a person removes an excerpt from a flagged topic");
    assert!(!gone.content_md.contains("![["));
    assert_eq!(snapshot(&vault, &topic).agent_read_only, 1, "flag kept");
}

// ---------- links ----------

#[test]
fn agent_link_edits_on_a_flagged_source_are_read_only_rule() {
    let (_dir, mut vault) = fresh_vault();
    create(&mut vault, "Roadmap", "Q1.\n", None);
    let source = create(&mut vault, "Pricing notes", "See [[Roadmap]].\n", None);
    let link_id: String = vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links WHERE from_note_id = ?",
            [source.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    set_flag(&vault, &source.id, true);
    let before = snapshot(&vault, &source.id);
    assert_read_only_rule(
        links::update_link_changed(
            &mut vault,
            &link_id,
            UpdateLink {
                new_kind: None,
                new_label: Some(Some("the plan".into())),
            },
            Caller::Agent,
        ),
        "Pricing notes",
        "label change",
    );
    // add_link's save: the agent's body write with a new wikilink.
    assert_read_only_rule(
        update_note_as(
            &mut vault,
            &source.id,
            source.version,
            UpdateNote {
                content_md: Some("See [[Roadmap]].\n\n[[Games]]\n".into()),
                ..Default::default()
            },
            RenameOptions {
                rename_links: false,
            },
            Caller::Agent,
        ),
        "Pricing notes",
        "add_link's save",
    );
    assert_eq!(snapshot(&vault, &source.id), before);
}

/// Spec #7 Req 5 / AC 2 in core: an agent's update_link that has nothing to
/// change (no new kind or label, or ones equal to the current) is
/// `ReadOnlyRule` on a flagged source, not the "unchanged" answer; the person
/// and an unflagged source still get it.
#[test]
fn agent_update_link_with_nothing_to_change_on_a_flagged_source_is_read_only_rule() {
    let (_dir, mut vault) = fresh_vault();
    create(&mut vault, "Roadmap", "Q1.\n", None);
    let source = create(
        &mut vault,
        "Pricing notes",
        "See [[Roadmap~extends]].\n",
        None,
    );
    let link_id: String = vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links WHERE from_note_id = ?",
            [source.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    let nothing = || UpdateLink {
        new_kind: None,
        new_label: None,
    };
    let same_kind = || UpdateLink {
        new_kind: Some(LinkKind::new("extends").unwrap()),
        new_label: None,
    };

    // Unflagged: the unchanged answer, nothing written.
    let before = snapshot(&vault, &source.id);
    for patch in [nothing(), same_kind()] {
        let (link, changed) =
            links::update_link_changed(&mut vault, &link_id, patch, Caller::Agent)
                .expect("an agent's no-op on an unflagged source");
        assert!(!changed);
        assert_eq!(link.link_kind, LinkKind::new("extends").unwrap());
    }
    assert_eq!(snapshot(&vault, &source.id), before);

    set_flag(&vault, &source.id, true);
    let before = snapshot(&vault, &source.id);
    let revision = content_revision(&vault);
    for (what, patch) in [("no fields", nothing()), ("the same kind", same_kind())] {
        assert_read_only_rule(
            links::update_link_changed(&mut vault, &link_id, patch, Caller::Agent),
            "Pricing notes",
            what,
        );
        assert_eq!(snapshot(&vault, &source.id), before, "{what}");
        assert_eq!(content_revision(&vault), revision, "{what}");
    }

    // The person's no-op on the flagged source is the unchanged answer.
    let (link, changed) =
        links::update_link_changed(&mut vault, &link_id, nothing(), Caller::Person)
            .expect("the person's no-op on a flagged source");
    assert!(!changed);
    assert_eq!(link.link_kind, LinkKind::new("extends").unwrap());
    assert_eq!(snapshot(&vault, &source.id), before);
}

#[test]
fn agent_link_from_an_unflagged_note_to_a_flagged_note_succeeds() {
    let (_dir, mut vault) = fresh_vault();
    let target = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    let source = create(&mut vault, "Roadmap", "Q1.\n", None);
    set_flag(&vault, &target.id, true);
    let target_before = snapshot(&vault, &target.id);

    let saved = update_note_as(
        &mut vault,
        &source.id,
        source.version,
        UpdateNote {
            content_md: Some("Q1.\n\n[[Pricing notes~extends]]\n".into()),
            ..Default::default()
        },
        RenameOptions {
            rename_links: false,
        },
        Caller::Agent,
    )
    .expect("an agent links to a read-only note from a writable one");
    indexer::reindex_note(
        vault.connection_mut(),
        saved.id.as_str(),
        &saved.content_md,
        None,
    )
    .unwrap();
    assert_eq!(
        snapshot(&vault, &source.id).links,
        [(
            "Pricing notes".to_string(),
            "extends".to_string(),
            None::<String>
        )]
    );
    let link_id: String = vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links WHERE from_note_id = ?",
            [source.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    let (link, changed) = links::update_link_changed(
        &mut vault,
        &link_id,
        UpdateLink {
            new_kind: Some(LinkKind::new("references").unwrap()),
            new_label: None,
        },
        Caller::Agent,
    )
    .expect("an agent edits its link to a read-only note");
    assert!(changed);
    assert_eq!(link.link_kind.as_str(), "references");
    assert_eq!(
        snapshot(&vault, &target.id),
        target_before,
        "the read-only target is untouched"
    );
}

// ---------- Req 6: reads, Smart Folders, canvas ----------

#[test]
fn search_and_neighbors_find_a_flagged_note() {
    let (_dir, mut vault) = fresh_vault();
    create(&mut vault, "Roadmap", "Ship the zeppelin update.\n", None);
    let note = create(
        &mut vault,
        "Pricing notes",
        "Zeppelin tier pricing, see [[Roadmap]].\n",
        None,
    );
    set_flag(&vault, &note.id, true);

    let hits = search(
        vault.connection_ref(),
        SearchOptions {
            query: "zeppelin",
            k: 10,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .expect("search")
    .hits;
    assert!(
        hits.iter().any(|h| h.note_id == note.id.as_str()),
        "the flagged note is found: {hits:?}"
    );
    let near = graph::neighbors(vault.connection_ref(), note.id.as_str(), 1, None)
        .expect("neighbors of a flagged note");
    assert_eq!(
        near.iter().map(|h| h.title.as_str()).collect::<Vec<_>>(),
        ["Roadmap"]
    );
    assert_eq!(get_note(&vault, &note.id).unwrap().title, "Pricing notes");
}

#[test]
fn agent_smart_folder_membership_works_on_a_flagged_topic_note() {
    let (_dir, mut vault) = fresh_vault();
    let t = topic(&mut vault, "Player Loop");
    set_flag(&vault, &t, true);
    let before = snapshot(&vault, &t);
    let folder =
        smart_folders::create_folder(&mut vault, "Games", None, Caller::Agent, &SystemClock)
            .expect("folder");
    let membership = smart_folders::add_member(
        &mut vault,
        &folder.id,
        t.as_str(),
        None,
        Caller::Agent,
        None,
    )
    .expect("an agent adds a read-only topic to a Smart Folder");
    assert_eq!(membership.note_id, t.as_str());
    let removed =
        smart_folders::remove_member_removed(&mut vault, &folder.id, t.as_str(), Caller::Agent)
            .expect("an agent removes it again");
    assert!(removed);
    let after = snapshot(&vault, &t);
    assert_eq!(after.agent_read_only, 1);
    assert_eq!(after.content_md, before.content_md);
}

#[test]
fn canvas_writes_work_on_a_flagged_note() {
    let (_dir, mut vault) = fresh_vault();
    let note = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    set_flag(&vault, &note.id, true);
    let before = snapshot(&vault, &note.id);
    let c = canvas::create_canvas(&mut vault, "Board").unwrap();
    canvas::add_to_canvas(&mut vault, &c.id, note.id.as_str(), 10.0, 20.0)
        .expect("a read-only note goes on a canvas");
    let moved = canvas::move_node(&mut vault, &c.id, note.id.as_str(), 30.0, 40.0, None)
        .expect("and moves");
    assert_eq!((moved.x, moved.y), (30.0, 40.0));
    canvas::remove_from_canvas(&mut vault, &c.id, note.id.as_str()).expect("and comes off");
    assert_eq!(
        snapshot(&vault, &note.id),
        before,
        "the note itself is untouched"
    );
}

// ---------- the in-transaction recheck (review r1, finding 3) ----------

/// Runs `op` (an agent write that passes its early flag check) on a thread
/// while another connection (the app's `memex`, say) holds the write lock and
/// has set `id`'s flag, uncommitted; commits the flag once `op` is waiting
/// for the lock. Returns the vault and `op`'s result. An agent write that
/// opens a deferred transaction, or does not recheck under the lock, lands
/// anyway (or fails on a stale snapshot) instead of being `ReadOnlyRule`.
fn agent_write_racing_the_flag<T: Send + 'static>(
    dir: &std::path::Path,
    vault: Vault,
    id: &NoteId,
    op: impl FnOnce(&mut Vault) -> Result<T, MemexError> + Send + 'static,
) -> (Vault, Result<T, MemexError>) {
    let other = rusqlite::Connection::open(dir.join("memex.db")).unwrap();
    other.execute_batch("BEGIN IMMEDIATE").unwrap();
    other
        .execute(
            "UPDATE notes SET agent_read_only = 1 WHERE id = ?1",
            [id.as_str()],
        )
        .unwrap();
    let agent = std::thread::spawn(move || {
        let mut vault = vault;
        let result = op(&mut vault);
        (vault, result)
    });
    std::thread::sleep(std::time::Duration::from_millis(600));
    assert!(
        !agent.is_finished(),
        "the agent write waits for the other connection's write lock"
    );
    other.execute_batch("COMMIT").unwrap();
    agent.join().unwrap()
}

/// `after` is `before` plus the person's flag write alone.
fn assert_only_the_flag_moved(vault: &Vault, id: &NoteId, before: Snapshot, revision: i64) {
    let after = snapshot(vault, id);
    assert_eq!(after.agent_read_only, 1, "the person's flag is committed");
    assert_eq!(
        content_revision(vault),
        revision + 1,
        "only the flag write moved the revision counter"
    );
    assert_eq!(
        Snapshot {
            agent_read_only: 0,
            ..after
        },
        before,
        "no row, footer, version or updated_at written by the agent"
    );
}

#[test]
fn agent_tag_note_refuses_when_the_flag_is_set_by_another_connection_after_the_early_check() {
    let TagWorld {
        _dir, vault, note, ..
    } = tag_world();
    let before = snapshot(&vault, &note);
    let revision = content_revision(&vault);
    let id = note.clone();
    let (vault, result) = agent_write_racing_the_flag(_dir.path(), vault, &note, move |v| {
        tags::agent_tag_note(v, &id, "games", None)
    });
    assert_read_only_rule(result, "Pricing notes", "tag_note racing the flag");
    assert_only_the_flag_moved(&vault, &note, before, revision);
}

#[test]
fn agent_untag_note_refuses_when_the_flag_is_set_by_another_connection_after_the_early_check() {
    let TagWorld {
        _dir,
        mut vault,
        note,
        ..
    } = tag_world();
    tags::agent_tag_note(&mut vault, &note, "games", None).expect("an agent tag to remove");
    let before = snapshot(&vault, &note);
    assert!(before.tags.contains(&("games".into(), "agent".into())));
    let revision = content_revision(&vault);
    let id = note.clone();
    let (vault, result) = agent_write_racing_the_flag(_dir.path(), vault, &note, move |v| {
        tags::agent_untag_note(v, &id, "games", None)
    });
    assert_read_only_rule(result, "Pricing notes", "untag_note racing the flag");
    assert_only_the_flag_moved(&vault, &note, before, revision);
}

#[test]
fn agent_set_chip_refuses_when_the_flag_is_set_by_another_connection_after_the_early_check() {
    let ChipWorld {
        _dir,
        vault,
        host,
        loop_topic,
        ..
    } = chip_world();
    let before = snapshot(&vault, &host);
    let revision = content_revision(&vault);
    let id = host.clone();
    let topic_id = loop_topic.clone();
    let (vault, result) = agent_write_racing_the_flag(_dir.path(), vault, &host, move |v| {
        footer::agent_set_chip(v, &id, &topic_id, None)
    });
    assert_read_only_rule(result, "Pricing notes", "add_footer_topic racing the flag");
    assert_only_the_flag_moved(&vault, &host, before, revision);
    assert_eq!(chip_origin(&vault, &host, &loop_topic), None, "no chip row");
}

/// The recheck is the agent's alone: with the same lock held, a person's chip
/// write on a note flagged in between still lands (Req 2), after the wait.
#[test]
fn person_set_chip_still_writes_when_the_flag_is_set_by_another_connection_in_between() {
    let ChipWorld {
        _dir,
        vault,
        host,
        loop_topic,
        ..
    } = chip_world();
    let id = host.clone();
    let topic_id = loop_topic.clone();
    let (vault, result) = agent_write_racing_the_flag(_dir.path(), vault, &host, move |v| {
        footer::set_chip(v, &id, &topic_id, ChipOrigin::Person, None)
    });
    result.expect("a person's chip write on a flagged note");
    assert_eq!(
        chip_origin(&vault, &host, &loop_topic).as_deref(),
        Some("person")
    );
    assert_eq!(snapshot(&vault, &host).agent_read_only, 1);
}
