//! The Command palette's note-text search (Spec #59 requirements 34-38,
//! architect D10, D11): hybrid search with the meaning state the app shows,
//! each hit enriched with its byte offset, note role, day and `updated_at`.
//! The `memex search` CLI and the vault server search route both call
//! [`note_search`], so the rules exist once.

use std::sync::atomic::{AtomicBool, Ordering};

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::daily::parse_iso_date;
use crate::embedder::Embedder;
use crate::search::{
    embed_query, search_with_query_vec, SearchFilters, SearchHit, SearchMode, SearchOptions,
};
use crate::vectors::{embed_missing, ConnLease};
use crate::{MemexError, Result};

const DAILY_ROLE: &str = "daily";
const TOPIC_ROLE: &str = "topic";

/// What the caller can offer for meaning search.
pub enum SearchEmbedder<'a> {
    /// A loaded (or lazily loading) local embedder.
    Ready(&'a dyn Embedder),
    /// The local model is not in the cache and the caller may not fetch it.
    NotDownloaded,
    /// Embeddings are off (a vault server run without `--with-embeddings`).
    Off,
}

/// Whether the vector arm ran, and if not, why (Spec #59 requirement 34).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Semantic {
    /// The query was embedded and the vector arm ran.
    On,
    /// Keyword only: no cached model.
    ModelNotDownloaded,
    /// Keyword only: embeddings are off.
    EmbeddingsOff,
    /// Keyword only: the embedder failed to load or embed.
    Unavailable,
}

/// One answer of [`note_search`]. Field names are a wire contract: the CLI
/// and the vault server print it as JSON.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteSearch {
    pub query: String,
    pub semantic: Semantic,
    pub hits: Vec<NoteSearchHit>,
    pub truncated: bool,
}

/// One hit. Every `Option` serializes as `null` when `None`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteSearchHit {
    pub note_id: String,
    pub note_title: String,
    /// `daily`, `topic`, or `None` for any other note.
    pub note_role: Option<String>,
    /// The ISO date of a daily note, else `None`.
    pub day: Option<String>,
    pub chunk_id: String,
    pub snippet: String,
    /// The chunk's `chunks.start_byte`, or `None` when it has none.
    pub start_byte: Option<usize>,
    /// The daily-note date a transcluded hit came through, else `None`.
    pub via: Option<String>,
    /// The note's `updated_at`, in ms since the epoch.
    pub note_updated_at: i64,
}

/// Searches note text for the Command palette, always in hybrid mode: the
/// hits are `search::search`'s (FTS and kNN fused, daily-note hits expanded
/// into the topics that transclude them), capped at `limit`, with
/// `truncated` set when more matched.
///
/// - `Off` and `NotDownloaded` run FTS only, as `embeddings_off` and
///   `model_not_downloaded`.
/// - `Ready` first embeds up to `pending_cap` chunks that have no vector
///   (`vectors::embed_missing`; 0 skips it), then embeds the query, then
///   runs FTS and kNN (`on`). A DB error while embedding pending chunks skips
///   that step; an embedder error anywhere answers FTS hits as `unavailable`.
///   Neither is an `Err`.
/// - An empty or whitespace query answers no hits, with no embedder call.
///
/// No lease is held across inference (D10): the query vector is computed
/// first, then one lease covers FTS, kNN, enrichment and expansion.
pub fn note_search<L: ConnLease>(
    conn: &mut L,
    query: &str,
    limit: usize,
    embedder: SearchEmbedder<'_>,
    pending_cap: usize,
) -> Result<NoteSearch> {
    let (semantic, ready) = match embedder {
        SearchEmbedder::Ready(e) => (Semantic::On, Some(e)),
        SearchEmbedder::NotDownloaded => (Semantic::ModelNotDownloaded, None),
        SearchEmbedder::Off => (Semantic::EmbeddingsOff, None),
    };
    let q = query.trim();
    if q.is_empty() {
        return Ok(NoteSearch {
            query: query.to_string(),
            semantic,
            hits: Vec::new(),
            truncated: false,
        });
    }

    let (semantic, q_vec) = match ready {
        Some(e) => query_vector(conn, e, q, pending_cap),
        None => (semantic, None),
    };

    let opts = SearchOptions {
        query: q,
        k: limit,
        mode: SearchMode::Hybrid,
        filters: SearchFilters::default(),
        embedder: None,
    };
    let (hits, truncated) = conn.lease(|c| {
        let found = search_with_query_vec(c, &opts, q_vec.as_deref())?;
        let hits = found
            .hits
            .into_iter()
            .map(|h| enrich(c, h))
            .collect::<Result<Vec<_>>>()?;
        Ok((hits, found.truncated))
    })?;
    Ok(NoteSearch {
        query: query.to_string(),
        semantic,
        hits,
        truncated,
    })
}

/// D11: embeds up to `pending_cap` pending chunks (best effort), then the
/// query, with no lease held across either inference. Answers `On` with the
/// query vector, or `Unavailable` with none when the embedder failed.
fn query_vector<L: ConnLease>(
    conn: &mut L,
    embedder: &dyn Embedder,
    q: &str,
    pending_cap: usize,
) -> (Semantic, Option<Vec<f32>>) {
    if pending_cap > 0 {
        let watched = Watched {
            inner: embedder,
            failed: AtomicBool::new(false),
        };
        if let Err(e) = embed_missing(conn, &watched, None, 0, pending_cap) {
            if watched.failed.load(Ordering::SeqCst) || is_embedder_error(&e) {
                return (Semantic::Unavailable, None);
            }
            // A DB error (SQLITE_BUSY, say): skip the pending chunks.
        }
    }
    match embed_query(embedder, q) {
        Ok(Some(v)) => (Semantic::On, Some(v)),
        Ok(None) | Err(_) => (Semantic::Unavailable, None),
    }
}

fn is_embedder_error(e: &MemexError) -> bool {
    matches!(
        e,
        MemexError::EmbedderInit(_) | MemexError::EmbedderInfer(_) | MemexError::ModelNotDownloaded
    )
}

/// Passes calls through to `inner` and records whether one failed, so an
/// [`embed_missing`] error is told apart as the embedder's or the DB's.
struct Watched<'a> {
    inner: &'a dyn Embedder,
    failed: AtomicBool,
}

impl Embedder for Watched<'_> {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let out = self.inner.embed_batch(texts);
        if out.is_err() {
            self.failed.store(true, Ordering::SeqCst);
        }
        out
    }
}

/// Adds the chunk's `start_byte` and the note's role, day and `updated_at`
/// to a `search::search` hit.
fn enrich(c: &Connection, hit: SearchHit) -> Result<NoteSearchHit> {
    let start_byte: Option<i64> = c
        .query_row(
            "SELECT start_byte FROM chunks WHERE id = ?",
            params![hit.chunk_id],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let (title, role, updated_at): (String, Option<String>, i64) = c.query_row(
        "SELECT title,
                CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END,
                updated_at
           FROM notes WHERE id = ?",
        params![hit.note_id],
        // A non-text role (a number, say) is no role.
        |r| Ok((r.get(0)?, r.get(1).unwrap_or(None), r.get(2)?)),
    )?;
    let day = (role.as_deref() == Some(DAILY_ROLE) && parse_iso_date(&title).is_ok())
        .then(|| title.clone());
    let note_role = role.filter(|r| r == DAILY_ROLE || r == TOPIC_ROLE);
    Ok(NoteSearchHit {
        note_id: hit.note_id,
        note_title: hit.note_title,
        note_role,
        day,
        chunk_id: hit.chunk_id,
        snippet: hit.snippet,
        start_byte: start_byte.and_then(|s| usize::try_from(s).ok()),
        via: hit.via,
        note_updated_at: updated_at,
    })
}
