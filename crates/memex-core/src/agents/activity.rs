//! Agent activity log entry (#390 req 9) and its insert (req 11).

use rusqlite::{params, Connection, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

use crate::Result;

/// One row of the `agent_activity` table: a one-line summary of one agent
/// write. `id` is a ULID string (the table's `TEXT PRIMARY KEY`);
/// `created_at` is ms since the Unix epoch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityEntry {
    pub id: String,
    pub session_id: String,
    pub client_name: String,
    pub tool: String,
    pub summary: String,
    pub note_id: Option<String>,
    pub created_at: i64,
}

/// The newest rows `agent_activity` keeps (req 11).
const KEEP: i64 = 1_000;

/// Inserts `entry` into `agent_activity` and prunes the table to its newest
/// 1,000 rows (by `created_at`, then `id`), in one transaction of its own.
/// On error nothing is written.
pub fn insert(conn: &Connection, entry: &ActivityEntry) -> Result<()> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    tx.execute(
        "INSERT INTO agent_activity
         (id, session_id, client_name, tool, summary, note_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            entry.id,
            entry.session_id,
            entry.client_name,
            entry.tool,
            entry.summary,
            entry.note_id,
            entry.created_at
        ],
    )?;
    tx.execute(
        "DELETE FROM agent_activity WHERE id IN (
             SELECT id FROM agent_activity
             ORDER BY created_at DESC, id DESC
             LIMIT -1 OFFSET ?1
         )",
        [KEEP],
    )?;
    tx.commit()?;
    Ok(())
}
