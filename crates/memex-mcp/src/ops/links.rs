//! Link ops: `memex add-link` and `memex update-link`.

use memex_core::embedder::Embedder;
use memex_core::links::{self as core_links, LinkKind, LinkSource};
use memex_core::notes::{get_note, update_note_with_options, RenameOptions, UpdateNote};
use memex_core::{indexer, Clock, MemexError, NoteId, Vault};
use rusqlite::params;
use serde::Serialize;

use crate::cli::InvalidArgument;
use crate::md_links;

/// Parses a `--kind` value. A malformed kind is `invalid_argument`
/// (`invalid --kind: …`), not the core error's code. A kind only the server
/// writes (`from-day`, `about`) is refused too.
pub fn parse_kind(kind: &str) -> anyhow::Result<LinkKind> {
    LinkKind::new_user_written(kind)
        .map_err(|e| InvalidArgument(format!("invalid --kind: {e}")).into())
}

/// The input of [`add_link`].
#[derive(Debug, Clone)]
pub struct AddLinkInput {
    /// Source note id.
    pub from: String,
    /// Target note id.
    pub to: String,
    /// Link kind (the CLI defaults it to `references`).
    pub kind: String,
    /// Optional display alias (`[[Title|alias]]`).
    pub label: Option<String>,
}

impl AddLinkInput {
    /// The checks `memex add-link` makes before it opens the vault, in its
    /// order: `from`, then `to`, then `kind`. [`add_link`] makes the same
    /// checks.
    pub fn validate(&self) -> anyhow::Result<(NoteId, NoteId, LinkKind)> {
        let from = NoteId::parse(&self.from)?;
        let to = NoteId::parse(&self.to)?;
        let kind = parse_kind(&self.kind)?;
        Ok((from, to, kind))
    }
}

/// The `memex add-link` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AddLinkOutput {
    pub vault_id: String,
    pub link_id: Option<String>,
    pub from: String,
    pub to: String,
    pub kind: String,
    pub source: String,
    /// `true` when a link of this kind already ran from `from` to `to`;
    /// nothing was written.
    pub was_existing: bool,
    /// The source note's version after the call.
    pub note_version: i64,
}

/// Adds a wikilink to the source note's markdown on the person path and
/// reindexes it. Idempotent per (from, to, kind).
pub fn add_link(
    vault: &mut Vault,
    input: AddLinkInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<AddLinkOutput> {
    let _ = clock;
    let (from_id, to_id, kind) = input.validate()?;
    let source = get_note(vault, &from_id)?;
    let target = get_note(vault, &to_id)?;
    let vault_id = vault.vault_id().to_string();
    let chosen_source = if kind.as_str() == LinkKind::REFERENCES {
        LinkSource::AutoAdded
    } else {
        LinkSource::Frontmatter
    };

    // Idempotency: a link of this kind already runs from source to target.
    let existing = vault.connection_ref().query_row(
        "SELECT id FROM links WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ? LIMIT 1",
        params![source.id.as_str(), target.id.as_str(), kind.as_str()],
        |r| r.get::<_, String>(0),
    );
    if let Ok(link_id) = existing {
        return Ok(AddLinkOutput {
            vault_id,
            link_id: Some(link_id),
            from: source.id.to_string(),
            to: target.id.to_string(),
            kind: kind.as_str().to_string(),
            source: chosen_source.as_str().to_string(),
            was_existing: true,
            note_version: source.version,
        });
    }

    // Insert into the source note's markdown. The extractor parses
    // `[[Title|alias]]` into the row's `label`.
    let new_md = md_links::insert_link_into_markdown(
        &source.content_md,
        &target.title,
        kind.as_str(),
        input.label.as_deref(),
    );
    // Apply the update without firing the title-rename pass.
    let updated = update_note_with_options(
        vault,
        &source.id,
        source.version,
        UpdateNote {
            content_md: Some(new_md),
            ..Default::default()
        },
        RenameOptions {
            rename_links: false,
        },
    )?;
    indexer::reindex_note(
        vault.connection_mut(),
        updated.id.as_str(),
        &updated.content_md,
        embedder,
    )?;

    // Find the new link's id.
    let link_id: Option<String> = vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links
                WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ?
                ORDER BY position DESC LIMIT 1",
            params![source.id.as_str(), target.id.as_str(), kind.as_str()],
            |r| r.get(0),
        )
        .ok();

    Ok(AddLinkOutput {
        vault_id,
        link_id,
        from: source.id.to_string(),
        to: target.id.to_string(),
        kind: kind.as_str().to_string(),
        source: chosen_source.as_str().to_string(),
        was_existing: false,
        note_version: updated.version,
    })
}

/// The input of [`update_link`].
#[derive(Debug, Clone, Default)]
pub struct UpdateLinkInput {
    pub link_id: String,
    /// The new kind; `None` keeps it.
    pub kind: Option<String>,
    /// The new label; `None` keeps it.
    pub label: Option<String>,
    /// Clear the label (overrides `label`).
    pub clear_label: bool,
}

impl UpdateLinkInput {
    /// The check `memex update-link` makes before it opens the vault: a
    /// given `kind` must parse. [`update_link`] makes the same check.
    pub fn validate(&self) -> anyhow::Result<Option<LinkKind>> {
        self.kind.as_deref().map(parse_kind).transpose()
    }
}

/// The `memex update-link` output line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UpdateLinkOutput {
    pub from_note_id: String,
    pub kind: String,
    pub label: Option<String>,
    pub link_id: String,
    pub position: i64,
    pub source: String,
    pub to_note_id: Option<String>,
    pub vault_id: String,
}

/// Rewrites a wikilink's kind and/or label in place on the person path.
pub fn update_link(
    vault: &mut Vault,
    input: UpdateLinkInput,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> anyhow::Result<UpdateLinkOutput> {
    let _ = (clock, embedder);
    let new_kind = input.validate()?;
    let new_label: Option<Option<String>> = if input.clear_label {
        Some(None)
    } else {
        input.label.map(Some)
    };
    let link = core_links::update_link(
        vault,
        &input.link_id,
        core_links::UpdateLink {
            new_kind,
            new_label,
        },
    )
    .map_err(|e| match e {
        // A kind change on a frontmatter link is a usage error, not
        // `internal` (core maps `InvalidLinkKind` there).
        MemexError::InvalidLinkKind(m)
            if m.starts_with(core_links::FRONTMATTER_KIND_CHANGE_REFUSED) =>
        {
            anyhow::Error::from(InvalidArgument(format!("invalid link kind: {m}")))
        }
        other => other.into(),
    })?;
    Ok(UpdateLinkOutput {
        from_note_id: link.from_note_id,
        kind: link.link_kind.as_str().to_string(),
        label: link.label,
        link_id: link.id,
        position: link.position,
        source: link.source.as_str().to_string(),
        to_note_id: link.to_note_id,
        vault_id: vault.vault_id().to_string(),
    })
}
