//! Tags: the inline `#tag` grammar (Spec #234 R4-R8, R20), the `tags` table
//! helpers, and the rules for who may write which tag (R3, R9, R34-R40, R53).
//!
//! The grammar contract is `app/test/fixtures/tags/grammar.json`, shared with
//! the Dart port (D17).

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use rusqlite::{params, Connection, OptionalExtension};

use crate::blocks::is_list_item;
use crate::daily::{self, TOPICS_MARKER};
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::footer;
use crate::link_extractor::{parse_transclusions, split_frontmatter, WIKILINK_RE};
use crate::notes::{self, Note, NoteId};
use crate::vault::{now_unix_ms, Vault};
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

/// Why a note has a tag (Spec #234 TD1): written as `#name` in its person
/// section (`body`), applied by an agent (`agent`) or added by the person
/// without writing it (`person`). `body` outranks the others.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TagOrigin {
    Body,
    Agent,
    Person,
}

/// The result of a tag write: whether a row changed, and the note's
/// `version` after the call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagWrite {
    pub changed: bool,
    pub version: i64,
}

/// The result of a tag removal: whether a row went, the `tag_corrections` id
/// it recorded (agent-origin removals only), and the note's `version` after
/// the call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagRemoval {
    pub removed: bool,
    pub correction_id: Option<i64>,
    pub version: i64,
}

/// A tag name and how many notes carry it from any origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagCount {
    pub tag: String,
    pub note_count: i64,
    pub system: bool,
}

/// A note carrying a tag, for the Tags mode listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagNote {
    pub note_id: String,
    pub title: String,
    pub role: Option<String>,
    pub first_line: Option<String>,
    pub updated_at: i64,
}

impl TagOrigin {
    /// The stored `tags.origin` value.
    fn as_str(self) -> &'static str {
        match self {
            TagOrigin::Body => "body",
            TagOrigin::Agent => "agent",
            TagOrigin::Person => "person",
        }
    }

    /// Reads a stored origin. The schema allows only `body`, `agent` and
    /// `person`.
    fn from_stored(origin: &str) -> Self {
        match origin {
            "body" => TagOrigin::Body,
            "agent" => TagOrigin::Agent,
            _ => TagOrigin::Person,
        }
    }
}

/// Makes the `body` rows of `note_id` match the `#name`s in the person section
/// of `body` (Spec #234 R3, R9), inside the caller's write transaction and
/// before it renders the footer from the rows.
///
/// A new name gets a `body` row, a body-less row of that name becomes `body`,
/// and a `body` row with no `#name` left goes; `agent` and `person` rows not
/// in the text stay. Open blocks on each written name are cleared (R35), and
/// the Correction rows stay. A row that already matches is not written.
pub(crate) fn reconcile_body_tags(
    conn: &Connection,
    note_id: &str,
    body: &str,
    is_daily: bool,
    now: i64,
) -> Result<()> {
    let written = if is_daily {
        extract(&daily::split_body(body).person)
    } else {
        extract(person_section(&daily::split_note_body(body).person))
    };
    let stored = stored_rows(conn, note_id)?;
    for (name, (origin, _)) in &stored {
        if origin == "body" && !written.iter().any(|tag| &tag.name == name) {
            conn.execute(
                "DELETE FROM tags WHERE note_id = ? AND tag = ?",
                params![note_id, name],
            )?;
        }
    }
    for tag in &written {
        let matches = stored.get(&tag.name).is_some_and(|(origin, line)| {
            origin == "body" && line.as_deref() == Some(tag.first_line.as_str())
        });
        if !matches {
            conn.execute(
                "INSERT INTO tags (note_id, tag, origin, first_line) VALUES (?, ?, 'body', ?)
                 ON CONFLICT (note_id, tag) DO UPDATE
                 SET origin = 'body', first_line = excluded.first_line",
                params![note_id, tag.name, tag.first_line],
            )?;
        }
        lift_block(conn, note_id, &tag.name, now)?;
    }
    Ok(())
}

/// The `tags` rows of a note: name to `(origin, first_line)`.
fn stored_rows(
    conn: &Connection,
    note_id: &str,
) -> Result<BTreeMap<String, (String, Option<String>)>> {
    let mut stmt = conn.prepare("SELECT tag, origin, first_line FROM tags WHERE note_id = ?")?;
    let rows = stmt
        .query_map([note_id], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?))))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(rows)
}

/// Sets `cleared_at` on the open Corrections for this note and tag. Rows are
/// never deleted, and one already cleared keeps its time (TD2).
fn lift_block(conn: &Connection, note_id: &str, tag: &str, now: i64) -> Result<()> {
    conn.execute(
        "UPDATE tag_corrections SET cleared_at = ?
         WHERE note_id = ? AND tag = ? AND cleared_at IS NULL",
        params![now, note_id, tag],
    )?;
    Ok(())
}

/// Removes every row a footer renders from on a note becoming `role: guide`,
/// in that save (R53). Its Corrections stay.
pub(crate) fn clear_guide_rows(conn: &Connection, note_id: &str) -> Result<()> {
    conn.execute("DELETE FROM tags WHERE note_id = ?", [note_id])?;
    conn.execute(
        "DELETE FROM footer_chips WHERE daily_note_id = ?",
        [note_id],
    )?;
    Ok(())
}

/// A tag input without one leading `#` (R38: `#Pricing` in a call).
fn bare_name(input: &str) -> &str {
    input.strip_prefix('#').unwrap_or(input)
}

/// The row of `note_id` a tag input means, as `(stored name, origin)` (R38):
/// the input exactly, then without a leading `#`, then lowercased.
fn stored_tag(
    conn: &Connection,
    note_id: &str,
    input: &str,
) -> Result<Option<(String, TagOrigin)>> {
    let bare = bare_name(input);
    for name in [input.to_string(), bare.to_string(), bare.to_lowercase()] {
        let origin: Option<String> = conn
            .query_row(
                "SELECT origin FROM tags WHERE note_id = ? AND tag = ?",
                params![note_id, name],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(origin) = origin {
            return Ok(Some((name, TagOrigin::from_stored(&origin))));
        }
    }
    Ok(None)
}

/// The note `note_id` when it may be tagged: any note but a `role: guide` one
/// (`GuideRule`, R53). An unknown id is `NotFound`.
fn tag_host(vault: &Vault, note_id: &NoteId) -> Result<Note> {
    let note = notes::get_note(vault, note_id)?;
    if notes::is_guide(&note.frontmatter) {
        return Err(MemexError::GuideRule(format!(
            "note {note_id} is the Vault Guide (role: guide), which has no tags"
        )));
    }
    Ok(note)
}

/// The issue's `InvalidArgument`, in the crate's `Io(InvalidInput)` form.
fn invalid_argument(message: String) -> MemexError {
    MemexError::Io(std::io::Error::new(
        std::io::ErrorKind::InvalidInput,
        message,
    ))
}

/// Re-renders the footer after a row of `name` changed and returns the note's
/// version. A system tag has no footer line (R20), so its rows write no note.
fn version_after_row_write(
    vault: &mut Vault,
    note: &Note,
    name: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<i64> {
    if is_system_tag(name) {
        return Ok(note.version);
    }
    Ok(footer::rerender_footer(vault, &note.id, embedder)?.version)
}

/// Adds the row `name` with `origin` and its footer line. A person adding the
/// tag lifts its block (R35).
fn insert_row(
    vault: &mut Vault,
    note: &Note,
    name: &str,
    origin: TagOrigin,
    embedder: Option<&dyn Embedder>,
) -> Result<TagWrite> {
    let tx = vault.conn_mut().transaction()?;
    tx.execute(
        "INSERT INTO tags (note_id, tag, origin) VALUES (?, ?, ?)",
        params![note.id.as_str(), name, origin.as_str()],
    )?;
    if origin == TagOrigin::Person {
        lift_block(&tx, note.id.as_str(), name, now_unix_ms())?;
    }
    tx.commit()?;
    Ok(TagWrite {
        changed: true,
        version: version_after_row_write(vault, note, name, embedder)?,
    })
}

/// Deletes the row `name` and re-renders the footer. With `record`, the
/// Correction goes in with the delete, or neither happens (TD2).
fn delete_row(
    vault: &mut Vault,
    note: &Note,
    name: &str,
    record: bool,
    embedder: Option<&dyn Embedder>,
) -> Result<TagRemoval> {
    let tx = vault.conn_mut().transaction()?;
    tx.execute(
        "DELETE FROM tags WHERE note_id = ? AND tag = ?",
        params![note.id.as_str(), name],
    )?;
    let correction_id = if record {
        tx.execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at)
             VALUES (?, ?, ?, 'removed', ?)",
            params![note.id.as_str(), note.title, name, now_unix_ms()],
        )?;
        Some(tx.last_insert_rowid())
    } else {
        None
    };
    tx.commit()?;
    Ok(TagRemoval {
        removed: true,
        correction_id,
        version: version_after_row_write(vault, note, name, embedder)?,
    })
}

/// Applies `tag` to `note_id` with `origin`, whatever its name (D16, R40:
/// `create_note`, `memex add`), with its footer line in the same call unless
/// it is a system tag.
///
/// A tag the note already has writes nothing and keeps its origin. A guide is
/// `GuideRule`, an unknown note `NotFound`, and a name outside the grammar or
/// the origin `Body` (only text makes a body tag) `Io(InvalidInput)`.
pub fn apply_tag(
    vault: &mut Vault,
    note_id: &NoteId,
    tag: &str,
    origin: TagOrigin,
    embedder: Option<&dyn Embedder>,
) -> Result<TagWrite> {
    let note = tag_host(vault, note_id)?;
    if origin == TagOrigin::Body {
        return Err(invalid_argument(
            "a body tag comes from the note's text and can't be applied".to_string(),
        ));
    }
    if stored_tag(vault.connection_ref(), note_id.as_str(), tag)?.is_some() {
        return Ok(TagWrite {
            changed: false,
            version: note.version,
        });
    }
    let name = normalize_name(bare_name(tag))
        .ok_or_else(|| invalid_argument(format!("{tag:?} is not a valid tag name")))?;
    insert_row(vault, &note, &name, origin, embedder)
}

/// The agent's `tag_note` (R38): applies a vocabulary tag, agent-origin.
///
/// Checks in order: `NotFound`, `GuideRule`, then a tag the note already has
/// succeeds with no write whatever its name, then `UnknownTag` (not in the
/// [`vocabulary`], including a name outside the grammar) and `TagRemoved` (an
/// open block on this note and tag, R35).
pub fn agent_tag_note(
    vault: &mut Vault,
    note_id: &NoteId,
    tag: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<TagWrite> {
    let note = tag_host(vault, note_id)?;
    if stored_tag(vault.connection_ref(), note_id.as_str(), tag)?.is_some() {
        return Ok(TagWrite {
            changed: false,
            version: note.version,
        });
    }
    let known = vocabulary(vault)?;
    let name = normalize_name(bare_name(tag))
        .filter(|name| known.iter().any(|t| &t.tag == name))
        .ok_or_else(|| {
            MemexError::UnknownTag(format!(
                "{tag:?} is not in the vocabulary: list_tags shows the tags the person has written"
            ))
        })?;
    let blocked: bool = vault.connection_ref().query_row(
        "SELECT EXISTS (SELECT 1 FROM tag_corrections
                        WHERE note_id = ? AND tag = ? AND cleared_at IS NULL)",
        params![note_id.as_str(), name],
        |r| r.get(0),
    )?;
    if blocked {
        return Err(MemexError::TagRemoved(format!(
            "the person removed #{name} from note {note_id}: don't apply it again"
        )));
    }
    insert_row(vault, &note, &name, TagOrigin::Agent, embedder)
}

/// The agent's `untag_note` (R38): removes an agent-origin non-system tag and
/// records no Correction, so no block follows. Any other origin or a system
/// tag is `Io(InvalidInput)`, a guide `GuideRule`, an unknown note `NotFound`;
/// a tag the note doesn't have returns `removed: false`.
pub fn agent_untag_note(
    vault: &mut Vault,
    note_id: &NoteId,
    tag: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<TagRemoval> {
    let note = tag_host(vault, note_id)?;
    let Some((name, origin)) = stored_tag(vault.connection_ref(), note_id.as_str(), tag)? else {
        return Ok(TagRemoval {
            removed: false,
            correction_id: None,
            version: note.version,
        });
    };
    if origin != TagOrigin::Agent || is_system_tag(&name) {
        return Err(invalid_argument(format!(
            "#{name} wasn't applied by an agent, so untag_note can't remove it"
        )));
    }
    delete_row(vault, &note, &name, false, embedder)
}

/// `memex tag add` (R35, R53): a body-less person-origin tag, with its footer
/// line. It lifts the tag's block on this note. See [`apply_tag`] for the
/// errors and for a tag the note already has.
pub fn person_add_tag(
    vault: &mut Vault,
    note_id: &NoteId,
    tag: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<TagWrite> {
    apply_tag(vault, note_id, tag, TagOrigin::Person, embedder)
}

/// `memex tag rm` and the footer × (R20, R34, R37).
///
/// An agent-origin non-system tag goes with one Correction row, which blocks
/// the agent from re-applying it to this note (R35). A person-origin or system
/// tag goes with none. A `body` row, system tag or not, is `Io(InvalidInput)`
/// saying to delete the text: it would come back on the next save. A tag the
/// note doesn't have returns `removed: false`, and an unknown note is
/// `NotFound`. A daily note's review state doesn't move.
pub fn person_remove_tag(
    vault: &mut Vault,
    note_id: &NoteId,
    tag: &str,
    embedder: Option<&dyn Embedder>,
) -> Result<TagRemoval> {
    let note = notes::get_note(vault, note_id)?;
    let Some((name, origin)) = stored_tag(vault.connection_ref(), note_id.as_str(), tag)? else {
        return Ok(TagRemoval {
            removed: false,
            correction_id: None,
            version: note.version,
        });
    };
    if origin == TagOrigin::Body {
        return Err(invalid_argument(format!(
            "#{name} is written in the note: delete the text to remove it"
        )));
    }
    let record = origin == TagOrigin::Agent && !is_system_tag(&name);
    delete_row(vault, &note, &name, record, embedder)
}

/// One tag name across the vault.
struct TagTally {
    count: TagCount,
    /// A `body` row on a non-guide note holds it.
    written: bool,
}

/// Every tag name, alphabetically, ignoring ASCII case. Malformed frontmatter
/// reads as not a guide.
fn tag_tallies(vault: &Vault) -> Result<Vec<TagTally>> {
    let conn = vault.connection_ref();
    let mut stmt = conn.prepare(
        "SELECT t.tag, t.origin, n.frontmatter FROM tags t JOIN notes n ON n.id = t.note_id
         ORDER BY t.tag COLLATE NOCASE, t.tag",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut tallies: Vec<TagTally> = Vec::new();
    for row in rows {
        let (tag, origin, frontmatter) = row?;
        let written =
            origin == "body" && !notes::is_guide(&notes::lenient_frontmatter(&frontmatter));
        match tallies.last_mut() {
            Some(last) if last.count.tag == tag => {
                last.count.note_count += 1;
                last.written |= written;
            }
            _ => tallies.push(TagTally {
                count: TagCount {
                    system: is_system_tag(&tag),
                    tag,
                    note_count: 1,
                },
                written,
            }),
        }
    }
    Ok(tallies)
}

/// The vocabulary (R38): names with a `body` row on a non-guide note, without
/// system tags, alphabetically. `note_count` counts notes from any origin.
pub fn vocabulary(vault: &Vault) -> Result<Vec<TagCount>> {
    Ok(tag_tallies(vault)?
        .into_iter()
        .filter(|tally| tally.written && !tally.count.system)
        .map(|tally| tally.count)
        .collect())
}

/// Every tag with its note count, alphabetically, system tags included (R27).
pub fn all_tags(vault: &Vault) -> Result<Vec<TagCount>> {
    Ok(tag_tallies(vault)?
        .into_iter()
        .map(|tally| tally.count)
        .collect())
}

/// The notes with a row named exactly `tag`, most recently updated first, then
/// by id (R28). `first_line` is `None` on a body-less tag.
pub fn notes_for_tag(vault: &Vault, tag: &str) -> Result<Vec<TagNote>> {
    let conn = vault.connection_ref();
    let mut stmt = conn.prepare(
        "SELECT n.id, n.title, n.frontmatter, t.first_line, n.updated_at
         FROM tags t JOIN notes n ON n.id = t.note_id
         WHERE t.tag = ? ORDER BY n.updated_at DESC, n.id",
    )?;
    let notes = stmt
        .query_map([tag], |r| {
            let frontmatter: String = r.get(2)?;
            Ok(TagNote {
                note_id: r.get(0)?,
                title: r.get(1)?,
                role: notes::lenient_frontmatter(&frontmatter)
                    .get("role")
                    .and_then(|role| role.as_str())
                    .map(str::to_string),
                first_line: r.get(3)?,
                updated_at: r.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;
    Ok(notes)
}

/// What the agent can remove from a note (R39): its agent-origin non-system
/// tags, sorted by name. An unknown note has none.
pub fn agent_tags_for_note(vault: &Vault, note_id: &NoteId) -> Result<Vec<String>> {
    let conn = vault.connection_ref();
    let mut stmt =
        conn.prepare("SELECT tag FROM tags WHERE note_id = ? AND origin = 'agent' ORDER BY tag")?;
    let names = stmt
        .query_map([note_id.as_str()], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(names
        .into_iter()
        .filter(|name| !is_system_tag(name))
        .collect())
}

/// The tags a note's footer shows, sorted by name (R11, R19, R20).
pub fn footer_tags_for_note(vault: &Vault, note_id: &NoteId) -> Result<Vec<String>> {
    daily::render_footer_tags(vault.connection_ref(), note_id.as_str())
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
