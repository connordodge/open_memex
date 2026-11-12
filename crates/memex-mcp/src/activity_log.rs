//! The vault side of the agent activity log (Spec #390 reqs 8, 9, 11, 12):
//! the names a write call may destroy, read before it runs, and the one
//! `agent_activity` row written after it. The `call_tool` hook in
//! `impl ServerHandler for Memex` calls these with the vault lock taken for
//! each call only, never across the tool itself.

use memex_core::agents::activity::{self, ActivityEntry};
use rmcp::model::{CallToolRequestParams, CallToolResult};
use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use crate::activity_summary::{summarize, PreSnapshot, TitleLookup};
use crate::presence::AgentSession;

/// The call's arguments as one JSON value (an empty object when it has none).
pub(crate) fn params_of(request: &CallToolRequestParams) -> Value {
    Value::Object(request.arguments.clone().unwrap_or_default())
}

/// The names `tool` may destroy or change, read from the vault before the
/// call: a Smart Folder's name and parent (`update_smart_folder`,
/// `delete_smart_folder`), a canvas title (`delete_canvas`), a link's
/// endpoint titles (`update_link`). Empty for every other tool, and for a
/// name the vault doesn't hold.
pub(crate) fn pre_snapshot(conn: &Connection, tool: &str, params: &Value) -> PreSnapshot {
    let param = |key: &str| params.get(key).and_then(Value::as_str);
    let mut pre = PreSnapshot::default();
    match tool {
        "update_smart_folder" | "delete_smart_folder" => {
            if let Some((name, parent)) = param("id").and_then(|id| folder(conn, id)) {
                pre.folder_name = Some(name);
                pre.folder_parent = parent;
            }
        }
        "delete_canvas" => {
            pre.canvas_title = param("canvas_id").and_then(|id| canvas_title(conn, id))
        }
        "update_link" => {
            if let Some((from, to)) = param("link_id").and_then(|id| link_titles(conn, id)) {
                pre.link_from_title = from;
                pre.link_to_title = to;
            }
        }
        _ => {}
    }
    pre
}

/// Appends the call's `agent_activity` row when `summarize` gives one: the
/// tool's write has committed, and this is a transaction of its own. A
/// failed insert is logged at WARN and never reaches the caller.
pub(crate) fn record(
    conn: &Connection,
    session: &AgentSession,
    tool: &str,
    params: &Value,
    pre: &PreSnapshot,
    result: &CallToolResult,
    created_at: i64,
) {
    let Some(payload) = payload(result) else {
        return;
    };
    let Some(summary) = summarize(tool, params, pre, &payload, &VaultTitles(conn)) else {
        return;
    };
    let entry = ActivityEntry {
        id: ulid::Ulid::new().to_string(),
        session_id: session.session_id.clone(),
        client_name: session.client_name.clone(),
        tool: tool.to_string(),
        summary: summary.text,
        note_id: summary.note_id,
        created_at,
    };
    if let Err(e) = activity::insert(conn, &entry) {
        tracing::warn!(
            tool,
            session_id = %entry.session_id,
            error = %e,
            "agent activity insert failed; the tool result is returned unchanged"
        );
    }
}

/// The tool's JSON payload: its first text content, parsed.
fn payload(result: &CallToolResult) -> Option<Value> {
    let text = result.content.first()?.as_text()?;
    serde_json::from_str(&text.text).ok()
}

/// Title lookups over the vault after the call.
struct VaultTitles<'a>(&'a Connection);

impl TitleLookup for VaultTitles<'_> {
    fn note_title(&self, note_id: &str) -> Option<String> {
        one(self.0, "SELECT title FROM notes WHERE id = ?1", note_id)
    }

    fn folder_name(&self, folder_id: &str) -> Option<String> {
        folder(self.0, folder_id).map(|(name, _)| name)
    }

    fn canvas_title(&self, canvas_id: &str) -> Option<String> {
        canvas_title(self.0, canvas_id)
    }
}

/// A Smart Folder's name and parent id.
fn folder(conn: &Connection, id: &str) -> Option<(String, Option<String>)> {
    conn.query_row(
        "SELECT name, parent_id FROM smart_folders WHERE id = ?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .ok()
    .flatten()
}

fn canvas_title(conn: &Connection, id: &str) -> Option<String> {
    one(conn, "SELECT title FROM canvases WHERE id = ?1", id)
}

/// A link's endpoint note titles (`None` for an unresolved or missing end).
fn link_titles(conn: &Connection, id: &str) -> Option<(Option<String>, Option<String>)> {
    conn.query_row(
        "SELECT (SELECT title FROM notes WHERE id = l.from_note_id),
                (SELECT title FROM notes WHERE id = l.to_note_id)
         FROM links l WHERE l.id = ?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .ok()
    .flatten()
}

/// The single text column `sql` selects for `id`.
fn one(conn: &Connection, sql: &str, id: &str) -> Option<String> {
    conn.query_row(sql, [id], |r| r.get(0))
        .optional()
        .ok()
        .flatten()
}
