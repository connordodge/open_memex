//! Hybrid search: FTS5 (BM25) + optional vector (`vec0`) fused via
//! Reciprocal Rank Fusion.
//!
//! After fusion, every hit on a daily note is expanded into the topic notes
//! that transclude one of the hit chunk's blocks (D25, Spec TD5). Transcluded
//! text is never indexed into the topic, so this is the only way a topic is
//! found through the day's words.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::embedder::Embedder;
use crate::link_extractor::{parse_transclusions, TransclusionToken};
use crate::links::{daily_note_id_for_title, LinkKind};
use crate::transclusion::resolve_span;
use crate::Result;

const RRF_K: f32 = 60.0;
const FTS_OVERSAMPLE: i64 = 5;
const VEC_OVERSAMPLE: i64 = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SearchMode {
    #[default]
    Hybrid,
    Fts,
    Vector,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchFilters {
    /// All listed tags must be present on a note for its chunks to be returned.
    pub tags_all: Vec<String>,
    /// Restrict to a specific note id (useful for "search within a note").
    pub note_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub chunk_id: String,
    pub note_id: String,
    pub note_title: String,
    pub snippet: String,
    pub score: f32,
    pub ord: i64,
    /// The daily-note date a hit came through, set only on hits expanded
    /// through a transclusion (D25). Absent from JSON when `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResults {
    pub hits: Vec<SearchHit>,
    pub truncated: bool,
}

pub struct SearchOptions<'a> {
    pub query: &'a str,
    pub k: usize,
    pub mode: SearchMode,
    pub filters: SearchFilters,
    pub embedder: Option<&'a dyn Embedder>,
}

pub fn search(conn: &Connection, opts: SearchOptions<'_>) -> Result<SearchResults> {
    let q = opts.query.trim();
    if q.is_empty() {
        return Ok(SearchResults {
            hits: Vec::new(),
            truncated: false,
        });
    }

    let want_fts = matches!(opts.mode, SearchMode::Hybrid | SearchMode::Fts);
    let want_vec = matches!(opts.mode, SearchMode::Hybrid | SearchMode::Vector)
        && opts.embedder.is_some();

    let oversample = (opts.k as i64) * (FTS_OVERSAMPLE.max(VEC_OVERSAMPLE));

    let fts_ranked: Vec<(String, i64)> = if want_fts {
        fts_search(conn, q, oversample)?
    } else {
        Vec::new()
    };

    let vec_ranked: Vec<(String, i64)> = if want_vec {
        let embedder = opts.embedder.expect("checked");
        let q_vec = embedder
            .embed_batch(&[q.to_string()])?
            .into_iter()
            .next()
            .unwrap_or_default();
        if q_vec.is_empty() {
            Vec::new()
        } else {
            vec_search(conn, &q_vec, oversample).unwrap_or_default()
        }
    } else {
        Vec::new()
    };

    // RRF fuse
    use std::collections::HashMap;
    let mut score_by_chunk: HashMap<String, f32> = HashMap::new();
    for (cid, rank) in &fts_ranked {
        *score_by_chunk.entry(cid.clone()).or_insert(0.0) += 1.0 / (RRF_K + (*rank as f32));
    }
    for (cid, rank) in &vec_ranked {
        *score_by_chunk.entry(cid.clone()).or_insert(0.0) += 1.0 / (RRF_K + (*rank as f32));
    }

    let mut fused: Vec<(String, f32)> = score_by_chunk.into_iter().collect();
    fused.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    if fused.is_empty() {
        return Ok(SearchResults {
            hits: Vec::new(),
            truncated: false,
        });
    }

    let mut hits = Vec::new();
    for (chunk_id, score) in fused.iter() {
        if let Some(hit) = enrich_hit(conn, chunk_id, *score, &opts.filters)? {
            hits.push(hit);
            if hits.len() >= opts.k {
                break;
            }
        }
    }
    let truncated = hits.len() >= opts.k && fused.len() > hits.len();
    let (hits, dropped) = expand_transclusions(conn, hits, opts.k, &opts.filters)?;
    Ok(SearchResults {
        hits,
        truncated: truncated || dropped,
    })
}

/// A topic note found through a transclusion of a daily-note hit's blocks.
/// `chunk_id`, `ord` and `snippet` are the topic's own chunk that holds the
/// covering `![[…]]` token.
struct Expansion {
    note_id: String,
    note_title: String,
    chunk_id: String,
    ord: i64,
    snippet: String,
}

/// Expands each daily-note hit in `direct` (already filtered, ranked and
/// capped at `k`) into the topic notes that transclude one of its blocks
/// (D25). Each expanded hit sits right after its source hit (after earlier
/// expansions of the same source), with the source's score and
/// `via: <date>`. A (topic, date) pair is expanded once, after its first
/// source hit. A topic appears as a direct hit or as expanded hits, never
/// both: a topic already shown as a direct hit above the source is not
/// expanded, and a topic already shown as an expanded hit drops its own
/// lower-ranked direct hit. The total is capped at `k`. Returns the hits and
/// whether the cap dropped any.
fn expand_transclusions(
    conn: &Connection,
    direct: Vec<SearchHit>,
    k: usize,
    filters: &SearchFilters,
) -> Result<(Vec<SearchHit>, bool)> {
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut shown_direct: HashSet<String> = HashSet::new();
    let mut shown_expanded: HashSet<String> = HashSet::new();
    let mut pairs: HashSet<(String, String)> = HashSet::new();
    for source in direct {
        if shown_expanded.contains(&source.note_id) {
            continue;
        }
        let topics = transcluding_topics(conn, &source, filters)?;
        shown_direct.insert(source.note_id.clone());
        let date = source.note_title.clone();
        let score = source.score;
        hits.push(source);
        for t in topics {
            if shown_direct.contains(&t.note_id) || !pairs.insert((t.note_id.clone(), date.clone()))
            {
                continue;
            }
            shown_expanded.insert(t.note_id.clone());
            hits.push(SearchHit {
                chunk_id: t.chunk_id,
                note_id: t.note_id,
                note_title: t.note_title,
                snippet: t.snippet,
                score,
                ord: t.ord,
                via: Some(date.clone()),
            });
        }
    }
    let dropped = hits.len() > k;
    hits.truncate(k);
    Ok((hits, dropped))
}

/// The topic notes (passing `filters`) with a transclusion covering a block
/// of `hit`'s daily note that overlaps the hit chunk's byte range, in title
/// order. Empty unless `hit` is on the daily note of its title's date and
/// its chunk has a stored range (NULL ranges never expand).
fn transcluding_topics(
    conn: &Connection,
    hit: &SearchHit,
    filters: &SearchFilters,
) -> Result<Vec<Expansion>> {
    let (cs, ce): (Option<i64>, Option<i64>) = conn.query_row(
        "SELECT start_byte, end_byte FROM chunks WHERE id = ?",
        params![hit.chunk_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let (Some(cs), Some(ce)) = (cs, ce) else {
        return Ok(Vec::new());
    };
    let date = hit.note_title.as_str();
    if daily_note_id_for_title(conn, date)?.as_deref() != Some(hit.note_id.as_str()) {
        return Ok(Vec::new());
    }

    // The ords of the day's blocks that overlap the chunk: block [s, e)
    // overlaps chunk [cs, ce) iff s < ce && cs < e.
    let mut hit_ords: Vec<i64> = Vec::new();
    let mut stmt =
        conn.prepare_cached("SELECT ord, start_byte, end_byte FROM blocks WHERE note_id = ?")?;
    let mut rows = stmt.query(params![hit.note_id])?;
    while let Some(r) = rows.next()? {
        let (ord, s, e): (i64, i64, i64) = (r.get(0)?, r.get(1)?, r.get(2)?);
        if s < ce && cs < e {
            hit_ords.push(ord);
        }
    }
    if hit_ords.is_empty() {
        return Ok(Vec::new());
    }

    let mut stmt = conn.prepare_cached(
        "SELECT DISTINCT n.id, n.title, n.content_md
           FROM links l JOIN notes n ON n.id = l.from_note_id
          WHERE l.link_kind = ? AND l.link_text = ?
          ORDER BY n.title, n.id",
    )?;
    let topics = stmt
        .query_map(params![LinkKind::FROM_DAY, date], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut out = Vec::new();
    for (note_id, note_title, body) in topics {
        let mut covering = None;
        for token in parse_transclusions(&body) {
            if token.date == date && covers(conn, &hit.note_id, &token, &hit_ords)? {
                covering = Some(token);
                break;
            }
        }
        let Some(token) = covering else {
            continue;
        };
        if !passes_filters(conn, &note_id, filters) {
            continue;
        }
        // The topic chunk holding the token, else its first chunk (a topic
        // whose chunks have no stored range yet).
        let chunk: Option<(String, i64, String)> = conn
            .query_row(
                "SELECT id, ord, content FROM chunks WHERE note_id = ?1
                  ORDER BY (start_byte <= ?2 AND ?2 < end_byte) DESC, ord
                  LIMIT 1",
                params![note_id, token.start as i64],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((chunk_id, ord, content)) = chunk else {
            continue;
        };
        out.push(Expansion {
            note_id,
            note_title,
            chunk_id,
            ord,
            snippet: snippet(&content, 280),
        });
    }
    Ok(out)
}

/// Whether `token` transcludes one of `hit_ords` of daily note
/// `daily_note_id`. Its block span comes from the one C4 resolver
/// ([`resolve_span`], D28); a token whose endpoint block no longer exists
/// covers nothing.
fn covers(
    conn: &Connection,
    daily_note_id: &str,
    token: &TransclusionToken,
    hit_ords: &[i64],
) -> Result<bool> {
    let span = resolve_span(conn, daily_note_id, &token.from, token.to.as_deref())?;
    Ok(span.is_some_and(|(lo, hi)| hit_ords.iter().any(|&ord| lo <= ord && ord <= hi)))
}

fn fts_search(conn: &Connection, q: &str, k: i64) -> Result<Vec<(String, i64)>> {
    // FTS5 MATCH, ranked by bm25.
    let mut stmt = conn.prepare(
        "SELECT chunk_id FROM chunk_fts WHERE chunk_fts MATCH ? ORDER BY bm25(chunk_fts) LIMIT ?",
    )?;
    let mut rows = stmt.query(params![sanitize_match(q), k])?;
    let mut out = Vec::new();
    let mut rank: i64 = 1;
    while let Some(r) = rows.next()? {
        out.push((r.get::<_, String>(0)?, rank));
        rank += 1;
    }
    Ok(out)
}

fn vec_search(conn: &Connection, q_vec: &[f32], k: i64) -> Result<Vec<(String, i64)>> {
    let mut bytes = Vec::with_capacity(q_vec.len() * 4);
    for f in q_vec {
        bytes.extend_from_slice(&f.to_le_bytes());
    }
    let mut stmt = conn.prepare(
        "SELECT chunk_id FROM chunk_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance",
    )?;
    let mut rows = stmt.query(params![bytes, k])?;
    let mut out = Vec::new();
    let mut rank: i64 = 1;
    while let Some(r) = rows.next()? {
        out.push((r.get::<_, String>(0)?, rank));
        rank += 1;
    }
    Ok(out)
}

fn enrich_hit(
    conn: &Connection,
    chunk_id: &str,
    score: f32,
    filters: &SearchFilters,
) -> Result<Option<SearchHit>> {
    let row: Option<(String, String, i64, String, String)> = conn
        .query_row(
            "SELECT c.id, c.note_id, c.ord, c.content, n.title
             FROM chunks c JOIN notes n ON n.id = c.note_id
             WHERE c.id = ?",
            params![chunk_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .ok();

    let Some((cid, nid, ord, content, title)) = row else {
        return Ok(None);
    };

    if !passes_filters(conn, &nid, filters) {
        return Ok(None);
    }

    Ok(Some(SearchHit {
        chunk_id: cid,
        note_id: nid,
        note_title: title,
        snippet: snippet(&content, 280),
        score,
        ord,
        via: None,
    }))
}

/// Whether note `nid` satisfies `filters` (direct and expanded hits alike).
fn passes_filters(conn: &Connection, nid: &str, filters: &SearchFilters) -> bool {
    if let Some(req) = &filters.note_id {
        if nid != req {
            return false;
        }
    }
    if !filters.tags_all.is_empty() {
        for tag in &filters.tags_all {
            let has: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM tags WHERE note_id = ? AND tag = ?",
                    params![nid, tag],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            if has == 0 {
                return false;
            }
        }
    }
    true
}

fn snippet(content: &str, max_chars: usize) -> String {
    if content.chars().count() <= max_chars {
        return content.to_string();
    }
    let mut out = String::new();
    for (i, c) in content.chars().enumerate() {
        if i >= max_chars {
            out.push('…');
            break;
        }
        out.push(c);
    }
    out
}

/// Escape FTS5 query special characters for MATCH safety. We accept plain
/// keyword input from agents/users; we don't expose FTS5's column / phrase
/// operators directly.
fn sanitize_match(q: &str) -> String {
    // Quote each whitespace-separated token to avoid syntax errors on ',
    // -, etc., and join with spaces (implicit AND).
    q.split_whitespace()
        .filter(|t| !t.is_empty())
        .map(|t| {
            let mut s = String::from("\"");
            for ch in t.chars() {
                if ch == '"' {
                    s.push_str("\"\"");
                } else {
                    s.push(ch);
                }
            }
            s.push('"');
            s
        })
        .collect::<Vec<_>>()
        .join(" ")
}
