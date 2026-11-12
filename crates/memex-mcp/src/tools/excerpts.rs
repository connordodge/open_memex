//! MCP tools for excerpts (architect ruling D7). This area's tools go in the
//! impl below; `Memex::new` already composes `excerpts_router`.

use memex_core::excerpts;
use memex_core::{Caller, MemexError, Note, NoteId, Vault};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_router};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

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

    /// The MCP result: these keys plus `outcome`'s (Spec #390 req 8), which
    /// say what the write did. The CLI line stays [`ExcerptWritten`] alone.
    pub(crate) fn with(self, outcome: Value) -> ExcerptResult<'a> {
        ExcerptResult {
            written: self,
            outcome,
        }
    }
}

/// An MCP excerpt tool's result: [`ExcerptWritten`] and one more field.
#[derive(Serialize)]
pub(crate) struct ExcerptResult<'a> {
    #[serde(flatten)]
    written: ExcerptWritten<'a>,
    #[serde(flatten)]
    outcome: Value,
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

/// An excerpt write, answering the topic note as stored and the result's
/// outcome field.
type ExcerptOp = fn(
    &mut Vault,
    &NoteId,
    &str,
    &[String],
    Caller,
    Option<&dyn memex_core::embedder::Embedder>,
) -> memex_core::Result<(Note, Value)>;

/// [`excerpts::add_excerpt_filed`], its ids as `filed_block_ids`.
fn add_excerpt_op(
    vault: &mut Vault,
    topic: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn memex_core::embedder::Embedder>,
) -> memex_core::Result<(Note, Value)> {
    excerpts::add_excerpt_filed(vault, topic, date, block_ids, caller, embedder)
        .map(|(note, filed)| (note, json!({ "filed_block_ids": filed })))
}

/// [`excerpts::remove_excerpt_counted`], its count as `removed_count`.
fn remove_excerpt_op(
    vault: &mut Vault,
    topic: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn memex_core::embedder::Embedder>,
) -> memex_core::Result<(Note, Value)> {
    excerpts::remove_excerpt_counted(vault, topic, date, block_ids, caller, embedder)
        .map(|(note, count)| (note, json!({ "removed_count": count })))
}

// Both tools act as `Caller::Agent`. The topic note goes through the
// marker-guarded save path; the daily note's footer through the internal
// footer writer, which agents may use (D9).
#[tool_router(router = excerpts_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "File blocks of the user's daily note for `date` \
        (YYYY-MM-DD) into a topic note (`role: topic`): one transclusion per \
        run of consecutive blocks, under a `## <date>` heading in the topic \
        (created when absent), plus a chip for the topic in that day's Note \
        footer. Blocks the topic already holds are skipped. Never hand-write \
        transclusion or footer syntax; use this tool. Returns vault_id, \
        topic_note_id, version (the topic note's new version) and \
        filed_block_ids (the blocks this call filed, in day order; empty when \
        the topic already held them all, though the day's chip for the topic \
        is still added when it is missing). Fails with \
        role_rule (target not a topic note), not_found (unknown topic or no \
        daily note that day), block_not_found, invalid_date, invalid_id, \
        invalid_argument (empty block_ids) or version_conflict.")]
    pub async fn add_excerpt(&self, params: Parameters<AddExcerptParams>) -> String {
        let AddExcerptParams {
            topic_note_id,
            date,
            block_ids,
        } = params.0;
        self.excerpt_write(add_excerpt_op, &topic_note_id, &date, &block_ids)
            .await
    }

    #[tool(description = "Remove one excerpt from a topic note: every \
        transclusion of `date` (YYYY-MM-DD) whose endpoints are `block_ids` \
        (one id for a single block, [from, to] for a range), the `## <date>` \
        heading when nothing else is under it, and the topic's chip in that \
        day's Note footer once no excerpt of the day remains (a chip the \
        user added stays). Returns vault_id, topic_note_id, version (the \
        topic note's new version) and removed_count (the blocks it unfiled: \
        every block of the day between the endpoints, or the endpoints \
        themselves, 1 or 2, when the daily note or an endpoint no longer \
        exists). Fails with role_rule, not_found (unknown \
        topic or no such transclusion), invalid_date, invalid_id, \
        invalid_argument (empty block_ids) or version_conflict.")]
    pub async fn remove_excerpt(&self, params: Parameters<RemoveExcerptParams>) -> String {
        let RemoveExcerptParams {
            topic_note_id,
            date,
            block_ids,
        } = params.0;
        self.excerpt_write(remove_excerpt_op, &topic_note_id, &date, &block_ids)
            .await
    }
}

impl Memex {
    /// Runs `op` as the agent and answers with [`ExcerptResult`] or C1.
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
            Ok(written) => written,
            Err(e) => return error(&e),
        };
        let (written, outcome) = written;
        serde_json::to_string(&ExcerptWritten::new(&vault, &written).with(outcome))
            .unwrap_or_else(|e| error(&MemexError::Json(e)))
    }
}
