//! The MCP session seam and stdio agent presence (#390 req 1, 3, 4, 5, 6).
//!
//! `impl ServerHandler for Memex` reports every request it answers to an
//! optional [`AgentSessions`] seam, attached with [`Memex::with_sessions`].
//! [`StdioSessions`] is the stdio implementation: it keeps the session's
//! presence record under `<vault>/.memex/agents/`. Presence lives in files
//! only; nothing here touches `memex.db`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use memex_core::agents::presence::{self, PresenceRecord, Transport};
use rmcp::model::ClientInfo;
use rmcp::service::RequestContext;
use rmcp::RoleServer;
use tokio::time::{Instant, MissedTickBehavior};

use crate::server::request_clock::SharedClock;
use crate::tools::Memex;

/// What kind of MCP request the seam is told about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestKind {
    /// A `tools/call` request.
    ToolCall,
    /// Any other request the server answers (`initialize`, `ping`,
    /// `tools/list`, `prompts/list`, `prompts/get`, …).
    Other,
}

/// The identity a request runs under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSession {
    pub session_id: String,
    pub client_name: String,
    pub transport: Transport,
}

/// The per-request session seam.
pub trait AgentSessions: Send + Sync {
    /// Called once per MCP request, before the request runs. Updates the
    /// session's last_request_at (and last_tool_at for ToolCall). Returns the
    /// identity L3 logs under, or None when this request has none.
    fn on_request(
        &self,
        ctx: &RequestContext<RoleServer>,
        kind: RequestKind,
    ) -> Option<AgentSession>;
}

impl Memex {
    /// This server with `sessions` told about every request it answers.
    pub fn with_sessions(mut self, sessions: Arc<dyn AgentSessions>) -> Self {
        self.sessions = Some(sessions);
        self
    }
}

/// The client identity and start time, set when initialize completes.
struct Started {
    client_name: String,
    client_version: Option<String>,
    started_at: i64,
}

/// What the next presence record is built from.
#[derive(Default)]
struct Live {
    started: Option<Started>,
    last_request_at: i64,
    last_tool_at: Option<i64>,
}

/// Stdio agent presence for one `memex serve --vault` session: one ULID
/// `session_id`, one record at `<vault>/.memex/agents/<session_id>.json`.
/// Requests update it in memory; [`begin`](Self::begin) and each
/// [`heartbeat`](Self::heartbeat) write it. A failed write or delete is
/// logged at WARN and never ends the session.
pub struct StdioSessions {
    dir: PathBuf,
    session_id: String,
    clock: SharedClock,
    embeddings: bool,
    live: Mutex<Live>,
}

impl StdioSessions {
    /// A new session for the vault at `vault_root`, stamped by `clock`.
    /// `embeddings` is recorded as whether this process serves with
    /// embeddings. Writes nothing.
    pub fn new(vault_root: &Path, clock: SharedClock, embeddings: bool) -> Self {
        Self {
            dir: presence::presence_dir(vault_root),
            session_id: ulid::Ulid::new().to_string(),
            clock,
            embeddings,
            live: Mutex::new(Live::default()),
        }
    }

    /// This session's id, the record's file stem.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    fn live(&self) -> MutexGuard<'_, Live> {
        // A panic while holding the lock leaves plain timestamps behind,
        // still fine to read.
        self.live.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Deletes the expired records other sessions left behind (req 6).
    pub fn sweep(&self) {
        if let Err(e) = presence::sweep(&self.dir, self.clock.now_ms()) {
            tracing::warn!(error = %e, "agent presence sweep failed");
        }
    }

    /// Initialize completed for `info`: records the client identity, sets
    /// started_at, last_seen_at and last_request_at to now and writes the
    /// record.
    pub fn begin(&self, info: &ClientInfo) {
        let now = self.clock.now_ms();
        {
            let mut live = self.live();
            live.started = Some(Started {
                client_name: presence::truncate_identity(&info.client_info.name),
                client_version: Some(presence::truncate_identity(&info.client_info.version)),
                started_at: now,
            });
            live.last_request_at = now;
        }
        self.write_at(now);
    }

    /// Rewrites the record with last_seen_at = now and a new expires_at.
    pub fn heartbeat(&self) {
        self.write_at(self.clock.now_ms());
    }

    /// Calls [`heartbeat`](Self::heartbeat) every `every`, first one
    /// interval from now, until the task is aborted.
    pub async fn run_heartbeat(self: Arc<Self>, every: Duration) {
        let mut ticks = tokio::time::interval_at(Instant::now() + every, every);
        ticks.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            ticks.tick().await;
            self.heartbeat();
        }
    }

    /// Deletes this session's record.
    pub fn end(&self) {
        if let Err(e) = presence::remove(&self.dir, &self.session_id) {
            tracing::warn!(error = %e, session_id = %self.session_id, "agent presence delete failed");
        }
    }

    /// The record as of `now`, once initialize has completed.
    fn record_at(&self, now: i64) -> Option<PresenceRecord> {
        let live = self.live();
        let started = live.started.as_ref()?;
        let last_request_at = live.last_request_at;
        Some(PresenceRecord {
            session_id: self.session_id.clone(),
            client_name: started.client_name.clone(),
            client_version: started.client_version.clone(),
            transport: Transport::Stdio,
            started_at: started.started_at,
            last_seen_at: now,
            last_request_at,
            last_tool_at: live.last_tool_at,
            expires_at: presence::expires_at(Transport::Stdio, now, last_request_at),
            embeddings: self.embeddings,
        })
    }

    fn write_at(&self, now: i64) {
        let Some(record) = self.record_at(now) else {
            return;
        };
        if let Err(e) = presence::write(&self.dir, &record) {
            tracing::warn!(error = %e, session_id = %self.session_id, "agent presence write failed");
        }
    }
}

impl AgentSessions for StdioSessions {
    fn on_request(
        &self,
        ctx: &RequestContext<RoleServer>,
        kind: RequestKind,
    ) -> Option<AgentSession> {
        {
            let mut live = self.live();
            // Read the clock under the lock, so concurrent requests can't
            // move last_request_at backward.
            let now = self.clock.now_ms();
            live.last_request_at = now;
            if kind == RequestKind::ToolCall {
                live.last_tool_at = Some(now);
            }
        }
        let info = ctx.peer.peer_info()?;
        Some(AgentSession {
            session_id: self.session_id.clone(),
            client_name: presence::truncate_identity(&info.client_info.name),
            transport: Transport::Stdio,
        })
    }
}
