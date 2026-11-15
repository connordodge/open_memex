//! Open Memex core library.

pub mod agents;
pub mod app_reads;
pub mod backup;
pub mod canvas;
pub mod chunker;
pub mod echoes;
pub mod embedder;
pub mod error;
pub mod fs_guard;
pub mod graph;
pub mod guide;
pub mod indexer;
pub mod link_extractor;
pub mod links;
pub mod note_edits;
pub mod notes;
pub mod schema;
pub mod search;
pub mod tags;
pub mod vault;
pub mod words;

// Registered up front (architect ruling D5); each feature fills its own file.
pub mod blocks;
pub mod caller;
pub mod daily;
pub mod excerpts;
pub mod feedback;
pub mod filing;
pub mod footer;
pub mod review;
pub mod smart_folders;
pub mod transclusion;
pub mod vault_settings;
pub mod vectors;

pub use caller::Caller;
pub use canvas::{
    CallerClock, Canvas, CanvasDetail, CanvasEdge, CanvasId, CanvasNode, CanvasSummary, Clock,
    SystemClock,
};
pub use chrono::FixedOffset;
pub use error::{MemexError, Result};
pub use notes::{Note, NoteId};
pub use search::{search, SearchFilters, SearchHit, SearchMode, SearchOptions, SearchResults};
pub use vault::{now_unix_ms, Vault};
