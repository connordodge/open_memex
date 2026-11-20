//! Attachment text extraction (Spec #123 R17, R43, R44; TD "Extraction at
//! store time, isolated"; WI #136): the text of a stored attachment and the
//! V9 index rows that hold it.
//!
//! - [`extract`] reads a file's text in this process: PDFs (their text
//!   layer only) and the [`TEXT_EXTENSIONS`] files decoded as UTF-8 with
//!   invalid bytes replaced. Any other type has no text. PDF parsing can
//!   panic or overflow the stack on a hostile file, so `memex serve` never
//!   calls this itself: it runs a child `memex` process (memex-mcp's
//!   `attachment_extract_child`). A one-shot `memex attach` may.
//! - [`record`] writes the `attachments` row (`done`, `empty`, or `failed`
//!   with `extract_error`, and `extracted_at`) and the chunks of the first
//!   [`MAX_CHARS`] characters of the text into `attachment_chunks` and
//!   `attachment_chunk_fts`, in one transaction. A path whose row is already
//!   in a final state is never written again (R44: extracted once).
//! - [`is_extracted`] says whether a path already has such a row, so a
//!   store route can skip extraction.
//!
//! No embeddings here: `embed_model_version` stays NULL (R4's lazy and
//! backfill paths fill the vectors).

use std::path::Path;

use rusqlite::Connection;

use crate::attachments::StoredAttachment;
use crate::Result;

/// The most characters (not bytes) of extracted text that are chunked
/// (R43): 200,000.
pub const MAX_CHARS: usize = 0;

/// The extensions decoded as UTF-8 text (R43), lowercase, without the dot.
/// Matched in any letter case, like the attachments module's tables.
pub const TEXT_EXTENSIONS: &[&str] = &[];

/// What extracting one file gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The file's text. Empty (or only whitespace) when it has none: an
    /// image-only PDF, or a type text isn't extracted from.
    Text(String),
    /// Extraction failed; the message is the row's `extract_error`.
    Failed(String),
}

/// The text of the file at `file`, by the type of `name` (its extension, in
/// any case): a PDF's text layer, a [`TEXT_EXTENSIONS`] file decoded as
/// UTF-8 with invalid bytes replaced, or no text for any other type. A PDF
/// that can't be read is [`Outcome::Failed`] with the reason.
///
/// Runs in this process: never call it inside `memex serve`.
pub fn extract(_file: &Path, _name: &str) -> Outcome {
    Outcome::Text(String::new())
}

/// Whether `path` (an attachment's vault-relative path, the `attachments`
/// key) already has an `attachments` row in a final state (`done`, `empty`
/// or `failed`).
pub fn is_extracted(_conn: &Connection, _path: &str) -> Result<bool> {
    Ok(false)
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
    _conn: &mut Connection,
    _stored: &StoredAttachment,
    _outcome: &Outcome,
    _now_ms: i64,
) -> Result<bool> {
    Ok(false)
}
