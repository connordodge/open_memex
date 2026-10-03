//! Inline indexing: when a note is written, its chunks + FTS rows are
//! rewritten in a single transaction. No background queue for the prototype.
//!
//! Vector embeddings are written if a non-None [`crate::embedder::Embedder`]
//! is provided; otherwise indexing is FTS-only.

use rusqlite::{params, Connection};
use ulid::Ulid;

use crate::chunker;
use crate::embedder::Embedder;
use crate::link_extractor;
use crate::links;
use crate::schema;
use crate::Result;

/// Reindex a single note: delete existing chunks/fts/vec rows for it, then
/// rewrite from the latest content. Optionally embed if `embedder` is provided.
pub fn reindex_note(
    conn: &mut Connection,
    note_id: &str,
    content_md: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<usize> {
    let chunks = chunker::chunk(content_md);
    let extracted = link_extractor::extract(content_md);

    let model_version = embedder.map(|e| e.model_version().to_string());
    let dim = embedder.map(|e| e.dimension());
    if let Some(d) = dim {
        schema::ensure_vector_table(conn, d)?;
    }

    let tx = conn.transaction()?;

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
    links::replace_links_for_note(&tx, note_id, &pending)?;

    // Drop existing chunk rows for this note. Cascading FK on `chunks` does
    // not extend to virtual tables, so we delete from chunk_fts (and chunk_vec)
    // explicitly via the chunk ids we're about to remove.
    let old_chunk_ids: Vec<String> = {
        let mut stmt = tx.prepare("SELECT id FROM chunks WHERE note_id = ?")?;
        let mut rows = stmt.query(params![note_id])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(r.get::<_, String>(0)?);
        }
        out
    };
    for cid in &old_chunk_ids {
        tx.execute("DELETE FROM chunk_fts WHERE chunk_id = ?", params![cid])?;
        if dim.is_some() {
            // chunk_vec may not exist if we previously indexed FTS-only; ignore the
            // not-found error.
            let _ = tx.execute("DELETE FROM chunk_vec WHERE chunk_id = ?", params![cid]);
        }
    }
    tx.execute("DELETE FROM chunks WHERE note_id = ?", params![note_id])?;

    if chunks.is_empty() {
        tx.execute(
            "DELETE FROM pending_index WHERE note_id = ?",
            params![note_id],
        )?;
        tx.commit()?;
        return Ok(0);
    }

    // Compute embeddings up front (outside the SQL loop) if requested.
    let embeddings: Option<Vec<Vec<f32>>> = if let Some(e) = embedder {
        let texts: Vec<String> = chunks.iter().map(|c| c.content.clone()).collect();
        Some(e.embed_batch(&texts)?)
    } else {
        None
    };

    let n_written = chunks.len();
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

    tx.execute(
        "DELETE FROM pending_index WHERE note_id = ?",
        params![note_id],
    )?;
    tx.commit()?;
    let _ = n_written; // suppress dead_code if embedding path skipped
    Ok(chunks.len())
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

fn floats_le_bytes(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for f in v {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}
