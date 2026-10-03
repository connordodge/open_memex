//! WI #8 (R5): the agent marker guard in core (Req 16 / Req 75, D3).
//!
//! `notes::update_note_as(…, Caller::Agent)` rejects, with `MarkerRule`
//! (C1: the message contains `<!-- memex:topics -->`), any write whose target
//! note is `role: daily`, or whose patch would make it `role: daily`, before
//! anything is written. Person writes are never blocked (Q1).
//! `links::update_link_as` saves through `update_note_as`, so the same guard
//! covers link edits whose source is a daily note.
//!
//! Real SQLite, real schema V5, temp vaults only.

use memex_core::daily;
use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::links::{self, LinkKind, UpdateLink};
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::{Caller, Vault};
use serde_json::{json, Value};
use tempfile::TempDir;

const MARKER: &str = "<!-- memex:topics -->";

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

fn create_topic(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, Some(json!({ "role": "topic" })))
}

fn update(
    vault: &mut Vault,
    id: &NoteId,
    patch: UpdateNote,
    caller: Caller,
) -> Result<Note, MemexError> {
    let version = get_note(vault, id).unwrap().version;
    update_note_as(vault, id, version, patch, RenameOptions::default(), caller)
}

fn body_patch(body: &str) -> UpdateNote {
    UpdateNote {
        content_md: Some(body.into()),
        ..Default::default()
    }
}

fn fm_patch(fm: Value) -> UpdateNote {
    UpdateNote {
        frontmatter: Some(fm),
        ..Default::default()
    }
}

/// Everything a rejected write must leave alone.
#[derive(Debug, PartialEq)]
struct Snapshot {
    title: String,
    content_md: String,
    frontmatter: Value,
    version: i64,
    updated_at: i64,
    blocks: Vec<(String, String)>,
    content_version: Option<i64>,
    links: Vec<(String, String, Option<String>)>,
}

fn snapshot(vault: &Vault, id: &NoteId) -> Snapshot {
    let note = get_note(vault, id).unwrap();
    let conn = vault.connection_ref();
    let blocks = conn
        .prepare("SELECT block_id, text FROM blocks WHERE note_id = ? ORDER BY ord")
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let content_version = conn
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .ok();
    let links = conn
        .prepare(
            "SELECT link_text, link_kind, label FROM links WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    Snapshot {
        title: note.title,
        content_md: note.content_md,
        frontmatter: note.frontmatter,
        version: note.version,
        updated_at: note.updated_at,
        blocks,
        content_version,
        links,
    }
}

fn assert_marker_rule(result: Result<Note, MemexError>, what: &str) {
    match result {
        Err(e @ MemexError::MarkerRule(_)) => {
            assert_eq!(e.code(), "marker_rule", "{what}");
            let json = e.to_error_json();
            assert_eq!(json["error"]["code"], "marker_rule", "{what}: {json}");
            let message = json["error"]["message"].as_str().unwrap_or_default();
            assert!(
                message.contains(MARKER),
                "{what}: the C1 message must contain the marker: {json}"
            );
        }
        other => panic!("{what}: expected MarkerRule, got {other:?}"),
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

// ---------- AC 4: agent updates of a daily note ----------

#[test]
fn agent_body_update_of_a_daily_note_fails_with_marker_rule_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");
    let before = snapshot(&v, &daily.id);

    // A person-section edit and an edit below the marker are both refused.
    for body in [
        "Morning pages, rewritten by an agent.\n",
        "Morning pages.\n<!-- memex:topics -->\n[[Sneaky~about]]\n",
        "",
    ] {
        assert_marker_rule(
            update(&mut v, &daily.id, body_patch(body), Caller::Agent),
            &format!("agent body {body:?}"),
        );
        assert_eq!(snapshot(&v, &daily.id), before, "after agent body {body:?}");
    }
}

#[test]
fn agent_frontmatter_or_title_update_of_a_daily_note_fails_with_marker_rule() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");
    let before = snapshot(&v, &daily.id);

    let patches = [
        (
            "add a key",
            fm_patch(json!({ "role": "daily", "mood": "good" })),
        ),
        ("demote to topic", fm_patch(json!({ "role": "topic" }))),
        ("drop the role", fm_patch(json!({}))),
        (
            "retitle",
            UpdateNote {
                title: Some("2026-10-02".into()),
                ..Default::default()
            },
        ),
    ];
    for (what, patch) in patches {
        assert_marker_rule(update(&mut v, &daily.id, patch, Caller::Agent), what);
        assert_eq!(snapshot(&v, &daily.id), before, "after agent {what}");
    }
}

#[test]
fn agent_update_that_sets_role_daily_fails_with_marker_rule_and_writes_nothing() {
    let (_dir, mut v) = fresh_vault();
    let role_less = create(&mut v, "2026-10-03", "Loose thoughts.\n", None);
    let topic = create_topic(&mut v, "2026-10-04", "Topic body.\n");

    for note in [&role_less, &topic] {
        let before = snapshot(&v, &note.id);
        let mut fm = note.frontmatter.clone();
        if !fm.is_object() {
            fm = json!({});
        }
        fm["role"] = "daily".into();
        assert_marker_rule(
            update(&mut v, &note.id, fm_patch(fm.clone()), Caller::Agent),
            &format!("agent sets role daily on {}", note.title),
        );
        // Together with a body change it is refused as well.
        assert_marker_rule(
            update(
                &mut v,
                &note.id,
                UpdateNote {
                    content_md: Some("Agent text.\n".into()),
                    frontmatter: Some(fm),
                    ..Default::default()
                },
                Caller::Agent,
            ),
            &format!("agent sets role daily with a body on {}", note.title),
        );
        let after = snapshot(&v, &note.id);
        assert_eq!(after, before, "{} unchanged", note.title);
        assert!(!daily::is_daily(&after.frontmatter));
        assert_eq!(after.content_version, None, "no day_reviews row");
    }
}

/// Lead ruling: the marker rule is checked before the version, so a stale
/// agent write to a daily note is `MarkerRule`, not `VersionConflict`.
#[test]
fn agent_update_of_a_daily_note_with_a_stale_version_fails_with_marker_rule() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");
    let loose = create(&mut v, "2026-10-02", "Loose thoughts.\n", None);
    let before = snapshot(&v, &daily.id);

    for stale in [daily.version - 1, daily.version + 1] {
        let result = update_note_as(
            &mut v,
            &daily.id,
            stale,
            body_patch("Agent text.\n"),
            RenameOptions::default(),
            Caller::Agent,
        );
        assert_marker_rule(result, &format!("stale {stale}"));
        let result = update_note_as(
            &mut v,
            &loose.id,
            loose.version + 1,
            fm_patch(json!({ "role": "daily" })),
            RenameOptions::default(),
            Caller::Agent,
        );
        assert_marker_rule(result, &format!("stale role change {stale}"));
    }
    assert_eq!(snapshot(&v, &daily.id), before);

    // A person write with the same stale version is a version conflict.
    let err = update_note_as(
        &mut v,
        &daily.id,
        daily.version + 1,
        body_patch("Person text.\n"),
        RenameOptions::default(),
        Caller::Person,
    )
    .map(|_| ())
    .unwrap_err();
    assert!(matches!(err, MemexError::VersionConflict { .. }), "{err:?}");
}

#[test]
fn agent_update_of_a_topic_note_still_succeeds_while_a_daily_note_is_guarded() {
    let (_dir, mut v) = fresh_vault();
    let topic = create_topic(&mut v, "Player Loop", "Topic body.\n");
    let role_less = create(&mut v, "Loose", "Loose body.\n", None);
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");

    let saved = update(
        &mut v,
        &topic.id,
        body_patch("Agent topic text.\n"),
        Caller::Agent,
    )
    .expect("agent update of a topic note");
    assert_eq!(saved.content_md, "Agent topic text.\n");
    assert_eq!(saved.version, topic.version + 1);

    let saved = update(
        &mut v,
        &role_less.id,
        fm_patch(json!({ "role": "topic" })),
        Caller::Agent,
    )
    .expect("agent may make a role-less note a topic");
    assert_eq!(saved.frontmatter["role"], "topic");

    assert_marker_rule(
        update(
            &mut v,
            &daily.id,
            body_patch("Agent text.\n"),
            Caller::Agent,
        ),
        "agent update of the daily note",
    );
}

#[test]
fn person_update_of_a_daily_note_succeeds_where_the_same_agent_update_is_rejected() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");
    let new_body = "Morning pages.\n\nAfternoon walk.\n";

    assert_marker_rule(
        update(&mut v, &daily.id, body_patch(new_body), Caller::Agent),
        "agent",
    );
    let saved = update(&mut v, &daily.id, body_patch(new_body), Caller::Person)
        .expect("person update of a daily note");
    assert_eq!(saved.version, daily.version + 1);
    assert_eq!(saved.content_md, format!("{new_body}{MARKER}\n"));

    // Person frontmatter edits of a daily note are not blocked either.
    let saved = update(
        &mut v,
        &daily.id,
        fm_patch(json!({ "role": "daily", "mood": "good" })),
        Caller::Person,
    )
    .expect("person frontmatter update of a daily note");
    assert_eq!(saved.frontmatter["mood"], "good");
}

#[test]
fn person_update_that_sets_role_daily_succeeds_where_the_agent_is_rejected() {
    let (_dir, mut v) = fresh_vault();
    let note = create(&mut v, "2026-10-05", "Loose thoughts.\n", None);
    let fm = json!({ "role": "daily" });

    assert_marker_rule(
        update(&mut v, &note.id, fm_patch(fm.clone()), Caller::Agent),
        "agent",
    );
    let saved = update(&mut v, &note.id, fm_patch(fm), Caller::Person)
        .expect("person may make a note daily");
    assert!(daily::is_daily(&saved.frontmatter));
    assert_eq!(saved.content_md, format!("Loose thoughts.\n{MARKER}\n"));
}

// ---------- AC 2 / AC 4 in core: link edits through update_link_as ----------

#[test]
fn agent_update_link_with_a_daily_source_fails_with_marker_rule_and_person_succeeds() {
    let (_dir, mut v) = fresh_vault();
    let _topic = create_topic(&mut v, "Player Loop", "Topic body.\n");
    let daily = create_daily(
        &mut v,
        "2026-10-01",
        "Thinking about [[Player Loop]] today.\n",
    );
    let link_id = link_id_from(&v, &daily.id, "Player Loop");
    let before = snapshot(&v, &daily.id);

    let kind_change = || UpdateLink {
        new_kind: Some(LinkKind::new("extends").unwrap()),
        new_label: None,
    };
    let label_change = || UpdateLink {
        new_kind: None,
        new_label: Some(Some("the loop".into())),
    };
    for (what, patch) in [("kind", kind_change()), ("label", label_change())] {
        let err = links::update_link_as(&mut v, &link_id, patch, Caller::Agent)
            .map(|_| ())
            .expect_err(what);
        assert!(
            matches!(err, MemexError::MarkerRule(_)),
            "agent {what} change: {err:?}"
        );
        assert!(err.to_string().contains(MARKER), "{err}");
        assert_eq!(snapshot(&v, &daily.id), before, "after agent {what} change");
    }

    let link = links::update_link_as(&mut v, &link_id, kind_change(), Caller::Person)
        .expect("person update_link on a daily source");
    assert_eq!(link.link_kind.as_str(), "extends");
    let stored = get_note(&v, &daily.id).unwrap();
    assert!(
        stored.content_md.contains("[[Player Loop~extends]]"),
        "{:?}",
        stored.content_md
    );
    assert_eq!(stored.version, daily.version + 1);
}

#[test]
fn agent_update_link_from_a_topic_note_to_a_daily_note_succeeds() {
    let (_dir, mut v) = fresh_vault();
    let daily = create_daily(&mut v, "2026-10-01", "Morning pages.\n");
    let topic = create_topic(&mut v, "Player Loop", "See [[2026-10-01]] for the idea.\n");
    let link_id = link_id_from(&v, &topic.id, "2026-10-01");
    let daily_before = snapshot(&v, &daily.id);

    let link = links::update_link_as(
        &mut v,
        &link_id,
        UpdateLink {
            new_kind: Some(LinkKind::new("extends").unwrap()),
            new_label: None,
        },
        Caller::Agent,
    )
    .expect("agent may edit a link whose source is a topic note");
    assert_eq!(link.link_kind.as_str(), "extends");
    assert_eq!(
        snapshot(&v, &daily.id),
        daily_before,
        "the daily note is untouched"
    );

    // The guard is on the source note: the same agent edit on a daily
    // source is refused.
    let from_daily = create_daily(&mut v, "2026-10-02", "Back to [[Player Loop]].\n");
    let daily_link = link_id_from(&v, &from_daily.id, "Player Loop");
    let err = links::update_link_as(
        &mut v,
        &daily_link,
        UpdateLink {
            new_kind: Some(LinkKind::new("extends").unwrap()),
            new_label: None,
        },
        Caller::Agent,
    )
    .map(|_| ())
    .unwrap_err();
    assert!(matches!(err, MemexError::MarkerRule(_)), "{err:?}");
}
