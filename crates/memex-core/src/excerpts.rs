//! Excerpts.

use serde_json::{Map, Value};

use crate::notes::Note;
use crate::vault::Vault;
use crate::Result;

/// Transclusion fields merged into the top level of MCP `get_note` and CLI
/// `memex get` (architect ruling D7). Empty for a note without excerpts;
/// filled by the excerpts Work Item (#10).
pub fn note_transclusion_fields(_vault: &Vault, _note: &Note) -> Result<Map<String, Value>> {
    Ok(Map::new())
}
