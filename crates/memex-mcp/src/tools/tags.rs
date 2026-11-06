//! MCP tools for tags and Note footer topics (Spec #234 R38-R40, D10, D18,
//! D21). Thin over `memex_core::tags` and `memex_core::footer`: the rules live
//! in core.

use rmcp::handler::server::wrapper::Parameters;
use schemars::JsonSchema;
use serde::Deserialize;

use super::Memex;

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListTagsParams {}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct TagNoteParams {
    /// The note id (ULID).
    pub note_id: String,
    /// A tag from `list_tags`.
    pub tag: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct UntagNoteParams {
    /// The note id (ULID).
    pub note_id: String,
    /// A tag from the note's `agent_tags`.
    pub tag: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddFooterTopicParams {
    /// The note id (ULID) of the note whose Note footer gets the chip.
    pub note_id: String,
    /// The topic note id (ULID); the note must be `role: topic`.
    pub topic_note_id: String,
}

impl Memex {
    pub async fn list_tags(&self, _params: Parameters<ListTagsParams>) -> String {
        "{}".to_string()
    }

    pub async fn tag_note(&self, _params: Parameters<TagNoteParams>) -> String {
        "{}".to_string()
    }

    pub async fn untag_note(&self, _params: Parameters<UntagNoteParams>) -> String {
        "{}".to_string()
    }

    pub async fn add_footer_topic(&self, _params: Parameters<AddFooterTopicParams>) -> String {
        "{}".to_string()
    }
}
