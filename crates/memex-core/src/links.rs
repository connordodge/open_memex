//! Wikilink storage. Mirrors the `tags.rs` shape: small free functions over
//! `&Vault`, plus type-safe wrappers (`LinkKind`, `LinkSource`) for the
//! columns whose values are constrained.

use std::str::FromStr;

use rusqlite::types::{FromSql, FromSqlError, ToSqlOutput, ValueRef};
use rusqlite::{params, Connection, ToSql};
use serde::{Deserialize, Serialize};
use ulid::Ulid;

use crate::caller::Caller;
use crate::error::MemexError;
use crate::vault::Vault;
use crate::Result;

const MAX_KIND_LEN: usize = 64;

/// Link kinds: four built-ins plus any normalized user-defined kebab-case string.
/// Stored verbatim in `links.link_kind`. The four built-ins are the ones the
/// extractor recognizes through curated section headings and frontmatter keys.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LinkKind(String);

impl LinkKind {
    pub const REFERENCES: &'static str = "references";
    pub const EXTENDS: &'static str = "extends";
    pub const CONTRADICTS: &'static str = "contradicts";
    pub const EXAMPLE_OF: &'static str = "example-of";
    pub const FROM_DAY: &'static str = "from-day";
    pub const ABOUT: &'static str = "about";

    /// Validate + return a `LinkKind`. Input is normalized (lowercased,
    /// whitespace runs collapsed to `-`, leading/trailing `-` stripped) before
    /// validation against `^[a-z][a-z0-9-]*$` length ≤ 64.
    pub fn new(s: &str) -> Result<Self> {
        let normalized = normalize(s);
        if !is_valid_kind(&normalized) {
            return Err(MemexError::InvalidLinkKind(s.to_string()));
        }
        Ok(Self(normalized))
    }

    /// Default kind when none is specified.
    pub fn references() -> Self {
        Self(Self::REFERENCES.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn is_built_in(&self) -> bool {
        matches!(
            self.0.as_str(),
            Self::REFERENCES | Self::EXTENDS | Self::CONTRADICTS | Self::EXAMPLE_OF
        )
    }
}

impl FromStr for LinkKind {
    type Err = MemexError;
    fn from_str(s: &str) -> Result<Self> {
        Self::new(s)
    }
}

impl std::fmt::Display for LinkKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl ToSql for LinkKind {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(ToSqlOutput::from(self.0.as_str()))
    }
}

impl FromSql for LinkKind {
    fn column_result(value: ValueRef<'_>) -> std::result::Result<Self, FromSqlError> {
        let s: String = FromSql::column_result(value)?;
        LinkKind::new(&s).map_err(|e| FromSqlError::Other(Box::new(std::io::Error::other(e.to_string()))))
    }
}

pub fn normalize(s: &str) -> String {
    let lower = s.trim().to_lowercase();
    let mut out = String::with_capacity(lower.len());
    let mut prev_dash = false;
    for ch in lower.chars() {
        if ch.is_whitespace() {
            if !prev_dash && !out.is_empty() {
                out.push('-');
                prev_dash = true;
            }
        } else {
            out.push(ch);
            prev_dash = ch == '-';
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    while out.starts_with('-') {
        out.remove(0);
    }
    out
}

fn is_valid_kind(s: &str) -> bool {
    if s.is_empty() || s.len() > MAX_KIND_LEN {
        return false;
    }
    let bytes = s.as_bytes();
    if !bytes[0].is_ascii_lowercase() {
        return false;
    }
    bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

/// Where a link came from in the source markdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LinkSource {
    InlineBody,
    InlineSection,
    Frontmatter,
    AutoAdded,
}

impl LinkSource {
    pub fn as_str(self) -> &'static str {
        match self {
            LinkSource::InlineBody => "inline_body",
            LinkSource::InlineSection => "inline_section",
            LinkSource::Frontmatter => "frontmatter",
            LinkSource::AutoAdded => "auto_added",
        }
    }
}

impl FromStr for LinkSource {
    type Err = MemexError;
    fn from_str(s: &str) -> Result<Self> {
        match s {
            "inline_body" => Ok(LinkSource::InlineBody),
            "inline_section" => Ok(LinkSource::InlineSection),
            "frontmatter" => Ok(LinkSource::Frontmatter),
            "auto_added" => Ok(LinkSource::AutoAdded),
            other => Err(MemexError::InvalidLinkKind(format!("source: {other}"))),
        }
    }
}

impl ToSql for LinkSource {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(ToSqlOutput::from(self.as_str()))
    }
}

impl FromSql for LinkSource {
    fn column_result(value: ValueRef<'_>) -> std::result::Result<Self, FromSqlError> {
        let s: String = FromSql::column_result(value)?;
        LinkSource::from_str(&s).map_err(|e| FromSqlError::Other(Box::new(std::io::Error::other(e.to_string()))))
    }
}

/// A row in the `links` table.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Link {
    pub id: String,
    pub from_note_id: String,
    pub to_note_id: Option<String>,
    pub link_text: String,
    pub link_kind: LinkKind,
    pub label: Option<String>,
    pub position: i64,
    pub source: LinkSource,
}

/// What the extractor produces. The indexer turns these into `Link` rows.
#[derive(Debug, Clone)]
pub struct PendingLink {
    pub link_text: String,
    pub link_kind: LinkKind,
    pub label: Option<String>,
    pub position: i64,
    pub source: LinkSource,
}

/// Replace all outgoing links for a note. Used by the indexer on every save.
/// Resolves `to_note_id` via exact title match against `notes.title`.
pub fn replace_links_for_note(
    conn: &Connection,
    from_note_id: &str,
    pending: &[PendingLink],
) -> Result<usize> {
    conn.execute(
        "DELETE FROM links WHERE from_note_id = ?",
        params![from_note_id],
    )?;
    let mut inserted = 0usize;
    for p in pending {
        let id = Ulid::new().to_string();
        let to_note_id: Option<String> = conn
            .query_row(
                "SELECT id FROM notes WHERE title = ?",
                params![p.link_text],
                |r| r.get(0),
            )
            .ok();
        conn.execute(
            "INSERT INTO links
                (id, from_note_id, to_note_id, link_text, link_kind, label, position, source)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                id,
                from_note_id,
                to_note_id,
                p.link_text,
                p.link_kind,
                p.label,
                p.position,
                p.source,
            ],
        )?;
        inserted += 1;
    }
    Ok(inserted)
}

pub fn links_out_for_note(vault: &Vault, note_id: &str) -> Result<Vec<Link>> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source
         FROM links WHERE from_note_id = ? ORDER BY position",
    )?;
    let mut rows = stmt.query(params![note_id])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        out.push(row_to_link(r)?);
    }
    Ok(out)
}

pub fn links_in_for_note(
    vault: &Vault,
    note_id: &str,
    kind: Option<&LinkKind>,
) -> Result<Vec<Link>> {
    let mut out = Vec::new();
    let conn = vault.connection_ref();
    if let Some(k) = kind {
        let mut stmt = conn.prepare(
            "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source
             FROM links WHERE to_note_id = ? AND link_kind = ? ORDER BY from_note_id, position",
        )?;
        let mut rows = stmt.query(params![note_id, k])?;
        while let Some(r) = rows.next()? {
            out.push(row_to_link(r)?);
        }
    } else {
        let mut stmt = conn.prepare(
            "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source
             FROM links WHERE to_note_id = ? ORDER BY link_kind, from_note_id, position",
        )?;
        let mut rows = stmt.query(params![note_id])?;
        while let Some(r) = rows.next()? {
            out.push(row_to_link(r)?);
        }
    }
    Ok(out)
}

/// Read one link row by id.
pub fn get_link(vault: &Vault, link_id: &str) -> Result<Link> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source
         FROM links WHERE id = ?",
    )?;
    let mut rows = stmt.query(params![link_id])?;
    let row = rows
        .next()?
        .ok_or_else(|| MemexError::NotFound(format!("link {link_id}")))?;
    row_to_link(row).map_err(MemexError::from)
}

/// Patch shape for `update_link`. Each field uses an `Option` to express
/// "no change"; for `new_label`, an additional inner `Option` distinguishes
/// "clear label" (`Some(None)`) from "set label" (`Some(Some(s))`).
#[derive(Debug, Clone, Default)]
pub struct UpdateLink {
    pub new_kind: Option<LinkKind>,
    pub new_label: Option<Option<String>>,
}

/// Rewrite the `kind` and/or `label` on a single wikilink occurrence in the
/// source note's body. The title is never changed by this function — title
/// renames go through `notes::update_note`'s rename-links pass.
///
/// Behavior by `LinkSource`:
/// * `InlineBody`, `InlineSection`, `AutoAdded` — rewrites the `[[...]]` token
///   at the link's `position` in the source body, preserving the title and
///   updating the `~kind` / `|alias` segments.
/// * `Frontmatter` — only `new_label` is supported in v1; supplying
///   `new_kind` returns `InvalidLinkKind` ("frontmatter kind change not
///   supported"). Label changes rewrite the `[[Title|alias]]` token in place.
///
/// After the body is updated, the source note is saved through
/// `notes::update_note_as(rename_links: false)` and reindexed from the saved
/// note's body (matching the existing add-link path).
pub fn update_link(
    vault: &mut Vault,
    link_id: &str,
    patch: UpdateLink,
) -> Result<Link> {
    update_link_as(vault, link_id, patch, Caller::Person)
}

/// [`update_link`] on behalf of `caller` (architect ruling D3). The source note
/// is saved through `notes::update_note_as` with the same `caller`, so every
/// rule that guards agent note writes also guards link edits.
pub fn update_link_as(
    vault: &mut Vault,
    link_id: &str,
    patch: UpdateLink,
    caller: Caller,
) -> Result<Link> {
    let current = get_link(vault, link_id)?;

    // Resolve target kind + label, then determine whether anything needs to change.
    let new_kind = patch.new_kind.unwrap_or_else(|| current.link_kind.clone());
    let kind_changed = new_kind.as_str() != current.link_kind.as_str();
    let new_label: Option<String> = match patch.new_label {
        Some(maybe) => maybe.and_then(|s| if s.is_empty() { None } else { Some(s) }),
        None => current.label.clone(),
    };
    let label_changed = new_label != current.label;
    if !kind_changed && !label_changed {
        return Ok(current);
    }

    if kind_changed && matches!(current.source, LinkSource::Frontmatter) {
        return Err(MemexError::InvalidLinkKind(
            "frontmatter link kind cannot be changed via update_link in v1; \
             remove the link and re-add it under the desired kind"
                .into(),
        ));
    }

    let from_id = current.from_note_id.clone();
    let title = current.link_text.clone();

    // Read current source body + version.
    let (source_version, source_body): (i64, String) = vault
        .connection_ref()
        .query_row(
            "SELECT version, content_md FROM notes WHERE id = ?",
            params![from_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                MemexError::NotFound(format!("note {from_id}"))
            }
            other => MemexError::from(other),
        })?;

    // Locate the `[[...]]` token at `current.position`.
    let pos = current.position as usize;
    if pos >= source_body.len() || !source_body[pos..].starts_with("[[") {
        return Err(MemexError::NotFound(format!(
            "wikilink token not found at position {pos} in note {from_id}"
        )));
    }
    let close_rel = source_body[pos..]
        .find("]]")
        .ok_or_else(|| MemexError::NotFound(format!(
            "wikilink missing closing brackets at position {pos} in note {from_id}"
        )))?;
    let token_end = pos + close_rel + 2;

    // Build replacement. Frontmatter never carries `~kind` (the YAML key does).
    let include_kind = !matches!(current.source, LinkSource::Frontmatter);
    let new_token = render_wikilink_token(&title, &new_kind, new_label.as_deref(), include_kind);
    let mut new_body = String::with_capacity(source_body.len() + new_token.len());
    new_body.push_str(&source_body[..pos]);
    new_body.push_str(&new_token);
    new_body.push_str(&source_body[token_end..]);

    // Save via the standard update path so existing indexing wires in.
    let saved = crate::notes::update_note_as(
        vault,
        &crate::notes::NoteId::parse(&from_id)?,
        source_version,
        crate::notes::UpdateNote {
            content_md: Some(new_body),
            ..Default::default()
        },
        crate::notes::RenameOptions {
            rename_links: false,
        },
        caller,
    )?;
    // Reindex so the `links` row reflects the new kind/label. Index the body
    // the save returned, not `new_body`: a save may normalize it (D8).
    crate::indexer::reindex_note(vault.conn_mut(), &from_id, &saved.content_md, None)?;

    // The new link row sits at the same (from_note_id, position) because we
    // edited the `[[...]]` token in place; the leading `[[` byte offset is
    // unchanged.
    let new_link: Link = vault
        .connection_ref()
        .query_row(
            "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source
             FROM links WHERE from_note_id = ? AND position = ?",
            params![from_id, current.position],
            row_to_link,
        )
        .map_err(MemexError::from)?;
    Ok(new_link)
}

fn render_wikilink_token(
    title: &str,
    kind: &LinkKind,
    label: Option<&str>,
    include_kind: bool,
) -> String {
    let kind_seg = if include_kind && kind.as_str() != LinkKind::REFERENCES {
        format!("~{}", kind.as_str())
    } else {
        String::new()
    };
    let alias_seg = match label {
        Some(l) if !l.is_empty() => format!("|{l}"),
        _ => String::new(),
    };
    format!("[[{title}{kind_seg}{alias_seg}]]")
}

fn row_to_link(r: &rusqlite::Row<'_>) -> rusqlite::Result<Link> {
    Ok(Link {
        id: r.get(0)?,
        from_note_id: r.get(1)?,
        to_note_id: r.get(2)?,
        link_text: r.get(3)?,
        link_kind: r.get(4)?,
        label: r.get(5)?,
        position: r.get(6)?,
        source: r.get(7)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_basic() {
        assert_eq!(normalize("Extends"), "extends");
        assert_eq!(normalize("Inspired By"), "inspired-by");
        assert_eq!(normalize("Example Of"), "example-of");
        assert_eq!(normalize("  Spaced  Out  "), "spaced-out");
        assert_eq!(normalize("already-kebab"), "already-kebab");
        assert_eq!(normalize(""), "");
    }

    #[test]
    fn linkkind_accepts_built_ins() {
        for k in [LinkKind::REFERENCES, LinkKind::EXTENDS, LinkKind::CONTRADICTS, LinkKind::EXAMPLE_OF] {
            let lk = LinkKind::new(k).unwrap();
            assert!(lk.is_built_in());
        }
    }

    #[test]
    fn linkkind_accepts_user_defined() {
        let lk = LinkKind::new("inspired-by").unwrap();
        assert!(!lk.is_built_in());
        assert_eq!(lk.as_str(), "inspired-by");
    }

    #[test]
    fn linkkind_normalizes_input() {
        let lk = LinkKind::new("Inspired By").unwrap();
        assert_eq!(lk.as_str(), "inspired-by");
    }

    #[test]
    fn linkkind_rejects_invalid() {
        assert!(LinkKind::new("").is_err());
        assert!(LinkKind::new("9digits").is_err(), "must start with letter");
        assert!(LinkKind::new("with_underscore").is_err());
        assert!(LinkKind::new("with.dot").is_err());
        assert!(LinkKind::new("ä-non-ascii").is_err());
        let too_long = "a".repeat(MAX_KIND_LEN + 1);
        assert!(LinkKind::new(&too_long).is_err());
    }

    #[test]
    fn linkkind_strips_leading_and_trailing_dashes() {
        // Normalize strips leading/trailing dashes, so this becomes valid.
        let lk = LinkKind::new("-leading-dash").unwrap();
        assert_eq!(lk.as_str(), "leading-dash");
    }
}
