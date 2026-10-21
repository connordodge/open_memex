//! App API reads for the graph view and the activity log (#85): the rows the
//! app's `GraphReads` (`app/lib/src/db/graph_reads.dart`) and `ActivityReads`
//! (`app/lib/src/db/activity_reads.dart`) read today, for the graph routes of
//! the vault server. Field names are the Dart models' in snake case.

use rusqlite::types::Value as SqlValue;
use serde::Serialize;
use serde_json::Value as JsonValue;

use crate::{Result, Vault};

/// A row of `GET /graph/notes`: the app's `GraphNoteRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GraphNoteRow {
    pub id: String,
    pub title: String,
    /// `json_extract(frontmatter, '$.role')` when the frontmatter is valid
    /// JSON and that value comes back as text; `None` otherwise.
    pub role: Option<String>,
}

/// A row of `GET /graph/links`: the app's `GraphLinkRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GraphLinkRow {
    pub from: String,
    pub to: String,
    pub kind: String,
    pub label: Option<String>,
}

/// A row of `GET /notes/{note_id}/agent-changes`: the app's `AgentChangeRow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AgentChangeRow {
    pub id: String,
    pub note_id: String,
    pub day: String,
    /// Unix ms.
    pub created_at: i64,
    pub bullets: Vec<String>,
}

/// `GraphReads.graphNotes`: every note with its role, ordered by id.
pub fn graph_notes(vault: &Vault) -> Result<Vec<GraphNoteRow>> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT id, title, (CASE WHEN json_valid(frontmatter) \
         THEN json_extract(frontmatter, '$.role') END) AS role \
         FROM notes ORDER BY id",
    )?;
    let rows = stmt.query_map([], |r| {
        let role = match r.get::<_, SqlValue>(2)? {
            SqlValue::Text(role) => Some(role),
            _ => None,
        };
        Ok(GraphNoteRow {
            id: r.get(0)?,
            title: r.get(1)?,
            role,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// `GraphReads.graphLinks`: every link whose target note exists, ordered by
/// source note, then position.
pub fn graph_links(vault: &Vault) -> Result<Vec<GraphLinkRow>> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT l.from_note_id, l.to_note_id, l.link_kind, l.label FROM links l \
         JOIN notes t ON t.id = l.to_note_id \
         ORDER BY l.from_note_id, l.position",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(GraphLinkRow {
            from: r.get(0)?,
            to: r.get(1)?,
            kind: r.get(2)?,
            label: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// `ActivityReads.agentChanges`: `note_id`'s change-log rows, newest
/// `created_at` first, then newest inserted first.
pub fn agent_changes(vault: &Vault, note_id: &str) -> Result<Vec<AgentChangeRow>> {
    let mut stmt = vault.connection_ref().prepare(
        "SELECT id, note_id, day, created_at, bullets_json FROM agent_changes \
         WHERE note_id = ? ORDER BY created_at DESC, rowid DESC",
    )?;
    let rows = stmt.query_map([note_id], |r| {
        Ok(AgentChangeRow {
            id: r.get(0)?,
            note_id: r.get(1)?,
            day: r.get(2)?,
            created_at: r.get(3)?,
            bullets: decode_bullets(&r.get::<_, SqlValue>(4)?),
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// The Dart read's `_decodeBullets`: a text value holding a JSON list gives
/// each item's Dart string form; anything else gives no bullets.
fn decode_bullets(raw: &SqlValue) -> Vec<String> {
    let SqlValue::Text(text) = raw else {
        return Vec::new();
    };
    match serde_json::from_str::<JsonValue>(text) {
        Ok(JsonValue::Array(items)) => items.iter().map(dart_string).collect(),
        _ => Vec::new(),
    }
}

/// `'$b'` in Dart for a value `jsonDecode` returned.
fn dart_string(value: &JsonValue) -> String {
    match value {
        JsonValue::Null => "null".to_string(),
        JsonValue::Bool(b) => b.to_string(),
        JsonValue::Number(n) => match (n.as_i64(), n.as_f64()) {
            (Some(i), _) => i.to_string(),
            (None, Some(f)) => dart_double(f),
            (None, None) => n.to_string(),
        },
        JsonValue::String(s) => s.clone(),
        JsonValue::Array(items) => {
            let items: Vec<String> = items.iter().map(dart_string).collect();
            format!("[{}]", items.join(", "))
        }
        JsonValue::Object(map) => {
            let entries: Vec<String> = map
                .iter()
                .map(|(k, v)| format!("{k}: {}", dart_string(v)))
                .collect();
            format!("{{{}}}", entries.join(", "))
        }
    }
}

/// Dart's `double.toString()`: shortest round-trip digits, a `.0` on whole
/// numbers, and exponent form below 1e-6 or from 1e21.
fn dart_double(f: f64) -> String {
    let a = f.abs();
    if a != 0.0 && !(1e-6..1e21).contains(&a) {
        let s = format!("{f:e}");
        match s.split_once('e') {
            Some((m, e)) if !e.starts_with('-') => format!("{m}e+{e}"),
            _ => s,
        }
    } else if f.fract() == 0.0 {
        format!("{f:.1}")
    } else {
        f.to_string()
    }
}
