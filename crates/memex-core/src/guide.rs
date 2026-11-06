//! The Vault Guide (#233 R24-R31): the one `role: guide` note of a vault,
//! created on first read, whose only agent write path is [`update`].

use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::Serialize;
use ulid::Ulid;

use crate::canvas::Clock;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::indexer;
use crate::notes;
use crate::review::{self, ChangeEntry};
use crate::vault::Vault;
use crate::Result;

const SEED_TITLE: &str = "Vault Guide";
const SEED_BODY: &str = "## Framework\n\n## Decisions\n";
const RESTORE_BULLET: &str = "Restored an earlier version";
/// Create attempts of one first read before it returns the last error.
const CREATE_ATTEMPTS: u32 = 5;

/// The SQL condition selecting the guide over a `frontmatter` column: the
/// expression of the unique index `idx_notes_guide`, which matches
/// `notes::is_guide`.
pub(crate) const GUIDE_NOTE: &str =
    "CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'guide'";

/// The guide as read or written: what `get_vault_guide` and
/// `update_vault_guide` answer with (field names are a contract, #256).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GuideDoc {
    pub note_id: String,
    pub version: i64,
    pub content_md: String,
}

/// One kept earlier text of the guide, as listed by [`revisions`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GuideRevision {
    pub id: String,
    /// `None` once the linked `agent_changes` row is gone (`ON DELETE SET NULL`).
    pub agent_change_id: Option<String>,
    pub created_at: i64,
}

/// The guide, created on the first read: `role: guide`, titled `Vault Guide`
/// (`Vault Guide 2`, and so on, when that title is taken), with empty
/// `## Framework` and `## Decisions` sections. A process that loses the race
/// to create it returns the winner's note.
pub fn get_or_create(
    vault: &mut Vault,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    get_or_create_with_hook(vault, clock, embedder, &mut |_| {})
}

/// [`get_or_create`] with a test seam: `before_create` runs once per create
/// attempt, after the free title is picked and before the create, with no
/// transaction open. It does not run when the guide is found.
#[doc(hidden)]
pub fn get_or_create_with_hook(
    vault: &mut Vault,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
    before_create: &mut dyn FnMut(&mut Vault),
) -> Result<GuideDoc> {
    let mut attempt = 1;
    loop {
        if let Some(doc) = find_guide(vault.connection_ref())? {
            return Ok(doc);
        }
        let title = first_free_title(vault.connection_ref())?;
        before_create(vault);
        match notes::create_guide_internal(vault, &title, SEED_BODY, clock) {
            Ok(note) => {
                let doc = GuideDoc {
                    note_id: note.id.to_string(),
                    version: note.version,
                    content_md: note.content_md,
                };
                return reindexed(vault, doc, embedder);
            }
            Err(e) if attempt < CREATE_ATTEMPTS && lost_create_race(&e) => attempt += 1,
            Err(e) => return Err(e),
        }
    }
}

/// The agent's one write path to the guide. A stale `expected_version` fails
/// with `version_conflict`, invalid `bullets` with `change_entries_invalid`,
/// and neither writes anything. The note, one `vault_guide_revisions` row
/// holding the previous text and one `agent_changes` row dated `day` commit in
/// one transaction; the note is reindexed afterwards. A vault with no guide yet
/// fails with `not_found`.
pub fn update(
    vault: &mut Vault,
    expected_version: i64,
    content_md: &str,
    bullets: &[String],
    day: &str,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = existing_guide(&tx)?;
    if current.version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current.version,
        });
    }
    let doc = commit_write(tx, current, content_md, bullets, day, clock)?;
    reindexed(vault, doc, embedder)
}

/// A person write replacing the current text with that of `revision_id`
/// (`not_found` when unknown). The replaced text is kept as a new revision,
/// linked to one new `agent_changes` row with the bullet
/// `Restored an earlier version`, under the same transaction as [`update`].
pub fn restore(
    vault: &mut Vault,
    revision_id: &str,
    day: &str,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    let tx = vault
        .conn_mut()
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = existing_guide(&tx)?;
    let restored: String = tx
        .query_row(
            "SELECT previous_md FROM vault_guide_revisions WHERE id = ?",
            [revision_id],
            |r| r.get(0),
        )
        .optional()?
        .ok_or_else(|| MemexError::NotFound(format!("guide revision {revision_id}")))?;
    let bullets = [RESTORE_BULLET.to_string()];
    let doc = commit_write(tx, current, &restored, &bullets, day, clock)?;
    reindexed(vault, doc, embedder)
}

/// The guide's revisions, newest first. Versions only grow, so `new_version`
/// orders them whatever the clock did.
pub fn revisions(vault: &Vault) -> Result<Vec<GuideRevision>> {
    let conn = vault.connection_ref();
    let mut stmt = conn.prepare(
        "SELECT id, agent_change_id, created_at FROM vault_guide_revisions
         ORDER BY new_version DESC",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(GuideRevision {
            id: r.get(0)?,
            agent_change_id: r.get(1)?,
            created_at: r.get(2)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// The vault's guide, if it has one yet.
fn find_guide(conn: &Connection) -> Result<Option<GuideDoc>> {
    let doc = conn
        .query_row(
            &format!("SELECT id, version, content_md FROM notes WHERE {GUIDE_NOTE}"),
            [],
            |r| {
                Ok(GuideDoc {
                    note_id: r.get(0)?,
                    version: r.get(1)?,
                    content_md: r.get(2)?,
                })
            },
        )
        .optional()?;
    Ok(doc)
}

/// [`find_guide`] for a write: no guide is `not_found`.
fn existing_guide(conn: &Connection) -> Result<GuideDoc> {
    find_guide(conn)?.ok_or_else(|| MemexError::NotFound("the vault has no Vault Guide yet".into()))
}

/// The first of `Vault Guide`, `Vault Guide 2`, ... that no note holds.
fn first_free_title(conn: &Connection) -> Result<String> {
    let mut title = SEED_TITLE.to_string();
    let mut n = 2;
    while conn
        .query_row("SELECT 1 FROM notes WHERE title = ?", [&title], |_| Ok(()))
        .optional()?
        .is_some()
    {
        title = format!("{SEED_TITLE} {n}");
        n += 1;
    }
    Ok(title)
}

/// Whether a failed create means another process got there first, so the next
/// attempt finds its guide or picks another title.
fn lost_create_race(error: &MemexError) -> bool {
    match error {
        MemexError::TitleConflict { .. } => true,
        MemexError::Sqlite(rusqlite::Error::SqliteFailure(_, Some(message))) => {
            message.contains("idx_notes_guide")
        }
        _ => false,
    }
}

/// Validates `bullets`, then commits the new text, one `agent_changes` row and
/// one revision keeping `current`, all from the transaction [`update`] or
/// [`restore`] read `current` in.
fn commit_write(
    tx: Transaction<'_>,
    current: GuideDoc,
    content_md: &str,
    bullets: &[String],
    day: &str,
    clock: &dyn Clock,
) -> Result<GuideDoc> {
    let note_id = current.note_id;
    let entry = ChangeEntry {
        note_id: note_id.clone(),
        bullets: bullets.to_vec(),
    };
    review::validate_change_entries(&tx, std::slice::from_ref(&entry))?;

    let now = clock.now_ms();
    let new_version = current.version + 1;
    let change_id = review::insert_agent_change(&tx, &note_id, day, now, bullets)?;
    notes::write_guide_internal(&tx, &note_id, content_md, new_version, now)?;
    tx.execute(
        "INSERT INTO vault_guide_revisions
             (id, note_id, previous_md, previous_version, new_version, agent_change_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        params![
            Ulid::new().to_string(),
            note_id,
            current.content_md,
            current.version,
            new_version,
            change_id,
            now,
        ],
    )?;
    tx.commit()?;
    Ok(GuideDoc {
        note_id,
        version: new_version,
        content_md: content_md.to_string(),
    })
}

/// Reindexes the guide from `doc`; a failure here comes after the commit and
/// propagates, as for any other saved note (D8).
fn reindexed(
    vault: &mut Vault,
    doc: GuideDoc,
    embedder: Option<&dyn Embedder>,
) -> Result<GuideDoc> {
    indexer::reindex_note(
        vault.connection_mut(),
        &doc.note_id,
        &doc.content_md,
        embedder,
    )?;
    Ok(doc)
}
