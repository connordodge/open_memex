//! MCP tool for the agent's body edits of notes (Spec #7 Req 11, 18, 29, 30):
//! `edit_note`, a thin wrapper over [`note_edits::edit_note`]. Every rule is
//! the engine's; this area maps the params, the errors and the result only.
//! `Memex::new` composes `edits_router`.

use memex_core::note_edits::{self, EditInput, EditPair};
use memex_core::{daily, NoteId};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::service::RequestContext;
use rmcp::{tool, tool_router, RoleServer};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::json;

use super::review::c1_error;
use super::{call_clock, Memex};

/// One Form A pair on the wire.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct EditPairParams {
    /// Text of the note body that must match exactly once.
    pub old_text: String,
    /// The text that replaces it.
    pub new_text: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct EditNoteParams {
    /// The note id (ULID).
    pub note_id: String,
    /// 1 to 3 bullets saying what changed.
    pub bullets: Vec<String>,
    /// Form A: exact find-and-replace pairs, applied all or nothing.
    #[serde(default)]
    pub edits: Option<Vec<EditPairParams>>,
    /// Form B: the whole new body above the Note footer.
    #[serde(default)]
    pub content_md: Option<String>,
    /// The note's version from `get_note`; required with `content_md`.
    #[serde(default)]
    pub expected_version: Option<i64>,
}

// The tool acts as the agent. Every failure is the C1 object, never an
// `op.sub` code.
#[tool_router(router = edits_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "Edit the body of a note: any note except daily \
        notes (marker_rule) and the Vault Guide (guide_rule). A note the \
        person made Agent read-only fails with read_only_rule. Keep every \
        transclusion token (`![[...]]`) exactly as it is, or the edit fails \
        with excerpt_rule: change filing only with add_excerpt, \
        remove_excerpt or remove_excerpt_block. The Note footer, the title \
        and the frontmatter are never changed. Give exactly one of two forms. \
        Form A, `edits`: a list of {old_text, new_text}; each old_text must \
        match exactly once, case- and byte-exact, in the note body above the \
        footer as it was before the call, else edit_not_found or \
        edit_ambiguous naming its `index`; overlapping occurrences count as \
        separate matches, so \"aa\" in \"aaa\" is edit_ambiguous. The edits \
        apply all or nothing; expected_version is optional. Form B, \
        `content_md`: the whole new body above the footer; it requires \
        expected_version. A stale expected_version fails with \
        version_conflict: read the note again. On a note with a footer, an \
        edit that leaves a code fence open above the footer is edit_invalid \
        and writes nothing: close the fence. `bullets` say what changed: 1 to \
        3, each one line of plain markdown, at most 200 characters; they show \
        in the note's Activity tab, dated today. Invalid bullets fail with \
        change_entries_invalid. An edit adds no tag and changes no review \
        state. A failure writes nothing. Returns vault_id, note_id, version, \
        content_md (the stored body, footer included) and changed (false when \
        the body was already that text and nothing was written).")]
    async fn edit_note(
        &self,
        params: Parameters<EditNoteParams>,
        ctx: RequestContext<RoleServer>,
    ) -> String {
        let EditNoteParams {
            note_id,
            bullets,
            edits,
            content_md,
            expected_version,
        } = params.0;
        let note_id = match NoteId::parse(&note_id) {
            Ok(id) => id,
            Err(e) => return c1_error(&e),
        };
        let input = EditInput {
            note_id,
            bullets,
            edits: edits.map(|pairs| {
                pairs
                    .into_iter()
                    .map(|p| EditPair {
                        old_text: p.old_text,
                        new_text: p.new_text,
                    })
                    .collect()
            }),
            content_md,
            expected_version,
        };
        let clock = call_clock(&ctx);
        let day = daily::today_with_clock(&*clock).to_string();
        let mut vault = self.state.vault.lock().await;
        match note_edits::edit_note(&mut vault, input, &day, &*clock, self.state.embedder_ref()) {
            Ok(outcome) => json!({
                "vault_id": vault.vault_id(),
                "note_id": outcome.note_id.as_str(),
                "version": outcome.version,
                "content_md": outcome.content_md,
                "changed": outcome.changed,
            })
            .to_string(),
            Err(e) => c1_error(&e),
        }
    }
}
