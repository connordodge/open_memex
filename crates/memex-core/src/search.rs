//! Hybrid search: FTS5 (BM25) + optional vector (`vec0`) fused via
//! Reciprocal Rank Fusion.

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use crate::embedder::Embedder;
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
    Ok(SearchResults { hits, truncated })
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

    if let Some(req) = &filters.note_id {
        if &nid != req {
            return Ok(None);
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
                return Ok(None);
            }
        }
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
