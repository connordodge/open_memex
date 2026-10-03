//! Excerpts: filing blocks of a daily note into a topic note as transclusion
//! tokens (Req 14, 31; CONTRACTS C4).
//!
//! This module owns the excerpt syntax a topic note holds: one
//! `![[<date>#^<from>(..^<to>)?]]` token per maximal run of consecutive
//! blocks, under a `## <date>` heading. Agents never hand-write it. Parsing
//! and rendering are `transclusion`'s (D13); footer chips are `footer`'s
//! (D11).

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rusqlite::params;
use serde_json::{json, Map, Value};

use crate::caller::Caller;
use crate::daily;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::footer::{self, ChipOrigin, RemoveMode};
use crate::indexer;
use crate::links;
use crate::notes::{self, Note, NoteId, RenameOptions, UpdateNote};
use crate::transclusion::{self, parse_transclusions, TransclusionToken};
use crate::vault::Vault;
use crate::Result;

/// The frontmatter `role` value of a topic note. The match is exact.
const TOPIC_ROLE: &str = "topic";

/// How many times an excerpt write reads the topic note and tries to save it
/// before giving up with `VersionConflict` (Req 31).
pub(crate) const WRITE_ATTEMPTS: u32 = 5;

/// Files the blocks `block_ids` of the daily note dated `date` into the topic
/// note `topic_note_id` (Req 14): one transclusion token per maximal run of
/// consecutive (by `ord`) blocks, in ord order, under a `## <date>` heading
/// (created at the end of the body when absent), and an `excerpt` chip for
/// the topic on that day's Topics footer (`footer::set_chip`). A block the
/// topic already holds for that day is not added twice.
///
/// The topic note is written through `notes::update_note_as` as `caller`,
/// re-reading and retrying when a person save races it (Req 31); the daily
/// note's content version and review state never change. Every written note
/// is reindexed from the stored body with `embedder` (D8).
///
/// Returns the topic note as stored after the call (`version` is its new
/// version). Errors: `RoleRule` (topic not `role: topic`), `NotFound`
/// (unknown topic, no daily note for `date`), `InvalidDate`, `BlockNotFound`,
/// `VersionConflict` (every retry raced).
pub fn add_excerpt(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
) -> Result<Note> {
    add_excerpt_with_hook(
        vault,
        topic_note_id,
        date,
        block_ids,
        caller,
        embedder,
        &mut |_| {},
    )
}

/// [`add_excerpt`] with a test seam: `before_write` runs once per attempt,
/// after the attempt has read the topic note and before it writes it.
///
/// Duplicate ids count once. An empty `block_ids` is rejected before
/// anything is read. When every requested block is already in the topic
/// nothing is written to it (its version stays); the chip is still ensured.
#[doc(hidden)]
pub fn add_excerpt_with_hook(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<Note> {
    let ids = requested_ids(block_ids)?;
    daily::parse_iso_date(date)?;
    topic_note(vault, topic_note_id)?;
    let day = daily_note_for_date(vault, date)?
        .ok_or_else(|| MemexError::NotFound(format!("no daily note for {date}")))?;
    let blocks = DayBlocks::load(vault, &day)?;
    let wanted = ids
        .iter()
        .map(|id| {
            blocks
                .ord_of(id)
                .ok_or_else(|| MemexError::BlockNotFound(format!("{id} in the daily note {date}")))
        })
        .collect::<Result<BTreeSet<i64>>>()?;

    let topic = write_topic(
        vault,
        topic_note_id,
        caller,
        embedder,
        before_write,
        |body| {
            let held = held_ords(body, date, &blocks);
            let tokens: Vec<String> = runs(wanted.difference(&held).copied())
                .into_iter()
                .map(|(first, last)| blocks.token(date, first, last))
                .collect();
            Ok((!tokens.is_empty()).then(|| insert_tokens(body, date, &tokens)))
        },
    )?;
    // The chip goes on only once the topic holds the excerpt: a call that
    // gives up leaves neither behind.
    footer::set_chip(vault, &day, topic_note_id, ChipOrigin::Excerpt, embedder)?;
    Ok(topic)
}

/// Reverses [`add_excerpt`]: removes every transclusion token for `date`
/// whose endpoints are `block_ids` (first id = the token's `from`, last id =
/// its `to`, or its only id), the `## <date>` heading when nothing else
/// remains under it, and the topic's footer chip on that day when the topic
/// holds no other excerpt from it and the chip's origin is `excerpt`
/// (`RemoveMode::ExcerptOnly`; a `person` chip stays).
///
/// Retries like [`add_excerpt`]; returns the topic note as stored after the
/// call. Errors: `RoleRule`, `NotFound` (unknown topic, or no matching
/// token), `InvalidDate`, `VersionConflict`.
pub fn remove_excerpt(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
) -> Result<Note> {
    remove_excerpt_with_hook(
        vault,
        topic_note_id,
        date,
        block_ids,
        caller,
        embedder,
        &mut |_| {},
    )
}

/// [`remove_excerpt`] with the same test seam as [`add_excerpt_with_hook`].
///
/// A token matches only with both endpoints equal: a single id never
/// matches a range token and two ids never match a single-block token. A
/// token still matches when its daily note or blocks are gone.
#[doc(hidden)]
pub fn remove_excerpt_with_hook(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<Note> {
    let ids = requested_ids(block_ids)?;
    daily::parse_iso_date(date)?;
    let from = ids[0];
    let to = (ids.len() > 1).then(|| ids[ids.len() - 1]);

    let topic = write_topic(
        vault,
        topic_note_id,
        caller,
        embedder,
        before_write,
        |body| {
            let matched: Vec<TransclusionToken> = parse_transclusions(body)
                .into_iter()
                .filter(|t| t.date == date && t.from == from && t.to.as_deref() == to)
                .collect();
            if matched.is_empty() {
                let range = to.map(|to| format!("..^{to}")).unwrap_or_default();
                return Err(MemexError::NotFound(format!(
                    "no transclusion ![[{date}#^{from}{range}]] in note {topic_note_id}"
                )));
            }
            Ok(Some(remove_tokens(body, date, &matched)))
        },
    )?;

    let day_still_excerpted = parse_transclusions(&topic.content_md)
        .iter()
        .any(|t| t.date == date);
    if !day_still_excerpted {
        if let Some(day) = daily_note_for_date(vault, date)? {
            footer::remove_chip(
                vault,
                &day,
                topic_note_id,
                RemoveMode::ExcerptOnly,
                embedder,
            )?;
        }
    }
    Ok(topic)
}

/// Transclusion fields merged into the top level of MCP `get_note` and CLI
/// `memex get` (architect ruling D7): `transclusions`, one
/// `{date, from, to, text}` per token of the note's body in body order, the
/// text rendered by the C4 render rule (`transclusion::render_all`). Empty
/// (no key) for a note without transclusion tokens.
pub fn note_transclusion_fields(vault: &Vault, note: &Note) -> Result<Map<String, Value>> {
    let rendered = transclusion::render_all(vault.connection_ref(), &note.content_md)?;
    let mut fields = Map::new();
    if !rendered.is_empty() {
        let entries = rendered
            .into_iter()
            .map(|r| json!({ "date": r.date, "from": r.from, "to": r.to, "text": r.text }))
            .collect();
        fields.insert("transclusions".into(), Value::Array(entries));
    }
    Ok(fields)
}

/// `block_ids` without repeats, in first-seen order. Empty is an error.
fn requested_ids(block_ids: &[String]) -> Result<Vec<&str>> {
    if block_ids.is_empty() {
        return Err(MemexError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "no block ids given",
        )));
    }
    let mut seen = BTreeSet::new();
    Ok(block_ids
        .iter()
        .map(String::as_str)
        .filter(|id| seen.insert(*id))
        .collect())
}

/// The note `id`, which must be `role: topic` (`RoleRule`).
fn topic_note(vault: &Vault, id: &NoteId) -> Result<Note> {
    let note = notes::get_note(vault, id)?;
    if note.frontmatter.get("role").and_then(Value::as_str) != Some(TOPIC_ROLE) {
        return Err(MemexError::RoleRule(format!(
            "note {id} is not a topic note (role: topic)"
        )));
    }
    Ok(note)
}

/// The `role: daily` note titled `date`, if any (D27: the one lookup is
/// `links::daily_note_id_for_title`).
fn daily_note_for_date(vault: &Vault, date: &str) -> Result<Option<NoteId>> {
    links::daily_note_id_for_title(vault.connection_ref(), date)?
        .map(|id| NoteId::parse(&id))
        .transpose()
}

/// Reads the topic note, lets `edit` compute its new body (`None`: nothing
/// to write) and saves it as `caller`, re-reading and retrying on
/// `VersionConflict` up to [`WRITE_ATTEMPTS`] times. `before_write` runs
/// between the read and the save of every attempt that saves. The saved note
/// is reindexed from its stored body (D8); with nothing to write the note is
/// returned as read.
fn write_topic(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault),
    mut edit: impl FnMut(&str) -> Result<Option<String>>,
) -> Result<Note> {
    let mut attempt = 1;
    loop {
        let current = topic_note(vault, topic_note_id)?;
        let Some(body) = edit(&current.content_md)? else {
            return Ok(current);
        };
        before_write(vault);
        let saved = notes::update_note_as(
            vault,
            topic_note_id,
            current.version,
            UpdateNote {
                content_md: Some(body),
                ..Default::default()
            },
            RenameOptions::default(),
            caller,
        );
        match saved {
            Ok(note) => {
                indexer::reindex_note(
                    vault.connection_mut(),
                    note.id.as_str(),
                    &note.content_md,
                    embedder,
                )?;
                return Ok(note);
            }
            Err(MemexError::VersionConflict { .. }) if attempt < WRITE_ATTEMPTS => attempt += 1,
            Err(e) => return Err(e),
        }
    }
}

/// The stored blocks of one daily note, by id and by ord.
struct DayBlocks {
    ords: HashMap<String, i64>,
    ids: BTreeMap<i64, String>,
}

impl DayBlocks {
    fn load(vault: &Vault, day: &NoteId) -> Result<Self> {
        let mut stmt = vault
            .connection_ref()
            .prepare("SELECT block_id, ord FROM blocks WHERE note_id = ?")?;
        let rows = stmt
            .query_map(params![day.as_str()], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Self {
            ids: rows.iter().map(|(id, ord)| (*ord, id.clone())).collect(),
            ords: rows.into_iter().collect(),
        })
    }

    fn ord_of(&self, id: &str) -> Option<i64> {
        self.ords.get(id).copied()
    }

    /// The token for the blocks at `first..=last` of the day `date`.
    fn token(&self, date: &str, first: i64, last: i64) -> String {
        let from = &self.ids[&first];
        if first == last {
            format!("![[{date}#^{from}]]")
        } else {
            format!("![[{date}#^{from}..^{}]]", self.ids[&last])
        }
    }
}

/// The ords of the day `date` that a token of `body` already covers. A token
/// whose endpoints no longer resolve covers nothing.
fn held_ords(body: &str, date: &str, blocks: &DayBlocks) -> BTreeSet<i64> {
    let mut held = BTreeSet::new();
    for token in parse_transclusions(body) {
        if token.date != date {
            continue;
        }
        let Some(from) = blocks.ord_of(&token.from) else {
            continue;
        };
        let to = match &token.to {
            None => Some(from),
            Some(to) => blocks.ord_of(to),
        };
        if let Some(to) = to {
            held.extend(from.min(to)..=from.max(to));
        }
    }
    held
}

/// Maximal runs of consecutive values of the ascending `ords`, as
/// `(first, last)`.
fn runs(ords: impl IntoIterator<Item = i64>) -> Vec<(i64, i64)> {
    let mut out: Vec<(i64, i64)> = Vec::new();
    for ord in ords {
        match out.last_mut() {
            Some((_, last)) if ord == *last + 1 => *last = ord,
            _ => out.push((ord, ord)),
        }
    }
    out
}

/// `body` split into lines, each with its `\n` (the last may lack one).
fn lines(body: &str) -> Vec<&str> {
    body.split_inclusive('\n').collect()
}

fn is_blank(line: &str) -> bool {
    line.trim().is_empty()
}

fn heading_for(date: &str) -> String {
    format!("## {date}")
}

/// Whether `line` opens a section that ends the one before it.
fn is_section_heading(line: &str) -> bool {
    line.starts_with("## ")
}

/// `body` with `tokens` (one per line, a blank line between) at the end of
/// the `## <date>` section, after its last non-blank line. Without such a
/// heading, the heading and the tokens are appended at the end, on their own
/// lines. Every other byte is kept.
fn insert_tokens(body: &str, date: &str, tokens: &[String]) -> String {
    let heading = heading_for(date);
    let block = tokens.join("\n\n");
    let lines = lines(body);
    let Some(h) = lines.iter().position(|l| l.trim_end() == heading) else {
        let sep = match body {
            "" => "",
            b if b.ends_with('\n') => "\n",
            _ => "\n\n",
        };
        return format!("{body}{sep}{heading}\n\n{block}\n");
    };
    let section_end = (h + 1..lines.len())
        .find(|&i| is_section_heading(lines[i]))
        .unwrap_or(lines.len());
    let content_end = (h..section_end)
        .rev()
        .find(|&i| !is_blank(lines[i]))
        .unwrap_or(h);
    let split: usize = lines[..=content_end].iter().map(|l| l.len()).sum();
    let (before, after) = body.split_at(split);
    let sep = if before.ends_with('\n') { "\n" } else { "\n\n" };
    format!("{before}{sep}{block}\n{after}")
}

/// `body` without the `matched` tokens. A line left blank by the removal
/// goes, a `## <date>` heading with nothing left under it goes with its
/// section's blank lines, and where lines went the blank lines around them
/// collapse to one (none at the start or end of the body).
fn remove_tokens(body: &str, date: &str, matched: &[TransclusionToken]) -> String {
    let lines = lines(body);
    let mut text: Vec<String> = Vec::with_capacity(lines.len());
    let mut deleted: Vec<bool> = Vec::with_capacity(lines.len());
    let mut start = 0;
    for line in &lines {
        let end = start + line.len();
        let mut kept = String::new();
        let mut cursor = start;
        let mut touched = false;
        for t in matched.iter().filter(|t| t.start >= start && t.end <= end) {
            kept.push_str(&body[cursor..t.start]);
            cursor = t.end;
            touched = true;
        }
        kept.push_str(&body[cursor..end]);
        deleted.push(touched && is_blank(&kept));
        text.push(kept);
        start = end;
    }

    let heading = heading_for(date);
    for h in 0..lines.len() {
        if lines[h].trim_end() != heading {
            continue;
        }
        let section_end = (h + 1..lines.len())
            .find(|&i| is_section_heading(lines[i]))
            .unwrap_or(lines.len());
        // A removed line's text is blank too.
        if (h + 1..section_end).all(|i| is_blank(&text[i])) {
            deleted[h..section_end].fill(true);
        }
    }

    let mut dropped = deleted.clone();
    let mut i = 0;
    while i < lines.len() {
        if !deleted[i] {
            i += 1;
            continue;
        }
        let first = i;
        while i < lines.len() && deleted[i] {
            i += 1;
        }
        let before = first.checked_sub(1);
        let after = (i < lines.len()).then_some(i);
        match (before, after) {
            (Some(p), None) if is_blank(&text[p]) => dropped[p] = true,
            (Some(p), Some(q)) if is_blank(&text[p]) && is_blank(&text[q]) => dropped[p] = true,
            (None, Some(q)) if is_blank(&text[q]) => dropped[q] = true,
            _ => {}
        }
    }

    text.into_iter()
        .zip(dropped)
        .filter(|(_, gone)| !gone)
        .map(|(line, _)| line)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_split_ascending_ords_at_every_gap() {
        assert_eq!(runs([]), Vec::<(i64, i64)>::new());
        assert_eq!(runs([3]), [(3, 3)]);
        assert_eq!(runs([0, 1, 2]), [(0, 2)]);
        assert_eq!(runs([0, 2, 3, 5]), [(0, 0), (2, 3), (5, 5)]);
    }

    #[test]
    fn requested_ids_drop_repeats_in_first_seen_order() {
        let ids: Vec<String> = ["b", "a", "b", "a", "c"].map(String::from).to_vec();
        assert_eq!(requested_ids(&ids).unwrap(), ["b", "a", "c"]);
        assert!(requested_ids(&[]).is_err());
    }
}
