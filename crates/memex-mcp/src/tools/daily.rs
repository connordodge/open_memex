//! MCP tools for daily notes (architect ruling D7). This area's tools go in
//! the impl below; `Memex::new` already composes `daily_router`.

use rmcp::handler::server::wrapper::Parameters;
use rmcp::tool_router;
use schemars::JsonSchema;
use serde::Deserialize;

use super::Memex;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AppendToDailyNoteParams {
    /// The text to append, verbatim.
    pub text: String,
    /// The day, YYYY-MM-DD; omit for today (local time).
    #[serde(default)]
    pub date: Option<String>,
}

#[tool_router(router = daily_router, vis = "pub(crate)")]
impl Memex {}

// Skeleton for #12 (test-first): the implementer registers it as a tool in
// `daily_router` above.
impl Memex {
    pub async fn append_to_daily_note(
        &self,
        params: Parameters<AppendToDailyNoteParams>,
    ) -> String {
        let _ = params;
        unimplemented!("#12: append_to_daily_note")
    }
}
