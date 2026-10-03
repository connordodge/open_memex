//! Review.

use serde_json::{Map, Value};

use crate::notes::Note;
use crate::vault::Vault;
use crate::Result;

/// Review fields merged into the top level of MCP `get_note` and CLI
/// `memex get` (architect ruling D7). Empty for a note with no review state;
/// filled by the review Work Item (#11).
pub fn note_review_fields(_vault: &Vault, _note: &Note) -> Result<Map<String, Value>> {
    todo!("WI #5: stub returning an empty map")
}
