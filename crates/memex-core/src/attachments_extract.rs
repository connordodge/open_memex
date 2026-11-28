//! Attachment text extraction (Spec #123 R17, R43, R44; TD "Extraction at
//! store time, isolated"; WI #136): the text of a stored attachment and the
//! V9 index rows that hold it.
//!
//! - [`extract`] reads a file's text in this process: PDFs (their text
//!   layer only) and the [`TEXT_EXTENSIONS`] files decoded as UTF-8 with
//!   invalid bytes replaced. Any other type has no text. PDF parsing can
//!   panic or overflow the stack on a hostile file, so neither `memex serve`
//!   nor `memex attach` calls this itself: each runs a child `memex`
//!   process (memex-mcp's `attachment_extract_child`), and only that child
//!   calls it.
//! - [`record`] writes the `attachments` row (`done`, `empty`, or `failed`
//!   with `extract_error`, and `extracted_at`) and the chunks of the first
//!   [`MAX_CHARS`] characters of the text into `attachment_chunks` and
//!   `attachment_chunk_fts`, in one transaction. A path whose row is already
//!   in a final state is never written again (R44: extracted once).
//! - [`is_extracted`] says whether a path already has such a row, so a
//!   store route can skip extraction.
//! - [`cap_data_memory`] (Linux: the kernel's `RLIMIT_DATA`) and
//!   [`limit_memory`] (a peak-resident watchdog, macOS and Linux) are the
//!   extraction child's memory limits.
//!
//! No embeddings here: `embed_model_version` stays NULL (R4's lazy and
//! backfill paths fill the vectors).

use std::fs::File;
use std::io::Read;
use std::panic::{self, AssertUnwindSafe};
use std::path::Path;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use ulid::Ulid;

use crate::attachments::StoredAttachment;
use crate::chunker;
use crate::Result;

/// The most characters (not bytes) of extracted text that are chunked
/// (R43): 200,000.
pub const MAX_CHARS: usize = 200_000;

/// The extensions decoded as UTF-8 text (R43), lowercase, without the dot.
/// Matched in any letter case, like the attachments module's tables.
pub const TEXT_EXTENSIONS: &[&str] = &["txt", "md", "csv", "json"];

/// The extension whose text layer is extracted (R43).
const PDF_EXTENSION: &str = "pdf";

/// The most bytes of a text file (or of a child's output) that can hold
/// [`MAX_CHARS`] characters: four bytes per character at most, plus one
/// partial character at the cut, which decodes past the limit.
pub const MAX_TEXT_BYTES: usize = MAX_CHARS * 4 + 4;

/// The extraction child's memory limit: 1 GiB of peak resident memory.
pub const MEMORY_LIMIT_BYTES: u64 = 1 << 30;

/// The exit status of an extraction child stopped by [`limit_memory`].
pub const MEMORY_LIMIT_EXIT: i32 = 3;

/// How often [`limit_memory`]'s watchdog reads the peak resident memory.
const MEMORY_POLL: Duration = Duration::from_millis(50);

/// What extracting one file gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The file's text. Empty (or only whitespace) when it has none: an
    /// image-only PDF, or a type text isn't extracted from.
    Text(String),
    /// Extraction failed; the message is the row's `extract_error`.
    Failed(String),
}

/// What follows `name`'s last `.`, if it has one.
fn extension(name: &str) -> Option<&str> {
    name.rsplit_once('.').map(|(_, ext)| ext)
}

fn is_pdf(name: &str) -> bool {
    extension(name).is_some_and(|ext| ext.eq_ignore_ascii_case(PDF_EXTENSION))
}

fn is_text_type(name: &str) -> bool {
    extension(name).is_some_and(|ext| TEXT_EXTENSIONS.iter().any(|t| t.eq_ignore_ascii_case(ext)))
}

/// Whether [`extract`] reads any text from a file named `name`: a PDF or a
/// [`TEXT_EXTENSIONS`] file, by extension in any letter case. Any other
/// type has no text, so a store route records it without extracting.
pub fn extracts_text(name: &str) -> bool {
    is_pdf(name) || is_text_type(name)
}

/// The first [`MAX_CHARS`] characters of `text`, cut on a character
/// boundary.
pub fn first_chars(text: &str) -> &str {
    match text.char_indices().nth(MAX_CHARS) {
        Some((at, _)) => &text[..at],
        None => text,
    }
}

/// `bytes` decoded as UTF-8 with invalid sequences replaced (U+FFFD), cut
/// to its first [`MAX_CHARS`] characters.
pub fn decode_text(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    first_chars(&text).to_string()
}

/// The text of the file at `file`, by the type of `name` (its extension, in
/// any case): a PDF's text layer, a [`TEXT_EXTENSIONS`] file decoded as
/// UTF-8 with invalid bytes replaced, or no text for any other type. A PDF
/// that can't be read is [`Outcome::Failed`] with the reason. The text is
/// cut to its first [`MAX_CHARS`] characters.
///
/// Runs in this process: call it only in the extraction child.
pub fn extract(file: &Path, name: &str) -> Outcome {
    if is_pdf(name) {
        extract_pdf(file)
    } else if is_text_type(name) {
        read_text(file)
    } else {
        Outcome::Text(String::new())
    }
}

/// A PDF's text layer. A panic inside the parser is a failure too (a
/// stack overflow still ends the process: hence the child in serve).
fn extract_pdf(file: &Path) -> Outcome {
    match panic::catch_unwind(AssertUnwindSafe(|| pdf_extract::extract_text(file))) {
        Ok(Ok(text)) => Outcome::Text(first_chars(&text).to_string()),
        Ok(Err(e)) => Outcome::Failed(format!("the PDF could not be read: {e}")),
        Err(panic) => {
            let why = panic
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".to_string());
            Outcome::Failed(format!("the PDF could not be read: {why}"))
        }
    }
}

/// A text file's first [`MAX_TEXT_BYTES`] bytes, decoded.
fn read_text(file: &Path) -> Outcome {
    let mut bytes = Vec::new();
    let read = File::open(file).and_then(|f| {
        f.take(MAX_TEXT_BYTES as u64)
            .read_to_end(&mut bytes)
            .map(|_| ())
    });
    match read {
        Ok(()) => Outcome::Text(decode_text(&bytes)),
        Err(e) => Outcome::Failed(format!("the file could not be read: {e}")),
    }
}

/// Whether `path` (an attachment's vault-relative path, the `attachments`
/// key) already has an `attachments` row in a final state (`done`, `empty`
/// or `failed`).
pub fn is_extracted(conn: &Connection, path: &str) -> Result<bool> {
    let found = conn
        .query_row(
            "SELECT 1 FROM attachments
              WHERE path = ? AND extract_state IN ('done', 'empty', 'failed')",
            params![path],
            |_| Ok(()),
        )
        .optional()?;
    Ok(found.is_some())
}

/// Records `outcome` for `stored` in one transaction: its `attachments` row
/// (`name`, `type`, `size` from `stored`; `extract_state` `done` when the
/// text gives at least one chunk, `empty` when it gives none, `failed` with
/// `extract_error` for a failure; `extracted_at = now_ms`) and the chunks of
/// the text's first [`MAX_CHARS`] characters (cut on a character boundary)
/// in `attachment_chunks` and `attachment_chunk_fts`, keyed by
/// `stored.path`.
///
/// When the path already has a row in a final state nothing changes, even
/// under a concurrent record of the same path. Returns whether this call
/// wrote the row.
pub fn record(
    conn: &mut Connection,
    stored: &StoredAttachment,
    outcome: &Outcome,
    now_ms: i64,
) -> Result<bool> {
    let (chunks, error) = match outcome {
        Outcome::Text(text) => (chunker::chunk(first_chars(text)), None),
        Outcome::Failed(why) => (Vec::new(), Some(why.as_str())),
    };
    let state = match (error, chunks.is_empty()) {
        (Some(_), _) => "failed",
        (None, false) => "done",
        (None, true) => "empty",
    };
    // IMMEDIATE takes the write lock before the existence check, so a
    // concurrent record of the same path waits (busy_timeout) and then sees
    // this row, instead of failing to upgrade a read transaction.
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // A `pending` row (never written today) is the only one replaced.
    let wrote = tx.execute(
        "INSERT INTO attachments (path, name, type, size, extract_state, extract_error, extracted_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(path) DO UPDATE SET
             name = excluded.name,
             type = excluded.type,
             size = excluded.size,
             extract_state = excluded.extract_state,
             extract_error = excluded.extract_error,
             extracted_at = excluded.extracted_at
         WHERE attachments.extract_state = 'pending'",
        params![
            stored.path,
            stored.name,
            stored.mime,
            stored.size as i64,
            state,
            error,
            now_ms
        ],
    )?;
    if wrote == 0 {
        return Ok(false);
    }
    for chunk in &chunks {
        let id = Ulid::new().to_string();
        tx.execute(
            "INSERT INTO attachment_chunks (id, path, ord, content, token_count)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, stored.path, chunk.ord, chunk.content, chunk.token_count],
        )?;
        tx.execute(
            "INSERT INTO attachment_chunk_fts (content, chunk_id, path) VALUES (?1, ?2, ?3)",
            params![chunk.content, id, stored.path],
        )?;
    }
    tx.commit()?;
    Ok(true)
}

/// Caps this process's (the extraction child's) data memory at `max_bytes`
/// in the kernel, on Linux only: `setrlimit(RLIMIT_DATA)` lowers the soft
/// limit (never above the hard one), so the kernel refuses any heap or
/// private mapping past it and the allocation failure ends the process
/// (the runner records it as a crash). Linux has counted private writable
/// mappings, not just `brk`, in `RLIMIT_DATA` since 4.7, so it covers what
/// the allocator `mmap`s. On macOS it does nothing: macOS does not apply
/// `RLIMIT_DATA` to `mmap` allocations, so [`limit_memory`]'s watchdog is
/// the only limit there. Returns whether a limit was set.
pub fn cap_data_memory(max_bytes: u64) -> bool {
    if cfg!(target_os = "linux") {
        set_data_rlimit(max_bytes)
    } else {
        false
    }
}

/// Lowers this process's soft `RLIMIT_DATA` to `max_bytes` (or to the hard
/// limit, if that is lower).
fn set_data_rlimit(max_bytes: u64) -> bool {
    let mut limit = std::mem::MaybeUninit::<libc::rlimit>::zeroed();
    // SAFETY: getrlimit writes a whole rlimit into the pointer it is given.
    if unsafe { libc::getrlimit(libc::RLIMIT_DATA, limit.as_mut_ptr()) } != 0 {
        return false;
    }
    // SAFETY: getrlimit returned 0, so it filled it (and zeroed is valid).
    let mut limit = unsafe { limit.assume_init() };
    let wanted = libc::rlim_t::try_from(max_bytes).unwrap_or(libc::RLIM_INFINITY);
    limit.rlim_cur = std::cmp::min(wanted, limit.rlim_max);
    // SAFETY: setrlimit only reads the rlimit it is given.
    unsafe { libc::setrlimit(libc::RLIMIT_DATA, &limit) == 0 }
}

/// Limits this process (the extraction child) to `max_resident` bytes of
/// peak resident memory: a watchdog thread reads the peak (`getrusage`)
/// every 50 ms and, past the limit, prints why on stderr and exits with
/// [`MEMORY_LIMIT_EXIT`]. It works the same on macOS and Linux, but it is a
/// poll: memory touched between two reads can pass the limit before it
/// fires. On Linux [`cap_data_memory`] adds the kernel's limit; on macOS
/// this is the only one (`RLIMIT_AS` and `RLIMIT_DATA` aren't enforced on
/// `mmap` allocations there).
pub fn limit_memory(max_resident: u64) {
    std::thread::spawn(move || loop {
        if peak_resident_bytes().is_some_and(|peak| peak > max_resident) {
            eprintln!(
                "extraction stopped: it used more than {} MB of memory",
                max_resident >> 20
            );
            std::process::exit(MEMORY_LIMIT_EXIT);
        }
        std::thread::sleep(MEMORY_POLL);
    });
}

/// This process's peak resident memory in bytes.
fn peak_resident_bytes() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage writes a whole rusage into the pointer it is given.
    let rc = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if rc != 0 {
        return None;
    }
    // SAFETY: rc == 0, so getrusage filled it (and zeroed is valid anyway).
    let max = unsafe { usage.assume_init() }.ru_maxrss;
    let max = u64::try_from(max).ok()?;
    // ru_maxrss is in bytes on macOS and in KiB on Linux.
    if cfg!(target_os = "macos") {
        Some(max)
    } else {
        Some(max.saturating_mul(1024))
    }
}
