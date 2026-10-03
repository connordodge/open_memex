//! MCP tools for reviews (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `review_router`.

use rmcp::handler::server::wrapper::Parameters;
use rmcp::tool_router;
use schemars::JsonSchema;
use serde::Deserialize;

use super::Memex;

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListUnreviewedDaysParams {}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetDailyNoteChangesParams {
    /// The day, `YYYY-MM-DD`.
    pub date: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ChangeEntryParams {
    /// The id of a note touched in this run.
    pub note_id: String,
    /// 1 to 3 bullets saying what was done.
    pub bullets: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MarkDayReviewedParams {
    /// The day, `YYYY-MM-DD`.
    pub date: String,
    /// The content version fetched with `get_daily_note_changes`.
    pub version: i64,
    /// One entry per note touched, including the daily note itself.
    pub changes: Vec<ChangeEntryParams>,
}

// Skeleton (WI #11 test author): the implementer adds `#[tool(...)]` to each
// method and fills its body. Every tool acts as `Caller::Agent`.
#[tool_router(router = review_router, vis = "pub(crate)")]
impl Memex {
    pub async fn list_unreviewed_days(
        &self,
        _params: Parameters<ListUnreviewedDaysParams>,
    ) -> String {
        todo!("WI #11: list_unreviewed_days tool")
    }

    pub async fn get_daily_note_changes(
        &self,
        _params: Parameters<GetDailyNoteChangesParams>,
    ) -> String {
        todo!("WI #11: get_daily_note_changes tool")
    }

    pub async fn mark_day_reviewed(&self, _params: Parameters<MarkDayReviewedParams>) -> String {
        todo!("WI #11: mark_day_reviewed tool")
    }
}
