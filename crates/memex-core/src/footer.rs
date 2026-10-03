//! Topics footer: the part of a note below the `<!-- memex:topics -->` marker.
//!
//! The footer of a daily note is rendered only from its `footer_chips` rows,
//! in rowid order (architect ruling D11). [`set_chip`] and [`remove_chip`]
//! maintain those rows and re-render the footer through the crate-private
//! daily write path: the note's `version` and `updated_at` move, its
//! `day_reviews.content_version` and review state never do (Req 19).

use rusqlite::{params, OptionalExtension};

use crate::daily;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::indexer;
use crate::notes::{self, Note, NoteId};
use crate::vault::{now_unix_ms, Vault};
use crate::Result;

/// The frontmatter `role` value of a topic note. The match is exact.
const TOPIC_ROLE: &str = "topic";

/// How many times a footer write re-reads the daily note after a
/// `VersionConflict` before giving up. Footer writes commute with person
/// edits, so a conflict only means another writer got there first.
const FOOTER_WRITE_ATTEMPTS: usize = 3;

/// Why a topic chip is in a daily note's footer. `Person` outranks `Excerpt`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ChipOrigin {
    /// Added by an excerpt of the day into the topic (#10, `remove_excerpt`
    /// may take it away again).
    Excerpt,
    /// Added by the person (`memex footer add`, Req 17).
    Person,
}

impl ChipOrigin {
    /// The stored `footer_chips.origin` value: `excerpt` or `person`.
    pub fn as_str(self) -> &'static str {
        match self {
            ChipOrigin::Excerpt => "excerpt",
            ChipOrigin::Person => "person",
        }
    }

    /// Reads a stored origin. The schema allows only `excerpt` and `person`.
    fn from_stored(origin: &str) -> Self {
        match origin {
            "person" => ChipOrigin::Person,
            _ => ChipOrigin::Excerpt,
        }
    }
}

/// Which chips [`remove_chip`] may remove.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoveMode {
    /// Remove the chip whatever its origin (person delete).
    AnyOrigin,
    /// Remove the chip only when its origin is `excerpt`; a `person` chip
    /// stays (Req 14).
    ExcerptOnly,
}

/// The result of a footer write.
#[derive(Debug, Clone)]
pub struct FooterWrite {
    /// The chip's origin after the call: `None` when no chip for the topic
    /// remains on the daily note.
    pub origin: Option<ChipOrigin>,
    /// The daily note as stored after the call.
    pub note: Note,
}

/// Records the chip `topic_note_id` on the daily note `daily_note_id` with
/// `origin` (person > excerpt: an `excerpt` set over `person` keeps `person`,
/// a `person` set over `excerpt` upgrades it in place, keeping its position),
/// re-renders the footer and reindexes the daily note with `embedder`.
///
/// When the chip is already stored with the resulting origin nothing is
/// written: the daily note keeps its version.
///
/// `daily_note_id` must be `role: daily` and `topic_note_id` `role: topic`,
/// else `RoleRule`; an unknown id is `NotFound`.
pub fn set_chip(
    vault: &mut Vault,
    daily_note_id: &NoteId,
    topic_note_id: &NoteId,
    origin: ChipOrigin,
    embedder: Option<&dyn Embedder>,
) -> Result<FooterWrite> {
    let daily = daily_note(vault, daily_note_id)?;
    let topic = notes::get_note(vault, topic_note_id)?;
    if topic.frontmatter.get("role").and_then(|r| r.as_str()) != Some(TOPIC_ROLE) {
        return Err(MemexError::RoleRule(format!(
            "note {topic_note_id} is not a topic note (role: topic)"
        )));
    }

    let stored = chip_origin(vault, daily_note_id, topic_note_id)?;
    let effective = stored.map_or(origin, |s| s.max(origin));
    if stored == Some(effective) {
        return Ok(FooterWrite {
            origin: stored,
            note: daily,
        });
    }
    // An upsert updates an existing row in place, so an upgrade keeps its
    // rowid and with it the chip's position in the footer.
    vault.connection_ref().execute(
        "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT (daily_note_id, topic_note_id) DO UPDATE SET origin = excluded.origin",
        params![
            daily_note_id.as_str(),
            topic_note_id.as_str(),
            effective.as_str(),
            now_unix_ms(),
        ],
    )?;
    let note = rerender_footer(vault, daily_note_id, embedder)?;
    Ok(FooterWrite {
        origin: Some(effective),
        note,
    })
}

/// Removes the chip `topic_note_id` from the daily note `daily_note_id` as
/// `mode` allows, re-renders the footer and reindexes the daily note with
/// `embedder`.
///
/// When there is no such chip, or `mode` keeps it (`ExcerptOnly` on a
/// `person` chip), nothing is written and `origin` is the chip's origin, if
/// any. `daily_note_id` must be `role: daily` (`RoleRule`); an unknown daily
/// note is `NotFound`.
pub fn remove_chip(
    vault: &mut Vault,
    daily_note_id: &NoteId,
    topic_note_id: &NoteId,
    mode: RemoveMode,
    embedder: Option<&dyn Embedder>,
) -> Result<FooterWrite> {
    let daily = daily_note(vault, daily_note_id)?;
    let stored = chip_origin(vault, daily_note_id, topic_note_id)?;
    let kept = mode == RemoveMode::ExcerptOnly && stored == Some(ChipOrigin::Person);
    if stored.is_none() || kept {
        return Ok(FooterWrite {
            origin: stored,
            note: daily,
        });
    }
    vault.connection_ref().execute(
        "DELETE FROM footer_chips WHERE daily_note_id = ? AND topic_note_id = ?",
        params![daily_note_id.as_str(), topic_note_id.as_str()],
    )?;
    let note = rerender_footer(vault, daily_note_id, embedder)?;
    Ok(FooterWrite { origin: None, note })
}

/// Re-renders the footer of the daily note `daily_note_id` from its
/// `footer_chips` rows through `notes::write_daily_internal` (its person
/// section unchanged: `version` + 1, `content_version` kept), re-reading and
/// retrying on `VersionConflict`, then reindexes it with `embedder` (D8).
pub(crate) fn rerender_footer(
    vault: &mut Vault,
    daily_note_id: &NoteId,
    embedder: Option<&dyn Embedder>,
) -> Result<Note> {
    let note = retry_on_conflict(FOOTER_WRITE_ATTEMPTS, || {
        let current = notes::get_note(vault, daily_note_id)?;
        notes::write_daily_internal(
            vault,
            daily_note_id,
            current.version,
            &current.content_md,
            "person",
        )
    })?;
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        embedder,
    )?;
    Ok(note)
}

/// Runs `write` until it returns anything but `VersionConflict`, at most
/// `attempts` times; the last result is returned as is.
fn retry_on_conflict<T>(attempts: usize, mut write: impl FnMut() -> Result<T>) -> Result<T> {
    let mut tried = 1;
    loop {
        match write() {
            Err(MemexError::VersionConflict { .. }) if tried < attempts => tried += 1,
            result => return result,
        }
    }
}

/// The note `id`, which must be `role: daily` (`RoleRule`).
fn daily_note(vault: &Vault, id: &NoteId) -> Result<Note> {
    let note = notes::get_note(vault, id)?;
    if !daily::is_daily(&note.frontmatter) {
        return Err(MemexError::RoleRule(format!(
            "note {id} is not a daily note (role: daily)"
        )));
    }
    Ok(note)
}

/// The origin of the chip `topic_note_id` on `daily_note_id`, if any.
fn chip_origin(
    vault: &Vault,
    daily_note_id: &NoteId,
    topic_note_id: &NoteId,
) -> Result<Option<ChipOrigin>> {
    let origin: Option<String> = vault
        .connection_ref()
        .query_row(
            "SELECT origin FROM footer_chips WHERE daily_note_id = ? AND topic_note_id = ?",
            params![daily_note_id.as_str(), topic_note_id.as_str()],
            |r| r.get(0),
        )
        .optional()?;
    Ok(origin.as_deref().map(ChipOrigin::from_stored))
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    fn conflict() -> MemexError {
        MemexError::VersionConflict {
            expected: 1,
            current: 2,
        }
    }

    /// A write that conflicts `conflicts` times, then succeeds; `calls`
    /// counts every call.
    fn flaky(conflicts: usize, calls: &Cell<usize>) -> impl FnMut() -> Result<usize> + '_ {
        move || {
            calls.set(calls.get() + 1);
            if calls.get() <= conflicts {
                Err(conflict())
            } else {
                Ok(calls.get())
            }
        }
    }

    #[test]
    fn retry_on_conflict_retries_until_the_write_succeeds() {
        let calls = Cell::new(0);
        assert_eq!(retry_on_conflict(3, flaky(2, &calls)).unwrap(), 3);
        assert_eq!(calls.get(), 3);

        let calls = Cell::new(0);
        assert_eq!(retry_on_conflict(3, flaky(0, &calls)).unwrap(), 1);
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn retry_on_conflict_gives_up_after_the_last_attempt() {
        let calls = Cell::new(0);
        let err = retry_on_conflict(3, flaky(3, &calls)).unwrap_err();
        assert!(matches!(err, MemexError::VersionConflict { .. }), "{err:?}");
        assert_eq!(calls.get(), 3, "exactly `attempts` tries");
    }

    #[test]
    fn retry_on_conflict_returns_other_errors_at_once() {
        let calls = Cell::new(0);
        let err = retry_on_conflict(3, || -> Result<()> {
            calls.set(calls.get() + 1);
            Err(MemexError::RoleRule("not daily".into()))
        })
        .unwrap_err();
        assert!(matches!(err, MemexError::RoleRule(_)), "{err:?}");
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn chip_origin_round_trips_through_its_stored_value() {
        for origin in [ChipOrigin::Excerpt, ChipOrigin::Person] {
            assert_eq!(ChipOrigin::from_stored(origin.as_str()), origin);
        }
        assert_eq!(ChipOrigin::Excerpt.as_str(), "excerpt");
        assert_eq!(ChipOrigin::Person.as_str(), "person");
        assert!(ChipOrigin::Person > ChipOrigin::Excerpt);
    }
}
