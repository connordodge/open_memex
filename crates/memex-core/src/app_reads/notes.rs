//! App API reads for notes (#81): the rows the app's `VaultDb` reads today,
//! for the notes routes of the vault server.

use std::collections::BTreeMap;

use rusqlite::{params, params_from_iter, OptionalExtension};
use serde::Serialize;
use serde_json::{Map, Value};

use crate::notes::{Note, NoteId};
use crate::{excerpts, links, review, tags, MemexError, Result, Vault};

/// A row of `GET /notes`: the app's `NoteListItem`, in snake case.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteListItem {
    pub id: String,
    pub title: String,
    pub snippet: String,
    pub version: i64,
    pub updated_at: i64,
}

/// `VaultDb.listNotes`: up to `limit` notes, newest `updated_at` first,
/// each with its [`snippet`].
pub fn list_notes(vault: &Vault, limit: i64) -> Result<Vec<NoteListItem>> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT id, title, content_md, version, updated_at FROM notes \
         ORDER BY updated_at DESC LIMIT ?",
    )?;
    let rows = stmt.query_map(params![limit], |r| {
        let content_md: String = r.get(2)?;
        Ok(NoteListItem {
            id: r.get(0)?,
            title: r.get(1)?,
            snippet: snippet(&content_md),
            version: r.get(3)?,
            updated_at: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// The longest first line kept whole, in UTF-16 units.
const SNIPPET_MAX_UNITS: usize = 120;

/// Where a longer line is cut, in UTF-16 units.
const SNIPPET_CUT_UNITS: usize = 117;

/// `VaultDb._snippet` (ruling D10b): heading markers stripped, the first
/// non-blank line, trimmed; a line over 120 UTF-16 units is cut to 117
/// units (116 when the cut would split a surrogate pair), trimmed, plus `…`.
pub fn snippet(content_md: &str) -> String {
    let stripped = strip_heading_markers(content_md);
    let first_line = stripped
        .split('\n')
        .find(|l| !dart_trim(l).is_empty())
        .unwrap_or("");
    if first_line.encode_utf16().count() <= SNIPPET_MAX_UNITS {
        return dart_trim(first_line).to_string();
    }
    // Whole chars up to the cut: a pair that would end past it is dropped.
    let mut units = 0;
    let mut end = 0;
    for (i, c) in first_line.char_indices() {
        if units + c.len_utf16() > SNIPPET_CUT_UNITS {
            break;
        }
        units += c.len_utf16();
        end = i + c.len_utf8();
    }
    format!("{}…", dart_trim(&first_line[..end]))
}

/// Dart's `content.replaceAll(RegExp(r'^#+\s*', multiLine: true), '')`:
/// at every line start (the text start, or after a JS line terminator), a
/// run of `#` and the JS whitespace after it (newlines included) is removed.
fn strip_heading_markers(content: &str) -> String {
    let mut out = String::with_capacity(content.len());
    let mut prev: Option<char> = None;
    let mut chars = content.chars().peekable();
    while let Some(c) = chars.next() {
        let line_start = prev.is_none_or(is_js_line_terminator);
        if c == '#' && line_start {
            let mut last = c;
            while let Some(&n) = chars.peek() {
                if n != '#' {
                    break;
                }
                last = n;
                chars.next();
            }
            while let Some(&n) = chars.peek() {
                if !is_js_whitespace(n) {
                    break;
                }
                last = n;
                chars.next();
            }
            prev = Some(last);
            continue;
        }
        out.push(c);
        prev = Some(c);
    }
    out
}

/// A JS `RegExp` line terminator (where a multi-line `^` matches after).
fn is_js_line_terminator(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// A JS `RegExp` `\s` character (Dart regexps follow JS): Unicode
/// `White_Space` without U+0085, plus the byte order mark U+FEFF.
fn is_js_whitespace(c: char) -> bool {
    (c.is_whitespace() && c != '\u{85}') || c == '\u{FEFF}'
}

/// A Dart `String.trim()` whitespace character: Unicode `White_Space` plus
/// the byte order mark U+FEFF.
fn is_dart_trim_whitespace(c: char) -> bool {
    c.is_whitespace() || c == '\u{FEFF}'
}

/// Dart's `String.trim()`.
fn dart_trim(s: &str) -> &str {
    s.trim_matches(is_dart_trim_whitespace)
}

/// `GET /notes/{note_id}`: the `memex get` object without links (the
/// `review`, `latest_change` and `transclusions` fields included).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NoteDetail {
    pub note_id: String,
    pub title: String,
    pub content_md: String,
    /// The stored frontmatter as JSON; the stored text as a JSON string when
    /// it is not valid JSON (`VaultDb.getNote` reads the text as is).
    pub frontmatter: Value,
    pub version: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub tags: Vec<String>,
    /// The tags the note's footer shows, sorted by name (R47).
    pub footer_tags: Vec<String>,
    #[serde(flatten)]
    pub fields: Map<String, Value>,
}

/// `VaultDb.getNote`: the note `id` with its tags, in the shape of
/// `memex get` (without links), plus `footer_tags`. Unlike the core read it
/// never refuses a note whose frontmatter is not valid JSON: that note gets
/// its frontmatter text as a string, and no role is read from it. An unknown
/// id is `NotFound`.
pub fn get_note(vault: &Vault, id: &NoteId) -> Result<NoteDetail> {
    let row = vault
        .connection_ref()
        .query_row(
            "SELECT title, content_md, frontmatter, version, created_at, updated_at \
             FROM notes WHERE id = ?",
            params![id.as_str()],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                ))
            },
        )
        .optional()?;
    let Some((title, content_md, frontmatter, version, created_at, updated_at)) = row else {
        return Err(MemexError::NotFound(format!("note {}", id.as_str())));
    };
    let frontmatter =
        serde_json::from_str::<Value>(&frontmatter).unwrap_or(Value::String(frontmatter));
    let note = Note {
        id: id.clone(),
        title,
        content_md,
        frontmatter,
        version,
        created_at,
        updated_at,
    };
    // Missing tags read as empty, as `memex get` always has.
    let tag_list = tags::tags_for_note(vault, note.id.as_str()).unwrap_or_default();
    let footer_tags = tags::footer_tags_for_note(vault, &note.id).unwrap_or_default();
    let mut fields = review::note_review_fields(vault, &note)?;
    fields.extend(excerpts::note_transclusion_fields(vault, &note)?);
    Ok(NoteDetail {
        note_id: note.id.to_string(),
        title: note.title,
        content_md: note.content_md,
        frontmatter: note.frontmatter,
        version: note.version,
        created_at: note.created_at,
        updated_at: note.updated_at,
        tags: tag_list,
        footer_tags,
        fields,
    })
}

/// A row of `GET /titles`: the app's `NoteTitle`, in snake case.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteTitle {
    pub id: String,
    pub title: String,
    pub updated_at: i64,
}

/// `VaultDb.allTitles`: up to `limit` (id, title) rows, newest first.
pub fn all_titles(vault: &Vault, limit: i64) -> Result<Vec<NoteTitle>> {
    let mut stmt = vault
        .connection_ref()
        .prepare("SELECT id, title, updated_at FROM notes ORDER BY updated_at DESC LIMIT ?")?;
    let rows = stmt.query_map(params![limit], |r| {
        Ok(NoteTitle {
            id: r.get(0)?,
            title: r.get(1)?,
            updated_at: r.get(2)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// A row of `GET /notes/{note_id}/links/out` and `/links/in`: the app's
/// `LinkRow`, in snake case.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkRow {
    pub id: String,
    pub from_note_id: String,
    pub to_note_id: Option<String>,
    pub link_text: String,
    pub kind: String,
    pub label: Option<String>,
    pub position: i64,
    pub source: String,
}

/// `VaultDb.linksOutFor`: the note's outgoing links by position.
pub fn links_out(vault: &Vault, note_id: &str) -> Result<Vec<LinkRow>> {
    Ok(links::links_out_for_note(vault, note_id)?
        .into_iter()
        .map(|l| LinkRow {
            id: l.id,
            from_note_id: l.from_note_id,
            to_note_id: l.to_note_id,
            link_text: l.link_text,
            kind: l.link_kind.as_str().to_string(),
            label: l.label,
            position: l.position,
            source: l.source.as_str().to_string(),
        })
        .collect())
}

/// `VaultDb.linksInFor`: the note's incoming links, only those whose kind is
/// exactly `kind` when given (matched as given, never parsed).
pub fn links_in(vault: &Vault, note_id: &str, kind: Option<&str>) -> Result<Vec<LinkRow>> {
    let where_kind = if kind.is_some() {
        " AND link_kind = ?"
    } else {
        ""
    };
    let sql = format!(
        "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source \
         FROM links WHERE to_note_id = ?{where_kind} \
         ORDER BY link_kind, from_note_id, position"
    );
    let mut args = vec![note_id];
    args.extend(kind);
    let mut stmt = vault.connection_ref().prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(args), |r| {
        Ok(LinkRow {
            id: r.get(0)?,
            from_note_id: r.get(1)?,
            to_note_id: r.get(2)?,
            link_text: r.get(3)?,
            kind: r.get(4)?,
            label: r.get(5)?,
            position: r.get(6)?,
            source: r.get(7)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// `VaultDb.titlesForIds`: id → title for the ids that exist.
pub fn titles_for_ids(vault: &Vault, ids: &[String]) -> Result<BTreeMap<String, String>> {
    if ids.is_empty() {
        return Ok(BTreeMap::new());
    }
    let placeholders = vec!["?"; ids.len()].join(",");
    let mut stmt = vault.connection_ref().prepare(&format!(
        "SELECT id, title FROM notes WHERE id IN ({placeholders})"
    ))?;
    let rows = stmt.query_map(params_from_iter(ids), |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// `VaultDb.distinctLinkKinds`: every kind in the links table, sorted. Unlike
/// `vault_settings::link_kinds`, no built-in kind is added.
pub fn distinct_link_kinds(vault: &Vault) -> Result<Vec<String>> {
    let mut stmt = vault
        .connection_ref()
        .prepare("SELECT DISTINCT link_kind FROM links ORDER BY link_kind")?;
    let rows = stmt.query_map([], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
