//! WI #9 (Spec #7 Req 3, 4, 7, 7a, 8; rulings D5, D6): the person-only
//! Agent read-only setter and the flag on the note read.
//!
//! - `notes::set_agent_read_only(vault, id, on) -> Result<bool>` writes only
//!   `notes.agent_read_only` (`version`, `updated_at`, body, title and
//!   frontmatter stay) and returns whether it changed. The value the note
//!   already has writes nothing (`content_revision.n` unchanged). Setting it
//!   on a daily note or the Vault Guide is `RoleRule`; clearing is always
//!   allowed. An unknown note is `NotFound`.
//! - A person save of any kind keeps the flag.
//! - `notes::note_agent_fields(vault, note)` is exactly
//!   `{"agent_read_only": bool}`.
//!
//! Real SQLite, temp vaults only.

use memex_core::error::MemexError;
use memex_core::indexer;
use memex_core::notes::{
    self, check_agent_read_only, create_note_as, get_note, note_agent_fields, set_agent_read_only,
    update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::{Caller, SystemClock, Vault};
use serde_json::{json, Map, Value};
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

fn flag(vault: &Vault, id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT agent_read_only FROM notes WHERE id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

/// Raw SQL, for states the setter refuses to make (a flagged daily note).
fn raw_flag(vault: &Vault, id: &NoteId) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE notes SET agent_read_only = 1 WHERE id = ?",
            [id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1);
}

fn content_revision(vault: &Vault) -> i64 {
    vault
        .connection_ref()
        .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
            r.get(0)
        })
        .unwrap()
}

/// Every stored field of the note but the flag.
#[derive(Debug, PartialEq)]
struct Stored {
    title: String,
    content_md: String,
    frontmatter: String,
    version: i64,
    created_at: i64,
    updated_at: i64,
}

fn stored(vault: &Vault, id: &NoteId) -> Stored {
    vault
        .connection_ref()
        .query_row(
            "SELECT title, content_md, frontmatter, version, created_at, updated_at
             FROM notes WHERE id = ?",
            [id.as_str()],
            |r| {
                Ok(Stored {
                    title: r.get(0)?,
                    content_md: r.get(1)?,
                    frontmatter: r.get(2)?,
                    version: r.get(3)?,
                    created_at: r.get(4)?,
                    updated_at: r.get(5)?,
                })
            },
        )
        .unwrap()
}

fn guide_id(vault: &mut Vault) -> NoteId {
    let doc = memex_core::guide::get_or_create(vault, &SystemClock, None)
        .expect("the Vault Guide is created on first read");
    NoteId::parse(&doc.note_id).unwrap()
}

fn agent_fields(vault: &Vault, id: &NoteId) -> Map<String, Value> {
    let note = get_note(vault, id).unwrap();
    note_agent_fields(vault, &note).expect("agent fields")
}

fn assert_role_rule<T: std::fmt::Debug>(result: Result<T, MemexError>, what: &str) {
    match result {
        Err(e @ MemexError::RoleRule(_)) => assert_eq!(e.code(), "role_rule", "{what}"),
        other => panic!("{what}: expected RoleRule, got {other:?}"),
    }
}

// ---------- set ----------

#[test]
fn set_agent_read_only_on_a_plain_or_topic_note_sets_the_flag_and_keeps_version_and_updated_at() {
    let (_dir, mut vault) = fresh_vault();
    let plain = create(&mut vault, "Pricing notes", "Tiers #pricing.\n", None);
    let topic_note = create(
        &mut vault,
        "Player Loop",
        "All about the loop.\n",
        Some(json!({ "role": "topic" })),
    );
    for (what, note) in [("plain", &plain), ("topic", &topic_note)] {
        let before = stored(&vault, &note.id);
        let revision = content_revision(&vault);
        assert_eq!(flag(&vault, &note.id), 0, "{what}: every note starts off");

        let changed = set_agent_read_only(&mut vault, &note.id, true)
            .unwrap_or_else(|e| panic!("{what}: set: {e}"));
        assert!(changed, "{what}: setting a cleared flag changes it");
        assert_eq!(flag(&vault, &note.id), 1, "{what}: the flag is stored");
        assert_eq!(
            stored(&vault, &note.id),
            before,
            "{what}: version, updated_at, body, title and frontmatter unchanged"
        );
        assert_eq!(
            content_revision(&vault),
            revision + 1,
            "{what}: one row moved (the hosted poller sees the toggle)"
        );
    }
}

#[test]
fn set_agent_read_only_false_on_a_flagged_note_clears_it_and_keeps_version() {
    let (_dir, mut vault) = fresh_vault();
    let note = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    assert!(set_agent_read_only(&mut vault, &note.id, true).unwrap());
    let before = stored(&vault, &note.id);
    let revision = content_revision(&vault);

    let changed = set_agent_read_only(&mut vault, &note.id, false).expect("clear");
    assert!(changed, "clearing a set flag changes it");
    assert_eq!(flag(&vault, &note.id), 0);
    assert_eq!(stored(&vault, &note.id), before);
    assert_eq!(content_revision(&vault), revision + 1);
}

#[test]
fn set_agent_read_only_with_the_value_the_note_already_has_writes_nothing() {
    let (_dir, mut vault) = fresh_vault();
    let note = create(&mut vault, "Pricing notes", "Tiers.\n", None);

    // Clear on a note that was never set.
    let revision = content_revision(&vault);
    assert!(!set_agent_read_only(&mut vault, &note.id, false).unwrap());
    assert_eq!(
        content_revision(&vault),
        revision,
        "clear again writes nothing"
    );
    assert_eq!(flag(&vault, &note.id), 0);

    // Set, then set again.
    assert!(set_agent_read_only(&mut vault, &note.id, true).unwrap());
    let before = stored(&vault, &note.id);
    let revision = content_revision(&vault);
    for round in 0..2 {
        let changed = set_agent_read_only(&mut vault, &note.id, true).unwrap();
        assert!(!changed, "round {round}: the flag is already set");
        assert_eq!(content_revision(&vault), revision, "round {round}");
        assert_eq!(flag(&vault, &note.id), 1);
        assert_eq!(stored(&vault, &note.id), before);
    }

    // Clear, then clear again.
    assert!(set_agent_read_only(&mut vault, &note.id, false).unwrap());
    let revision = content_revision(&vault);
    assert!(!set_agent_read_only(&mut vault, &note.id, false).unwrap());
    assert_eq!(content_revision(&vault), revision);
    assert_eq!(flag(&vault, &note.id), 0);
}

#[test]
fn set_agent_read_only_touches_only_the_named_note() {
    let (_dir, mut vault) = fresh_vault();
    let a = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    let b = create(&mut vault, "Roadmap", "Q1.\n", None);
    let b_before = stored(&vault, &b.id);
    assert!(set_agent_read_only(&mut vault, &a.id, true).unwrap());
    assert_eq!(flag(&vault, &a.id), 1);
    assert_eq!(flag(&vault, &b.id), 0, "the other note keeps its flag");
    assert_eq!(stored(&vault, &b.id), b_before);
    assert!(set_agent_read_only(&mut vault, &b.id, true).unwrap());
    assert!(set_agent_read_only(&mut vault, &a.id, false).unwrap());
    assert_eq!((flag(&vault, &a.id), flag(&vault, &b.id)), (0, 1));
}

#[test]
fn set_agent_read_only_on_a_daily_note_is_role_rule_and_clearing_it_succeeds() {
    let (_dir, mut vault) = fresh_vault();
    let daily = create(
        &mut vault,
        "2026-11-13",
        "Standup notes.\n",
        Some(json!({ "role": "daily" })),
    );
    let before = stored(&vault, &daily.id);
    let revision = content_revision(&vault);
    assert_role_rule(
        set_agent_read_only(&mut vault, &daily.id, true),
        "set on a daily note",
    );
    assert_eq!(flag(&vault, &daily.id), 0, "nothing written");
    assert_eq!(stored(&vault, &daily.id), before);
    assert_eq!(content_revision(&vault), revision);

    // Clearing is always allowed: a no-op here...
    assert!(!set_agent_read_only(&mut vault, &daily.id, false).expect("clear on a daily note"));
    // ...and a real clear on a daily note flagged some other way.
    raw_flag(&vault, &daily.id);
    assert!(set_agent_read_only(&mut vault, &daily.id, false).expect("clear a flagged daily"));
    assert_eq!(flag(&vault, &daily.id), 0);
    assert_eq!(stored(&vault, &daily.id), before);
}

#[test]
fn set_agent_read_only_on_the_vault_guide_is_role_rule_and_clearing_it_succeeds() {
    let (_dir, mut vault) = fresh_vault();
    let guide = guide_id(&mut vault);
    let before = stored(&vault, &guide);
    assert_role_rule(
        set_agent_read_only(&mut vault, &guide, true),
        "set on the Vault Guide",
    );
    assert_eq!(flag(&vault, &guide), 0);
    assert_eq!(stored(&vault, &guide), before);

    assert!(!set_agent_read_only(&mut vault, &guide, false).expect("clear on the guide"));
    raw_flag(&vault, &guide);
    assert!(set_agent_read_only(&mut vault, &guide, false).expect("clear a flagged guide"));
    assert_eq!(flag(&vault, &guide), 0);
}

#[test]
fn set_agent_read_only_on_an_unknown_note_is_not_found() {
    let (_dir, mut vault) = fresh_vault();
    let missing = NoteId::new();
    for on in [true, false] {
        match set_agent_read_only(&mut vault, &missing, on) {
            Err(e @ MemexError::NotFound(_)) => assert_eq!(e.code(), "not_found"),
            other => panic!("on={on}: expected NotFound, got {other:?}"),
        }
    }
}

#[test]
fn set_agent_read_only_binds_agent_writes_until_cleared() {
    let (_dir, mut vault) = fresh_vault();
    let note = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    let patch = || UpdateNote {
        content_md: Some("Agent tiers.\n".into()),
        ..Default::default()
    };
    assert!(set_agent_read_only(&mut vault, &note.id, true).unwrap());
    let err = check_agent_read_only(vault.connection_ref(), Caller::Agent, &note.id)
        .expect_err("flagged by the setter");
    assert_eq!(err.code(), "read_only_rule");
    let err = update_note_as(
        &mut vault,
        &note.id,
        note.version,
        patch(),
        RenameOptions::default(),
        Caller::Agent,
    )
    .expect_err("the agent save is refused");
    assert_eq!(err.code(), "read_only_rule");

    assert!(set_agent_read_only(&mut vault, &note.id, false).unwrap());
    // The toggle kept the version, so the agent's version is still current.
    let saved = update_note_as(
        &mut vault,
        &note.id,
        note.version,
        patch(),
        RenameOptions::default(),
        Caller::Agent,
    )
    .expect("cleared, the agent saves on the version it read before the toggles");
    assert_eq!(saved.version, note.version + 1);
}

// ---------- person writes keep the flag ----------

#[test]
fn person_update_note_on_a_flagged_note_keeps_agent_read_only() {
    let (_dir, mut vault) = fresh_vault();
    let note = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    assert!(set_agent_read_only(&mut vault, &note.id, true).unwrap());
    let patches: [(&str, UpdateNote); 4] = [
        (
            "body",
            UpdateNote {
                content_md: Some("Tiers, by the person #pricing.\n".into()),
                ..Default::default()
            },
        ),
        (
            "title",
            UpdateNote {
                title: Some("Pricing".into()),
                ..Default::default()
            },
        ),
        (
            "frontmatter",
            UpdateNote {
                frontmatter: Some(json!({ "status": "final", "agent_read_only": false })),
                ..Default::default()
            },
        ),
        (
            "everything",
            UpdateNote {
                title: Some("Pricing plan".into()),
                content_md: Some("Plan.\n".into()),
                frontmatter: Some(json!({ "role": "topic" })),
            },
        ),
    ];
    let mut version = note.version;
    for (what, patch) in patches {
        let saved = update_note_as(
            &mut vault,
            &note.id,
            version,
            patch,
            RenameOptions::default(),
            Caller::Person,
        )
        .unwrap_or_else(|e| panic!("{what}: {e}"));
        assert_eq!(saved.version, version + 1, "{what}: saved");
        version = saved.version;
        assert_eq!(
            flag(&vault, &note.id),
            1,
            "{what}: a person save keeps the flag"
        );
        assert_eq!(
            agent_fields(&vault, &note.id),
            json!({ "agent_read_only": true })
                .as_object()
                .unwrap()
                .clone(),
            "{what}"
        );
    }
    // `update_note`, the default person entry point, too.
    notes::update_note(
        &mut vault,
        &note.id,
        version,
        UpdateNote {
            content_md: Some("Once more.\n".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(flag(&vault, &note.id), 1);
}

#[test]
fn a_rename_that_rewrites_a_flagged_linker_keeps_its_flag() {
    let (_dir, mut vault) = fresh_vault();
    let target = create(&mut vault, "Roadmap", "Q1.\n", None);
    let linker = create(&mut vault, "Pricing notes", "See [[Roadmap]].\n", None);
    assert!(set_agent_read_only(&mut vault, &linker.id, true).unwrap());
    update_note_as(
        &mut vault,
        &target.id,
        target.version,
        UpdateNote {
            title: Some("Product roadmap".into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .expect("the person renames the target");
    let rewritten = get_note(&vault, &linker.id).unwrap();
    assert!(
        rewritten.content_md.contains("[[Product roadmap]]"),
        "the rename pass rewrote the linker: {}",
        rewritten.content_md
    );
    assert_eq!(
        flag(&vault, &linker.id),
        1,
        "the rename pass keeps the flag"
    );
}

// ---------- note_agent_fields ----------

#[test]
fn note_agent_fields_reports_the_flag_as_a_bool() {
    let (_dir, mut vault) = fresh_vault();
    let note = create(&mut vault, "Pricing notes", "Tiers.\n", None);
    let daily = create(
        &mut vault,
        "2026-11-13",
        "Standup.\n",
        Some(json!({ "role": "daily" })),
    );
    let off = json!({ "agent_read_only": false })
        .as_object()
        .unwrap()
        .clone();
    let on = json!({ "agent_read_only": true })
        .as_object()
        .unwrap()
        .clone();

    assert_eq!(
        agent_fields(&vault, &note.id),
        off,
        "exactly one key, false"
    );
    assert_eq!(
        agent_fields(&vault, &daily.id),
        off,
        "a daily note is false"
    );
    assert!(set_agent_read_only(&mut vault, &note.id, true).unwrap());
    assert_eq!(agent_fields(&vault, &note.id), on);
    assert_eq!(agent_fields(&vault, &daily.id), off, "per note");
    assert!(set_agent_read_only(&mut vault, &note.id, false).unwrap());
    assert_eq!(agent_fields(&vault, &note.id), off);

    // Any stored non-zero value reads as true.
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET agent_read_only = 2 WHERE id = ?",
            [note.id.as_str()],
        )
        .unwrap();
    assert_eq!(agent_fields(&vault, &note.id), on);
}
