//! Topics footer: the part of a note below the `<!-- memex:topics -->` marker.
//!
//! The footer of a daily note is rendered only from its `footer_chips` rows,
//! in rowid order (architect ruling D11). [`set_chip`] and [`remove_chip`]
//! maintain those rows and re-render the footer through the crate-private
//! daily write path: the note's `version` and `updated_at` move, its
//! `day_reviews.content_version` and review state never do (Req 19).

use crate::embedder::Embedder;
use crate::notes::{Note, NoteId};
use crate::vault::Vault;
use crate::Result;

/// Why a topic chip is in a daily note's footer. `Person` outranks `Excerpt`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChipOrigin {
    /// Added by an excerpt of the day into the topic (#10, `remove_excerpt`
    /// may take it away again).
    Excerpt,
    /// Added by the person (`memex footer add`, Req 17).
    Person,
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
/// `daily_note_id` must be `role: daily` and `topic_note_id` `role: topic`,
/// else `RoleRule`; an unknown id is `NotFound`.
pub fn set_chip(
    vault: &mut Vault,
    daily_note_id: &NoteId,
    topic_note_id: &NoteId,
    origin: ChipOrigin,
    embedder: Option<&dyn Embedder>,
) -> Result<FooterWrite> {
    let _ = (vault, daily_note_id, topic_note_id, origin, embedder);
    unimplemented!("footer::set_chip (#8)")
}

/// Removes the chip `topic_note_id` from the daily note `daily_note_id` as
/// `mode` allows, re-renders the footer and reindexes the daily note with
/// `embedder`.
pub fn remove_chip(
    vault: &mut Vault,
    daily_note_id: &NoteId,
    topic_note_id: &NoteId,
    mode: RemoveMode,
    embedder: Option<&dyn Embedder>,
) -> Result<FooterWrite> {
    let _ = (vault, daily_note_id, topic_note_id, mode, embedder);
    unimplemented!("footer::remove_chip (#8)")
}
