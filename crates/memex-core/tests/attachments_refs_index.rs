//! WI #135 (Spec #123 R4, R5, R6, R49): `indexer::write_index` (behind
//! `reindex_note` and the rechunk drain) rewrites a note's
//! `note_attachments` rows on every save: one row per attachment reference
//! line of the note's person section, holding the line's start byte in the
//! stored body. Deleting the note removes its rows (cascade); the
//! `attachments` row and the file in `objects/` stay.
//!
//! A reference line is a line whose content is exactly one R4 attachment
//! reference (`attachments::parse_reference`). Mid-text images and links,
//! lines inside fenced code and footer lines are not reference lines. The
//! save path writes only `note_attachments`: it never inserts into
//! `attachments` (R3 does, at store time), and `note_attachments.path` has
//! no key to it.
//!
//! Real SQLite, real schema, temp vaults with invented names only.

use std::path::Path;

use memex_core::attachments;
use memex_core::daily::TOPICS_MARKER;
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, delete_note, delete_note_checked, get_note, update_note, CreateNote, Note,
    NoteId, UpdateNote,
};
use memex_core::{Caller, Vault};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

// ---- fixtures ---------------------------------------------------------------------------------

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("My Vault")).unwrap();
    (dir, vault)
}

fn reopen(root: &Path) -> Vault {
    Vault::open(root).unwrap_or_else(|e| panic!("open {}: {e}", root.display()))
}

/// A 64-hex content hash whose first two characters are `h2`.
fn hash(h2: &str) -> String {
    h2.repeat(32)
}

/// One stand-in attachment: its R3 markdown and its decoded path.
struct Att {
    markdown: String,
    path: String,
}

/// The attachment `name` with hash `h2…`, its markdown built by the core
/// (R3: an image for an inline image type, a link otherwise).
fn att(h2: &str, name: &str) -> Att {
    let h = hash(h2);
    let markdown = attachments::markdown_for(name, &h);
    let path = attachments::parse_reference(&markdown)
        .unwrap_or_else(|| panic!("fixture: {markdown} is an R4 reference"))
        .target
        .path;
    Att { markdown, path }
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
    reindex(vault, &note.id);
    note
}

/// Reindexes the note from its stored body, as every save does.
fn reindex(vault: &mut Vault, id: &NoteId) {
    let body = stored_body(vault.connection_ref(), id);
    indexer::reindex_note(vault.connection_mut(), id.as_str(), &body, None)
        .unwrap_or_else(|e| panic!("reindex {id}: {e}"));
}

/// A person save of `body` through `update_note`, then the reindex.
fn save(vault: &mut Vault, id: &NoteId, body: &str) {
    let version = get_note(vault, id).unwrap().version;
    update_note(
        vault,
        id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("update {id}: {e}"));
    reindex(vault, id);
}

/// Stores `body` verbatim (no footer rendering) and reindexes it.
fn save_raw(vault: &mut Vault, id: &NoteId, body: &str) {
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = ?1 WHERE id = ?2",
            params![body, id.as_str()],
        )
        .unwrap();
    reindex(vault, id);
}

fn stored_body(conn: &Connection, id: &NoteId) -> String {
    conn.query_row(
        "SELECT content_md FROM notes WHERE id = ?",
        [id.as_str()],
        |r| r.get(0),
    )
    .unwrap()
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

/// `(path, line_start_byte)` of a note's `note_attachments` rows, sorted.
fn refs(conn: &Connection, id: &NoteId) -> Vec<(String, usize)> {
    let mut stmt = conn
        .prepare(
            "SELECT path, line_start_byte FROM note_attachments WHERE note_id = ?
             ORDER BY line_start_byte, path",
        )
        .expect("note_attachments exists (schema V9)");
    stmt.query_map([id.as_str()], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as usize))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// The byte offset in `body` of the `nth` (0-based) line equal to `line`.
fn line_start(body: &str, line: &str, nth: usize) -> usize {
    let mut start = 0;
    let mut seen = 0;
    for l in body.split_inclusive('\n') {
        if l.strip_suffix('\n').unwrap_or(l) == line {
            if seen == nth {
                return start;
            }
            seen += 1;
        }
        start += l.len();
    }
    panic!("fixture: line {line:?} #{nth} not in {body:?}");
}

/// Asserts each row's offset starts its line in `body`, on a char boundary.
fn assert_rows_start_their_lines(body: &str, rows: &[(String, usize)], markdowns: &[&str]) {
    for (path, start) in rows {
        assert!(body.is_char_boundary(*start), "{start} is a char boundary");
        assert!(
            *start == 0 || body.as_bytes()[start - 1] == b'\n',
            "{start} starts a line of {body:?}"
        );
        let line = body[*start..].split('\n').next().unwrap();
        assert!(
            markdowns.contains(&line),
            "row ({path}, {start}) points at {line:?}"
        );
    }
}

fn daily_fm() -> Option<Value> {
    Some(json!({ "role": "daily" }))
}

// ---- AC 4: two reference lines, two rows; one removed, one row ---------------------------------

#[test]
fn saving_a_note_whose_person_section_holds_two_reference_lines_writes_two_rows_at_each_lines_start_byte(
) {
    let (_dir, mut vault) = fresh_vault();
    let mock = att("3f", "mock ☕.png");
    let spec = att("9b", "Q3 report.pdf");
    // Frontmatter and multi-byte text above the lines, so a section-relative
    // or char-counted offset would differ from the byte offset in the body.
    let body = format!(
        "---\nsummary: Café notes\n---\nReview the draft — ünïcödé 🎉\n\n{}\n{}\n\nNext steps\n",
        mock.markdown, spec.markdown
    );
    let note = create(&mut vault, "Draft review", "Start.\n", None);
    save(&mut vault, &note.id, &body);

    let stored = stored_body(vault.connection_ref(), &note.id);
    let rows = refs(vault.connection_ref(), &note.id);
    assert_eq!(
        rows,
        vec![
            (mock.path.clone(), line_start(&stored, &mock.markdown, 0)),
            (spec.path.clone(), line_start(&stored, &spec.markdown, 0)),
        ],
        "one row per reference line, at its start byte in the stored body"
    );
    assert_rows_start_their_lines(&stored, &rows, &[&mock.markdown, &spec.markdown]);
    // The path is the decoded vault-relative path, not the encoded URL.
    assert_eq!(
        spec.path,
        format!("objects/9b/{}/Q3 report.pdf", hash("9b"))
    );
    assert!(spec.markdown.contains("Q3%20report.pdf"));
}

#[test]
fn saving_again_after_one_reference_line_is_removed_leaves_one_row_at_its_new_start_byte() {
    let (_dir, mut vault) = fresh_vault();
    let mock = att("3f", "mock.png");
    let spec = att("9b", "spec.pdf");
    let two = format!("Intro\n\n{}\n{}\n\nOutro\n", mock.markdown, spec.markdown);
    let note = create(&mut vault, "Two files", &two, None);
    assert_eq!(
        refs(vault.connection_ref(), &note.id).len(),
        2,
        "precondition"
    );

    // The first line goes, so the second line moves up.
    let one = format!("Intro\n\n{}\n\nOutro\n", spec.markdown);
    save(&mut vault, &note.id, &one);
    let stored = stored_body(vault.connection_ref(), &note.id);
    assert_eq!(
        refs(vault.connection_ref(), &note.id),
        vec![(spec.path.clone(), line_start(&stored, &spec.markdown, 0))],
        "the removed line's row is gone and the kept row has its new offset"
    );

    // No reference line left: no rows.
    save(&mut vault, &note.id, "Intro\n\nOutro\n");
    assert!(refs(vault.connection_ref(), &note.id).is_empty());
}

#[test]
fn a_save_rewrites_only_the_saved_notes_rows_and_never_writes_attachments() {
    let (_dir, mut vault) = fresh_vault();
    let a = att("1a", "a.pdf");
    let b = att("2b", "b.png");
    // An attachments row R3 would have written for `b`, to see it is kept.
    vault
        .connection_ref()
        .execute(
            "INSERT INTO attachments (path, name, type, size, extract_state)
             VALUES (?1, 'b.png', 'image/png', 12, 'empty')",
            [&b.path],
        )
        .expect("attachments exists (schema V9)");
    let first = create(&mut vault, "First", &format!("{}\n", a.markdown), None);
    let second = create(&mut vault, "Second", &format!("{}\n", b.markdown), None);
    let second_rows = refs(vault.connection_ref(), &second.id);
    assert_eq!(second_rows, vec![(b.path.clone(), 0)]);
    assert_eq!(
        refs(vault.connection_ref(), &first.id),
        vec![(a.path.clone(), 0)]
    );

    save(&mut vault, &first.id, &format!("Text\n{}\n", b.markdown));
    assert_eq!(
        refs(vault.connection_ref(), &first.id),
        vec![(b.path.clone(), 5)]
    );
    assert_eq!(
        refs(vault.connection_ref(), &second.id),
        second_rows,
        "another note's rows are untouched"
    );
    let conn = vault.connection_ref();
    assert_eq!(
        count(conn, "SELECT COUNT(*) FROM attachments"),
        1,
        "a save never inserts into attachments, whose rows R3 writes"
    );
    assert_eq!(
        count(
            conn,
            "SELECT COUNT(*) FROM attachments WHERE extract_state = 'empty' AND size = 12"
        ),
        1,
        "and never changes one"
    );
}

#[test]
fn an_image_and_a_link_reference_line_each_write_a_row_and_other_destinations_write_none() {
    let (_dir, mut vault) = fresh_vault();
    let h = hash("c4");
    let image = format!("![Pic](objects/c4/{h}/pic.png)");
    let link = format!("[Doc](objects/c4/{h}/doc.txt)");
    let not_refs = [
        "![Web](https://example.com/objects/c4/pic.png)".to_string(),
        "[Other](notes/other.md)".to_string(),
        // Hash prefix not equal to the folder.
        format!("![Bad](objects/c5/{h}/pic.png)"),
        // Uppercase hex is not a content hash.
        format!("![Bad](objects/C4/{}/pic.png)", h.to_uppercase()),
        // No name.
        format!("[Bad](objects/c4/{h}/)"),
    ];
    let body = format!("{image}\n{link}\n{}\n", not_refs.join("\n"));
    let note = create(&mut vault, "Kinds", &body, None);
    let stored = stored_body(vault.connection_ref(), &note.id);
    assert_eq!(
        refs(vault.connection_ref(), &note.id),
        vec![
            (
                format!("objects/c4/{h}/pic.png"),
                line_start(&stored, &image, 0)
            ),
            (
                format!("objects/c4/{h}/doc.txt"),
                line_start(&stored, &link, 0)
            ),
        ]
    );
}

// ---- AC 5: fences, mid-text, footers, repeats ------------------------------------------------

#[test]
fn a_reference_inside_a_fenced_code_block_writes_no_row() {
    let (_dir, mut vault) = fresh_vault();
    let hidden = att("5e", "hidden.png");
    let tilde = att("6f", "tilde.pdf");
    let shown = att("7a", "shown.pdf");
    let body = format!(
        "Before\n\n```markdown\n{}\n```\n\n~~~~\n{}\n~~~~\n\n{}\n",
        hidden.markdown, tilde.markdown, shown.markdown
    );
    let note = create(&mut vault, "Fenced", &body, None);
    let stored = stored_body(vault.connection_ref(), &note.id);
    assert_eq!(
        refs(vault.connection_ref(), &note.id),
        vec![(shown.path.clone(), line_start(&stored, &shown.markdown, 0))],
        "only the line after the closed fences is a reference line"
    );
}

#[test]
fn a_mid_text_image_or_link_writes_no_row() {
    let (_dir, mut vault) = fresh_vault();
    let pic = att("8b", "inline.png");
    let doc = att("9c", "inline.pdf");
    let own = att("ad", "own line.pdf");
    let body = format!(
        "See {} here.\n{} trailing words\nLead-in {}\n{}{}\n\n{}\n",
        pic.markdown, doc.markdown, pic.markdown, pic.markdown, doc.markdown, own.markdown
    );
    let note = create(&mut vault, "Mid text", &body, None);
    let stored = stored_body(vault.connection_ref(), &note.id);
    assert_eq!(
        refs(vault.connection_ref(), &note.id),
        vec![(own.path.clone(), line_start(&stored, &own.markdown, 0))],
        "a reference with anything else on its line is not a reference line; \
         one on its own line is"
    );
}

#[test]
fn a_reference_on_a_footer_line_writes_no_row() {
    let (_dir, mut vault) = fresh_vault();
    let person = att("0d", "person.png");
    let footer = att("1e", "footer.pdf");

    // A note's Note footer.
    let body = format!(
        "{}\n\n{TOPICS_MARKER}\n{}\n",
        person.markdown, footer.markdown
    );
    let note = create(&mut vault, "Footer note", "x\n", None);
    save_raw(&mut vault, &note.id, &body);
    assert_eq!(
        refs(vault.connection_ref(), &note.id),
        vec![(person.path.clone(), 0)],
        "the person-section line is a row, the Note footer line is not"
    );

    // A daily note's Topics footer.
    let day = create(&mut vault, "2026-11-18", "x\n", daily_fm());
    let body = format!(
        "Standup ☕\n{}\n\n{TOPICS_MARKER}\n{}\n",
        person.markdown, footer.markdown
    );
    save_raw(&mut vault, &day.id, &body);
    assert_eq!(
        refs(vault.connection_ref(), &day.id),
        vec![(person.path.clone(), "Standup ☕\n".len())],
        "the daily person-section line is a row, the Topics footer line is not"
    );
}

#[test]
fn a_reference_repeated_on_two_lines_writes_two_rows() {
    let (_dir, mut vault) = fresh_vault();
    let deck = att("2f", "deck.pdf");
    let body = format!("{}\n\nMiddle 🎉\n\n{}\n", deck.markdown, deck.markdown);
    let note = create(&mut vault, "Repeated", &body, None);
    let stored = stored_body(vault.connection_ref(), &note.id);
    let rows = refs(vault.connection_ref(), &note.id);
    assert_eq!(
        rows,
        vec![
            (deck.path.clone(), line_start(&stored, &deck.markdown, 0)),
            (deck.path.clone(), line_start(&stored, &deck.markdown, 1)),
        ]
    );
    assert_rows_start_their_lines(&stored, &rows, &[&deck.markdown]);
}

// ---- AC 6: delete cascades; the attachments row and the file stay -----------------------------

#[test]
fn deleting_the_note_removes_its_note_attachments_rows_and_keeps_the_attachments_row_and_the_file()
{
    let (_dir, mut vault) = fresh_vault();
    let root = vault.root().to_path_buf();
    let stored = attachments::store_bytes(&root, b"%PDF-1.4 quarterly", "Q3 report.pdf")
        .expect("store an attachment");
    vault
        .connection_ref()
        .execute(
            "INSERT INTO attachments (path, name, type, size, extract_state)
             VALUES (?1, ?2, ?3, ?4, 'done')",
            params![stored.path, stored.name, stored.mime, stored.size as i64],
        )
        .expect("attachments exists (schema V9)");

    for (title, checked) in [("Checked delete", true), ("Plain delete", false)] {
        let body = format!("Notes\n{}\n", stored.markdown);
        let note = create(&mut vault, title, &body, None);
        let keep = create(&mut vault, &format!("{title} keeper"), &body, None);
        assert_eq!(
            refs(vault.connection_ref(), &note.id),
            vec![(stored.path.clone(), "Notes\n".len())],
            "precondition: {title} references the file"
        );

        if checked {
            let version = get_note(&vault, &note.id).unwrap().version;
            delete_note_checked(&mut vault, &note.id, version, None).unwrap();
        } else {
            delete_note(&mut vault, &note.id).unwrap();
        }
        let conn = vault.connection_ref();
        assert_eq!(
            count(
                conn,
                &format!(
                    "SELECT COUNT(*) FROM note_attachments WHERE note_id = '{}'",
                    note.id
                )
            ),
            0,
            "{title}: the note's rows cascade away"
        );
        assert_eq!(
            refs(conn, &keep.id),
            vec![(stored.path.clone(), "Notes\n".len())],
            "{title}: another note's reference stays"
        );
        assert_eq!(
            count(conn, "SELECT COUNT(*) FROM attachments"),
            1,
            "{title}: the attachments row stays (R6)"
        );
        assert!(
            root.join(&stored.path).is_file(),
            "{title}: the file in objects/ stays (R6)"
        );
    }
}

// ---- AC 7: the rechunk drain writes the same rows ---------------------------------------------

#[test]
fn the_rechunk_drain_writes_the_same_rows_as_reindex_note() {
    let (dir, mut vault) = fresh_vault();
    let root = vault.root().to_path_buf();
    let mock = att("3f", "mock.png");
    let spec = att("9b", "spec ünï.pdf");
    let hidden = att("4a", "hidden.png");
    let footer = att("5b", "footer.pdf");
    let body = format!(
        "---\nsummary: Café\n---\nIntro 🎉\n\n{m}\n{s}\n\n```\n{h}\n```\n\nSee {m} inline.\n{m}\n\n{TOPICS_MARKER}\n{f}\n",
        m = mock.markdown,
        s = spec.markdown,
        h = hidden.markdown,
        f = footer.markdown
    );
    let day_body = format!(
        "Standup\n{}\n\n{TOPICS_MARKER}\n{}\n",
        spec.markdown, footer.markdown
    );

    // Through reindex_note.
    let saved = create(&mut vault, "Saved", "x\n", None);
    save_raw(&mut vault, &saved.id, &body);
    let saved_day = create(&mut vault, "2026-11-17", "x\n", daily_fm());
    save_raw(&mut vault, &saved_day.id, &day_body);
    let by_save = refs(vault.connection_ref(), &saved.id);
    let by_save_day = refs(vault.connection_ref(), &saved_day.id);
    let stored = stored_body(vault.connection_ref(), &saved.id);
    assert_eq!(
        by_save,
        vec![
            (mock.path.clone(), line_start(&stored, &mock.markdown, 0)),
            (spec.path.clone(), line_start(&stored, &spec.markdown, 0)),
            (mock.path.clone(), line_start(&stored, &mock.markdown, 1)),
        ],
        "precondition: reindex_note writes the reference-line rows"
    );
    assert_eq!(by_save_day, vec![(spec.path.clone(), "Standup\n".len())]);

    // Through the drain: the same bodies stored without a reindex, a stale
    // row to replace, and the notes queued.
    let queued = create(&mut vault, "Queued", "x\n", None);
    let queued_day = create(&mut vault, "2026-11-18", "x\n", daily_fm());
    {
        let conn = vault.connection_ref();
        for (id, b) in [(&queued.id, &body), (&queued_day.id, &day_body)] {
            conn.execute(
                "UPDATE notes SET content_md = ?1 WHERE id = ?2",
                params![b, id.as_str()],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?1, ?2, 999)",
                params![id.as_str(), hidden.path],
            )
            .unwrap();
            conn.execute(
                "INSERT OR IGNORE INTO pending_index (note_id, enqueued_at) VALUES (?1, 1)",
                [id.as_str()],
            )
            .unwrap();
        }
    }
    drop(vault);

    let vault = reopen(&root);
    let conn = vault.connection_ref();
    assert_eq!(
        count(conn, "SELECT COUNT(*) FROM pending_index"),
        0,
        "drained"
    );
    assert_eq!(
        refs(conn, &queued.id),
        by_save,
        "the drain writes what reindex_note writes"
    );
    assert_eq!(refs(conn, &queued_day.id), by_save_day, "daily notes too");
    drop(dir);
}
