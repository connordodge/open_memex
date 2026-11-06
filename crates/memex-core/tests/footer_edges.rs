//! WI #238 (T2), verify-mode additions: edges of the footer write paths that
//! the AC-mapped tests leave to a reader.
//!
//! - the rename pass leaves a `role: guide` linker as rewritten (D3);
//! - `write_topic` puts the footer back after the person section without
//!   inventing or dropping a newline (D14).
//!
//! Real SQLite, real schema, temp vaults only.

use memex_core::excerpts::remove_excerpt;
use memex_core::guide;
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::{Caller, Clock, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const M: &str = "<!-- memex:topics -->";
const DAY: &str = "2026-09-05";
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n";
const TOKEN: &str = "![[2026-09-05#^b7k2m9]]";

/// A clock that stays where it is put (no wall-clock reads).
struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

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

fn create_topic(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, Some(json!({ "role": "topic" })))
}

/// The fixture day with its first block id pinned to the token's.
fn create_day(vault: &mut Vault) -> Note {
    let day = create(vault, DAY, DAY_BODY, Some(json!({ "role": "daily" })));
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET block_id = 'b7k2m9' WHERE note_id = ? AND ord = 0",
            params![day.id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "setup: block 0 of {DAY}");
    day
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    get_note(vault, id).unwrap()
}

fn set_body(vault: &mut Vault, id: &NoteId, body: &str) {
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            params![body, id.as_str()],
        )
        .unwrap();
    indexer::reindex_note(vault.connection_mut(), id.as_str(), body, None).unwrap();
}

fn tag_row(vault: &Vault, id: &NoteId, tag: &str, origin: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tags (note_id, tag, origin) VALUES (?, ?, ?)",
            params![id.as_str(), tag, origin],
        )
        .unwrap();
}

fn chip_row(vault: &Vault, host: &NoteId, topic: &NoteId) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
             VALUES (?, ?, 'person', 0)",
            params![host.as_str(), topic.as_str()],
        )
        .unwrap();
}

fn drop_excerpt(vault: &mut Vault, topic: &NoteId) -> Note {
    remove_excerpt(
        vault,
        topic,
        DAY,
        &["b7k2m9".to_string()],
        Caller::Agent,
        None,
    )
    .expect("remove the excerpt")
}

#[test]
fn rename_pass_leaves_a_guide_linker_as_rewritten_without_a_footer() {
    let (_dir, mut v) = fresh_vault();
    let renamed = create(&mut v, "Loose", "About.\n", None);
    let topic = create_topic(&mut v, "Player Loop", "About the loop.\n");
    // The real guide (D10: `create_note_as` rejects `role: guide`), holding a
    // link that `guide::update` indexes.
    let clock = FixedClock(1_759_500_000_000);
    let seeded = guide::get_or_create(&mut v, &clock, None).expect("create the guide");
    let doc = guide::update(
        &mut v,
        seeded.version,
        "See [[Loose]] for rules.\n",
        &["Linked Loose".to_string()],
        DAY,
        &clock,
        None,
    )
    .expect("write the guide body");
    let guide = get_note(&v, &NoteId::parse(&doc.note_id).unwrap()).unwrap();
    // Rows a footer would render from, were the guide any other note.
    tag_row(&v, &guide.id, "work", "agent");
    chip_row(&v, &guide.id, &topic.id);

    let version = stored(&v, &renamed.id).version;
    update_note_as(
        &mut v,
        &renamed.id,
        version,
        UpdateNote {
            title: Some("Renamed".into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .expect("rename the linked note");

    assert_eq!(
        stored(&v, &guide.id).content_md,
        "See [[Renamed]] for rules.\n",
        "the link is rewritten and no footer or marker is added"
    );
}

#[test]
fn remove_excerpt_on_a_topic_with_a_footer_and_no_person_text_adds_no_blank_line() {
    let (_dir, mut v) = fresh_vault();
    create_day(&mut v);
    let sleep = create_topic(&mut v, "Sleep", "About sleep.\n");
    let topic = create_topic(&mut v, "Player Loop", &format!("## {DAY}\n\n{TOKEN}\n"));
    chip_row(&v, &topic.id, &sleep.id);
    tag_row(&v, &topic.id, "x", "agent");
    let footer = format!("{M}\n[[Sleep~about]]\n#x\n");
    set_body(&mut v, &topic.id, &format!("## {DAY}\n\n{TOKEN}\n{footer}"));

    let saved = drop_excerpt(&mut v, &topic.id);

    assert_eq!(
        saved.content_md, footer,
        "the section goes with nothing left of the person text; the footer starts the body"
    );
}

#[test]
fn remove_excerpt_on_a_topic_without_a_footer_keeps_a_missing_final_newline() {
    let (_dir, mut v) = fresh_vault();
    create_day(&mut v);
    let topic = create_topic(
        &mut v,
        "Player Loop",
        &format!("Intro.\n\n## {DAY}\n\n{TOKEN}\n\nTail"),
    );

    let saved = drop_excerpt(&mut v, &topic.id);

    assert_eq!(
        saved.content_md,
        format!("Intro.\n\n## {DAY}\n\nTail"),
        "with no footer to put back, the body keeps the final newline it had: none"
    );
}
