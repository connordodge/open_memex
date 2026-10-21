//! WI #94 (R4): the hosted vault revision (D9, lead ruling on the busy
//! placeholder).
//!
//! `GET /vaults/{name}/api/v1/revision` answers 200
//! `{"revision": "<open_id>-<total_changes>-<data_version>"}`, read on the
//! vault's one server connection:
//!
//! - `open_id` is the registry entry's ULID, new for every open, so a
//!   reopened vault (or a restarted server) never repeats a value;
//! - `total_changes()` moves with the server connection's own commits;
//! - `PRAGMA data_version` moves with commits by other connections (the CLI,
//!   a stdio `memex serve`).
//!
//! The route `try_lock`s the vault and never waits: while the vault is busy
//! it answers the last value it computed for this `open_id`, or
//! `<open_id>-0-0` when it has computed none yet.
//!
//! Most tests serve the app API with their own [`Registry`], so they can
//! reach the registry entry's `AppState` (the connection app-API and `/mcp`
//! writes use) and hold its mutex. The auth, 405 and fixture tests use the
//! whole server (`memex_mcp::server::router`).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::io::Write as _;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use axum::middleware::from_fn_with_state;
use axum::routing::get as get_route;
use axum::{Extension, Router};
use memex_core::notes::{self, CreateNote};
use memex_core::{SystemClock, Vault};
use memex_mcp::server::registry::{Registry, VaultEntry};
use memex_mcp::server::request_clock::{BaseClock, SharedClock};
use memex_mcp::server::{api, vaults};
use regex::Regex;
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, run_rows, FixtureRequest,
    FixtureResponse, SEED_VAULT_NAME,
};
use server::{
    assert_wrong_method_is_c1_405, get, make_vault, raw_request, Reply, TestServer, TEST_TOKEN,
};

/// How long a revision read may take while the vault is busy (AC 4).
const BUSY_BOUND: Duration = Duration::from_secs(1);

const VAULT: &str = "work";

// ---------------------------------------------------------------------------
// Harness: the app API over a registry the test holds
// ---------------------------------------------------------------------------

/// `/vaults/{name}/api/v1/info` and every app-API route, behind the vault
/// guard, over a [`Registry`] this test can reach. No auth layer.
struct Wi94Server {
    registry: Arc<Registry>,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl Wi94Server {
    async fn start(root: &Path) -> Self {
        let registry = Arc::new(Registry::new(root.to_path_buf(), None));
        let clock: SharedClock = Arc::new(SystemClock);
        let app = Router::new()
            .route("/vaults/{name}/api/v1/info", get_route(vaults::info))
            .nest("/vaults/{name}/api/v1", api::router())
            .layer(from_fn_with_state(registry.clone(), vaults::vault_guard))
            .layer(Extension(registry.clone()))
            .layer(Extension(BaseClock(clock)));
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local addr");
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self {
            registry,
            addr,
            task,
        }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    /// `GET /vaults/<name>/api/v1/revision`, as read.
    async fn revision_reply(&self, name: &str) -> Reply {
        get(&self.url(&format!("/vaults/{name}/api/v1/revision")), None).await
    }

    /// The revision string of a 200 `{"revision": "<non-empty string>"}`.
    async fn revision(&self, name: &str) -> String {
        revision_of(&self.revision_reply(name).await)
    }

    /// [`Self::revision`], failing unless it answers within [`BUSY_BOUND`].
    async fn revision_within_bound(&self, name: &str, what: &str) -> String {
        match tokio::time::timeout(BUSY_BOUND, self.revision_reply(name)).await {
            Ok(reply) => revision_of(&reply),
            Err(_) => panic!("{what}: the revision route waited more than {BUSY_BOUND:?}"),
        }
    }

    /// The registry entry the server uses for `name` (the same `Arc`).
    async fn entry(&self, name: &str) -> Arc<VaultEntry> {
        match self.registry.get(name).await {
            Ok(entry) => entry,
            Err(_) => panic!("registry get {name} failed"),
        }
    }

    async fn stop(mut self) {
        self.task.abort();
        let _ = (&mut self.task).await;
    }
}

impl Drop for Wi94Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The revision of a 200 reply: a JSON object whose only key is a non-empty
/// string `revision`.
fn revision_of(reply: &Reply) -> String {
    assert_eq!(reply.status, 200, "revision status: {:?}", reply.body);
    assert!(
        reply
            .header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "a JSON body, got {:?}",
        reply.header("content-type")
    );
    let v = reply.json();
    let obj = v
        .as_object()
        .unwrap_or_else(|| panic!("a JSON object: {v}"));
    assert_eq!(
        obj.keys().collect::<Vec<_>>(),
        vec!["revision"],
        "the body is {{\"revision\": …}} only: {v}"
    );
    let revision = obj["revision"]
        .as_str()
        .unwrap_or_else(|| panic!("revision is a string: {v}"))
        .to_string();
    assert!(!revision.is_empty(), "revision is non-empty: {v}");
    revision
}

/// `<ULID>-<int>-<int>` split into its three parts.
fn parts(revision: &str) -> (String, u64, u64) {
    let re = Regex::new(r"^([0-7][0-9A-HJKMNP-TV-Z]{25})-(\d+)-(\d+)$").unwrap();
    let c = re.captures(revision).unwrap_or_else(|| {
        panic!("revision {revision:?} is <open_id>-<total_changes>-<data_version>")
    });
    (
        c[1].to_string(),
        c[2].parse().unwrap(),
        c[3].parse().unwrap(),
    )
}

fn create_note_in(vault: &mut Vault, title: &str) -> notes::NoteId {
    notes::create_note(
        vault,
        CreateNote {
            title: Some(title.to_string()),
            content_md: format!("body of {title}"),
            frontmatter: None,
        },
    )
    .unwrap_or_else(|e| panic!("create note {title}: {e}"))
    .id
}

/// A note created on the entry's own server connection (its `AppState`).
async fn write_on_server_connection(entry: &VaultEntry, title: &str) -> notes::NoteId {
    let mut vault = entry.state.vault.lock().await;
    create_note_in(&mut vault, title)
}

/// The built `memex add --vault <vault> --title <title>` with `body` on
/// stdin, run to completion in its own process.
fn memex_add_out_of_process(vault: &Path, title: &str, body: &str) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["add", "--vault"])
        .arg(vault)
        .args(["--title", title])
        .env_remove("MEMEX_ACCESS_TOKEN")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex add");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(body.as_bytes())
        .expect("write stdin");
    let out = child.wait_with_output().expect("wait memex add");
    assert!(
        out.status.success(),
        "memex add failed: exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

fn vault_dir(root: &Path, name: &str) -> PathBuf {
    std::path::absolute(root.join(name)).expect("absolute vault path")
}

/// Copies the vault files of `<root>/<name>` (closed) to `dest`.
fn back_up_vault(root: &Path, name: &str, dest: &Path) {
    std::fs::create_dir_all(dest).unwrap();
    for file in ["manifest.json", "memex.db"] {
        std::fs::copy(root.join(name).join(file), dest.join(file))
            .unwrap_or_else(|e| panic!("back up {file}: {e}"));
    }
}

fn restore_vault(backup: &Path, root: &Path, name: &str) {
    let dir = root.join(name);
    std::fs::create_dir_all(&dir).unwrap();
    for file in ["manifest.json", "memex.db"] {
        std::fs::copy(backup.join(file), dir.join(file))
            .unwrap_or_else(|e| panic!("restore {file}: {e}"));
    }
}

async fn assert_vault_not_found(srv: &Wi94Server, name: &str) {
    let r = srv.revision_reply(name).await;
    assert_eq!(r.status, 404, "revision of a deleted vault: {:?}", r.body);
    assert_eq!(r.c1_code(), "vault_not_found");
}

// ---------------------------------------------------------------------------
// AC 1: 200 {"revision"}, stable with no write
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revision_is_200_with_a_non_empty_string_and_stable_without_writes() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    let first = srv.revision(VAULT).await;
    let second = srv.revision(VAULT).await;
    assert_eq!(first, second, "two reads with no write between them");

    // A read route on the same vault is not a write.
    let info = get(&srv.url(&format!("/vaults/{VAULT}/api/v1/info")), None).await;
    assert_eq!(info.status, 200, "{:?}", info.body);
    // Nor is a read on the server connection.
    let entry = srv.entry(VAULT).await;
    {
        let vault = entry.state.vault.lock().await;
        let n: i64 = vault
            .connection_ref()
            .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
            .unwrap();
        assert!(n >= 0);
    }
    assert_eq!(srv.revision(VAULT).await, first, "reads change nothing");
    // The name is case-insensitive, like every vault route.
    assert_eq!(srv.revision("WORK").await, first, "same vault, any case");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revision_is_the_registry_open_id_then_total_changes_then_data_version() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    let revision = srv.revision(VAULT).await;
    let entry = srv.entry(VAULT).await;
    let (open_id, total_changes, data_version) = parts(&revision);
    assert_eq!(open_id, entry.open_id.to_string(), "prefix is the open_id");

    // Read the same two numbers on the same server connection.
    let (tc, dv): (u64, u64) = {
        let vault = entry.state.vault.lock().await;
        let conn = vault.connection_ref();
        let tc: i64 = conn
            .query_row("SELECT total_changes()", [], |r| r.get(0))
            .unwrap();
        let dv: i64 = conn
            .query_row("PRAGMA data_version", [], |r| r.get(0))
            .unwrap();
        (tc as u64, dv as u64)
    };
    assert_eq!(
        (total_changes, data_version),
        (tc, dv),
        "{revision} is <open_id>-<total_changes()>-<PRAGMA data_version> \
         of the server connection"
    );
    assert_ne!(
        revision,
        format!("{open_id}-0-0"),
        "a computed value is never the busy placeholder"
    );
}

// ---------------------------------------------------------------------------
// AC 2: a write on the server connection changes it
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_write_on_the_server_connection_changes_the_next_revision() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    let r0 = srv.revision(VAULT).await;
    let entry = srv.entry(VAULT).await;
    let mut seen = vec![r0.clone()];

    // A note create through the AppState app-API and /mcp writes use.
    let id = write_on_server_connection(&entry, "server write").await;
    let r1 = srv.revision(VAULT).await;
    assert!(
        !seen.contains(&r1),
        "a note create changes it: {seen:?} then {r1}"
    );
    seen.push(r1.clone());

    // A non-note table (D9: notes.updated_at alone would miss it).
    {
        let vault = entry.state.vault.lock().await;
        vault
            .connection_ref()
            .execute(
                "INSERT INTO vault_settings(key, value) VALUES ('wi94', '1')",
                [],
            )
            .unwrap();
    }
    let r2 = srv.revision(VAULT).await;
    assert!(
        !seen.contains(&r2),
        "a settings write changes it: {seen:?} then {r2}"
    );
    seen.push(r2.clone());

    // A delete (D9: notes.updated_at alone would miss it).
    {
        let mut vault = entry.state.vault.lock().await;
        notes::delete_note(&mut vault, &id).unwrap();
    }
    let r3 = srv.revision(VAULT).await;
    assert!(
        !seen.contains(&r3),
        "a delete changes it: {seen:?} then {r3}"
    );

    assert_eq!(srv.revision(VAULT).await, r3, "stable again with no write");
    for r in [&r1, &r2, &r3] {
        assert_eq!(parts(r).0, entry.open_id.to_string(), "the same open: {r}");
    }
}

// ---------------------------------------------------------------------------
// AC 3: an out-of-process write changes it
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_out_of_process_memex_add_changes_the_next_revision() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    // The server holds the vault open from here on.
    let r0 = srv.revision(VAULT).await;
    let entry = srv.entry(VAULT).await;

    let dir = vault_dir(root.path(), VAULT);
    tokio::task::spawn_blocking(move || {
        memex_add_out_of_process(&dir, "cli write", "written by another process\n")
    })
    .await
    .unwrap();

    let r1 = srv.revision(VAULT).await;
    assert_ne!(r1, r0, "a commit by another process changes it");
    assert_eq!(
        parts(&r1).0,
        entry.open_id.to_string(),
        "the server did not reopen the vault"
    );
    assert_eq!(srv.revision(VAULT).await, r1, "stable again with no write");

    // A second one moves it again.
    let dir = vault_dir(root.path(), VAULT);
    tokio::task::spawn_blocking(move || memex_add_out_of_process(&dir, "cli write 2", "again\n"))
        .await
        .unwrap();
    let r2 = srv.revision(VAULT).await;
    assert!(r2 != r1 && r2 != r0, "{r0} {r1} {r2}");
}

// ---------------------------------------------------------------------------
// AC 4: a busy vault never makes the route wait
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_busy_vault_answers_within_a_second_with_the_last_value_it_returned() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    let entry = srv.entry(VAULT).await;
    write_on_server_connection(&entry, "before").await;
    let last = srv.revision(VAULT).await;

    // Busy: the test holds the vault's mutex (as a long write would) and
    // even commits under it.
    let mut busy = entry.state.vault.clone().lock_owned().await;
    for i in 0..3 {
        assert_eq!(
            srv.revision_within_bound(VAULT, &format!("busy read {i}"))
                .await,
            last,
            "busy read {i}: the last value the route returned"
        );
    }
    create_note_in(&mut busy, "written while busy");
    assert_eq!(
        srv.revision_within_bound(VAULT, "busy read after a held write")
            .await,
        last,
        "still the last value it returned, not a fresh read"
    );
    drop(busy);

    let after = srv.revision(VAULT).await;
    assert_ne!(after, last, "after release, the held write shows");
    assert_eq!(parts(&after).0, entry.open_id.to_string());

    write_on_server_connection(&entry, "after release").await;
    let later = srv.revision(VAULT).await;
    assert!(later != after && later != last, "{last} {after} {later}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_vault_busy_before_its_first_revision_answers_the_open_id_zero_zero_placeholder() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    // Opened by another route; no revision computed yet for this open.
    let info = get(&srv.url(&format!("/vaults/{VAULT}/api/v1/info")), None).await;
    assert_eq!(info.status, 200, "{:?}", info.body);
    let entry = srv.entry(VAULT).await;
    let placeholder = format!("{}-0-0", entry.open_id);

    let busy = entry.state.vault.clone().lock_owned().await;
    for i in 0..2 {
        assert_eq!(
            srv.revision_within_bound(VAULT, &format!("first read while busy {i}"))
                .await,
            placeholder,
            "busy before any value for this open"
        );
    }
    drop(busy);

    let real = srv.revision(VAULT).await;
    assert!(
        real.starts_with(&format!("{}-", entry.open_id)),
        "same open_id prefix: {real}"
    );
    assert_ne!(
        real, placeholder,
        "the first real value is not the placeholder"
    );
    assert_eq!(srv.revision(VAULT).await, real, "then stable");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reopened_vault_busy_before_its_first_revision_never_answers_the_old_open_value() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    let old = srv.revision(VAULT).await;
    let old_entry = srv.entry(VAULT).await;

    std::fs::remove_dir_all(root.path().join(VAULT)).unwrap();
    assert_vault_not_found(&srv, VAULT).await;
    make_vault(root.path(), VAULT);

    // Reopened by another route: a new open_id, nothing computed for it.
    let info = get(&srv.url(&format!("/vaults/{VAULT}/api/v1/info")), None).await;
    assert_eq!(info.status, 200, "{:?}", info.body);
    let entry = srv.entry(VAULT).await;
    assert_ne!(entry.open_id, old_entry.open_id, "a new open");

    let busy = entry.state.vault.clone().lock_owned().await;
    let answer = srv
        .revision_within_bound(VAULT, "busy after the reopen")
        .await;
    drop(busy);
    assert_ne!(answer, old, "never the previous open's cached value");
    assert_eq!(
        answer,
        format!("{}-0-0", entry.open_id),
        "the cache is keyed by open_id"
    );
}

// ---------------------------------------------------------------------------
// AC 5: fresh opens never repeat a value
// ---------------------------------------------------------------------------

/// Every value one open serves: fresh, then after a server-connection write.
async fn values_of_one_open(srv: &Wi94Server) -> (String, BTreeSet<String>) {
    let mut seen = BTreeSet::new();
    seen.insert(srv.revision(VAULT).await);
    let entry = srv.entry(VAULT).await;
    write_on_server_connection(&entry, &format!("one write in {}", entry.open_id)).await;
    seen.insert(srv.revision(VAULT).await);
    (entry.open_id.to_string(), seen)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_vault_deleted_and_created_again_never_repeats_a_revision() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    let srv = Wi94Server::start(root.path()).await;

    let (old_open, old_values) = values_of_one_open(&srv).await;

    std::fs::remove_dir_all(root.path().join(VAULT)).unwrap();
    assert_vault_not_found(&srv, VAULT).await;
    make_vault(root.path(), VAULT);

    let fresh = srv.revision(VAULT).await;
    assert!(
        !old_values.contains(&fresh),
        "{fresh} was served before: {old_values:?}"
    );
    assert_ne!(parts(&fresh).0, old_open, "a new open_id");
    let (_, new_values) = values_of_one_open(&srv).await;
    assert!(
        new_values.is_disjoint(&old_values),
        "{new_values:?} vs {old_values:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_vault_restored_from_the_same_files_never_repeats_a_revision() {
    // The same vault_id and the same database bytes: only the open differs.
    let root = tempfile::tempdir().unwrap();
    let backup = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);
    back_up_vault(root.path(), VAULT, backup.path());
    let srv = Wi94Server::start(root.path()).await;

    let first = srv.revision(VAULT).await;
    let first_open = srv.entry(VAULT).await.open_id;

    std::fs::remove_dir_all(root.path().join(VAULT)).unwrap();
    assert_vault_not_found(&srv, VAULT).await;
    restore_vault(backup.path(), root.path(), VAULT);

    let again = srv.revision(VAULT).await;
    assert_ne!(again, first, "the restored vault is a fresh open");
    assert_ne!(parts(&again).0, first_open.to_string());
    assert_eq!(
        (parts(&again).1, parts(&again).2),
        (parts(&first).1, parts(&first).2),
        "same files, same counters: only the open_id tells them apart"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_server_restarted_on_the_same_root_serves_values_the_previous_run_never_served() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), VAULT);

    let srv = Wi94Server::start(root.path()).await;
    let first_fresh = srv.revision(VAULT).await;
    let (old_open, mut old_values) = values_of_one_open(&srv).await;
    old_values.insert(first_fresh.clone());
    srv.stop().await;

    let srv = Wi94Server::start(root.path()).await;
    let fresh = srv.revision(VAULT).await;
    assert!(
        !old_values.contains(&fresh),
        "{fresh} was served by the previous run: {old_values:?}"
    );
    assert_ne!(parts(&fresh).0, old_open, "a new open_id for the new run");
    let (_, new_values) = values_of_one_open(&srv).await;
    assert!(
        new_values.is_disjoint(&old_values),
        "{new_values:?} vs {old_values:?}"
    );
}

// ---------------------------------------------------------------------------
// AC 6: errors through the whole server (auth layer, vault guard, C1)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unknown_vault_is_404_vault_not_found_and_no_token_is_401_unauthorized() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), VAULT);
    let bearer = srv.bearer();

    // The served vault answers with the token.
    let ok = get(
        &srv.url(&format!("/vaults/{VAULT}/api/v1/revision")),
        Some(&bearer),
    )
    .await;
    revision_of(&ok);

    let unknown = get(&srv.url("/vaults/nope/api/v1/revision"), Some(&bearer)).await;
    assert_eq!(unknown.status, 404, "{:?}", unknown.body);
    assert_eq!(unknown.c1_code(), "vault_not_found");

    let path = format!("/vaults/{VAULT}/api/v1/revision");
    for (what, auth) in [
        ("no token", None),
        ("a wrong token", Some("Bearer not-the-server-token")),
    ] {
        let r = get(&srv.url(&path), auth).await;
        assert_eq!(r.status, 401, "{what}: {:?}", r.body);
        assert_eq!(r.c1_code(), "unauthorized", "{what}");
        assert!(!r.body.contains(TEST_TOKEN), "{what}: no token echo");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wrong_methods_on_the_revision_route_are_c1_405_method_not_allowed() {
    let srv = TestServer::start().await;
    make_vault(srv.root(), VAULT);
    let path = format!("/vaults/{VAULT}/api/v1/revision");
    // POST, PUT, DELETE, PATCH and OPTIONS: a JSON C1 405, no CORS headers,
    // no token echo.
    assert_wrong_method_is_c1_405(&srv, &[(&path, &["GET"])]).await;
    let r = get(&srv.url(&path), Some(&srv.bearer())).await;
    revision_of(&r);
}

// ---------------------------------------------------------------------------
// AC 7: the revision/ fixture rows against the seed vault
// ---------------------------------------------------------------------------

async fn exec(srv: &TestServer, req: &FixtureRequest) -> FixtureResponse {
    let has = |name: &str| req.headers.keys().any(|k| k.eq_ignore_ascii_case(name));
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        req.method, req.path
    );
    if !has("authorization") {
        head.push_str(&format!("Authorization: {}\r\n", srv.bearer()));
    }
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    if req.body.is_some() && !has("content-length") {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    let reply = raw_request(srv.addr(), &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

#[test]
fn revision_fixture_rows_match_the_server_over_the_seed_vault() {
    let dir = api_v1_dir().join("revision");
    let rows = load_rows(&dir).expect("revision/index.json parses");
    let seed_path = format!("/vaults/{SEED_VAULT_NAME}/api/v1/revision");
    let ok = rows
        .iter()
        .find(|r| !r.dart_only && r.method == "GET" && r.path == seed_path && r.status == 200)
        .unwrap_or_else(|| panic!("revision/ has a Rust GET {seed_path} 200 row"));
    let stored: Value = serde_json::from_slice(&std::fs::read(dir.join(&ok.response)).unwrap())
        .expect("the response file is JSON");
    let revision = stored["revision"].as_str().unwrap_or_default();
    assert!(
        Regex::new(r"^<id:1>-\d+-\d+$").unwrap().is_match(revision),
        "the stored revision is normalized (open_id as <id:1>): {stored}"
    );
    assert!(
        rows.iter()
            .any(|r| r.status == 404 && r.path.ends_with("/api/v1/revision")),
        "revision/ has a vault_not_found row"
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&dir, bless_requested(), |req| rt.block_on(exec(&srv, req)));
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}
