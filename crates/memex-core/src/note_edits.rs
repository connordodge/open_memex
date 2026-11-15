//! Agent body edits of notes (Spec #7 Req 11-25, 27, 28; architect rulings
//! D7-D11): the agent's `edit_note` in two forms, exact find/replace
//! (Form A) and full person-section replace (Form B), the agent-edit
//! revisions kept for each write (newest 20 per note), and the person's
//! Restore of one.
//!
//! The engine opens its own Immediate transaction and does not go through
//! `notes::update_note_as` (D7), so a new agent rule added there must also be
//! added here.

use rusqlite::{params, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use ulid::Ulid;

use crate::caller::Caller;
use crate::canvas::Clock;
use crate::daily;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::guide::RESTORE_BULLET;
use crate::indexer;
use crate::notes::{self, NoteId, TagMode};
use crate::review::{self, ChangeEntry};
use crate::transclusion;
use crate::vault::Vault;
use crate::Result;

/// Agent-edit revisions kept per note (Req 24).
const KEPT_REVISIONS: i64 = 20;

/// One Form A pair: `old_text` must match exactly once in the person section
/// as it was before the call; `new_text` replaces it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditPair {
    pub old_text: String,
    pub new_text: String,
}

/// An agent's edit of one note: exactly one of `edits` (Form A) and
/// `content_md` (Form B), with 1 to 3 `bullets` saying what changed.
/// `expected_version` is optional for Form A and required for Form B.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditInput {
    pub note_id: NoteId,
    pub bullets: Vec<String>,
    pub edits: Option<Vec<EditPair>>,
    pub content_md: Option<String>,
    pub expected_version: Option<i64>,
}

/// What [`edit_note`] answers with: the note's version and stored body after
/// the call, and whether it wrote (`false` for a no-op, Req 17).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EditOutcome {
    pub note_id: NoteId,
    pub version: i64,
    pub content_md: String,
    pub changed: bool,
}

/// What [`restore`] answers with: the note's new version and stored body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RestoreOutcome {
    pub note_id: NoteId,
    pub version: i64,
    pub content_md: String,
}

/// One kept earlier person section of a note, as listed by [`revisions`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoteRevision {
    pub id: String,
    /// `None` once the linked `agent_changes` row is gone.
    pub agent_change_id: Option<String>,
    pub created_at: i64,
}

/// The two forms of an edit, once the input shape is checked.
enum Form<'a> {
    Pairs(&'a [EditPair]),
    Whole(&'a str),
}

/// The agent's body edit of one note (Req 11-23). The checks run in Req 11a
/// order and the first failure answers, with nothing written:
///
/// 1. input shape (`EditInvalid`), then the bullets (`ChangeEntriesInvalid`:
///    1 to 3 non-blank lines of at most 200 characters);
/// 2. an unknown note (`NotFound`);
/// 3. the agent rules: `check_agent_write` (`MarkerRule` on a daily note,
///    `GuideRule` on the Vault Guide), then `check_agent_read_only`
///    (`ReadOnlyRule`), whatever the version;
/// 4. a stale `expected_version` (`VersionConflict`);
/// 5. Form A matching against the person section as it was before the call:
///    each `old_text` in index order matches byte-exactly once
///    (`EditNotFound` / `EditAmbiguous` naming its index), then no two matched
///    ranges overlap (`EditInvalid` naming both);
/// 6. the same transclusion tokens as a multiset (`ExcerptRule`);
/// 7. a person section byte-identical to the current one is a no-op:
///    `changed: false`, no version bump, no revision, no `agent_changes` row.
///
/// A write stores the new person section with the Note footer rebuilt from
/// its rows, drops only the body tags whose text went (D8), and commits the
/// note, one `agent_changes` row dated `day` with `bullets`, one revision
/// holding the previous person section and the pruning to the newest 20 in
/// one transaction; the note is reindexed after the commit.
pub fn edit_note(
    vault: &mut Vault,
    input: EditInput,
    day: &str,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<EditOutcome> {
    let form = input_form(&input)?;
    check_bullets(&input)?;
    let id = &input.note_id;

    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (version, content_md, frontmatter) = read_note(&tx, id)?;
    notes::check_agent_write(
        Caller::Agent,
        &notes::lenient_frontmatter(&frontmatter),
        None,
    )?;
    notes::check_agent_read_only(&tx, Caller::Agent, id)?;
    if let Some(expected) = input.expected_version {
        if expected != version {
            return Err(MemexError::VersionConflict {
                expected,
                current: version,
            });
        }
    }

    let person = person_section(&content_md);
    let new_person = match form {
        Form::Pairs(pairs) => apply_pairs(person, pairs)?,
        Form::Whole(text) => text.to_string(),
    };
    let new_person = daily::split_note_body(&new_person).person;
    check_transclusions(person, &new_person)?;
    if new_person == person {
        return Ok(EditOutcome {
            note_id: id.clone(),
            version,
            content_md,
            changed: false,
        });
    }

    let now = clock.now_ms();
    let written =
        notes::write_person_section_internal(&tx, id, &new_person, TagMode::RemovalsOnly, now)?;
    let change_id = review::insert_agent_change(&tx, id.as_str(), day, now, &input.bullets)?;
    keep_revision(&tx, id, person, version, written.version, &change_id, now)?;
    tx.commit()?;

    indexer::reindex_note(
        vault.connection_mut(),
        id.as_str(),
        &written.content_md,
        embedder,
    )?;
    Ok(EditOutcome {
        note_id: input.note_id,
        version: written.version,
        content_md: written.content_md,
        changed: true,
    })
}

/// The note's agent-edit revisions, newest first (`new_version DESC`). An
/// unknown note is `NotFound`.
pub fn revisions(vault: &Vault, note_id: &NoteId) -> Result<Vec<NoteRevision>> {
    let conn = vault.connection_ref();
    let exists = conn
        .query_row(
            "SELECT 1 FROM notes WHERE id = ?",
            [note_id.as_str()],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !exists {
        return Err(not_found(note_id));
    }
    let mut stmt = conn.prepare(
        "SELECT id, agent_change_id, created_at FROM note_revisions
         WHERE note_id = ? ORDER BY new_version DESC, id DESC",
    )?;
    let rows = stmt.query_map([note_id.as_str()], |r| {
        Ok(NoteRevision {
            id: r.get(0)?,
            agent_change_id: r.get(1)?,
            created_at: r.get(2)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// The person's Restore of `revision_id` (Req 27, 28). With `note_id`, the
/// revision must belong to that note. Unknown, pruned or foreign revisions
/// are `NotFound`.
///
/// A person write, so no agent rule applies and a note flagged Agent
/// read-only is restored too: the person section becomes the revision's
/// previous text, the body tags are re-derived as on a person save and the
/// Note footer is rebuilt from its rows. The replaced person section is kept
/// as a new revision linked to a new `agent_changes` row dated `day` with the
/// one bullet `Restored an earlier version`, pruned to the newest 20, all in
/// one transaction; the note is reindexed after the commit. A revision of a
/// daily note is `RoleRule` and of the Vault Guide `GuideRule`.
pub fn restore(
    vault: &mut Vault,
    revision_id: &str,
    note_id: Option<&NoteId>,
    day: &str,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<RestoreOutcome> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let revision: Option<(String, String)> = tx
        .query_row(
            "SELECT note_id, previous_md FROM note_revisions WHERE id = ?",
            [revision_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (owner, restored) = revision
        .filter(|(owner, _)| note_id.is_none_or(|id| id.as_str() == owner))
        .ok_or_else(|| MemexError::NotFound(format!("note revision {revision_id}")))?;
    let id = NoteId::parse(&owner)?;
    let (version, content_md, _) = read_note(&tx, &id)?;
    let replaced = person_section(&content_md);

    let now = clock.now_ms();
    let written = notes::write_person_section_internal(&tx, &id, &restored, TagMode::Derive, now)?;
    let bullets = [RESTORE_BULLET.to_string()];
    let change_id = review::insert_agent_change(&tx, id.as_str(), day, now, &bullets)?;
    keep_revision(
        &tx,
        &id,
        replaced,
        version,
        written.version,
        &change_id,
        now,
    )?;
    tx.commit()?;

    indexer::reindex_note(
        vault.connection_mut(),
        id.as_str(),
        &written.content_md,
        embedder,
    )?;
    Ok(RestoreOutcome {
        note_id: id,
        version: written.version,
        content_md: written.content_md,
    })
}

/// Step 1 of Req 11a, the input shape: exactly one of `edits` and
/// `content_md`, a non-empty `edits` list without an empty `old_text`, and
/// Form B with an `expected_version`. Anything else is `EditInvalid`.
fn input_form(input: &EditInput) -> Result<Form<'_>> {
    let invalid = |message: String| Err(MemexError::EditInvalid(message));
    match (&input.edits, &input.content_md) {
        (Some(_), Some(_)) | (None, None) => {
            invalid("give exactly one of edits and content_md".into())
        }
        (Some(pairs), None) => {
            if pairs.is_empty() {
                return invalid("edits needs at least one {old_text, new_text} pair".into());
            }
            if let Some(index) = pairs.iter().position(|p| p.old_text.is_empty()) {
                return invalid(format!("edit {index} has an empty old_text"));
            }
            Ok(Form::Pairs(pairs))
        }
        (None, Some(text)) => {
            if input.expected_version.is_none() {
                return invalid(
                    "content_md replaces the whole person section and needs expected_version"
                        .into(),
                );
            }
            Ok(Form::Whole(text))
        }
    }
}

/// The bullets of step 1 (Req 16, ruling D9): the change-entry rules of
/// `update_vault_guide` (1 to 3 one-line bullets of at most 200 characters,
/// no leading `- `), and no blank bullet. Any break is `ChangeEntriesInvalid`.
fn check_bullets(input: &EditInput) -> Result<()> {
    let entry = ChangeEntry {
        note_id: input.note_id.to_string(),
        bullets: input.bullets.clone(),
    };
    review::check_entry_rules(std::slice::from_ref(&entry))?;
    if input.bullets.iter().any(|b| b.trim().is_empty()) {
        return Err(MemexError::ChangeEntriesInvalid(format!(
            "a bullet may not be blank ({})",
            input.note_id
        )));
    }
    Ok(())
}

/// `(version, content_md, frontmatter)` of the note, read in `tx`; an unknown
/// note is `NotFound`.
fn read_note(tx: &Transaction<'_>, id: &NoteId) -> Result<(i64, String, String)> {
    tx.query_row(
        "SELECT version, content_md, frontmatter FROM notes WHERE id = ?",
        [id.as_str()],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )
    .optional()?
    .ok_or_else(|| not_found(id))
}

fn not_found(id: &NoteId) -> MemexError {
    MemexError::NotFound(format!("note {}", id.as_str()))
}

/// The person section of a non-daily body: everything above the Note footer
/// marker, or the whole body without one (as `excerpts::write_topic`).
fn person_section(body: &str) -> &str {
    &body[..daily::note_marker_start(body).unwrap_or(body.len())]
}

/// Applies the Form A `pairs` to `person` together (Req 12). Every pair is
/// matched against `person` in index order first: no occurrence of its
/// `old_text` is `EditNotFound` and two or more (overlapping ones included)
/// `EditAmbiguous`, naming the pair's index. Only then are the matched byte
/// ranges checked: two that overlap are `EditInvalid` naming both indexes;
/// ranges that only touch do not overlap.
fn apply_pairs(person: &str, pairs: &[EditPair]) -> Result<String> {
    let mut ranges = Vec::with_capacity(pairs.len());
    for (index, pair) in pairs.iter().enumerate() {
        let old = pair.old_text.as_str();
        let Some(start) = person.find(old) else {
            return Err(MemexError::EditNotFound {
                index,
                message: format!("edit {index}: old_text is not in the note's person section"),
            });
        };
        // The next char boundary after `start`, so a second occurrence that
        // overlaps the first is found too.
        let next = start + person[start..].chars().next().map_or(1, char::len_utf8);
        if person[next..].contains(old) {
            return Err(MemexError::EditAmbiguous {
                index,
                message: format!(
                    "edit {index}: old_text matches more than once in the note's person \
                     section; include more of the surrounding text"
                ),
            });
        }
        ranges.push((start, start + old.len(), index));
    }
    for (i, a) in ranges.iter().enumerate() {
        for b in &ranges[i + 1..] {
            if a.0 < b.1 && b.0 < a.1 {
                return Err(MemexError::EditInvalid(format!(
                    "edits {} and {} overlap in the note's person section; combine them into one edit",
                    a.2, b.2
                )));
            }
        }
    }
    ranges.sort_unstable();
    let mut out = String::with_capacity(person.len());
    let mut at = 0;
    for (start, end, index) in ranges {
        out.push_str(&person[at..start]);
        out.push_str(&pairs[index].new_text);
        at = end;
    }
    out.push_str(&person[at..]);
    Ok(out)
}

/// Step 6 (Req 19, ruling D10): the new person section holds the same
/// transclusion tokens as the current one, compared as sorted
/// `(date, from, to)` lists; otherwise `ExcerptRule`.
fn check_transclusions(current: &str, new: &str) -> Result<()> {
    let tokens = |text: &str| {
        let mut tokens: Vec<_> = transclusion::parse_transclusions(text)
            .into_iter()
            .map(|t| (t.date, t.from, t.to))
            .collect();
        tokens.sort_unstable();
        tokens
    };
    if tokens(current) != tokens(new) {
        return Err(MemexError::ExcerptRule(
            "edit_note keeps every transclusion token (![[...]]) of the note; agents change \
             filing with add_excerpt, remove_excerpt and remove_excerpt_block"
                .into(),
        ));
    }
    Ok(())
}

/// Inserts the revision keeping `previous_md`, the person section a write
/// replaced, linked to `agent_change_id`, then deletes the note's revisions
/// past the newest 20 by `new_version` (Req 23, 24; ruling D11), in `tx`.
fn keep_revision(
    tx: &Transaction<'_>,
    note_id: &NoteId,
    previous_md: &str,
    previous_version: i64,
    new_version: i64,
    agent_change_id: &str,
    now: i64,
) -> Result<()> {
    tx.execute(
        "INSERT INTO note_revisions
             (id, note_id, previous_md, previous_version, new_version, agent_change_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        params![
            Ulid::new().to_string(),
            note_id.as_str(),
            previous_md,
            previous_version,
            new_version,
            agent_change_id,
            now,
        ],
    )?;
    tx.execute(
        "DELETE FROM note_revisions WHERE note_id = ?1 AND id NOT IN (
             SELECT id FROM note_revisions WHERE note_id = ?1
             ORDER BY new_version DESC, id DESC LIMIT ?2
         )",
        params![note_id.as_str(), KEPT_REVISIONS],
    )?;
    Ok(())
}
