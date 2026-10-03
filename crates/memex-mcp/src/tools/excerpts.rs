//! MCP tools for excerpts (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `excerpts_router`.

use rmcp::handler::server::wrapper::Parameters;
use rmcp::tool_router;
use schemars::JsonSchema;
use serde::Deserialize;

use super::Memex;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddExcerptParams {
    /// The topic note id (ULID); the note must be `role: topic`.
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    pub date: String,
    /// Block ids of that daily note to file into the topic.
    pub block_ids: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RemoveExcerptParams {
    /// The topic note id (ULID).
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    pub date: String,
    /// The transclusion's endpoint block ids: one id, or `[from, to]`.
    pub block_ids: Vec<String>,
}

#[tool_router(router = excerpts_router, vis = "pub(crate)")]
impl Memex {}

// Test-author skeleton (#10): the implementer moves these into the
// `#[tool_router]` impl above as `#[tool]`s (`Caller::Agent`), returning
// `{"vault_id","topic_note_id","version"}` or the C1 error object.
impl Memex {
    pub async fn add_excerpt(&self, params: Parameters<AddExcerptParams>) -> String {
        let _ = params;
        unimplemented!("add_excerpt tool (#10)")
    }

    pub async fn remove_excerpt(&self, params: Parameters<RemoveExcerptParams>) -> String {
        let _ = params;
        unimplemented!("remove_excerpt tool (#10)")
    }
}
