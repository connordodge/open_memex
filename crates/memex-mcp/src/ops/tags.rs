//! Tag ops: `memex tag add|rm|ls` and `memex ls --tag` (Spec #234 R45), which
//! the hosted tag routes share (R47). The rules are `memex_core::tags`'; these
//! ops parse the input and name the row in the output.

use memex_core::embedder::Embedder;
use memex_core::tags::{self, TagNote};
use memex_core::{Clock, MemexError, NoteId, Vault};
use rusqlite::params;
use serde::Serialize;

use super::invalid_input_as_argument;

/// A tag input without one leading `#`, as `memex_core::tags` reads it (R38:
/// `#Pricing` in a call).
fn bare_name(input: &str) -> &str {
    input.strip_prefix('#').unwrap_or(input)
}

/// True when `input` names a tag inside the grammar, `#` or not (D43).
pub(crate) fn is_valid_name(input: &str) -> bool {
    tags::normalize_name(bare_name(input)).is_some()
}

/// The stored name a tag input means on a note (R38): the input exactly, then
/// without a leading `#`, then lowercased. With no such row it is the
/// lowercased one, the name a new row would get.
pub(crate) fn stored_name(vault: &Vault, note_id: &NoteId, input: &str) -> anyhow::Result<String> {
    let stored = tags::tags_for_note(vault, note_id.as_str())?;
    let bare = bare_name(input);
    let name = [input, bare]
        .into_iter()
        .find(|name| stored.iter().any(|row| row == name))
        .map_or_else(|| bare.to_lowercase(), str::to_string);
    Ok(name)
}

/// The input of [`add`].
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    pub note_id: String,
    pub tag: String,
}

/// The `memex tag add` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddOutput {
    pub note_id: String,
    /// The stored name.
    pub tag: String,
    /// `person`, as the contract fixes it. A tag the note already has keeps
    /// its stored origin, which `memex tag ls --note-id` shows.
    pub origin: String,
    pub changed: bool,
    /// The note's version after the call.
    pub version: i64,
}

/// Adds a body-less `person` tag with its footer line and lifts its block
/// (R35). A tag the note already has changes nothing.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    let _ = clock;
    let id = NoteId::parse(&input.note_id)?;
    let written = tags::person_add_tag(vault, &id, &input.tag, embedder)
        .map_err(invalid_input_as_argument)?;
    Ok(AddOutput {
        note_id: id.to_string(),
        tag: stored_name(vault, &id, &input.tag)?,
        origin: "person".to_string(),
        changed: written.changed,
        version: written.version,
    })
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub note_id: String,
    pub tag: String,
}

/// The `memex tag rm` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RmOutput {
    pub note_id: String,
    /// The stored name of the row that went.
    pub tag: String,
    pub removed: bool,
    /// The Correction recorded for an agent tag; otherwise `null`.
    pub correction_id: Option<i64>,
    /// The note's version after the call.
    pub version: i64,
}

/// Removes a tag from a note. An agent tag leaves one Correction, which blocks
/// the agent from applying it again (R35); a tag in the text is
/// `invalid_argument` saying to delete the text; a tag the note doesn't have is
/// `removed: false`.
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = clock;
    let id = NoteId::parse(&input.note_id)?;
    // Read first: the row is gone after the call.
    let tag = stored_name(vault, &id, &input.tag)?;
    let removal = tags::person_remove_tag(vault, &id, &input.tag, embedder)
        .map_err(invalid_input_as_argument)?;
    Ok(RmOutput {
        note_id: id.to_string(),
        tag,
        removed: removal.removed,
        correction_id: removal.correction_id,
        version: removal.version,
    })
}

/// The input of [`ls`].
#[derive(Debug, Clone, Default)]
pub struct LsInput;

/// A row of `memex tag ls`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TagRow {
    pub tag: String,
    pub note_count: i64,
    pub system: bool,
}

/// The `memex tag ls` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LsOutput {
    pub tags: Vec<TagRow>,
}

/// Every tag with its note count, system tags included, in `tag COLLATE
/// NOCASE, tag` order (D28).
pub fn ls(
    vault: &mut Vault,
    input: LsInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<LsOutput> {
    let _ = (input, clock, embedder);
    let tags = tags::all_tags(vault)?
        .into_iter()
        .map(|t| TagRow {
            tag: t.tag,
            note_count: t.note_count,
            system: t.system,
        })
        .collect();
    Ok(LsOutput { tags })
}

/// The input of [`ls_note`].
#[derive(Debug, Clone, Default)]
pub struct LsNoteInput {
    pub note_id: String,
}

/// A row of `memex tag ls --note-id`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NoteTagRow {
    pub tag: String,
    /// `body`, `agent` or `person`.
    pub origin: String,
}

/// The `memex tag ls --note-id` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LsNoteOutput {
    pub note_id: String,
    pub tags: Vec<NoteTagRow>,
}

/// One note's tags and their origins, system tags included (`memex tag rm`
/// acts on them), in `tag COLLATE NOCASE, tag` order (D28). An unknown note is
/// `not_found`; a note whose frontmatter doesn't parse still lists.
pub fn ls_note(
    vault: &mut Vault,
    input: LsNoteInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<LsNoteOutput> {
    let _ = (clock, embedder);
    let id = NoteId::parse(&input.note_id)?;
    let conn = vault.connection_ref();
    let known: bool = conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM notes WHERE id = ?)",
        params![id.as_str()],
        |r| r.get(0),
    )?;
    if !known {
        return Err(MemexError::NotFound(format!("note {id}")).into());
    }
    let mut stmt = conn.prepare(
        "SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag COLLATE NOCASE, tag",
    )?;
    let tags = stmt
        .query_map(params![id.as_str()], |r| {
            Ok(NoteTagRow {
                tag: r.get(0)?,
                origin: r.get(1)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;
    Ok(LsNoteOutput {
        note_id: id.to_string(),
        tags,
    })
}

/// The input of [`tag_notes`].
#[derive(Debug, Clone, Default)]
pub struct TagNotesInput {
    /// The exact stored name.
    pub tag: String,
}

/// A row of `GET /tags/{tag}/notes`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TagNoteRow {
    pub note_id: String,
    pub title: String,
    pub role: Option<String>,
    /// `null` for a tag that isn't in the note's text.
    pub first_line: Option<String>,
    pub updated_at: i64,
}

/// The `GET /tags/{tag}/notes` response.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TagNotesOutput {
    pub notes: Vec<TagNoteRow>,
}

/// The notes with a tag named exactly `tag`, most recently updated first (R28).
pub fn tag_notes(
    vault: &mut Vault,
    input: TagNotesInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<TagNotesOutput> {
    let _ = (clock, embedder);
    let notes = tags::notes_for_tag(vault, &input.tag)?
        .into_iter()
        .map(|n| TagNoteRow {
            note_id: n.note_id,
            title: n.title,
            role: n.role,
            first_line: n.first_line,
            updated_at: n.updated_at,
        })
        .collect();
    Ok(TagNotesOutput { notes })
}

/// `memex ls --tag`: up to `limit` notes with the tag `input` means, most
/// recently updated first. The input means the stored name first, then the
/// name without a leading `#`, then the lowercased one, across the vault (R38).
/// A negative `limit` is no limit, as it is in `memex ls`.
pub fn notes_with_tag(vault: &Vault, input: &str, limit: i64) -> anyhow::Result<Vec<TagNote>> {
    let bare = bare_name(input);
    for name in [input, bare, &bare.to_lowercase()] {
        let mut notes = tags::notes_for_tag(vault, name)?;
        if !notes.is_empty() {
            notes.truncate(usize::try_from(limit).unwrap_or(usize::MAX));
            return Ok(notes);
        }
    }
    Ok(Vec::new())
}
