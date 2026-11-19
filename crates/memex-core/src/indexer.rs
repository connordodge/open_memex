//! Inline indexing: when a note is written, its chunks + FTS rows are
//! rewritten in a single transaction. No background queue for the prototype.
//!
//! Vector embeddings are written if a non-None [`crate::embedder::Embedder`]
//! is provided; otherwise indexing is FTS-only.

use std::ops::Range;

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use ulid::Ulid;

use crate::attachments;
use crate::chunker::{self, Chunk};
use crate::daily;
use crate::embedder::Embedder;
use crate::link_extractor;
use crate::links;
use crate::notes;
use crate::schema;
use crate::tags;
use crate::Result;

/// Reindex a single note: delete existing chunks/fts/vec rows for it, then
/// rewrite from the latest content. Optionally embed if `embedder` is provided.
///
/// Only the note's person section is chunked (Spec #391 req 1): for a
/// `role: daily` note (by its stored frontmatter) the body up to its first
/// marker line, for any other note [`tags::person_section`]. Chunk ranges
/// stay byte offsets into the full `content_md`. The `chunk_vec` rows of the
/// old chunks are deleted whenever `chunk_vec` exists, with or without an
/// embedder (req 4). The note's `note_attachments` rows are rewritten from
/// the attachment reference lines of the same person section (R49).
pub fn reindex_note(
    conn: &mut Connection,
    note_id: &str,
    content_md: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<usize> {
    let person = person_range(conn, note_id, content_md)?;
    let chunks = person_chunks(content_md, &person);

    if let Some(e) = embedder {
        schema::ensure_vector_table(conn, e.dimension())?;
    }

    let tx = conn.transaction()?;
    let written = write_index(&tx, note_id, content_md, &person, &chunks, embedder)?;
    tx.commit()?;
    Ok(written)
}

/// The byte range of `content_md`'s person section. The note's role comes
/// from its stored frontmatter; a note missing from `notes` is not daily.
fn person_range(conn: &Connection, note_id: &str, content_md: &str) -> Result<Range<usize>> {
    let frontmatter: Option<String> = conn
        .query_row(
            "SELECT frontmatter FROM notes WHERE id = ?",
            params![note_id],
            |r| r.get(0),
        )
        .optional()?;
    let is_daily = frontmatter.is_some_and(|f| daily::is_daily(&notes::lenient_frontmatter(&f)));
    Ok(if is_daily {
        // The daily person section runs from after any leading frontmatter
        // block to the first marker line. Ranges stay offsets into the full
        // body, so chunk and block ranges share a base (D25).
        let (_, start) = link_extractor::split_frontmatter(content_md);
        let end =
            daily::daily_marker_start(&content_md[start..]).map_or(content_md.len(), |e| start + e);
        start..end
    } else {
        // `person_section` returns a subslice of `content_md`.
        let section = tags::person_section(content_md);
        let start = section.as_ptr() as usize - content_md.as_ptr() as usize;
        start..start + section.len()
    })
}

/// The chunks of the `person` section of `content_md`, with ranges into the
/// full `content_md`.
fn person_chunks(content_md: &str, person: &Range<usize>) -> Vec<Chunk> {
    let mut chunks = chunker::chunk(&content_md[person.clone()]);
    for c in &mut chunks {
        c.start_byte += person.start;
        c.end_byte += person.start;
    }
    chunks
}

/// The attachment references of the `person` section of `content_md`, in
/// body order: `(decoded vault-relative path, line start byte)` for each
/// reference line, the byte offset into the full `content_md` (R49).
///
/// A reference line is a line whose content, without surrounding
/// whitespace, is exactly one attachment reference
/// ([`attachments::parse_reference`], R4). A reference with anything else
/// on its line, and any line inside fenced code (an unclosed fence runs to
/// the end of the section), is not one. The same reference on two lines is
/// two entries.
fn attachment_reference_lines(content_md: &str, person: &Range<usize>) -> Vec<(String, usize)> {
    let mut out = Vec::new();
    let mut fence: Option<tags::Fence> = None;
    let mut line_start = person.start;
    for line in content_md[person.clone()].split_inclusive('\n') {
        let text = line.strip_suffix('\n').unwrap_or(line);
        if let Some(open) = fence {
            if open.closed_by(text) {
                fence = None;
            }
        } else if let Some(opened) = tags::Fence::opened_by(text) {
            fence = Some(opened);
        } else if let Some(reference) = attachments::parse_reference(text.trim()) {
            out.push((reference.target.path, line_start));
        }
        line_start += line.len();
    }
    out
}

/// Rewrites a note's index rows (flags, links, chunks, FTS, vectors and
/// attachment references) from `content_md`, its `person` section range and
/// `chunks` inside the caller's transaction, and removes its `pending_index`
/// row. Returns the number of chunks written.
fn write_index(
    tx: &Connection,
    note_id: &str,
    content_md: &str,
    person: &Range<usize>,
    chunks: &[Chunk],
    embedder: Option<&dyn Embedder>,
) -> Result<usize> {
    let extracted = link_extractor::extract(content_md);
    let model_version = embedder.map(|e| e.model_version().to_string());

    // Update per-note flags + replace outgoing links.
    tx.execute(
        "UPDATE notes
            SET has_open_questions = ?, frontmatter_parse_error = ?
            WHERE id = ?",
        params![
            extracted.has_open_questions as i64,
            extracted.frontmatter_parse_error as i64,
            note_id,
        ],
    )?;
    let pending: Vec<links::PendingLink> = extracted
        .body
        .into_iter()
        .chain(extracted.frontmatter)
        .collect();
    links::replace_links_for_note(tx, note_id, &pending)?;

    // Drop existing chunk rows for this note. Cascading FK on `chunks` does
    // not extend to virtual tables, so we delete from chunk_fts (and from
    // chunk_vec whenever it exists) explicitly via the chunk ids we're about
    // to remove.
    let old_chunk_ids: Vec<String> = {
        let mut stmt = tx.prepare("SELECT id FROM chunks WHERE note_id = ?")?;
        let mut rows = stmt.query(params![note_id])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(r.get::<_, String>(0)?);
        }
        out
    };
    let has_vectors = !old_chunk_ids.is_empty() && has_chunk_vec(tx)?;
    for cid in &old_chunk_ids {
        tx.execute("DELETE FROM chunk_fts WHERE chunk_id = ?", params![cid])?;
        if has_vectors {
            tx.execute("DELETE FROM chunk_vec WHERE chunk_id = ?", params![cid])?;
        }
    }
    tx.execute("DELETE FROM chunks WHERE note_id = ?", params![note_id])?;

    // Compute embeddings up front (outside the SQL loop) if requested.
    let embeddings: Option<Vec<Vec<f32>>> = match embedder {
        Some(e) if !chunks.is_empty() => {
            let texts: Vec<String> = chunks.iter().map(|c| c.content.clone()).collect();
            Some(e.embed_batch(&texts)?)
        }
        _ => None,
    };

    for (idx, c) in chunks.iter().enumerate() {
        let chunk_id = Ulid::new().to_string();
        tx.execute(
            "INSERT INTO chunks
                (id, note_id, ord, content, token_count, embed_model_version,
                 start_byte, end_byte)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                chunk_id,
                note_id,
                c.ord,
                c.content,
                c.token_count,
                model_version.as_deref(),
                c.start_byte as i64,
                c.end_byte as i64,
            ],
        )?;
        tx.execute(
            "INSERT INTO chunk_fts (chunk_id, note_id, content) VALUES (?, ?, ?)",
            params![chunk_id, note_id, c.content],
        )?;
        if let Some(embs) = &embeddings {
            let bytes = floats_le_bytes(&embs[idx]);
            tx.execute(
                "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
                params![chunk_id, bytes],
            )?;
        }
    }

    // Replace the note's attachment references (R49). Only `note_attachments`
    // is written: `attachments` rows are the store's (R3), and a reference
    // needs none.
    tx.execute(
        "DELETE FROM note_attachments WHERE note_id = ?",
        params![note_id],
    )?;
    for (path, line_start) in attachment_reference_lines(content_md, person) {
        tx.execute(
            "INSERT INTO note_attachments (note_id, path, line_start_byte) VALUES (?, ?, ?)",
            params![note_id, path, line_start as i64],
        )?;
    }

    tx.execute(
        "DELETE FROM pending_index WHERE note_id = ?",
        params![note_id],
    )?;
    Ok(chunks.len())
}

/// Whether the vault's `chunk_vec` table exists (it is made lazily, once an
/// embedding model is known).
fn has_chunk_vec(conn: &Connection) -> Result<bool> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'chunk_vec'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// Reindexes every note queued in `pending_index` from its stored body,
/// without an embedder, one note per IMMEDIATE transaction (ruling D3).
///
/// A note no longer queued when its turn comes (another drain or a save
/// reindexed it) is skipped. When one note fails, its transaction rolls
/// back, its row stays queued for the next drain, a warning names it, and
/// the drain moves on (D38). Never fails: an open is not refused over the
/// rechunk.
pub(crate) fn drain_pending_index(conn: &mut Connection) {
    let queued = match queued_note_ids(conn) {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!(error = %e, "rechunk drain: could not read pending_index");
            return;
        }
    };
    for note_id in queued {
        if let Err(e) = drain_one(conn, &note_id) {
            tracing::warn!(
                note_id = %note_id,
                error = %e,
                "rechunk drain: reindex failed; the note stays queued for the next open"
            );
        }
    }
}

/// The queued note ids, oldest first.
fn queued_note_ids(conn: &Connection) -> Result<Vec<String>> {
    let mut stmt =
        conn.prepare("SELECT note_id FROM pending_index ORDER BY enqueued_at, note_id")?;
    let ids = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(ids)
}

/// Reindexes one queued note in its own IMMEDIATE transaction. Its body and
/// queue row are read inside that transaction, so a concurrent save is never
/// overwritten with an older body.
fn drain_one(conn: &mut Connection, note_id: &str) -> Result<()> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let body: Option<String> = tx
        .query_row(
            "SELECT n.content_md FROM pending_index p JOIN notes n ON n.id = p.note_id
              WHERE p.note_id = ?",
            params![note_id],
            |r| r.get(0),
        )
        .optional()?;
    match body {
        Some(body) => {
            let person = person_range(&tx, note_id, &body)?;
            let chunks = person_chunks(&body, &person);
            write_index(&tx, note_id, &body, &person, &chunks, None)?;
        }
        // Not queued any more, or queued for a note that no longer exists.
        None => {
            tx.execute(
                "DELETE FROM pending_index
                  WHERE note_id = ? AND note_id NOT IN (SELECT id FROM notes)",
                params![note_id],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Hide chunks for a deleted note from the FTS/vec mirrors as well.
/// (We rely on FK CASCADE for the `chunks` table itself.)
pub fn purge_note_indexes(conn: &mut Connection, note_id: &str) -> Result<()> {
    let tx = conn.transaction()?;
    let chunk_ids: Vec<String> = {
        let mut stmt = tx.prepare("SELECT id FROM chunks WHERE note_id = ?")?;
        let mut rows = stmt.query(params![note_id])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(r.get::<_, String>(0)?);
        }
        out
    };
    for cid in &chunk_ids {
        tx.execute("DELETE FROM chunk_fts WHERE chunk_id = ?", params![cid])?;
        let _ = tx.execute("DELETE FROM chunk_vec WHERE chunk_id = ?", params![cid]);
    }
    tx.commit()?;
    Ok(())
}

pub(crate) fn floats_le_bytes(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for f in v {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}
