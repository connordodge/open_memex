//! Open Memex core library.

pub mod error;
pub mod schema;
pub mod vault;
pub mod notes;

pub use error::{MemexError, Result};
pub use notes::{Note, NoteId};
pub use vault::Vault;
