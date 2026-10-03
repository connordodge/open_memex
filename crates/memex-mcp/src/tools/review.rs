//! MCP tools for reviews (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `review_router`.

use memex_core::blocks::{Block, SnapshotBlock};
use memex_core::review::{self as core_review, ChangeEntry};
use memex_core::{MemexError, SystemClock};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_router};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{json, Value};

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

/// Every failure of these tools as the C1 error object
/// (`{"error":{"code","message",…rule fields}}`), `not_found` and
/// `invalid_date` included. The `op.sub` codes of `tools::err_from` stay with
/// the tools that had them before C1.
fn c1_error(e: &MemexError) -> String {
    e.to_error_json().to_string()
}

/// A current block as the tools show it: `{id, source, text}`.
fn block_json(b: &Block) -> Value {
    json!({ "id": b.block_id, "source": b.source, "text": b.text })
}

/// A removed snapshot block: `{id, text}` (a snapshot has no source).
fn removed_json(b: &SnapshotBlock) -> Value {
    json!({ "id": b.block_id, "text": b.text })
}

// Every tool acts as the agent (`Caller::Agent`): none of them writes a note.
#[tool_router(router = review_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "List the daily notes that still need a review: \
        state `Unreviewed` or `Changed since review`, oldest date first, \
        skipping days with nothing written above the Topics footer. Each day \
        has date, note_id, state, content_version and reviewed_content_version \
        (null when never reviewed).")]
    pub async fn list_unreviewed_days(
        &self,
        _params: Parameters<ListUnreviewedDaysParams>,
    ) -> String {
        let vault = self.state.vault.lock().await;
        match core_review::list_unreviewed_days(&vault) {
            Ok(days) => {
                let days: Vec<Value> = days
                    .iter()
                    .map(|d| {
                        json!({
                            "date": d.date,
                            "note_id": d.note_id,
                            "state": d.state.as_str(),
                            "content_version": d.content_version,
                            "reviewed_content_version": d.reviewed_content_version,
                        })
                    })
                    .collect();
                json!({ "vault_id": vault.vault_id(), "days": days }).to_string()
            }
            Err(e) => c1_error(&e),
        }
    }

    #[tool(description = "What changed in a daily note (date YYYY-MM-DD) \
        since its last review: `added` and `changed` blocks ({id, source, \
        text}, current text) and `removed` blocks ({id, text}, as last \
        reviewed). A never-reviewed day returns every block as added. Also \
        returns content_version: pass it as `version` to mark_day_reviewed.")]
    pub async fn get_daily_note_changes(
        &self,
        params: Parameters<GetDailyNoteChangesParams>,
    ) -> String {
        let vault = self.state.vault.lock().await;
        match core_review::get_daily_note_changes(&vault, &params.0.date) {
            Ok(c) => json!({
                "vault_id": vault.vault_id(),
                "date": c.date,
                "note_id": c.note_id,
                "content_version": c.content_version,
                "added": c.added.iter().map(block_json).collect::<Vec<_>>(),
                "changed": c.changed.iter().map(block_json).collect::<Vec<_>>(),
                "removed": c.removed.iter().map(removed_json).collect::<Vec<_>>(),
            })
            .to_string(),
            Err(e) => c1_error(&e),
        }
    }

    #[tool(description = "Mark a daily note (date YYYY-MM-DD) reviewed at \
        `version`, the content_version from get_daily_note_changes; if the \
        person edited the day since, this fails with review_stale. `changes` \
        has one entry per note you touched, including the daily note itself: \
        {note_id, bullets} with 1 to 3 bullets, each one line of plain \
        markdown, at most 200 characters, without a leading \"- \". Any \
        invalid entry rejects the whole call (change_entries_invalid) and \
        nothing is recorded.")]
    pub async fn mark_day_reviewed(&self, params: Parameters<MarkDayReviewedParams>) -> String {
        let MarkDayReviewedParams {
            date,
            version,
            changes,
        } = params.0;
        let changes: Vec<ChangeEntry> = changes
            .into_iter()
            .map(|c| ChangeEntry {
                note_id: c.note_id,
                bullets: c.bullets,
            })
            .collect();
        let mut vault = self.state.vault.lock().await;
        match core_review::mark_day_reviewed(&mut vault, &date, version, &changes, &SystemClock) {
            Ok(r) => json!({
                "vault_id": vault.vault_id(),
                "date": r.date,
                "note_id": r.note_id,
                "state": r.state.as_str(),
                "content_version": r.content_version,
                "reviewed_content_version": r.reviewed_content_version,
                "reviewed_at": r.reviewed_at,
            })
            .to_string(),
            Err(e) => c1_error(&e),
        }
    }
}
