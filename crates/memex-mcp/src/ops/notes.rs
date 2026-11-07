//! Note ops: `memex add`, `memex update`, `memex get` and `memex rm`.

use std::collections::BTreeMap;

use memex_core::embedder::Embedder;
use memex_core::links::{self as core_links, Link};
use memex_core::notes::{
    create_or_adopt_note, delete_note_checked, get_note, update_note_with_options, CreateNote,
    RenameOptions, UpdateNote,
};
use memex_core::tags::{self, TagOrigin};
use memex_core::{daily, excerpts, indexer, review};
use memex_core::{Caller, Clock, NoteId, Vault};
use serde::Serialize;
use serde_json::{json, Map, Value};

use super::tags::{is_valid_name, stored_name};
use crate::cli::{InvalidArgument, Role};

/// The input of [`add`]: the note body plus `memex add`'s flags.
#[derive(Debug, Clone, Default)]
pub struct AddInput {
    /// The title. `None` derives it from the first line, or, for a daily
    /// note, uses today's date from the clock.
    pub title: Option<String>,
    /// The note body (stdin for the CLI).
    pub content_md: String,
    /// Tags added to the note after it is created, as `person` tags with
    /// footer text (R40). Any name in the grammar (D43).
    pub tags: Vec<String>,
    /// The `role` frontmatter value.
    pub role: Option<Role>,
}

impl AddInput {
    /// The checks `memex add` makes before it opens the vault: a body is
    /// required unless the note is a daily note (C2.1: a day may start
    /// empty), and every tag name is in the grammar (D43). [`add`] makes the
    /// same checks.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.content_md.trim().is_empty() && self.role != Some(Role::Daily) {
            let msg = "stdin was empty — nothing to add".to_string();
            return Err(InvalidArgument(msg).into());
        }
        if let Some(bad) = self.tags.iter().find(|tag| !is_valid_name(tag)) {
            return Err(InvalidArgument(format!("{bad:?} is not a valid tag name")).into());
        }
        Ok(())
    }
}

/// What `memex add` prints: `Created note` (or `Adopted note`), then
/// `note_id`, `title`, and `tags` (their stored names) when there are any.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddOutput {
    pub note_id: String,
    pub title: String,
    pub tags: Vec<String>,
    /// `true` when a daily add adopted a role-less note titled with the date.
    pub adopted: bool,
}

/// Creates a note on the person path (adopting a role-less note titled with
/// the date for a daily add), tags it and indexes it.
pub fn add(
    vault: &mut Vault,
    input: AddInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddOutput> {
    input.validate()?;
    let AddInput {
        title,
        content_md,
        tags: tag_list,
        role,
    } = input;
    let frontmatter = role.map(|r| json!({ "role": r.as_str() }));
    let create = if role == Some(Role::Daily) {
        let date = daily::resolve_date(title.as_deref(), clock)?;
        let content_md = if content_md.trim().is_empty() {
            String::new()
        } else {
            content_md
        };
        CreateNote {
            title: Some(date.to_string()),
            content_md,
            frontmatter,
        }
    } else {
        CreateNote {
            title,
            content_md,
            frontmatter,
        }
    };
    let outcome = create_or_adopt_note(vault, create, Caller::Person, clock)?;
    let id = outcome.note.id;
    let stored_tags = tag_list
        .iter()
        .map(|tag| {
            // The index below reads the note once all its footer lines are in.
            tags::apply_tag(vault, &id, tag, TagOrigin::Person, None)?;
            stored_name(vault, &id, tag)
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let note = get_note(vault, &id)?;
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        embedder,
    )?;
    Ok(AddOutput {
        note_id: note.id.to_string(),
        title: note.title,
        tags: stored_tags,
        adopted: outcome.adopted,
    })
}

/// The input of [`update`]: `memex update`'s flags plus the new body.
#[derive(Debug, Clone, Default)]
pub struct UpdateInput {
    pub note_id: String,
    pub expected_version: i64,
    /// The new title; `None` keeps the current one.
    pub title: Option<String>,
    /// The new body (stdin for the CLI).
    pub content_md: String,
    /// Skip the pass that rewrites `[[OldTitle]]` in linkers.
    pub no_rename_links: bool,
}

/// The `memex update` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UpdateOutput {
    pub note_id: String,
    pub version: i64,
    pub updated_at: i64,
}

/// Saves a note on the person path and reindexes it.
pub fn update(
    vault: &mut Vault,
    input: UpdateInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<UpdateOutput> {
    let _ = clock;
    let id = NoteId::parse(&input.note_id)?;
    let updated = update_note_with_options(
        vault,
        &id,
        input.expected_version,
        UpdateNote {
            title: input.title,
            content_md: Some(input.content_md),
            frontmatter: None,
        },
        RenameOptions {
            rename_links: !input.no_rename_links,
        },
    )?;
    indexer::reindex_note(
        vault.connection_mut(),
        updated.id.as_str(),
        &updated.content_md,
        embedder,
    )?;
    Ok(UpdateOutput {
        note_id: updated.id.to_string(),
        version: updated.version,
        updated_at: updated.updated_at,
    })
}

/// The input of [`get`].
#[derive(Debug, Clone, Default)]
pub struct GetInput {
    pub note_id: String,
    /// Add `links` and `backlinks`, grouped by kind.
    pub include_links: bool,
}

/// The `memex get` object.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GetOutput {
    pub note_id: String,
    pub title: String,
    pub content_md: String,
    pub frontmatter: Value,
    pub version: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub tags: Vec<String>,
    /// The review and transclusion fields, at the top level (D7).
    #[serde(flatten)]
    pub fields: Map<String, Value>,
    /// Outgoing links by kind; `Some` only with `include_links`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<Map<String, Value>>,
    /// Incoming links by kind; `Some` only with `include_links`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backlinks: Option<Map<String, Value>>,
}

/// Reads one note with its tags, review and transclusion fields and, when
/// asked, its links.
pub fn get(
    vault: &mut Vault,
    input: GetInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<GetOutput> {
    let _ = (clock, embedder);
    let id = NoteId::parse(&input.note_id)?;
    let note = get_note(vault, &id)?;
    // Missing tags or links read as empty, as `memex get` always has.
    let tag_list = tags::tags_for_note(vault, note.id.as_str()).unwrap_or_default();
    let mut fields = review::note_review_fields(vault, &note)?;
    fields.extend(excerpts::note_transclusion_fields(vault, &note)?);
    let (links, backlinks) = if input.include_links {
        let outgoing = core_links::links_out_for_note(vault, note.id.as_str()).unwrap_or_default();
        let incoming =
            core_links::links_in_for_note(vault, note.id.as_str(), None).unwrap_or_default();
        (
            Some(group_links_by_kind(&outgoing)),
            Some(group_links_by_kind(&incoming)),
        )
    } else {
        (None, None)
    };
    Ok(GetOutput {
        note_id: note.id.to_string(),
        title: note.title,
        content_md: note.content_md,
        frontmatter: note.frontmatter,
        version: note.version,
        created_at: note.created_at,
        updated_at: note.updated_at,
        tags: tag_list,
        fields,
        links,
        backlinks,
    })
}

/// Link kinds in display order: the built-ins in canonical order, then
/// user-defined kinds alphabetically. `memex links` prints its tree in this
/// order too.
pub fn ordered_kinds(kinds: Vec<String>) -> Vec<String> {
    const BUILT_IN: [&str; 4] = ["references", "extends", "contradicts", "example-of"];
    let mut out: Vec<String> = Vec::new();
    let mut user_defined: Vec<String> = Vec::new();
    for k in &kinds {
        if !BUILT_IN.contains(&k.as_str()) {
            user_defined.push(k.clone());
        }
    }
    user_defined.sort();
    for b in BUILT_IN {
        if kinds.iter().any(|k| k == b) {
            out.push(b.to_string());
        }
    }
    out.extend(user_defined);
    out
}

/// `links` / `backlinks` of `memex get`: link rows grouped by kind.
fn group_links_by_kind(links: &[Link]) -> Map<String, Value> {
    let mut by_kind: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for l in links {
        by_kind
            .entry(l.link_kind.as_str().to_string())
            .or_default()
            .push(json!({
                "link_id": l.id,
                "from_note_id": l.from_note_id,
                "to_note_id": l.to_note_id,
                "link_text": l.link_text,
                "label": l.label,
                "source": l.source.as_str(),
                "position": l.position,
            }));
    }
    let mut out = Map::new();
    for k in ordered_kinds(by_kind.keys().cloned().collect()) {
        if let Some(v) = by_kind.remove(&k) {
            out.insert(k, Value::Array(v));
        }
    }
    out
}

/// The input of [`rm`].
#[derive(Debug, Clone, Default)]
pub struct RmInput {
    pub note_id: String,
    pub expected_version: i64,
}

/// The `memex rm` output line (C2.2).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RmOutput {
    pub vault_id: String,
    pub note_id: String,
    pub deleted: bool,
}

/// Deletes a note on the person path (D24).
pub fn rm(
    vault: &mut Vault,
    input: RmInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<RmOutput> {
    let _ = clock;
    let id = NoteId::parse(&input.note_id)?;
    delete_note_checked(vault, &id, input.expected_version, embedder)?;
    Ok(RmOutput {
        vault_id: vault.vault_id().to_string(),
        note_id: id.to_string(),
        deleted: true,
    })
}
