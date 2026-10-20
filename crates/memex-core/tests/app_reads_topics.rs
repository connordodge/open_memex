//! WI #83 (V3), AC 4: the topics reads of the app API (`app_reads::topics`)
//! read exactly what the app's local `TopicsReads` reads today
//! (app/lib/src/db/topics_reads.dart:56-101), on temp vaults.
//!
//! - unsorted: every note in no Smart Folder whose role is not `daily`
//!   (the app's SQL: `role IS NULL OR role != 'daily'`); invalid-JSON
//!   frontmatter counts as role-less; rows by `note_id`.
//! - smart folders: every folder by `id`, every membership by `folder_id`
//!   then `note_id`, the member title from `notes`.
//!
//! API under test:
//!   memex_core::app_reads::topics::unsorted_notes(&Vault) -> Result<Vec<UnsortedNoteRow>>
//!   memex_core::app_reads::topics::smart_folders(&Vault) -> Result<SmartFolderData>
//!   UnsortedNoteRow { note_id, title, role: Option<String> }
//!   SmartFolderData { folders: Vec<SmartFolderRow>, members: Vec<SmartFolderMemberRow> }
//!   SmartFolderRow { id, name, parent_id, pinned }
//!   SmartFolderMemberRow { folder_id, note_id, title, pinned }

use memex_core::app_reads::topics::{
    smart_folders, unsorted_notes, SmartFolderData, SmartFolderMemberRow, SmartFolderRow,
    UnsortedNoteRow,
};
use memex_core::notes::{create_or_adopt_note, CreateNote};
use memex_core::smart_folders as sf;
use memex_core::{Caller, Clock, Vault};
use rusqlite::params;
use serde_json::json;

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

const T0: i64 = 1_760_000_000_000;

fn fresh() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

/// A note row written straight into `notes`, so the id (and with it the
/// row order) and the raw frontmatter text are exactly as given.
fn note(vault: &Vault, id: &str, title: &str, frontmatter: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, 1, ?5, ?5)",
            params![id, title, format!("{title}\n"), frontmatter, T0],
        )
        .unwrap_or_else(|e| panic!("insert note {title}: {e}"));
}

fn folder(vault: &Vault, id: &str, name: &str, parent: Option<&str>, pinned: bool) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO smart_folders (id, name, parent_id, pinned, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![id, name, parent, pinned, T0],
        )
        .unwrap_or_else(|e| panic!("insert folder {name}: {e}"));
}

fn member(vault: &Vault, folder_id: &str, note_id: &str, pinned: bool) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO smart_folder_members (smart_folder_id, note_id, pinned) VALUES (?1, ?2, ?3)",
            params![folder_id, note_id, pinned],
        )
        .unwrap_or_else(|e| panic!("insert member {note_id}: {e}"));
}

fn unsorted(vault: &Vault) -> Vec<(String, String, Option<String>)> {
    unsorted_notes(vault)
        .expect("unsorted_notes")
        .into_iter()
        .map(|r| (r.note_id, r.title, r.role))
        .collect()
}

fn row(id: &str, title: &str, role: Option<&str>) -> (String, String, Option<String>) {
    (id.to_string(), title.to_string(), role.map(String::from))
}

// Ids are valid ULIDs; the trailing letters set their sort order.
const N_A: &str = "01M5DQAYZ40000000000000AAA";
const N_B: &str = "01M5DQAYZ40000000000000BBB";
const N_C: &str = "01M5DQAYZ40000000000000CCC";
const N_D: &str = "01M5DQAYZ40000000000000DDD";
const N_E: &str = "01M5DQAYZ40000000000000EEE";
const N_F: &str = "01M5DQAYZ40000000000000FFF";
const N_G: &str = "01M5DQAYZ40000000000000GGG";
const F_A: &str = "01M5DQAYZH0000000000000AAA";
const F_B: &str = "01M5DQAYZH0000000000000BBB";
const F_C: &str = "01M5DQAYZH0000000000000CCC";

#[test]
fn unsorted_excludes_daily_notes_and_notes_in_any_folder() {
    let (_dir, vault) = fresh();
    folder(&vault, F_A, "Root", None, true);
    folder(&vault, F_B, "Child", Some(F_A), false);
    note(&vault, N_A, "Topic In Root", r#"{"role":"topic"}"#);
    note(&vault, N_B, "Topic In Child", r#"{"role":"topic"}"#);
    // A role-less note can be a member when the row was written directly.
    note(&vault, N_C, "Role-less In Child", "{}");
    note(&vault, N_D, "2026-10-18", r#"{"role":"daily"}"#);
    // A daily note in a folder is still not unsorted.
    note(&vault, N_E, "2026-10-19", r#"{"role":"daily"}"#);
    note(&vault, N_F, "Free Topic", r#"{"role":"topic"}"#);
    note(&vault, N_G, "Free Thought", "{}");
    member(&vault, F_A, N_A, true);
    member(&vault, F_B, N_B, false);
    member(&vault, F_B, N_C, false);
    member(&vault, F_A, N_E, false);

    assert_eq!(
        unsorted(&vault),
        vec![
            row(N_F, "Free Topic", Some("topic")),
            row(N_G, "Free Thought", None),
        ],
        "no daily note and no note in any folder, root or nested"
    );
}

#[test]
fn unsorted_gives_a_note_with_invalid_json_frontmatter_role_null() {
    let (_dir, vault) = fresh();
    // The seed's Broken Frontmatter: it would be a topic if it parsed.
    note(&vault, N_A, "Broken Frontmatter", r#"{"role": "topic""#);
    // Even a "daily" that does not parse is role-less, so it is unsorted.
    note(&vault, N_B, "Broken Daily", r#"{"role": "daily""#);
    note(&vault, N_C, "Not JSON At All", "role: topic");
    assert_eq!(
        unsorted(&vault),
        vec![
            row(N_A, "Broken Frontmatter", None),
            row(N_B, "Broken Daily", None),
            row(N_C, "Not JSON At All", None),
        ]
    );
}

#[test]
fn unsorted_keeps_a_topic_note_role() {
    let (_dir, mut vault) = fresh();
    let clock = FixedClock(T0);
    let topic = create_or_adopt_note(
        &mut vault,
        CreateNote {
            title: Some("Combat Feel".into()),
            content_md: "Hit stop and screen shake.\n".into(),
            frontmatter: Some(json!({"role": "topic"})),
        },
        Caller::Person,
        &clock,
    )
    .unwrap()
    .note;
    let rows = unsorted_notes(&vault).unwrap();
    assert_eq!(
        rows,
        vec![UnsortedNoteRow {
            note_id: topic.id.to_string(),
            title: "Combat Feel".into(),
            role: Some("topic".into()),
        }]
    );
}

#[test]
fn unsorted_keeps_any_other_non_daily_role_as_the_app_sql_does() {
    let (_dir, vault) = fresh();
    note(&vault, N_A, "Reference Note", r#"{"role":"reference"}"#);
    // The app compares with `!= 'daily'`: case matters.
    note(&vault, N_B, "Shouty Daily", r#"{"role":"Daily"}"#);
    note(&vault, N_C, "Null Role", r#"{"role":null,"tags":["x"]}"#);
    note(&vault, N_D, "Array Frontmatter", "[1, 2]");
    assert_eq!(
        unsorted(&vault),
        vec![
            row(N_A, "Reference Note", Some("reference")),
            row(N_B, "Shouty Daily", Some("Daily")),
            row(N_C, "Null Role", None),
            row(N_D, "Array Frontmatter", None),
        ]
    );
}

#[test]
fn unsorted_notes_come_in_note_id_order() {
    let (_dir, vault) = fresh();
    // Inserted out of id order, with titles in the opposite order of ids.
    note(&vault, N_C, "Alpha", "{}");
    note(&vault, N_A, "Charlie", "{}");
    note(&vault, N_B, "Bravo", r#"{"role":"topic"}"#);
    let ids: Vec<String> = unsorted(&vault).into_iter().map(|r| r.0).collect();
    assert_eq!(ids, vec![N_A, N_B, N_C]);
}

#[test]
fn a_note_added_to_a_folder_leaves_unsorted() {
    let (_dir, mut vault) = fresh();
    let clock = FixedClock(T0);
    let loose = create_or_adopt_note(
        &mut vault,
        CreateNote {
            title: Some("Loose Thought".into()),
            content_md: "Maybe the map folds like paper?\n".into(),
            frontmatter: None,
        },
        Caller::Person,
        &clock,
    )
    .unwrap()
    .note;
    let id = loose.id.to_string();
    assert_eq!(unsorted(&vault), vec![row(&id, "Loose Thought", None)]);
    let f = sf::create_folder(&mut vault, "Inbox", None, Caller::Person, &clock).unwrap();
    sf::add_member(&mut vault, &f.id, &id, None, Caller::Person, None).unwrap();
    assert!(unsorted(&vault).is_empty(), "a member is never unsorted");
    sf::remove_member(&mut vault, &f.id, &id, Caller::Person).unwrap();
    // `folder add` made it a topic (Q3); out of the folder it is unsorted
    // again, now with that role.
    assert_eq!(
        unsorted(&vault),
        vec![row(&id, "Loose Thought", Some("topic"))]
    );
}

#[test]
fn unsorted_and_smart_folders_are_empty_on_a_fresh_vault() {
    let (_dir, vault) = fresh();
    assert!(unsorted_notes(&vault).unwrap().is_empty());
    assert_eq!(
        smart_folders(&vault).unwrap(),
        SmartFolderData {
            folders: vec![],
            members: vec![],
        }
    );
}

#[test]
fn smart_folders_lists_folders_by_id_and_members_by_folder_then_note() {
    let (_dir, vault) = fresh();
    // Inserted out of id order: C, A, B.
    folder(&vault, F_C, "Zeta", None, false);
    folder(&vault, F_A, "Alpha", Some(F_C), true);
    folder(&vault, F_B, "Beta", None, false);
    note(&vault, N_C, "Third", r#"{"role":"topic"}"#);
    note(&vault, N_A, "First", r#"{"role":"topic"}"#);
    note(&vault, N_B, "Second", "{}");
    member(&vault, F_C, N_A, true);
    member(&vault, F_A, N_C, false);
    member(&vault, F_A, N_A, true);
    member(&vault, F_C, N_B, false);

    let s = |v: &str| v.to_string();
    assert_eq!(
        smart_folders(&vault).unwrap(),
        SmartFolderData {
            folders: vec![
                SmartFolderRow {
                    id: s(F_A),
                    name: s("Alpha"),
                    parent_id: Some(s(F_C)),
                    pinned: true,
                },
                SmartFolderRow {
                    id: s(F_B),
                    name: s("Beta"),
                    parent_id: None,
                    pinned: false,
                },
                SmartFolderRow {
                    id: s(F_C),
                    name: s("Zeta"),
                    parent_id: None,
                    pinned: false,
                },
            ],
            members: vec![
                SmartFolderMemberRow {
                    folder_id: s(F_A),
                    note_id: s(N_A),
                    title: s("First"),
                    pinned: true,
                },
                SmartFolderMemberRow {
                    folder_id: s(F_A),
                    note_id: s(N_C),
                    title: s("Third"),
                    pinned: false,
                },
                SmartFolderMemberRow {
                    folder_id: s(F_C),
                    note_id: s(N_A),
                    title: s("First"),
                    pinned: true,
                },
                SmartFolderMemberRow {
                    folder_id: s(F_C),
                    note_id: s(N_B),
                    title: s("Second"),
                    pinned: false,
                },
            ],
        }
    );
}

#[test]
fn smart_folder_members_carry_the_current_note_title() {
    let (_dir, mut vault) = fresh();
    let clock = FixedClock(T0);
    let f = sf::create_folder(&mut vault, "Design", None, Caller::Person, &clock).unwrap();
    let n = create_or_adopt_note(
        &mut vault,
        CreateNote {
            title: Some("Player Loop".into()),
            content_md: "Explore, gather, build.\n".into(),
            frontmatter: Some(json!({"role": "topic"})),
        },
        Caller::Person,
        &clock,
    )
    .unwrap()
    .note;
    let id = n.id.to_string();
    sf::add_member(&mut vault, &f.id, &id, Some(false), Caller::Person, None).unwrap();
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET title = 'Core Loop' WHERE id = ?1",
            params![id],
        )
        .unwrap();
    let data = smart_folders(&vault).unwrap();
    assert_eq!(
        data.members,
        vec![SmartFolderMemberRow {
            folder_id: f.id.clone(),
            note_id: id,
            title: "Core Loop".into(),
            pinned: false,
        }]
    );
    assert_eq!(
        data.folders,
        vec![SmartFolderRow {
            id: f.id,
            name: "Design".into(),
            parent_id: None,
            pinned: true,
        }],
        "a person-created folder is pinned"
    );
}
