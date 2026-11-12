//! Agent presence for MCP clients of the vault server (#390 req 2-6).
//!
//! Each served vault gets one [`HttpSessions`], built with its MCP service
//! (`mcp::service_for`), so its client map lives as long as that vault stays
//! open and a reopened vault (or a restarted server) starts empty.
//!
//! - **Identity.** A request whose `X-Memex-Agent-Session` is a valid ULID
//!   is a `bridge` client keyed on that id, named by `X-Memex-Agent-Client`
//!   (split at the last `/`) or else by the User-Agent. Any other request is
//!   an `http` client keyed on `sha256(User-Agent, peer IP)`, which maps to a
//!   ULID `session_id` made on first sight, named by the User-Agent's first
//!   product token (`http client` without one). Both identity values are cut
//!   to 64 chars. A session header that is not a ULID names no file.
//! - **Writes.** Every request updates the client in memory. Its record
//!   file is written at most once per window (5 s): at once when the last
//!   write is a full window old, otherwise by one trailing write at the
//!   window's end carrying the newest state. A failed write is logged and
//!   never fails the request.
//! - **Sweeps.** Expired records are deleted when a vault is first served
//!   ([`HttpSessions::sweep`]) and every hour for every served vault
//!   ([`spawn_presence_sweeps`]).
//!
//! All times come from the server's [`SharedClock`]; waits use tokio timers.
//! Presence lives in files only; nothing here touches `memex.db`.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use axum::extract::ConnectInfo;
use axum::http::request::Parts;
use axum::http::HeaderMap;
use memex_core::agents::presence::{self, PresenceRecord, Transport};
use rmcp::service::RequestContext;
use rmcp::RoleServer;
use sha2::{Digest, Sha256};
use tokio::task::JoinHandle;
use tokio::time::{Instant, MissedTickBehavior};
use ulid::Ulid;

use super::registry::Registry;
use super::request_clock::SharedClock;
use crate::presence::{AgentSession, AgentSessions, RequestKind};

/// The bridge's session header: a ULID the bridge made for its session.
pub const SESSION_HEADER: &str = "x-memex-agent-session";
/// The bridge's client header: `<name>/<version>`.
pub const CLIENT_HEADER: &str = "x-memex-agent-client";
/// The shortest gap between two writes of one client's record.
pub const WRITE_WINDOW: Duration = Duration::from_secs(5);
/// How often [`run`](super::run) sweeps every served vault's records.
pub const SWEEP_EVERY: Duration = Duration::from_secs(60 * 60);
/// The name of an `http` client that sent no usable User-Agent.
const UNNAMED_CLIENT: &str = "http client";

/// What a client's in-memory record is keyed on.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum ClientKey {
    /// The bridge's session ULID.
    Bridge(Ulid),
    /// `sha256(User-Agent, peer IP)`.
    Http([u8; 32]),
}

/// Who sent a request, as read from its headers and peer address.
struct Identity {
    key: ClientKey,
    client_name: String,
    client_version: Option<String>,
}

/// One client's newest state, and when its record was last written.
struct Client {
    session_id: String,
    transport: Transport,
    client_name: String,
    client_version: Option<String>,
    started_at: i64,
    last_request_at: i64,
    last_tool_at: Option<i64>,
    /// When the record was last written (or a write last tried).
    written_at: Option<i64>,
    /// A trailing write is scheduled.
    trailing: bool,
}

impl Client {
    /// The record of this client's newest state. `last_seen_at` is the
    /// newest request's time.
    fn record(&self, embeddings: bool) -> PresenceRecord {
        let last_seen_at = self.last_request_at;
        PresenceRecord {
            session_id: self.session_id.clone(),
            client_name: self.client_name.clone(),
            client_version: self.client_version.clone(),
            transport: self.transport,
            started_at: self.started_at,
            last_seen_at,
            last_request_at: self.last_request_at,
            last_tool_at: self.last_tool_at,
            expires_at: presence::expires_at(self.transport, last_seen_at, self.last_request_at),
            embeddings,
        }
    }
}

type SharedClient = Arc<Mutex<Client>>;

/// Locks `m`; a panic while it was held leaves plain values behind, still
/// fine to read.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What a write needs; shared with the trailing-write tasks.
struct Writer {
    dir: PathBuf,
    clock: SharedClock,
    embeddings: bool,
}

impl Writer {
    /// Writes `client`'s record as of `now`. A failure is logged.
    fn write(&self, client: &mut Client, now: i64) {
        client.written_at = Some(now);
        if let Err(e) = presence::write(&self.dir, &client.record(self.embeddings)) {
            tracing::warn!(
                error = %e,
                session_id = %client.session_id,
                "agent presence write failed"
            );
        }
    }
}

/// Agent presence for the MCP clients of one served vault: an in-memory
/// record per client, written to `<vault>/.memex/agents/<session_id>.json`
/// at most once per write window.
pub struct HttpSessions {
    writer: Arc<Writer>,
    window_ms: i64,
    clients: Mutex<HashMap<ClientKey, SharedClient>>,
}

impl HttpSessions {
    /// Presence for the vault at `vault_root`, stamped by `clock`, writing
    /// each client's record at most once per `window`. `embeddings` is
    /// recorded as whether the server serves this vault with an embedder.
    /// Writes nothing.
    pub fn new(vault_root: &Path, clock: SharedClock, embeddings: bool, window: Duration) -> Self {
        Self {
            writer: Arc::new(Writer {
                dir: presence::presence_dir(vault_root),
                clock,
                embeddings,
            }),
            window_ms: i64::try_from(window.as_millis()).unwrap_or(i64::MAX),
            clients: Mutex::new(HashMap::new()),
        }
    }

    /// Deletes the vault's records that have expired by now. A failure is
    /// logged.
    pub fn sweep(&self) {
        if let Err(e) = presence::sweep(&self.writer.dir, self.writer.clock.now_ms()) {
            tracing::warn!(error = %e, "agent presence sweep failed");
        }
    }

    /// The client `identity` names, made on first sight at `now`.
    fn client(&self, identity: &Identity, now: i64) -> SharedClient {
        let mut clients = lock(&self.clients);
        clients
            .entry(identity.key.clone())
            .or_insert_with(|| {
                let (session_id, transport) = match &identity.key {
                    ClientKey::Bridge(id) => (id.to_string(), Transport::Bridge),
                    ClientKey::Http(_) => (Ulid::new().to_string(), Transport::Http),
                };
                Arc::new(Mutex::new(Client {
                    session_id,
                    transport,
                    client_name: identity.client_name.clone(),
                    client_version: identity.client_version.clone(),
                    started_at: now,
                    last_request_at: now,
                    last_tool_at: None,
                    written_at: None,
                    trailing: false,
                }))
            })
            .clone()
    }

    /// Writes `client`'s record now if its last write is a full window old,
    /// or is in the future because the clock stepped back; otherwise makes
    /// sure one trailing write is scheduled for the window's end, so the
    /// wait is never longer than one window.
    fn write_or_schedule(&self, shared: &SharedClient, client: &mut Client, now: i64) {
        if client.trailing {
            return;
        }
        let due = match client.written_at {
            Some(at) if at <= now => at.saturating_add(self.window_ms),
            _ => now,
        };
        if now >= due {
            self.writer.write(client, now);
            return;
        }
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            self.writer.write(client, now);
            return;
        };
        client.trailing = true;
        let wait = Duration::from_millis(u64::try_from(due - now).unwrap_or(0));
        let writer = self.writer.clone();
        let shared = shared.clone();
        runtime.spawn(async move {
            tokio::time::sleep(wait).await;
            let mut client = lock(&shared);
            client.trailing = false;
            let now = writer.clock.now_ms();
            writer.write(&mut client, now);
        });
    }
}

impl AgentSessions for HttpSessions {
    fn on_request(
        &self,
        ctx: &RequestContext<RoleServer>,
        kind: RequestKind,
    ) -> Option<AgentSession> {
        let now = self.writer.clock.now_ms();
        let identity = identify(ctx.extensions.get::<Parts>());
        let shared = self.client(&identity, now);
        let mut client = lock(&shared);
        if client.transport == Transport::Bridge {
            client.client_name = identity.client_name;
            client.client_version = identity.client_version;
        }
        client.last_request_at = now;
        if kind == RequestKind::ToolCall {
            client.last_tool_at = Some(now);
        }
        let session = AgentSession {
            session_id: client.session_id.clone(),
            client_name: client.client_name.clone(),
            transport: client.transport,
        };
        self.write_or_schedule(&shared, &mut client, now);
        Some(session)
    }
}

/// The identity of the request `parts` belong to (none: a nameless `http`
/// client with no peer address).
fn identify(parts: Option<&Parts>) -> Identity {
    let headers = parts.map(|p| &p.headers);
    let user_agent = headers.and_then(|h| h.get(axum::http::header::USER_AGENT));
    let (ua_name, ua_version) =
        user_agent_identity(user_agent.and_then(|v| std::str::from_utf8(v.as_bytes()).ok()));
    let (key, name, version) = match headers.and_then(bridge_session) {
        Some(id) => {
            let (name, version) = headers
                .and_then(client_header_identity)
                .unwrap_or((ua_name, ua_version));
            (ClientKey::Bridge(id), name, version)
        }
        None => {
            let peer_ip = parts
                .and_then(|p| p.extensions.get::<ConnectInfo<SocketAddr>>())
                .map(|ConnectInfo(addr)| addr.ip().to_canonical().to_string())
                .unwrap_or_default();
            let ua_bytes = user_agent.map(|v| v.as_bytes()).unwrap_or_default();
            (
                ClientKey::Http(http_key(ua_bytes, &peer_ip)),
                ua_name,
                ua_version,
            )
        }
    };
    Identity {
        key,
        client_name: presence::truncate_identity(&name),
        client_version: version.map(|v| presence::truncate_identity(&v)),
    }
}

/// The bridge session in `headers`: `X-Memex-Agent-Session` when it is a
/// canonical ULID string in either case, else none.
fn bridge_session(headers: &HeaderMap) -> Option<Ulid> {
    let raw = headers.get(SESSION_HEADER)?.to_str().ok()?;
    let id = Ulid::from_string(raw).ok()?;
    // `from_string` also takes 26-char strings past the ULID range and
    // decodes them to another id: only a value that round-trips is one.
    id.to_string().eq_ignore_ascii_case(raw).then_some(id)
}

/// `X-Memex-Agent-Client` split at its last `/` into name and version;
/// without a `/` the whole value is the name. None when the header is
/// absent, not UTF-8, or names no client.
fn client_header_identity(headers: &HeaderMap) -> Option<(String, Option<String>)> {
    let raw = std::str::from_utf8(headers.get(CLIENT_HEADER)?.as_bytes()).ok()?;
    let value = raw.trim();
    let (name, version) = match value.rsplit_once('/') {
        Some((name, version)) => (name, Some(version)),
        None => (value, None),
    };
    if name.is_empty() {
        return None;
    }
    Some((name.to_string(), non_empty(version)))
}

/// The name and version of `user_agent`'s first product token
/// (`claude-code/1.2.3 (darwin)` is `claude-code`, `1.2.3`), or
/// `http client` and none without one.
fn user_agent_identity(user_agent: Option<&str>) -> (String, Option<String>) {
    let token = user_agent.and_then(|ua| ua.split_whitespace().next());
    let (name, version) = match token.map(|t| t.split_once('/').unwrap_or((t, ""))) {
        Some((name, version)) if !name.is_empty() => (name, Some(version)),
        _ => return (UNNAMED_CLIENT.to_string(), None),
    };
    (name.to_string(), non_empty(version))
}

fn non_empty(s: Option<&str>) -> Option<String> {
    s.filter(|s| !s.is_empty()).map(str::to_string)
}

/// `sha256(User-Agent, peer IP)`, the User-Agent length-prefixed so no two
/// pairs hash the same bytes.
fn http_key(user_agent: &[u8], peer_ip: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update((user_agent.len() as u64).to_be_bytes());
    hasher.update(user_agent);
    hasher.update(peer_ip.as_bytes());
    hasher.finalize().into()
}

/// Starts the presence sweep of every vault `registry` serves: once every
/// `every`, first one `every` from now, deleting the records that have
/// expired by `clock`. The task ends when the returned handle is aborted or
/// the runtime is dropped.
pub fn spawn_presence_sweeps(
    registry: Arc<Registry>,
    clock: SharedClock,
    every: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticks = tokio::time::interval_at(Instant::now() + every, every);
        ticks.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            ticks.tick().await;
            sweep_served(&registry, &clock).await;
        }
    })
}

/// Sweeps the presence records of every vault `registry` serves.
async fn sweep_served(registry: &Registry, clock: &SharedClock) {
    let vaults = match registry.list().await {
        Ok(vaults) => vaults,
        Err(e) => {
            tracing::warn!(error = ?e, "agent presence sweep: could not list the served vaults");
            return;
        }
    };
    let root = registry.root().to_path_buf();
    let now = clock.now_ms();
    let swept = tokio::task::spawn_blocking(move || {
        for listed in vaults {
            let dir = presence::presence_dir(&root.join(&listed.name));
            if let Err(e) = presence::sweep(&dir, now) {
                tracing::warn!(error = %e, vault = %listed.name, "agent presence sweep failed");
            }
        }
    })
    .await;
    if let Err(e) = swept {
        tracing::warn!(error = %e, "agent presence sweep: the sweep task failed");
    }
}

#[cfg(test)]
mod tests {
    //! `write_or_schedule` called directly, with no await between the call
    //! and the check: a write that a spawned task would do is not on disk
    //! yet, so these pin the boundary where `now == due` writes at once.

    use std::sync::atomic::{AtomicI64, Ordering};

    use memex_core::Clock;

    use super::*;

    const T0: i64 = 1_700_000_000_000;
    const WINDOW_MS: i64 = 5_000;

    struct FakeClock(AtomicI64);

    impl Clock for FakeClock {
        fn now_ms(&self) -> i64 {
            self.0.load(Ordering::SeqCst)
        }
    }

    fn sessions(dir: &Path) -> HttpSessions {
        let clock: SharedClock = Arc::new(FakeClock(AtomicI64::new(T0)));
        HttpSessions::new(dir, clock, false, WRITE_WINDOW)
    }

    fn identity() -> Identity {
        Identity {
            key: ClientKey::Http([7; 32]),
            client_name: "test-client".to_string(),
            client_version: None,
        }
    }

    fn record_files(sessions: &HttpSessions) -> usize {
        std::fs::read_dir(&sessions.writer.dir)
            .map(|d| d.count())
            .unwrap_or(0)
    }

    #[tokio::test(start_paused = true)]
    async fn first_request_writes_synchronously_without_a_trailing_task() {
        let vault = tempfile::tempdir().unwrap();
        let sessions = sessions(vault.path());
        let shared = sessions.client(&identity(), T0);
        let mut client = lock(&shared);

        sessions.write_or_schedule(&shared, &mut client, T0);

        // No await since the call: only a synchronous write is on disk.
        assert_eq!(record_files(&sessions), 1, "record written before return");
        assert_eq!(client.written_at, Some(T0));
        assert!(!client.trailing, "no trailing write was scheduled");
    }

    #[tokio::test(start_paused = true)]
    async fn request_exactly_one_window_after_the_last_write_writes_synchronously() {
        let vault = tempfile::tempdir().unwrap();
        let sessions = sessions(vault.path());
        let shared = sessions.client(&identity(), T0);
        let mut client = lock(&shared);
        sessions.write_or_schedule(&shared, &mut client, T0);
        assert_eq!(client.written_at, Some(T0));

        let now = T0 + WINDOW_MS;
        client.last_request_at = now;
        sessions.write_or_schedule(&shared, &mut client, now);

        assert_eq!(client.written_at, Some(now), "written at the boundary");
        assert!(!client.trailing, "no trailing write was scheduled");
        let file = sessions
            .writer
            .dir
            .join(format!("{}.json", client.session_id));
        let on_disk = std::fs::read_to_string(file).unwrap();
        assert!(
            on_disk.contains(&format!("\"last_request_at\": {now}"))
                || on_disk.contains(&format!("\"last_request_at\":{now}")),
            "the file carries the boundary request: {on_disk}"
        );
    }
}
