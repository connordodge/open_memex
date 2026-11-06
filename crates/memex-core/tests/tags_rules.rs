//! WI #239 (T3): tag reconciliation and the server-side tag rules (Spec #234
//! R3, R8, R9, R34-R37, R40, R53, TD1, TD2, TD4).
//!
//! - Body tags are derived on a person write and on `append_to_daily_note`,
//!   in the save transaction; agent bodies, footer writes, excerpts, links and
//!   the rename pass leave them alone.
//! - One row per `(note_id, tag)`; `body` outranks `agent` and `person`.
//! - `tag_corrections` rows are blocks while `cleared_at IS NULL` and are
//!   never deleted.
//! - "Writes no tag rows" ACs count row changes with temp triggers on `tags`
//!   and `tag_corrections`, not just the final state.
//!
//! Real SQLite, real schema V6, temp vaults only.

use memex_core::daily::{self, AppendSource, ReviewState};
use memex_core::error::MemexError;
use memex_core::excerpts::{add_excerpt, remove_excerpt};
use memex_core::footer::{self, ChipOrigin, RemoveMode};
use memex_core::guide;
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, create_or_adopt_note, delete_note, get_note, update_note_as, CreateNote, Note,
    NoteId, RenameOptions, UpdateNote,
};
use memex_core::tags::{self, TagCount, TagNote, TagOrigin};
use memex_core::{review, Caller, Clock, SystemClock, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const M: &str = "<!-- memex:topics -->";
const DAY: &str = "2026-09-05";

// ---------- setup ----------

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn create_as(
    vault: &mut Vault,
    title: &str,
    body: &str,
    fm: Option<Value>,
    caller: Caller,
) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        caller,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    reindex(vault, &note.id, &note.content_md);
    note
}

fn reindex(vault: &mut Vault, id: &NoteId, body: &str) {
    indexer::reindex_note(vault.connection_mut(), id.as_str(), body, None).unwrap();
}

fn person_note(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_as(vault, title, body, None, Caller::Person)
}

fn agent_note(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_as(vault, title, body, None, Caller::Agent)
}

fn topic_note(vault: &mut Vault, title: &str, body: &str) -> Note {
    create_as(
        vault,
        title,
        body,
        Some(json!({"role": "topic"})),
        Caller::Person,
    )
}

fn day_note(vault: &mut Vault, body: &str) -> Note {
    create_as(
        vault,
        DAY,
        body,
        Some(json!({"role": "daily"})),
        Caller::Person,
    )
}

/// A clock that stays where it is put (no wall-clock reads).
struct GuideFixtureClock(i64);

impl Clock for GuideFixtureClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// The vault's real guide, built the only way D10 allows: `guide::get_or_create`
/// (`create_note_as` rejects `role: guide`), then `guide::update` to `body`.
/// A vault has one guide, so a test calls this once.
fn guide_note(vault: &mut Vault, body: &str) -> Note {
    let clock = GuideFixtureClock(1_759_500_000_000);
    let seeded = guide::get_or_create(vault, &clock, None).expect("create the guide");
    let doc = guide::update(
        vault,
        seeded.version,
        body,
        &["Set up the guide".to_string()],
        DAY,
        &clock,
        None,
    )
    .expect("write the guide body");
    get_note(vault, &NoteId::parse(&doc.note_id).unwrap()).unwrap()
}

/// The note kinds a tag rule holds on: role-less, topic and daily.
#[derive(Debug, Clone, Copy)]
enum Kind {
    Plain,
    Topic,
    Daily,
}

const KINDS: [Kind; 3] = [Kind::Plain, Kind::Topic, Kind::Daily];

fn note_of(vault: &mut Vault, kind: Kind, body: &str) -> Note {
    match kind {
        Kind::Plain => person_note(vault, "Plain", body),
        Kind::Topic => topic_note(vault, "Topic", body),
        Kind::Daily => day_note(vault, body),
    }
}

/// A note whose person-written `#name` puts `name` in the vocabulary.
fn seed_vocabulary(vault: &mut Vault, name: &str) -> Note {
    person_note(vault, &format!("Vocabulary {name}"), &format!("#{name}\n"))
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    get_note(vault, id).unwrap()
}

fn save_as(vault: &mut Vault, id: &NoteId, body: &str, caller: Caller) -> Note {
    let version = stored(vault, id).version;
    let note = update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        caller,
    )
    .unwrap_or_else(|e| panic!("save {id}: {e}"));
    reindex(vault, id, &note.content_md);
    note
}

fn person_save(vault: &mut Vault, id: &NoteId, body: &str) -> Note {
    save_as(vault, id, body, Caller::Person)
}

/// Stores `body` straight in the table: text no scan has seen.
fn set_body(vault: &mut Vault, id: &NoteId, body: &str) {
    let n = vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = ? WHERE id = ?",
            params![body, id.as_str()],
        )
        .unwrap();
    assert_eq!(n, 1, "setup: set_body {id}");
    reindex(vault, id, body);
}

/// Forces a `tags` row, whatever a previous write left.
fn seed_row(vault: &Vault, id: &NoteId, tag: &str, origin: &str) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tags (note_id, tag, origin, first_line) VALUES (?, ?, ?, NULL)
             ON CONFLICT (note_id, tag) DO UPDATE SET origin = excluded.origin, first_line = NULL",
            params![id.as_str(), tag, origin],
        )
        .unwrap();
}

/// An open block: a Correction row with `cleared_at` NULL.
fn seed_block(vault: &Vault, note: &Note, tag: &str) -> i64 {
    let conn = vault.connection_ref();
    conn.execute(
        "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at)
         VALUES (?, ?, ?, 'removed', 1)",
        params![note.id.as_str(), note.title, tag],
    )
    .unwrap();
    conn.last_insert_rowid()
}

fn mark_reviewed(vault: &mut Vault, id: &NoteId) {
    let cv = content_version(vault, id);
    let entry = review::ChangeEntry {
        note_id: id.to_string(),
        bullets: vec!["Reviewed".into()],
    };
    review::mark_day_reviewed(vault, DAY, cv, &[entry], &SystemClock).unwrap();
    assert_eq!(review_state(vault, id), ReviewState::Reviewed, "setup");
}

// ---------- reads ----------

type Row = (String, String, Option<String>);

fn row(tag: &str, origin: &str, first_line: Option<&str>) -> Row {
    (tag.into(), origin.into(), first_line.map(str::to_string))
}

fn rows(vault: &Vault, id: &NoteId) -> Vec<Row> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare("SELECT tag, origin, first_line FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap();
    let found = stmt
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<Vec<Row>>>()
        .unwrap();
    found
}

/// A `tag_corrections` row, as stored.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Correction {
    id: i64,
    note_id: Option<String>,
    note_title: String,
    tag: String,
    kind: String,
    created_at: i64,
    cleared_at: Option<i64>,
}

fn corrections(vault: &Vault) -> Vec<Correction> {
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, note_id, note_title, tag, kind, created_at, cleared_at
             FROM tag_corrections ORDER BY id",
        )
        .unwrap();
    let found = stmt
        .query_map([], |r| {
            Ok(Correction {
                id: r.get(0)?,
                note_id: r.get(1)?,
                note_title: r.get(2)?,
                tag: r.get(3)?,
                kind: r.get(4)?,
                created_at: r.get(5)?,
                cleared_at: r.get(6)?,
            })
        })
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    found
}

fn correction(vault: &Vault, id: i64) -> Correction {
    corrections(vault)
        .into_iter()
        .find(|c| c.id == id)
        .unwrap_or_else(|| panic!("correction {id} must never be deleted"))
}

fn content_version(vault: &Vault, id: &NoteId) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id.as_str()],
            |r| r.get(0),
        )
        .unwrap()
}

fn review_state(vault: &Vault, id: &NoteId) -> ReviewState {
    daily::review_state(vault.connection_ref(), id.as_str()).unwrap()
}

fn split(note: &Note) -> daily::DailyBody {
    if daily::is_daily(&note.frontmatter) {
        daily::split_body(&note.content_md)
    } else {
        daily::split_note_body(&note.content_md)
    }
}

fn footer_lines(vault: &Vault, id: &NoteId) -> Vec<String> {
    split(&stored(vault, id)).tags
}

fn vocabulary_names(vault: &Vault) -> Vec<String> {
    let mut names: Vec<String> = tags::vocabulary(vault)
        .unwrap()
        .into_iter()
        .map(|t| t.tag)
        .collect();
    names.sort();
    names
}

// ---------- row-change counting ----------

/// Logs every row change on `tags` and `tag_corrections` from here on.
fn count_tag_writes(vault: &Vault) {
    let mut sql = String::from("CREATE TEMP TABLE tag_write_log (tbl TEXT NOT NULL);");
    for table in ["tags", "tag_corrections"] {
        for op in ["INSERT", "UPDATE", "DELETE"] {
            sql.push_str(&format!(
                "CREATE TEMP TRIGGER log_{table}_{op} AFTER {op} ON main.{table}
                 BEGIN INSERT INTO tag_write_log VALUES ('{table}'); END;"
            ));
        }
    }
    vault.connection_ref().execute_batch(&sql).unwrap();
}

fn writes_to(vault: &Vault, table: &str) -> i64 {
    vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM tag_write_log WHERE tbl = ?",
            [table],
            |r| r.get(0),
        )
        .unwrap()
}

fn tag_writes(vault: &Vault) -> i64 {
    writes_to(vault, "tags") + writes_to(vault, "tag_corrections")
}

fn reset_tag_writes(vault: &Vault) {
    vault
        .connection_ref()
        .execute("DELETE FROM tag_write_log", [])
        .unwrap();
}

/// Makes the next `op` on `table` fail, to prove a write is one transaction.
fn abort_on(vault: &Vault, op: &str, table: &str) {
    vault
        .connection_ref()
        .execute_batch(&format!(
            "CREATE TEMP TRIGGER abort_write BEFORE {op} ON main.{table}
             BEGIN SELECT RAISE(ABORT, 'test abort'); END;"
        ))
        .unwrap();
}

fn stop_aborting(vault: &Vault) {
    vault
        .connection_ref()
        .execute_batch("DROP TRIGGER temp.abort_write")
        .unwrap();
}

// ---------- error helpers ----------

fn assert_code<T: std::fmt::Debug>(result: memex_core::Result<T>, code: &str, what: &str) {
    match result {
        Ok(v) => panic!("{what}: expected {code}, got Ok({v:?})"),
        Err(e) => assert_eq!(e.code(), code, "{what}: {e}"),
    }
}

/// The issue's `InvalidArgument`: the crate's existing `Io(InvalidInput)`
/// form (see `footer::set_chip`).
fn assert_invalid_argument<T: std::fmt::Debug>(
    result: memex_core::Result<T>,
    what: &str,
) -> String {
    match result {
        Ok(v) => panic!("{what}: expected an invalid-argument error, got Ok({v:?})"),
        Err(MemexError::Io(e)) if e.kind() == std::io::ErrorKind::InvalidInput => e.to_string(),
        Err(e) => panic!("{what}: expected an invalid-argument error, got {e:?}"),
    }
}

// ---------- AC 1: a person save adds and drops, in one transaction ----------

#[test]
fn person_save_adds_a_new_tag_and_drops_a_removed_one_on_daily_and_non_daily_notes() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "#keep one\n\n#gone two\n");
        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("gone", "body", Some("#gone two")),
                row("keep", "body", Some("#keep one")),
            ],
            "{kind:?} after create"
        );

        let saved = person_save(&mut v, &note.id, "#keep one\n\n#new three\n");

        assert_eq!(saved.version, note.version + 1, "{kind:?}: one version");
        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("keep", "body", Some("#keep one")),
                row("new", "body", Some("#new three")),
            ],
            "{kind:?} after save"
        );
        assert_eq!(
            split(&saved).person,
            "#keep one\n\n#new three\n",
            "{kind:?}"
        );
        assert!(split(&saved).tags.is_empty(), "{kind:?}: no footer line");
        assert!(corrections(&v).is_empty(), "{kind:?}: R37 records nothing");
    }
}

#[test]
fn person_save_writes_tags_and_body_in_one_transaction() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "#old\n");
        assert_eq!(rows(&v, &note.id), vec![row("old", "body", Some("#old"))]);
        let id = note.id.clone();
        let patch = |body: &str| UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        };

        // A failing tag write rolls the body back.
        abort_on(&v, "INSERT", "tags");
        let failed = update_note_as(
            &mut v,
            &id,
            note.version,
            patch("#new\n"),
            RenameOptions::default(),
            Caller::Person,
        );
        stop_aborting(&v);
        assert!(failed.is_err(), "{kind:?}: the tag insert was aborted");
        let after = stored(&v, &id);
        assert_eq!(after.content_md, note.content_md, "{kind:?}: body kept");
        assert_eq!(after.version, note.version, "{kind:?}: version kept");

        // A failing body write rolls the tags back.
        abort_on(&v, "UPDATE", "notes");
        let failed = update_note_as(
            &mut v,
            &id,
            note.version,
            patch("#new\n"),
            RenameOptions::default(),
            Caller::Person,
        );
        stop_aborting(&v);
        assert!(failed.is_err(), "{kind:?}: the notes update was aborted");
        assert_eq!(
            rows(&v, &id),
            vec![row("old", "body", Some("#old"))],
            "{kind:?}: tags kept"
        );
    }
}

#[test]
fn person_create_derives_body_tags_in_one_transaction_with_the_note() {
    for (title, fm) in [("Plain", None), (DAY, Some(json!({"role": "daily"})))] {
        let (_d, mut v) = fresh_vault();
        abort_on(&v, "INSERT", "tags");
        let failed = create_note_as(
            &mut v,
            CreateNote {
                title: Some(title.into()),
                content_md: "#x here\n".into(),
                frontmatter: fm.clone(),
            },
            Caller::Person,
        );
        stop_aborting(&v);
        assert!(failed.is_err(), "{title}: the tag insert was aborted");
        assert!(
            memex_core::notes::list_notes(&v, 10).unwrap().is_empty(),
            "{title}: no note without its tags"
        );

        let note = create_as(&mut v, title, "#x here\n", fm, Caller::Person);
        assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("#x here"))]);
        assert_eq!(note.version, 1, "{title}: a create is version 1");
    }
}

#[test]
fn person_daily_create_adopting_a_note_derives_tags_from_the_merged_body() {
    let (_d, mut v) = fresh_vault();
    let plain = agent_note(&mut v, DAY, "#existing one\n");
    let outcome = create_or_adopt_note(
        &mut v,
        CreateNote {
            title: None,
            content_md: "#added two\n".into(),
            frontmatter: Some(json!({"role": "daily"})),
        },
        Caller::Person,
        &FixedDay,
    )
    .unwrap();
    assert!(outcome.adopted);
    assert_eq!(
        rows(&v, &plain.id),
        vec![
            row("added", "body", Some("#added two")),
            row("existing", "body", Some("#existing one")),
        ]
    );
}

/// A clock whose "today" is [`DAY`] in UTC.
struct FixedDay;

impl memex_core::Clock for FixedDay {
    fn now_ms(&self) -> i64 {
        1_788_609_600_000 // 2026-09-05T12:00:00Z
    }

    fn utc_offset_at(&self, _now_ms: i64) -> memex_core::FixedOffset {
        memex_core::FixedOffset::east_opt(0).unwrap()
    }
}

#[test]
fn only_the_person_section_is_scanned_on_a_save() {
    let (_d, mut v) = fresh_vault();

    // Frontmatter is not scanned.
    let plain = person_note(&mut v, "Fronted", "---\nnote: \"#fm\"\n---\n#real\n");
    assert_eq!(
        rows(&v, &plain.id),
        vec![row("real", "body", Some("#real"))]
    );

    // A marker in fenced code is body text, and a fence holds no tag.
    let fenced = "```\n<!-- memex:topics -->\n#fenced\n```\n#after\n";
    let plain = person_note(&mut v, "Fenced", "start\n");
    let saved = person_save(&mut v, &plain.id, fenced);
    assert_eq!(saved.content_md, fenced);
    assert_eq!(
        rows(&v, &plain.id),
        vec![row("after", "body", Some("#after"))]
    );

    // `#x` typed below the marker in Source mode is not a tag (R12), on a
    // non-daily and a daily note.
    let below = format!("#above\n{M}\n#typed\n");
    let plain = person_note(&mut v, "Below", "start\n");
    let saved = person_save(&mut v, &plain.id, &below);
    assert_eq!(
        rows(&v, &plain.id),
        vec![row("above", "body", Some("#above"))]
    );
    assert!(split(&saved).tags.is_empty(), "rows decide the footer");

    let day = day_note(&mut v, "start\n");
    let saved = person_save(&mut v, &day.id, &below);
    assert_eq!(
        rows(&v, &day.id),
        vec![row("above", "body", Some("#above"))]
    );
    assert!(split(&saved).tags.is_empty(), "rows decide the footer");
}

// ---------- AC 2: unchanged tags write nothing ----------

#[test]
fn person_save_with_unchanged_body_tags_and_first_lines_writes_no_tag_rows() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let body = "#a line one\n\nprose\n\n#b line two\n";
        let note = note_of(&mut v, kind, body);
        seed_row(&v, &note.id, "kept", "agent");
        seed_block(&v, &note, "blocked");
        let before = rows(&v, &note.id);
        assert_eq!(before.len(), 3, "{kind:?}: setup, a, b and kept");
        let blocks_before = corrections(&v);
        count_tag_writes(&v);

        // The same text, then other lines changing around the tag lines.
        person_save(&mut v, &note.id, body);
        assert_eq!(tag_writes(&v), 0, "{kind:?}: same body");
        person_save(
            &mut v,
            &note.id,
            "#a line one\n\nother prose\n\n#b line two\n",
        );
        assert_eq!(tag_writes(&v), 0, "{kind:?}: other lines changed");
        // A second mention of a tag doesn't move its first line.
        person_save(&mut v, &note.id, "#a line one\n\n#a again\n\n#b line two\n");
        assert_eq!(tag_writes(&v), 0, "{kind:?}: a later mention");

        assert_eq!(rows(&v, &note.id), before, "{kind:?}");
        assert_eq!(corrections(&v), blocks_before, "{kind:?}");
    }
}

// ---------- AC 3: first_line ----------

#[test]
fn a_person_save_stores_a_heading_first_line_without_its_marker() {
    // D48: the stored first_line is what Tags mode shows.
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "# Pricing #work\n\n- # Item #y\n");
        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("work", "body", Some("Pricing #work")),
                row("y", "body", Some("Item #y")),
            ],
            "{kind:?}"
        );

        // The heading marker is not part of the text: dropping it is no change.
        person_save(&mut v, &note.id, "Pricing #work\n\n- # Item #y\n");
        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("work", "body", Some("Pricing #work")),
                row("y", "body", Some("Item #y")),
            ],
            "{kind:?}: same text, same row"
        );
    }
}

#[test]
fn changed_first_line_updates_first_line_for_that_tag_only() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "- #a was this\n\n#b stays\n");
        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("a", "body", Some("#a was this")),
                row("b", "body", Some("#b stays")),
            ],
            "{kind:?}: the first line drops its list marker"
        );
        count_tag_writes(&v);

        person_save(&mut v, &note.id, "- #a is now that\n\n#b stays\n");

        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("a", "body", Some("#a is now that")),
                row("b", "body", Some("#b stays")),
            ],
            "{kind:?}"
        );
        assert_eq!(writes_to(&v, "tags"), 1, "{kind:?}: one row written");

        // An earlier mention becomes the first line.
        reset_tag_writes(&v);
        person_save(
            &mut v,
            &note.id,
            "first #b\n\n- #a is now that\n\n#b stays\n",
        );
        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("a", "body", Some("#a is now that")),
                row("b", "body", Some("first #b")),
            ],
            "{kind:?}"
        );
        assert_eq!(writes_to(&v, "tags"), 1, "{kind:?}: one row written");
    }
}

// ---------- AC 4: append ----------

#[test]
fn append_to_daily_note_with_a_tag_adds_a_body_tag() {
    for source in [AppendSource::QuickEntry, AppendSource::Agent] {
        let (_d, mut v) = fresh_vault();
        // A missing day is created by the append.
        let first = daily::append_to_daily_note(
            &mut v,
            "did #work today\n",
            Some(DAY),
            source,
            &SystemClock,
            None,
        )
        .unwrap();
        assert_eq!(
            rows(&v, &first.note.id),
            vec![row("work", "body", Some("did #work today"))],
            "{source:?}"
        );

        // An existing day keeps its tags and gains the new one.
        let second = daily::append_to_daily_note(
            &mut v,
            "- then #more\n",
            Some(DAY),
            source,
            &SystemClock,
            None,
        )
        .unwrap();
        assert_eq!(second.note.version, first.note.version + 1, "{source:?}");
        assert_eq!(
            second.content_version,
            first.content_version + 1,
            "{source:?}"
        );
        assert_eq!(
            rows(&v, &second.note.id),
            vec![
                row("more", "body", Some("then #more")),
                row("work", "body", Some("did #work today")),
            ],
            "{source:?}"
        );
    }
}

#[test]
fn append_with_a_tag_upgrades_an_agent_tag_drops_its_footer_line_and_clears_its_block() {
    let (_d, mut v) = fresh_vault();
    let day = day_note(&mut v, "start\n");
    seed_row(&v, &day.id, "x", "agent");
    let block = seed_block(&v, &day, "x");
    set_body(&mut v, &day.id, &format!("start\n{M}\n#x\n"));
    let cv = content_version(&v, &day.id);

    let out = daily::append_to_daily_note(
        &mut v,
        "now #x\n",
        Some(DAY),
        AppendSource::QuickEntry,
        &SystemClock,
        None,
    )
    .unwrap();

    assert_eq!(rows(&v, &day.id), vec![row("x", "body", Some("now #x"))]);
    assert!(split(&out.note).tags.is_empty(), "{}", out.note.content_md);
    assert!(correction(&v, block).cleared_at.is_some(), "block lifted");
    assert_eq!(out.content_version, cv + 1);
}

#[test]
fn append_writes_tags_and_body_in_one_transaction() {
    let (_d, mut v) = fresh_vault();
    let day = day_note(&mut v, "start\n");
    abort_on(&v, "INSERT", "tags");
    let failed = daily::append_to_daily_note(
        &mut v,
        "#x\n",
        Some(DAY),
        AppendSource::QuickEntry,
        &SystemClock,
        None,
    );
    stop_aborting(&v);
    assert!(failed.is_err(), "the tag insert was aborted");
    let after = stored(&v, &day.id);
    assert_eq!(after.content_md, day.content_md);
    assert_eq!(after.version, day.version);
}

#[test]
fn append_retrying_after_a_racing_person_save_keeps_tags_from_both_writes() {
    let (_d, mut v) = fresh_vault();
    let day = day_note(&mut v, "start\n");
    let id = day.id.clone();
    let out = daily::append_to_daily_note_with_hook(
        &mut v,
        "#appended\n",
        Some(DAY),
        AppendSource::QuickEntry,
        &SystemClock,
        None,
        &mut |vault, attempt| {
            if attempt == 1 {
                person_save(vault, &id, "start\n\n#raced\n");
            }
        },
    )
    .unwrap();
    assert!(out.note.content_md.contains("#appended"));
    assert_eq!(
        rows(&v, &day.id),
        vec![
            row("appended", "body", Some("#appended")),
            row("raced", "body", Some("#raced")),
        ]
    );
}

// ---------- AC 5: agent bodies aren't scanned ----------

#[test]
fn agent_create_note_body_adds_no_tag_and_a_later_person_save_adds_it() {
    let (_d, mut v) = fresh_vault();
    let note = agent_note(&mut v, "Agent wrote", "about #x\n");
    assert!(
        rows(&v, &note.id).is_empty(),
        "the agent body isn't scanned"
    );
    assert!(
        vocabulary_names(&v).is_empty(),
        "no vocabulary from an agent"
    );
    assert_code(
        tags::agent_tag_note(&mut v, &note.id, "x", None),
        "unknown_tag",
        "x is outside the vocabulary",
    );

    // The person saves the same text.
    person_save(&mut v, &note.id, "about #x\n");
    assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("about #x"))]);
    assert_eq!(vocabulary_names(&v), vec!["x"]);
}

#[test]
fn agent_update_note_body_leaves_body_tags_alone() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Shared", "#kept here\n");
    assert_eq!(
        rows(&v, &note.id),
        vec![row("kept", "body", Some("#kept here"))]
    );
    count_tag_writes(&v);

    // Neither adds `#new` nor drops `#kept`: only a person write derives tags.
    save_as(&mut v, &note.id, "agent replaced it #new\n", Caller::Agent);

    assert_eq!(tag_writes(&v), 0);
    assert_eq!(
        rows(&v, &note.id),
        vec![row("kept", "body", Some("#kept here"))]
    );
}

// ---------- AC 6: footer, excerpt, link and rename writes ----------

#[test]
fn footer_writes_change_no_body_tags() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let chip = topic_note(&mut v, "Chip", "About.\n");
        let note = note_of(&mut v, kind, "#kept here\n");
        assert_eq!(
            rows(&v, &note.id),
            vec![row("kept", "body", Some("#kept here"))],
            "{kind:?}"
        );
        // Text no scan has seen: a footer write must not scan it.
        set_body(&mut v, &note.id, "#kept here\n\n#unscanned\n");
        count_tag_writes(&v);

        let added = footer::set_chip(&mut v, &note.id, &chip.id, ChipOrigin::Person, None).unwrap();
        assert!(
            added.note.content_md.contains(M),
            "{kind:?}: footer written"
        );
        footer::remove_chip(&mut v, &note.id, &chip.id, RemoveMode::AnyOrigin, None).unwrap();

        assert_eq!(tag_writes(&v), 0, "{kind:?}");
        assert_eq!(
            rows(&v, &note.id),
            vec![row("kept", "body", Some("#kept here"))],
            "{kind:?}"
        );
    }
}

/// A day with one tagged block, and the id of that block.
fn tagged_day(vault: &mut Vault, body: &str) -> (Note, String) {
    let day = day_note(vault, body);
    let block: String = vault
        .connection_ref()
        .query_row(
            "SELECT block_id FROM blocks WHERE note_id = ? AND ord = 0",
            [day.id.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    (day, block)
}

#[test]
fn agent_add_excerpt_and_remove_excerpt_change_no_body_tags() {
    let (_d, mut v) = fresh_vault();
    let (day, block) = tagged_day(&mut v, "#daytag fixed it\n");
    let topic = topic_note(&mut v, "Topic", "#own text\n");
    let day_rows = vec![row("daytag", "body", Some("#daytag fixed it"))];
    let topic_rows = vec![row("own", "body", Some("#own text"))];
    assert_eq!(rows(&v, &day.id), day_rows);
    assert_eq!(rows(&v, &topic.id), topic_rows);
    // Text no scan has seen: neither the topic write nor the day's footer
    // write may scan it.
    set_body(&mut v, &topic.id, "#own text\n\n#unscanned\n");
    set_body(&mut v, &day.id, "#daytag fixed it\n\n#dayunscanned\n");
    count_tag_writes(&v);

    let blocks = [block];
    let with = add_excerpt(&mut v, &topic.id, DAY, &blocks, Caller::Agent, None).unwrap();
    assert!(with.content_md.contains("![["), "{}", with.content_md);
    remove_excerpt(&mut v, &topic.id, DAY, &blocks, Caller::Agent, None).unwrap();

    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &day.id), day_rows);
    assert_eq!(rows(&v, &topic.id), topic_rows);
}

#[test]
fn person_add_excerpt_on_a_scanned_body_writes_no_tag_rows() {
    let (_d, mut v) = fresh_vault();
    let (day, block) = tagged_day(&mut v, "#daytag fixed it\n");
    let topic = topic_note(&mut v, "Topic", "#own text\n");
    let topic_rows = vec![row("own", "body", Some("#own text"))];
    assert_eq!(rows(&v, &topic.id), topic_rows);
    count_tag_writes(&v);

    let blocks = [block];
    add_excerpt(&mut v, &topic.id, DAY, &blocks, Caller::Person, None).unwrap();
    remove_excerpt(&mut v, &topic.id, DAY, &blocks, Caller::Person, None).unwrap();

    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &topic.id), topic_rows);
    assert_eq!(
        rows(&v, &day.id),
        vec![row("daytag", "body", Some("#daytag fixed it"))]
    );
}

#[test]
fn rename_pass_changes_no_body_tags() {
    let (_d, mut v) = fresh_vault();
    let renamed = topic_note(&mut v, "Old Title", "#own\n");
    let plain = person_note(&mut v, "Linker", "[[Old Title]] #plaintag\n");
    let day = day_note(&mut v, "[[Old Title]] #daytag\n");
    footer::set_chip(&mut v, &day.id, &renamed.id, ChipOrigin::Person, None).unwrap();
    let own = vec![row("own", "body", Some("#own"))];
    let plain_rows = vec![row("plaintag", "body", Some("[[Old Title]] #plaintag"))];
    let day_rows = vec![row("daytag", "body", Some("[[Old Title]] #daytag"))];
    assert_eq!(rows(&v, &renamed.id), own);
    assert_eq!(rows(&v, &plain.id), plain_rows);
    assert_eq!(rows(&v, &day.id), day_rows);
    // Text no scan has seen, on every note the pass writes.
    set_body(&mut v, &renamed.id, "#own\n\n#unscanned\n");
    set_body(&mut v, &plain.id, "[[Old Title]] #plaintag\n\n#unscanned\n");
    let day_body = stored(&v, &day.id).content_md.replace(
        "[[Old Title]] #daytag\n",
        "[[Old Title]] #daytag\n\n#unscanned\n",
    );
    set_body(&mut v, &day.id, &day_body);
    count_tag_writes(&v);

    let version = stored(&v, &renamed.id).version;
    update_note_as(
        &mut v,
        &renamed.id,
        version,
        UpdateNote {
            title: Some("New Title".into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap();

    assert!(stored(&v, &plain.id).content_md.contains("[[New Title]]"));
    assert!(stored(&v, &day.id).content_md.contains("[[New Title]]"));
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &renamed.id), own);
    assert_eq!(rows(&v, &plain.id), plain_rows);
    assert_eq!(rows(&v, &day.id), day_rows);
}

#[test]
fn person_save_without_a_body_in_the_patch_does_not_scan() {
    let (_d, mut v) = fresh_vault();
    let note = agent_note(&mut v, "Agent wrote", "about #x\n");
    seed_vocabulary(&mut v, "seed");
    count_tag_writes(&v);

    // A frontmatter-only person write, as smart folders make when they turn
    // a note into a topic.
    let version = stored(&v, &note.id).version;
    update_note_as(
        &mut v,
        &note.id,
        version,
        UpdateNote {
            frontmatter: Some(json!({"role": "topic"})),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap();

    assert_eq!(tag_writes(&v), 0);
    assert!(rows(&v, &note.id).is_empty());
    assert_eq!(
        vocabulary_names(&v),
        vec!["seed"],
        "the seed note is scanned"
    );
}

// ---------- AC 7: transcluded excerpts ----------

#[test]
fn tag_in_a_transcluded_excerpt_does_not_tag_the_topic_note_holding_it() {
    let (_d, mut v) = fresh_vault();
    let (day, block) = tagged_day(&mut v, "#fromday fixed it\n");
    let topic = topic_note(&mut v, "Topic", "#own text\n");
    let held = add_excerpt(&mut v, &topic.id, DAY, &[block], Caller::Agent, None).unwrap();
    assert!(held.content_md.contains("![["), "{}", held.content_md);

    // The person saves the topic with the token in it.
    let saved = person_save(&mut v, &topic.id, &split(&held).person);

    assert!(saved.content_md.contains("![["), "{}", saved.content_md);
    assert_eq!(
        rows(&v, &topic.id),
        vec![row("own", "body", Some("#own text"))]
    );
    assert_eq!(
        rows(&v, &day.id),
        vec![row("fromday", "body", Some("#fromday fixed it"))]
    );
}

// ---------- AC 8: origin upgrade ----------

#[test]
fn body_tag_over_a_body_less_tag_leaves_one_body_row_removes_its_footer_line_and_clears_its_block()
{
    for kind in KINDS {
        for origin in ["agent", "person"] {
            let (_d, mut v) = fresh_vault();
            let note = note_of(&mut v, kind, "text\n");
            seed_row(&v, &note.id, "x", origin);
            let block = seed_block(&v, &note, "x");
            set_body(&mut v, &note.id, &format!("text\n{M}\n#x\n"));
            let what = format!("{kind:?} {origin}");
            assert_eq!(footer_lines(&v, &note.id), vec!["x"], "{what}: setup");
            let version = stored(&v, &note.id).version;

            let saved = person_save(&mut v, &note.id, "text\n\n#x here\n");

            assert_eq!(saved.version, version + 1, "{what}: one write");
            assert_eq!(
                rows(&v, &note.id),
                vec![row("x", "body", Some("#x here"))],
                "{what}"
            );
            assert!(
                split(&saved).tags.is_empty(),
                "{what}: {}",
                saved.content_md
            );
            assert_eq!(split(&saved).person, "text\n\n#x here\n", "{what}");
            if !daily::is_daily(&saved.frontmatter) {
                assert!(
                    !saved.content_md.contains(M),
                    "{what}: last item, no marker"
                );
            }
            let cleared = correction(&v, block);
            assert!(cleared.cleared_at.is_some(), "{what}: block lifted");

            // Deleting the text removes the tag, even with the stale footer
            // line still in the saved body.
            let deleted = person_save(&mut v, &note.id, &format!("text\n{M}\n#x\n"));
            assert!(rows(&v, &note.id).is_empty(), "{what}: tag gone");
            assert!(
                split(&deleted).tags.is_empty(),
                "{what}: not back in the footer"
            );
            assert_eq!(correction(&v, block), cleared, "{what}: records nothing");
            assert_eq!(corrections(&v).len(), 1, "{what}: records nothing");
        }
    }
}

#[test]
fn stale_footer_text_cannot_bring_back_a_removed_tag_or_clear_its_block() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        seed_vocabulary(&mut v, "x");
        let note = note_of(&mut v, kind, "text\n");
        tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
        assert_eq!(footer_lines(&v, &note.id), vec!["x"], "{kind:?}: applied");
        let stale = stored(&v, &note.id).content_md;
        let removal = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
        let block = removal.correction_id.expect("a recorded removal");

        // An open editor saves the body it read before the removal.
        let saved = person_save(&mut v, &note.id, &stale);

        assert!(rows(&v, &note.id).is_empty(), "{kind:?}: not back");
        assert!(
            split(&saved).tags.is_empty(),
            "{kind:?}: {}",
            saved.content_md
        );
        assert_eq!(
            correction(&v, block).cleared_at,
            None,
            "{kind:?}: still blocked"
        );
        assert_code(
            tags::agent_tag_note(&mut v, &note.id, "x", None),
            "tag_removed",
            "still blocked",
        );
    }
}

#[test]
fn person_save_keeps_agent_person_and_legacy_tags_not_in_the_text() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "text\n");
        seed_row(&v, &note.id, "y", "agent");
        seed_row(&v, &note.id, "z", "person");
        seed_row(&v, &note.id, "inbox", "agent");
        // A legacy row stays as stored next to the inline `work` (Spec notes).
        seed_row(&v, &note.id, "Work", "person");

        let saved = person_save(&mut v, &note.id, "#work now\n");

        assert_eq!(
            rows(&v, &note.id),
            vec![
                row("Work", "person", None),
                row("inbox", "agent", None),
                row("work", "body", Some("#work now")),
                row("y", "agent", None),
                row("z", "person", None),
            ],
            "{kind:?}"
        );
        assert_eq!(split(&saved).tags, vec!["Work", "y", "z"], "{kind:?}");
    }
}

// ---------- AC 9: agent_tag_note's rules ----------

#[test]
fn agent_tag_note_returns_guide_rule_unknown_tag_tag_removed_and_not_found() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "known");
    let guide = guide_note(&mut v, "How to.\n");
    let note = person_note(&mut v, "Note", "text\n");
    seed_block(&v, &note, "known");
    let other = person_note(&mut v, "Other", "text\n");
    count_tag_writes(&v);

    assert_code(
        tags::agent_tag_note(&mut v, &guide.id, "known", None),
        "guide_rule",
        "a guide",
    );
    assert_code(
        tags::agent_tag_note(&mut v, &other.id, "stranger", None),
        "unknown_tag",
        "outside the vocabulary",
    );
    assert_code(
        tags::agent_tag_note(&mut v, &note.id, "known", None),
        "tag_removed",
        "blocked",
    );
    assert_code(
        tags::agent_tag_note(&mut v, &NoteId::new(), "known", None),
        "not_found",
        "an unknown note",
    );
    assert!(tags::agent_tag_note(&mut v, &other.id, "not a tag", None).is_err());

    assert_eq!(tag_writes(&v), 0, "a refused call writes nothing");
    assert_eq!(stored(&v, &note.id).version, note.version);
}

#[test]
fn agent_tag_note_checks_guide_rule_then_unknown_tag_then_tag_removed() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "known");
    let guide = guide_note(&mut v, "How to.\n");
    seed_block(&v, &guide, "known");
    seed_block(&v, &guide, "stranger");
    assert_code(
        tags::agent_tag_note(&mut v, &guide.id, "stranger", None),
        "guide_rule",
        "guide over unknown tag",
    );
    assert_code(
        tags::agent_tag_note(&mut v, &guide.id, "known", None),
        "guide_rule",
        "guide over a block",
    );

    let note = person_note(&mut v, "Note", "text\n");
    seed_block(&v, &note, "stranger");
    assert_code(
        tags::agent_tag_note(&mut v, &note.id, "stranger", None),
        "unknown_tag",
        "unknown tag over a block",
    );
}

#[test]
fn agent_tag_note_applies_an_agent_tag_with_its_footer_line() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        seed_vocabulary(&mut v, "pricing");
        let note = note_of(&mut v, kind, "text\n");

        // The input is normalized.
        let write = tags::agent_tag_note(&mut v, &note.id, "Pricing", None).unwrap();

        let after = stored(&v, &note.id);
        assert!(write.changed, "{kind:?}");
        assert_eq!(write.version, after.version, "{kind:?}: the stored version");
        assert_eq!(after.version, note.version + 1, "{kind:?}: one write");
        assert_eq!(
            rows(&v, &note.id),
            vec![row("pricing", "agent", None)],
            "{kind:?}"
        );
        assert_eq!(split(&after).tags, vec!["pricing"], "{kind:?}");
        assert_eq!(split(&after).person, "text\n", "{kind:?}: person text kept");
    }
}

#[test]
fn agent_tag_note_on_a_daily_note_keeps_content_version_and_review_state() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let day = day_note(&mut v, "text\n");
    mark_reviewed(&mut v, &day.id);
    let cv = content_version(&v, &day.id);

    let write = tags::agent_tag_note(&mut v, &day.id, "x", None).unwrap();

    assert!(
        write.changed,
        "R41: Review tags the day, past the marker rule"
    );
    assert_eq!(footer_lines(&v, &day.id), vec!["x"]);
    assert_eq!(content_version(&v, &day.id), cv);
    assert_eq!(review_state(&v, &day.id), ReviewState::Reviewed);
}

// ---------- AC 10: a repeat writes nothing ----------

#[test]
fn repeating_agent_tag_note_writes_nothing() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "text\n");
    assert!(
        tags::agent_tag_note(&mut v, &note.id, "x", None)
            .unwrap()
            .changed
    );
    let before = stored(&v, &note.id);
    count_tag_writes(&v);

    let again = tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();

    assert!(!again.changed);
    assert_eq!(again.version, before.version);
    assert_eq!(tag_writes(&v), 0);
    let after = stored(&v, &note.id);
    assert_eq!(after.version, before.version, "no footer write");
    assert_eq!(after.updated_at, before.updated_at);
    assert_eq!(after.content_md, before.content_md);
}

#[test]
fn agent_tag_note_on_a_tag_the_note_already_has_keeps_its_origin_and_writes_nothing() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "#x here\n");
    assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("#x here"))]);
    seed_vocabulary(&mut v, "p");
    seed_row(&v, &note.id, "p", "person");
    let before = stored(&v, &note.id);
    count_tag_writes(&v);

    let on_body = tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
    let on_person = tags::agent_tag_note(&mut v, &note.id, "p", None).unwrap();

    assert!(!on_body.changed);
    assert!(!on_person.changed);
    assert_eq!(on_person.version, before.version);
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(
        rows(&v, &note.id),
        vec![row("p", "person", None), row("x", "body", Some("#x here"))]
    );
}

// ---------- AC 11, 12: the vocabulary ----------

#[test]
fn inbox_and_agent_authored_are_not_vocabulary_even_when_person_written() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "#inbox #agent-authored #work\n");
    assert_eq!(rows(&v, &note.id).len(), 3, "written, so tagged");
    assert_eq!(vocabulary_names(&v), vec!["work"]);
    for system in ["inbox", "agent-authored"] {
        let other = person_note(&mut v, &format!("Other {system}"), "text\n");
        assert_code(
            tags::agent_tag_note(&mut v, &other.id, system, None),
            "unknown_tag",
            system,
        );
    }
}

#[test]
fn vocabulary_name_written_only_on_a_guide_note_does_not_count() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "work");
    let guide = guide_note(&mut v, "#scanned-not\n");
    assert!(rows(&v, &guide.id).is_empty(), "a guide is never scanned");
    person_save(&mut v, &guide.id, "#still-not\n");
    assert!(rows(&v, &guide.id).is_empty(), "a guide is never scanned");

    // A row there anyway (say, an older write) doesn't count either.
    seed_row(&v, &guide.id, "legacy-row", "body");

    assert_eq!(vocabulary_names(&v), vec!["work"]);
    let note = person_note(&mut v, "Note", "text\n");
    assert_code(
        tags::agent_tag_note(&mut v, &note.id, "legacy-row", None),
        "unknown_tag",
        "only on a guide",
    );
}

#[test]
fn vocabulary_needs_a_body_row_and_counts_notes_from_any_origin() {
    let (_d, mut v) = fresh_vault();
    let body = person_note(&mut v, "Body", "#shared\n");
    let agent = person_note(&mut v, "Agent", "text\n");
    let person = person_note(&mut v, "Person", "text\n");
    seed_row(&v, &agent.id, "shared", "agent");
    seed_row(&v, &person.id, "shared", "person");
    seed_row(&v, &agent.id, "agent-only", "agent");
    seed_row(&v, &person.id, "person-only", "person");
    assert_eq!(rows(&v, &body.id).len(), 1);

    assert_eq!(
        tags::vocabulary(&v).unwrap(),
        vec![TagCount {
            tag: "shared".into(),
            note_count: 3,
            system: false,
        }]
    );
}

#[test]
fn tag_reads_treat_malformed_frontmatter_as_not_a_guide() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Broken", "#x\n");
    v.connection_ref()
        .execute(
            "UPDATE notes SET frontmatter = 'not json' WHERE id = ?",
            [note.id.as_str()],
        )
        .unwrap();

    assert_eq!(vocabulary_names(&v), vec!["x"]);
    let listed = tags::notes_for_tag(&v, "x").unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].role, None);
}

// ---------- AC 13: a recorded removal ----------

#[test]
fn person_remove_tag_on_an_agent_tag_writes_one_correction_with_note_title_and_keeps_review_state()
{
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    seed_vocabulary(&mut v, "y");
    let day = day_note(&mut v, "text\n");
    tags::agent_tag_note(&mut v, &day.id, "x", None).unwrap();
    tags::agent_tag_note(&mut v, &day.id, "y", None).unwrap();
    assert_eq!(footer_lines(&v, &day.id), vec!["x", "y"]);
    mark_reviewed(&mut v, &day.id);
    let cv = content_version(&v, &day.id);
    let before = stored(&v, &day.id);
    count_tag_writes(&v);

    let removal = tags::person_remove_tag(&mut v, &day.id, "x", None).unwrap();

    assert!(removal.removed);
    let after = stored(&v, &day.id);
    assert_eq!(removal.version, after.version);
    assert_eq!(after.version, before.version + 1, "one footer write");
    assert_eq!(
        writes_to(&v, "tag_corrections"),
        1,
        "exactly one correction row"
    );
    let all = corrections(&v);
    assert_eq!(all.len(), 1);
    let c = &all[0];
    assert_eq!(removal.correction_id, Some(c.id));
    assert_eq!(c.note_id.as_deref(), Some(day.id.as_str()));
    assert_eq!(c.note_title, DAY);
    assert_eq!(c.tag, "x");
    assert_eq!(c.kind, "removed");
    assert!(c.created_at > 0, "a real time, not {}", c.created_at);
    assert_eq!(c.cleared_at, None, "active: it blocks");
    assert_eq!(rows(&v, &day.id), vec![row("y", "agent", None)]);
    assert_eq!(split(&after).tags, vec!["y"], "the footer re-rendered");
    assert_eq!(content_version(&v, &day.id), cv);
    assert_eq!(review_state(&v, &day.id), ReviewState::Reviewed);
    assert_code(
        tags::agent_tag_note(&mut v, &day.id, "x", None),
        "tag_removed",
        "R35",
    );
}

#[test]
fn person_remove_tag_on_the_last_footer_item_of_a_non_daily_note_removes_the_marker() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "my text\n");
    tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
    assert!(stored(&v, &note.id).content_md.contains(M));

    tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();

    let after = stored(&v, &note.id);
    assert!(!after.content_md.contains(M), "{}", after.content_md);
    assert_eq!(after.content_md.trim_end(), "my text");
    assert_eq!(corrections(&v)[0].note_title, "Note");
}

#[test]
fn correction_keeps_its_title_after_a_rename_and_outlives_its_note() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "First Title", "text\n");
    tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
    let removal = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
    let id = removal.correction_id.expect("a recorded removal");

    let version = stored(&v, &note.id).version;
    update_note_as(
        &mut v,
        &note.id,
        version,
        UpdateNote {
            title: Some("Second Title".into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap();
    assert_eq!(correction(&v, id).note_title, "First Title");

    delete_note(&mut v, &note.id).unwrap();

    let kept = correction(&v, id);
    assert_eq!(kept.note_id, None, "D7a: SET NULL");
    assert_eq!(kept.note_title, "First Title");
}

#[test]
fn person_remove_tag_keeps_the_tag_when_its_correction_cannot_be_written() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "text\n");
    tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
    let before = stored(&v, &note.id);

    abort_on(&v, "INSERT", "tag_corrections");
    let failed = tags::person_remove_tag(&mut v, &note.id, "x", None);
    stop_aborting(&v);

    assert!(failed.is_err(), "the correction insert was aborted");
    assert_eq!(rows(&v, &note.id), vec![row("x", "agent", None)]);
    assert_eq!(stored(&v, &note.id).content_md, before.content_md);
}

// ---------- AC 14: removals that record nothing ----------

#[test]
fn person_remove_tag_on_a_system_person_or_missing_tag_writes_zero_correction_rows() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");
    // System tags go whatever their origin; a person tag has a footer line.
    seed_row(&v, &note.id, "inbox", "agent");
    seed_row(&v, &note.id, "agent-authored", "person");
    tags::person_add_tag(&mut v, &note.id, "mine", None).unwrap();
    assert_eq!(footer_lines(&v, &note.id), vec!["mine"], "setup");
    count_tag_writes(&v);

    for tag in ["inbox", "agent-authored", "mine"] {
        let removal = tags::person_remove_tag(&mut v, &note.id, tag, None).unwrap();
        assert!(removal.removed, "{tag}");
        assert_eq!(removal.correction_id, None, "{tag}");
        assert_eq!(removal.version, stored(&v, &note.id).version, "{tag}");
    }
    assert!(rows(&v, &note.id).is_empty());
    assert!(
        footer_lines(&v, &note.id).is_empty(),
        "the person tag's line went"
    );
    assert_eq!(writes_to(&v, "tag_corrections"), 0);

    // Missing: nothing happens at all.
    let before = stored(&v, &note.id);
    reset_tag_writes(&v);
    let removal = tags::person_remove_tag(&mut v, &note.id, "missing", None).unwrap();
    assert!(!removal.removed);
    assert_eq!(removal.correction_id, None);
    assert_eq!(removal.version, before.version);
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(stored(&v, &note.id).version, before.version);

    // A person-tag removal leaves no block.
    seed_vocabulary(&mut v, "mine");
    assert!(
        tags::agent_tag_note(&mut v, &note.id, "mine", None)
            .unwrap()
            .changed
    );
}

#[test]
fn agent_untag_note_removes_an_agent_tag_and_writes_zero_correction_rows() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "text\n");
    tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
    let before = stored(&v, &note.id);
    assert!(
        before.content_md.contains(M),
        "setup: {}",
        before.content_md
    );
    count_tag_writes(&v);

    let removal = tags::agent_untag_note(&mut v, &note.id, "x", None).unwrap();

    assert!(removal.removed);
    assert_eq!(removal.correction_id, None);
    let after = stored(&v, &note.id);
    assert_eq!(removal.version, after.version);
    assert_eq!(after.version, before.version + 1);
    assert!(!after.content_md.contains(M), "{}", after.content_md);
    assert!(rows(&v, &note.id).is_empty());
    assert_eq!(writes_to(&v, "tag_corrections"), 0);

    // No block: the agent can apply it again.
    assert!(
        tags::agent_tag_note(&mut v, &note.id, "x", None)
            .unwrap()
            .changed
    );
}

#[test]
fn agent_untag_note_fails_on_every_other_origin_and_on_a_guide() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "#written here\n");
    seed_row(&v, &note.id, "mine", "person");
    seed_row(&v, &note.id, "inbox", "agent");
    let before_rows = rows(&v, &note.id);
    assert_eq!(before_rows.len(), 3, "setup");
    count_tag_writes(&v);

    for tag in ["written", "mine", "inbox"] {
        assert_invalid_argument(tags::agent_untag_note(&mut v, &note.id, tag, None), tag);
    }
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &note.id), before_rows);
    assert_eq!(stored(&v, &note.id).version, note.version);

    let guide = guide_note(&mut v, "How to.\n");
    assert_code(
        tags::agent_untag_note(&mut v, &guide.id, "written", None),
        "guide_rule",
        "a guide",
    );
}

#[test]
fn tag_writes_on_an_unknown_note_are_not_found() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let id = NoteId::new();
    assert_code(
        tags::apply_tag(&mut v, &id, "x", TagOrigin::Agent, None),
        "not_found",
        "apply_tag",
    );
    assert_code(
        tags::person_add_tag(&mut v, &id, "x", None),
        "not_found",
        "person_add_tag",
    );
    assert_code(
        tags::person_remove_tag(&mut v, &id, "x", None),
        "not_found",
        "person_remove_tag",
    );
    assert_code(
        tags::agent_untag_note(&mut v, &id, "x", None),
        "not_found",
        "agent_untag_note",
    );
}

// ---------- AC 15: a body tag can't be removed ----------

#[test]
fn person_remove_tag_on_a_body_tag_fails_and_changes_nothing() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "#x here\n");
        let before_rows = rows(&v, &note.id);
        assert_eq!(
            before_rows,
            vec![row("x", "body", Some("#x here"))],
            "{kind:?}"
        );
        let before = stored(&v, &note.id);
        count_tag_writes(&v);

        let message = assert_invalid_argument(
            tags::person_remove_tag(&mut v, &note.id, "x", None),
            "a body tag",
        );

        assert!(message.contains("delete the text"), "{kind:?}: {message}");
        assert_eq!(tag_writes(&v), 0, "{kind:?}");
        assert_eq!(rows(&v, &note.id), before_rows, "{kind:?}");
        let after = stored(&v, &note.id);
        assert_eq!(after.version, before.version, "{kind:?}");
        assert_eq!(after.content_md, before.content_md, "{kind:?}");
    }
}

// ---------- AC 16: the block's life ----------

#[test]
fn block_lifts_when_the_person_writes_the_tag_and_a_later_removal_inserts_a_new_id() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        seed_vocabulary(&mut v, "x");
        let note = note_of(&mut v, kind, "text\n");
        tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
        let first = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
        let first = first.correction_id.expect("recorded");
        assert_code(
            tags::agent_tag_note(&mut v, &note.id, "x", None),
            "tag_removed",
            "blocked",
        );

        // Writing `#x` lifts it, keeping the row.
        person_save(&mut v, &note.id, "text\n\n#x here\n");
        let lifted = correction(&v, first);
        let cleared_at = lifted.cleared_at.expect("cleared_at set");
        assert!(cleared_at > 0, "{kind:?}: a real time");

        // The tag goes with its text, and the agent may apply it again.
        person_save(&mut v, &note.id, "text\n");
        assert!(rows(&v, &note.id).is_empty(), "{kind:?}");
        assert!(
            tags::agent_tag_note(&mut v, &note.id, "x", None)
                .unwrap()
                .changed
        );

        // Removing again is a new row with a new id.
        let second = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
        let second = second.correction_id.expect("recorded");
        assert!(second > first, "{kind:?}: a new id, {second} after {first}");
        assert_eq!(correction(&v, second).cleared_at, None, "{kind:?}");
        assert_eq!(
            correction(&v, first),
            lifted,
            "{kind:?}: the old row is kept"
        );
        assert_eq!(corrections(&v).len(), 2, "{kind:?}");
        assert_code(
            tags::agent_tag_note(&mut v, &note.id, "x", None),
            "tag_removed",
            "blocked again",
        );
    }
}

#[test]
fn block_lifts_on_person_add_tag_and_a_later_removal_inserts_a_new_id() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "text\n");
    tags::agent_tag_note(&mut v, &note.id, "x", None).unwrap();
    let first = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
    let first = first.correction_id.expect("recorded");

    let write = tags::person_add_tag(&mut v, &note.id, "x", None).unwrap();

    assert!(write.changed);
    assert_eq!(rows(&v, &note.id), vec![row("x", "person", None)]);
    let lifted = correction(&v, first);
    assert!(lifted.cleared_at.is_some(), "cleared_at set, row kept");

    // A person tag's removal records nothing; an agent tag's records anew.
    let removal = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
    assert_eq!(removal.correction_id, None);
    assert!(
        tags::agent_tag_note(&mut v, &note.id, "x", None)
            .unwrap()
            .changed
    );
    let second = tags::person_remove_tag(&mut v, &note.id, "x", None).unwrap();
    let second = second.correction_id.expect("recorded");
    assert!(second > first);
    assert_eq!(correction(&v, first), lifted);
}

#[test]
fn lifting_a_block_touches_only_open_rows_for_that_note_and_tag() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");
    let other = person_note(&mut v, "Other", "text\n");
    let old = seed_block(&v, &note, "x");
    v.connection_ref()
        .execute(
            "UPDATE tag_corrections SET cleared_at = 123 WHERE id = ?",
            [old],
        )
        .unwrap();
    let open = seed_block(&v, &note, "x");
    let other_tag = seed_block(&v, &note, "y");
    let other_note = seed_block(&v, &other, "x");

    person_save(&mut v, &note.id, "#x here\n");

    assert_eq!(correction(&v, old).cleared_at, Some(123), "already cleared");
    assert!(
        correction(&v, open).cleared_at.is_some(),
        "open row cleared"
    );
    assert_eq!(correction(&v, other_tag).cleared_at, None, "another tag");
    assert_eq!(correction(&v, other_note).cleared_at, None, "another note");

    // And unchanged on a later save, which writes nothing.
    let at = correction(&v, open).cleared_at;
    count_tag_writes(&v);
    person_save(&mut v, &note.id, "#x here\n");
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(correction(&v, open).cleared_at, at);
}

#[test]
fn person_save_without_the_tag_leaves_its_block_open() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "text\n");
    let block = seed_block(&v, &note, "x");

    person_save(&mut v, &note.id, "other #y text\n");

    assert_eq!(
        rows(&v, &note.id),
        vec![row("y", "body", Some("other #y text"))]
    );
    assert_eq!(correction(&v, block).cleared_at, None);
    assert_code(
        tags::agent_tag_note(&mut v, &note.id, "x", None),
        "tag_removed",
        "still blocked",
    );
}

#[test]
fn person_add_tag_adds_a_body_less_person_tag_and_requires_a_valid_name() {
    for kind in KINDS {
        let (_d, mut v) = fresh_vault();
        let note = note_of(&mut v, kind, "text\n");

        let write = tags::person_add_tag(&mut v, &note.id, "Mine", None).unwrap();

        let after = stored(&v, &note.id);
        assert!(write.changed, "{kind:?}");
        assert_eq!(write.version, after.version, "{kind:?}");
        assert_eq!(after.version, note.version + 1, "{kind:?}");
        assert_eq!(
            rows(&v, &note.id),
            vec![row("mine", "person", None)],
            "{kind:?}"
        );
        assert_eq!(split(&after).tags, vec!["mine"], "{kind:?}");

        // A repeat writes nothing.
        count_tag_writes(&v);
        let again = tags::person_add_tag(&mut v, &note.id, "mine", None).unwrap();
        assert!(!again.changed, "{kind:?}");
        assert_eq!(again.version, after.version, "{kind:?}");
        assert_eq!(tag_writes(&v), 0, "{kind:?}");

        for invalid in ["", "not a tag", "123", "a/b"] {
            reset_tag_writes(&v);
            assert_invalid_argument(
                tags::person_add_tag(&mut v, &note.id, invalid, None),
                invalid,
            );
            assert_eq!(tag_writes(&v), 0, "{kind:?} {invalid:?}");
        }
    }
}

#[test]
fn person_add_tag_keeps_a_body_tag_and_refuses_a_guide() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "#x here\n");
    assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("#x here"))]);
    count_tag_writes(&v);

    let write = tags::person_add_tag(&mut v, &note.id, "x", None).unwrap();

    assert!(!write.changed);
    assert_eq!(write.version, note.version);
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("#x here"))]);

    let guide = guide_note(&mut v, "How to.\n");
    assert_code(
        tags::person_add_tag(&mut v, &guide.id, "x", None),
        "guide_rule",
        "R45, R53",
    );
    assert!(rows(&v, &guide.id).is_empty());
}

// ---------- AC 17: a block is per note ----------

#[test]
fn block_on_one_note_does_not_affect_the_same_tag_on_another_note() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let blocked = person_note(&mut v, "Blocked", "text\n");
    let free = person_note(&mut v, "Free", "text\n");
    tags::agent_tag_note(&mut v, &blocked.id, "x", None).unwrap();
    tags::person_remove_tag(&mut v, &blocked.id, "x", None).unwrap();

    assert_code(
        tags::agent_tag_note(&mut v, &blocked.id, "x", None),
        "tag_removed",
        "the blocked note",
    );
    let write = tags::agent_tag_note(&mut v, &free.id, "x", None).unwrap();

    assert!(write.changed);
    assert_eq!(rows(&v, &free.id), vec![row("x", "agent", None)]);
    assert_code(
        tags::agent_tag_note(&mut v, &blocked.id, "x", None),
        "tag_removed",
        "still blocked",
    );
}

// ---------- AC 18: apply_tag ----------

#[test]
fn apply_tag_with_agent_on_a_new_note_writes_the_footer_line_in_the_same_call() {
    for (origin, stored_origin) in [(TagOrigin::Agent, "agent"), (TagOrigin::Person, "person")] {
        for kind in KINDS {
            let (_d, mut v) = fresh_vault();
            let note = note_of(&mut v, kind, "text\n");

            // Any name goes (R40): nothing here is in the vocabulary.
            let write = tags::apply_tag(&mut v, &note.id, "fresh", origin, None).unwrap();

            let after = stored(&v, &note.id);
            assert!(write.changed, "{kind:?} {origin:?}");
            assert_eq!(write.version, after.version, "{kind:?} {origin:?}");
            assert_eq!(after.version, note.version + 1, "{kind:?} {origin:?}");
            assert_eq!(
                rows(&v, &note.id),
                vec![row("fresh", stored_origin, None)],
                "{kind:?} {origin:?}"
            );
            assert_eq!(split(&after).tags, vec!["fresh"], "{kind:?} {origin:?}");
            assert_eq!(split(&after).person, "text\n", "{kind:?} {origin:?}");
        }
    }
}

#[test]
fn apply_tag_never_gives_a_system_tag_a_footer_line() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");

    let write =
        tags::apply_tag(&mut v, &note.id, "agent-authored", TagOrigin::Agent, None).unwrap();
    tags::apply_tag(&mut v, &note.id, "inbox", TagOrigin::Person, None).unwrap();

    let after = stored(&v, &note.id);
    assert!(write.changed);
    assert_eq!(
        rows(&v, &note.id),
        vec![
            row("agent-authored", "agent", None),
            row("inbox", "person", None),
        ]
    );
    assert!(!after.content_md.contains(M), "{}", after.content_md);
    assert_eq!(after.content_md, "text\n");
    assert!(footer_lines(&v, &note.id).is_empty());
}

#[test]
fn apply_tag_on_a_tag_the_note_already_has_writes_nothing_and_never_downgrades_body() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "#x here\n");
    assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("#x here"))]);
    count_tag_writes(&v);

    let write = tags::apply_tag(&mut v, &note.id, "x", TagOrigin::Agent, None).unwrap();

    assert!(!write.changed);
    assert_eq!(write.version, note.version);
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &note.id), vec![row("x", "body", Some("#x here"))]);
    assert_eq!(stored(&v, &note.id).version, note.version);
}

// ---------- AC 19: becoming a guide (D45: refused, nothing changes) ----------

#[test]
fn note_becoming_a_guide_is_refused_with_guide_rule_and_keeps_its_tag_rows_and_footer() {
    // The save carries no body, then one with the footer in it.
    for with_body in [false, true] {
        let (_d, mut v) = fresh_vault();
        let chip = topic_note(&mut v, "Chip", "About.\n");
        let note = person_note(&mut v, "Note", "#x my text\n");
        seed_row(&v, &note.id, "x", "body");
        seed_row(&v, &note.id, "y", "agent");
        footer::set_chip(&mut v, &note.id, &chip.id, ChipOrigin::Person, None).unwrap();
        let block = seed_block(&v, &note, "z");
        let before = stored(&v, &note.id);
        assert!(
            before.content_md.contains(M),
            "setup: {}",
            before.content_md
        );

        let rows_before = rows(&v, &note.id);
        let corrections_before = corrections(&v);
        count_tag_writes(&v);

        // After #288 (D45) the vault has one guide: no note can become it.
        for caller in [Caller::Person, Caller::Agent] {
            assert_code(
                update_note_as(
                    &mut v,
                    &note.id,
                    before.version,
                    UpdateNote {
                        content_md: with_body.then(|| before.content_md.clone()),
                        frontmatter: Some(json!({"role": "guide"})),
                        ..Default::default()
                    },
                    RenameOptions::default(),
                    caller,
                ),
                "guide_rule",
                &format!("with_body {with_body}, {caller:?}"),
            );
        }

        let after = stored(&v, &note.id);
        assert_eq!(after.content_md, before.content_md, "with_body {with_body}");
        assert!(after.content_md.contains(M), "the footer stays");
        assert_eq!(after.version, before.version, "with_body {with_body}");
        assert_eq!(
            after.frontmatter, before.frontmatter,
            "with_body {with_body}"
        );
        assert_eq!(rows(&v, &note.id), rows_before, "with_body {with_body}");
        assert_eq!(tag_writes(&v), 0, "a refused save writes no tag row");
        assert_eq!(corrections(&v), corrections_before, "corrections stay");
        assert_eq!(correction(&v, block).cleared_at, None);
    }
}

// ---------- AC 20: content_version ----------

#[test]
fn person_save_on_a_daily_note_moves_content_version_only_when_person_text_changed() {
    let (_d, mut v) = fresh_vault();
    let person = "#x note\n";
    let day = day_note(&mut v, person);
    // An agent row over text no scan has seen, its footer line stored.
    seed_row(&v, &day.id, "x", "agent");
    set_body(&mut v, &day.id, &format!("{person}{M}\n#x\n"));
    mark_reviewed(&mut v, &day.id);
    let cv = content_version(&v, &day.id);
    let before = stored(&v, &day.id);

    // The origin upgrade rewrites the footer; the person text is the same.
    let saved = person_save(&mut v, &day.id, person);

    assert_eq!(rows(&v, &day.id), vec![row("x", "body", Some("#x note"))]);
    assert!(split(&saved).tags.is_empty(), "{}", saved.content_md);
    assert_eq!(saved.version, before.version + 1, "version moves");
    assert_eq!(
        content_version(&v, &day.id),
        cv,
        "upgrade: same person text"
    );
    assert_eq!(review_state(&v, &day.id), ReviewState::Reviewed);

    // No change at all.
    person_save(&mut v, &day.id, person);
    assert_eq!(content_version(&v, &day.id), cv, "same text");
    assert_eq!(review_state(&v, &day.id), ReviewState::Reviewed);

    // Person text changes, once.
    person_save(&mut v, &day.id, "#x note\n\nmore\n");
    assert_eq!(content_version(&v, &day.id), cv + 1, "changed text");
    assert_eq!(review_state(&v, &day.id), ReviewState::ChangedSinceReview);
}

#[test]
fn tag_writes_never_move_a_daily_notes_content_version() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let day = day_note(&mut v, "text\n");
    mark_reviewed(&mut v, &day.id);
    let cv = content_version(&v, &day.id);

    let applied = tags::apply_tag(&mut v, &day.id, "a", TagOrigin::Agent, None).unwrap();
    let added = tags::person_add_tag(&mut v, &day.id, "b", None).unwrap();
    let tagged = tags::agent_tag_note(&mut v, &day.id, "x", None).unwrap();
    let untagged = tags::agent_untag_note(&mut v, &day.id, "x", None).unwrap();
    let removed = tags::person_remove_tag(&mut v, &day.id, "b", None).unwrap();

    assert!(applied.changed && added.changed && tagged.changed);
    assert!(untagged.removed && removed.removed);
    assert_eq!(footer_lines(&v, &day.id), vec!["a"]);
    assert_eq!(content_version(&v, &day.id), cv);
    assert_eq!(review_state(&v, &day.id), ReviewState::Reviewed);
}

// ---------- tag inputs (R38) ----------

#[test]
fn tag_inputs_match_a_stored_name_exactly_first_then_lowercased() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "pricing");
    let note = person_note(&mut v, "Note", "#pricing here\n");
    seed_row(&v, &note.id, "Pricing", "person");

    // The legacy row, exactly; then nothing but the lowercase body row.
    let removal = tags::person_remove_tag(&mut v, &note.id, "Pricing", None).unwrap();
    assert!(removal.removed);
    assert_eq!(
        rows(&v, &note.id),
        vec![row("pricing", "body", Some("#pricing here"))]
    );
    assert_invalid_argument(
        tags::person_remove_tag(&mut v, &note.id, "Pricing", None),
        "lowercased onto the body row",
    );

    // Lowercased, when no stored name matches exactly.
    let other = person_note(&mut v, "Other", "text\n");
    seed_row(&v, &other.id, "alpha", "agent");
    seed_row(&v, &other.id, "beta", "agent");
    seed_row(&v, &other.id, "gamma", "person");
    assert!(
        tags::person_remove_tag(&mut v, &other.id, "ALPHA", None)
            .unwrap()
            .removed
    );
    assert!(
        tags::agent_untag_note(&mut v, &other.id, "BETA", None)
            .unwrap()
            .removed
    );
    assert!(
        tags::person_remove_tag(&mut v, &other.id, "GAMMA", None)
            .unwrap()
            .removed
    );
    assert!(rows(&v, &other.id).is_empty());

    // A stored name outside the grammar is still reachable, exactly (R50).
    let legacy = person_note(&mut v, "Legacy", "text\n");
    seed_row(&v, &legacy.id, "foo bar", "person");
    seed_row(&v, &legacy.id, "Legacy", "agent");
    assert!(
        tags::person_remove_tag(&mut v, &legacy.id, "foo bar", None)
            .unwrap()
            .removed
    );
    assert!(
        tags::agent_untag_note(&mut v, &legacy.id, "Legacy", None)
            .unwrap()
            .removed
    );
    assert!(rows(&v, &legacy.id).is_empty());

    // Adding a name the note holds exactly writes nothing.
    let held = person_note(&mut v, "Held", "text\n");
    seed_row(&v, &held.id, "Pricing", "person");
    count_tag_writes(&v);
    let write = tags::person_add_tag(&mut v, &held.id, "Pricing", None).unwrap();
    assert!(!write.changed);
    let tagged = tags::agent_tag_note(&mut v, &held.id, "Pricing", None).unwrap();
    assert!(!tagged.changed);
    assert_eq!(tagged.version, stored(&v, &held.id).version);
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(rows(&v, &held.id), vec![row("Pricing", "person", None)]);
}

// ---------- reads ----------

#[test]
fn all_tags_lists_every_tag_alphabetically_with_the_system_flag() {
    let (_d, mut v) = fresh_vault();
    let a = person_note(&mut v, "A", "#zeta #alpha\n");
    let b = person_note(&mut v, "B", "#alpha\n");
    seed_row(&v, &a.id, "mid", "agent");
    seed_row(&v, &a.id, "inbox", "agent");
    seed_row(&v, &b.id, "agent-authored", "agent");
    seed_row(&v, &b.id, "inbox", "person");

    let count = |tag: &str, note_count, system| TagCount {
        tag: tag.into(),
        note_count,
        system,
    };
    assert_eq!(
        tags::all_tags(&v).unwrap(),
        vec![
            count("agent-authored", 1, true),
            count("alpha", 2, false),
            count("inbox", 2, true),
            count("mid", 1, false),
            count("zeta", 1, false),
        ]
    );
}

#[test]
fn notes_for_tag_lists_notes_most_recently_updated_first_with_their_first_line() {
    let (_d, mut v) = fresh_vault();
    let body = person_note(&mut v, "Body", "- [ ] #work to do\n");
    let agent = topic_note(&mut v, "Agent", "text\n");
    let day = day_note(&mut v, "#work today\n");
    person_note(&mut v, "Unrelated", "#other\n");
    seed_row(&v, &agent.id, "work", "agent");
    for (note, updated_at) in [(&body, 100_i64), (&agent, 300), (&day, 200)] {
        v.connection_ref()
            .execute(
                "UPDATE notes SET updated_at = ? WHERE id = ?",
                params![updated_at, note.id.as_str()],
            )
            .unwrap();
    }

    let listed = tags::notes_for_tag(&v, "work").unwrap();

    let want = |note: &Note, role: Option<&str>, first_line: Option<&str>, updated_at| TagNote {
        note_id: note.id.to_string(),
        title: note.title.clone(),
        role: role.map(str::to_string),
        first_line: first_line.map(str::to_string),
        updated_at,
    };
    assert_eq!(
        listed,
        vec![
            want(&agent, Some("topic"), None, 300),
            want(&day, Some("daily"), Some("#work today"), 200),
            want(&body, None, Some("#work to do"), 100),
        ]
    );
    assert!(tags::notes_for_tag(&v, "nothing").unwrap().is_empty());
}

#[test]
fn agent_tags_and_footer_tags_read_a_note_by_origin() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "#written\n");
    let other = person_note(&mut v, "Other", "#elsewhere\n");
    seed_row(&v, &note.id, "b", "agent");
    seed_row(&v, &note.id, "a", "agent");
    seed_row(&v, &note.id, "mine", "person");
    // The agent can't remove a system tag, so it isn't listed as its own.
    seed_row(&v, &note.id, "inbox", "agent");
    seed_row(&v, &other.id, "c", "agent");

    let sorted = |mut names: Vec<String>| {
        names.sort();
        names
    };
    assert_eq!(
        sorted(tags::agent_tags_for_note(&v, &note.id).unwrap()),
        vec!["a", "b"]
    );
    assert_eq!(
        sorted(tags::footer_tags_for_note(&v, &note.id).unwrap()),
        vec!["a", "b", "mine"]
    );
}

// ---------- contract pins added in verify ----------

#[test]
fn tag_reads_sort_ignoring_case_then_by_exact_name() {
    let (_d, mut v) = fresh_vault();
    let a = person_note(&mut v, "A", "text\n");
    let b = person_note(&mut v, "B", "text\n");
    // Legacy rows can hold capitals: ASCII order alone would list "Bravo" first.
    for tag in ["Bravo", "alpha", "charlie", "x", "X"] {
        seed_row(&v, &a.id, tag, "body");
    }
    seed_row(&v, &b.id, "Bravo", "agent");

    let names = |counts: Vec<TagCount>| -> Vec<(String, i64)> {
        counts.into_iter().map(|t| (t.tag, t.note_count)).collect()
    };
    let want: Vec<(String, i64)> = [
        ("alpha", 1),
        ("Bravo", 2),
        ("charlie", 1),
        ("X", 1),
        ("x", 1),
    ]
    .into_iter()
    .map(|(tag, n)| (tag.to_string(), n))
    .collect();
    assert_eq!(names(tags::all_tags(&v).unwrap()), want);
    assert_eq!(names(tags::vocabulary(&v).unwrap()), want);
}

#[test]
fn notes_for_tag_breaks_ties_by_id_and_matches_the_exact_name_only() {
    let (_d, mut v) = fresh_vault();
    let notes: Vec<Note> = (0..3)
        .map(|i| person_note(&mut v, &format!("Tied {i}"), "#work here\n"))
        .collect();
    for note in &notes {
        v.connection_ref()
            .execute(
                "UPDATE notes SET updated_at = 500 WHERE id = ?",
                [note.id.as_str()],
            )
            .unwrap();
    }
    seed_row(&v, &notes[0].id, "Work", "person");

    let listed: Vec<String> = tags::notes_for_tag(&v, "work")
        .unwrap()
        .into_iter()
        .map(|n| n.note_id)
        .collect();

    let mut want: Vec<String> = notes.iter().map(|n| n.id.to_string()).collect();
    want.sort();
    assert_eq!(listed, want, "equal updated_at: by id");
    let capital = tags::notes_for_tag(&v, "Work").unwrap();
    assert_eq!(capital.len(), 1, "no lowercasing of the asked name");
    assert_eq!(capital[0].note_id, notes[0].id.to_string());
}

#[test]
fn agent_tags_for_note_on_an_unknown_note_is_empty() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");
    seed_row(&v, &note.id, "a", "agent");

    assert!(tags::agent_tags_for_note(&v, &NoteId::new())
        .unwrap()
        .is_empty());
    assert_eq!(tags::agent_tags_for_note(&v, &note.id).unwrap(), vec!["a"]);
}

#[test]
fn a_leading_hash_on_a_tag_input_is_stripped_once() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "pricing");
    let note = person_note(&mut v, "Note", "text\n");

    let tagged = tags::agent_tag_note(&mut v, &note.id, "#Pricing", None).unwrap();
    assert!(tagged.changed);
    assert_eq!(rows(&v, &note.id), vec![row("pricing", "agent", None)]);
    let untagged = tags::agent_untag_note(&mut v, &note.id, "#PRICING", None).unwrap();
    assert!(untagged.removed);
    assert!(rows(&v, &note.id).is_empty());

    let added = tags::person_add_tag(&mut v, &note.id, "#Mine", None).unwrap();
    assert!(added.changed);
    assert_eq!(rows(&v, &note.id), vec![row("mine", "person", None)]);
    let removed = tags::person_remove_tag(&mut v, &note.id, "#mine", None).unwrap();
    assert!(removed.removed);
    assert!(rows(&v, &note.id).is_empty());

    // Only one # goes: "##pricing" is neither a vocabulary name nor a valid one.
    assert_code(
        tags::agent_tag_note(&mut v, &note.id, "##pricing", None),
        "unknown_tag",
        "two hashes",
    );
    assert_invalid_argument(
        tags::person_add_tag(&mut v, &note.id, "##mine", None),
        "two hashes",
    );
    assert!(rows(&v, &note.id).is_empty());
}

#[test]
fn agent_tag_note_with_a_name_outside_the_grammar_is_unknown_tag() {
    let (_d, mut v) = fresh_vault();
    seed_vocabulary(&mut v, "x");
    let note = person_note(&mut v, "Note", "text\n");
    count_tag_writes(&v);

    for bad in ["", "not a tag", "123", "a/b"] {
        assert_code(
            tags::agent_tag_note(&mut v, &note.id, bad, None),
            "unknown_tag",
            bad,
        );
    }
    assert_eq!(tag_writes(&v), 0);
}

#[test]
fn apply_tag_refuses_origin_body_and_a_guide_and_writes_nothing() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");
    let guide = guide_note(&mut v, "How to.\n");
    count_tag_writes(&v);

    assert_invalid_argument(
        tags::apply_tag(&mut v, &note.id, "x", TagOrigin::Body, None),
        "origin body",
    );
    for origin in [TagOrigin::Agent, TagOrigin::Person] {
        assert_code(
            tags::apply_tag(&mut v, &guide.id, "x", origin, None),
            "guide_rule",
            &format!("{origin:?} on a guide"),
        );
    }
    assert_invalid_argument(
        tags::apply_tag(&mut v, &note.id, "not a tag", TagOrigin::Agent, None),
        "outside the grammar",
    );
    assert_eq!(tag_writes(&v), 0);
    assert!(rows(&v, &note.id).is_empty());
    assert!(rows(&v, &guide.id).is_empty());
    assert_eq!(stored(&v, &note.id).version, note.version);
}

#[test]
fn apply_tag_with_agent_origin_does_not_lift_an_open_block() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");
    let block = seed_block(&v, &note, "x");

    let write = tags::apply_tag(&mut v, &note.id, "x", TagOrigin::Agent, None).unwrap();

    assert!(write.changed);
    assert_eq!(rows(&v, &note.id), vec![row("x", "agent", None)]);
    assert_eq!(
        correction(&v, block).cleared_at,
        None,
        "only a person lifts"
    );
}

#[test]
fn agent_untag_note_on_a_tag_the_note_does_not_have_writes_nothing() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");
    count_tag_writes(&v);

    let removal = tags::agent_untag_note(&mut v, &note.id, "missing", None).unwrap();

    assert!(!removal.removed);
    assert_eq!(removal.correction_id, None);
    assert_eq!(removal.version, note.version);
    assert_eq!(tag_writes(&v), 0);
    assert_eq!(stored(&v, &note.id).version, note.version);
}

#[test]
fn system_tag_rows_write_no_note() {
    let (_d, mut v) = fresh_vault();
    let note = person_note(&mut v, "Note", "text\n");

    let added = tags::apply_tag(&mut v, &note.id, "inbox", TagOrigin::Agent, None).unwrap();
    let after_add = stored(&v, &note.id);
    assert!(added.changed);
    assert_eq!(added.version, note.version);
    assert_eq!(after_add.version, note.version);
    assert_eq!(after_add.updated_at, note.updated_at);
    assert_eq!(after_add.content_md, note.content_md);

    let removed = tags::person_remove_tag(&mut v, &note.id, "inbox", None).unwrap();
    let after_remove = stored(&v, &note.id);
    assert!(removed.removed);
    assert_eq!(removed.version, note.version);
    assert_eq!(after_remove.version, note.version);
    assert_eq!(after_remove.updated_at, note.updated_at);

    // A tag with a footer line does write the note.
    let line = tags::person_add_tag(&mut v, &note.id, "mine", None).unwrap();
    assert_eq!(line.version, note.version + 1);
}

#[test]
fn note_becoming_a_guide_is_refused_and_keeps_every_footer_chip() {
    let (_d, mut v) = fresh_vault();
    let topic = topic_note(&mut v, "Topic", "About.\n");
    let host = person_note(&mut v, "Host", "text\n");
    let note = topic_note(&mut v, "Note", "text\n");
    footer::set_chip(&mut v, &note.id, &topic.id, ChipOrigin::Person, None).unwrap();
    footer::set_chip(&mut v, &host.id, &note.id, ChipOrigin::Person, None).unwrap();
    let chips = |v: &Vault, column: &str, id: &NoteId| -> i64 {
        v.connection_ref()
            .query_row(
                &format!("SELECT COUNT(*) FROM footer_chips WHERE {column} = ?"),
                [id.as_str()],
                |r| r.get(0),
            )
            .unwrap()
    };
    assert_eq!(chips(&v, "daily_note_id", &note.id), 1, "setup");
    assert_eq!(chips(&v, "topic_note_id", &note.id), 1, "setup");

    let before = stored(&v, &note.id);
    for with_body in [false, true] {
        assert_code(
            update_note_as(
                &mut v,
                &note.id,
                before.version,
                UpdateNote {
                    content_md: with_body.then(|| before.content_md.clone()),
                    frontmatter: Some(json!({"role": "guide"})),
                    ..Default::default()
                },
                RenameOptions::default(),
                Caller::Person,
            ),
            "guide_rule",
            &format!("with_body {with_body}"),
        );
    }

    assert_eq!(
        chips(&v, "daily_note_id", &note.id),
        1,
        "its own chip stays"
    );
    assert_eq!(
        chips(&v, "topic_note_id", &note.id),
        1,
        "chips on other notes stay"
    );
    let after = stored(&v, &note.id);
    assert_eq!(after.content_md, before.content_md, "its footer stays");
    assert_eq!(after.version, before.version);
    assert_eq!(after.frontmatter, json!({"role": "topic"}));
}

#[test]
fn person_remove_tag_on_a_guide_deletes_a_stray_row_and_misses_quietly() {
    let (_d, mut v) = fresh_vault();
    let guide = guide_note(&mut v, "How to.\n");
    seed_row(&v, &guide.id, "stray", "person");

    let missing = tags::person_remove_tag(&mut v, &guide.id, "nothing", None).unwrap();
    assert!(!missing.removed);

    let removal = tags::person_remove_tag(&mut v, &guide.id, "stray", None).unwrap();

    assert!(removal.removed);
    assert_eq!(removal.correction_id, None);
    assert!(rows(&v, &guide.id).is_empty());
    let after = stored(&v, &guide.id);
    assert_eq!(after.content_md, guide.content_md);
    assert_eq!(after.version, guide.version);
}
