//! Vector-index status and maintenance for the `chunk_vec` table.

use rusqlite::{params, Connection, TransactionBehavior};
use serde::Serialize;

use crate::embedder::Embedder;
use crate::indexer::floats_le_bytes;
use crate::schema;
use crate::{MemexError, Result};

/// How many chunks the vault holds and how many of them have a vector.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct EmbeddingCounts {
    /// Row count of `chunks`.
    pub chunks: i64,
    /// `chunk_vec` rows whose `chunk_id` joins to `chunks` (orphans excluded);
    /// 0 when `chunk_vec` does not exist.
    pub embedded: i64,
}

/// Counts the vault's chunks and the vectors that belong to them. When
/// `chunk_vec` exists, both counts come from one statement, so they read the
/// same snapshot.
pub fn embedding_counts(conn: &Connection) -> Result<EmbeddingCounts> {
    let has_vec: bool = conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'chunk_vec')",
        [],
        |r| r.get(0),
    )?;
    let (chunks, embedded): (i64, i64) = if has_vec {
        conn.query_row(
            "SELECT (SELECT COUNT(*) FROM chunks), \
             (SELECT COUNT(*) FROM chunk_vec v JOIN chunks c ON c.id = v.chunk_id)",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?
    } else {
        let chunks = conn.query_row("SELECT COUNT(*) FROM chunks", [], |r| r.get(0))?;
        (chunks, 0)
    };
    Ok(EmbeddingCounts { chunks, embedded })
}

/// Access to the vault connection that is held only for one call (lead
/// ruling, #420). A plain `&mut Connection` is a lease (CLI, tests); the
/// vault server's lease locks the served vault for each call.
pub trait ConnLease {
    /// Runs `f` with the vault connection held only for the call.
    fn lease<R>(&mut self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R>;
}

impl ConnLease for &mut Connection {
    fn lease<R>(&mut self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        f(self)
    }
}

/// What one [`embed_missing`] run did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct EmbedMissing {
    /// Vectors this run wrote.
    pub embedded: usize,
    /// Unembedded chunks left after the run.
    pub pending: usize,
}

/// Embeds up to `note_cap` of `note_first`'s unembedded chunks (by `ord`),
/// then up to `others_cap` unembedded chunks of other notes (by ascending
/// chunk id), without holding the connection across inference (Spec #391
/// req 5).
///
/// The lease is taken once for the read phase (orphan delete, `chunk_vec`
/// creation, pick) and once per vector insert; `embed_batch` runs between
/// them with no lease held. Each insert is skipped when its chunk was
/// deleted or given a vector in the meantime. `chunks` is never written, and
/// the embedder is never called when nothing is picked.
pub fn embed_missing<L: ConnLease>(
    conn: &mut L,
    embedder: &dyn Embedder,
    note_first: Option<&str>,
    note_cap: usize,
    others_cap: usize,
) -> Result<EmbedMissing> {
    let (picked, pending_now) = conn.lease(|c| {
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        schema::ensure_vector_table(&tx, embedder.dimension())?;
        tx.execute(
            "DELETE FROM chunk_vec WHERE chunk_id NOT IN (SELECT id FROM chunks)",
            [],
        )?;
        let picked = pick_unembedded(&tx, note_first, note_cap, others_cap)?;
        let pending = if picked.is_empty() {
            Some(pending_count(&tx)?)
        } else {
            None
        };
        tx.commit()?;
        Ok((picked, pending))
    })?;
    if let Some(pending) = pending_now {
        return Ok(EmbedMissing {
            embedded: 0,
            pending,
        });
    }

    // Inference: no lease, no transaction.
    let texts: Vec<String> = picked.iter().map(|(_, text)| text.clone()).collect();
    let vectors = embedder.embed_batch(&texts)?;
    if vectors.len() != picked.len() {
        return Err(MemexError::EmbedderInfer(format!(
            "embedder returned {} vectors for {} texts",
            vectors.len(),
            picked.len()
        )));
    }

    let mut embedded = 0;
    let mut pending = 0;
    let last = picked.len() - 1;
    for (i, ((chunk_id, _), vector)) in picked.iter().zip(&vectors).enumerate() {
        let (wrote, left) = conn.lease(|c| {
            let wrote = insert_if_unembedded(c, chunk_id, vector)?;
            let left = if i == last { pending_count(c)? } else { 0 };
            Ok((wrote, left))
        })?;
        if wrote {
            embedded += 1;
        }
        pending = left;
    }
    Ok(EmbedMissing { embedded, pending })
}

/// Unembedded chunks to embed: `note_first`'s by `ord`, then other notes'
/// by ascending id, each list capped. Returns `(chunk id, content)`.
fn pick_unembedded(
    conn: &Connection,
    note_first: Option<&str>,
    note_cap: usize,
    others_cap: usize,
) -> Result<Vec<(String, String)>> {
    let mut picked = Vec::new();
    if let Some(note) = note_first {
        let mut stmt = conn.prepare(
            "SELECT id, content FROM chunks
              WHERE note_id = ?1 AND id NOT IN (SELECT chunk_id FROM chunk_vec)
              ORDER BY ord, id
              LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![note, sql_limit(note_cap)], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?;
        for row in rows {
            picked.push(row?);
        }
    }
    let mut stmt = conn.prepare(
        "SELECT id, content FROM chunks
          WHERE (?1 IS NULL OR note_id <> ?1)
            AND id NOT IN (SELECT chunk_id FROM chunk_vec)
          ORDER BY id
          LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![note_first, sql_limit(others_cap)], |r| {
        Ok((r.get(0)?, r.get(1)?))
    })?;
    for row in rows {
        picked.push(row?);
    }
    Ok(picked)
}

fn sql_limit(cap: usize) -> i64 {
    i64::try_from(cap).unwrap_or(i64::MAX)
}

/// Writes `vector` for `chunk_id` in one short transaction, only if the
/// chunk still exists and has no vector. Returns whether it wrote.
fn insert_if_unembedded(conn: &mut Connection, chunk_id: &str, vector: &[f32]) -> Result<bool> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let insertable: bool = tx.query_row(
        "SELECT EXISTS (SELECT 1 FROM chunks WHERE id = ?1)
            AND NOT EXISTS (SELECT 1 FROM chunk_vec WHERE chunk_id = ?1)",
        [chunk_id],
        |r| r.get(0),
    )?;
    if insertable {
        tx.execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
            params![chunk_id, floats_le_bytes(vector)],
        )?;
    }
    tx.commit()?;
    Ok(insertable)
}

/// Unembedded chunks left: [`embedding_counts`] `chunks - embedded`.
fn pending_count(conn: &Connection) -> Result<usize> {
    let c = embedding_counts(conn)?;
    Ok(usize::try_from(c.chunks - c.embedded).unwrap_or(0))
}
