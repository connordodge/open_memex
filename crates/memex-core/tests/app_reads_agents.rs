//! WI #448 (P5), ACs 1-3: the shared agents read of the app API
//! (`app_reads::agents`), on temp vaults (Spec #390 req 14, 16; TD "One
//! source for both transports").
//!
//! - `agents`: every parsed presence record in `<vault>/.memex/agents/`,
//!   expired or not, by `last_request_at` descending; malformed files and
//!   `*.json.tmp` are skipped.
//! - `recent`: the newest 20 `agent_activity` rows, `created_at DESC, id
//!   DESC`; a schema without the table gives an empty `recent`, no error.
//!
//! API under test:
//!   memex_core::app_reads::agents::activity(&Vault) -> Result<AgentActivity>
//!   AgentActivity { agents: Vec<PresenceRecord>, recent: Vec<ActivityEntry> }

use std::fs;
use std::path::PathBuf;

use memex_core::agents::activity::ActivityEntry;
use memex_core::agents::presence::{presence_dir, write, PresenceRecord, Transport};
use memex_core::app_reads::agents::{activity, AgentActivity};
use memex_core::{now_unix_ms, Vault};
use rusqlite::params;

/// A fixed instant the records are laid out around (2025-11-11T10:00:00Z).
const T0: i64 = 1_762_855_200_000;

fn fresh() -> (tempfile::TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

fn agents_dir(vault: &Vault) -> PathBuf {
    presence_dir(vault.root())
}

/// A record whose timestamps are offsets from `T0`; `expires_at` is given
/// explicitly so expired and live records sit side by side. `last_seen_at`
/// runs opposite to `last_request_at` (`T0 - offset`): sorting by the
/// heartbeat instead of the last request reverses the order.
#[allow(clippy::too_many_arguments)]
fn record(
    session_id: &str,
    client_name: &str,
    client_version: Option<&str>,
    transport: Transport,
    last_request_offset: i64,
    last_tool_offset: Option<i64>,
    expires_at: i64,
    embeddings: bool,
) -> PresenceRecord {
    PresenceRecord {
        session_id: session_id.to_string(),
        client_name: client_name.to_string(),
        client_version: client_version.map(str::to_string),
        transport,
        started_at: T0 - 3_600_000,
        last_seen_at: T0 - last_request_offset,
        last_request_at: T0 + last_request_offset,
        last_tool_at: last_tool_offset.map(|o| T0 + o),
        expires_at,
        embeddings,
    }
}

/// One `agent_activity` row, written with plain SQL.
fn insert_activity(vault: &Vault, entry: &ActivityEntry) {
    vault
        .connection_ref()
        .execute(
            "INSERT INTO agent_activity (id, session_id, client_name, tool, summary, note_id, created_at)
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
        )
        .unwrap_or_else(|e| panic!("insert activity {}: {e}", entry.id));
}

fn entry(id: &str, created_at: i64) -> ActivityEntry {
    let n: usize = id.trim_start_matches('r').parse().unwrap();
    ActivityEntry {
        id: id.to_string(),
        session_id: format!("session-{}", n % 3),
        client_name: format!("client-{}", n % 2),
        tool: ["add_excerpt", "tag_note"][n % 2].to_string(),
        summary: format!("summary of {id}"),
        note_id: (!n.is_multiple_of(3)).then(|| format!("note-{n}")),
        created_at,
    }
}

fn ids(read: &AgentActivity) -> Vec<&str> {
    read.recent.iter().map(|e| e.id.as_str()).collect()
}

fn sessions(read: &AgentActivity) -> Vec<&str> {
    read.agents.iter().map(|r| r.session_id.as_str()).collect()
}

// ---------------------------------------------------------------------------
// AC 1: agents
// ---------------------------------------------------------------------------

#[test]
fn agents_lists_every_record_expired_included_by_last_request_desc_skipping_malformed() {
    let (_dir, vault) = fresh();
    let dir = agents_dir(&vault);
    let now = now_unix_ms();
    // Neither file-name order nor its reverse is the expected order.
    let a = record(
        "01JCAGENTA0000000000000001",
        "Claude Desktop",
        Some("0.14.2"),
        Transport::Stdio,
        -2_000,
        Some(-2_000),
        now + 3_600_000,
        false,
    );
    let b = record(
        "01JCAGENTB0000000000000002",
        "claude-code",
        None,
        Transport::Http,
        -500,
        None,
        now + 3_600_000,
        true,
    );
    // Expired long ago against any clock: the reader still lists it.
    let c = record(
        "01JCAGENTC0000000000000003",
        "memex-bridge",
        Some("1.0.0"),
        Transport::Bridge,
        -90_000,
        Some(-95_000),
        T0 - 75_000,
        true,
    );
    // Expired, and the newest request of all: it sorts first.
    let d = record(
        "01JCAGENTD0000000000000004",
        "zed",
        Some("0.200.1"),
        Transport::Http,
        -100,
        Some(-100),
        1,
        false,
    );
    for r in [&c, &a, &d, &b] {
        write(&dir, r).unwrap();
    }
    fs::write(dir.join("01JCMALFORMED0000000000005.json"), b"{not json").unwrap();
    fs::write(
        dir.join("01JCHALFWAY00000000000006.json"),
        br#"{"session_id":"01JCHALFWAY00000000000006","client_name":"x"}"#,
    )
    .unwrap();
    let mut tmp = serde_json::to_vec(&a).unwrap();
    tmp.extend_from_slice(b" ");
    fs::write(dir.join("01JCTEMP000000000000000007.json.tmp"), &tmp).unwrap();

    let read = activity(&vault).expect("the agents read succeeds");
    assert_eq!(
        sessions(&read),
        [
            "01JCAGENTD0000000000000004",
            "01JCAGENTB0000000000000002",
            "01JCAGENTA0000000000000001",
            "01JCAGENTC0000000000000003",
        ],
        "every parsed record, expired included, by last_request_at descending"
    );
    assert_eq!(read.agents, vec![d, b, a, c], "records come back unchanged");
}

#[test]
fn agents_is_empty_without_a_presence_dir_while_recent_still_reads() {
    let (_dir, vault) = fresh();
    assert!(!agents_dir(&vault).exists());
    let e = entry("r01", T0);
    insert_activity(&vault, &e);
    let read = activity(&vault).expect("no presence dir is not an error");
    assert!(read.agents.is_empty(), "{:?}", read.agents);
    assert_eq!(read.recent, vec![e]);
}

// ---------------------------------------------------------------------------
// AC 2: recent
// ---------------------------------------------------------------------------

/// `(id, created_at offset)`, in insertion (rowid) order. Within the tie
/// groups the rowid order is ascending by id for some and descending for
/// others, so neither rowid order matches `id DESC`. The `T0 + 10` pair
/// straddles the 20th place.
const ROWS: &[(&str, i64)] = &[
    ("r24", 25),
    ("r10", 25),
    ("r03", 24),
    ("r05", 23),
    ("r21", 23),
    ("r17", 23),
    ("r12", 22),
    ("r01", 21),
    ("r19", 20),
    ("r08", 19),
    ("r15", 19),
    ("r22", 18),
    ("r02", 17),
    ("r13", 16),
    ("r07", 15),
    ("r25", 14),
    ("r11", 13),
    ("r09", 12),
    ("r16", 11),
    ("r06", 10),
    ("r23", 10),
    ("r14", 9),
    ("r18", 8),
    ("r20", 1),
    ("r04", 1),
];

#[test]
fn recent_is_the_newest_20_rows_newest_first_ties_by_id_desc() {
    let (_dir, vault) = fresh();
    for (id, offset) in ROWS {
        insert_activity(&vault, &entry(id, T0 + offset * 1_000));
    }
    let read = activity(&vault).expect("the agents read succeeds");
    assert_eq!(
        ids(&read),
        [
            "r24", "r10", "r03", "r21", "r17", "r05", "r12", "r01", "r19", "r15", "r08", "r22",
            "r02", "r13", "r07", "r25", "r11", "r09", "r16", "r23",
        ],
        "25 rows: the newest 20, created_at DESC then id DESC"
    );
}

#[test]
fn recent_maps_every_column_into_the_entry() {
    let (_dir, vault) = fresh();
    let with_note = ActivityEntry {
        id: "01JCACT0000000000000000001".to_string(),
        session_id: "01JCSTD1000000000000000001".to_string(),
        client_name: "Claude Desktop".to_string(),
        tool: "add_excerpt".to_string(),
        summary: "filed 4 blocks → Rest & Recharge".to_string(),
        note_id: Some("01M5DQAYZ3WP7H0NXZZV9M2315".to_string()),
        created_at: T0 + 7,
    };
    let without_note = ActivityEntry {
        id: "01JCACT0000000000000000002".to_string(),
        session_id: "01JCHTTP000000000000000002".to_string(),
        client_name: "claude-code".to_string(),
        tool: "mark_day_reviewed".to_string(),
        summary: "marked 2026-11-09 reviewed".to_string(),
        note_id: None,
        created_at: T0 - 3,
    };
    insert_activity(&vault, &without_note);
    insert_activity(&vault, &with_note);
    let read = activity(&vault).expect("the agents read succeeds");
    assert_eq!(read.recent, vec![with_note, without_note]);
}

#[test]
fn recent_is_every_row_when_there_are_fewer_than_20() {
    let (_dir, vault) = fresh();
    for (id, offset) in &ROWS[..3] {
        insert_activity(&vault, &entry(id, T0 + offset * 1_000));
    }
    let read = activity(&vault).expect("the agents read succeeds");
    assert_eq!(ids(&read), ["r24", "r10", "r03"]);
}

// ---------------------------------------------------------------------------
// AC 3: no agent_activity table
// ---------------------------------------------------------------------------

#[test]
fn recent_is_empty_without_an_agent_activity_table_and_agents_still_read() {
    let (dir, vault) = fresh();
    vault
        .connection_ref()
        .execute_batch("DROP TABLE agent_activity;")
        .unwrap();
    drop(vault);
    // Reopened, the vault keeps its schema: the table stays gone.
    let vault = Vault::open(dir.path().join("vault")).unwrap();
    let missing: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'agent_activity'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(missing, 0, "the fixture vault has no agent_activity table");
    let live = record(
        "01JCAGENTA0000000000000001",
        "Claude Desktop",
        Some("0.14.2"),
        Transport::Stdio,
        -2_000,
        None,
        T0 + 13_000,
        false,
    );
    write(&agents_dir(&vault), &live).unwrap();

    let read = activity(&vault).expect("a schema without agent_activity is not an error");
    assert!(read.recent.is_empty(), "{:?}", read.recent);
    assert_eq!(read.agents, vec![live], "the presence records still read");
}
