//! App API read for agents (#390 req 14, 16): the agent presence records
//! and the newest agent activity entries of one vault, for
//! `GET /vaults/{name}/api/v1/agents`. The app's local `AgentsAccess` reads
//! the same data ("One source for both transports").

use std::cmp::Reverse;

use rusqlite::Connection;
use serde::Serialize;

use crate::agents::activity::ActivityEntry;
use crate::agents::presence::{presence_dir, read_all, PresenceRecord};
use crate::{Result, Vault};

/// What [`activity`] reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AgentActivity {
    /// Every parsed presence record in `<vault>/.memex/agents/`, expired or
    /// not, by `last_request_at` descending.
    pub agents: Vec<PresenceRecord>,
    /// The newest 20 `agent_activity` rows, by `created_at` descending, then
    /// `id` descending. Empty when the schema has no `agent_activity` table.
    pub recent: Vec<ActivityEntry>,
}

/// How many `agent_activity` rows [`activity`] reads.
const RECENT_LIMIT: i64 = 20;

/// The agents and recent activity of `vault`.
pub fn activity(vault: &Vault) -> Result<AgentActivity> {
    let mut agents = read_all(&presence_dir(vault.root()));
    agents.sort_by_key(|r| Reverse(r.last_request_at));
    Ok(AgentActivity {
        agents,
        recent: recent(vault.conn())?,
    })
}

/// The newest [`RECENT_LIMIT`] `agent_activity` rows; none when the table
/// does not exist (a schema older than V7).
fn recent(conn: &Connection) -> Result<Vec<ActivityEntry>> {
    let has_table: bool = conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'agent_activity')",
        [],
        |r| r.get(0),
    )?;
    if !has_table {
        return Ok(Vec::new());
    }
    let mut stmt = conn.prepare(
        "SELECT id, session_id, client_name, tool, summary, note_id, created_at
         FROM agent_activity ORDER BY created_at DESC, id DESC LIMIT ?1",
    )?;
    let rows = stmt
        .query_map([RECENT_LIMIT], |r| {
            Ok(ActivityEntry {
                id: r.get(0)?,
                session_id: r.get(1)?,
                client_name: r.get(2)?,
                tool: r.get(3)?,
                summary: r.get(4)?,
                note_id: r.get(5)?,
                created_at: r.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}
