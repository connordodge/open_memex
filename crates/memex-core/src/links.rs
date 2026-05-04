//! Wikilink storage. Mirrors the `tags.rs` shape: small free functions over
//! `&Vault`, plus type-safe wrappers (`LinkKind`, `LinkSource`) for the
//! columns whose values are constrained.

use std::str::FromStr;

use rusqlite::types::{FromSql, FromSqlError, ToSqlOutput, ValueRef};
use rusqlite::{params, Connection, ToSql};
use serde::{Deserialize, Serialize};
use ulid::Ulid;

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
