//! WI #136 (Spec #123 R17, R43, R44; TD "Extraction at store time,
//! isolated"): attachment text extraction and the V9 rows it writes.
//!
//! - `extract`: a PDF's text layer; `.txt .md .csv .json` (any letter case)
//!   decoded as UTF-8 with invalid bytes replaced; no text for any other
//!   type; a PDF that can't be read fails with a reason.
//! - `record`: one `attachments` row per stored file (`done` with chunks,
//!   `empty` without, `failed` with `extract_error`; `extracted_at` the
//!   given clock), and the chunks of the first 200,000 characters of the
//!   text in `attachment_chunks` and `attachment_chunk_fts` under the
//!   attachment's path. A path already in a final state is never written
//!   again, even by a concurrent record.
//!
//! The PDFs and the invalid UTF-8 file in `tests/fixtures/attachments/` are
//! made by its `generate.py`. Real SQLite, real schema, temp vaults.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Barrier};

use memex_core::attachments::{self, StoredAttachment};
use memex_core::attachments_extract::{
    extract, is_extracted, record, Outcome, MAX_CHARS, TEXT_EXTENSIONS,
};
use memex_core::chunker;
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote};
use memex_core::{Caller, Vault};
use rusqlite::{params, Connection, OptionalExtension};
use tempfile::TempDir;

/// The clock every record here is given.
const NOW: i64 = 1_790_000_000_123;
/// A later clock, for records that must change nothing.
const LATER: i64 = 1_790_000_999_999;

/// The words of the text-layer fixture (generate.py's TITLE and LINE).
const PDF_TITLE: &str = "Quarterly zebra migration report";
const PDF_LINE: &str = "Striped kelp forests drift north";

// ---------------------------------------------------------------- harness

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/attachments")
        .join(name)
}

fn fixture_bytes(name: &str) -> Vec<u8> {
    std::fs::read(fixture(name)).unwrap_or_else(|e| panic!("read fixture {name}: {e}"))
}

/// A fresh vault at `<tmp>/vault`.
fn vault() -> (TempDir, PathBuf, Vault) {
    let dir = tempfile::Builder::new()
        .prefix("wi136-core-")
        .tempdir()
        .unwrap();
    let path = dir.path().join("vault");
    let v = Vault::create(&path).unwrap();
    (dir, path, v)
}

/// Stores `bytes` as `name` (test setup: the store itself is #134's).
fn store(vault: &Path, bytes: &[u8], name: &str) -> StoredAttachment {
    attachments::store_bytes(vault, bytes, name).unwrap()
}

/// The stored file's absolute path.
fn file_of(vault: &Path, stored: &StoredAttachment) -> PathBuf {
    vault.join(&stored.path)
}

#[derive(Debug, PartialEq)]
struct Row {
    name: String,
    mime: String,
    size: i64,
    state: String,
    error: Option<String>,
    extracted_at: Option<i64>,
}

fn row(conn: &Connection, path: &str) -> Option<Row> {
    conn.query_row(
        "SELECT name, type, size, extract_state, extract_error, extracted_at
           FROM attachments WHERE path = ?",
        params![path],
        |r| {
            Ok(Row {
                name: r.get(0)?,
                mime: r.get(1)?,
                size: r.get(2)?,
                state: r.get(3)?,
                error: r.get(4)?,
                extracted_at: r.get(5)?,
            })
        },
    )
    .optional()
    .unwrap()
}

fn row_count(conn: &Connection) -> i64 {
    conn.query_row("SELECT COUNT(*) FROM attachments", [], |r| r.get(0))
        .unwrap()
}

#[derive(Debug, Clone, PartialEq)]
struct ChunkRow {
    id: String,
    ord: i64,
    content: String,
    token_count: i64,
    embed_model_version: Option<String>,
}

/// The `attachment_chunks` rows of `path`, by `ord`.
fn chunks(conn: &Connection, path: &str) -> Vec<ChunkRow> {
    let mut stmt = conn
        .prepare(
            "SELECT id, ord, content, token_count, embed_model_version
               FROM attachment_chunks WHERE path = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map(params![path], |r| {
        Ok(ChunkRow {
            id: r.get(0)?,
            ord: r.get(1)?,
            content: r.get(2)?,
            token_count: r.get(3)?,
            embed_model_version: r.get(4)?,
        })
    })
    .unwrap()
    .map(Result::unwrap)
    .collect()
}

fn all_chunk_count(conn: &Connection) -> i64 {
    conn.query_row("SELECT COUNT(*) FROM attachment_chunks", [], |r| r.get(0))
        .unwrap()
}

/// The `attachment_chunk_fts` rows of `path` as (chunk_id, content), by
/// chunk id.
fn fts_rows(conn: &Connection, path: &str) -> Vec<(String, String)> {
    let mut stmt = conn
        .prepare(
            "SELECT chunk_id, content FROM attachment_chunk_fts WHERE path = ? ORDER BY chunk_id",
        )
        .unwrap();
    stmt.query_map(params![path], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

fn all_fts_count(conn: &Connection) -> i64 {
    conn.query_row("SELECT COUNT(*) FROM attachment_chunk_fts", [], |r| {
        r.get(0)
    })
    .unwrap()
}

/// The paths whose FTS rows match `query`.
fn fts_match(conn: &Connection, query: &str) -> Vec<String> {
    let mut stmt = conn
        .prepare("SELECT path FROM attachment_chunk_fts WHERE attachment_chunk_fts MATCH ?")
        .unwrap();
    stmt.query_map(params![query], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// The text of a `Text` outcome; panics on `Failed`.
fn text_of(outcome: &Outcome) -> &str {
    match outcome {
        Outcome::Text(t) => t,
        Outcome::Failed(e) => panic!("expected text, got Failed({e:?})"),
    }
}

/// Asserts the chunk rows of `path` are exactly `chunker::chunk(text)`
/// (ord, content, token count), with unique ids, NULL embed versions, and
/// one FTS row per chunk holding the same id, content and path.
fn assert_chunks_are(conn: &Connection, path: &str, text: &str) {
    let want = chunker::chunk(text);
    let got = chunks(conn, path);
    assert_eq!(
        got.len(),
        want.len(),
        "chunk count of {path}: got {} want {}",
        got.len(),
        want.len()
    );
    for (g, w) in got.iter().zip(&want) {
        assert_eq!(g.ord, w.ord, "ord");
        assert_eq!(g.content, w.content, "content of chunk {}", w.ord);
        assert_eq!(
            g.token_count, w.token_count,
            "token_count of chunk {}",
            w.ord
        );
        assert_eq!(g.embed_model_version, None, "no embeddings here (R4)");
    }
    let mut ids: Vec<&str> = got.iter().map(|c| c.id.as_str()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), got.len(), "chunk ids are unique: {got:?}");
    let mut want_fts: Vec<(String, String)> = got
        .iter()
        .map(|c| (c.id.clone(), c.content.clone()))
        .collect();
    want_fts.sort();
    assert_eq!(fts_rows(conn, path), want_fts, "FTS mirrors the chunks");
}

/// `n` characters: sentences with two 2-byte characters each, so a cut by
/// bytes and a cut by characters land in different places.
fn sentences(n: usize) -> String {
    const SENTENCE: &str = "Naïve café walruses graze slowly. ";
    let mut s = String::new();
    let mut chars = 0;
    let len = SENTENCE.chars().count();
    while chars + len <= n {
        s.push_str(SENTENCE);
        chars += len;
    }
    s.push_str(&" ".repeat(n - chars));
    s
}

// ---------------------------------------------------------------- core values

#[test]
fn extraction_limits_and_text_types_are_pinned() {
    assert_eq!(MAX_CHARS, 200_000, "R43: the first 200,000 characters");
    assert_eq!(TEXT_EXTENSIONS, &["txt", "md", "csv", "json"], "R43");
}

// ---------------------------------------------------------------- AC 1: text-layer PDF

#[test]
fn text_layer_pdf_records_done_with_its_text_in_chunks_and_fts() {
    let (_dir, path, mut v) = vault();
    let stored = store(&path, &fixture_bytes("text-layer.pdf"), "Q3 report.pdf");

    let outcome = extract(&file_of(&path, &stored), &stored.name);
    let text = text_of(&outcome).to_string();
    assert!(text.contains(PDF_TITLE), "text layer: {text:?}");
    assert!(text.contains(PDF_LINE), "text layer: {text:?}");

    assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
    let conn = v.connection_ref();
    assert_eq!(
        row(conn, &stored.path),
        Some(Row {
            name: stored.name.clone(),
            mime: "application/pdf".to_string(),
            size: stored.size as i64,
            state: "done".to_string(),
            error: None,
            extracted_at: Some(NOW),
        })
    );
    assert_chunks_are(conn, &stored.path, &text);
    assert_eq!(fts_match(conn, "zebra"), vec![stored.path.clone()]);
    assert_eq!(fts_match(conn, "kelp"), vec![stored.path.clone()]);
}

#[test]
fn pdf_extension_is_matched_in_any_case() {
    let (_dir, path, _v) = vault();
    let stored = store(&path, &fixture_bytes("text-layer.pdf"), "SCAN.PDF");
    let outcome = extract(&file_of(&path, &stored), &stored.name);
    assert!(
        text_of(&outcome).contains(PDF_TITLE),
        "an upper-case .PDF is still a PDF: {outcome:?}"
    );
}

// ---------------------------------------------------------------- AC 2: image-only and corrupt PDFs

#[test]
fn image_only_pdf_records_empty_with_no_chunks_and_keeps_the_file() {
    let (_dir, path, mut v) = vault();
    let bytes = fixture_bytes("image-only.pdf");
    let stored = store(&path, &bytes, "scan.pdf");

    let outcome = extract(&file_of(&path, &stored), &stored.name);
    assert!(
        text_of(&outcome).trim().is_empty(),
        "an image-only PDF has no text: {outcome:?}"
    );
    assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());

    let conn = v.connection_ref();
    let r = row(conn, &stored.path).expect("the attachments row exists");
    assert_eq!(r.state, "empty");
    assert_eq!(r.error, None);
    assert_eq!(r.extracted_at, Some(NOW));
    assert_eq!(r.size, bytes.len() as i64);
    assert!(chunks(conn, &stored.path).is_empty());
    assert!(fts_rows(conn, &stored.path).is_empty());
    assert_eq!(std::fs::read(file_of(&path, &stored)).unwrap(), bytes);
}

#[test]
fn whitespace_only_text_records_empty() {
    let (_dir, path, mut v) = vault();
    let stored = store(&path, b"   \n\n \t\n", "blank.txt");
    let outcome = Outcome::Text("   \n\n \t\n".to_string());
    assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
    let conn = v.connection_ref();
    assert_eq!(row(conn, &stored.path).unwrap().state, "empty");
    assert!(chunks(conn, &stored.path).is_empty());
}

#[test]
fn corrupt_pdf_records_failed_with_an_extract_error_and_keeps_the_file() {
    let (_dir, path, mut v) = vault();
    let bytes = fixture_bytes("corrupt.pdf");
    let stored = store(&path, &bytes, "broken.pdf");

    let outcome = extract(&file_of(&path, &stored), &stored.name);
    let Outcome::Failed(reason) = &outcome else {
        panic!("a corrupt PDF fails: {outcome:?}");
    };
    assert!(!reason.trim().is_empty(), "the failure has a reason");

    assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
    let conn = v.connection_ref();
    let r = row(conn, &stored.path).expect("the attachments row exists");
    assert_eq!(r.state, "failed");
    assert_eq!(r.error.as_deref(), Some(reason.as_str()));
    assert_eq!(r.extracted_at, Some(NOW));
    assert_eq!(r.name, "broken.pdf");
    assert!(chunks(conn, &stored.path).is_empty());
    assert_eq!(std::fs::read(file_of(&path, &stored)).unwrap(), bytes);
}

#[test]
fn a_failed_outcome_records_its_message_as_extract_error() {
    let (_dir, path, mut v) = vault();
    let stored = store(&path, b"%PDF-1.4 whatever", "child.pdf");
    let outcome = Outcome::Failed("extraction timed out after 20 s".to_string());
    assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
    let r = row(v.connection_ref(), &stored.path).unwrap();
    assert_eq!(r.state, "failed");
    assert_eq!(r.error.as_deref(), Some("extraction timed out after 20 s"));
    assert_eq!(r.extracted_at, Some(NOW));
    assert!(chunks(v.connection_ref(), &stored.path).is_empty());
}

// ---------------------------------------------------------------- AC 3: text types and other types

#[test]
fn text_types_are_decoded_as_utf8_with_invalid_bytes_replaced() {
    let bytes = fixture_bytes("invalid-utf8.txt");
    assert!(
        std::str::from_utf8(&bytes).is_err(),
        "fixture is invalid UTF-8"
    );
    let want = String::from_utf8_lossy(&bytes).into_owned();
    assert_eq!(
        want.matches('\u{FFFD}').count(),
        3,
        "three invalid sequences"
    );
    assert!(want.contains("walrus café"), "valid UTF-8 is kept");

    for name in ["notes.txt", "README.MD", "table.Csv", "data.JSON", "x.md"] {
        let (_dir, path, mut v) = vault();
        let stored = store(&path, &bytes, name);
        let outcome = extract(&file_of(&path, &stored), &stored.name);
        assert_eq!(outcome, Outcome::Text(want.clone()), "{name}");

        assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
        let conn = v.connection_ref();
        assert_eq!(row(conn, &stored.path).unwrap().state, "done", "{name}");
        assert_chunks_are(conn, &stored.path, &want);
        assert_eq!(
            fts_match(conn, "tundra"),
            vec![stored.path.clone()],
            "{name}"
        );
    }
}

#[test]
fn other_types_get_an_attachments_row_with_no_chunks() {
    // Valid UTF-8 words in every file: only the type decides.
    let bytes = b"zebra walrus tundra ledger words".to_vec();
    for name in [
        "photo.png",
        "bundle.zip",
        "archive.tar.gz",
        "notes.txt.bak",
        "Makefile",
        "slides.pptx",
    ] {
        let (_dir, path, mut v) = vault();
        let stored = store(&path, &bytes, name);
        let outcome = extract(&file_of(&path, &stored), &stored.name);
        assert!(
            matches!(&outcome, Outcome::Text(t) if t.trim().is_empty()),
            "{name} has no text: {outcome:?}"
        );
        assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
        let conn = v.connection_ref();
        let r = row(conn, &stored.path).unwrap_or_else(|| panic!("{name}: a row"));
        assert_eq!(r.state, "empty", "{name}");
        assert_eq!(r.error, None, "{name}");
        assert_eq!(r.mime, attachments::mime_for(name), "{name}");
        assert!(chunks(conn, &stored.path).is_empty(), "{name}");
        assert!(fts_match(conn, "zebra").is_empty(), "{name}");
    }
}

// ---------------------------------------------------------------- AC 4: the 200,000-character cap

#[test]
fn only_the_first_200000_characters_are_chunked() {
    let (_dir, path, mut v) = vault();
    let kept_end = "keptmarkeré";
    let head = format!(
        "{}{kept_end}",
        sentences(200_000 - kept_end.chars().count())
    );
    assert_eq!(head.chars().count(), 200_000);
    assert!(head.len() > 200_000 + 10_000, "the cut by bytes differs");
    let text = format!("{head}Z droppedmarker tail. {}", sentences(5_000));
    let stored = store(&path, text.as_bytes(), "long.txt");

    let outcome = Outcome::Text(text.clone());
    assert!(record(v.connection_mut(), &stored, &outcome, NOW).unwrap());
    let conn = v.connection_ref();
    assert_eq!(row(conn, &stored.path).unwrap().state, "done");
    let got = chunks(conn, &stored.path);
    let last = got.last().expect("chunks");
    assert!(
        last.content.ends_with(kept_end),
        "the last chunk ends at character 200,000: …{:?}",
        last.content
            .chars()
            .rev()
            .take(30)
            .collect::<String>()
            .chars()
            .rev()
            .collect::<String>()
    );
    for c in &got {
        assert!(!c.content.contains("droppedmarker"), "chunk {}", c.ord);
        assert!(!c.content.contains('Z'), "chunk {}", c.ord);
    }
    assert!(fts_match(conn, "droppedmarker").is_empty());
    assert_eq!(fts_match(conn, "keptmarkeré"), vec![stored.path.clone()]);
    assert_chunks_are(conn, &stored.path, &head);
}

#[test]
fn text_of_exactly_200000_characters_is_chunked_whole() {
    let (_dir, path, mut v) = vault();
    let end = "lastcharmarkeré";
    let text = format!("{}{end}", sentences(200_000 - end.chars().count()));
    assert_eq!(text.chars().count(), 200_000);
    let stored = store(&path, text.as_bytes(), "exact.md");
    assert!(record(
        v.connection_mut(),
        &stored,
        &Outcome::Text(text.clone()),
        NOW
    )
    .unwrap());
    let conn = v.connection_ref();
    assert_chunks_are(conn, &stored.path, &text);
    assert!(chunks(conn, &stored.path)
        .last()
        .unwrap()
        .content
        .ends_with(end));
}

#[test]
fn a_multi_chunk_text_is_stored_as_the_chunker_chunks_with_unique_ids() {
    let (_dir, path, mut v) = vault();
    let para = "Walrus herds migrate along the tundra coast every spring. ".repeat(40);
    let text = format!("# Field notes\n\n{para}\n\n{para}\n\n{para}\n\nTail paragraph.");
    assert!(
        chunker::chunk(&text).len() >= 3,
        "precondition: several chunks"
    );
    let stored = store(&path, text.as_bytes(), "field.md");
    assert!(record(
        v.connection_mut(),
        &stored,
        &Outcome::Text(text.clone()),
        NOW
    )
    .unwrap());
    assert_chunks_are(v.connection_ref(), &stored.path, &text);
}

#[test]
fn chunk_ids_are_unique_across_attachments() {
    let (_dir, path, mut v) = vault();
    let a = store(&path, b"alpha zebra words", "a.txt");
    let b = store(&path, b"beta kelp words", "b.txt");
    for s in [&a, &b] {
        let text = String::from_utf8(std::fs::read(file_of(&path, s)).unwrap()).unwrap();
        assert!(record(v.connection_mut(), s, &Outcome::Text(text), NOW).unwrap());
    }
    let conn = v.connection_ref();
    let ca = chunks(conn, &a.path);
    let cb = chunks(conn, &b.path);
    assert_eq!((ca.len(), cb.len()), (1, 1));
    assert_ne!(ca[0].id, cb[0].id, "ord 0 of two paths has two ids");
    assert_eq!(fts_match(conn, "zebra"), vec![a.path.clone()]);
    assert_eq!(fts_match(conn, "kelp"), vec![b.path.clone()]);
}

// ---------------------------------------------------------------- AC 6: extracted once

#[test]
fn is_extracted_is_true_only_once_a_final_state_is_recorded() {
    let (_dir, path, mut v) = vault();
    let outcomes = [
        ("done.txt", Outcome::Text("zebra words".to_string())),
        ("empty.png", Outcome::Text(String::new())),
        ("failed.pdf", Outcome::Failed("boom".to_string())),
    ];
    for (name, outcome) in &outcomes {
        let stored = store(&path, name.as_bytes(), name);
        assert!(
            !is_extracted(v.connection_ref(), &stored.path).unwrap(),
            "{name} before"
        );
        assert!(record(v.connection_mut(), &stored, outcome, NOW).unwrap());
        assert!(
            is_extracted(v.connection_ref(), &stored.path).unwrap(),
            "{name} after"
        );
    }
    assert!(!is_extracted(v.connection_ref(), "objects/ab/never/stored.txt").unwrap());
}

#[test]
fn recording_a_path_again_changes_nothing() {
    let (_dir, path, mut v) = vault();
    let text = "Walrus ledger tundra report.".to_string();
    let stored = store(&path, text.as_bytes(), "ledger.txt");
    assert!(record(
        v.connection_mut(),
        &stored,
        &Outcome::Text(text.clone()),
        NOW
    )
    .unwrap());
    let before_row = row(v.connection_ref(), &stored.path).unwrap();
    let before_chunks = chunks(v.connection_ref(), &stored.path);
    assert_eq!(before_row.extracted_at, Some(NOW));

    for again in [
        Outcome::Text(text.clone()),
        Outcome::Text("different words entirely".to_string()),
        Outcome::Failed("would fail now".to_string()),
        Outcome::Text(String::new()),
    ] {
        let wrote = record(v.connection_mut(), &stored, &again, LATER).unwrap();
        assert!(!wrote, "{again:?} wrote over a final row");
        let conn = v.connection_ref();
        assert_eq!(row(conn, &stored.path).unwrap(), before_row, "{again:?}");
        assert_eq!(chunks(conn, &stored.path), before_chunks, "{again:?}");
        assert_eq!(all_chunk_count(conn), before_chunks.len() as i64);
        assert_eq!(all_fts_count(conn), before_chunks.len() as i64);
        assert_eq!(row_count(conn), 1);
    }
}

#[test]
fn two_concurrent_records_of_one_path_write_one_set_of_chunks() {
    let (_dir, path, v) = vault();
    let para = "Walrus herds migrate along the tundra coast every spring. ".repeat(40);
    let text = format!("{para}\n\n{para}\n\n{para}");
    let stored = store(&path, text.as_bytes(), "race.txt");
    let want = chunker::chunk(&text).len() as i64;
    assert!(want >= 2, "precondition: several chunks");

    for round in 0..8 {
        // A fresh name each round, so every round races on a new path.
        let stored = store(&path, text.as_bytes(), &format!("race-{round}.txt"));
        let barrier = Arc::new(Barrier::new(2));
        let handles: Vec<_> = [NOW, LATER]
            .into_iter()
            .map(|now| {
                let barrier = barrier.clone();
                let path = path.clone();
                let stored = stored.clone();
                let text = text.clone();
                std::thread::spawn(move || {
                    let mut v = Vault::open(&path).unwrap();
                    barrier.wait();
                    record(v.connection_mut(), &stored, &Outcome::Text(text), now)
                })
            })
            .collect();
        let wrote: Vec<bool> = handles
            .into_iter()
            .map(|h| {
                h.join()
                    .expect("record thread")
                    .expect("a concurrent record never errors")
            })
            .collect();
        assert_eq!(
            wrote.iter().filter(|w| **w).count(),
            1,
            "round {round}: exactly one record wrote: {wrote:?}"
        );
        let conn = v.connection_ref();
        assert_eq!(
            chunks(conn, &stored.path).len() as i64,
            want,
            "round {round}"
        );
        assert_eq!(
            fts_rows(conn, &stored.path).len() as i64,
            want,
            "round {round}"
        );
        assert_chunks_are(conn, &stored.path, &text);
    }
    // The first stored path was never recorded.
    assert!(row(v.connection_ref(), &stored.path).is_none());
}

// ---------------------------------------------------------------- AC 7: a note save never extracts

#[test]
fn a_note_save_that_references_a_stored_file_writes_no_attachments_row() {
    let (_dir, path, mut v) = vault();
    let stored = store(&path, b"zebra ledger text", "ref.txt");
    let body = format!("See this:\n\n{}\n", stored.markdown);
    let note = create_note_as(
        &mut v,
        CreateNote {
            title: Some("Refers".into()),
            content_md: body.clone(),
            frontmatter: None,
        },
        Caller::Person,
    )
    .unwrap();
    // The save's index step (what `memex add`, the MCP tools and the
    // server run after a write).
    indexer::reindex_note(v.connection_mut(), note.id.as_str(), &body, None).unwrap();
    let conn = v.connection_ref();
    let refs: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM note_attachments WHERE path = ?",
            params![stored.path],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(refs, 1, "the save indexed the reference (#135)");
    assert!(
        row(conn, &stored.path).is_none(),
        "the save extracted nothing"
    );
    assert_eq!(all_chunk_count(conn), 0);
}
