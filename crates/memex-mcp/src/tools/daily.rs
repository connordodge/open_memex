//! MCP tools for daily notes (architect ruling D7). This area's tools go in
//! the impl below; `Memex::new` already composes `daily_router`.

use memex_core::daily::{self, AppendOutcome, AppendSource};
use memex_core::{Clock, MemexError, SystemClock};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::service::RequestContext;
use rmcp::{tool, tool_router, RoleServer};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::{call_clock, Memex};

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AppendToDailyNoteParams {
    /// The text to append, verbatim.
    pub text: String,
    /// The day, YYYY-MM-DD; omit for today (local time).
    #[serde(default)]
    pub date: Option<String>,
}

/// An append on the wire, `vault_id` first: the MCP tool's result and the
/// `memex append` stdout line (CONTRACTS C2.12).
#[derive(Serialize)]
pub(crate) struct Appended<'a> {
    vault_id: &'a str,
    note_id: &'a str,
    date: String,
    block_ids: &'a [String],
    content_version: i64,
    version: i64,
    prior_state: &'static str,
}

impl<'a> Appended<'a> {
    pub(crate) fn new(vault_id: &'a str, outcome: &'a AppendOutcome) -> Self {
        Self {
            vault_id,
            note_id: outcome.note.id.as_str(),
            date: outcome.date.to_string(),
            block_ids: &outcome.block_ids,
            content_version: outcome.content_version,
            version: outcome.note.version,
            prior_state: outcome.prior_state.as_str(),
        }
    }
}

/// The C1 error object. This area's tools report every failure this way,
/// never with the `op.sub` codes of the older tools.
fn error(e: &MemexError) -> String {
    e.to_error_json().to_string()
}

#[tool_router(router = daily_router, vis = "pub(crate)")]
impl Memex {
    /// Appends to the daily note for `date`, or for today in the machine's
    /// local time. The MCP tool is [`Self::append_to_daily_note_tool`].
    pub async fn append_to_daily_note(
        &self,
        params: Parameters<AppendToDailyNoteParams>,
    ) -> String {
        self.append_to_daily_note_impl(params, &SystemClock).await
    }

    /// The `append_to_daily_note` tool: without `date` it appends to today
    /// on the call's clock ([`call_clock`]).
    #[tool(
        name = "append_to_daily_note",
        description = "Append text to the end of the user's daily note for \
        `date` (YYYY-MM-DD; default today, local time), above its Note footer, \
        creating the daily note when the day has none. The text is kept \
        verbatim; this is the only way to add to a daily note. Returns note_id, \
        date, block_ids (the new blocks), content_version, version and \
        prior_state: the day's review state just before the append \
        (`Unreviewed`, `Reviewed` or `Changed since review`). Fails with \
        invalid_argument for empty text, invalid_date, and title_conflict \
        (with existing_id) when a non-daily note already has that date as its \
        title."
    )]
    async fn append_to_daily_note_tool(
        &self,
        params: Parameters<AppendToDailyNoteParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        self.append_to_daily_note_impl(params, &*call_clock(&ctx))
            .await
    }

    async fn append_to_daily_note_impl(
        &self,
        params: Parameters<AppendToDailyNoteParams>,
        clock: &(dyn Clock + Sync),
    ) -> String {
        let AppendToDailyNoteParams { text, date } = params.0;
        if text.trim().is_empty() {
            let message = "nothing to append: `text` is empty";
            return json!({ "error": { "code": "invalid_argument", "message": message } })
                .to_string();
        }
        let mut vault = self.state.vault.lock().await;
        let outcome = match daily::append_to_daily_note(
            &mut vault,
            &text,
            date.as_deref(),
            AppendSource::Agent,
            clock,
            self.state.embedder_ref(),
        ) {
            Ok(outcome) => outcome,
            Err(e) => return error(&e),
        };
        serde_json::to_string(&Appended::new(vault.vault_id(), &outcome))
            .unwrap_or_else(|e| error(&MemexError::Json(e)))
    }
}
