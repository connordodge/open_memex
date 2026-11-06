//! Tags: the inline `#tag` grammar (Spec #234 R4-R8, R20) and the `tags`
//! table helpers.
//!
//! The grammar contract is `app/test/fixtures/tags/grammar.json`, shared with
//! the Dart port (D17).

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use rusqlite::params;

use crate::blocks::is_list_item;
use crate::daily::TOPICS_MARKER;
use crate::link_extractor::{parse_transclusions, split_frontmatter, WIKILINK_RE};
use crate::vault::Vault;
use crate::Result;

/// The system tags (R20); `grammar.json` lists the same names (D17).
const SYSTEM_TAGS: [&str; 2] = ["inbox", "agent-authored"];

/// A tag name as written after `#`: a letter, then letters, marks, decimal
/// digits, `-` and `_` (R4). Trailing `-`/`_` are stripped separately.
static NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\A\p{L}[\p{L}\p{M}\p{Nd}_-]*").expect("compile tag name regex"));

/// A URL, from its scheme up to the next whitespace.
static URL_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z][A-Za-z0-9+.\-]*://\S*").expect("compile url regex"));

/// A markdown link or image: `[text](target)` / `![alt](target)`.
static MD_LINK_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[[^\]\n]*\]\([^)\n]*\)").expect("compile markdown link regex"));

/// A tag found in a person section: its lowercase name and the first line
/// holding it (Spec #234 R4-R8, WI #236).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractedTag {
    pub name: String,
    pub first_line: String,
}

/// The tags written in `person_text`, sorted by name, one per name.
///
/// A tag is `#` at line start, after whitespace or after one of `( [ { " '`,
/// followed by a name (see [`normalize_name`]); names are lowercased without
/// Unicode normalization. Nothing inside fenced code, code spans, URLs,
/// wikilinks, transclusion tokens or markdown links is a tag. `first_line` is
/// the first line holding the tag, trimmed, without its quote, list or task
/// box marker.
pub fn extract(person_text: &str) -> Vec<ExtractedTag> {
    let mut found: BTreeMap<String, String> = BTreeMap::new();
    let mut fence: Option<Fence> = None;
    for line in person_text.split('\n') {
        if let Some(open) = fence {
            if open.closed_by(line) {
                fence = None;
            }
            continue;
        }
        fence = Fence::opened_by(line);
        if fence.is_some() {
            continue;
        }
        for name in line_tags(line) {
            found
                .entry(name)
                .or_insert_with(|| first_line_text(line).to_string());
        }
    }
    found
        .into_iter()
        .map(|(name, first_line)| ExtractedTag { name, first_line })
        .collect()
}

/// The person section of a non-daily note body: above the first marker line
/// outside fenced code, without a leading frontmatter block.
///
/// A marker line is [`TOPICS_MARKER`] with only trailing spaces or `\r` after
/// it, as in `daily::split_body`. Without one the whole body (after any
/// frontmatter) is returned.
pub fn person_section(body: &str) -> &str {
    let (_, start) = split_frontmatter(body);
    let mut fence: Option<Fence> = None;
    let mut line_start = start;
    for line in body[start..].split_inclusive('\n') {
        let text = line.strip_suffix('\n').unwrap_or(line);
        if let Some(open) = fence {
            if open.closed_by(text) {
                fence = None;
            }
        } else if text.trim_end_matches([' ', '\r']) == TOPICS_MARKER {
            return &body[start..line_start];
        } else {
            fence = Fence::opened_by(text);
        }
        line_start += line.len();
    }
    &body[start..]
}

/// `Some(lowercase)` only when the whole `input` is one valid tag name.
pub fn normalize_name(input: &str) -> Option<String> {
    tag_name(input)
        .filter(|name| name.len() == input.len())
        .map(str::to_lowercase)
}

/// True only for the system tags `inbox` and `agent-authored` (R20, D17).
pub fn is_system_tag(name: &str) -> bool {
    SYSTEM_TAGS.contains(&name)
}

/// An open fenced code block: its fence character and run length.
#[derive(Debug, Clone, Copy)]
struct Fence {
    ch: char,
    len: usize,
}

impl Fence {
    /// The fence `line` opens: three or more backticks or tildes after any
    /// indentation. A backtick fence's info string holds no backtick.
    fn opened_by(line: &str) -> Option<Fence> {
        let trimmed = line.trim_start_matches([' ', '\t']);
        let ch = trimmed.chars().next().filter(|c| matches!(c, '`' | '~'))?;
        let info = trimmed.trim_start_matches(ch);
        let len = trimmed.len() - info.len();
        (len >= 3 && !(ch == '`' && info.contains('`'))).then_some(Fence { ch, len })
    }

    /// Whether `line` closes this fence: the same character, at least as many
    /// times, after any indentation, and nothing but whitespace after it.
    fn closed_by(self, line: &str) -> bool {
        let trimmed = line.trim_start_matches([' ', '\t']);
        let rest = trimmed.trim_start_matches(self.ch);
        trimmed.len() - rest.len() >= self.len && rest.trim().is_empty()
    }
}

/// The lowercase tag names on one line outside fenced code, in order.
fn line_tags(line: &str) -> Vec<String> {
    let hidden = hidden_ranges(line);
    let mut out = Vec::new();
    let mut prev: Option<char> = None;
    for (i, c) in line.char_indices() {
        if c == '#' && opens_tag(prev) && !hidden.iter().any(|r| r.contains(&i)) {
            if let Some(name) = tag_name(&line[i + 1..]) {
                out.push(name.to_lowercase());
            }
        }
        prev = Some(c);
    }
    out
}

/// Whether a `#` after `prev` (`None` at line start) can start a tag.
fn opens_tag(prev: Option<char>) -> bool {
    match prev {
        None => true,
        Some(c) => c.is_whitespace() || matches!(c, '(' | '[' | '{' | '"' | '\''),
    }
}

/// The tag name at the start of `text` (just after `#`), without trailing
/// `-`/`_`, as written.
fn tag_name(text: &str) -> Option<&str> {
    NAME_RE
        .find(text)
        .map(|m| m.as_str().trim_end_matches(['-', '_']))
}

/// Byte ranges of `line` where no tag can start: code spans, transclusion
/// tokens, wikilinks, markdown links and URLs.
fn hidden_ranges(line: &str) -> Vec<Range<usize>> {
    let mut hidden = code_spans(line);
    hidden.extend(
        parse_transclusions(line)
            .into_iter()
            .map(|t| t.start..t.end),
    );
    for re in [&*WIKILINK_RE, &*MD_LINK_RE, &*URL_RE] {
        hidden.extend(re.find_iter(line).map(|m| m.range()));
    }
    hidden
}

/// Code spans on one line: a backtick run up to the next run of the same
/// length. A run with no partner is plain text.
fn code_spans(line: &str) -> Vec<Range<usize>> {
    let bytes = line.as_bytes();
    let mut runs = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'`' {
            let start = i;
            while i < bytes.len() && bytes[i] == b'`' {
                i += 1;
            }
            runs.push((start, i - start));
        } else {
            i += 1;
        }
    }
    let mut spans = Vec::new();
    let mut k = 0;
    while k < runs.len() {
        let (start, len) = runs[k];
        match runs[k + 1..].iter().position(|&(_, l)| l == len) {
            Some(offset) => {
                let (close, _) = runs[k + 1 + offset];
                spans.push(start..close + len);
                k += offset + 2;
            }
            None => k += 1,
        }
    }
    spans
}

/// `line` trimmed, without a leading quote marker, list marker and task box.
fn first_line_text(line: &str) -> &str {
    let mut text = line.trim();
    if let Some(rest) = text.strip_prefix('>') {
        text = rest.trim_start();
    }
    if is_list_item(text) {
        // Every list marker (`- `, `* `, `+ `, `12. `) ends at its first space.
        text = text
            .split_once(' ')
            .map_or("", |(_, rest)| rest)
            .trim_start();
        text = strip_task_box(text);
    }
    text.trim()
}

/// `text` without a leading `[ ]`, `[x]` or `[X]` task box.
fn strip_task_box(text: &str) -> &str {
    ["[ ]", "[x]", "[X]"]
        .iter()
        .find_map(|b| text.strip_prefix(b))
        .filter(|rest| rest.is_empty() || rest.starts_with([' ', '\t']))
        .unwrap_or(text)
}

pub fn add_tag(vault: &Vault, note_id: &str, tag: &str) -> Result<()> {
    vault.connection_ref().execute(
        "INSERT OR IGNORE INTO tags (note_id, tag) VALUES (?, ?)",
        params![note_id, tag],
    )?;
    Ok(())
}

pub fn remove_tag(vault: &Vault, note_id: &str, tag: &str) -> Result<()> {
    vault.connection_ref().execute(
        "DELETE FROM tags WHERE note_id = ? AND tag = ?",
        params![note_id, tag],
    )?;
    Ok(())
}

pub fn tags_for_note(vault: &Vault, note_id: &str) -> Result<Vec<String>> {
    let mut stmt = vault
        .connection_ref()
        .prepare("SELECT tag FROM tags WHERE note_id = ? ORDER BY tag")?;
    let mut rows = stmt.query(params![note_id])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        out.push(r.get::<_, String>(0)?);
    }
    Ok(out)
}
