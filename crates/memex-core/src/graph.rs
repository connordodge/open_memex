//! Graph traversal over the `links` table. Used by the `neighbors` MCP tool
//! and any caller that wants "what's adjacent to this idea?" without
//! re-running search.
//!
//! The traversal treats the link graph as **undirected** (an edge is an edge,
//! regardless of direction) because that's what users mean when they ask
//! "what's connected." Each returned hit carries the actual edge metadata so
//! the caller can still tell direction + kind.

use std::collections::{HashMap, HashSet, VecDeque};

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use crate::Result;

pub const MAX_DEPTH: i64 = 3;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EdgeMeta {
    pub from_note_id: String,
    pub to_note_id: String,
    pub link_kind: String,
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NeighborHit {
    pub note_id: String,
    pub title: String,
    pub distance: i64,
    pub edges: Vec<EdgeMeta>,
}

/// BFS adjacent notes up to `depth` hops. Self-edges (from == to) are excluded.
/// `kind_filter` restricts which edges are followed (matches edge `link_kind`
/// exactly).
pub fn neighbors(
    conn: &Connection,
    root_note_id: &str,
    depth: i64,
    kind_filter: Option<&str>,
) -> Result<Vec<NeighborHit>> {
    let depth = depth.clamp(1, MAX_DEPTH);

    let mut visited: HashSet<String> = HashSet::new();
    visited.insert(root_note_id.to_string());

    let mut hits: HashMap<String, NeighborHit> = HashMap::new();
    let mut queue: VecDeque<(String, i64)> = VecDeque::new();
    queue.push_back((root_note_id.to_string(), 0));

    while let Some((current, dist)) = queue.pop_front() {
        if dist >= depth {
            continue;
        }
        let edges = adjacent_edges(conn, &current, kind_filter)?;
        for edge in edges {
            // Determine "the other end".
            let other = if edge.from_note_id == current {
                edge.to_note_id.clone()
            } else {
                edge.from_note_id.clone()
            };
            // Skip self-edges and ghost links (no resolved target).
            if other == current || other.is_empty() {
                continue;
            }
            // Record the edge on the matching hit (always — even if visited,
            // so that later edges to the same neighbor accumulate).
            let title = note_title(conn, &other)?.unwrap_or_else(|| "(unresolved)".to_string());
            let hit = hits.entry(other.clone()).or_insert_with(|| NeighborHit {
                note_id: other.clone(),
                title,
                distance: dist + 1,
                edges: Vec::new(),
            });
            // Keep the *shortest* distance recorded.
            if dist + 1 < hit.distance {
                hit.distance = dist + 1;
            }
            hit.edges.push(edge);

            if !visited.contains(&other) {
                visited.insert(other.clone());
                queue.push_back((other, dist + 1));
            }
        }
    }

    let mut out: Vec<NeighborHit> = hits.into_values().collect();
    out.sort_by(|a, b| a.distance.cmp(&b.distance).then(a.title.cmp(&b.title)));
    Ok(out)
}

/// All edges (in or out) touching `note_id`, with optional kind filter.
/// Self-edges are filtered out at the SQL level.
fn adjacent_edges(
    conn: &Connection,
    note_id: &str,
    kind_filter: Option<&str>,
) -> Result<Vec<EdgeMeta>> {
    let mut out = Vec::new();
    let where_kind = match kind_filter {
        Some(_) => " AND link_kind = ?",
        None => "",
    };
    // Outgoing edges (from this note → other).
    {
        let sql = format!(
            "SELECT from_note_id, to_note_id, link_kind, label
             FROM links
             WHERE from_note_id = ? AND to_note_id IS NOT NULL AND to_note_id != ?{where_kind}"
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = match kind_filter {
            Some(k) => stmt.query(params![note_id, note_id, k])?,
            None => stmt.query(params![note_id, note_id])?,
        };
        while let Some(r) = rows.next()? {
            out.push(EdgeMeta {
                from_note_id: r.get(0)?,
                to_note_id: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                link_kind: r.get(2)?,
                label: r.get(3)?,
            });
        }
    }
    // Incoming edges (other → this note).
    {
        let sql = format!(
            "SELECT from_note_id, to_note_id, link_kind, label
             FROM links
             WHERE to_note_id = ? AND from_note_id != ?{where_kind}"
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = match kind_filter {
            Some(k) => stmt.query(params![note_id, note_id, k])?,
            None => stmt.query(params![note_id, note_id])?,
        };
        while let Some(r) = rows.next()? {
            out.push(EdgeMeta {
                from_note_id: r.get(0)?,
                to_note_id: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                link_kind: r.get(2)?,
                label: r.get(3)?,
            });
        }
    }
    Ok(out)
}

fn note_title(conn: &Connection, note_id: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT title FROM notes WHERE id = ?",
            params![note_id],
            |r| r.get::<_, String>(0),
        )
        .ok())
}
