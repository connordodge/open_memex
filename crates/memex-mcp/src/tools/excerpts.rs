//! MCP tools for excerpts (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `excerpts_router`.

use memex_core::excerpts;
use memex_core::{Caller, MemexError, Note, NoteId, Vault};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_router};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;

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

/// An excerpt write on the wire (CONTRACTS C2.4): the MCP tools' result and
/// the `memex excerpt rm` stdout line. `version` is the topic note's.
#[derive(Serialize)]
pub(crate) struct ExcerptWritten<'a> {
    vault_id: &'a str,
    topic_note_id: &'a str,
    version: i64,
}

impl<'a> ExcerptWritten<'a> {
    pub(crate) fn new(vault: &'a Vault, topic: &'a Note) -> Self {
        Self {
            vault_id: vault.vault_id(),
            topic_note_id: topic.id.as_str(),
            version: topic.version,
        }
    }
}

/// The C1 error object. This area's tools report every failure this way,
/// never with the `op.sub` codes of the older tools.
fn error(e: &MemexError) -> String {
    e.to_error_json().to_string()
}

/// The C1 `invalid_argument` object for an empty `block_ids`.
fn no_block_ids() -> String {
    json!({ "error": { "code": "invalid_argument", "message": "`block_ids` is empty" } })
        .to_string()
}

type ExcerptOp = fn(
    &mut Vault,
    &NoteId,
    &str,
    &[String],
    Caller,
    Option<&dyn memex_core::embedder::Embedder>,
) -> memex_core::Result<Note>;

// Both tools act as `Caller::Agent`. The topic note goes through the
// marker-guarded save path; the daily note's footer through the internal
// footer writer, which agents may use (D9).
#[tool_router(router = excerpts_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "File blocks of the user's daily note for `date` \
        (YYYY-MM-DD) into a topic note (`role: topic`): one transclusion per \
        run of consecutive blocks, under a `## <date>` heading in the topic \
        (created when absent), plus a chip for the topic in that day's Topics \
        footer. Blocks the topic already holds are skipped. Never hand-write \
        transclusion or footer syntax; use this tool. Returns vault_id, \
        topic_note_id and version (the topic note's new version). Fails with \
        role_rule (target not a topic note), not_found (unknown topic or no \
        daily note that day), block_not_found, invalid_date, invalid_id, \
        invalid_argument (empty block_ids) or version_conflict.")]
    pub async fn add_excerpt(&self, params: Parameters<AddExcerptParams>) -> String {
        let AddExcerptParams {
            topic_note_id,
            date,
            block_ids,
        } = params.0;
        self.excerpt_write(excerpts::add_excerpt, &topic_note_id, &date, &block_ids)
            .await
    }

    #[tool(description = "Remove one excerpt from a topic note: every \
        transclusion of `date` (YYYY-MM-DD) whose endpoints are `block_ids` \
        (one id for a single block, [from, to] for a range), the `## <date>` \
        heading when nothing else is under it, and the topic's chip in that \
        day's Topics footer once no excerpt of the day remains (a chip the \
        user added stays). Returns vault_id, topic_note_id and version (the \
        topic note's new version). Fails with role_rule, not_found (unknown \
        topic or no such transclusion), invalid_date, invalid_id, \
        invalid_argument (empty block_ids) or version_conflict.")]
    pub async fn remove_excerpt(&self, params: Parameters<RemoveExcerptParams>) -> String {
        let RemoveExcerptParams {
            topic_note_id,
            date,
            block_ids,
        } = params.0;
        self.excerpt_write(excerpts::remove_excerpt, &topic_note_id, &date, &block_ids)
            .await
    }
}

impl Memex {
    /// Runs `op` as the agent and answers with [`ExcerptWritten`] or C1.
    async fn excerpt_write(
        &self,
        op: ExcerptOp,
        topic_note_id: &str,
        date: &str,
        block_ids: &[String],
    ) -> String {
        let topic = match NoteId::parse(topic_note_id) {
            Ok(id) => id,
            Err(e) => return error(&e),
        };
        if block_ids.is_empty() {
            return no_block_ids();
        }
        let mut vault = self.state.vault.lock().await;
        let written = match op(
            &mut vault,
            &topic,
            date,
            block_ids,
            Caller::Agent,
            self.state.embedder_ref(),
        ) {
            Ok(note) => note,
            Err(e) => return error(&e),
        };
        serde_json::to_string(&ExcerptWritten::new(&vault, &written))
            .unwrap_or_else(|e| error(&MemexError::Json(e)))
    }
}
