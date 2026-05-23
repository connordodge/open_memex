//! Canvas layer. Mirrors the shape of `notes.rs`: free functions over `&Vault` /
//! `&mut Vault`, ULID newtype id, optimistic-concurrency `expected_version`.
//!
//! A canvas is a user-curated board with placed notes; lines on the canvas are
//! the existing wikilinks in `links` whose `from_note_id` and `to_note_id` are
//! both placed on the canvas. The canvas layer never owns edges.

use std::str::FromStr;

use rusqlite::params;
use rusqlite::types::ToSql;
use serde::{Deserialize, Serialize};
use ulid::Ulid;

use crate::error::MemexError;
use crate::links::{LinkKind, LinkSource};
use crate::vault::{now_unix_ms, Vault};
use crate::Result;

const MAX_TITLE_LEN: usize = 200;

/// Injectable clock seam so tests can fix `created_at` / `updated_at` without
/// monkey-patching the system clock.
pub trait Clock {
    fn now_ms(&self) -> i64;
}

/// Default clock that reads the system clock via `now_unix_ms()`.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        now_unix_ms()
    }
}

/// Stable, sortable canvas identifier (ULID, 26 chars Crockford base32).
#[derive(Debug, Clone, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CanvasId(String);

impl CanvasId {
    pub fn new() -> Self {
        Self(Ulid::new().to_string())
    }

    pub fn parse(s: &str) -> Result<Self> {
        Ulid::from_str(s).map_err(|_| MemexError::InvalidId(s.to_string()))?;
        Ok(Self(s.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for CanvasId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for CanvasId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Canvas {
    pub id: CanvasId,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub version: i64,
}

/// Lightweight list-row form including `node_count` for the rail UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanvasSummary {
    pub id: CanvasId,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub version: i64,
    pub node_count: i64,
}

/// A note placed on a canvas at a fixed position.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanvasNode {
    pub canvas_id: CanvasId,
    pub note_id: String,
    pub note_title: String,
    pub x: f64,
    pub y: f64,
    pub z_order: i64,
    pub placed_at: i64,
}

/// An edge on the canvas — read-through view of a `links` row whose endpoints
/// are both placed on the canvas. Mirrors `links::Link` minus the from/to
/// (those are always the canvas's placed nodes).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanvasEdge {
    pub link_id: String,
    pub from_note_id: String,
    pub to_note_id: String,
    pub link_text: String,
    pub link_kind: LinkKind,
    pub label: Option<String>,
    pub position: i64,
    pub source: LinkSource,
}

/// Full canvas read shape returned by `get_canvas`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanvasDetail {
    pub canvas: Canvas,
    pub nodes: Vec<CanvasNode>,
    pub edges: Vec<CanvasEdge>,
}

// ---------- CRUD ----------

pub fn create_canvas(vault: &mut Vault, title: impl Into<String>) -> Result<Canvas> {
    create_canvas_with_clock(vault, title, &SystemClock)
}

pub fn create_canvas_with_clock(
    vault: &mut Vault,
    title: impl Into<String>,
    clock: &dyn Clock,
) -> Result<Canvas> {
    let title = title.into();
    validate_title(&title)?;

    if let Some(existing) = find_canvas_id_by_title(vault, &title)? {
        return Err(MemexError::TitleConflict {
            existing_id: existing,
            attempted_title: title,
        });
    }

    let now = clock.now_ms();
    let id = CanvasId::new();
    vault.conn().execute(
        "INSERT INTO canvases (id, title, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, 1)",
        params![id.as_str(), title, now, now],
    )?;
    Ok(Canvas {
        id,
        title,
        created_at: now,
        updated_at: now,
        version: 1,
    })
}

pub fn list_canvases(vault: &Vault) -> Result<Vec<CanvasSummary>> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT c.id, c.title, c.created_at, c.updated_at, c.version,
                (SELECT COUNT(*) FROM canvas_nodes n WHERE n.canvas_id = c.id) AS node_count
         FROM canvases c
         ORDER BY c.updated_at DESC, c.id ASC",
    )?;
    let mut rows = stmt.query([])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        let id_s: String = r.get(0)?;
        out.push(CanvasSummary {
            id: CanvasId(id_s),
            title: r.get(1)?,
            created_at: r.get(2)?,
            updated_at: r.get(3)?,
            version: r.get(4)?,
            node_count: r.get(5)?,
        });
    }
    Ok(out)
}

pub fn get_canvas(vault: &Vault, id: &CanvasId) -> Result<CanvasDetail> {
    let conn = vault.connection_ref();
    let canvas = {
        let mut stmt = conn.prepare(
            "SELECT id, title, created_at, updated_at, version
             FROM canvases WHERE id = ?",
        )?;
        let mut rows = stmt.query(params![id.as_str()])?;
        let row = rows
            .next()?
            .ok_or_else(|| MemexError::NotFound(format!("canvas {}", id.as_str())))?;
        let id_s: String = row.get(0)?;
        Canvas {
            id: CanvasId(id_s),
            title: row.get(1)?,
            created_at: row.get(2)?,
            updated_at: row.get(3)?,
            version: row.get(4)?,
        }
    };

    let nodes: Vec<CanvasNode> = {
        let mut stmt = conn.prepare(
            "SELECT cn.canvas_id, cn.note_id, n.title, cn.x, cn.y, cn.z_order, cn.placed_at
             FROM canvas_nodes cn
             JOIN notes n ON n.id = cn.note_id
             WHERE cn.canvas_id = ?
             ORDER BY cn.z_order ASC, cn.placed_at ASC",
        )?;
        let mut rows = stmt.query(params![id.as_str()])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            let canvas_id_s: String = r.get(0)?;
            out.push(CanvasNode {
                canvas_id: CanvasId(canvas_id_s),
                note_id: r.get(1)?,
                note_title: r.get(2)?,
                x: r.get(3)?,
                y: r.get(4)?,
                z_order: r.get(5)?,
                placed_at: r.get(6)?,
            });
        }
        out
    };

    let edges = if nodes.is_empty() {
        Vec::new()
    } else {
        // Build the (N) placeholder list once and reuse it for both IN-clauses.
        let n = nodes.len();
        let placeholders = std::iter::repeat_n("?", n).collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source
             FROM links
             WHERE to_note_id IS NOT NULL
               AND from_note_id IN ({placeholders})
               AND to_note_id   IN ({placeholders})
             ORDER BY from_note_id, position"
        );
        let mut stmt = conn.prepare(&sql)?;
        // Bind the note id list twice in order.
        let mut bound: Vec<&dyn ToSql> = Vec::with_capacity(n * 2);
        for node in &nodes {
            bound.push(&node.note_id);
        }
        for node in &nodes {
            bound.push(&node.note_id);
        }
        let mut rows = stmt.query(bound.as_slice())?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            let to_note_id: Option<String> = r.get(2)?;
            // The WHERE clause already filters NULLs, but be defensive.
            let to_note_id = match to_note_id {
                Some(s) => s,
                None => continue,
            };
            out.push(CanvasEdge {
                link_id: r.get(0)?,
                from_note_id: r.get(1)?,
                to_note_id,
                link_text: r.get(3)?,
                link_kind: r.get(4)?,
                label: r.get(5)?,
                position: r.get(6)?,
                source: r.get(7)?,
            });
        }
        out
    };

    Ok(CanvasDetail {
        canvas,
        nodes,
        edges,
    })
}

pub fn rename_canvas(
    vault: &mut Vault,
    id: &CanvasId,
    new_title: impl Into<String>,
    expected_version: i64,
) -> Result<Canvas> {
    rename_canvas_with_clock(vault, id, new_title, expected_version, &SystemClock)
}

pub fn rename_canvas_with_clock(
    vault: &mut Vault,
    id: &CanvasId,
    new_title: impl Into<String>,
    expected_version: i64,
    clock: &dyn Clock,
) -> Result<Canvas> {
    let new_title = new_title.into();
    validate_title(&new_title)?;

    let (current_version, current_title): (i64, String) = vault
        .connection_ref()
        .query_row(
            "SELECT version, title FROM canvases WHERE id = ?",
            params![id.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                MemexError::NotFound(format!("canvas {}", id.as_str()))
            }
            other => MemexError::from(other),
        })?;

    if current_version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current_version,
        });
    }

    if new_title != current_title {
        if let Some(existing) = find_canvas_id_by_title(vault, &new_title)? {
            if existing != id.as_str() {
                return Err(MemexError::TitleConflict {
                    existing_id: existing,
                    attempted_title: new_title,
                });
            }
        }
    }

    let now = clock.now_ms();
    let new_version = current_version + 1;
    vault.conn().execute(
        "UPDATE canvases SET title = ?, updated_at = ?, version = ? WHERE id = ?",
        params![new_title, now, new_version, id.as_str()],
    )?;
    Ok(Canvas {
        id: id.clone(),
        title: new_title,
        created_at: 0, // overwritten by get below
        updated_at: now,
        version: new_version,
    })
    .and_then(|_| {
        // Return the fresh row so created_at is accurate.
        let row: (i64, i64) = vault.connection_ref().query_row(
            "SELECT created_at, updated_at FROM canvases WHERE id = ?",
            params![id.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(Canvas {
            id: id.clone(),
            title: {
                let t: String = vault.connection_ref().query_row(
                    "SELECT title FROM canvases WHERE id = ?",
                    params![id.as_str()],
                    |r| r.get(0),
                )?;
                t
            },
            created_at: row.0,
            updated_at: row.1,
            version: new_version,
        })
    })
}

pub fn delete_canvas(vault: &mut Vault, id: &CanvasId, expected_version: i64) -> Result<()> {
    let current_version: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT version FROM canvases WHERE id = ?",
            params![id.as_str()],
            |r| r.get(0),
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                MemexError::NotFound(format!("canvas {}", id.as_str()))
            }
            other => MemexError::from(other),
        })?;

    if current_version != expected_version {
        return Err(MemexError::VersionConflict {
            expected: expected_version,
            current: current_version,
        });
    }

    vault
        .conn()
        .execute("DELETE FROM canvases WHERE id = ?", params![id.as_str()])?;
    Ok(())
}

pub fn add_to_canvas(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    note_id: &str,
    x: f64,
    y: f64,
) -> Result<CanvasNode> {
    add_to_canvas_with_clock(vault, canvas_id, note_id, x, y, &SystemClock)
}

pub fn add_to_canvas_with_clock(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    note_id: &str,
    x: f64,
    y: f64,
    clock: &dyn Clock,
) -> Result<CanvasNode> {
    require_canvas_exists(vault, canvas_id)?;
    require_note_exists(vault, note_id)?;

    let now = clock.now_ms();

    {
        let tx = vault.conn_mut().transaction()?;
        // Idempotent: if a placement already exists, return it unchanged.
        let existing: Option<(f64, f64, i64, i64)> = tx
            .query_row(
                "SELECT x, y, z_order, placed_at FROM canvas_nodes
                 WHERE canvas_id = ? AND note_id = ?",
                params![canvas_id.as_str(), note_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(other),
            })?;

        if existing.is_none() {
            tx.execute(
                "INSERT INTO canvas_nodes (canvas_id, note_id, x, y, z_order, placed_at)
                 VALUES (?, ?, ?, ?, 0, ?)",
                params![canvas_id.as_str(), note_id, x, y, now],
            )?;
            tx.execute(
                "UPDATE canvases SET updated_at = ?, version = version + 1 WHERE id = ?",
                params![now, canvas_id.as_str()],
            )?;
        }
        tx.commit()?;
    }

    read_canvas_node(vault, canvas_id, note_id)
}

pub fn remove_from_canvas(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    note_id: &str,
) -> Result<()> {
    remove_from_canvas_with_clock(vault, canvas_id, note_id, &SystemClock)
}

pub fn remove_from_canvas_with_clock(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    note_id: &str,
    clock: &dyn Clock,
) -> Result<()> {
    let now = clock.now_ms();
    let tx = vault.conn_mut().transaction()?;
    let n = tx.execute(
        "DELETE FROM canvas_nodes WHERE canvas_id = ? AND note_id = ?",
        params![canvas_id.as_str(), note_id],
    )?;
    if n > 0 {
        tx.execute(
            "UPDATE canvases SET updated_at = ?, version = version + 1 WHERE id = ?",
            params![now, canvas_id.as_str()],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn move_node(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    note_id: &str,
    x: f64,
    y: f64,
    z_order: Option<i64>,
) -> Result<CanvasNode> {
    move_node_with_clock(vault, canvas_id, note_id, x, y, z_order, &SystemClock)
}

pub fn move_node_with_clock(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    note_id: &str,
    x: f64,
    y: f64,
    z_order: Option<i64>,
    clock: &dyn Clock,
) -> Result<CanvasNode> {
    let now = clock.now_ms();
    let tx = vault.conn_mut().transaction()?;
    let n = match z_order {
        Some(z) => tx.execute(
            "UPDATE canvas_nodes SET x = ?, y = ?, z_order = ?
             WHERE canvas_id = ? AND note_id = ?",
            params![x, y, z, canvas_id.as_str(), note_id],
        )?,
        None => tx.execute(
            "UPDATE canvas_nodes SET x = ?, y = ?
             WHERE canvas_id = ? AND note_id = ?",
            params![x, y, canvas_id.as_str(), note_id],
        )?,
    };
    if n == 0 {
        tx.rollback()?;
        return Err(MemexError::NotFound(format!(
            "canvas_node ({}, {})",
            canvas_id.as_str(),
            note_id
        )));
    }
    tx.execute(
        "UPDATE canvases SET updated_at = ?, version = version + 1 WHERE id = ?",
        params![now, canvas_id.as_str()],
    )?;
    tx.commit()?;
    read_canvas_node(vault, canvas_id, note_id)
}

pub fn move_nodes_batch(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    moves: &[(String, f64, f64)],
) -> Result<Vec<CanvasNode>> {
    move_nodes_batch_with_clock(vault, canvas_id, moves, &SystemClock)
}

pub fn move_nodes_batch_with_clock(
    vault: &mut Vault,
    canvas_id: &CanvasId,
    moves: &[(String, f64, f64)],
    clock: &dyn Clock,
) -> Result<Vec<CanvasNode>> {
    let now = clock.now_ms();
    {
        let tx = vault.conn_mut().transaction()?;
        for (note_id, x, y) in moves {
            let n = tx.execute(
                "UPDATE canvas_nodes SET x = ?, y = ?
                 WHERE canvas_id = ? AND note_id = ?",
                params![x, y, canvas_id.as_str(), note_id],
            )?;
            if n == 0 {
                // Rolls back the whole batch — atomic semantics required by the spec.
                tx.rollback()?;
                return Err(MemexError::NotFound(format!(
                    "canvas_node ({}, {})",
                    canvas_id.as_str(),
                    note_id
                )));
            }
        }
        if !moves.is_empty() {
            tx.execute(
                "UPDATE canvases SET updated_at = ?, version = version + 1 WHERE id = ?",
                params![now, canvas_id.as_str()],
            )?;
        }
        tx.commit()?;
    }

    let mut out = Vec::with_capacity(moves.len());
    for (note_id, _, _) in moves {
        out.push(read_canvas_node(vault, canvas_id, note_id)?);
    }
    Ok(out)
}

// ---------- helpers ----------

fn validate_title(t: &str) -> Result<()> {
    let trimmed = t.trim();
    if trimmed.is_empty() {
        return Err(MemexError::TitleInvalid("title cannot be empty".into()));
    }
    if trimmed.len() != t.len() {
        return Err(MemexError::TitleInvalid(
            "title cannot have leading or trailing whitespace".into(),
        ));
    }
    if t.chars().count() > MAX_TITLE_LEN {
        return Err(MemexError::TitleInvalid(format!(
            "title too long ({} chars, max {})",
            t.chars().count(),
            MAX_TITLE_LEN
        )));
    }
    Ok(())
}

fn find_canvas_id_by_title(vault: &Vault, title: &str) -> Result<Option<String>> {
    vault
        .connection_ref()
        .query_row(
            "SELECT id FROM canvases WHERE title = ?",
            params![title],
            |r| r.get::<_, String>(0),
        )
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other.into()),
        })
}

fn require_canvas_exists(vault: &Vault, id: &CanvasId) -> Result<()> {
    let exists: i64 = vault.connection_ref().query_row(
        "SELECT COUNT(*) FROM canvases WHERE id = ?",
        params![id.as_str()],
        |r| r.get(0),
    )?;
    if exists == 0 {
        return Err(MemexError::NotFound(format!("canvas {}", id.as_str())));
    }
    Ok(())
}

fn require_note_exists(vault: &Vault, note_id: &str) -> Result<()> {
    let exists: i64 = vault.connection_ref().query_row(
        "SELECT COUNT(*) FROM notes WHERE id = ?",
        params![note_id],
        |r| r.get(0),
    )?;
    if exists == 0 {
        return Err(MemexError::NotFound(format!("note {note_id}")));
    }
    Ok(())
}

fn read_canvas_node(vault: &Vault, canvas_id: &CanvasId, note_id: &str) -> Result<CanvasNode> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT cn.canvas_id, cn.note_id, n.title, cn.x, cn.y, cn.z_order, cn.placed_at
         FROM canvas_nodes cn
         JOIN notes n ON n.id = cn.note_id
         WHERE cn.canvas_id = ? AND cn.note_id = ?",
    )?;
    let mut rows = stmt.query(params![canvas_id.as_str(), note_id])?;
    let row = rows.next()?.ok_or_else(|| {
        MemexError::NotFound(format!(
            "canvas_node ({}, {})",
            canvas_id.as_str(),
            note_id
        ))
    })?;
    let canvas_id_s: String = row.get(0)?;
    Ok(CanvasNode {
        canvas_id: CanvasId(canvas_id_s),
        note_id: row.get(1)?,
        note_title: row.get(2)?,
        x: row.get(3)?,
        y: row.get(4)?,
        z_order: row.get(5)?,
        placed_at: row.get(6)?,
    })
}
