//! Smart Folders.
//!
//! A tree of vault rows (`smart_folders`) with case-insensitively unique
//! sibling names, plus topic-note memberships (`smart_folder_members`).
//! Depth is limited by the vault setting `smart_folder_max_depth`
//! ([`crate::vault_settings`]) for every caller; pinning guards only
//! [`Caller::Agent`], and person writes pin what they touch (architect ruling
//! D17, Spec Reqs 34–47).

use std::collections::HashMap;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use serde_json::{Map, Value};
use ulid::Ulid;

use crate::caller::Caller;
use crate::canvas::Clock;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::indexer;
use crate::notes::{self, NoteId, RenameOptions, UpdateNote};
use crate::vault::Vault;
use crate::vault_settings;
use crate::Result;

/// One Smart Folder. `depth` is 1 for a root folder, 2 for its child, ….
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolder {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub pinned: bool,
    pub depth: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// A topic note's membership as listed under its folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FolderMember {
    pub note_id: String,
    pub title: String,
    pub pinned: bool,
}

/// A folder in [`SmartFolderList::folders`]: the folder's fields plus its
/// members.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ListedFolder {
    #[serde(flatten)]
    pub folder: SmartFolder,
    pub members: Vec<FolderMember>,
}

/// A non-daily note with no membership (the implicit Unsorted row).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UnsortedNote {
    pub note_id: String,
    pub title: String,
}

/// The whole tree as a flat list (each folder carries `parent_id`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmartFolderList {
    pub max_depth: i64,
    pub folders: Vec<ListedFolder>,
    pub unsorted: Vec<UnsortedNote>,
}

/// The result of [`add_member`]. `role_set` is true when a role-less note
/// became `role: topic` (Connor Q3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Membership {
    pub smart_folder_id: String,
    pub note_id: String,
    pub pinned: bool,
    pub role_set: bool,
}

/// Where [`update_folder`] moves a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NewParent {
    /// Make it a root folder (`--to-root`, MCP `to_root: true`).
    Root,
    /// Make it a child of this folder id.
    Folder(String),
}

/// A partial update of a Smart Folder. `None` leaves the field unchanged.
/// `pinned` is honoured for [`Caller::Person`] only; without it, a person
/// rename or re-parent pins the folder (Req 41).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FolderUpdate {
    pub name: Option<String>,
    pub parent: Option<NewParent>,
    pub pinned: Option<bool>,
}

/// Every folder with its members, plus the unsorted notes and the current
/// `smart_folder_max_depth`. Folders come parents first (by depth, then
/// name); members and unsorted notes by title.
pub fn list_folders(vault: &Vault) -> Result<SmartFolderList> {
    let conn = vault.conn();
    let mut members: HashMap<String, Vec<FolderMember>> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT m.smart_folder_id, m.note_id, n.title, m.pinned
             FROM smart_folder_members m JOIN notes n ON n.id = m.note_id
             ORDER BY n.title COLLATE NOCASE, m.note_id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                FolderMember {
                    note_id: r.get(1)?,
                    title: r.get(2)?,
                    pinned: r.get(3)?,
                },
            ))
        })?;
        for row in rows {
            let (folder_id, member) = row?;
            members.entry(folder_id).or_default().push(member);
        }
    }

    let mut stmt = conn.prepare(
        "WITH RECURSIVE tree(id, depth) AS (
             SELECT id, 1 FROM smart_folders WHERE parent_id IS NULL
             UNION ALL
             SELECT f.id, tree.depth + 1 FROM smart_folders f
             JOIN tree ON f.parent_id = tree.id
             WHERE tree.depth < 64
         )
         SELECT f.id, f.name, f.parent_id, f.pinned, f.created_at, f.updated_at, tree.depth
         FROM smart_folders f JOIN tree ON tree.id = f.id
         ORDER BY tree.depth, f.name COLLATE NOCASE, f.id",
    )?;
    let folders = stmt
        .query_map([], |r| {
            let row = FolderRow::from_row(r)?;
            Ok(row.into_folder(r.get(6)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .map(|folder| ListedFolder {
            members: members.remove(&folder.id).unwrap_or_default(),
            folder,
        })
        .collect();

    let mut stmt = conn.prepare(
        "SELECT id, title FROM notes
         WHERE NOT EXISTS (SELECT 1 FROM smart_folder_members m WHERE m.note_id = notes.id)
           AND COALESCE(CASE WHEN json_valid(frontmatter)
                             THEN json_extract(frontmatter, '$.role') END, '') != 'daily'
         ORDER BY title COLLATE NOCASE, id",
    )?;
    let unsorted = stmt
        .query_map([], |r| {
            Ok(UnsortedNote {
                note_id: r.get(0)?,
                title: r.get(1)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    Ok(SmartFolderList {
        max_depth: vault_settings::smart_folder_max_depth(vault)?,
        folders,
        unsorted,
    })
}

/// Creates a folder named `name` under `parent_id` (`None` = root). Pinned
/// when the caller is the person.
pub fn create_folder(
    vault: &mut Vault,
    name: &str,
    parent_id: Option<&str>,
    caller: Caller,
    clock: &dyn Clock,
) -> Result<SmartFolder> {
    let conn = vault.conn();
    let parent_depth = match parent_id {
        None => 0,
        Some(parent) => {
            load(conn, parent)?;
            depth(conn, parent)?
        }
    };
    let depth = parent_depth + 1;
    check_depth(vault, depth)?;
    check_sibling_name(conn, parent_id, name, None)?;

    let now = clock.now_ms();
    let row = FolderRow {
        id: Ulid::new().to_string(),
        name: name.to_string(),
        parent_id: parent_id.map(str::to_string),
        pinned: caller == Caller::Person,
        created_at: now,
        updated_at: now,
    };
    conn.execute(
        "INSERT INTO smart_folders (id, name, parent_id, pinned, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        params![
            row.id,
            row.name,
            row.parent_id,
            row.pinned,
            row.created_at,
            row.updated_at
        ],
    )?;
    Ok(row.into_folder(depth))
}

/// Renames, re-parents and (person only) pins or unpins a folder.
///
/// Checks run in this order and nothing is written unless all pass:
/// `not_found`, `pinned_rule` (agent only), `not_found` for the new parent,
/// `folder_cycle`, `depth_exceeded` (re-parents only; a rename is never
/// depth-checked), `name_conflict`. An agent's `pinned` is ignored, and an
/// update that changes nothing writes nothing.
pub fn update_folder(
    vault: &mut Vault,
    id: &str,
    update: FolderUpdate,
    caller: Caller,
    clock: &dyn Clock,
) -> Result<SmartFolder> {
    let conn = vault.conn();
    let current = load(conn, id)?;
    let renames = update.name.is_some();
    let moves = update.parent.is_some();
    if caller == Caller::Agent && current.pinned && (renames || moves) {
        return Err(pinned_folder(&current));
    }

    let (parent_id, parent_depth) = match update.parent {
        None => (current.parent_id.clone(), None),
        Some(NewParent::Root) => (None, Some(0)),
        Some(NewParent::Folder(parent)) => {
            load(conn, &parent)?;
            let chain = ancestry(conn, &parent)?;
            if chain.iter().any(|ancestor| ancestor == id) {
                return Err(MemexError::FolderCycle(format!(
                    "\"{}\" cannot move under itself or one of its subfolders",
                    current.name
                )));
            }
            (Some(parent), Some(chain.len() as i64))
        }
    };
    if let Some(parent_depth) = parent_depth {
        check_depth(vault, parent_depth + height(conn, id)?)?;
    }
    let name = update.name.unwrap_or_else(|| current.name.clone());
    check_sibling_name(conn, parent_id.as_deref(), &name, Some(id))?;

    let pinned = match caller {
        Caller::Agent => current.pinned,
        Caller::Person => update.pinned.unwrap_or(current.pinned || renames || moves),
    };
    if renames || moves || pinned != current.pinned {
        conn.execute(
            "UPDATE smart_folders SET name = ?, parent_id = ?, pinned = ?, updated_at = ?
             WHERE id = ?",
            params![name, parent_id, pinned, clock.now_ms(), id],
        )?;
    }
    read_folder(conn, id)
}

/// Deletes a folder: re-parents its children to its parent, drops its
/// memberships, never deletes a note. An agent may not delete a pinned
/// folder or one holding a pinned membership (`pinned_rule`); a child whose
/// name clashes at its new level fails the whole delete (`name_conflict`).
pub fn delete_folder(vault: &mut Vault, id: &str, caller: Caller) -> Result<()> {
    let conn = vault.conn();
    let folder = load(conn, id)?;
    if caller == Caller::Agent {
        if folder.pinned {
            return Err(pinned_folder(&folder));
        }
        let pinned_member: Option<(String, String)> = conn
            .query_row(
                "SELECT m.note_id, n.title
                 FROM smart_folder_members m JOIN notes n ON n.id = m.note_id
                 WHERE m.smart_folder_id = ? AND m.pinned != 0
                 ORDER BY n.title COLLATE NOCASE, m.note_id LIMIT 1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((note_id, title)) = pinned_member {
            return Err(pinned_membership(id, &note_id, &title));
        }
    }

    let children: Vec<String> = conn
        .prepare("SELECT name FROM smart_folders WHERE parent_id = ? ORDER BY name, id")?
        .query_map(params![id], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    for child in &children {
        check_sibling_name(conn, folder.parent_id.as_deref(), child, Some(id))?;
    }

    // The folder goes before its children move up: a child may share its
    // name, which the sibling index would reject while both exist. The
    // children's `parent_id` dangles until the UPDATE, so the foreign-key
    // check waits for the commit.
    let tx = vault.conn_mut().transaction()?;
    tx.pragma_update(None, "defer_foreign_keys", "ON")?;
    tx.execute(
        "DELETE FROM smart_folder_members WHERE smart_folder_id = ?",
        params![id],
    )?;
    tx.execute("DELETE FROM smart_folders WHERE id = ?", params![id])?;
    tx.execute(
        "UPDATE smart_folders SET parent_id = ? WHERE parent_id = ?",
        params![folder.parent_id, id],
    )?;
    tx.commit()?;
    Ok(())
}

/// Adds a topic note to a folder (idempotent upsert). `pinned: None` means
/// the caller's default (person: pinned, agent: unpinned); `Some(_)` is the
/// person's membership pin toggle. A person adding a role-less non-daily note
/// sets its `role: topic` and reindexes it with `embedder`.
///
/// A daily note is `role_rule` for every caller; for the agent so is any
/// note whose role is not `topic`. An agent never changes an existing pin.
pub fn add_member(
    vault: &mut Vault,
    folder_id: &str,
    note_id: &str,
    pinned: Option<bool>,
    caller: Caller,
    embedder: Option<&dyn Embedder>,
) -> Result<Membership> {
    load(vault.conn(), folder_id)?;
    let note = notes::get_note(vault, &NoteId::parse(note_id)?)?;
    let role_set = match note.frontmatter.get("role").and_then(Value::as_str) {
        Some(TOPIC) => false,
        None if caller == Caller::Person => true,
        Some(DAILY) => {
            return Err(MemexError::RoleRule(format!(
                "\"{}\" is a daily note (role: daily); only topic notes go in Smart Folders",
                note.title
            )))
        }
        _ => {
            return Err(MemexError::RoleRule(format!(
                "\"{}\" is not a topic note; an agent can add only notes with role: topic",
                note.title
            )))
        }
    };

    let existing: Option<bool> = vault
        .conn()
        .query_row(
            "SELECT pinned FROM smart_folder_members WHERE smart_folder_id = ? AND note_id = ?",
            params![folder_id, note_id],
            |r| r.get(0),
        )
        .optional()?;
    let pinned = match caller {
        Caller::Person => pinned.unwrap_or(true),
        Caller::Agent => existing.unwrap_or(false),
    };

    if role_set {
        // Connor Q3: through the person write path, which bumps the version
        // (D8), then reindex with the returned content.
        let mut frontmatter = match note.frontmatter {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        frontmatter.insert("role".into(), TOPIC.into());
        let patch = UpdateNote {
            frontmatter: Some(Value::Object(frontmatter)),
            ..Default::default()
        };
        let updated = notes::update_note_as(
            vault,
            &note.id,
            note.version,
            patch,
            RenameOptions::default(),
            Caller::Person,
        )?;
        indexer::reindex_note(
            vault.conn_mut(),
            updated.id.as_str(),
            &updated.content_md,
            embedder,
        )?;
    }

    vault.conn().execute(
        "INSERT INTO smart_folder_members (smart_folder_id, note_id, pinned) VALUES (?, ?, ?)
         ON CONFLICT(smart_folder_id, note_id) DO UPDATE SET pinned = excluded.pinned",
        params![folder_id, note_id, pinned],
    )?;
    Ok(Membership {
        smart_folder_id: folder_id.to_string(),
        note_id: note_id.to_string(),
        pinned,
        role_set,
    })
}

/// Removes a topic note from a folder. A note that is not a member is
/// `not_found`. An agent may not remove any membership of a pinned folder,
/// nor a pinned membership (`pinned_rule`).
pub fn remove_member(
    vault: &mut Vault,
    folder_id: &str,
    note_id: &str,
    caller: Caller,
) -> Result<()> {
    let conn = vault.conn();
    let folder = load(conn, folder_id)?;
    let (pinned, title): (bool, String) = conn
        .query_row(
            "SELECT m.pinned, n.title
             FROM smart_folder_members m JOIN notes n ON n.id = m.note_id
             WHERE m.smart_folder_id = ? AND m.note_id = ?",
            params![folder_id, note_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| {
            MemexError::NotFound(format!(
                "note {note_id} is not in Smart Folder \"{}\"",
                folder.name
            ))
        })?;
    if caller == Caller::Agent {
        if folder.pinned {
            return Err(pinned_folder(&folder));
        }
        if pinned {
            return Err(pinned_membership(folder_id, note_id, &title));
        }
    }
    conn.execute(
        "DELETE FROM smart_folder_members WHERE smart_folder_id = ? AND note_id = ?",
        params![folder_id, note_id],
    )?;
    Ok(())
}

// ---------- internals ----------

const TOPIC: &str = "topic";
const DAILY: &str = "daily";

/// A `smart_folders` row.
struct FolderRow {
    id: String,
    name: String,
    parent_id: Option<String>,
    pinned: bool,
    created_at: i64,
    updated_at: i64,
}

impl FolderRow {
    fn from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: r.get(0)?,
            name: r.get(1)?,
            parent_id: r.get(2)?,
            pinned: r.get(3)?,
            created_at: r.get(4)?,
            updated_at: r.get(5)?,
        })
    }

    fn into_folder(self, depth: i64) -> SmartFolder {
        SmartFolder {
            id: self.id,
            name: self.name,
            parent_id: self.parent_id,
            pinned: self.pinned,
            depth,
            created_at: self.created_at,
            updated_at: self.updated_at,
        }
    }
}

/// The folder row, or `not_found`.
fn load(conn: &Connection, id: &str) -> Result<FolderRow> {
    conn.query_row(
        "SELECT id, name, parent_id, pinned, created_at, updated_at
         FROM smart_folders WHERE id = ?",
        params![id],
        FolderRow::from_row,
    )
    .optional()?
    .ok_or_else(|| MemexError::NotFound(format!("Smart Folder {id}")))
}

fn read_folder(conn: &Connection, id: &str) -> Result<SmartFolder> {
    let depth = depth(conn, id)?;
    Ok(load(conn, id)?.into_folder(depth))
}

/// The folder and its ancestors, nearest first; its length is the folder's
/// depth.
fn ancestry(conn: &Connection, id: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "WITH RECURSIVE up(id, parent_id, n) AS (
             SELECT id, parent_id, 1 FROM smart_folders WHERE id = ?1
             UNION ALL
             SELECT f.id, f.parent_id, up.n + 1 FROM smart_folders f
             JOIN up ON f.id = up.parent_id
             WHERE up.n < 64
         )
         SELECT id FROM up ORDER BY n",
    )?;
    let chain = stmt
        .query_map(params![id], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(chain)
}

/// Root is depth 1.
fn depth(conn: &Connection, id: &str) -> Result<i64> {
    Ok(ancestry(conn, id)?.len() as i64)
}

/// The height of the subtree rooted at `id`; a leaf has height 1.
fn height(conn: &Connection, id: &str) -> Result<i64> {
    let height = conn.query_row(
        "WITH RECURSIVE down(id, n) AS (
             SELECT id, 1 FROM smart_folders WHERE id = ?1
             UNION ALL
             SELECT f.id, down.n + 1 FROM smart_folders f
             JOIN down ON f.parent_id = down.id
             WHERE down.n < 64
         )
         SELECT MAX(n) FROM down",
        params![id],
        |r| r.get(0),
    )?;
    Ok(height)
}

/// `depth_exceeded` when `required_depth` is over the vault maximum.
fn check_depth(vault: &Vault, required_depth: i64) -> Result<()> {
    let max_depth = vault_settings::smart_folder_max_depth(vault)?;
    if required_depth > max_depth {
        return Err(MemexError::DepthExceeded {
            max_depth,
            required_depth,
        });
    }
    Ok(())
}

/// `name_conflict` when a folder under `parent_id`, other than `except`, has
/// `name` ignoring case. Compares Unicode lowercase (the `COLLATE NOCASE`
/// index folds ASCII only and is the backstop).
fn check_sibling_name(
    conn: &Connection,
    parent_id: Option<&str>,
    name: &str,
    except: Option<&str>,
) -> Result<()> {
    let wanted = name.to_lowercase();
    let mut stmt = conn.prepare("SELECT id, name FROM smart_folders WHERE parent_id IS ?")?;
    let siblings = stmt.query_map(params![parent_id], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    for sibling in siblings {
        let (sibling_id, sibling_name) = sibling?;
        if Some(sibling_id.as_str()) != except && sibling_name.to_lowercase() == wanted {
            return Err(MemexError::NameConflict(format!(
                "\"{name}\" clashes with the Smart Folder \"{sibling_name}\" at the same level"
            )));
        }
    }
    Ok(())
}

fn pinned_folder(folder: &FolderRow) -> MemexError {
    MemexError::PinnedRule {
        item: folder.id.clone(),
        name: format!("Smart Folder \"{}\"", folder.name),
    }
}

fn pinned_membership(folder_id: &str, note_id: &str, title: &str) -> MemexError {
    MemexError::PinnedRule {
        item: format!("{folder_id}/{note_id}"),
        name: format!("the membership of \"{title}\""),
    }
}
