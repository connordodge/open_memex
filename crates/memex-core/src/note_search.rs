//! The Command palette's note-text search (Spec #59 requirements 34-38,
//! architect D10, D11): hybrid search with the meaning state the app shows,
//! each hit enriched with its byte offset, note role, day and `updated_at`.
//! The `memex search` CLI and the vault server search route both call
//! [`note_search`], so the rules exist once.

use serde::Serialize;

use crate::embedder::Embedder;
use crate::vectors::ConnLease;
use crate::Result;

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

/// Searches note text for the Command palette. Skeleton: no behavior yet.
pub fn note_search<L: ConnLease>(
    _conn: &mut L,
    _query: &str,
    _limit: usize,
    _embedder: SearchEmbedder<'_>,
    _pending_cap: usize,
) -> Result<NoteSearch> {
    Ok(NoteSearch {
        query: String::new(),
        semantic: Semantic::Unavailable,
        hits: Vec::new(),
        truncated: false,
    })
}
