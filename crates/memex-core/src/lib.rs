//! Open Memex core library.

pub mod chunker;
pub mod embedder;
pub mod error;
pub mod graph;
pub mod indexer;
pub mod link_extractor;
pub mod links;
pub mod notes;
pub mod schema;
pub mod search;
pub mod tags;
pub mod vault;

pub use error::{MemexError, Result};
pub use notes::{Note, NoteId};
pub use search::{search, SearchFilters, SearchHit, SearchMode, SearchOptions, SearchResults};
pub use vault::{now_unix_ms, Vault};
