//! WI #136 (Spec #123 R43, R44; TD "Extraction at store time, isolated"):
//! the limits and helpers of `attachments_extract` that the main test file
//! (`attachments_extract.rs`) reaches only through `extract` and `record`.
//!
//! - The 200,000-character cap on a text file, a PDF and the child's output
//!   (`first_chars`, `decode_text`, the byte bound `MAX_TEXT_BYTES`), cut on
//!   a character boundary, with four-byte characters.
//! - `extracts_text`: which names are read (a PDF or `.txt .md .csv .json`,
//!   in any letter case).
//! - `record` replaces a `pending` row and nothing else.
//! - `limit_memory`: the extraction child's watchdog stops its own process
//!   with exit status 3 past the limit, and leaves it alone under it. Tested
//!   in a re-run of this test binary (the watchdog ends its process).
//!
//! Real SQLite, real schema, temp vaults and folders.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use memex_core::attachments::{self, StoredAttachment};
use memex_core::attachments_extract::{
    decode_text, extract, extracts_text, first_chars, is_extracted, limit_memory, record, Outcome,
    MAX_CHARS, MAX_TEXT_BYTES, MEMORY_LIMIT_BYTES, MEMORY_LIMIT_EXIT, TEXT_EXTENSIONS,
};
use memex_core::Vault;
use rusqlite::{params, OptionalExtension};
use tempfile::TempDir;

const NOW: i64 = 1_790_000_000_123;

/// A four-byte character (U+10348).
const FOUR_BYTES: &str = "\u{10348}";

fn tempdir() -> TempDir {
    tempfile::Builder::new()
        .prefix("wi136-limits-")
        .tempdir()
        .unwrap()
}

fn write(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

fn text_of(outcome: Outcome) -> String {
    match outcome {
        Outcome::Text(t) => t,
        Outcome::Failed(e) => panic!("expected text, got Failed({e:?})"),
    }
}

// ---------------------------------------------------------------- constants

#[test]
fn extraction_limit_constants_are_pinned() {
    assert_eq!(MAX_CHARS, 200_000, "R43");
    assert_eq!(TEXT_EXTENSIONS, &["txt", "md", "csv", "json"], "R43");
    assert_eq!(
        MAX_TEXT_BYTES,
        200_000 * 4 + 4,
        "four bytes per character, plus one partial character at the cut"
    );
    assert_eq!(MEMORY_LIMIT_BYTES, 1 << 30, "a 1 GiB memory limit");
    assert_eq!(MEMORY_LIMIT_EXIT, 3, "not clap's usage error (2) or 1");
}

// ---------------------------------------------------------------- first_chars, decode_text

#[test]
fn first_chars_cuts_on_a_character_boundary() {
    let exact = "a".repeat(MAX_CHARS);
    assert_eq!(first_chars(&exact), exact, "200,000 characters are kept");
    let over = format!("{exact}b");
    assert_eq!(first_chars(&over), exact, "the 200,001st is cut");
    assert_eq!(first_chars(""), "");
    assert_eq!(first_chars("short"), "short");

    let two = "\u{e9}".repeat(MAX_CHARS + 1);
    assert_eq!(
        first_chars(&two),
        "\u{e9}".repeat(MAX_CHARS),
        "2-byte chars"
    );
    let four = FOUR_BYTES.repeat(MAX_CHARS + 5);
    let cut = first_chars(&four);
    assert_eq!(cut.chars().count(), MAX_CHARS, "4-byte chars");
    assert_eq!(cut.len(), MAX_CHARS * 4);
    let under = FOUR_BYTES.repeat(MAX_CHARS - 1);
    assert_eq!(first_chars(&under), under, "fewer than the cap: all kept");
}

#[test]
fn decode_text_replaces_invalid_bytes_and_cuts_to_200000_characters() {
    assert_eq!(decode_text(b"a\xffb\xc3\x28c"), "a\u{fffd}b\u{fffd}(c");
    assert_eq!(decode_text(b""), "");
    assert_eq!(decode_text("caf\u{e9}".as_bytes()), "caf\u{e9}");

    let mut bytes = vec![b'x'; MAX_CHARS + 10];
    bytes[3] = 0xff;
    let text = decode_text(&bytes);
    assert_eq!(text.chars().count(), MAX_CHARS);
    assert_eq!(text.chars().nth(3), Some('\u{fffd}'));
}

// ---------------------------------------------------------------- extracts_text

#[test]
fn extracts_text_is_true_for_a_pdf_or_a_text_type_in_any_letter_case() {
    for name in [
        "a.pdf",
        "A.PDF",
        "scan.Pdf",
        "a.txt",
        "a.TXT",
        "README.md",
        "README.MD",
        "t.csv",
        "t.CSV",
        "d.json",
        "d.Json",
        "two.parts.pdf",
        "report v2.txt",
    ] {
        assert!(extracts_text(name), "{name} has text");
    }
    for name in [
        "photo.png",
        "bundle.zip",
        "archive.tar.gz",
        "notes.txt.bak",
        "Makefile",
        "pdf",
        "txt",
        "notes.txt ",
        "slides.pptx",
        "doc.docx",
        "page.html",
        "x.markdown",
        "",
    ] {
        assert!(!extracts_text(name), "{name} has no text");
    }
}

// ---------------------------------------------------------------- the cap on a file

#[test]
fn a_text_file_is_cut_to_its_first_200000_characters_of_four_byte_characters() {
    let dir = tempdir();
    let file = write(
        dir.path(),
        "big.txt",
        FOUR_BYTES.repeat(MAX_CHARS + 50_000).as_bytes(),
    );
    let text = text_of(extract(&file, "big.txt"));
    assert_eq!(text, FOUR_BYTES.repeat(MAX_CHARS));
}

#[test]
fn a_text_file_with_a_leading_ascii_byte_keeps_its_first_200000_characters_whole() {
    // One ASCII byte first, so every four-byte character is offset by one:
    // the byte bound must still hold 200,000 characters and no half one.
    let dir = tempdir();
    let body = format!("a{}", FOUR_BYTES.repeat(MAX_CHARS + 50_000));
    let file = write(dir.path(), "straddle.md", body.as_bytes());
    let text = text_of(extract(&file, "straddle.md"));
    assert_eq!(text.chars().count(), MAX_CHARS);
    assert_eq!(text, format!("a{}", FOUR_BYTES.repeat(MAX_CHARS - 1)));
    assert!(!text.contains('\u{fffd}'), "no half character at the cut");
}

#[test]
fn a_text_file_under_the_cap_is_read_whole() {
    let dir = tempdir();
    let body = format!("{}end", FOUR_BYTES.repeat(1_000));
    let file = write(dir.path(), "small.json", body.as_bytes());
    assert_eq!(text_of(extract(&file, "small.json")), body);
}

#[test]
fn a_text_file_that_cannot_be_read_fails_with_a_reason() {
    let dir = tempdir();
    let outcome = extract(&dir.path().join("missing.txt"), "missing.txt");
    assert!(
        matches!(&outcome, Outcome::Failed(e) if e.contains("could not be read")),
        "{outcome:?}"
    );
}

/// A one-page PDF whose text layer holds `lines` (each a short string
/// without parentheses), with a correct cross-reference table.
fn pdf_with_lines(lines: &[String]) -> Vec<u8> {
    let mut content = String::new();
    for line in lines {
        content.push_str(&format!("BT /F1 8 Tf 10 700 Td ({line}) Tj ET\n"));
    }
    let objects: Vec<String> = vec![
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R \
         /Resources << /Font << /F1 5 0 R >> >> >>"
            .to_string(),
        format!(
            "<< /Length {} >>\nstream\n{content}\nendstream",
            content.len()
        ),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
            .to_string(),
    ];
    let mut out = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, body) in objects.iter().enumerate() {
        offsets.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n{body}\nendobj\n", i + 1).as_bytes());
    }
    let xref = out.len();
    out.extend_from_slice(
        format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes(),
    );
    for off in offsets {
        out.extend_from_slice(format!("{off:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    out
}

#[test]
fn a_pdf_with_more_than_200000_characters_of_text_is_cut_to_200000() {
    let dir = tempdir();
    // 6,000 lines of 50 characters: about 300,000 characters of text.
    let lines: Vec<String> = (0..6_000)
        .map(|i| format!("line{i:05} walrus tundra ledger entries recorded here"))
        .collect();
    let file = write(dir.path(), "long.pdf", &pdf_with_lines(&lines));
    let text = text_of(extract(&file, "long.pdf"));
    assert_eq!(text.chars().count(), MAX_CHARS, "cut at 200,000 characters");
    assert!(text.contains("line00000"), "the start is kept");
    assert!(
        !text.contains("line05999"),
        "the end is cut: {:?}",
        &text[text.len().saturating_sub(60)..]
    );

    let short = write(
        dir.path(),
        "short.pdf",
        &pdf_with_lines(&["only one short line".to_string()]),
    );
    let text = text_of(extract(&short, "short.pdf"));
    assert!(text.contains("only one short line"), "{text:?}");
    assert!(text.chars().count() < 100, "a short PDF is not padded");
}

// ---------------------------------------------------------------- record and a pending row

fn vault() -> (TempDir, PathBuf, Vault) {
    let dir = tempdir();
    let path = dir.path().join("vault");
    let v = Vault::create(&path).unwrap();
    (dir, path, v)
}

fn store(vault: &Path, bytes: &[u8], name: &str) -> StoredAttachment {
    attachments::store_bytes(vault, bytes, name).unwrap()
}

type StateRow = (String, String, String, i64, Option<String>, Option<i64>);

fn state_row(v: &Vault, path: &str) -> Option<StateRow> {
    v.connection_ref()
        .query_row(
            "SELECT name, type, extract_state, size, extract_error, extracted_at
               FROM attachments WHERE path = ?",
            params![path],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .optional()
        .unwrap()
}

#[test]
fn record_replaces_a_pending_row_once() {
    let (_dir, path, mut v) = vault();
    let stored = store(&path, b"zebra ledger words", "ledger.txt");
    v.connection_ref()
        .execute(
            "INSERT INTO attachments (path, name, type, size, extract_state)
             VALUES (?1, 'stale name', 'text/x-stale', 1, 'pending')",
            params![stored.path],
        )
        .unwrap();
    assert!(
        !is_extracted(v.connection_ref(), &stored.path).unwrap(),
        "a pending row is not extracted yet"
    );

    let text = Outcome::Text("zebra ledger words".to_string());
    assert!(
        record(v.connection_mut(), &stored, &text, NOW).unwrap(),
        "a pending row is replaced"
    );
    assert_eq!(
        state_row(&v, &stored.path),
        Some((
            "ledger.txt".to_string(),
            "text/plain".to_string(),
            "done".to_string(),
            stored.size as i64,
            None,
            Some(NOW),
        ))
    );
    let chunks: i64 = v
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM attachment_chunks WHERE path = ?",
            params![stored.path],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(chunks, 1);
    assert!(is_extracted(v.connection_ref(), &stored.path).unwrap());

    // The replaced row is final now.
    let failed = Outcome::Failed("late".to_string());
    assert!(!record(v.connection_mut(), &stored, &failed, NOW + 1).unwrap());
    assert_eq!(state_row(&v, &stored.path).unwrap().2, "done");
}

// ---------------------------------------------------------------- limit_memory

/// Set in the re-run of this test binary: what the helper test does.
const CHILD_MODE: &str = "WI136_LIMIT_MEMORY_MODE";

/// Not a test of its own: the body the tests below re-run in a child
/// process (`WI136_LIMIT_MEMORY_MODE` unset: it does nothing).
#[test]
fn limit_memory_child_body() {
    let Ok(mode) = std::env::var(CHILD_MODE) else {
        return;
    };
    match mode.as_str() {
        // A 1 MiB limit is far below this process's resident memory.
        "over" => {
            limit_memory(1 << 20);
            // The watchdog ends this process within a few polls; the loop
            // is only a bound for a watchdog that never fires.
            for _ in 0..200 {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        // A 512 MiB limit is far above it.
        "under" => {
            limit_memory(512 << 20);
            for _ in 0..12 {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        other => panic!("unknown mode {other}"),
    }
}

fn run_child_body(mode: &str) -> std::process::Output {
    Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "limit_memory_child_body",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_MODE, mode)
        .stdin(Stdio::null())
        .output()
        .expect("re-run the test binary")
}

#[test]
fn limit_memory_stops_a_process_past_the_limit_with_exit_3_and_says_why() {
    let out = run_child_body("over");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(MEMORY_LIMIT_EXIT),
        "past the limit the process exits with 3: {stderr}"
    );
    assert!(
        stderr.contains("extraction stopped: it used more than 1 MB of memory"),
        "the reason names the limit in MB: {stderr}"
    );
}

#[test]
fn limit_memory_leaves_a_process_under_the_limit_running() {
    let out = run_child_body("under");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(0),
        "under the limit nothing stops it: {stderr}"
    );
    assert!(!stderr.contains("extraction stopped"), "{stderr}");
}
