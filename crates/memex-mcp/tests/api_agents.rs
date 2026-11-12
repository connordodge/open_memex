//! WI #448 (P5), ACs 4-6: `GET /vaults/{name}/api/v1/agents` on the full
//! `memex_mcp::server::router()` (Spec #390 req 14, 16; rulings D20, D22).
//!
//! | Route | Response |
//! |---|---|
//! | `GET /agents` | `{"agents":[presence record…],"recent":[activity entry…],"available":true,"server_now":<ms>}` |
//!
//! `agents` is every presence record of the vault, expired included, by
//! `last_request_at` descending; `recent` is the newest 20 `agent_activity`
//! rows, `created_at DESC, id DESC`. `server_now` is the server's base clock
//! (`ServerConfig::with_clock`), read per request. The route needs the access
//! token like every `/api/v1` route.
//!
//! The rows of `app/test/fixtures/api_v1/agents/index.json` hold the hosted
//! `AgentsAccess` (#454) contract: never rebless them to fit the server.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use memex_core::agents::presence::{presence_dir, write, PresenceRecord, Transport};
use memex_core::{Clock, Vault};
use memex_mcp::server::{router, ServerConfig};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{
    api_v1_dir, bless_requested, materialize_seed, run_rows, FixtureRequest, FixtureResponse,
    SEED_VAULT_NAME,
};
use server::{assert_wrong_method_is_c1_405_at, get, raw_request, Reply, TEST_TOKEN};

/// The server clock's instant in every fixture row (2025-11-11T10:00:00Z).
const NOW: i64 = 1_762_855_200_000;

/// The vault with no presence records and no activity rows.
const EMPTY_VAULT: &str = "empty";

/// A seed note id (`role: topic`, "Player loop").
const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";

/// The live stdio agent: newest request.
const STDIO_SESSION: &str = "01JCSTD1000000000000000001";
/// The expired plain-HTTP agent: older request.
const HTTP_SESSION: &str = "01JCHTTP000000000000000002";

const ACT_1: &str = "01JCACT0000000000000000001";
const ACT_2: &str = "01JCACT0000000000000000002";
const ACT_3: &str = "01JCACT0000000000000000003";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A server clock tests can move.
struct StepClock(AtomicI64);

impl Clock for StepClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// The full router over a vault root holding the seed vault (two presence
/// records, three activity rows) and [`EMPTY_VAULT`], with a [`StepClock`]
/// at [`NOW`] as its base clock.
struct Srv {
    root: TempDir,
    addr: SocketAddr,
    clock: Arc<StepClock>,
    task: JoinHandle<()>,
}

impl Drop for Srv {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The live stdio record, written second.
fn stdio_record() -> PresenceRecord {
    PresenceRecord {
        session_id: STDIO_SESSION.to_string(),
        client_name: "Claude Desktop".to_string(),
        client_version: Some("0.14.2".to_string()),
        transport: Transport::Stdio,
        started_at: NOW - 600_000,
        last_seen_at: NOW - 2_000,
        last_request_at: NOW - 3_000,
        last_tool_at: Some(NOW - 3_000),
        expires_at: NOW + 13_000,
        embeddings: false,
    }
}

/// The plain-HTTP record, expired a minute before [`NOW`], written first.
fn http_record() -> PresenceRecord {
    PresenceRecord {
        session_id: HTTP_SESSION.to_string(),
        client_name: "claude-code".to_string(),
        client_version: None,
        transport: Transport::Http,
        started_at: NOW - 7_200_000,
        last_seen_at: NOW - 120_000,
        last_request_at: NOW - 120_000,
        last_tool_at: None,
        expires_at: NOW - 60_000,
        embeddings: true,
    }
}

/// `(id, session_id, client_name, tool, summary, note_id, created_at)`.
type ActivityRow = (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    Option<&'static str>,
    i64,
);

/// `agent_activity` rows of the seed vault, in insertion order: ACT_2 and
/// ACT_3 share `created_at`, so `id DESC` puts ACT_3 first.
fn seed_activity(vault: &Path) {
    let conn = Connection::open(vault.join("memex.db")).expect("open the seed memex.db");
    let rows: [ActivityRow; 3] = [
        (
            ACT_2,
            STDIO_SESSION,
            "Claude Desktop",
            "mark_day_reviewed",
            "marked 2026-11-09 reviewed",
            None,
            NOW - 10_000,
        ),
        (
            ACT_1,
            STDIO_SESSION,
            "Claude Desktop",
            "add_excerpt",
            "filed 4 blocks → Rest & Recharge",
            Some(PLAYER_LOOP),
            NOW - 3_000,
        ),
        (
            ACT_3,
            HTTP_SESSION,
            "claude-code",
            "tag_note",
            "tagged Player loop #core",
            Some(PLAYER_LOOP),
            NOW - 10_000,
        ),
    ];
    for (id, session, client, tool, summary, note, at) in rows {
        conn.execute(
            "INSERT INTO agent_activity (id, session_id, client_name, tool, summary, note_id, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![id, session, client, tool, summary, note, at],
        )
        .unwrap_or_else(|e| panic!("insert activity {id}: {e}"));
    }
}

impl Srv {
    async fn start() -> Self {
        let root = tempfile::tempdir().unwrap();
        let seed = materialize_seed(root.path());
        seed_activity(&std::path::absolute(&seed).unwrap());
        let empty = std::path::absolute(root.path().join(EMPTY_VAULT)).unwrap();
        drop(Vault::create(&empty).expect("create the empty vault"));

        let clock = Arc::new(StepClock(AtomicI64::new(NOW)));
        let config =
            ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN).with_clock(clock.clone());
        let app = router(config);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let srv = Self {
            root,
            addr,
            clock,
            task,
        };
        // Open both vaults first, so presence written below is never swept
        // by a vault open (req 6); then write the records the reads list.
        for name in [SEED_VAULT_NAME, EMPTY_VAULT] {
            let r = srv.get(&format!("/vaults/{name}/api/v1/info"), true).await;
            assert_eq!(r.status, 200, "open {name}: {}", r.body);
        }
        let dir = presence_dir(&srv.seed_vault());
        write(&dir, &http_record()).unwrap();
        write(&dir, &stdio_record()).unwrap();
        srv
    }

    fn seed_vault(&self) -> PathBuf {
        std::path::absolute(self.root.path().join(SEED_VAULT_NAME)).unwrap()
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    fn bearer() -> String {
        format!("Bearer {TEST_TOKEN}")
    }

    async fn get(&self, path: &str, with_token: bool) -> Reply {
        let bearer = Self::bearer();
        get(&self.url(path), with_token.then_some(bearer.as_str())).await
    }
}

/// The wire form of the seed vault's agents response at [`NOW`], key by key
/// as the WI body names them.
fn seed_wire(server_now: i64) -> Value {
    json!({
        "agents": [
            {
                "session_id": STDIO_SESSION,
                "client_name": "Claude Desktop",
                "client_version": "0.14.2",
                "transport": "stdio",
                "started_at": NOW - 600_000,
                "last_seen_at": NOW - 2_000,
                "last_request_at": NOW - 3_000,
                "last_tool_at": NOW - 3_000,
                "expires_at": NOW + 13_000,
                "embeddings": false
            },
            {
                "session_id": HTTP_SESSION,
                "client_name": "claude-code",
                "client_version": null,
                "transport": "http",
                "started_at": NOW - 7_200_000,
                "last_seen_at": NOW - 120_000,
                "last_request_at": NOW - 120_000,
                "last_tool_at": null,
                "expires_at": NOW - 60_000,
                "embeddings": true
            }
        ],
        "recent": [
            {
                "id": ACT_1,
                "session_id": STDIO_SESSION,
                "client_name": "Claude Desktop",
                "tool": "add_excerpt",
                "summary": "filed 4 blocks → Rest & Recharge",
                "note_id": PLAYER_LOOP,
                "created_at": NOW - 3_000
            },
            {
                "id": ACT_3,
                "session_id": HTTP_SESSION,
                "client_name": "claude-code",
                "tool": "tag_note",
                "summary": "tagged Player loop #core",
                "note_id": PLAYER_LOOP,
                "created_at": NOW - 10_000
            },
            {
                "id": ACT_2,
                "session_id": STDIO_SESSION,
                "client_name": "Claude Desktop",
                "tool": "mark_day_reviewed",
                "summary": "marked 2026-11-09 reviewed",
                "note_id": null,
                "created_at": NOW - 10_000
            }
        ],
        "available": true,
        "server_now": server_now
    })
}

// ---------------------------------------------------------------------------
// AC 4: shape, available, server_now
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_agents_returns_records_recent_available_and_the_server_clock_now() {
    let srv = Srv::start().await;
    let r = srv.get("/vaults/seed/api/v1/agents", true).await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert!(
        r.header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "{:?}",
        r.headers
    );
    // Exactly the WI body's shape: the expired record included, records by
    // last_request_at DESC, entries by created_at DESC then id DESC.
    assert_eq!(r.json(), seed_wire(NOW));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_agents_on_a_vault_with_no_records_or_rows_is_empty_and_available() {
    let srv = Srv::start().await;
    let r = srv.get("/vaults/empty/api/v1/agents", true).await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(
        r.json(),
        json!({"agents": [], "recent": [], "available": true, "server_now": NOW})
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_now_reads_the_server_clock_on_every_request() {
    let srv = Srv::start().await;
    let now_of = |r: &Reply| {
        assert_eq!(r.status, 200, "{}", r.body);
        r.json()["server_now"]
            .as_i64()
            .unwrap_or_else(|| panic!("server_now is an integer: {}", r.body))
    };
    let first = srv.get("/vaults/seed/api/v1/agents", true).await;
    assert_eq!(now_of(&first), NOW);

    let later = NOW + 61_234;
    srv.clock.0.store(later, Ordering::SeqCst);
    let second = srv.get("/vaults/seed/api/v1/agents", true).await;
    assert_eq!(now_of(&second), later, "read again, not cached at start");
    // The rest of the body does not move with the clock.
    assert_eq!(second.json(), seed_wire(later));

    // A caller UTC offset changes date mapping only, never the instant.
    let head = format!(
        "GET /vaults/seed/api/v1/agents HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\
         Authorization: {}\r\nX-Memex-UTC-Offset: +05:30\r\n",
        Srv::bearer()
    );
    let offset = raw_request(srv.addr, &head, b"").await;
    assert_eq!(now_of(&offset), later);
}

// ---------------------------------------------------------------------------
// AC 5: the access token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agents_without_a_token_is_refused_exactly_like_tags() {
    let srv = Srv::start().await;
    let served = srv.get("/vaults/seed/api/v1/agents", true).await;
    assert_eq!(served.status, 200, "with the token: {}", served.body);

    let agents = srv.get("/vaults/seed/api/v1/agents", false).await;
    let tags = srv.get("/vaults/seed/api/v1/tags", false).await;
    assert_ne!(agents.status, 200, "{}", agents.body);
    assert_eq!(
        (agents.status, agents.c1_code(), agents.json()),
        (tags.status, tags.c1_code(), tags.json()),
        "no token: the same status, code and body as GET /tags"
    );

    let wrong = "Bearer not-the-token";
    let agents = get(&srv.url("/vaults/seed/api/v1/agents"), Some(wrong)).await;
    let tags = get(&srv.url("/vaults/seed/api/v1/tags"), Some(wrong)).await;
    assert_eq!(
        (agents.status, agents.c1_code(), agents.json()),
        (tags.status, tags.c1_code(), tags.json()),
        "a wrong token: the same status, code and body as GET /tags"
    );
    assert!(
        !agents.body.contains("Claude Desktop"),
        "a refused request leaks no agent: {}",
        agents.body
    );
}

// ---------------------------------------------------------------------------
// AC 6: the wire fixture, through the full router (D20)
// ---------------------------------------------------------------------------

fn agents_dir() -> PathBuf {
    api_v1_dir().join("agents")
}

async fn exec(addr: SocketAddr, req: &FixtureRequest) -> FixtureResponse {
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: {}\r\n",
        req.method,
        req.path,
        Srv::bearer()
    );
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    if req.body.is_some() {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    let reply = raw_request(addr, &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

#[test]
fn agents_fixture_rows_match_through_the_full_router() {
    let rows = api_fixtures::load_rows(&agents_dir()).expect("agents/index.json loads");
    let paths: Vec<(&str, &str, u16)> = rows
        .iter()
        .map(|r| (r.method.as_str(), r.path.as_str(), r.status))
        .collect();
    assert_eq!(
        paths,
        [
            ("GET", "/vaults/seed/api/v1/agents", 200),
            ("GET", "/vaults/empty/api/v1/agents", 200),
        ],
        "a vault with records and rows, and one with neither"
    );
    assert!(rows.iter().all(|r| !r.dart_only), "every row runs in Rust");

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let srv = rt.block_on(Srv::start());
    let addr = srv.addr;
    let result = run_rows(&agents_dir(), bless_requested(), |req| {
        rt.block_on(exec(addr, req))
    });
    rt.block_on(async move { drop(srv) });
    if let Err(e) = result {
        panic!("{e}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_serves_agents_on_get_only() {
    // A path parameter clash in the nested routers panics only when the
    // full router starts (D20).
    let srv = Srv::start().await;
    assert_wrong_method_is_c1_405_at(
        srv.addr,
        &Srv::bearer(),
        &[("/vaults/seed/api/v1/agents", &["GET"])],
    )
    .await;
    // The route takes no path parameters.
    let r = srv.get("/vaults/seed/api/v1/agents/extra", true).await;
    assert_eq!(r.status, 404, "{}", r.body);
    assert_eq!(r.c1_code(), "not_found");
}

/// The shared `run_rows` comparison scrubs every `_at` value the seed does not
/// hold to `"<timestamp>"` on both sides, so on its own it would let the
/// committed files lose the ms values: a hosted replay (#454, #456) would then
/// see two live records with one identical time, and the expired record would
/// vanish from the contract. This test also holds the files byte for byte
/// against the unscrubbed canonical body (`MEMEX_BLESS=1` rewrites them).
#[test]
fn agents_fixture_files_keep_the_unscrubbed_ms_values_and_the_expired_record() {
    let rows = api_fixtures::load_rows(&agents_dir()).expect("agents/index.json loads");
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let srv = rt.block_on(Srv::start());
    let addr = srv.addr;
    let mut seed_file: Option<Value> = None;
    for row in &rows {
        let reply = rt.block_on(exec(
            addr,
            &FixtureRequest {
                method: row.method.clone(),
                path: row.path.clone(),
                headers: row.headers.clone(),
                body: None,
            },
        ));
        let actual: Value = serde_json::from_slice(&reply.body).expect("a JSON body");
        let canonical = api_fixtures::canonical_json(&actual);
        let path = agents_dir().join(&row.response);
        if bless_requested() {
            std::fs::write(&path, &canonical).expect("write the response file");
        }
        let committed = std::fs::read_to_string(&path).expect("the response file reads");
        assert_eq!(
            committed, canonical,
            "{} must hold the unscrubbed canonical body of {}",
            row.response, row.path
        );
        if row.path.contains("/seed/") {
            seed_file = Some(serde_json::from_str(&committed).unwrap());
        }
    }
    rt.block_on(async move { drop(srv) });

    let file = seed_file.expect("a row for the seed vault");
    let server_now = file["server_now"]
        .as_i64()
        .expect("server_now is integer ms");
    assert_eq!(server_now, NOW);
    let agents = file["agents"].as_array().expect("agents array");
    let expires: Vec<i64> = agents
        .iter()
        .map(|a| a["expires_at"].as_i64().expect("expires_at is integer ms"))
        .collect();
    assert_eq!(expires.len(), 2);
    assert!(
        expires[0] > server_now,
        "the newest record is live: {expires:?}"
    );
    assert!(
        expires[1] < server_now,
        "the older record is expired: {expires:?}"
    );
    for a in agents {
        for key in ["started_at", "last_seen_at", "last_request_at"] {
            assert!(a[key].is_i64(), "{key} is integer ms: {a}");
        }
    }
    assert!(
        agents[0]["last_request_at"].as_i64() > agents[1]["last_request_at"].as_i64(),
        "agents are ordered by last_request_at descending in the contract"
    );
    for e in file["recent"].as_array().expect("recent array") {
        assert!(e["created_at"].is_i64(), "created_at is integer ms: {e}");
    }
}
