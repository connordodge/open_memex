//! Excerpts: filing blocks of a daily note into a topic note as transclusion
//! tokens (Req 14, 31; CONTRACTS C4).
//!
//! This module owns the excerpt syntax a topic note holds: one
//! `![[<date>#^<from>(..^<to>)?]]` token per maximal run of consecutive
//! blocks, under a `## <date>` heading. Agents never hand-write it. Parsing
//! and rendering are `transclusion`'s (D13); footer chips are `footer`'s
//! (D11).

use std::collections::{BTreeMap, BTreeSet, HashMap};

use chrono::NaiveDate;
use serde_json::{json, Map, Value};

use crate::blocks::Block;
use crate::caller::Caller;
use crate::daily;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::feedback::{self, ExcerptBlock};
use crate::footer::{self, ChipOrigin, RemoveMode};
use crate::indexer;
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
/// is reindexed from the stored body with `embedder` (D8). A person's call records
/// one `excerpt_added` Correction per block it newly files (WI #250).
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

/// [`add_excerpt`] for the person's "File in…", carrying the optional `Why?`
/// note: `note` is stored as the `text` of each Correction the call records
/// (WI #250; [`add_excerpt`] behaves like `note: None`).
pub fn add_excerpt_noted(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    note: Option<&str>,
) -> Result<Note> {
    add_excerpt_inner(
        vault,
        topic_note_id,
        date,
        block_ids,
        caller,
        embedder,
        note,
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
    add_excerpt_inner(
        vault,
        topic_note_id,
        date,
        block_ids,
        caller,
        embedder,
        None,
        before_write,
    )
}

/// [`add_excerpt`]: the writes, then the Correction.
#[allow(clippy::too_many_arguments)]
fn add_excerpt_inner(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    note: Option<&str>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<Note> {
    let filed = file_blocks(
        vault,
        topic_note_id,
        date,
        block_ids,
        caller,
        embedder,
        before_write,
    )?;
    if caller == Caller::Person {
        feedback::record_excerpts_added(
            vault,
            date,
            &filed.blocks,
            topic_note_id.as_str(),
            &filed.title,
            note,
        )?;
    }
    Ok(filed.topic)
}

/// What [`file_blocks`] did.
struct FiledBlocks {
    /// The topic note as stored after the call.
    topic: Note,
    /// The topic's title, read before the write.
    title: String,
    /// The blocks this call added to the topic, in ord order.
    blocks: Vec<ExcerptBlock>,
}

/// The writes of [`add_excerpt`]; it records nothing.
fn file_blocks(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_ids: &[String],
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<FiledBlocks> {
    let ids = requested_ids(block_ids)?;
    let day_date = daily::parse_iso_date(date)?;
    let title = topic_note(vault, topic_note_id)?.title;
    let day = daily_note_for_date(vault, day_date)?
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

    // Each attempt recomputes it, so it ends as what the saved body gained.
    let mut newly_filed: Vec<i64> = Vec::new();
    let topic = write_topic(
        vault,
        topic_note_id,
        caller,
        embedder,
        AfterCommit::Fail,
        before_write,
        |body| {
            let held = held_ords(body, date, &blocks);
            newly_filed = wanted.difference(&held).copied().collect();
            let tokens: Vec<String> = runs(newly_filed.iter().copied())
                .into_iter()
                .map(|(first, last)| blocks.token(date, first, last))
                .collect();
            Ok((!tokens.is_empty()).then(|| insert_tokens(body, date, &tokens)))
        },
    )?;
    // The chip goes on only once the topic holds the excerpt: a call that
    // gives up leaves neither behind.
    footer::set_chip(vault, &day, topic_note_id, ChipOrigin::Excerpt, embedder)?;
    Ok(FiledBlocks {
        topic,
        title,
        blocks: newly_filed
            .iter()
            .map(|ord| blocks.excerpt_block(&blocks.ids[ord]))
            .collect(),
    })
}

/// Reverses [`add_excerpt`]: removes every transclusion token for `date`
/// whose endpoints are `block_ids` (first id = the token's `from`, last id =
/// its `to`, or its only id), the `## <date>` heading when nothing else
/// remains under it, and the topic's footer chip on that day when the topic
/// holds no other excerpt from it and the chip's origin is `excerpt`
/// (`RemoveMode::ExcerptOnly`; a `person` chip stays). A person's call records
/// one `excerpt_removed` Correction for the blocks the token covers, leaving out
/// the person's own already Handled ones (WI #250).
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
    let day_date = daily::parse_iso_date(date)?;
    let from = ids[0];
    let to = (ids.len() > 1).then(|| ids[ids.len() - 1]);
    let removed = (caller == Caller::Person)
        .then(|| removed_excerpt(vault, topic_note_id, day_date, from, to))
        .transpose()?;

    let topic = write_topic(
        vault,
        topic_note_id,
        caller,
        embedder,
        AfterCommit::Fail,
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

    remove_chip_if_day_gone(vault, &topic, date, day_date, embedder)?;
    if let Some(removed) = removed {
        feedback::record_excerpt_removed(
            vault.connection_ref(),
            date,
            &removed.blocks,
            topic_note_id.as_str(),
            &removed.title,
            None,
        )?;
    }
    Ok(topic)
}

/// What a person's [`remove_excerpt`] is about to remove, read before the write.
struct RemovedExcerpt {
    title: String,
    blocks: Vec<ExcerptBlock>,
}

/// The blocks between the endpoints `from` and `to` by ord, or just the endpoints
/// when the day is gone or one of them no longer resolves.
fn removed_excerpt(
    vault: &Vault,
    topic_note_id: &NoteId,
    day_date: NaiveDate,
    from: &str,
    to: Option<&str>,
) -> Result<RemovedExcerpt> {
    let title = topic_note(vault, topic_note_id)?.title;
    let blocks = match daily_note_for_date(vault, day_date)? {
        Some(day) => DayBlocks::load(vault, &day)?,
        None => DayBlocks::from_blocks(&[]),
    };
    let covered = blocks.ids_between(from, to).unwrap_or_else(|| {
        std::iter::once(from)
            .chain(to)
            .map(str::to_string)
            .collect()
    });
    Ok(RemovedExcerpt {
        title,
        blocks: covered.iter().map(|id| blocks.excerpt_block(id)).collect(),
    })
}

/// The two topic notes as stored after [`move_block`].
#[derive(Debug, Clone)]
pub struct MovedBlock {
    pub from: Note,
    pub to: Note,
}

/// Removes one block of the day `date` from the topic note `topic_note_id`
/// (Spec #233 R11). Every token of `date` that covers the block, by `ord`
/// between its endpoints, is rewritten in place: a range is split around the
/// block or shrunk (one block on a side becomes a single-block token), and a
/// token with nothing left goes. The `## <date>` heading and the footer chip
/// then follow the same rules as [`remove_excerpt`]. A person's call records one
/// `excerpt_removed` Correction, unless the block is the person's own and already
/// Handled (WI #250).
///
/// Retries like [`add_excerpt`]; returns the topic note as stored after the
/// call. Errors, each writing nothing: `InvalidDate`, `RoleRule`, `NotFound`
/// (unknown topic, no daily note for `date`, or no token of `date` covers the
/// block), `BlockNotFound` (not a stored block of that day), and
/// `VersionConflict` (every retry raced).
///
/// An error from these checks means the block was not removed. Once the topic's
/// save commits, a failure of its reindex or of the footer chip removal is logged
/// as a warning and not returned; a failure to record the Correction is returned.
pub fn remove_excerpt_block(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_id: &str,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
) -> Result<Note> {
    remove_excerpt_block_with_hook(
        vault,
        topic_note_id,
        date,
        block_id,
        caller,
        embedder,
        &mut |_| {},
    )
}

/// [`remove_excerpt_block`] for the person's `Remove`, carrying the optional
/// `Why?` note: `note` is stored as the `text` of the Correction the call
/// records (WI #250; [`remove_excerpt_block`] behaves like `note: None`).
pub fn remove_excerpt_block_noted(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_id: &str,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    note: Option<&str>,
) -> Result<Note> {
    remove_excerpt_block_inner(
        vault,
        topic_note_id,
        date,
        block_id,
        caller,
        embedder,
        note,
        &mut |_| {},
    )
}

/// [`remove_excerpt_block`] with the same test seam as
/// [`add_excerpt_with_hook`].
#[doc(hidden)]
pub fn remove_excerpt_block_with_hook(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_id: &str,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<Note> {
    remove_excerpt_block_inner(
        vault,
        topic_note_id,
        date,
        block_id,
        caller,
        embedder,
        None,
        before_write,
    )
}

/// [`remove_excerpt_block`]: the writes, then the Correction.
#[allow(clippy::too_many_arguments)]
fn remove_excerpt_block_inner(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_id: &str,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    note: Option<&str>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<Note> {
    let (topic, located) = remove_block(
        vault,
        topic_note_id,
        date,
        block_id,
        caller,
        embedder,
        before_write,
    )?;
    if caller == Caller::Person {
        feedback::record_excerpt_removed(
            vault.connection_ref(),
            date,
            &[located.blocks.excerpt_block(block_id)],
            topic_note_id.as_str(),
            &located.topic.title,
            note,
        )?;
    }
    Ok(topic)
}

/// The writes of [`remove_excerpt_block`]; it records nothing. Also returns the
/// block as located before the write.
fn remove_block(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_id: &str,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault),
) -> Result<(Note, LocatedBlock)> {
    let located = locate_block(vault, topic_note_id, date, block_id)?;
    let topic = write_topic(
        vault,
        topic_note_id,
        caller,
        embedder,
        AfterCommit::Warn,
        before_write,
        |body| {
            without_block(body, date, located.ord, &located.blocks)
                .map(Some)
                .ok_or_else(|| block_not_held(topic_note_id, date, block_id))
        },
    )?;
    let chip = remove_chip_if_day_gone(vault, &topic, date, located.day_date, embedder);
    AfterCommit::Warn.settle(&topic.id, "footer chip removal", chip)?;
    Ok((topic, located))
}

/// Files one block of the day `date` into `to_topic`, then removes it from
/// `from_topic` (Spec #233 R12): [`add_excerpt`] followed by
/// [`remove_excerpt_block`], with their errors and write rules. A target
/// already holding the block is not written, and the removal still runs. A
/// failing removal leaves the block in both topic notes and returns the error.
/// A reindex or footer failure after the source's save has committed is not a
/// failing removal: the block has moved and the call succeeds, as
/// [`remove_excerpt_block`] says. A person's move records one `excerpt_moved`
/// Correction only after both writes, unless the block is the person's own and
/// already Handled in `from_topic` (WI #250); a failure to record it is returned.
///
/// Before any write it fails with `Io(InvalidInput)` when the two topics are
/// the same note, and with [`remove_excerpt_block`]'s errors when the source
/// does not hold the block. Returns both topic notes as stored after the call.
pub fn move_block(
    vault: &mut Vault,
    date: &str,
    block_id: &str,
    from_topic: &NoteId,
    to_topic: &NoteId,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
) -> Result<MovedBlock> {
    move_block_with_hook(
        vault,
        date,
        block_id,
        from_topic,
        to_topic,
        caller,
        embedder,
        &mut |_| {},
    )
}

/// [`move_block`] for the person's `Move to…`, carrying the optional `Why?`
/// note: `note` is stored as the `text` of the Correction the call records
/// (WI #250; [`move_block`] behaves like `note: None`).
#[allow(clippy::too_many_arguments)]
pub fn move_block_noted(
    vault: &mut Vault,
    date: &str,
    block_id: &str,
    from_topic: &NoteId,
    to_topic: &NoteId,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    note: Option<&str>,
) -> Result<MovedBlock> {
    move_block_inner(
        vault,
        date,
        block_id,
        from_topic,
        to_topic,
        caller,
        embedder,
        note,
        &mut |_| {},
    )
}

/// [`move_block`] with a test seam: `before_remove_write` is the
/// `before_write` of the write to `from_topic`.
#[doc(hidden)]
#[allow(clippy::too_many_arguments)]
pub fn move_block_with_hook(
    vault: &mut Vault,
    date: &str,
    block_id: &str,
    from_topic: &NoteId,
    to_topic: &NoteId,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    before_remove_write: &mut dyn FnMut(&mut Vault),
) -> Result<MovedBlock> {
    move_block_inner(
        vault,
        date,
        block_id,
        from_topic,
        to_topic,
        caller,
        embedder,
        None,
        before_remove_write,
    )
}

/// [`move_block`]: both writes, then the one Correction.
#[allow(clippy::too_many_arguments)]
fn move_block_inner(
    vault: &mut Vault,
    date: &str,
    block_id: &str,
    from_topic: &NoteId,
    to_topic: &NoteId,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    note: Option<&str>,
    before_remove_write: &mut dyn FnMut(&mut Vault),
) -> Result<MovedBlock> {
    if from_topic == to_topic {
        return Err(MemexError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("cannot move a block from note {from_topic} to itself"),
        )));
    }
    let source = locate_block(vault, from_topic, date, block_id)?;
    if !held_ords(&source.topic.content_md, date, &source.blocks).contains(&source.ord) {
        return Err(block_not_held(from_topic, date, block_id));
    }
    let filed = file_blocks(
        vault,
        to_topic,
        date,
        &[block_id.to_string()],
        caller,
        embedder,
        &mut |_| {},
    )?;
    let (from, _) = remove_block(
        vault,
        from_topic,
        date,
        block_id,
        caller,
        embedder,
        before_remove_write,
    )?;
    if caller == Caller::Person {
        feedback::record_excerpt_moved(
            vault.connection_ref(),
            date,
            &source.blocks.excerpt_block(block_id),
            (from_topic.as_str(), &source.topic.title),
            (to_topic.as_str(), &filed.title),
            note,
        )?;
    }
    Ok(MovedBlock {
        from,
        to: filed.topic,
    })
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

/// The `role: daily` note for `date`, if any (D27: the one lookup is
/// `daily::daily_note_for_date`).
fn daily_note_for_date(vault: &Vault, date: NaiveDate) -> Result<Option<NoteId>> {
    daily::daily_note_for_date(vault.connection_ref(), date)?
        .map(|id| NoteId::parse(&id))
        .transpose()
}

/// One block of a day, resolved against the topic note it should be in.
struct LocatedBlock {
    topic: Note,
    day_date: NaiveDate,
    blocks: DayBlocks,
    ord: i64,
}

/// Resolves `block_id` for a removal from `topic_note_id`. Read-only. Errors,
/// in this order: `InvalidDate`, `RoleRule` / `NotFound` for the topic,
/// `NotFound` for no daily note on `date`, `BlockNotFound`.
fn locate_block(
    vault: &Vault,
    topic_note_id: &NoteId,
    date: &str,
    block_id: &str,
) -> Result<LocatedBlock> {
    let day_date = daily::parse_iso_date(date)?;
    let topic = topic_note(vault, topic_note_id)?;
    let day = daily_note_for_date(vault, day_date)?
        .ok_or_else(|| MemexError::NotFound(format!("no daily note for {date}")))?;
    let blocks = DayBlocks::load(vault, &day)?;
    let ord = blocks
        .ord_of(block_id)
        .ok_or_else(|| MemexError::BlockNotFound(format!("{block_id} in the daily note {date}")))?;
    Ok(LocatedBlock {
        topic,
        day_date,
        blocks,
        ord,
    })
}

/// The error for a block of the day that no token of `date` in the topic
/// covers.
fn block_not_held(topic_note_id: &NoteId, date: &str, block_id: &str) -> MemexError {
    MemexError::NotFound(format!(
        "no transclusion of {date} covers block {block_id} in note {topic_note_id}"
    ))
}

/// Removes the topic's footer chip on the day `date` when `topic` holds no
/// other token of that date and the chip's origin is `excerpt`.
fn remove_chip_if_day_gone(
    vault: &mut Vault,
    topic: &Note,
    date: &str,
    day_date: NaiveDate,
    embedder: Option<&dyn Embedder>,
) -> Result<()> {
    let day_still_excerpted = parse_transclusions(&topic.content_md)
        .iter()
        .any(|t| t.date == date);
    if !day_still_excerpted {
        if let Some(day) = daily_note_for_date(vault, day_date)? {
            footer::remove_chip(vault, &day, &topic.id, RemoveMode::ExcerptOnly, embedder)?;
        }
    }
    Ok(())
}

/// What a failure after a topic note's save has committed does to the call.
#[derive(Clone, Copy)]
enum AfterCommit {
    /// It is the call's error.
    Fail,
    /// It is logged as a warning, for a call whose error must mean "not
    /// applied" (`move_block`'s partial-failure rule, Spec #233 R12).
    Warn,
}

impl AfterCommit {
    /// Settles `result` of the post-commit `step` on the topic note `topic`.
    fn settle<T>(self, topic: &NoteId, step: &str, result: Result<T>) -> Result<()> {
        match (self, result) {
            (_, Ok(_)) => Ok(()),
            (AfterCommit::Fail, Err(e)) => Err(e),
            (AfterCommit::Warn, Err(e)) => {
                tracing::warn!(
                    note_id = %topic,
                    step,
                    error = %e,
                    "step failed after the topic note's save committed"
                );
                Ok(())
            }
        }
    }
}

/// Reads the topic note, lets `edit` compute its new body (`None`: nothing
/// to write) and saves it as `caller`, re-reading and retrying on
/// `VersionConflict` up to [`WRITE_ATTEMPTS`] times. `before_write` runs
/// between the read and the save of every attempt that saves. The saved note
/// is reindexed from its stored body (D8), and `after_commit` settles a failed
/// reindex; with nothing to write the note is returned as read.
fn write_topic(
    vault: &mut Vault,
    topic_note_id: &NoteId,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
    after_commit: AfterCommit,
    before_write: &mut dyn FnMut(&mut Vault),
    mut edit: impl FnMut(&str) -> Result<Option<String>>,
) -> Result<Note> {
    let mut attempt = 1;
    loop {
        let current = topic_note(vault, topic_note_id)?;
        // `edit` sees only the person section; the Note footer is put back
        // after it (D14), and the save re-renders it from rows.
        let content = current.content_md.as_str();
        let (person, footer) =
            content.split_at(daily::note_marker_start(content).unwrap_or(content.len()));
        let Some(mut body) = edit(person)? else {
            return Ok(current);
        };
        if !footer.is_empty() && !body.is_empty() && !body.ends_with('\n') {
            body.push('\n');
        }
        body.push_str(footer);
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
                let reindexed = indexer::reindex_note(
                    vault.connection_mut(),
                    note.id.as_str(),
                    &note.content_md,
                    embedder,
                );
                after_commit.settle(&note.id, "reindex", reindexed)?;
                return Ok(note);
            }
            Err(MemexError::VersionConflict { .. }) if attempt < WRITE_ATTEMPTS => attempt += 1,
            Err(e) => return Err(e),
        }
    }
}

/// The stored blocks of one daily note, by id and by ord.
pub(crate) struct DayBlocks {
    ords: HashMap<String, i64>,
    ids: BTreeMap<i64, String>,
    texts: HashMap<String, String>,
}

impl DayBlocks {
    pub(crate) fn load(vault: &Vault, day: &NoteId) -> Result<Self> {
        let (blocks, _) = daily::stored_blocks(vault.connection_ref(), day.as_str())?;
        Ok(Self::from_blocks(&blocks))
    }

    pub(crate) fn from_blocks(blocks: &[Block]) -> Self {
        Self {
            ids: blocks
                .iter()
                .map(|b| (b.ord as i64, b.block_id.clone()))
                .collect(),
            ords: blocks
                .iter()
                .map(|b| (b.block_id.clone(), b.ord as i64))
                .collect(),
            texts: blocks
                .iter()
                .map(|b| (b.block_id.clone(), b.text.clone()))
                .collect(),
        }
    }

    fn ord_of(&self, id: &str) -> Option<i64> {
        self.ords.get(id).copied()
    }

    /// The block `id` as a Correction names it. A block that is gone has an empty
    /// preview.
    fn excerpt_block(&self, id: &str) -> ExcerptBlock {
        ExcerptBlock {
            id: id.to_string(),
            preview: self
                .texts
                .get(id)
                .map(|text| feedback::preview(text))
                .unwrap_or_default(),
        }
    }

    /// The stored ids at the ords between the endpoints, in day order, or `None`
    /// when an endpoint no longer resolves.
    fn ids_between(&self, from: &str, to: Option<&str>) -> Option<Vec<String>> {
        let first = self.ord_of(from)?;
        let last = match to {
            None => first,
            Some(to) => self.ord_of(to)?,
        };
        Some(
            self.ids
                .range(first.min(last)..=first.max(last))
                .map(|(_, id)| id.clone())
                .collect(),
        )
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

    /// The ords between `token`'s endpoints as `(lowest, highest)`, or `None`
    /// when an endpoint no longer resolves.
    fn span_of(&self, token: &TransclusionToken) -> Option<(i64, i64)> {
        let from = self.ord_of(&token.from)?;
        let to = match &token.to {
            None => from,
            Some(to) => self.ord_of(to)?,
        };
        Some((from.min(to), from.max(to)))
    }

    /// The tokens left of the span `lo..=hi` of the day `date` without the
    /// block at `ord`: the stored blocks on each side of it, in day order.
    /// Ords can have gaps, so the neighbours come from the stored ords.
    fn tokens_around(&self, date: &str, lo: i64, hi: i64, ord: i64) -> Vec<String> {
        let below = self.ids.range(..ord).next_back().map(|(&o, _)| o);
        let above = self.ids.range(ord + 1..).next().map(|(&o, _)| o);
        let left = below
            .filter(|&last| last >= lo)
            .map(|last| self.token(date, lo, last));
        let right = above
            .filter(|&first| first <= hi)
            .map(|first| self.token(date, first, hi));
        left.into_iter().chain(right).collect()
    }
}

/// The ords of the day `date` that a token of `body` already covers. A token
/// whose endpoints no longer resolve covers nothing.
pub(crate) fn held_ords(body: &str, date: &str, blocks: &DayBlocks) -> BTreeSet<i64> {
    let mut held = BTreeSet::new();
    for token in parse_transclusions(body) {
        if token.date != date {
            continue;
        }
        if let Some((lo, hi)) = blocks.span_of(&token) {
            held.extend(lo..=hi);
        }
    }
    held
}

/// `body` with no token of `date` covering the block at `ord`, or `None` when
/// none does. A covering token is replaced in place by what is left of it
/// (joined by a blank line), so every byte outside its span is kept; a token
/// with nothing left goes through [`remove_tokens`].
fn without_block(body: &str, date: &str, ord: i64, blocks: &DayBlocks) -> Option<String> {
    let covered_span = |t: &TransclusionToken| {
        (t.date == date)
            .then(|| blocks.span_of(t))
            .flatten()
            .filter(|&(lo, hi)| lo <= ord && ord <= hi)
    };
    let covering: Vec<(TransclusionToken, (i64, i64))> = parse_transclusions(body)
        .into_iter()
        .filter_map(|t| covered_span(&t).map(|span| (t, span)))
        .collect();
    if covering.is_empty() {
        return None;
    }
    let mut edited = body.to_string();
    // Back to front, so the offsets of the tokens still to do stay valid.
    for (token, (lo, hi)) in covering.iter().rev() {
        let left = blocks.tokens_around(date, *lo, *hi, ord);
        if !left.is_empty() {
            edited.replace_range(token.start..token.end, &left.join("\n\n"));
        }
    }
    // What still covers the block is every token that had nothing left.
    let emptied: Vec<TransclusionToken> = parse_transclusions(&edited)
        .into_iter()
        .filter(|t| covered_span(t).is_some())
        .collect();
    if emptied.is_empty() {
        return Some(edited);
    }
    Some(remove_tokens(&edited, date, &emptied))
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
