//! MCP tools for Feedback, the Vault Guide and block filing (Spec #233 R39-R41).
//! `Memex::new` composes `feedback_router`.

use memex_core::feedback::{self, Feedback};
use memex_core::filing::{self, DayFiling};
use memex_core::{daily, excerpts, guide, Caller, MemexError, NoteId};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::service::RequestContext;
use rmcp::{tool, tool_router, RoleServer};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::excerpts::ExcerptWritten;
use super::review::{c1_error, change_entries, ChangeEntryParams};
use super::{call_clock, Memex};

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct GetVaultGuideParams {}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct UpdateVaultGuideParams {
    /// The version from `get_vault_guide`.
    pub version: i64,
    /// The whole new text of the guide.
    pub content_md: String,
    /// 1 to 3 bullets saying what changed.
    pub bullets: Vec<String>,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListOpenFeedbackParams {}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ResolveFeedbackParams {
    /// The id from `list_open_feedback`: a ULID, or `tag-<n>`.
    pub id: String,
    /// One line for the person, at most 200 characters.
    pub reply: String,
    /// One entry per note touched while acting on this Feedback.
    #[serde(default)]
    pub changes: Vec<ChangeEntryParams>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RecordFeedbackParams {
    /// What the person said, stored verbatim; at most 2,000 characters.
    pub text: String,
    /// The note it is about, if any.
    pub note_id: Option<String>,
    /// The day it is about, `YYYY-MM-DD`, if any.
    pub date: Option<String>,
    /// One line for the person, at most 200 characters.
    pub reply: String,
    /// One entry per note touched while acting on this Feedback.
    #[serde(default)]
    pub changes: Vec<ChangeEntryParams>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetDayFilingParams {
    /// The day, `YYYY-MM-DD`.
    pub date: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RemoveExcerptBlockParams {
    /// The topic note id (ULID).
    pub topic_note_id: String,
    /// The daily note's date, YYYY-MM-DD.
    pub date: String,
    /// The block id to take out of the topic note's excerpts of that day.
    pub block_id: String,
}

/// Filing on the wire (the Contract in #256): core's read model plus the vault.
#[derive(Serialize)]
struct Filing<'a> {
    vault_id: &'a str,
    #[serde(flatten)]
    filing: DayFiling,
}

/// A write's answer: the Feedback row as JSON, or the C1 error object.
fn feedback_answer(result: memex_core::Result<Feedback>) -> String {
    match result {
        Ok(row) => serde_json::to_string(&row).unwrap_or_else(|e| c1_error(&MemexError::Json(e))),
        Err(e) => c1_error(&e),
    }
}

// Every tool acts as the agent. None of them records a Correction: those are
// the person's, and only their channel (the CLI and the hosted API) records one.
#[tool_router(router = feedback_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "Read the Vault Guide: this vault's framework and \
        decisions for filing, kept across reviews. The first call creates it \
        with empty `## Framework` and `## Decisions` sections. Returns note_id, \
        version and content_md; pass version to update_vault_guide.")]
    async fn get_vault_guide(
        &self,
        _params: Parameters<GetVaultGuideParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        let clock = call_clock(&ctx);
        let mut vault = self.state.vault.lock().await;
        match guide::get_or_create(&mut vault, &*clock, self.state.embedder_ref()) {
            Ok(doc) => json!({
                "note_id": doc.note_id,
                "version": doc.version,
                "content_md": doc.content_md,
            })
            .to_string(),
            Err(e) => c1_error(&e),
        }
    }

    #[tool(
        description = "Replace the text of the Vault Guide with `content_md`. \
        Keep it short, about 200 lines. `version` is the one from \
        get_vault_guide; if the guide changed since, this fails with \
        version_conflict, so read it again. `bullets` say what changed: 1 to 3, \
        each one line of plain markdown, at most 200 characters, without a \
        leading \"- \"; they show in the guide's Activity tab, dated today. \
        Invalid bullets fail with change_entries_invalid. The previous text is \
        kept. A vault with no guide yet fails with not_found: call \
        get_vault_guide first. A failure writes nothing. Returns note_id and the \
        new version."
    )]
    async fn update_vault_guide(
        &self,
        params: Parameters<UpdateVaultGuideParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        let UpdateVaultGuideParams {
            version,
            content_md,
            bullets,
        } = params.0;
        let clock = call_clock(&ctx);
        let day = daily::today_with_clock(&*clock).to_string();
        let mut vault = self.state.vault.lock().await;
        match guide::update(
            &mut vault,
            version,
            &content_md,
            &bullets,
            &day,
            &*clock,
            self.state.embedder_ref(),
        ) {
            Ok(doc) => json!({ "note_id": doc.note_id, "version": doc.version }).to_string(),
            Err(e) => c1_error(&e),
        }
    }

    #[tool(description = "List the person's Open Feedback, oldest first: their \
        comments and their Corrections (changes they made to your filing), tag \
        Corrections included, with ids of the form `tag-<n>`. Returns {feedback: \
        [...]}. Each row has id, kind (comment or correction), source, note_id, \
        day, agent_change_id, text, correction (structured by its own `kind`, \
        null on a comment), status, reply, created_at, updated_at and handled_at.")]
    async fn list_open_feedback(&self, _params: Parameters<ListOpenFeedbackParams>) -> String {
        let vault = self.state.vault.lock().await;
        match feedback::list_open(&vault) {
            Ok(rows) => json!({ "feedback": rows }).to_string(),
            Err(e) => c1_error(&e),
        }
    }

    #[tool(description = "Mark one Open Feedback Handled, with `reply`: one \
        line for the person, at most 200 characters. `id` comes from \
        list_open_feedback (a ULID or `tag-<n>`). `changes`, optional, has one \
        entry per note you touched: {note_id, bullets}, with the bullet rules of \
        mark_day_reviewed; they show in each note's Activity tab, dated the \
        Feedback's day, else today. Returns the Handled Feedback. A not_found \
        means the person deleted it: carry on with the next one. The exception \
        is a `changes` entry naming a note that doesn't exist, which is also \
        not_found; the message says which. Also fails with feedback_handled \
        (already Handled), feedback_invalid (bad reply) or \
        change_entries_invalid. A failure writes nothing.")]
    async fn resolve_feedback(
        &self,
        params: Parameters<ResolveFeedbackParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        let ResolveFeedbackParams { id, reply, changes } = params.0;
        let changes = change_entries(changes);
        let clock = call_clock(&ctx);
        let mut vault = self.state.vault.lock().await;
        feedback_answer(feedback::resolve(
            &mut vault, &id, &reply, &changes, &*clock,
        ))
    }

    #[tool(description = "Store as Feedback something the person told you in \
        chat about your filing: `text` verbatim, at most 2,000 characters, \
        already Handled with `reply` (one line, at most 200 characters), source \
        chat. `note_id` and `date` (YYYY-MM-DD) say what it is about, if \
        anything. `changes`, optional, has one entry per note you touched: \
        {note_id, bullets}, with the bullet rules of mark_day_reviewed; they \
        show in each note's Activity tab, dated `date`, else today. Returns the \
        Feedback. Fails with feedback_invalid (bad text or reply), invalid_date, \
        not_found (a note that doesn't exist) or change_entries_invalid. A \
        failure stores nothing.")]
    async fn record_feedback(
        &self,
        params: Parameters<RecordFeedbackParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        let RecordFeedbackParams {
            text,
            note_id,
            date,
            reply,
            changes,
        } = params.0;
        let changes = change_entries(changes);
        let clock = call_clock(&ctx);
        let mut vault = self.state.vault.lock().await;
        feedback_answer(feedback::record_chat(
            &mut vault,
            &text,
            note_id.as_deref(),
            date.as_deref(),
            &reply,
            &changes,
            &*clock,
        ))
    }

    #[tool(description = "Where the blocks of the daily note for `date` \
        (YYYY-MM-DD) are filed. Returns vault_id, date, note_id, reviewed, \
        `topics` ({topic_note_id, title, blocks: [{id, text}]}, by title) and \
        `not_filed` ([{id, text}]: blocks of the last review in no topic note, \
        headings left out). A day never reviewed has reviewed false and empty \
        lists. Fails with not_found (no daily note that day) or invalid_date.")]
    async fn get_day_filing(&self, params: Parameters<GetDayFilingParams>) -> String {
        let vault = self.state.vault.lock().await;
        match filing::day_filing(&vault, &params.0.date) {
            Ok(filing) => serde_json::to_string(&Filing {
                vault_id: vault.vault_id(),
                filing,
            })
            .unwrap_or_else(|e| c1_error(&MemexError::Json(e))),
            Err(e) => c1_error(&e),
        }
    }

    #[tool(description = "Take one block of `date` (YYYY-MM-DD) out of a topic \
        note: every transclusion of that day covering `block_id` is split around \
        it or shrunk. Unlike remove_excerpt, the block need not be an endpoint. \
        The `## <date>` heading goes when nothing else is under it, and the \
        topic's chip in that day's Note footer once no excerpt of the day \
        remains (a chip the user added stays). Records no Correction. Returns \
        vault_id, topic_note_id and version (the topic note's new version). \
        Fails with role_rule (target not a topic note), not_found (unknown \
        topic, no daily note that day, or no excerpt covers the block), \
        block_not_found (not a block of that day), invalid_date, invalid_id or \
        version_conflict.")]
    async fn remove_excerpt_block(&self, params: Parameters<RemoveExcerptBlockParams>) -> String {
        let RemoveExcerptBlockParams {
            topic_note_id,
            date,
            block_id,
        } = params.0;
        let topic = match NoteId::parse(&topic_note_id) {
            Ok(id) => id,
            Err(e) => return c1_error(&e),
        };
        let mut vault = self.state.vault.lock().await;
        let written = match excerpts::remove_excerpt_block(
            &mut vault,
            &topic,
            &date,
            &block_id,
            Caller::Agent,
            self.state.embedder_ref(),
        ) {
            Ok(note) => note,
            Err(e) => return c1_error(&e),
        };
        serde_json::to_string(&ExcerptWritten::new(&vault, &written))
            .unwrap_or_else(|e| c1_error(&MemexError::Json(e)))
    }
}
