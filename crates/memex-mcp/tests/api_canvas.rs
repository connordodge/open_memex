//! WI #84 (V4): canvas over the app API, Rust half.
//!
//! The canvas routes under `/vaults/{name}/api/v1`, served by the in-process
//! vault server (`127.0.0.1:0`) over #74's frozen seed (one canvas,
//! "Prototype Map", with Player Loop and Economy Design placed):
//!
//! | Route | Response |
//! |---|---|
//! | `GET /canvases` | the `memex canvas ls` object `{vault_id,canvases:[{canvas_id,title,created_at,updated_at,version,node_count}]}` |
//! | `GET /canvases/{canvas_id}` | the `memex canvas get` object (nodes, edges); unknown id: C1 `not_found` |
//! | `POST /canvases {title}` | 201, the `memex canvas new` object; a used title: C1 `title_conflict` with `existing_id` |
//! | `POST /canvases/{canvas_id}/nodes {note_id,x,y}` | the `memex canvas add` object (idempotent) |
//! | `PATCH /canvases/{canvas_id}/nodes/{note_id} {x,y,z_order?}` | the `memex canvas move` object (no `placed_at`) |
//!
//! Errors are the C1 body the CLI prints for the same failure. The fixture
//! rows in `app/test/fixtures/api_v1/canvas/index.json` were made with the
//! `memex` CLI on a copy of the seed, in row order
//! ([`canvas_fixture_rows_are_the_memex_cli_on_a_seed_copy`] is the only
//! test that may rewrite them, from the CLI, under `MEMEX_BLESS=1`), then
//! frozen: the server test never reblesses them.
//!
//! Every CLI parity test runs the real `memex` binary on a second copy of
//! the seed (temp dirs only).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use axum::Router;
use memex_core::Clock;
use memex_mcp::server::error::status_for_code;
use memex_mcp::server::{router, ServerConfig};
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;

use api_fixtures::{
    api_v1_dir, bless_requested, canonical_json, load_rows, materialize_seed, normalize_volatile,
    run_rows, FixtureRequest, FixtureResponse, FixtureRow, SEED_VAULT_NAME,
};
use server::{
    assert_wrong_method_is_c1_405, client, raw_request, Reply, TestServer, PROBE_METHODS,
    TEST_TOKEN,
};

const BASE: &str = "/vaults/seed/api/v1";

/// The seed canvas, "Prototype Map" (version 3).
const CANVAS: &str = "01M5DQAYZJET989N2YR8341XAN";
/// Placed at (0, 0), z 0.
const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
/// Placed at (240.5, 120), z 0.
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
/// Not placed.
const PACING: &str = "01M5DQAYZ4YAPYMEDWXP8WCNGJ";
/// Not placed.
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
/// A valid ULID no seed canvas or note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

/// Player Loop -> Economy Design (references): an edge.
const LINK_LOOP_TO_ECONOMY: &str = "01M5DQAYZC5FQW4HVPK8ZE5SXW";
/// Economy Design -> Player Loop (extends): an edge.
const LINK_ECONOMY_TO_LOOP: &str = "01M5DQAYZFCB2T0ECN4HG7XFQM";
/// Player Loop -> "Unwritten Idea" (no target): a ghost link, never an edge.
const LINK_GHOST: &str = "01M5DQAYZCV1DXWK1CFVDNP0SS";
/// Economy Design -> 2026-10-19 (not placed): off the canvas, never an edge.
const LINK_OFF_CANVAS: &str = "01M5DQAYZFCJGDA345T48TPSH3";
/// Pacing Notes -> Player Loop: from an unplaced note, never an edge.
const LINK_FROM_UNPLACED: &str = "01M5DQAYZDBGZSDQ7X3PJT783V";

fn canvas_dir() -> PathBuf {
    api_v1_dir().join("canvas")
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// The server over one seed copy, plus a second identical seed copy for the
/// `memex` CLI.
struct Env {
    srv: TestServer,
    /// The CLI's copy: `<cli_root>/seed`.
    cli_root: TempDir,
}

impl Env {
    async fn start() -> Self {
        let root = tempfile::tempdir().unwrap();
        materialize_seed(root.path());
        let cli_root = tempfile::tempdir().unwrap();
        materialize_seed(cli_root.path());
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

    /// `METHOD <BASE><path>` with the token, raw body bytes and an optional
    /// `Content-Type`.
    async fn call_raw(
        &self,
        method: &str,
        path: &str,
        content_type: Option<&str>,
        body: &[u8],
    ) -> Reply {
        let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
        let mut req = client()
            .request(method, self.srv.url(&format!("{BASE}{path}")))
            .header("authorization", self.srv.bearer())
            .body(body.to_vec());
        if let Some(ct) = content_type {
            req = req.header("content-type", ct);
        }
        Reply::read(req.send().await.expect("send request")).await
    }

    /// `memex canvas <action> --vault <cli copy> <args…>`.
    fn cli(&self, action: &str, args: &[&str]) -> Cli {
        run_canvas_cli(&self.cli_vault(), action, args)
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

/// Runs `memex canvas <action> --vault <vault> <args…>`. Numbers go as
/// `--x=<n>` so a negative value is never read as a flag.
fn run_canvas_cli(vault: &Path, action: &str, args: &[&str]) -> Cli {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["canvas", action])
        .arg("--vault")
        .arg(vault)
        .args(args)
        .output()
        .expect("run memex");
    Cli {
        ok: out.status.success(),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    }
}

fn norm(v: &Value) -> Value {
    normalize_volatile(v)
}

fn assert_c1(reply: &Reply, status: u16, code: &str) {
    assert_eq!(
        (reply.status, reply.c1_code()),
        (status, code.to_string()),
        "body: {}",
        reply.body
    );
}

/// A read-only look at a vault's database (the server keeps its own
/// connection open; WAL lets this one read alongside).
fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

/// Every `canvases` and `canvas_nodes` row of a vault, as JSON, in a fixed
/// order: what "nothing was written" compares.
fn canvas_state(vault: &Path) -> Value {
    let conn = db(vault);
    let mut stmt = conn
        .prepare("SELECT id, title, created_at, updated_at, version FROM canvases ORDER BY id")
        .unwrap();
    let canvases: Vec<Value> = stmt
        .query_map([], |r| {
            Ok(json!([
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, i64>(4)?
            ]))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    let mut stmt = conn
        .prepare(
            "SELECT canvas_id, note_id, x, y, z_order, placed_at FROM canvas_nodes
             ORDER BY canvas_id, note_id",
        )
        .unwrap();
    let nodes: Vec<Value> = stmt
        .query_map([], |r| {
            Ok(json!([
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, f64>(2)?,
                r.get::<_, f64>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, i64>(5)?
            ]))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    json!({ "canvases": canvases, "canvas_nodes": nodes })
}

/// `(version, updated_at)` of a canvas.
fn canvas_version(vault: &Path, id: &str) -> (i64, i64) {
    db(vault)
        .query_row(
            "SELECT version, updated_at FROM canvases WHERE id = ?",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or_else(|e| panic!("no canvas {id}: {e}"))
}

// ---------------------------------------------------------------------------
// Fixture rows: executors
// ---------------------------------------------------------------------------

/// Sends one fixture row to the server, with the token unless the row names
/// an `Authorization` header.
async fn exec(srv: &TestServer, req: &FixtureRequest) -> FixtureResponse {
    let has = |name: &str| req.headers.keys().any(|k| k.eq_ignore_ascii_case(name));
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        req.method, req.path
    );
    if !has("authorization") {
        head.push_str(&format!("Authorization: {}\r\n", srv.bearer()));
    }
    if req.body.is_some() && !has("content-type") {
        head.push_str("Content-Type: application/json\r\n");
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

/// A JSON number as the CLI flag value (`--x=<n>`), printed the way
/// `serde_json` prints the `f64`.
fn number_arg(flag: &str, v: &Value) -> String {
    let n = v
        .as_f64()
        .unwrap_or_else(|| panic!("{flag} must be a number, got {v}"));
    format!("--{flag}={}", serde_json::to_string(&n).unwrap())
}

/// Runs one fixture row as the `memex canvas` command it stands for, on
/// `vault`: stdout on success (201 for `POST /canvases`, else 200), the C1
/// stderr line on failure (with the C1 code's HTTP status).
fn exec_cli(vault: &Path, req: &FixtureRequest) -> FixtureResponse {
    let path = req
        .path
        .strip_prefix(BASE)
        .unwrap_or_else(|| panic!("row path {} is not under {BASE}", req.path));
    let seg: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let body: Value = req
        .body
        .as_ref()
        .map(|b| serde_json::from_slice(b).expect("row request is JSON"))
        .unwrap_or(Value::Null);
    let s = |k: &str| {
        body[k]
            .as_str()
            .unwrap_or_else(|| panic!("{}: body has no string {k}", req.path))
            .to_string()
    };
    let (action, args, created): (&str, Vec<String>, bool) = match (req.method.as_str(), &seg[..]) {
        ("GET", ["canvases"]) => ("ls", vec![], false),
        ("GET", ["canvases", id]) => ("get", vec!["--canvas-id".into(), id.to_string()], false),
        ("POST", ["canvases"]) => ("new", vec![format!("--title={}", s("title"))], true),
        ("POST", ["canvases", id, "nodes"]) => (
            "add",
            vec![
                "--canvas-id".into(),
                id.to_string(),
                "--note-id".into(),
                s("note_id"),
                number_arg("x", &body["x"]),
                number_arg("y", &body["y"]),
            ],
            false,
        ),
        ("PATCH", ["canvases", id, "nodes", note]) => {
            let mut args = vec![
                "--canvas-id".into(),
                id.to_string(),
                "--note-id".into(),
                note.to_string(),
                number_arg("x", &body["x"]),
                number_arg("y", &body["y"]),
            ];
            if let Some(z) = body.get("z_order") {
                args.push(format!(
                    "--z={}",
                    z.as_i64().expect("z_order is an integer")
                ));
            }
            ("move", args, false)
        }
        other => panic!("no memex canvas command for {other:?}"),
    };
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let cli = run_canvas_cli(vault, action, &args);
    if cli.ok {
        FixtureResponse {
            status: if created { 201 } else { 200 },
            body: cli.stdout.trim().as_bytes().to_vec(),
        }
    } else {
        let err = cli.error();
        let code = err["error"]["code"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        FixtureResponse {
            status: status_for_code(&code).as_u16(),
            body: serde_json::to_vec(&err).unwrap(),
        }
    }
}

/// `(METHOD, path template)` of a row: ULIDs become `{id}`.
fn template(row: &FixtureRow) -> (String, String) {
    let ulid = Regex::new(r"[0-7][0-9A-HJKMNP-TV-Z]{25}").unwrap();
    let path = row
        .path
        .strip_prefix(BASE)
        .unwrap_or_else(|| panic!("row path {} is not under {BASE}", row.path));
    (
        row.method.clone(),
        ulid.replace_all(path, "{id}").into_owned(),
    )
}

/// The routes of the WI #84 table, as `(METHOD, path)` under `BASE`.
const ROUTES: &[(&str, &str)] = &[
    ("GET", "/canvases"),
    ("GET", "/canvases/{id}"),
    ("POST", "/canvases"),
    ("POST", "/canvases/{id}/nodes"),
    ("PATCH", "/canvases/{id}/nodes/{id}"),
];

// ---------------------------------------------------------------------------
// AC 1, 5, 6, 7: the fixture rows
// ---------------------------------------------------------------------------

#[test]
fn canvas_fixture_rows_are_the_memex_cli_on_a_seed_copy() {
    // The fixtures' only source: the CLI on a fresh seed copy, row by row.
    let root = tempfile::tempdir().unwrap();
    let vault = materialize_seed(root.path());
    let result = run_rows(&canvas_dir(), bless_requested(), |req| {
        exec_cli(&vault, req)
    });
    if let Err(e) = result {
        panic!("{e}");
    }
}

#[test]
fn canvas_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&canvas_dir()).expect("canvas/index.json parses");
    let seen: BTreeSet<(String, u16, String)> = rows
        .iter()
        .map(|r| {
            let (m, t) = template(r);
            (m, r.status, t)
        })
        .collect();
    for (m, status, t) in [
        ("GET", 200, "/canvases"),
        ("GET", 200, "/canvases/{id}"),
        ("GET", 404, "/canvases/{id}"),
        ("POST", 201, "/canvases"),
        ("POST", 409, "/canvases"),
        ("POST", 200, "/canvases/{id}/nodes"),
        ("POST", 404, "/canvases/{id}/nodes"),
        ("PATCH", 200, "/canvases/{id}/nodes/{id}"),
        ("PATCH", 404, "/canvases/{id}/nodes/{id}"),
    ] {
        let want = (m.to_string(), status, t.to_string());
        assert!(seen.contains(&want), "canvas/ has a row for {want:?}");
    }
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every canvas row runs in Rust"
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    // Never blessed from the server: the CLI made these rows.
    let result = run_rows(&canvas_dir(), false, |req| rt.block_on(exec(&srv, req)));
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

// ---------------------------------------------------------------------------
// AC 1: reads equal the fixtures and `memex canvas ls|get`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn list_and_get_canvas_answer_the_fixture_bytes_and_memex_canvas_ls_and_get() {
    let env = Env::start().await;
    let fixture = |name: &str| std::fs::read_to_string(canvas_dir().join(name)).unwrap();

    let list = env.call("GET", "/canvases", None).await;
    assert_eq!(list.status, 200, "{}", list.body);
    assert_eq!(canonical_json(&list.json()), fixture("list_canvases.json"));
    assert_eq!(list.json(), env.cli("ls", &[]).json(), "== memex canvas ls");
    assert!(
        list.json()["canvases"].is_array(),
        "the list is wrapped in an object"
    );

    let get = env.call("GET", &format!("/canvases/{CANVAS}"), None).await;
    assert_eq!(get.status, 200, "{}", get.body);
    assert_eq!(canonical_json(&get.json()), fixture("get_canvas.json"));
    assert_eq!(
        get.json(),
        env.cli("get", &["--canvas-id", CANVAS]).json(),
        "== memex canvas get"
    );

    // Nodes by z_order, then placed_at; edges only between placed notes.
    let v = get.json();
    let nodes: Vec<&str> = v["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["note_id"].as_str().unwrap())
        .collect();
    assert_eq!(nodes, vec![PLAYER_LOOP, ECONOMY]);
    assert_eq!(v["nodes"][1]["x"], json!(240.5));
    let edges: Vec<&str> = v["edges"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["link_id"].as_str().unwrap())
        .collect();
    assert_eq!(edges, vec![LINK_LOOP_TO_ECONOMY, LINK_ECONOMY_TO_LOOP]);
    for absent in [LINK_GHOST, LINK_OFF_CANVAS, LINK_FROM_UNPLACED] {
        assert!(!edges.contains(&absent), "{absent} is not an edge");
    }
}

// ---------------------------------------------------------------------------
// AC 4: an unknown canvas
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_canvas_for_an_unknown_id_is_c1_not_found_like_memex_canvas_get() {
    let env = Env::start().await;
    let reply = env.call("GET", &format!("/canvases/{UNKNOWN}"), None).await;
    assert_c1(&reply, 404, "not_found");
    let cli = env.cli("get", &["--canvas-id", UNKNOWN]);
    assert_eq!(reply.json(), cli.error(), "the CLI's not_found body");

    // An id that isn't a ULID gets the CLI's own error body too.
    let reply = env.call("GET", "/canvases/not-a-ulid", None).await;
    let cli = env.cli("get", &["--canvas-id", "not-a-ulid"]);
    assert_eq!(reply.json(), cli.error(), "the CLI's body for a bad id");
    assert_eq!(
        reply.status,
        status_for_code(&reply.c1_code()).as_u16(),
        "the status follows the C1 code"
    );
}

// ---------------------------------------------------------------------------
// AC 5: create
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_canvas_answers_like_memex_canvas_new_and_a_used_title_is_title_conflict() {
    let env = Env::start().await;
    let reply = env
        .call("POST", "/canvases", Some(&json!({"title": "Level Flow"})))
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let cli = env.cli("new", &["--title", "Level Flow"]);
    assert_eq!(
        norm(&reply.json()),
        norm(&cli.json()),
        "== memex canvas new"
    );
    let created = reply.json();
    let new_id = created["canvas_id"].as_str().unwrap().to_string();
    assert_eq!(created["version"], 1);
    assert_eq!(created["title"], "Level Flow");

    // The new canvas is stored and listed.
    let list = env.call("GET", "/canvases", None).await.json();
    let ids: Vec<&str> = list["canvases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["canvas_id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&new_id.as_str()), "{ids:?}");
    assert_eq!(canvas_version(&env.server_vault(), &new_id).0, 1);

    // A used title: the seed's, and the one just made.
    for (title, existing) in [("Prototype Map", CANVAS), ("Level Flow", new_id.as_str())] {
        let before = canvas_state(&env.server_vault());
        let reply = env
            .call("POST", "/canvases", Some(&json!({"title": title})))
            .await;
        assert_c1(&reply, 409, "title_conflict");
        assert_eq!(reply.json()["error"]["existing_id"], existing, "{title}");
        assert_eq!(canvas_state(&env.server_vault()), before, "nothing written");
    }
    let cli = env.cli("new", &["--title", "Prototype Map"]);
    let reply = env
        .call(
            "POST",
            "/canvases",
            Some(&json!({"title": "Prototype Map"})),
        )
        .await;
    assert_eq!(reply.json(), cli.error(), "the CLI's title_conflict body");
}

// ---------------------------------------------------------------------------
// AC 6: add to canvas
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_node_answers_like_memex_canvas_add_and_a_placed_note_keeps_its_placement() {
    let env = Env::start().await;
    let nodes = format!("/canvases/{CANVAS}/nodes");
    let reply = env
        .call(
            "POST",
            &nodes,
            Some(&json!({"note_id": PACING, "x": 123.456789, "y": -64.5})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        "add",
        &[
            "--canvas-id",
            CANVAS,
            "--note-id",
            PACING,
            "--x=123.456789",
            "--y=-64.5",
        ],
    );
    assert_eq!(
        norm(&reply.json()),
        norm(&cli.json()),
        "== memex canvas add"
    );
    assert_eq!(canvas_version(&env.server_vault(), CANVAS).0, 4, "3 -> 4");

    // Placing an already placed note returns the existing placement and
    // leaves the canvas version alone.
    let before = canvas_state(&env.server_vault());
    let get_before = env.call("GET", &format!("/canvases/{CANVAS}"), None).await;
    let reply = env
        .call(
            "POST",
            &nodes,
            Some(&json!({"note_id": PLAYER_LOOP, "x": 999.0, "y": 999.0})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(
        (&v["x"], &v["y"], &v["z_order"], &v["placed_at"]),
        (
            &json!(0.0),
            &json!(0.0),
            &json!(0),
            &json!(1760000840000_i64)
        ),
        "the existing placement"
    );
    let cli = env.cli(
        "add",
        &[
            "--canvas-id",
            CANVAS,
            "--note-id",
            PLAYER_LOOP,
            "--x=999.0",
            "--y=999.0",
        ],
    );
    assert_eq!(
        reply.json(),
        cli.json(),
        "== memex canvas add on a placed note"
    );
    assert_eq!(canvas_state(&env.server_vault()), before, "nothing written");
    let get_after = env.call("GET", &format!("/canvases/{CANVAS}"), None).await;
    assert_eq!(get_after.json()["version"], get_before.json()["version"]);

    // Unknown canvas or note: the CLI's not_found.
    for (canvas, note) in [(UNKNOWN, PACING), (CANVAS, UNKNOWN)] {
        let reply = env
            .call(
                "POST",
                &format!("/canvases/{canvas}/nodes"),
                Some(&json!({"note_id": note, "x": 1.0, "y": 2.0})),
            )
            .await;
        assert_c1(&reply, 404, "not_found");
        let cli = env.cli(
            "add",
            &[
                "--canvas-id",
                canvas,
                "--note-id",
                note,
                "--x=1.0",
                "--y=2.0",
            ],
        );
        assert_eq!(reply.json(), cli.error(), "{canvas} / {note}");
    }
    assert_eq!(canvas_state(&env.server_vault()), before, "nothing written");
}

// ---------------------------------------------------------------------------
// AC 7: move
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn move_node_answers_like_memex_canvas_move_with_and_without_z_order() {
    let env = Env::start().await;
    let at = |note: &str| format!("/canvases/{CANVAS}/nodes/{note}");

    // With z_order.
    let reply = env
        .call(
            "PATCH",
            &at(PLAYER_LOOP),
            Some(&json!({"x": -12.5, "y": 48.0, "z_order": 3})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        "move",
        &[
            "--canvas-id",
            CANVAS,
            "--note-id",
            PLAYER_LOOP,
            "--x=-12.5",
            "--y=48.0",
            "--z=3",
        ],
    );
    assert_eq!(reply.json(), cli.json(), "== memex canvas move --z");
    assert_eq!(reply.json()["z_order"], 3);
    assert!(
        reply.json().get("placed_at").is_none(),
        "no placed_at, like the CLI"
    );

    // Without z_order the node keeps its z (3, set above).
    let reply = env
        .call(
            "PATCH",
            &at(PLAYER_LOOP),
            Some(&json!({"x": 5.25, "y": 6.0})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        "move",
        &[
            "--canvas-id",
            CANVAS,
            "--note-id",
            PLAYER_LOOP,
            "--x=5.25",
            "--y=6.0",
        ],
    );
    assert_eq!(reply.json(), cli.json(), "== memex canvas move");
    assert_eq!(reply.json()["z_order"], 3, "omitted z_order keeps z");
    assert_eq!(
        (reply.json()["x"].clone(), reply.json()["y"].clone()),
        (json!(5.25), json!(6.0))
    );
    assert_eq!(
        canvas_version(&env.server_vault(), CANVAS).0,
        5,
        "each move bumps the version: 3 -> 5"
    );

    // A note that isn't on the canvas, and an unknown canvas.
    let before = canvas_state(&env.server_vault());
    for (canvas, note) in [(CANVAS, LOOSE), (UNKNOWN, ECONOMY)] {
        let reply = env
            .call(
                "PATCH",
                &format!("/canvases/{canvas}/nodes/{note}"),
                Some(&json!({"x": 1.0, "y": 2.0})),
            )
            .await;
        assert_c1(&reply, 404, "not_found");
        let cli = env.cli(
            "move",
            &[
                "--canvas-id",
                canvas,
                "--note-id",
                note,
                "--x=1.0",
                "--y=2.0",
            ],
        );
        assert_eq!(reply.json(), cli.error(), "{canvas} / {note}");
    }
    assert_eq!(canvas_state(&env.server_vault()), before, "nothing written");
}

// ---------------------------------------------------------------------------
// Risk: x and y are f64 end to end
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn coordinates_stay_f64_from_request_to_store_to_response() {
    let env = Env::start().await;
    let (x, y) = (1234.5678901234567_f64, -0.000123_f64);
    let reply = env
        .call(
            "POST",
            &format!("/canvases/{CANVAS}/nodes"),
            Some(&json!({"note_id": PACING, "x": x, "y": y})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["x"].as_f64(), Some(x));
    assert_eq!(reply.json()["y"].as_f64(), Some(y));
    let stored: (f64, f64) = db(&env.server_vault())
        .query_row(
            "SELECT x, y FROM canvas_nodes WHERE canvas_id = ? AND note_id = ?",
            params![CANVAS, PACING],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(stored, (x, y), "stored exactly");
    let get = env
        .call("GET", &format!("/canvases/{CANVAS}"), None)
        .await
        .json();
    let node = get["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["note_id"] == PACING)
        .unwrap()
        .clone();
    assert_eq!((node["x"].as_f64(), node["y"].as_f64()), (Some(x), Some(y)));

    // A whole-number coordinate is accepted and answered as a float.
    let reply = env
        .call(
            "PATCH",
            &format!("/canvases/{CANVAS}/nodes/{PACING}"),
            Some(&json!({"x": 12, "y": -7})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert!(reply.json()["x"].is_f64(), "{}", reply.body);
    assert_eq!(reply.json()["x"].as_f64(), Some(12.0));
    assert_eq!(reply.json()["y"].as_f64(), Some(-7.0));
    // A fractional move survives too (no integer round trip).
    let reply = env
        .call(
            "PATCH",
            &format!("/canvases/{CANVAS}/nodes/{PACING}"),
            Some(&json!({"x": 0.1, "y": 2.675})),
        )
        .await;
    assert_eq!(reply.json()["x"].as_f64(), Some(0.1));
    assert_eq!(reply.json()["y"].as_f64(), Some(2.675));
}

// ---------------------------------------------------------------------------
// AC 8: malformed requests
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_canvas_bodies_get_400_invalid_argument_and_write_nothing() {
    let env = Env::start().await;
    let canvases = "/canvases".to_string();
    let nodes = format!("/canvases/{CANVAS}/nodes");
    let node = format!("/canvases/{CANVAS}/nodes/{ECONOMY}");
    let json_ct = Some("application/json");
    let b = |s: String| s.into_bytes();
    let cases: Vec<(&str, &String, Option<&str>, Vec<u8>)> = vec![
        // POST /canvases
        ("POST", &canvases, json_ct, b(r#"{"title": "#.into())),
        ("POST", &canvases, json_ct, b("not json".into())),
        ("POST", &canvases, json_ct, b("[]".into())),
        ("POST", &canvases, json_ct, b("{}".into())),
        ("POST", &canvases, json_ct, b("".into())),
        ("POST", &canvases, json_ct, b(r#"{"title": 7}"#.into())),
        ("POST", &canvases, json_ct, b(r#"{"title": null}"#.into())),
        (
            "POST",
            &canvases,
            json_ct,
            b(r#"{"name": "Level Flow"}"#.into()),
        ),
        (
            "POST",
            &canvases,
            None,
            b(r#"{"title": "Level Flow"}"#.into()),
        ),
        // POST /canvases/{id}/nodes
        ("POST", &nodes, json_ct, b(r#"{"note_id": "#.into())),
        ("POST", &nodes, json_ct, b("{}".into())),
        ("POST", &nodes, json_ct, b(r#"{"x": 1.0, "y": 2.0}"#.into())),
        (
            "POST",
            &nodes,
            json_ct,
            b(format!(r#"{{"note_id": "{PACING}", "y": 2.0}}"#)),
        ),
        (
            "POST",
            &nodes,
            json_ct,
            b(format!(r#"{{"note_id": "{PACING}", "x": 1.0}}"#)),
        ),
        (
            "POST",
            &nodes,
            json_ct,
            b(format!(
                r#"{{"note_id": "{PACING}", "x": "1.0", "y": 2.0}}"#
            )),
        ),
        (
            "POST",
            &nodes,
            json_ct,
            b(format!(r#"{{"note_id": "{PACING}", "x": 1.0, "y": true}}"#)),
        ),
        (
            "POST",
            &nodes,
            json_ct,
            b(format!(r#"{{"note_id": "{PACING}", "x": null, "y": 2.0}}"#)),
        ),
        (
            "POST",
            &nodes,
            json_ct,
            b(r#"{"note_id": 7, "x": 1.0, "y": 2.0}"#.into()),
        ),
        (
            "POST",
            &nodes,
            None,
            b(format!(r#"{{"note_id": "{PACING}", "x": 1.0, "y": 2.0}}"#)),
        ),
        // PATCH /canvases/{id}/nodes/{note_id}
        ("PATCH", &node, json_ct, b(r#"{"x": "#.into())),
        ("PATCH", &node, json_ct, b("{}".into())),
        ("PATCH", &node, json_ct, b(r#"{"y": 2.0}"#.into())),
        ("PATCH", &node, json_ct, b(r#"{"x": 1.0}"#.into())),
        ("PATCH", &node, json_ct, b(r#"{"x": "1", "y": 2.0}"#.into())),
        ("PATCH", &node, json_ct, b(r#"{"x": 1.0, "y": [2]}"#.into())),
        (
            "PATCH",
            &node,
            json_ct,
            b(r#"{"x": 1.0, "y": 2.0, "z_order": "3"}"#.into()),
        ),
        (
            "PATCH",
            &node,
            json_ct,
            b(r#"{"x": 1.0, "y": 2.0, "z_order": 1.5}"#.into()),
        ),
        ("PATCH", &node, None, b(r#"{"x": 1.0, "y": 2.0}"#.into())),
    ];
    for (method, path, ct, body) in &cases {
        let reply = env.call_raw(method, path, *ct, body).await;
        assert_eq!(
            (reply.status, reply.c1_code()),
            (400, "invalid_argument".to_string()),
            "{method} {path} {ct:?} {}: {}",
            String::from_utf8_lossy(body),
            reply.body
        );
    }
    assert_eq!(
        canvas_state(&env.server_vault()),
        canvas_state(&env.cli_vault()),
        "no malformed request wrote anything"
    );
}

// ---------------------------------------------------------------------------
// AC 9: 401 without a token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_canvas_route_answers_401_unauthorized_without_a_bearer_token() {
    let env = Env::start().await;
    let rows = load_rows(&canvas_dir()).expect("canvas/index.json parses");
    let routes: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    assert_eq!(routes.len(), ROUTES.len(), "every route has a row");
    for row in &rows {
        let method = reqwest::Method::from_bytes(row.method.as_bytes()).unwrap();
        let body = row
            .request
            .as_ref()
            .map(|f| std::fs::read(canvas_dir().join(f)).unwrap())
            .unwrap_or_default();
        let send = |auth: Option<String>| {
            let mut req = client()
                .request(method.clone(), env.srv.url(&row.path))
                .header("content-type", "application/json")
                .body(body.clone());
            if let Some(a) = auth {
                req = req.header("authorization", a);
            }
            req
        };
        for auth in [None, Some("Bearer not-the-token".to_string())] {
            let reply = Reply::read(send(auth.clone()).send().await.unwrap()).await;
            assert_eq!(
                (reply.status, reply.c1_code()),
                (401, "unauthorized".to_string()),
                "{} {} with {auth:?}",
                row.method,
                row.path
            );
            assert!(!reply.body.contains(TEST_TOKEN));
        }
        // Only reads are replayed with the token: the route exists.
        if row.method == "GET" {
            let reply = Reply::read(send(Some(env.srv.bearer())).send().await.unwrap()).await;
            assert_eq!(
                reply.status, row.status,
                "{} {} with the token: {}",
                row.method, row.path, reply.body
            );
        }
    }
    assert_eq!(
        canvas_state(&env.server_vault()),
        canvas_state(&env.cli_vault()),
        "nothing was written without the token"
    );
}

// ---------------------------------------------------------------------------
// AC 11: the route inventory
// ---------------------------------------------------------------------------

#[test]
fn canvas_index_routes_are_exactly_the_wi_table_and_take_no_sql_or_argv() {
    let rows = load_rows(&canvas_dir()).expect("canvas/index.json parses");
    let served: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    let table: BTreeSet<(String, String)> = ROUTES
        .iter()
        .map(|(m, p)| (m.to_string(), p.to_string()))
        .collect();
    assert_eq!(
        served, table,
        "canvas/index.json routes == the WI #84 table"
    );
    for row in &rows {
        assert!(!row.path.contains('?'), "{}: no query", row.path);
        if let Some(file) = &row.request {
            let body: Value =
                serde_json::from_slice(&std::fs::read(canvas_dir().join(file)).unwrap()).unwrap();
            let obj = body.as_object().expect("every request body is an object");
            let allowed: &[&str] = match template(row).1.as_str() {
                "/canvases" => &["title"],
                "/canvases/{id}/nodes" => &["note_id", "x", "y"],
                "/canvases/{id}/nodes/{id}" => &["x", "y", "z_order"],
                other => panic!("{file}: a body on {other}"),
            };
            for key in obj.keys() {
                assert!(allowed.contains(&key.as_str()), "{file}: field {key}");
            }
        }
    }
}

/// Serves only `api::canvas::router()`, nested where the server nests it,
/// with no vault guard: a served route answers anything but 404 and 405.
async fn serve_canvas_router_alone() -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let app = Router::new().nest(
        "/vaults/{name}/api/v1",
        memex_mcp::server::api::canvas::router(),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (addr, task)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn canvas_router_serves_exactly_the_table_routes_and_no_rename_delete_or_remove() {
    let (addr, task) = serve_canvas_router_alone().await;
    let http = client();
    let concrete = |p: &str| p.replacen("{id}", CANVAS, 1).replacen("{id}", ECONOMY, 1);
    let paths: BTreeSet<&str> = ROUTES.iter().map(|(_, p)| *p).collect();
    for path in paths {
        for method in PROBE_METHODS {
            let served = ROUTES.iter().any(|(m, p)| *p == path && *m == method);
            let url = format!("http://{addr}{BASE}{}", concrete(path));
            let req = http
                .request(
                    reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                    &url,
                )
                .header("content-type", "application/json")
                .body("{}");
            let status = req.send().await.unwrap().status().as_u16();
            if served {
                assert!(
                    status != 404 && status != 405,
                    "{method} {path} is a canvas route (got {status})"
                );
            } else {
                assert_eq!(status, 405, "{method} {path} is not a canvas route");
            }
        }
    }
    // No rename, delete, remove-node or batch route under another path.
    for path in [
        format!("/canvases/{CANVAS}/rename"),
        format!("/canvases/{CANVAS}/title"),
        format!("/canvases/{CANVAS}/delete"),
        format!("/canvases/{CANVAS}/edges"),
        format!("/canvases/{CANVAS}/nodes/{ECONOMY}/remove"),
        format!("/canvases/{CANVAS}/nodes/{ECONOMY}/move"),
        "/canvas".to_string(),
        "/canvases/ls".to_string(),
    ] {
        for method in ["GET", "POST", "PATCH", "DELETE"] {
            let url = format!("http://{addr}{BASE}{path}");
            let req = http.request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                &url,
            );
            let status = req.send().await.unwrap().status().as_u16();
            // `/canvases/ls` is `/canvases/{canvas_id}`: GET is served
            // there (the id just isn't a ULID), every other method is not.
            if path == "/canvases/ls" && method == "GET" {
                continue;
            }
            assert!(
                status == 404 || status == 405,
                "{method} {path} has no canvas route (got {status})"
            );
        }
    }
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn canvas_routes_answer_wrong_methods_with_the_c1_405() {
    let env = Env::start().await;
    let list = format!("{BASE}/canvases");
    let one = format!("{BASE}/canvases/{CANVAS}");
    let nodes = format!("{BASE}/canvases/{CANVAS}/nodes");
    let node = format!("{BASE}/canvases/{CANVAS}/nodes/{ECONOMY}");
    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (list.as_str(), &["GET", "POST"][..]),
            // No rename (PATCH/PUT) or delete on a canvas.
            (one.as_str(), &["GET"][..]),
            (nodes.as_str(), &["POST"][..]),
            // No remove-node (DELETE) on a placement.
            (node.as_str(), &["PATCH"][..]),
        ],
    )
    .await;
    assert_eq!(
        canvas_state(&env.server_vault()),
        canvas_state(&env.cli_vault()),
        "the probes wrote nothing"
    );
}

// ---------------------------------------------------------------------------
// Handler convention: writes are stamped by the request clock
// ---------------------------------------------------------------------------

/// A clock stopped at one instant.
struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn canvas_writes_are_stamped_by_the_server_request_clock() {
    const NOW: i64 = 1_770_000_123_456;
    let root = tempfile::tempdir().unwrap();
    let vault = materialize_seed(root.path());
    let config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN)
        .with_clock(Arc::new(FixedClock(NOW)));
    let app = router(config);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let send = |method: &str, path: &str, body: Value| {
        let url = format!("http://{addr}{BASE}{path}");
        let req = client()
            .request(reqwest::Method::from_bytes(method.as_bytes()).unwrap(), url)
            .header("authorization", format!("Bearer {TEST_TOKEN}"))
            .json(&body);
        async move { Reply::read(req.send().await.unwrap()).await }
    };

    let created = send("POST", "/canvases", json!({"title": "Clocked"})).await;
    assert_eq!(created.status, 201, "{}", created.body);
    assert_eq!(created.json()["created_at"], NOW);
    assert_eq!(created.json()["updated_at"], NOW);

    let added = send(
        "POST",
        &format!("/canvases/{CANVAS}/nodes"),
        json!({"note_id": PACING, "x": 1.0, "y": 2.0}),
    )
    .await;
    assert_eq!(added.status, 200, "{}", added.body);
    assert_eq!(added.json()["placed_at"], NOW);

    // The seed canvas was last updated at 1760000900000.
    let conn = Connection::open(vault.join("memex.db")).unwrap();
    conn.execute(
        "UPDATE canvases SET updated_at = 1 WHERE id = ?",
        params![CANVAS],
    )
    .unwrap();
    drop(conn);
    let moved = send(
        "PATCH",
        &format!("/canvases/{CANVAS}/nodes/{ECONOMY}"),
        json!({"x": 3.0, "y": 4.0}),
    )
    .await;
    assert_eq!(moved.status, 200, "{}", moved.body);
    assert_eq!(
        canvas_version(&vault, CANVAS).1,
        NOW,
        "move stamps updated_at"
    );
    task.abort();
}
