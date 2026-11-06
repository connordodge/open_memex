//! MCP tools for tags and Note footer topics (Spec #234 R38-R40, D10, D18,
//! D21). Thin over `memex_core::tags` and `memex_core::footer`: the rules live
//! in core.

use std::io::ErrorKind;

use memex_core::footer::{self, ChipOrigin};
use memex_core::tags as core_tags;
use memex_core::{MemexError, NoteId};
use rmcp::handler::server::wrapper::Parameters;
use rmcp::{tool, tool_router};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::json;

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

/// The C1 error object. Core's `Io(InvalidInput)` is its form of
/// `invalid_argument`, which `to_error_json` alone reports as `internal`.
fn error(e: &MemexError) -> String {
    match e {
        MemexError::Io(io) if io.kind() == ErrorKind::InvalidInput => {
            json!({ "error": { "code": "invalid_argument", "message": io.to_string() } })
                .to_string()
        }
        _ => e.to_error_json().to_string(),
    }
}

/// The name a tag input means, for the output's `tag`: without one leading `#`
/// and lowercased. An input outside the grammar stays as given, without the
/// `#`.
fn output_name(input: &str) -> String {
    let bare = input.strip_prefix('#').unwrap_or(input);
    core_tags::normalize_name(bare).unwrap_or_else(|| bare.to_string())
}

/// The C1 `invalid_argument` object for the first of a `create_note` call's
/// `tags` outside the grammar (D43), checked as `apply_tag` reads a name.
pub(super) fn invalid_tag_name(tags: &[String]) -> Option<String> {
    let bad = tags
        .iter()
        .find(|tag| core_tags::normalize_name(tag.strip_prefix('#').unwrap_or(tag)).is_none())?;
    let message = format!("{bad:?} is not a valid tag name");
    Some(json!({ "error": { "code": "invalid_argument", "message": message } }).to_string())
}

// Every rule is core's: the guide check (D10) comes first in `agent_tag_note`,
// `agent_untag_note` and `set_chip`. Every failure is a C1 object, never the
// `op.sub` codes of the older tools.
#[tool_router(router = tags_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "List the vault's tag vocabulary: every tag the \
        person has written in a note body, with `note_count`, the number of \
        notes carrying it from any origin. System tags and tags written only \
        on the Vault Guide are left out. `tag_note` accepts only these names. \
        Returns vault_id and tags: [{tag, note_count}], sorted by name.")]
    pub async fn list_tags(&self, _params: Parameters<ListTagsParams>) -> String {
        let vault = self.state.vault.lock().await;
        let vocabulary = match core_tags::vocabulary(&vault) {
            Ok(vocabulary) => vocabulary,
            Err(e) => return error(&e),
        };
        let tags: Vec<_> = vocabulary
            .iter()
            .map(|t| json!({ "tag": t.tag, "note_count": t.note_count }))
            .collect();
        json!({ "vault_id": vault.vault_id(), "tags": tags }).to_string()
    }

    #[tool(description = "Apply a tag from `list_tags` to a note, with its \
        line in the Note footer. A leading `#` and capitals in `tag` are \
        ignored. A tag the note already has succeeds with no write and keeps \
        its origin. Returns vault_id, note_id, tag, applied (false when \
        nothing was written) and version. Fails with unknown_tag (not in the \
        vocabulary), tag_removed (the person removed it from this note: don't \
        apply it again), guide_rule (the note is the Vault Guide), not_found \
        or invalid_id.")]
    pub async fn tag_note(&self, params: Parameters<TagNoteParams>) -> String {
        let TagNoteParams { note_id, tag } = params.0;
        let id = match NoteId::parse(&note_id) {
            Ok(id) => id,
            Err(e) => return error(&e),
        };
        let mut vault = self.state.vault.lock().await;
        let write =
            match core_tags::agent_tag_note(&mut vault, &id, &tag, self.state.embedder_ref()) {
                Ok(write) => write,
                Err(e) => return error(&e),
            };
        json!({
            "vault_id": vault.vault_id(),
            "note_id": id.as_str(),
            "tag": output_name(&tag),
            "applied": write.changed,
            "version": write.version,
        })
        .to_string()
    }

    #[tool(description = "Remove a tag an agent applied from a note (one of \
        `get_note`'s `agent_tags`), with its line in the Note footer. A \
        leading `#` and capitals in `tag` are ignored. Returns vault_id, \
        note_id, tag, removed (false when the note doesn't have the tag) and \
        version. Fails with invalid_argument (a tag from any other origin, \
        including one in the note's text, or a system tag), guide_rule (the \
        note is the Vault Guide), not_found or invalid_id.")]
    pub async fn untag_note(&self, params: Parameters<UntagNoteParams>) -> String {
        let UntagNoteParams { note_id, tag } = params.0;
        let id = match NoteId::parse(&note_id) {
            Ok(id) => id,
            Err(e) => return error(&e),
        };
        let mut vault = self.state.vault.lock().await;
        let removal =
            match core_tags::agent_untag_note(&mut vault, &id, &tag, self.state.embedder_ref()) {
                Ok(removal) => removal,
                Err(e) => return error(&e),
            };
        json!({
            "vault_id": vault.vault_id(),
            "note_id": id.as_str(),
            "tag": output_name(&tag),
            "removed": removal.removed,
            "version": removal.version,
        })
        .to_string()
    }

    #[tool(description = "Add a chip for a topic note (`role: topic`) to a \
        note's Note footer. A chip already there writes nothing. Returns \
        vault_id, note_id, topic_note_id, origin (the chip's stored origin: \
        `excerpt`, or `person` when the person added it) and version. Fails \
        with guide_rule (the note is the Vault Guide), role_rule (the target \
        isn't a topic note), invalid_argument (the note and the target are \
        the same note), not_found or invalid_id.")]
    pub async fn add_footer_topic(&self, params: Parameters<AddFooterTopicParams>) -> String {
        let AddFooterTopicParams {
            note_id,
            topic_note_id,
        } = params.0;
        let id = match NoteId::parse(&note_id) {
            Ok(id) => id,
            Err(e) => return error(&e),
        };
        let topic = match NoteId::parse(&topic_note_id) {
            Ok(id) => id,
            Err(e) => return error(&e),
        };
        let mut vault = self.state.vault.lock().await;
        // D18: the schema has no agent chip origin, so an agent's chip is
        // `excerpt`.
        let write = match footer::set_chip(
            &mut vault,
            &id,
            &topic,
            ChipOrigin::Excerpt,
            self.state.embedder_ref(),
        ) {
            Ok(write) => write,
            Err(e) => return error(&e),
        };
        json!({
            "vault_id": vault.vault_id(),
            "note_id": id.as_str(),
            "topic_note_id": topic.as_str(),
            "origin": write.origin.map(ChipOrigin::as_str),
            "version": write.note.version,
        })
        .to_string()
    }
}
