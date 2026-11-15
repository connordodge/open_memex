//! WI #12 (Spec #7 Req 36, 37, Technical Decisions "App API routes"; rulings
//! D11, D13, D14): the hosted half of the frozen Agent read-only and
//! agent-edit revision contract, under `/vaults/{name}/api/v1`, served by the
//! in-process vault server over #74's frozen seed:
//!
//! | Route | Response |
//! |---|---|
//! | `PUT /notes/{note_id}/agent-read-only {agent_read_only: bool}` | the `memex read-only set\|clear` object `{vault_id, note_id, agent_read_only}` |
//! | `GET /notes/{note_id}/revisions` | the `memex revisions list` object `{vault_id, revisions}` |
//! | `POST /notes/{note_id}/revisions/{revision_id}/restore` (no body) | the `memex revisions restore` object `{vault_id, note_id, version, content_md}` |
//!
//! Every parity test runs the real `memex` binary on a second copy of the seed
//! (temp dirs only) and compares the two objects after `normalize_volatile`.
//! Hosted failures compare the status to `status_for_code(code)` and the C1
//! body to the CLI's. No wire-fixture files (D14).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::Router;
use chrono::{TimeZone, Utc};
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::note_edits::{self, EditInput};
use memex_core::notes::NoteId;
use memex_core::{guide, Clock, Vault};
use memex_mcp::server::error::status_for_code;
use memex_mcp::server::{router, ServerConfig};
use rusqlite::Connection;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{materialize_seed, normalize_volatile, seed_vault_id, SEED_VAULT_NAME};
use server::{assert_wrong_method_is_c1_405, client, Reply, TestServer, TEST_TOKEN};

const BASE: &str = "/vaults/seed/api/v1";

/// A topic note (`role: topic`).
const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
/// A plain note (`{}` frontmatter), body `Maybe the map folds like paper?\n`.
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
const LOOSE_TEXT: &str = "Maybe the map folds like paper?\n";
/// A daily note.
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
/// A valid ULID nothing in the seed has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

const T0: i64 = 1_790_000_000_000;
const SECOND: &str = "The map folds twice.\n";
const THIRD: &str = "The map folds three times.\n";
const RESTORE_BULLET: &str = "Restored an earlier version";
/// The fallback's message for a path no route serves.
const NO_ROUTE: &str = "no route for this path";

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// The server over one seed copy, plus a second identical copy for the CLI.
struct Env {
    srv: TestServer,
    cli_root: TempDir,
}

impl Env {
    async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    /// Like [`Env::start`], running `prepare` on both seed copies first.
    async fn start_with(prepare: impl Fn(&Path)) -> Self {
        let root = tempfile::tempdir().unwrap();
        prepare(&materialize_seed(root.path()));
        let cli_root = tempfile::tempdir().unwrap();
        prepare(&materialize_seed(cli_root.path()));
        Self {
            srv: TestServer::start_in(root).await,
            cli_root,
        }
    }

    fn server_vault(&self) -> PathBuf {
        self.srv.root().join(SEED_VAULT_NAME)
    }

    fn cli_vault(&self) -> PathBuf {
        self.cli_root.path().join(SEED_VAULT_NAME)
    }

    /// `METHOD <BASE><path>` with the token and an optional JSON body.
    async fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Reply {
        let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
        let mut req = client()
            .request(method, self.srv.url(&format!("{BASE}{path}")))
            .header("authorization", self.srv.bearer());
        if let Some(body) = body {
            req = req.json(body);
        }
        Reply::read(req.send().await.expect("send request")).await
    }

    /// `METHOD <BASE><path>` with the token and raw JSON-typed body bytes.
    async fn call_raw(&self, method: &str, path: &str, body: &[u8]) -> Reply {
        let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
        let req = client()
            .request(method, self.srv.url(&format!("{BASE}{path}")))
            .header("authorization", self.srv.bearer())
            .header("content-type", "application/json")
            .body(body.to_vec());
        Reply::read(req.send().await.expect("send request")).await
    }

    /// `PUT /notes/{id}/agent-read-only {"agent_read_only": on}`.
    async fn put_flag(&self, id: &str, on: bool) -> Reply {
        self.call(
            "PUT",
            &format!("/notes/{id}/agent-read-only"),
            Some(&json!({ "agent_read_only": on })),
        )
        .await
    }

    /// Runs `memex <command…> --vault <cli copy> <args…>`.
    fn cli(&self, command: &[&str], args: &[&str]) -> Cli {
        let out = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(command)
            .arg("--vault")
            .arg(self.cli_vault())
            .args(args)
            .output()
            .expect("run memex");
        Cli {
            ok: out.status.success(),
            stdout: String::from_utf8(out.stdout).unwrap(),
            stderr: String::from_utf8(out.stderr).unwrap(),
        }
    }

    fn cli_flag(&self, verb: &str, id: &str) -> Cli {
        self.cli(&["read-only", verb], &["--note-id", id])
    }
}

/// What a `memex` run printed.
struct Cli {
    ok: bool,
    stdout: String,
    stderr: String,
}

impl Cli {
    /// The one-line JSON stdout of a successful run.
    fn json(&self) -> Value {
        assert!(self.ok, "memex failed: {}", self.stderr);
        serde_json::from_str(self.stdout.trim())
            .unwrap_or_else(|e| panic!("memex stdout is not JSON ({e}): {}", self.stdout))
    }

    /// The C1 body of a failed run (its last JSON stderr line).
    fn error(&self) -> Value {
        assert!(!self.ok, "memex succeeded: {}", self.stdout);
        let line = self
            .stderr
            .lines()
            .rev()
            .find(|l| l.trim_start().starts_with('{'))
            .unwrap_or_else(|| panic!("no C1 line in stderr: {}", self.stderr));
        serde_json::from_str(line).expect("C1 stderr line is JSON")
    }
}

fn norm(v: &Value) -> Value {
    normalize_volatile(v)
}

/// The route answered `status` with the object `memex` printed.
fn assert_same_object(reply: &Reply, status: u16, cli: &Cli) {
    assert_eq!(reply.status, status, "body: {}", reply.body);
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
}

/// The route answered C1 `code` with `status_for_code(code)` from its own
/// handler (not the no-route fallback), and `memex` printed the same C1 body
/// for the same failure.
fn assert_same_failure(reply: &Reply, code: &str, cli: &Cli) {
    assert_status_for_code(reply, code);
    assert_eq!(norm(&reply.json()), norm(&cli.error()), "code {code}");
}

fn assert_status_for_code(reply: &Reply, code: &str) {
    assert_eq!(reply.c1_code(), code, "body: {}", reply.body);
    assert_eq!(
        reply.status,
        status_for_code(code).as_u16(),
        "{code}: {}",
        reply.body
    );
    assert!(
        !reply.body.contains(NO_ROUTE),
        "answered by the route, not the fallback: {}",
        reply.body
    );
}

fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

fn open(vault: &Path) -> Vault {
    Vault::open(vault).expect("open the seed vault")
}

fn flag(vault: &Path, id: &str) -> i64 {
    db(vault)
        .query_row(
            "SELECT agent_read_only FROM notes WHERE id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

/// `(version, updated_at, content_md)`.
fn stored(vault: &Path, id: &str) -> (i64, i64, String) {
    db(vault)
        .query_row(
            "SELECT version, updated_at, content_md FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap()
}

fn count(vault: &Path, table: &str) -> i64 {
    db(vault)
        .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

/// The guide, created on first read; returns its id.
fn make_guide(dir: &Path) -> String {
    guide::get_or_create(&mut open(dir), &FixedClock(T0), None)
        .unwrap()
        .note_id
}

fn guide_id(vault: &Path) -> String {
    db(vault)
        .query_row(
            "SELECT id FROM notes WHERE CASE WHEN json_valid(frontmatter) \
                 THEN json_extract(frontmatter, '$.role') END = 'guide'",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

/// The agent's `edit_note` (Form B) of `id` to `text` at `at`.
fn agent_rewrite(dir: &Path, id: &str, text: &str, at: i64) {
    let mut vault = open(dir);
    let version = stored(dir, id).0;
    let out = note_edits::edit_note(
        &mut vault,
        EditInput {
            note_id: NoteId::parse(id).unwrap(),
            bullets: vec!["Rewrote the note".to_string()],
            edits: None,
            content_md: Some(text.to_string()),
            expected_version: Some(version),
        },
        "2026-10-18",
        &FixedClock(at),
        None,
    )
    .unwrap_or_else(|e| panic!("edit_note {id}: {e}"));
    assert!(out.changed);
}

/// Two agent edits of [`LOOSE`] and one of [`PLAYER_LOOP`].
fn edits_world(dir: &Path) {
    agent_rewrite(dir, LOOSE, SECOND, T0);
    agent_rewrite(dir, LOOSE, THIRD, T0 + 1);
    agent_rewrite(dir, PLAYER_LOOP, "Rewritten by an agent.\n", T0 + 2);
}

/// `(id, agent_change_id, created_at)` of the note's revisions, newest first.
fn revisions(vault: &Path, id: &str) -> Vec<(String, Option<String>, i64)> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare(
            "SELECT id, agent_change_id, created_at FROM note_revisions
             WHERE note_id = ? ORDER BY new_version DESC",
        )
        .unwrap();
    stmt.query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

fn newest_revision(vault: &Path, id: &str) -> String {
    revisions(vault, id).remove(0).0
}

/// The oldest kept revision of [`LOOSE`]: the one holding its seed text.
fn first_revision(vault: &Path) -> String {
    revisions(vault, LOOSE).pop().unwrap().0
}

// ---------------------------------------------------------------------------
// AC 8: PUT /notes/{note_id}/agent-read-only
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn put_agent_read_only_route_answers_like_memex_read_only_set_and_clear() {
    let env = Env::start().await;
    for id in [LOOSE, PLAYER_LOOP] {
        let before = stored(&env.server_vault(), id);

        let on = env.put_flag(id, true).await;

        assert_same_object(&on, 200, &env.cli_flag("set", id));
        assert_eq!(
            on.json(),
            json!({ "vault_id": seed_vault_id(), "note_id": id, "agent_read_only": true })
        );
        assert_eq!(flag(&env.server_vault(), id), 1, "{id}: set");
        assert_eq!(
            stored(&env.server_vault(), id),
            before,
            "{id}: only the flag"
        );

        let off = env.put_flag(id, false).await;

        assert_same_object(&off, 200, &env.cli_flag("clear", id));
        assert_eq!(
            off.json(),
            json!({ "vault_id": seed_vault_id(), "note_id": id, "agent_read_only": false })
        );
        assert_eq!(flag(&env.server_vault(), id), 0, "{id}: cleared");
        assert_eq!(
            stored(&env.server_vault(), id),
            before,
            "{id}: only the flag"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn put_agent_read_only_true_on_a_daily_note_or_the_guide_is_422_role_rule_like_the_cli() {
    let env = Env::start_with(|dir| {
        make_guide(dir);
    })
    .await;
    let server_guide = guide_id(&env.server_vault());
    let cli_guide = guide_id(&env.cli_vault());

    for (id, cli_id) in [
        (DAY_18, DAY_18),
        (server_guide.as_str(), cli_guide.as_str()),
    ] {
        let before = stored(&env.server_vault(), id);

        let reply = env.put_flag(id, true).await;

        assert_eq!(reply.status, 422, "{id}: {}", reply.body);
        assert_same_failure(&reply, "role_rule", &env.cli_flag("set", cli_id));
        assert_eq!(flag(&env.server_vault(), id), 0, "{id}: nothing written");
        assert_eq!(stored(&env.server_vault(), id), before, "{id}");

        // Clearing always works.
        let off = env.put_flag(id, false).await;
        assert_same_object(&off, 200, &env.cli_flag("clear", cli_id));
        assert_eq!(off.json()["agent_read_only"], json!(false), "{}", off.body);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn put_agent_read_only_true_again_succeeds_and_leaves_the_version_unchanged() {
    let env = Env::start().await;
    let first = env.put_flag(LOOSE, true).await;
    assert_eq!(first.status, 200, "{}", first.body);
    let before = (
        stored(&env.server_vault(), LOOSE),
        count(&env.server_vault(), "note_revisions"),
    );

    let again = env.put_flag(LOOSE, true).await;

    assert_eq!(again.status, 200, "{}", again.body);
    assert_eq!(again.json(), first.json());
    assert_eq!(flag(&env.server_vault(), LOOSE), 1);
    assert_eq!(
        (
            stored(&env.server_vault(), LOOSE),
            count(&env.server_vault(), "note_revisions"),
        ),
        before,
        "version and updated_at stay"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn put_agent_read_only_on_an_unknown_note_is_not_found_like_the_cli() {
    let env = Env::start().await;

    for (on, verb) in [(true, "set"), (false, "clear")] {
        let reply = env.put_flag(UNKNOWN, on).await;
        assert_same_failure(&reply, "not_found", &env.cli_flag(verb, UNKNOWN));
    }
}

/// The body must be `{agent_read_only: bool}`; anything else is the C1
/// `invalid_argument` (400) and writes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn put_agent_read_only_with_a_missing_or_non_bool_field_is_invalid_argument() {
    let env = Env::start().await;
    let path = format!("/notes/{LOOSE}/agent-read-only");

    for body in [
        &b""[..],
        b"{}",
        br#"{"agent_read_only": "true"}"#,
        br#"{"agent_read_only": 1}"#,
        br#"{"agent_read_only": null}"#,
        b"not json",
    ] {
        let reply = env.call_raw("PUT", &path, body).await;
        assert_status_for_code(&reply, "invalid_argument");
        assert_eq!(
            flag(&env.server_vault(), LOOSE),
            0,
            "{}: nothing written",
            String::from_utf8_lossy(body)
        );
    }
}

// ---------------------------------------------------------------------------
// AC 9: GET /notes/{note_id}/revisions
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_revisions_route_answers_like_memex_revisions_list() {
    let env = Env::start_with(edits_world).await;

    let reply = env
        .call("GET", &format!("/notes/{LOOSE}/revisions"), None)
        .await;

    assert_same_object(
        &reply,
        200,
        &env.cli(&["revisions", "list"], &["--note-id", LOOSE]),
    );
    let rows: Vec<Value> = revisions(&env.server_vault(), LOOSE)
        .into_iter()
        .map(|(id, change, at)| json!({ "id": id, "agent_change_id": change, "created_at": at }))
        .collect();
    assert_eq!(rows.len(), 2, "only LOOSE's revisions");
    assert_eq!(rows[0]["created_at"], json!(T0 + 1), "newest first");
    assert_eq!(
        reply.json(),
        json!({ "vault_id": seed_vault_id(), "revisions": rows })
    );

    // A note no agent edited lists none.
    let none = env
        .call("GET", &format!("/notes/{DAY_18}/revisions"), None)
        .await;
    assert_same_object(
        &none,
        200,
        &env.cli(&["revisions", "list"], &["--note-id", DAY_18]),
    );
    assert_eq!(
        none.json(),
        json!({ "vault_id": seed_vault_id(), "revisions": [] })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_revisions_of_an_unknown_note_is_not_found_like_the_cli() {
    let env = Env::start().await;

    let reply = env
        .call("GET", &format!("/notes/{UNKNOWN}/revisions"), None)
        .await;

    assert_same_failure(
        &reply,
        "not_found",
        &env.cli(&["revisions", "list"], &["--note-id", UNKNOWN]),
    );
}

// ---------------------------------------------------------------------------
// AC 10: POST /notes/{note_id}/revisions/{revision_id}/restore
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_restore_route_answers_like_memex_revisions_restore() {
    let env = Env::start_with(edits_world).await;
    let id = first_revision(&env.server_vault());
    let cli_id = first_revision(&env.cli_vault());
    let before = stored(&env.server_vault(), LOOSE);

    let reply = env
        .call(
            "POST",
            &format!("/notes/{LOOSE}/revisions/{id}/restore"),
            None,
        )
        .await;

    assert_same_object(
        &reply,
        200,
        &env.cli(&["revisions", "restore"], &["--revision-id", &cli_id]),
    );
    let (version, _, content_md) = stored(&env.server_vault(), LOOSE);
    assert_eq!(version, before.0 + 1);
    assert_eq!(content_md, LOOSE_TEXT, "the seed text is back");
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": seed_vault_id(),
            "note_id": LOOSE,
            "version": version,
            "content_md": LOOSE_TEXT,
        })
    );
    // The replaced text is kept: restoring the new revision brings it back.
    let kept = newest_revision(&env.server_vault(), LOOSE);
    assert_ne!(kept, id);
    let back = env
        .call(
            "POST",
            &format!("/notes/{LOOSE}/revisions/{kept}/restore"),
            None,
        )
        .await;
    assert_eq!(back.status, 200, "{}", back.body);
    assert_eq!(back.json()["content_md"], json!(THIRD), "{}", back.body);
}

/// D11: the path's `note_id` is passed to Restore; a revision of another note
/// is `not_found` and writes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_restore_with_a_revision_of_another_note_is_not_found_and_writes_nothing() {
    let env = Env::start_with(edits_world).await;
    let loose_revision = first_revision(&env.server_vault());
    let vault = env.server_vault();
    let before = (
        stored(&vault, LOOSE),
        stored(&vault, PLAYER_LOOP),
        count(&vault, "note_revisions"),
        count(&vault, "agent_changes"),
    );

    for owner in [PLAYER_LOOP, DAY_18, UNKNOWN] {
        let reply = env
            .call(
                "POST",
                &format!("/notes/{owner}/revisions/{loose_revision}/restore"),
                None,
            )
            .await;
        assert_status_for_code(&reply, "not_found");
    }

    assert_eq!(
        (
            stored(&vault, LOOSE),
            stored(&vault, PLAYER_LOOP),
            count(&vault, "note_revisions"),
            count(&vault, "agent_changes"),
        ),
        before,
        "nothing written"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_restore_of_an_unknown_revision_is_not_found_like_the_cli() {
    let env = Env::start_with(edits_world).await;

    let reply = env
        .call(
            "POST",
            &format!("/notes/{LOOSE}/revisions/{UNKNOWN}/restore"),
            None,
        )
        .await;

    assert_same_failure(
        &reply,
        "not_found",
        &env.cli(&["revisions", "restore"], &["--revision-id", UNKNOWN]),
    );
}

/// Restore is a person write: it works on a note flagged Agent read-only.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_restore_works_on_an_agent_read_only_note() {
    let env = Env::start_with(edits_world).await;
    let set = env.put_flag(LOOSE, true).await;
    assert_eq!(set.status, 200, "{}", set.body);
    let id = first_revision(&env.server_vault());

    let reply = env
        .call(
            "POST",
            &format!("/notes/{LOOSE}/revisions/{id}/restore"),
            None,
        )
        .await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["content_md"], json!(LOOSE_TEXT));
    assert_eq!(flag(&env.server_vault(), LOOSE), 1, "the flag stays");
}

// ---------------------------------------------------------------------------
// AC 11: the routes on the full server router
// ---------------------------------------------------------------------------

/// The full vault server (`server::router`, every nest at server/mod.rs) starts
/// with the new routes nested under `/vaults/{name}/api/v1`: merging them
/// panics on a path-parameter-name clash, and each answers from its own
/// handler.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_server_router_starts_with_the_note_edit_routes_nested_under_the_vault_api() {
    let env = Env::start_with(edits_world).await;
    let revision = first_revision(&env.server_vault());

    let put = env.put_flag(LOOSE, false).await;
    assert_eq!(put.status, 200, "PUT agent-read-only: {}", put.body);
    let list = env
        .call("GET", &format!("/notes/{LOOSE}/revisions"), None)
        .await;
    assert_eq!(list.status, 200, "GET revisions: {}", list.body);
    let restore = env
        .call(
            "POST",
            &format!("/notes/{LOOSE}/revisions/{revision}/restore"),
            None,
        )
        .await;
    assert_eq!(restore.status, 200, "POST restore: {}", restore.body);

    // The routes it already had still answer.
    let note = env.call("GET", &format!("/notes/{LOOSE}"), None).await;
    assert_eq!(note.status, 200, "GET note: {}", note.body);
    let guide_revisions = env.call("GET", "/guide/revisions", None).await;
    assert_eq!(guide_revisions.status, 200, "{}", guide_revisions.body);
}

/// Every route this WI adds, as `(METHOD, path)` with concrete ids.
fn note_edit_routes() -> Vec<(&'static str, String)> {
    vec![
        ("PUT", format!("/notes/{LOOSE}/agent-read-only")),
        ("GET", format!("/notes/{LOOSE}/revisions")),
        (
            "POST",
            format!("/notes/{LOOSE}/revisions/{UNKNOWN}/restore"),
        ),
    ]
}

async fn serve_nested(api: Router) -> (SocketAddr, JoinHandle<()>) {
    let app = Router::new().nest("/vaults/{name}/api/v1", api);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (addr, task)
}

async fn status_at(addr: SocketAddr, method: &str, path: &str) -> u16 {
    client()
        .request(
            reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
            format!("http://{addr}{BASE}{path}"),
        )
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

/// D13: the routes live in `api/note_edits.rs`, merged into the api router.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn note_edits_router_holds_the_three_routes_and_the_api_router_merges_it() {
    let (own, own_task) = serve_nested(memex_mcp::server::api::note_edits::router()).await;
    let (all, all_task) = serve_nested(memex_mcp::server::api::router()).await;

    for (method, path) in note_edit_routes() {
        for (what, addr) in [("note_edits", own), ("api", all)] {
            let status = status_at(addr, method, &path).await;
            assert!(
                status != 404 && status != 405,
                "{method} {path} is in the {what} router (got {status})"
            );
        }
    }
    // Nothing else lives in it.
    for (method, path) in [
        ("GET", format!("/notes/{LOOSE}")),
        ("GET", "/guide/revisions".to_string()),
    ] {
        assert_eq!(
            status_at(own, method, &path).await,
            404,
            "{method} {path} is not in the note_edits router"
        );
    }

    own_task.abort();
    all_task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn note_edit_routes_answer_wrong_methods_with_the_c1_405() {
    let env = Env::start().await;
    let flag = format!("{BASE}/notes/{LOOSE}/agent-read-only");
    let list = format!("{BASE}/notes/{LOOSE}/revisions");
    let restore = format!("{BASE}/notes/{LOOSE}/revisions/{UNKNOWN}/restore");

    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (flag.as_str(), &["PUT"][..]),
            (list.as_str(), &["GET"][..]),
            (restore.as_str(), &["POST"][..]),
        ],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn note_edit_routes_answer_401_without_a_bearer_token_and_serve_with_one() {
    let env = Env::start().await;

    for (method, path) in note_edit_routes() {
        let send = |auth: Option<String>| {
            let mut req = client().request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                env.srv.url(&format!("{BASE}{path}")),
            );
            if let Some(a) = auth {
                req = req.header("authorization", a);
            }
            req.send()
        };
        for auth in [None, Some("Bearer not-the-token".to_string())] {
            let reply = Reply::read(send(auth.clone()).await.unwrap()).await;
            assert_eq!(
                (reply.status, reply.c1_code()),
                (401, "unauthorized".to_string()),
                "{method} {path} with {auth:?}"
            );
        }
        let reply = Reply::read(send(Some(env.srv.bearer())).await.unwrap()).await;
        assert_ne!(reply.status, 401, "{method} {path}");
        assert_ne!(reply.status, 405, "{method} {path}");
        assert!(
            !reply.body.contains(NO_ROUTE),
            "{method} {path}: {}",
            reply.body
        );
    }
    assert_eq!(flag(&env.server_vault(), LOOSE), 0, "401s write nothing");
}

// ---------------------------------------------------------------------------
// The request's clock and the shared embedder
// ---------------------------------------------------------------------------

/// A vault server over a seed copy with a config the test chooses.
struct ConfiguredServer {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl ConfiguredServer {
    async fn start(
        prepare: impl Fn(&Path),
        config: impl FnOnce(ServerConfig) -> ServerConfig,
    ) -> Self {
        let root = tempfile::tempdir().unwrap();
        prepare(&materialize_seed(root.path()));
        let app = router(config(ServerConfig::new(
            root.path().to_path_buf(),
            TEST_TOKEN,
        )));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self { root, addr, task }
    }

    fn vault(&self) -> PathBuf {
        self.root.path().join(SEED_VAULT_NAME)
    }

    async fn call(
        &self,
        method: &str,
        path: &str,
        utc_offset: Option<&str>,
        body: Option<&Value>,
    ) -> Reply {
        let mut req = client()
            .request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                format!("http://{}{BASE}{path}", self.addr),
            )
            .header("authorization", format!("Bearer {TEST_TOKEN}"));
        if let Some(offset) = utc_offset {
            req = req.header("x-memex-utc-offset", offset);
        }
        if let Some(body) = body {
            req = req.json(body);
        }
        Reply::read(req.send().await.expect("send request")).await
    }
}

impl Drop for ConfiguredServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Restore dates its entry today in the request's zone and stamps the kept
/// revision with the request's clock. 2026-11-05T12:00Z is 2026-11-06 at
/// +14:00 and 2026-11-05 at -12:00. Nothing in the request can name the day.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_restore_dates_its_entry_in_the_requests_zone_and_stamps_the_requests_clock() {
    let now = Utc
        .with_ymd_and_hms(2026, 11, 5, 12, 0, 0)
        .unwrap()
        .timestamp_millis();
    let srv =
        ConfiguredServer::start(edits_world, |c| c.with_clock(Arc::new(FixedClock(now)))).await;

    for (offset, day) in [("+14:00", "2026-11-06"), ("-12:00", "2026-11-05")] {
        let id = newest_revision(&srv.vault(), LOOSE);
        let reply = srv
            .call(
                "POST",
                &format!("/notes/{LOOSE}/revisions/{id}/restore?day=1999-01-01"),
                Some(offset),
                Some(&json!({"day": "1999-01-01"})),
            )
            .await;
        assert_eq!(reply.status, 200, "{offset}: {}", reply.body);

        let (kept, change, created_at) = revisions(&srv.vault(), LOOSE).remove(0);
        assert_ne!(kept, id, "{offset}: a new revision");
        assert_eq!(created_at, now, "{offset}: stamped by the request");
        let (got_day, bullets): (String, String) = db(&srv.vault())
            .query_row(
                "SELECT day, bullets_json FROM agent_changes WHERE id = ?",
                [change.expect("linked")],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(got_day, day, "at {offset}");
        assert_eq!(bullets, format!(r#"["{RESTORE_BULLET}"]"#));
    }
}

/// An embedder that counts its batches.
struct CountingEmbedder {
    inner: FakeEmbedder,
    batches: Arc<AtomicUsize>,
}

impl Embedder for CountingEmbedder {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        self.batches.fetch_add(1, Ordering::SeqCst);
        self.inner.embed_batch(texts)
    }
}

/// Lead decision 6: a hosted Restore reindexes with the registry's shared
/// embedder.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_restore_reindexes_with_the_shared_embedder() {
    let batches = Arc::new(AtomicUsize::new(0));
    let embedder = CountingEmbedder {
        inner: FakeEmbedder::new(8),
        batches: batches.clone(),
    };
    let srv = ConfiguredServer::start(edits_world, |c| {
        c.with_embeddings(true).with_embedder(Arc::new(embedder))
    })
    .await;

    // The server's background backfill shares this embedder and runs an
    // `embed_batch` of its own once the first request opens the vault. Let it
    // finish first, so the count below is the request's own batch.
    let warm_up = srv.call("GET", "/info", None, None).await;
    assert!(warm_up.status < 300, "warm-up: {}", warm_up.body);
    let started = std::time::Instant::now();
    loop {
        let counts = memex_core::vectors::embedding_counts(&db(&srv.vault())).unwrap();
        if counts.chunks > 0 && counts.embedded == counts.chunks {
            break;
        }
        assert!(
            started.elapsed() < std::time::Duration::from_secs(30),
            "the backfill did not embed the seed vault: {counts:?}"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    let id = first_revision(&srv.vault());
    let before = batches.load(Ordering::SeqCst);
    let reply = srv
        .call(
            "POST",
            &format!("/notes/{LOOSE}/revisions/{id}/restore"),
            None,
            None,
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert!(
        batches.load(Ordering::SeqCst) > before,
        "restore reindexed with the shared embedder"
    );
}
