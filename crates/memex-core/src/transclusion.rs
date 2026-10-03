//! Transclusion: parsing and rendering embedded blocks.
//!
//! Parsing lives beside wikilink parsing in `link_extractor` (D13) and is
//! re-exported here; rendering resolves a token to the live text of its
//! blocks, or to the stub `removed from <date>` (CONTRACTS C4).

use rusqlite::{params, Connection, OptionalExtension};

pub use crate::link_extractor::{parse_transclusions, TransclusionToken};
use crate::links::daily_note_id_for_title;
use crate::Result;

/// A transclusion token resolved against the vault.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedExcerpt {
    pub date: String,
    pub from: String,
    pub to: Option<String>,
    /// The blocks' text joined with `\n`, or `removed from <date>`.
    pub text: String,
    /// `true` when the daily note or an endpoint block is gone.
    pub removed: bool,
}

/// Renders one token by the C4 render rule.
///
/// The date resolves only to the `role: daily` note with that title, and the
/// block ids resolve only within that note. When the note and both endpoint
/// blocks exist, the text is every block of the note with
/// `min(from.ord, to.ord) <= ord <= max(from.ord, to.ord)`, in ord order,
/// joined with `\n`. Otherwise it is the stub `removed from <date>` with
/// `removed: true`. Only a database error is an `Err`.
pub fn render(conn: &Connection, token: &TransclusionToken) -> Result<RenderedExcerpt> {
    let text = live_text(conn, token)?;
    let removed = text.is_none();
    Ok(RenderedExcerpt {
        date: token.date.clone(),
        from: token.from.clone(),
        to: token.to.clone(),
        text: text.unwrap_or_else(|| format!("removed from {}", token.date)),
        removed,
    })
}

/// Renders every transclusion token in `body`, in the order
/// [`parse_transclusions`] returns them (zip by index for the spans).
pub fn render_all(conn: &Connection, body: &str) -> Result<Vec<RenderedExcerpt>> {
    parse_transclusions(body)
        .iter()
        .map(|token| render(conn, token))
        .collect()
}

/// The joined block text for `token`, or `None` when the daily note or an
/// endpoint block is gone.
fn live_text(conn: &Connection, token: &TransclusionToken) -> Result<Option<String>> {
    let Some(note_id) = daily_note_id_for_title(conn, &token.date)? else {
        return Ok(None);
    };
    let Some((min_ord, max_ord)) = resolve_span(conn, &note_id, &token.from, token.to.as_deref())?
    else {
        return Ok(None);
    };
    let mut stmt = conn.prepare_cached(
        "SELECT text FROM blocks WHERE note_id = ? AND ord BETWEEN ? AND ? ORDER BY ord",
    )?;
    let texts = stmt
        .query_map(params![note_id, min_ord, max_ord], |r| {
            r.get::<_, String>(0)
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(Some(texts.join("\n")))
}

/// The inclusive `(min_ord, max_ord)` span of the blocks a transclusion of
/// `from` (and `to`, for a range) covers in daily note `daily_note_id`, by
/// the C4 rule: every block with an ord between the endpoints' ords, in
/// either order. `None` when an endpoint block no longer exists. The one
/// copy of these semantics (D28): rendering and search expansion both use it.
pub(crate) fn resolve_span(
    conn: &Connection,
    daily_note_id: &str,
    from: &str,
    to: Option<&str>,
) -> Result<Option<(i64, i64)>> {
    let Some(from_ord) = block_ord(conn, daily_note_id, from)? else {
        return Ok(None);
    };
    let to_ord = match to {
        None => from_ord,
        Some(to) => match block_ord(conn, daily_note_id, to)? {
            Some(ord) => ord,
            None => return Ok(None),
        },
    };
    Ok(Some((from_ord.min(to_ord), from_ord.max(to_ord))))
}

/// The `ord` of block `block_id` within note `note_id`.
fn block_ord(conn: &Connection, note_id: &str, block_id: &str) -> Result<Option<i64>> {
    Ok(conn
        .query_row(
            "SELECT ord FROM blocks WHERE note_id = ? AND block_id = ?",
            params![note_id, block_id],
            |r| r.get(0),
        )
        .optional()?)
}
