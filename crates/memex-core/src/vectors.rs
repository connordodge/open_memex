//! Vector-index status and maintenance for the `chunk_vec` and
//! `attachment_chunk_vec` tables.

use rusqlite::{params, Connection, TransactionBehavior};
use serde::Serialize;

use crate::embedder::Embedder;
use crate::indexer::{self, floats_le_bytes};
use crate::schema;
use crate::{MemexError, Result};

/// How many chunks the vault holds and how many of them have a vector. Note
/// chunks and attachment chunks both count (Spec #123 TD).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct EmbeddingCounts {
    /// Row count of `chunks` plus row count of `attachment_chunks`.
    pub chunks: i64,
    /// `chunk_vec` rows whose `chunk_id` joins to `chunks`, plus
    /// `attachment_chunk_vec` rows whose `chunk_id` joins to
    /// `attachment_chunks` (orphans excluded); a vector table that does not
    /// exist counts 0.
    pub embedded: i64,
}

/// Counts the vault's note and attachment chunks and the vectors that belong
/// to them, in one statement, so every count reads the same snapshot.
pub fn embedding_counts(conn: &Connection) -> Result<EmbeddingCounts> {
    let note_vecs = if has_table(conn, "chunk_vec")? {
        "(SELECT COUNT(*) FROM chunk_vec v JOIN chunks c ON c.id = v.chunk_id)"
    } else {
        "0"
    };
    let attachment_vecs = if has_table(conn, "attachment_chunk_vec")? {
        "(SELECT COUNT(*) FROM attachment_chunk_vec v \
          JOIN attachment_chunks c ON c.id = v.chunk_id)"
    } else {
        "0"
    };
    let sql = format!(
        "SELECT (SELECT COUNT(*) FROM chunks) + (SELECT COUNT(*) FROM attachment_chunks), \
         {note_vecs} + {attachment_vecs}"
    );
    let (chunks, embedded): (i64, i64) =
        conn.query_row(&sql, [], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(EmbeddingCounts { chunks, embedded })
}

/// Whether table `name` exists.
fn has_table(conn: &Connection, name: &str) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = ?)",
        [name],
        |r| r.get(0),
    )?)
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
    /// Unembedded chunks (note and attachment) left after the run.
    pub pending: usize,
}

/// Which vector table a picked chunk's vector goes to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Side {
    /// A note chunk: `chunks` → `chunk_vec`.
    Note,
    /// An attachment chunk: `attachment_chunks` → `attachment_chunk_vec`.
    Attachment,
}

impl Side {
    fn chunk_table(self) -> &'static str {
        match self {
            Side::Note => "chunks",
            Side::Attachment => "attachment_chunks",
        }
    }

    fn vec_table(self) -> &'static str {
        match self {
            Side::Note => "chunk_vec",
            Side::Attachment => "attachment_chunk_vec",
        }
    }
}

/// One chunk [`embed_missing`] picked: its side, id and embedding input.
struct Picked {
    side: Side,
    id: String,
    text: String,
}

/// Embeds up to `note_cap` of `note_first`'s unembedded chunks (by `ord`),
/// then up to `others_cap` unembedded chunks of other notes (by ascending
/// chunk id) and, in what `others_cap` leaves, unembedded attachment chunks
/// (by ascending id), without holding the connection across inference (Spec
/// #391 req 5, Spec #123 TD).
///
/// A note chunk's embedding input is its `chunk_fts` text (R45: no
/// `objects/…` destination); an attachment chunk's is its content. Note
/// vectors go to `chunk_vec`, attachment vectors to `attachment_chunk_vec`
/// (made once the vault has an attachment chunk). The orphan delete removes
/// `chunk_vec` rows not in `chunks` and `attachment_chunk_vec` rows not in
/// `attachment_chunks`, never one table's rows as orphans of the other.
///
/// The lease is taken once for the read phase (orphan delete, vector table
/// creation, pick) and once per vector insert; `embed_batch` runs between
/// them with no lease held. Each insert is skipped when its chunk was
/// deleted or given a vector in the meantime. Neither chunk table is
/// written, and the embedder is never called when nothing is picked.
pub fn embed_missing<L: ConnLease>(
    conn: &mut L,
    embedder: &dyn Embedder,
    note_first: Option<&str>,
    note_cap: usize,
    others_cap: usize,
) -> Result<EmbedMissing> {
    embed_missing_of(
        conn,
        embedder,
        note_first,
        note_cap,
        others_cap,
        Attachments::Embed,
    )
}

/// [`embed_missing`] over note chunks only, for Echoes, whose kNN reads only
/// `chunk_vec`: no attachment chunk is picked, and `pending` counts only
/// unembedded note chunks (`chunks` rows with no `chunk_vec` row), so
/// attachment text never keeps Echoes "still indexing". Both orphan deletes
/// still run.
pub fn embed_missing_notes<L: ConnLease>(
    conn: &mut L,
    embedder: &dyn Embedder,
    note_first: Option<&str>,
    note_cap: usize,
    others_cap: usize,
) -> Result<EmbedMissing> {
    embed_missing_of(
        conn,
        embedder,
        note_first,
        note_cap,
        others_cap,
        Attachments::Skip,
    )
}

/// Whether an [`embed_missing`] run embeds and counts attachment chunks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Attachments {
    Embed,
    Skip,
}

fn embed_missing_of<L: ConnLease>(
    conn: &mut L,
    embedder: &dyn Embedder,
    note_first: Option<&str>,
    note_cap: usize,
    others_cap: usize,
    attachments: Attachments,
) -> Result<EmbedMissing> {
    let (picked, pending_now) = conn.lease(|c| {
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        schema::ensure_vector_table(&tx, embedder.dimension())?;
        tx.execute(
            "DELETE FROM chunk_vec WHERE chunk_id NOT IN (SELECT id FROM chunks)",
            [],
        )?;
        let has_attachment_chunks: bool =
            tx.query_row("SELECT EXISTS (SELECT 1 FROM attachment_chunks)", [], |r| {
                r.get(0)
            })?;
        if has_attachment_chunks {
            schema::ensure_attachment_vector_table(&tx, embedder.dimension())?;
        }
        if has_table(&tx, "attachment_chunk_vec")? {
            tx.execute(
                "DELETE FROM attachment_chunk_vec
                  WHERE chunk_id NOT IN (SELECT id FROM attachment_chunks)",
                [],
            )?;
        }
        let picked = pick_unembedded(&tx, note_first, note_cap, others_cap, attachments)?;
        let pending = if picked.is_empty() {
            Some(pending_count(&tx, attachments)?)
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
    let texts: Vec<String> = picked.iter().map(|p| p.text.clone()).collect();
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
    for (i, (p, vector)) in picked.iter().zip(&vectors).enumerate() {
        let (wrote, left) = conn.lease(|c| {
            let wrote = insert_if_unembedded(c, p.side, &p.id, vector)?;
            let left = if i == last {
                pending_count(c, attachments)?
            } else {
                0
            };
            Ok((wrote, left))
        })?;
        if wrote {
            embedded += 1;
        }
        pending = left;
    }
    Ok(EmbedMissing { embedded, pending })
}

/// Unembedded chunks to embed: `note_first`'s by `ord` (at most
/// `note_cap`), then other notes' by ascending id, then attachment chunks by
/// ascending id (those two together at most `others_cap`), unless
/// `attachments` is [`Attachments::Skip`].
fn pick_unembedded(
    conn: &Connection,
    note_first: Option<&str>,
    note_cap: usize,
    others_cap: usize,
    attachments: Attachments,
) -> Result<Vec<Picked>> {
    // (chunk id, note id, content, start_byte, the note's stored body)
    type Row = (String, String, String, Option<i64>, Option<String>);
    let read = |r: &rusqlite::Row<'_>| -> rusqlite::Result<Row> {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    };
    let note = |(id, note_id, content, start, body): Row| -> Result<Picked> {
        let text =
            indexer::stored_chunk_index_text(conn, &note_id, body.as_deref(), start, &content)?;
        Ok(Picked {
            side: Side::Note,
            id,
            text,
        })
    };
    let mut picked = Vec::new();
    if let Some(note_id) = note_first {
        let mut stmt = conn.prepare(
            "SELECT c.id, c.note_id, c.content, c.start_byte, n.content_md
               FROM chunks c LEFT JOIN notes n ON n.id = c.note_id
              WHERE c.note_id = ?1 AND c.id NOT IN (SELECT chunk_id FROM chunk_vec)
              ORDER BY c.ord, c.id
              LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![note_id, sql_limit(note_cap)], read)?;
        for row in rows {
            picked.push(note(row?)?);
        }
    }
    let first = picked.len();
    let mut stmt = conn.prepare(
        "SELECT c.id, c.note_id, c.content, c.start_byte, n.content_md
           FROM chunks c LEFT JOIN notes n ON n.id = c.note_id
          WHERE (?1 IS NULL OR c.note_id <> ?1)
            AND c.id NOT IN (SELECT chunk_id FROM chunk_vec)
          ORDER BY c.id
          LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![note_first, sql_limit(others_cap)], read)?;
    for row in rows {
        picked.push(note(row?)?);
    }
    let left = others_cap.saturating_sub(picked.len() - first);
    if attachments == Attachments::Embed && left > 0 && has_table(conn, "attachment_chunk_vec")? {
        let mut stmt = conn.prepare(
            "SELECT id, content FROM attachment_chunks
              WHERE id NOT IN (SELECT chunk_id FROM attachment_chunk_vec)
              ORDER BY id
              LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![sql_limit(left)], |r| Ok((r.get(0)?, r.get(1)?)))?;
        for row in rows {
            let (id, text) = row?;
            picked.push(Picked {
                side: Side::Attachment,
                id,
                text,
            });
        }
    }
    Ok(picked)
}

fn sql_limit(cap: usize) -> i64 {
    i64::try_from(cap).unwrap_or(i64::MAX)
}

/// Writes `vector` for `side`'s chunk `chunk_id` in one short transaction,
/// only if the chunk still exists and has no vector. Returns whether it
/// wrote.
fn insert_if_unembedded(
    conn: &mut Connection,
    side: Side,
    chunk_id: &str,
    vector: &[f32],
) -> Result<bool> {
    let (chunks, vecs) = (side.chunk_table(), side.vec_table());
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let insertable: bool = tx.query_row(
        &format!(
            "SELECT EXISTS (SELECT 1 FROM {chunks} WHERE id = ?1)
                AND NOT EXISTS (SELECT 1 FROM {vecs} WHERE chunk_id = ?1)"
        ),
        [chunk_id],
        |r| r.get(0),
    )?;
    if insertable {
        tx.execute(
            &format!("INSERT INTO {vecs} (chunk_id, embedding) VALUES (?, ?)"),
            params![chunk_id, floats_le_bytes(vector)],
        )?;
    }
    tx.commit()?;
    Ok(insertable)
}

/// Unembedded chunks left: [`embedding_counts`] `chunks - embedded`, or,
/// with [`Attachments::Skip`], the `chunks` rows with no `chunk_vec` row.
fn pending_count(conn: &Connection, attachments: Attachments) -> Result<usize> {
    let left = match attachments {
        Attachments::Embed => {
            let c = embedding_counts(conn)?;
            c.chunks - c.embedded
        }
        Attachments::Skip => conn.query_row(
            "SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_vec)",
            [],
            |r| r.get::<_, i64>(0),
        )?,
    };
    Ok(usize::try_from(left).unwrap_or(0))
}
