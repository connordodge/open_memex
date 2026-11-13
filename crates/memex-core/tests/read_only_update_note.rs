//! WI #8 (Spec #7 Req 2, 5, 9 and 10, ruling D3): the Agent read-only guard
//! in core.
//!
//! - `notes::check_agent_read_only(conn, caller, note_id)` passes a person
//!   caller always, passes an agent on a note whose `agent_read_only` is 0,
//!   and refuses an agent on a flagged note with `ReadOnlyRule`, whose
//!   message is exactly `"<title>" is read-only for agents; the person can
//!   change this in the app`.
//! - `notes::update_note_as(…, Caller::Agent)` runs it right after
//!   `check_agent_write` and before every other check, the version check
//!   included: a flagged note answers `read_only_rule` even with a stale
//!   `expected_version`, and nothing is written.
//! - `update_note_as(…, Caller::Person)` saves a flagged note normally.
//!
//! Nothing in WI #8 sets the flag: these tests set it with raw SQL
//! (`UPDATE notes SET agent_read_only = 1`). Real SQLite, temp vaults only.

use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::links::{self, LinkKind, UpdateLink};
use memex_core::notes::{
    self, check_agent_read_only, create_note_as, get_note, update_note_as, CreateNote, Note,
    NoteId, RenameOptions, UpdateNote,
};
use memex_core::{Caller, Vault};
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

/// On a build without schema V8 (the gate's red-on-main run) adds the
/// `notes.agent_read_only` column, so these tests fail on the guard, not on
/// the schema; the schema itself is pinned in `migration_v8.rs`. A no-op at V8.
fn ensure_flag_column(vault: &Vault) {
    let conn = vault.connection_ref();
    let has: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('notes') WHERE name = 'agent_read_only'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    if has == 0 {
        conn.execute_batch(
            "ALTER TABLE notes ADD COLUMN agent_read_only INTEGER NOT NULL DEFAULT 0;",
        )
        .unwrap();
    }
}

/// Sets or clears the flag the way WI #8's tests must: raw SQL.
fn set_flag(vault: &Vault, id: &NoteId, on: bool) {
    ensure_flag_column(vault);
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE notes SET agent_read_only = ?1 WHERE id = ?2",
            rusqlite::params![i64::from(on), id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "the note exists");
}

fn flag(vault: &Vault, id: &NoteId) -> i64 {
    ensure_flag_column(vault);
    vault
        .connection_ref()
        .query_row(
            "SELECT agent_read_only FROM notes WHERE id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

/// The Req 9 message for `title`.
fn read_only_message(title: &str) -> String {
    format!("\"{title}\" is read-only for agents; the person can change this in the app")
}

fn body_patch(body: &str) -> UpdateNote {
    UpdateNote {
        content_md: Some(body.into()),
        ..Default::default()
    }
}

/// Everything a refused write must leave alone.
#[derive(Debug, PartialEq)]
struct Snapshot {
    title: String,
    content_md: String,
    frontmatter: Value,
    version: i64,
    updated_at: i64,
    agent_read_only: i64,
    tags: Vec<String>,
    links: Vec<(String, String, Option<String>)>,
    content_revision: i64,
}

fn snapshot(vault: &Vault, id: &NoteId) -> Snapshot {
    let note = get_note(vault, id).unwrap();
    let conn = vault.connection_ref();
    let tags = conn
        .prepare("SELECT tag FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap()
        .query_map([id.as_str()], |r| r.get(0))
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
    let content_revision = conn
        .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
            r.get(0)
        })
        .unwrap();
    Snapshot {
        title: note.title,
        content_md: note.content_md,
        frontmatter: note.frontmatter,
        version: note.version,
        updated_at: note.updated_at,
        agent_read_only: flag(vault, id),
        tags,
        links,
        content_revision,
    }
}

/// `result` is `ReadOnlyRule` with code `read_only_rule` and exactly the
/// Req 9 message for `title`.
fn assert_read_only_rule<T: std::fmt::Debug>(
    result: Result<T, MemexError>,
    title: &str,
    what: &str,
) {
    match result {
        Err(e @ MemexError::ReadOnlyRule(_)) => {
            assert_eq!(e.code(), "read_only_rule", "{what}");
            assert_eq!(e.to_string(), read_only_message(title), "{what}");
            assert_eq!(
                e.to_error_json(),
                json!({"error": {"code": "read_only_rule", "message": read_only_message(title)}}),
                "{what}"
            );
        }
        other => panic!("{what}: expected ReadOnlyRule, got {other:?}"),
    }
}

fn link_id_from(vault: &Vault, from: &NoteId, link_text: &str) -> String {
    vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links WHERE from_note_id = ? AND link_text = ? ORDER BY position LIMIT 1",
            [from.as_str(), link_text],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("no link {link_text:?} from {from}: {e}"))
}

// ---------- check_agent_read_only ----------

#[test]
fn check_agent_read_only_passes_a_person_and_an_unflagged_agent_but_refuses_a_flagged_agent() {
    let (_dir, mut v) = fresh_vault();
    let flagged = create(&mut v, "Pricing notes", "Tiers.\n", None);
    let open_note = create(&mut v, "Roadmap", "Q1.\n", None);
    set_flag(&v, &flagged.id, true);
    let conn = v.connection_ref();

    // Both directions of the boundary, on the same vault.
    check_agent_read_only(conn, Caller::Person, &flagged.id)
        .expect("a person always passes, even on a flagged note");
    check_agent_read_only(conn, Caller::Person, &open_note.id).expect("person, unflagged");
    check_agent_read_only(conn, Caller::Agent, &open_note.id)
        .expect("an agent passes on an unflagged note");
    assert_read_only_rule(
        check_agent_read_only(conn, Caller::Agent, &flagged.id),
        "Pricing notes",
        "agent on a flagged note",
    );

    // It reads the flag as stored now: cleared, the agent passes again;
    // set on the other note, that one refuses.
    set_flag(&v, &flagged.id, false);
    set_flag(&v, &open_note.id, true);
    let conn = v.connection_ref();
    check_agent_read_only(conn, Caller::Agent, &flagged.id).expect("cleared flag passes");
    assert_read_only_rule(
        check_agent_read_only(conn, Caller::Agent, &open_note.id),
        "Roadmap",
        "the newly flagged note",
    );
    check_agent_read_only(conn, Caller::Person, &open_note.id).expect("person still passes");
}

#[test]
fn check_agent_read_only_refuses_a_flagged_note_with_read_only_rule_naming_its_title() {
    let (_dir, mut v) = fresh_vault();
    // Built from run-time values: the message follows the stored title.
    let title = format!("Q{} launch: \"beta\" plan", std::hint::black_box(3u8));
    let note = create(&mut v, &title, "Ship it.\n", None);
    set_flag(&v, &note.id, true);
    let err = check_agent_read_only(v.connection_ref(), Caller::Agent, &note.id)
        .expect_err("flagged note, agent caller");
    assert_eq!(
        err.to_string(),
        format!("\"{title}\" is read-only for agents; the person can change this in the app")
    );
    assert_read_only_rule(Err::<(), _>(err), &title, "run-time title");

    // A retitled note's message names the new title.
    let renamed = update_note_as(
        &mut v,
        &note.id,
        note.version,
        UpdateNote {
            title: Some("Café pricing".into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .expect("the person renames the flagged note");
    assert_eq!(renamed.title, "Café pricing");
    assert_read_only_rule(
        check_agent_read_only(v.connection_ref(), Caller::Agent, &note.id),
        "Café pricing",
        "after a rename",
    );
}

#[test]
fn check_agent_read_only_passes_an_agent_on_a_missing_note() {
    // Callers answer not_found themselves; the guard adds no error of its own.
    let (_dir, v) = fresh_vault();
    let missing = NoteId::new();
    check_agent_read_only(v.connection_ref(), Caller::Agent, &missing)
        .expect("a missing note is the caller's not_found, not read_only_rule");
    check_agent_read_only(v.connection_ref(), Caller::Person, &missing).unwrap();
}

// ---------- update_note_as(Agent) on a flagged note ----------

#[test]
fn update_note_as_agent_on_a_flagged_note_is_read_only_rule_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let _games = create(&mut v, "Games", "Topic.\n", None);
    let note = create(
        &mut v,
        "Pricing notes",
        "Tiers and #pricing, see [[Games]].\n",
        None,
    );
    set_flag(&v, &note.id, true);
    let before = snapshot(&v, &note.id);
    assert_eq!(before.agent_read_only, 1);
    assert_eq!(before.tags, ["pricing"], "fixture: a body tag");
    assert_eq!(before.links.len(), 1, "fixture: a link");

    let patches = [
        ("body", body_patch("Tiers rewritten by an agent.\n")),
        (
            "title",
            UpdateNote {
                title: Some("Agent title".into()),
                ..Default::default()
            },
        ),
        (
            "frontmatter",
            UpdateNote {
                frontmatter: Some(json!({ "status": "draft" })),
                ..Default::default()
            },
        ),
        ("empty patch", UpdateNote::default()),
    ];
    for (what, patch) in patches {
        assert_read_only_rule(
            update_note_as(
                &mut v,
                &note.id,
                before.version,
                patch,
                RenameOptions::default(),
                Caller::Agent,
            ),
            "Pricing notes",
            what,
        );
        assert_eq!(
            snapshot(&v, &note.id),
            before,
            "{what}: version, body, updated_at and everything else unchanged"
        );
    }
}

#[test]
fn update_note_as_agent_on_a_flagged_note_with_a_stale_version_is_read_only_rule_not_version_conflict(
) {
    let (_dir, mut v) = fresh_vault();
    let note = create(&mut v, "Pricing notes", "Tiers.\n", None);
    // The person saves once more, so the agent's version is stale.
    let saved = update_note_as(
        &mut v,
        &note.id,
        note.version,
        body_patch("Tiers, revised.\n"),
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap();
    assert_eq!(saved.version, note.version + 1);
    set_flag(&v, &note.id, true);
    let before = snapshot(&v, &note.id);

    for stale in [note.version, saved.version + 5, 0, -1] {
        assert_read_only_rule(
            update_note_as(
                &mut v,
                &note.id,
                stale,
                body_patch("Agent retry.\n"),
                RenameOptions::default(),
                Caller::Agent,
            ),
            "Pricing notes",
            &format!("expected_version {stale}"),
        );
        assert_eq!(
            snapshot(&v, &note.id),
            before,
            "stale {stale}: nothing written"
        );
    }

    // Unflagged, the same stale save is a version conflict again.
    set_flag(&v, &note.id, false);
    match update_note_as(
        &mut v,
        &note.id,
        note.version,
        body_patch("Agent retry.\n"),
        RenameOptions::default(),
        Caller::Agent,
    ) {
        Err(MemexError::VersionConflict { expected, current }) => {
            assert_eq!((expected, current), (note.version, saved.version));
        }
        other => panic!("expected VersionConflict, got {other:?}"),
    }
}

#[test]
fn update_note_as_agent_read_only_rule_wins_over_title_errors() {
    // The guard runs before every validation that follows the agent-write
    // check, not only before the version check.
    let (_dir, mut v) = fresh_vault();
    let _taken = create(&mut v, "Taken", "Other.\n", None);
    let note = create(&mut v, "Pricing notes", "Tiers.\n", None);
    set_flag(&v, &note.id, true);
    let before = snapshot(&v, &note.id);
    for (what, title) in [
        ("title conflict", "Taken"),
        ("invalid title", ""),
        ("newline title", "two\nlines"),
    ] {
        assert_read_only_rule(
            update_note_as(
                &mut v,
                &note.id,
                note.version,
                UpdateNote {
                    title: Some(title.into()),
                    ..Default::default()
                },
                RenameOptions::default(),
                Caller::Agent,
            ),
            "Pricing notes",
            what,
        );
        assert_eq!(snapshot(&v, &note.id), before, "{what}");
    }
}

#[test]
fn update_note_as_agent_marker_and_guide_rules_still_come_before_read_only_rule() {
    // D3: the read-only check sits right after check_agent_write, so a
    // flagged daily note or Vault Guide keeps its own rule code.
    let (_dir, mut v) = fresh_vault();
    let daily = create(
        &mut v,
        "2026-11-13",
        "Standup.\n",
        Some(json!({ "role": "daily" })),
    );
    let doc = memex_core::guide::get_or_create(&mut v, &memex_core::canvas::SystemClock, None)
        .expect("the Vault Guide is created on first read");
    let guide = get_note(&v, &NoteId::parse(&doc.note_id).unwrap()).unwrap();
    set_flag(&v, &daily.id, true);
    set_flag(&v, &guide.id, true);
    let daily_before = snapshot(&v, &daily.id);
    let guide_before = snapshot(&v, &guide.id);

    let err = update_note_as(
        &mut v,
        &daily.id,
        daily.version,
        body_patch("Agent text.\n"),
        RenameOptions::default(),
        Caller::Agent,
    )
    .expect_err("agent on a flagged daily note");
    assert_eq!(err.code(), "marker_rule", "{err:?}");
    let err = update_note_as(
        &mut v,
        &guide.id,
        guide.version,
        body_patch("Agent guide.\n"),
        RenameOptions::default(),
        Caller::Agent,
    )
    .expect_err("agent on a flagged Vault Guide");
    assert_eq!(err.code(), "guide_rule", "{err:?}");
    assert_eq!(snapshot(&v, &daily.id), daily_before);
    assert_eq!(snapshot(&v, &guide.id), guide_before);
}

#[test]
fn update_note_as_agent_saves_an_unflagged_note_and_is_refused_once_it_is_flagged() {
    let (_dir, mut v) = fresh_vault();
    let note = create(&mut v, "Pricing notes", "Tiers.\n", None);
    let saved = update_note_as(
        &mut v,
        &note.id,
        note.version,
        body_patch("Tiers, by the agent.\n"),
        RenameOptions::default(),
        Caller::Agent,
    )
    .expect("an agent saves a note that is not read-only");
    assert_eq!(saved.version, note.version + 1);
    assert_eq!(flag(&v, &note.id), 0, "an agent write never sets the flag");

    set_flag(&v, &note.id, true);
    let before = snapshot(&v, &note.id);
    assert_read_only_rule(
        update_note_as(
            &mut v,
            &note.id,
            saved.version,
            body_patch("Tiers, again.\n"),
            RenameOptions::default(),
            Caller::Agent,
        ),
        "Pricing notes",
        "after the person flags it",
    );
    assert_eq!(snapshot(&v, &note.id), before);

    set_flag(&v, &note.id, false);
    let again = update_note_as(
        &mut v,
        &note.id,
        saved.version,
        body_patch("Tiers, again.\n"),
        RenameOptions::default(),
        Caller::Agent,
    )
    .expect("cleared, the agent saves again");
    assert_eq!(again.version, saved.version + 1);
}

// ---------- update_note_as(Person) on a flagged note ----------

#[test]
fn update_note_as_person_saves_a_flagged_note_that_an_agent_may_not() {
    let (_dir, mut v) = fresh_vault();
    let note = create(&mut v, "Pricing notes", "Tiers.\n", None);
    set_flag(&v, &note.id, true);

    // The agent is refused first, so this test proves the boundary both ways.
    assert_read_only_rule(
        update_note_as(
            &mut v,
            &note.id,
            note.version,
            body_patch("Agent tiers.\n"),
            RenameOptions::default(),
            Caller::Agent,
        ),
        "Pricing notes",
        "agent",
    );

    let saved = update_note_as(
        &mut v,
        &note.id,
        note.version,
        UpdateNote {
            title: Some("Pricing".into()),
            content_md: Some("Tiers by the person #pricing.\n".into()),
            frontmatter: Some(json!({ "status": "final" })),
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .expect("a person write is never blocked by Agent read-only");
    assert_eq!(saved.version, note.version + 1);
    assert_eq!(saved.title, "Pricing");
    assert!(saved
        .content_md
        .starts_with("Tiers by the person #pricing.\n"));
    let stored = get_note(&v, &note.id).unwrap();
    assert_eq!(stored.version, saved.version);
    assert_eq!(stored.content_md, saved.content_md);
    assert_eq!(stored.frontmatter, json!({ "status": "final" }));
    assert_eq!(flag(&v, &note.id), 1, "a person save keeps the flag");
    let tags = snapshot(&v, &note.id).tags;
    assert_eq!(
        tags,
        ["pricing"],
        "the person save derives body tags as usual"
    );

    // The person path keeps its own version check.
    match update_note_as(
        &mut v,
        &note.id,
        note.version,
        body_patch("Stale person save.\n"),
        RenameOptions::default(),
        Caller::Person,
    ) {
        Err(MemexError::VersionConflict { expected, current }) => {
            assert_eq!((expected, current), (note.version, saved.version));
        }
        other => panic!("expected VersionConflict, got {other:?}"),
    }
    // And the default person entry point (`update_note`) saves too.
    let again = notes::update_note(
        &mut v,
        &note.id,
        saved.version,
        body_patch("Person, once more.\n"),
    )
    .expect("update_note is the person path");
    assert_eq!(again.version, saved.version + 1);
}

// ---------- link edits save through update_note_as ----------

#[test]
fn update_link_as_agent_on_a_flagged_source_is_read_only_rule_and_person_succeeds() {
    let (_dir, mut v) = fresh_vault();
    let _topic = create(&mut v, "Player Loop", "Topic body.\n", None);
    let source = create(
        &mut v,
        "Pricing notes",
        "Thinking about [[Player Loop]] today.\n",
        None,
    );
    let link_id = link_id_from(&v, &source.id, "Player Loop");
    set_flag(&v, &source.id, true);
    let before = snapshot(&v, &source.id);

    let kind_change = || UpdateLink {
        new_kind: Some(LinkKind::new("extends").unwrap()),
        new_label: None,
    };
    assert_read_only_rule(
        links::update_link_as(&mut v, &link_id, kind_change(), Caller::Agent),
        "Pricing notes",
        "agent link kind change",
    );
    assert_eq!(snapshot(&v, &source.id), before);

    links::update_link_as(&mut v, &link_id, kind_change(), Caller::Person)
        .expect("the person edits a link on a flagged note");
    let after = snapshot(&v, &source.id);
    assert_eq!(after.version, before.version + 1);
    assert_eq!(after.links[0].1, "extends");
}
