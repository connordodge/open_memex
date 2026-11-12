//! Echoes: passages of the person's own writing in other notes that are
//! semantically close to the open note and not linked to it (Spec #391
//! requirements 11-16).

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use chrono::NaiveDate;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::chunker::split_blocks;
use crate::daily::parse_iso_date;
use crate::embedder::Embedder;
use crate::guide::GUIDE_NOTE;
use crate::links::{daily_note_id_for_title, LinkKind};
use crate::transclusion::{parse_transclusions, resolve_span};
use crate::vectors::{embed_missing, ConnLease};
use crate::{MemexError, Result};

/// The lowest similarity (`1 - cosine distance`) an echo may have; a
/// candidate scoring exactly this is kept (Spec #391 req 11.6).
pub const ECHO_MIN_SIMILARITY: f32 = 0.70;

/// The open note's unembedded chunks one read embeds first (req 11.1).
const NOTE_CAP: usize = 32;
/// `k = K_BASE + E` on the first kNN round (req 11.3).
const K_BASE: usize = 50;
/// Doubling `k` stops here (req 11.3).
const K_DOUBLING_CAP: usize = 400;
/// sqlite-vec refuses a kNN `k` above this (`SQLITE_VEC_VEC0_K_MAX`).
const K_SQLITE_VEC_MAX: usize = 4096;
/// At most this many block texts are embedded per read (req 13).
const BLOCK_TEXT_CAP: usize = 64;
const EMPTY_NOTE: &str = "empty_note";
const DAILY_ROLE: &str = "daily";
const TOPIC_ROLE: &str = "topic";

/// What one [`echoes`] read returns (Spec #391 req 15). Field names are a
/// wire contract: the CLI and the vault server print this as JSON.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Echoes {
    /// At most `limit` echoes, best first.
    pub echoes: Vec<Echo>,
    /// `Some("empty_note")` when the open note has no chunks and transcludes
    /// no block, else `None`. Only a topic note's transclusions count, as only
    /// they give query vectors (req 11.2).
    pub reason: Option<&'static str>,
    /// Unembedded chunks left after the read's `embed_missing` run.
    pub pending: usize,
}

/// One echo (Spec #391 req 14). It carries no score.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Echo {
    pub note_id: String,
    pub note_title: String,
    /// `daily`, `topic`, or `None` for any other note.
    pub note_role: Option<String>,
    /// The ISO date of a daily note, else `None`.
    pub day: Option<String>,
    /// The chosen block's text.
    pub passage: String,
    /// The passage's UTF-8 byte offset in the note's full body, or `None`
    /// when its chunk has no stored `start_byte`.
    pub start_byte: Option<usize>,
    /// The echoed note's `updated_at`, in ms since the epoch.
    pub note_updated_at: i64,
}

/// The echoes of note `note_id`: up to `limit` passages from other, unlinked
/// notes, one per note, scoring at least [`ECHO_MIN_SIMILARITY`].
/// `others_cap` bounds how many other notes' unembedded chunks this read
/// embeds (64 for the CLI, 0 on the vault server). A missing note is
/// `MemexError::NotFound`.
///
/// The connection is leased for the existence check, for `embed_missing`'s
/// own leases, and once for the kNN read; the best-block batch is embedded
/// with no lease held, and only when some kept chunk has more than one block.
pub fn echoes<L: ConnLease>(
    conn: &mut L,
    embedder: &dyn Embedder,
    note_id: &str,
    limit: usize,
    others_cap: usize,
) -> Result<Echoes> {
    conn.lease(|c| load_note(c, note_id).map(|_| ()))?;
    let pending = embed_missing(conn, embedder, Some(note_id), NOTE_CAP, others_cap)?.pending;
    let Some(kept) = conn.lease(|c| read_kept(c, note_id, limit))? else {
        return Ok(Echoes {
            echoes: Vec::new(),
            reason: Some(EMPTY_NOTE),
            pending,
        });
    };
    let echoes = pick_passages(embedder, kept)?;
    Ok(Echoes {
        echoes,
        reason: None,
        pending,
    })
}

/// A note's columns the read needs.
#[derive(Debug, Clone)]
struct NoteMeta {
    id: String,
    title: String,
    /// `$.role` of valid JSON frontmatter.
    role: Option<String>,
    content_md: String,
    updated_at: i64,
}

impl NoteMeta {
    fn is_role(&self, role: &str) -> bool {
        self.role.as_deref() == Some(role)
    }

    /// The date of a daily note whose title is an ISO date.
    fn day(&self) -> Option<NaiveDate> {
        if self.is_role(DAILY_ROLE) {
            parse_iso_date(&self.title).ok()
        } else {
            None
        }
    }
}

/// One query vector: the stored bytes (for the kNN) and the floats (for the
/// best-block cosine).
struct Query {
    bytes: Vec<u8>,
    floats: Vec<f32>,
}

/// Each kNN chunk id's best score and the index of the query vector that
/// gave it.
type Scores = HashMap<String, (f32, usize)>;

/// The best chunk of one candidate note.
struct Candidate {
    chunk_id: String,
    ord: i64,
    score: f32,
    /// Index of the query vector that gave `score`.
    query: usize,
    content: String,
    start_byte: Option<i64>,
    end_byte: Option<i64>,
}

/// A kept chunk with what the passage step needs.
struct Kept {
    note: NoteMeta,
    content: String,
    start_byte: Option<i64>,
    end_byte: Option<i64>,
    query: Vec<f32>,
}

fn load_note(c: &Connection, note_id: &str) -> Result<NoteMeta> {
    note_meta(c, note_id)?.ok_or_else(|| MemexError::NotFound(format!("note {note_id}")))
}

fn note_meta(c: &Connection, note_id: &str) -> Result<Option<NoteMeta>> {
    Ok(c.query_row(
        "SELECT id, title, content_md, updated_at,
                CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END
           FROM notes WHERE id = ?",
        [note_id],
        |r| {
            Ok(NoteMeta {
                id: r.get(0)?,
                title: r.get(1)?,
                content_md: r.get(2)?,
                updated_at: r.get(3)?,
                // A non-text role (a number, say) is no role.
                role: r.get::<_, Option<String>>(4).unwrap_or(None),
            })
        },
    )
    .optional()?)
}

/// Steps 11.2-11.8: the kept chunks in result order, or `None` when the open
/// note has no query vector source (`empty_note`).
fn read_kept(c: &mut Connection, note_id: &str, limit: usize) -> Result<Option<Vec<Kept>>> {
    let open = load_note(c, note_id)?;
    let own_chunks = chunk_ids(c, note_id)?;
    let mut queries: Vec<Query> = Vec::new();
    for id in &own_chunks {
        if let Some(q) = chunk_vector(c, id)? {
            queries.push(q);
        }
    }
    let mut transcludes = false;
    if open.is_role(TOPIC_ROLE) {
        let (any, day_chunks) = transcluded_day_chunks(c, &open.content_md)?;
        transcludes = any;
        for id in &day_chunks {
            if let Some(q) = chunk_vector(c, id)? {
                queries.push(q);
            }
        }
    }
    if own_chunks.is_empty() && !transcludes {
        return Ok(None);
    }

    let linked = linked_notes(c, &open)?;
    let mut excluded: HashSet<String> = linked.clone();
    excluded.insert(open.id.clone());
    let mut e = own_chunks.len();
    for n in &linked {
        if *n != open.id {
            e += chunk_count(c, n)?;
        }
    }
    excluded.extend(guide_ids(c)?);
    let open_day = open.day();

    let mut notes: HashMap<String, Option<NoteMeta>> = HashMap::new();
    let mut k = (K_BASE + e).min(K_SQLITE_VEC_MAX);
    let candidates = loop {
        let (scores, exhausted) = knn_round(c, &queries, k)?;
        let candidates = qualify(c, scores, &excluded, open_day, &mut notes)?;
        if candidates.len() >= limit || exhausted || k >= K_DOUBLING_CAP {
            break candidates;
        }
        k = (k * 2).min(K_DOUBLING_CAP);
    };

    let mut ranked: Vec<(NoteMeta, Candidate)> = candidates
        .into_iter()
        .filter_map(|(id, cand)| notes.get(&id).cloned().flatten().map(|n| (n, cand)))
        .collect();
    ranked.sort_by(|(na, a), (nb, b)| {
        b.score
            .total_cmp(&a.score)
            .then(nb.updated_at.cmp(&na.updated_at))
            .then(na.id.cmp(&nb.id))
    });
    ranked.truncate(limit);
    Ok(Some(
        ranked
            .into_iter()
            .map(|(note, cand)| Kept {
                note,
                content: cand.content,
                start_byte: cand.start_byte,
                end_byte: cand.end_byte,
                query: queries[cand.query].floats.clone(),
            })
            .collect(),
    ))
}

/// A note's chunk ids by `ord`.
fn chunk_ids(c: &Connection, note_id: &str) -> Result<Vec<String>> {
    let mut stmt = c.prepare_cached("SELECT id FROM chunks WHERE note_id = ? ORDER BY ord, id")?;
    let ids = stmt
        .query_map([note_id], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

fn chunk_count(c: &Connection, note_id: &str) -> Result<usize> {
    let n: i64 = c.query_row(
        "SELECT COUNT(*) FROM chunks WHERE note_id = ?",
        [note_id],
        |r| r.get(0),
    )?;
    Ok(usize::try_from(n).unwrap_or(0))
}

/// The stored vector of a chunk, if it has one.
fn chunk_vector(c: &Connection, chunk_id: &str) -> Result<Option<Query>> {
    let bytes: Option<Vec<u8>> = c
        .query_row(
            "SELECT embedding FROM chunk_vec WHERE chunk_id = ?",
            [chunk_id],
            |r| r.get(0),
        )
        .optional()?;
    Ok(bytes.map(|bytes| {
        let floats = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        Query { bytes, floats }
    }))
}

/// The daily-note chunks overlapping, by byte range, a block that `body`
/// transcludes (req 11.2), in token then `ord` order, and whether any token
/// resolved to a block span at all. Chunks with no stored range overlap
/// nothing.
fn transcluded_day_chunks(c: &Connection, body: &str) -> Result<(bool, Vec<String>)> {
    let mut any = false;
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for token in parse_transclusions(body) {
        let Some(day) = daily_note_id_for_title(c, &token.date)? else {
            continue;
        };
        let Some((lo, hi)) = resolve_span(c, &day, &token.from, token.to.as_deref())? else {
            continue;
        };
        any = true;
        let mut stmt = c.prepare_cached(
            "SELECT start_byte, end_byte FROM blocks
              WHERE note_id = ? AND ord BETWEEN ? AND ?",
        )?;
        let ranges = stmt
            .query_map(params![day, lo, hi], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut stmt = c.prepare_cached(
            "SELECT id, start_byte, end_byte FROM chunks
              WHERE note_id = ? AND start_byte IS NOT NULL AND end_byte IS NOT NULL
              ORDER BY ord, id",
        )?;
        let chunks = stmt
            .query_map([&day], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for (id, cs, ce) in chunks {
            // Block [s, e) overlaps chunk [cs, ce) iff s < ce && cs < e.
            let overlaps = ranges.iter().any(|&(s, e)| s < ce && cs < e);
            if overlaps && seen.insert(id.clone()) {
                out.push(id);
            }
        }
    }
    Ok((any, out))
}

/// The notes linked to or from `open` by any link of any kind (req 12),
/// resolved or not. An unresolved link (`to_note_id` NULL) links the notes
/// its `link_text` names by the `links.rs` title rule: an exact `title`
/// match, and for a `from-day` link only the `role: daily` note of that
/// title. `open` itself is never in the set.
fn linked_notes(c: &Connection, open: &NoteMeta) -> Result<HashSet<String>> {
    let mut out: HashSet<String> = HashSet::new();
    let mut stmt = c.prepare_cached(
        "SELECT to_note_id FROM links WHERE from_note_id = ?1 AND to_note_id IS NOT NULL
         UNION
         SELECT from_note_id FROM links WHERE to_note_id = ?1",
    )?;
    for id in stmt.query_map([&open.id], |r| r.get::<_, String>(0))? {
        out.insert(id?);
    }

    // Unresolved outgoing links: the notes their text names.
    let mut stmt = c.prepare_cached(
        "SELECT link_text, link_kind FROM links
          WHERE from_note_id = ? AND to_note_id IS NULL",
    )?;
    let outgoing = stmt
        .query_map([&open.id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (text, kind) in outgoing {
        if kind == LinkKind::FROM_DAY {
            out.extend(daily_note_id_for_title(c, &text)?);
        } else {
            let mut stmt = c.prepare_cached("SELECT id FROM notes WHERE title = ?")?;
            for id in stmt.query_map([&text], |r| r.get::<_, String>(0))? {
                out.insert(id?);
            }
        }
    }

    // Unresolved incoming links whose text names the open note.
    let open_is_named_day =
        daily_note_id_for_title(c, &open.title)?.as_deref() == Some(open.id.as_str());
    let mut stmt = c.prepare_cached(
        "SELECT from_note_id, link_kind FROM links
          WHERE to_note_id IS NULL AND link_text = ?",
    )?;
    let incoming = stmt
        .query_map([&open.title], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (from, kind) in incoming {
        if kind != LinkKind::FROM_DAY || open_is_named_day {
            out.insert(from);
        }
    }

    out.remove(&open.id);
    Ok(out)
}

/// The Vault Guide's id (at most one note, by `idx_notes_guide`).
fn guide_ids(c: &Connection) -> Result<Vec<String>> {
    let mut stmt = c.prepare_cached(&format!("SELECT id FROM notes WHERE {GUIDE_NOTE}"))?;
    let ids = stmt
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

/// One kNN pass with `k` per query vector (req 11.3, 11.5): each chunk's
/// best `1 - distance` and the first query vector that gave it. `exhausted`
/// is true when every query returned fewer than `k` rows, so a larger `k`
/// could find nothing more.
fn knn_round(c: &Connection, queries: &[Query], k: usize) -> Result<(Scores, bool)> {
    let mut best: Scores = HashMap::new();
    let mut exhausted = true;
    let mut stmt = c.prepare_cached(
        "SELECT chunk_id, distance FROM chunk_vec
          WHERE embedding MATCH ? AND k = ? ORDER BY distance",
    )?;
    let k_sql = i64::try_from(k).unwrap_or(i64::MAX);
    for (qi, q) in queries.iter().enumerate() {
        let rows = stmt
            .query_map(params![q.bytes, k_sql], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<f64>>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        if rows.len() >= k {
            exhausted = false;
        }
        // A zero vector's cosine distance is NaN, which SQLite returns as
        // NULL: that row has no score and is skipped.
        for (chunk_id, distance) in rows {
            let Some(distance) = distance.filter(|d| !d.is_nan()) else {
                continue;
            };
            let score = 1.0 - distance as f32;
            match best.get(&chunk_id) {
                Some(&(s, _)) if s >= score => {}
                _ => {
                    best.insert(chunk_id, (score, qi));
                }
            }
        }
    }
    Ok((best, exhausted))
}

/// Steps 11.4, 11.6 and 11.7: drops excluded and below-threshold chunks and
/// keeps each note's best chunk (ties to the lower `ord`, then chunk id).
/// `notes` caches note rows across rounds.
fn qualify(
    c: &Connection,
    scores: Scores,
    excluded: &HashSet<String>,
    open_day: Option<NaiveDate>,
    notes: &mut HashMap<String, Option<NoteMeta>>,
) -> Result<HashMap<String, Candidate>> {
    let mut out: HashMap<String, Candidate> = HashMap::new();
    let mut stmt = c.prepare_cached(
        "SELECT note_id, ord, content, start_byte, end_byte FROM chunks WHERE id = ?",
    )?;
    for (chunk_id, (score, query)) in scores {
        if score.is_nan() || score < ECHO_MIN_SIMILARITY {
            continue;
        }
        let row = stmt
            .query_row([&chunk_id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<i64>>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                ))
            })
            .optional()?;
        let Some((note_id, ord, content, start_byte, end_byte)) = row else {
            continue;
        };
        if excluded.contains(&note_id) {
            continue;
        }
        if !notes.contains_key(&note_id) {
            let meta = note_meta(c, &note_id)?;
            notes.insert(note_id.clone(), meta);
        }
        let Some(Some(meta)) = notes.get(&note_id) else {
            continue;
        };
        if let (Some(open), Some(day)) = (open_day, meta.day()) {
            if day > open {
                continue;
            }
        }
        let cand = Candidate {
            chunk_id,
            ord,
            score,
            query,
            content,
            start_byte,
            end_byte,
        };
        match out.get(&note_id) {
            Some(prev) if !better(&cand, prev) => {}
            _ => {
                out.insert(note_id, cand);
            }
        }
    }
    Ok(out)
}

/// Whether `a` beats `b` as a note's best chunk.
fn better(a: &Candidate, b: &Candidate) -> bool {
    a.score
        .total_cmp(&b.score)
        .then(b.ord.cmp(&a.ord))
        .then(b.chunk_id.cmp(&a.chunk_id))
        == Ordering::Greater
}

/// How a kept chunk's passage is chosen.
enum Plan {
    /// This block, without embedding.
    Block(usize, String),
    /// The best of these blocks, whose vectors start at `at` in the batch.
    Best {
        at: usize,
        blocks: Vec<(usize, String)>,
    },
}

/// Req 13: each kept chunk's passage. Multi-block chunks are taken in result
/// order while their blocks fit in [`BLOCK_TEXT_CAP`] texts; a chunk whose
/// blocks no longer fit uses its first block. The blocks are embedded in one
/// batch (not stored), and none is embedded when no chunk needs it.
fn pick_passages(embedder: &dyn Embedder, kept: Vec<Kept>) -> Result<Vec<Echo>> {
    let mut batch: Vec<String> = Vec::new();
    let mut plans = Vec::with_capacity(kept.len());
    for k in &kept {
        let blocks: Vec<(usize, String)> = split_blocks(&k.content)
            .into_iter()
            .map(|(at, text)| (at, text.to_string()))
            .collect();
        let plan = match blocks.len() {
            0 => Plan::Block(0, k.content.trim().to_string()),
            1 => Plan::Block(blocks[0].0, blocks[0].1.clone()),
            n if batch.len() + n <= BLOCK_TEXT_CAP => {
                let at = batch.len();
                batch.extend(blocks.iter().map(|(_, t)| t.clone()));
                Plan::Best { at, blocks }
            }
            _ => Plan::Block(blocks[0].0, blocks[0].1.clone()),
        };
        plans.push(plan);
    }

    let vectors = if batch.is_empty() {
        Vec::new()
    } else {
        let vectors = embedder.embed_batch(&batch)?;
        if vectors.len() != batch.len() {
            return Err(MemexError::EmbedderInfer(format!(
                "embedder returned {} vectors for {} texts",
                vectors.len(),
                batch.len()
            )));
        }
        vectors
    };

    let mut out = Vec::with_capacity(kept.len());
    for (k, plan) in kept.into_iter().zip(plans) {
        let (offset, passage) = match plan {
            Plan::Block(at, text) => (at, text),
            Plan::Best { at, blocks } => {
                let mut best = 0;
                let mut best_sim = f32::NEG_INFINITY;
                for i in 0..blocks.len() {
                    let sim = cosine(&vectors[at + i], &k.query);
                    // Strictly greater: a tie keeps the earlier block.
                    if sim > best_sim {
                        best = i;
                        best_sim = sim;
                    }
                }
                blocks.into_iter().nth(best).unwrap_or_default()
            }
        };
        let (passage, start_byte) = locate(&k, offset, passage);
        out.push(echo(k.note, passage, start_byte));
    }
    Ok(out)
}

/// The passage's byte offset in the note's full body, and its text.
///
/// A chunk of whole blocks is the exact body slice at its `start_byte`, so
/// the passage starts at `start_byte + offset`. A sentence sub-chunk of a
/// long block is not: its sentences are re-joined with single spaces and it
/// carries the whole block's range. Its passage is then found inside that
/// range, matching any whitespace run with any whitespace run, and both the
/// offset and the text are taken from the body. When it cannot be found
/// (the body changed since chunking), the offset falls back to
/// `start_byte + offset` and the text stays the chunk's.
fn locate(k: &Kept, offset: usize, passage: String) -> (String, Option<usize>) {
    let Some(start) = k.start_byte.and_then(|s| usize::try_from(s).ok()) else {
        return (passage, None);
    };
    let body = k.note.content_md.as_str();
    let exact = body
        .get(start..)
        .is_some_and(|rest| rest.starts_with(k.content.as_str()));
    if !exact {
        let end = k
            .end_byte
            .and_then(|e| usize::try_from(e).ok())
            .filter(|&e| e >= start)
            .map_or(body.len(), |e| e.min(body.len()));
        if let Some(window) = body.get(start..end) {
            if let Some((from, to)) = find_loose(window, &passage) {
                return (window[from..to].to_string(), Some(start + from));
            }
        }
    }
    (passage, Some(start + offset))
}

/// The first `[from, to)` byte range of `hay` that equals `needle` when each
/// whitespace run on either side counts as one space. `needle` is trimmed.
fn find_loose(hay: &str, needle: &str) -> Option<(usize, usize)> {
    let first = needle.chars().next().filter(|c| !c.is_whitespace())?;
    hay.char_indices()
        .filter(|&(_, c)| c == first)
        .find_map(|(i, _)| loose_prefix_len(&hay[i..], needle).map(|len| (i, i + len)))
}

/// The byte length of the prefix of `hay` that loosely equals `needle` (see
/// [`find_loose`]), if there is one.
fn loose_prefix_len(hay: &str, needle: &str) -> Option<usize> {
    let mut h = hay.char_indices().peekable();
    let mut n = needle.chars().peekable();
    let mut end = 0;
    while let Some(nc) = n.next() {
        if nc.is_whitespace() {
            while n.next_if(|c| c.is_whitespace()).is_some() {}
            h.next().filter(|&(_, hc)| hc.is_whitespace())?;
            while h.next_if(|&(_, c)| c.is_whitespace()).is_some() {}
        } else {
            let (i, hc) = h.next().filter(|&(_, hc)| hc == nc)?;
            end = i + hc.len_utf8();
        }
    }
    Some(end)
}

fn echo(note: NoteMeta, passage: String, start_byte: Option<usize>) -> Echo {
    let day = note.day().map(|_| note.title.clone());
    let note_role = note.role.filter(|r| r == DAILY_ROLE || r == TOPIC_ROLE);
    Echo {
        note_id: note.id,
        note_title: note.title,
        note_role,
        day,
        passage,
        start_byte,
        note_updated_at: note.updated_at,
    }
}

/// Cosine similarity; 0 when either vector is zero.
fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na == 0.0 || nb == 0.0 {
        0.0
    } else {
        dot / (na * nb)
    }
}
