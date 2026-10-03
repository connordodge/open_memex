//! Transclusion: parsing and rendering embedded blocks.
//!
//! Parsing lives beside wikilink parsing in `link_extractor` (D13) and is
//! re-exported here; rendering resolves a token to the live text of its
//! blocks, or to the stub `removed from <date>` (CONTRACTS C4).

use rusqlite::Connection;

pub use crate::link_extractor::{parse_transclusions, TransclusionToken};
use crate::Result;

/// A transclusion token resolved against the vault.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedExcerpt {
    pub date: String,
    pub from: String,
    pub to: Option<String>,
    /// The blocks' text joined with `\n`, or `removed from <date>`.
    pub text: String,
    /// `true` when the daily note or an endpoint block is gone.
    pub removed: bool,
}

/// Renders one token by the C4 render rule.
pub fn render(_conn: &Connection, _token: &TransclusionToken) -> Result<RenderedExcerpt> {
    unimplemented!("WI #9: render a transclusion token")
}

/// Renders every transclusion token in `body`, in order.
pub fn render_all(_conn: &Connection, _body: &str) -> Result<Vec<RenderedExcerpt>> {
    unimplemented!("WI #9: render every transclusion token in a body")
}
