//! WI #83 (V3): Smart Folders, unsorted, vault settings and the review
//! prompt over the app API, Rust half.
//!
//! The topics routes under `/vaults/{name}/api/v1`, served by the in-process
//! vault server (`127.0.0.1:0`) over #74's frozen seed:
//!
//! | Route | Response |
//! |---|---|
//! | `GET /smart-folders` | `{"max_depth":n,"folders":[{id,name,parent_id,pinned}],"members":[{folder_id,note_id,title,pinned}]}` |
//! | `GET /unsorted` | `{"notes":[{note_id,title,role}]}` |
//! | `GET /settings/{key}` | `{vault_id,key,value}` (`memex settings get`) |
//! | `PUT /settings/{key} {"value":n}` | `{vault_id,key,value}` (`memex settings set`) |
//! | `POST /smart-folders {name,parent_id?}` | 201, the `memex folder new` object |
//! | `PATCH /smart-folders/{id} {name?,parent_id?,to_root?,pinned?}` | the `memex folder update` object |
//! | `DELETE /smart-folders/{id}` | `{vault_id,id,deleted}` (`memex folder rm`) |
//! | `POST /smart-folders/{id}/members {note_id,pinned?}` | `{vault_id,smart_folder_id,note_id,pinned,role_set}` (`memex folder add`) |
//! | `GET /prompts/review` | `{"text":…}` (`memex prompt review` stdout) |
//!
//! Folders come by `id`, members by `folder_id` then `note_id`, unsorted
//! notes by `note_id`. Errors are the C1 body the CLI prints for the same
//! failure; a malformed body or a missing `name` / `note_id` / `value` is
//! C1 `invalid_argument` (400).
//!
//! The rows of `app/test/fixtures/api_v1/topics/index.json` were made from
//! the app's own local reads (`TopicsReads` on `seededFakeVaultDb()`) and
//! from the `memex` CLI on a copy of the seed, then frozen: never rebless
//! them to fit the server. Every CLI parity test runs the real `memex`
//! binary on a second copy of the seed (temp dirs only).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;

use memex_core::Clock;
use memex_mcp::server::request_clock::SharedClock;
use memex_mcp::server::{router, ServerConfig};
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, normalize_volatile, run_rows,
    FixtureRequest, FixtureResponse, FixtureRow, SEED_VAULT_NAME,
};
use server::{assert_wrong_method_is_c1_405, client, raw_request, Reply, TestServer, TEST_TOKEN};

const BASE: &str = "/vaults/seed/api/v1";

/// Root, pinned.
const DESIGN: &str = "01M5DQAYZHJGKWXCJHR5FSDFA0";
/// Inside Design, unpinned; members Economy Design and Pacing Notes.
const SYSTEMS: &str = "01M5DQAYZHE33BZ4NA4H5YSBJD";
/// Root, unpinned, no members.
const INBOX: &str = "01M5DQAYZHJTTW6PPF4P7GNCHN";
const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
const PACING: &str = "01M5DQAYZ4YAPYMEDWXP8WCNGJ";
/// Role-less (`{}`), in no folder.
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
/// Invalid-JSON frontmatter, in no folder.
const BROKEN: &str = "01M5DQAYZ5RH88SRZGPY15XXVM";
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
/// A valid ULID no seed row has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";
const MAX_DEPTH: &str = "smart_folder_max_depth";

fn topics_dir() -> PathBuf {
    api_v1_dir().join("topics")
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
        call_at(self.srv.addr(), method, path, body).await
    }

    /// `METHOD <BASE><path>` with the token and raw body bytes sent as JSON.
    async fn call_raw(&self, method: &str, path: &str, body: &[u8]) -> Reply {
        let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
        let req = client()
            .request(method, self.srv.url(&format!("{BASE}{path}")))
            .header("authorization", self.srv.bearer())
            .header("content-type", "application/json")
            .body(body.to_vec());
        Reply::read(req.send().await.expect("send request")).await
    }

    /// Runs `memex <a> <b> --vault <cli copy> <rest…>`.
    fn cli(&self, sub: [&str; 2], rest: &[&str]) -> Cli {
        let vault = self.cli_vault();
        let mut args: Vec<String> = vec![sub[0].into(), sub[1].into(), "--vault".into()];
        args.push(vault.to_string_lossy().into_owned());
        args.extend(rest.iter().map(|s| s.to_string()));
        run_cli(&args)
    }
}

async fn call_at(addr: SocketAddr, method: &str, path: &str, body: Option<&Value>) -> Reply {
    let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap();
    let mut req = client()
        .request(method, format!("http://{addr}{BASE}{path}"))
        .header("authorization", format!("Bearer {TEST_TOKEN}"));
    if let Some(body) = body {
        req = req.json(body);
    }
    Reply::read(req.send().await.expect("send request")).await
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

fn run_cli(args: &[String]) -> Cli {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::null())
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

/// A read-only look at a vault's database (WAL lets it read alongside the
/// server's own connection).
fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

/// `(name, parent name, pinned)` of every folder, by name.
fn folder_tree(vault: &Path) -> Vec<(String, Option<String>, bool)> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare(
            "SELECT f.name, (SELECT p.name FROM smart_folders p WHERE p.id = f.parent_id), f.pinned
             FROM smart_folders f ORDER BY f.name",
        )
        .unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// `(folder name, note title, pinned)` of every membership, sorted.
fn memberships(vault: &Path) -> Vec<(String, String, bool)> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare(
            "SELECT f.name, n.title, m.pinned FROM smart_folder_members m
             JOIN smart_folders f ON f.id = m.smart_folder_id
             JOIN notes n ON n.id = m.note_id ORDER BY f.name, n.title",
        )
        .unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn frontmatter_of(vault: &Path, id: &str) -> String {
    db(vault)
        .query_row(
            "SELECT frontmatter FROM notes WHERE id = ?",
            params![id],
            |r| r.get(0),
        )
        .unwrap()
}

fn folder_count(vault: &Path) -> i64 {
    db(vault)
        .query_row("SELECT COUNT(*) FROM smart_folders", [], |r| r.get(0))
        .unwrap()
}

fn assert_c1(reply: &Reply, status: u16, code: &str) {
    assert_eq!(
        (reply.status, reply.c1_code()),
        (status, code.to_string()),
        "body: {}",
        reply.body
    );
}

/// The vault server over `root` with `clock` as its base clock.
async fn start_with_clock(root: &Path, clock: SharedClock) -> SocketAddr {
    let config = ServerConfig::new(root.to_path_buf(), TEST_TOKEN)
        .with_embeddings(false)
        .with_clock(clock);
    let app = router(config);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve");
    });
    addr
}

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

// ---------------------------------------------------------------------------
// AC 1 (and every write row): the fixture rows
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

/// `(METHOD, path template)` of a row: ULIDs become `{id}` and the setting
/// key `{key}`.
fn template(row: &FixtureRow) -> (String, String) {
    let ulid = Regex::new(r"[0-7][0-9A-HJKMNP-TV-Z]{25}").unwrap();
    let path = row
        .path
        .strip_prefix(BASE)
        .unwrap_or_else(|| panic!("row path {} is not under {BASE}", row.path));
    assert!(
        !path.contains('?'),
        "{}: topics routes take no query",
        row.path
    );
    let mut t = ulid.replace_all(path, "{id}").into_owned();
    if let Some(rest) = t.strip_prefix("/settings/") {
        assert!(!rest.contains('/'), "{}", row.path);
        t = "/settings/{key}".to_string();
    }
    (row.method.clone(), t)
}

/// The routes of the WI #83 table, as `(METHOD, path)` under `BASE`.
const ROUTES: &[(&str, &str)] = &[
    ("GET", "/smart-folders"),
    ("GET", "/unsorted"),
    ("GET", "/settings/{key}"),
    ("PUT", "/settings/{key}"),
    ("POST", "/smart-folders"),
    ("PATCH", "/smart-folders/{id}"),
    ("DELETE", "/smart-folders/{id}"),
    ("POST", "/smart-folders/{id}/members"),
    ("GET", "/prompts/review"),
];

fn response_json(row: &FixtureRow) -> Value {
    serde_json::from_slice(&std::fs::read(topics_dir().join(&row.response)).unwrap()).unwrap()
}

#[test]
fn topics_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&topics_dir()).expect("topics/index.json parses");
    let seen: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    for (m, p) in ROUTES {
        let want = (m.to_string(), p.to_string());
        assert!(seen.contains(&want), "topics/ has a row for {want:?}");
    }
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every topics row runs in Rust"
    );
    // The first row is the seed's Smart Folders: the pinned Design, the
    // unpinned nested Systems, and max_depth 2 from the default.
    let first = response_json(&rows[0]);
    assert_eq!(rows[0].path, format!("{BASE}/smart-folders"));
    assert_eq!(first["max_depth"], 2);
    let folders = first["folders"].as_array().unwrap();
    assert!(folders
        .iter()
        .any(|f| f["id"] == DESIGN && f["pinned"] == true && f["parent_id"].is_null()));
    assert!(folders
        .iter()
        .any(|f| f["id"] == SYSTEMS && f["pinned"] == false && f["parent_id"] == DESIGN));
    // Both role-less seed notes are unsorted.
    let unsorted = response_json(&rows[1]);
    assert_eq!(rows[1].path, format!("{BASE}/unsorted"));
    assert_eq!(
        unsorted,
        json!({"notes": [
            {"note_id": LOOSE, "title": "Loose Thought", "role": null},
            {"note_id": BROKEN, "title": "Broken Frontmatter", "role": null},
        ]})
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&topics_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_smart_folders_reports_max_depth_2_when_the_vault_has_no_setting_row() {
    let env = Env::start().await;
    for vault in [env.server_vault(), env.cli_vault()] {
        let deleted = db(&vault)
            .execute(
                "DELETE FROM vault_settings WHERE key = ?",
                params![MAX_DEPTH],
            )
            .unwrap();
        assert_eq!(deleted, 1, "the schema writes the default row");
    }
    let reply = env.call("GET", "/smart-folders", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["max_depth"], 2);
    let reply = env
        .call("GET", &format!("/settings/{MAX_DEPTH}"), None)
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(["settings", "get"], &["--key", MAX_DEPTH]);
    assert_eq!(
        reply.json(),
        cli.json(),
        "GET /settings == memex settings get"
    );
    assert_eq!(reply.json()["value"], 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_smart_folders_is_the_app_read_not_the_folder_ls_struct() {
    let env = Env::start().await;
    let reply = env.call("GET", "/smart-folders", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    let keys: BTreeSet<&str> = v.as_object().unwrap().keys().map(|k| k.as_str()).collect();
    assert_eq!(keys, BTreeSet::from(["folders", "max_depth", "members"]));
    for f in v["folders"].as_array().unwrap() {
        let keys: BTreeSet<&str> = f.as_object().unwrap().keys().map(|k| k.as_str()).collect();
        assert_eq!(keys, BTreeSet::from(["id", "name", "parent_id", "pinned"]));
    }
    for m in v["members"].as_array().unwrap() {
        let keys: BTreeSet<&str> = m.as_object().unwrap().keys().map(|k| k.as_str()).collect();
        assert_eq!(
            keys,
            BTreeSet::from(["folder_id", "note_id", "pinned", "title"])
        );
    }
    // Folders by id, members by folder then note.
    let ids: Vec<&str> = v["folders"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![SYSTEMS, DESIGN, INBOX]);
    let members: Vec<(&str, &str)> = v["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            (
                m["folder_id"].as_str().unwrap(),
                m["note_id"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        members,
        vec![(SYSTEMS, ECONOMY), (SYSTEMS, PACING), (DESIGN, PLAYER_LOOP)]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_unsorted_lists_the_role_less_seed_notes_and_no_daily_note() {
    let env = Env::start().await;
    let reply = env.call("GET", "/unsorted", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let ids: Vec<String> = reply.json()["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["note_id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids, vec![LOOSE, BROKEN]);
    assert!(!ids.contains(&DAY_18.to_string()), "no daily note");
}

// ---------------------------------------------------------------------------
// AC 5: folder writes answer like the CLI
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn folder_writes_answer_like_memex_folder_on_identical_seed_copies() {
    let env = Env::start().await;
    struct Step {
        method: &'static str,
        path: String,
        body: Option<Value>,
        status: u16,
        cli: ([&'static str; 2], Vec<String>),
    }
    let s = |v: &str| v.to_string();
    let steps = vec![
        Step {
            method: "POST",
            path: s("/smart-folders"),
            body: Some(json!({"name": "Mechanics"})),
            status: 201,
            cli: (["folder", "new"], vec![s("--name"), s("Mechanics")]),
        },
        Step {
            method: "POST",
            path: s("/smart-folders"),
            body: Some(json!({"name": "Combat", "parent_id": DESIGN})),
            status: 201,
            cli: (
                ["folder", "new"],
                vec![s("--name"), s("Combat"), s("--parent-id"), s(DESIGN)],
            ),
        },
        // Rename: a person rename pins the unpinned Inbox.
        Step {
            method: "PATCH",
            path: format!("/smart-folders/{INBOX}"),
            body: Some(json!({"name": "Later"})),
            status: 200,
            cli: (
                ["folder", "update"],
                vec![s("--id"), s(INBOX), s("--name"), s("Later")],
            ),
        },
        Step {
            method: "PATCH",
            path: format!("/smart-folders/{INBOX}"),
            body: Some(json!({"pinned": false})),
            status: 200,
            cli: (
                ["folder", "update"],
                vec![s("--id"), s(INBOX), s("--pinned"), s("false")],
            ),
        },
        // Move under a parent.
        Step {
            method: "PATCH",
            path: format!("/smart-folders/{INBOX}"),
            body: Some(json!({"parent_id": DESIGN})),
            status: 200,
            cli: (
                ["folder", "update"],
                vec![s("--id"), s(INBOX), s("--parent-id"), s(DESIGN)],
            ),
        },
        Step {
            method: "PATCH",
            path: format!("/smart-folders/{INBOX}"),
            body: Some(json!({"to_root": true, "pinned": false})),
            status: 200,
            cli: (
                ["folder", "update"],
                vec![
                    s("--id"),
                    s(INBOX),
                    s("--to-root"),
                    s("--pinned"),
                    s("false"),
                ],
            ),
        },
        Step {
            method: "PATCH",
            path: format!("/smart-folders/{INBOX}"),
            body: Some(json!({"pinned": true})),
            status: 200,
            cli: (
                ["folder", "update"],
                vec![s("--id"), s(INBOX), s("--pinned"), s("true")],
            ),
        },
        // Rename with an explicit unpin keeps it unpinned.
        Step {
            method: "PATCH",
            path: format!("/smart-folders/{SYSTEMS}"),
            body: Some(json!({"name": "Mechanisms", "pinned": false})),
            status: 200,
            cli: (
                ["folder", "update"],
                vec![
                    s("--id"),
                    s(SYSTEMS),
                    s("--name"),
                    s("Mechanisms"),
                    s("--pinned"),
                    s("false"),
                ],
            ),
        },
        Step {
            method: "POST",
            path: format!("/smart-folders/{INBOX}/members"),
            body: Some(json!({"note_id": LOOSE})),
            status: 200,
            cli: (
                ["folder", "add"],
                vec![s("--id"), s(INBOX), s("--note-id"), s(LOOSE)],
            ),
        },
        Step {
            method: "POST",
            path: format!("/smart-folders/{DESIGN}/members"),
            body: Some(json!({"note_id": PLAYER_LOOP, "pinned": false})),
            status: 200,
            cli: (
                ["folder", "add"],
                vec![
                    s("--id"),
                    s(DESIGN),
                    s("--note-id"),
                    s(PLAYER_LOOP),
                    s("--pinned"),
                    s("false"),
                ],
            ),
        },
        Step {
            method: "DELETE",
            path: format!("/smart-folders/{SYSTEMS}"),
            body: None,
            status: 200,
            cli: (["folder", "rm"], vec![s("--id"), s(SYSTEMS)]),
        },
    ];
    for step in &steps {
        let what = format!("{} {}", step.method, step.path);
        let reply = env.call(step.method, &step.path, step.body.as_ref()).await;
        assert_eq!(reply.status, step.status, "{what}: {}", reply.body);
        let rest: Vec<&str> = step.cli.1.iter().map(|s| s.as_str()).collect();
        let cli = env.cli(step.cli.0, &rest);
        assert_eq!(
            norm(&reply.json()),
            norm(&cli.json()),
            "{what} == memex {:?}",
            step.cli.0
        );
    }
    assert_eq!(
        folder_tree(&env.server_vault()),
        folder_tree(&env.cli_vault()),
        "the same folders after the same writes"
    );
    assert_eq!(
        memberships(&env.server_vault()),
        memberships(&env.cli_vault()),
        "the same memberships after the same writes"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_folder_created_through_the_api_is_pinned() {
    let env = Env::start().await;
    for body in [
        json!({"name": "Mechanics"}),
        json!({"name": "Combat", "parent_id": INBOX}),
    ] {
        let reply = env.call("POST", "/smart-folders", Some(&body)).await;
        assert_eq!(reply.status, 201, "{}", reply.body);
        let v = reply.json();
        assert_eq!(v["pinned"], true, "{body}");
        let pinned: bool = db(&env.server_vault())
            .query_row(
                "SELECT pinned FROM smart_folders WHERE id = ?",
                params![v["id"].as_str().unwrap()],
                |r| r.get(0),
            )
            .unwrap();
        assert!(pinned, "the stored folder is pinned: {body}");
    }
    let tree = folder_tree(&env.server_vault());
    assert!(tree.contains(&("Combat".into(), Some("Inbox".into()), true)));
    assert!(tree.contains(&("Mechanics".into(), None, true)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn folder_writes_stamp_the_server_request_clock() {
    const FIXED_MS: i64 = 1_792_600_000_000;
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let fixed: SharedClock = Arc::new(FixedClock(FIXED_MS));
    let addr = start_with_clock(root.path(), fixed).await;

    let reply = call_at(
        addr,
        "POST",
        "/smart-folders",
        Some(&json!({"name": "Mechanics"})),
    )
    .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let v = reply.json();
    assert_eq!(
        (v["created_at"].as_i64(), v["updated_at"].as_i64()),
        (Some(FIXED_MS), Some(FIXED_MS))
    );

    let reply = call_at(
        addr,
        "PATCH",
        &format!("/smart-folders/{INBOX}"),
        Some(&json!({"name": "Later"})),
    )
    .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(v["updated_at"].as_i64(), Some(FIXED_MS));
    assert_eq!(
        v["created_at"].as_i64(),
        Some(1_760_000_720_000),
        "the seed stamp"
    );
}

// ---------------------------------------------------------------------------
// AC 6: membership defaults
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn adding_a_member_without_pinned_pins_it_and_makes_a_role_less_note_a_topic() {
    let env = Env::start().await;
    assert_eq!(frontmatter_of(&env.server_vault(), LOOSE), "{}");
    let reply = env
        .call(
            "POST",
            &format!("/smart-folders/{INBOX}/members"),
            Some(&json!({"note_id": LOOSE})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(
        (
            &v["smart_folder_id"],
            &v["note_id"],
            &v["pinned"],
            &v["role_set"]
        ),
        (&json!(INBOX), &json!(LOOSE), &json!(true), &json!(true)),
        "{v}"
    );
    assert!(memberships(&env.server_vault()).contains(&(
        "Inbox".into(),
        "Loose Thought".into(),
        true
    )));
    let fm: Value = serde_json::from_str(&frontmatter_of(&env.server_vault(), LOOSE)).unwrap();
    assert_eq!(fm["role"], "topic", "the role-less note became a topic");

    let unsorted = env.call("GET", "/unsorted", None).await.json();
    let ids: Vec<&str> = unsorted["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["note_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![BROKEN], "a member is no longer unsorted");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn adding_a_member_with_pinned_false_leaves_it_unpinned_and_a_topic_keeps_its_role() {
    let env = Env::start().await;
    let reply = env
        .call(
            "POST",
            &format!("/smart-folders/{INBOX}/members"),
            Some(&json!({"note_id": PACING, "pinned": false})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        ["folder", "add"],
        &["--id", INBOX, "--note-id", PACING, "--pinned", "false"],
    );
    assert_eq!(reply.json(), cli.json());
    assert_eq!(reply.json()["pinned"], false);
    assert_eq!(reply.json()["role_set"], false, "already a topic");
    assert!(memberships(&env.server_vault()).contains(&(
        "Inbox".into(),
        "Pacing Notes".into(),
        false
    )));
}

// ---------------------------------------------------------------------------
// AC 7: the depth limit
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_or_move_past_max_depth_is_c1_depth_exceeded_with_both_depths() {
    let env = Env::start().await;
    let before = folder_tree(&env.server_vault());

    // Create under Systems (depth 2): depth 3 > 2.
    let reply = env
        .call(
            "POST",
            "/smart-folders",
            Some(&json!({"name": "Too Deep", "parent_id": SYSTEMS})),
        )
        .await;
    assert_c1(&reply, 422, "depth_exceeded");
    let v = reply.json();
    assert_eq!(
        (&v["error"]["max_depth"], &v["error"]["required_depth"]),
        (&json!(2), &json!(3))
    );
    let cli = env.cli(
        ["folder", "new"],
        &["--name", "Too Deep", "--parent-id", SYSTEMS],
    );
    assert_eq!(v, cli.error(), "the CLI's depth_exceeded body");

    // Move Design (with its child Systems) under Inbox: depth 3 > 2.
    let reply = env
        .call(
            "PATCH",
            &format!("/smart-folders/{DESIGN}"),
            Some(&json!({"parent_id": INBOX})),
        )
        .await;
    assert_c1(&reply, 422, "depth_exceeded");
    let v = reply.json();
    assert_eq!(
        (&v["error"]["max_depth"], &v["error"]["required_depth"]),
        (&json!(2), &json!(3))
    );
    let cli = env.cli(
        ["folder", "update"],
        &["--id", DESIGN, "--parent-id", INBOX],
    );
    assert_eq!(v, cli.error());

    assert_eq!(folder_tree(&env.server_vault()), before, "nothing written");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn raising_max_depth_lets_the_same_create_through() {
    let env = Env::start().await;
    let reply = env
        .call(
            "PUT",
            &format!("/settings/{MAX_DEPTH}"),
            Some(&json!({"value": 3})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let reply = env
        .call(
            "POST",
            "/smart-folders",
            Some(&json!({"name": "Deep Enough", "parent_id": SYSTEMS})),
        )
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    assert_eq!(reply.json()["depth"], 3);
}

// ---------------------------------------------------------------------------
// AC 8: the CLI's other folder errors
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn name_conflict_folder_cycle_and_not_found_answer_with_the_cli_codes_and_fields() {
    let env = Env::start().await;
    type Case<'a> = (
        &'a str,
        String,
        Option<Value>,
        u16,
        &'a str,
        [&'a str; 2],
        Vec<&'a str>,
    );
    let cases: Vec<Case> = vec![
        (
            "POST",
            "/smart-folders".into(),
            Some(json!({"name": "design"})),
            409,
            "name_conflict",
            ["folder", "new"],
            vec!["--name", "design"],
        ),
        (
            "PATCH",
            format!("/smart-folders/{INBOX}"),
            Some(json!({"name": "DESIGN"})),
            409,
            "name_conflict",
            ["folder", "update"],
            vec!["--id", INBOX, "--name", "DESIGN"],
        ),
        (
            "PATCH",
            format!("/smart-folders/{DESIGN}"),
            Some(json!({"parent_id": SYSTEMS})),
            422,
            "folder_cycle",
            ["folder", "update"],
            vec!["--id", DESIGN, "--parent-id", SYSTEMS],
        ),
        (
            "PATCH",
            format!("/smart-folders/{DESIGN}"),
            Some(json!({"parent_id": DESIGN})),
            422,
            "folder_cycle",
            ["folder", "update"],
            vec!["--id", DESIGN, "--parent-id", DESIGN],
        ),
        (
            "POST",
            "/smart-folders".into(),
            Some(json!({"name": "Orphan", "parent_id": UNKNOWN})),
            404,
            "not_found",
            ["folder", "new"],
            vec!["--name", "Orphan", "--parent-id", UNKNOWN],
        ),
        (
            "PATCH",
            format!("/smart-folders/{UNKNOWN}"),
            Some(json!({"name": "Nowhere"})),
            404,
            "not_found",
            ["folder", "update"],
            vec!["--id", UNKNOWN, "--name", "Nowhere"],
        ),
        (
            "DELETE",
            format!("/smart-folders/{UNKNOWN}"),
            None,
            404,
            "not_found",
            ["folder", "rm"],
            vec!["--id", UNKNOWN],
        ),
        (
            "POST",
            format!("/smart-folders/{UNKNOWN}/members"),
            Some(json!({"note_id": LOOSE})),
            404,
            "not_found",
            ["folder", "add"],
            vec!["--id", UNKNOWN, "--note-id", LOOSE],
        ),
        (
            "POST",
            format!("/smart-folders/{INBOX}/members"),
            Some(json!({"note_id": UNKNOWN})),
            404,
            "not_found",
            ["folder", "add"],
            vec!["--id", INBOX, "--note-id", UNKNOWN],
        ),
    ];
    let before = folder_tree(&env.server_vault());
    for (method, path, body, status, code, sub, args) in &cases {
        let what = format!("{method} {path}");
        let reply = env.call(method, path, body.as_ref()).await;
        assert_eq!(
            (reply.status, reply.c1_code()),
            (*status, code.to_string()),
            "{what}: {}",
            reply.body
        );
        let cli = env.cli(*sub, args);
        assert_eq!(reply.json(), cli.error(), "{what}: the CLI's {code} body");
    }
    assert_eq!(folder_tree(&env.server_vault()), before, "nothing written");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn patch_with_both_parent_id_and_to_root_is_c1_invalid_argument() {
    let env = Env::start().await;
    let before = folder_tree(&env.server_vault());
    let reply = env
        .call(
            "PATCH",
            &format!("/smart-folders/{INBOX}"),
            Some(&json!({"parent_id": DESIGN, "to_root": true})),
        )
        .await;
    assert_c1(&reply, 400, "invalid_argument");
    // The CLI refuses the same pair of flags (clap conflicts_with).
    let cli = env.cli(
        ["folder", "update"],
        &["--id", INBOX, "--parent-id", DESIGN, "--to-root"],
    );
    assert!(
        !cli.ok,
        "memex folder update refuses --parent-id with --to-root"
    );
    assert_eq!(folder_tree(&env.server_vault()), before, "nothing written");
}

// ---------------------------------------------------------------------------
// AC 9: vault settings
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn settings_get_and_put_answer_like_memex_settings_on_a_seed_copy() {
    let env = Env::start().await;
    let path = format!("/settings/{MAX_DEPTH}");

    let reply = env.call("GET", &path, None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(["settings", "get"], &["--key", MAX_DEPTH]);
    assert_eq!(reply.json(), cli.json(), "GET == memex settings get");

    let reply = env.call("PUT", &path, Some(&json!({"value": 4}))).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(["settings", "set"], &["--key", MAX_DEPTH, "--value", "4"]);
    assert_eq!(reply.json(), cli.json(), "PUT == memex settings set");
    assert_eq!(reply.json()["value"], 4);

    let reply = env.call("GET", &path, None).await;
    let cli = env.cli(["settings", "get"], &["--key", MAX_DEPTH]);
    assert_eq!(
        reply.json(),
        cli.json(),
        "GET after PUT == memex settings get"
    );
    assert_eq!(reply.json()["value"], 4);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bad_setting_values_and_unknown_keys_are_c1_setting_invalid() {
    let env = Env::start().await;
    let path = format!("/settings/{MAX_DEPTH}");
    // Out of 1..=5: the CLI's body for the same value.
    for value in [0, 6] {
        let reply = env.call("PUT", &path, Some(&json!({"value": value}))).await;
        assert_c1(&reply, 400, "setting_invalid");
        let cli = env.cli(
            ["settings", "set"],
            &["--key", MAX_DEPTH, "--value", &value.to_string()],
        );
        assert_eq!(reply.json(), cli.error(), "value {value}");
    }
    // Negative and non-integer values.
    for value in [
        json!(-1),
        json!(100),
        json!(2.5),
        json!("three"),
        json!(true),
        json!([3]),
    ] {
        let reply = env.call("PUT", &path, Some(&json!({"value": value}))).await;
        assert_c1(&reply, 400, "setting_invalid");
    }
    // An unknown key, read or written.
    let reply = env.call("GET", "/settings/unknown_key", None).await;
    assert_c1(&reply, 400, "setting_invalid");
    let cli = env.cli(["settings", "get"], &["--key", "unknown_key"]);
    assert_eq!(reply.json(), cli.error(), "GET unknown key");
    let reply = env
        .call("PUT", "/settings/unknown_key", Some(&json!({"value": 3})))
        .await;
    assert_c1(&reply, 400, "setting_invalid");
    let cli = env.cli(
        ["settings", "set"],
        &["--key", "unknown_key", "--value", "3"],
    );
    assert_eq!(reply.json(), cli.error(), "PUT unknown key");

    let reply = env.call("GET", &path, None).await;
    assert_eq!(reply.json()["value"], 2, "nothing stored");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn after_a_settings_put_get_smart_folders_reports_the_new_max_depth() {
    let env = Env::start().await;
    for value in [5, 1] {
        let reply = env
            .call(
                "PUT",
                &format!("/settings/{MAX_DEPTH}"),
                Some(&json!({"value": value})),
            )
            .await;
        assert_eq!(reply.status, 200, "{}", reply.body);
        let reply = env.call("GET", "/smart-folders", None).await;
        assert_eq!(reply.status, 200, "{}", reply.body);
        assert_eq!(reply.json()["max_depth"], value);
    }
}

// ---------------------------------------------------------------------------
// AC 10: the review prompt
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_prompts_review_text_equals_memex_prompt_review_stdout_byte_for_byte() {
    let env = Env::start().await;
    let reply = env.call("GET", "/prompts/review", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(
        v.as_object().unwrap().keys().collect::<Vec<_>>(),
        vec!["text"]
    );
    let text = v["text"].as_str().unwrap();
    let cli = run_cli(&["prompt".into(), "review".into()]);
    assert!(cli.ok, "{}", cli.stderr);
    assert_eq!(text.as_bytes(), cli.stdout.as_bytes(), "byte for byte");
    assert_eq!(text, memex_mcp::prompts::REVIEW_DAILY_NOTES);
    assert!(
        text.ends_with('\n') && !text.ends_with("\n\n"),
        "one trailing newline"
    );
    assert_ne!(text, memex_mcp::prompts::CAPTURE, "not the capture prompt");
}

// ---------------------------------------------------------------------------
// AC 11: malformed requests
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_json_and_missing_required_fields_are_c1_invalid_argument() {
    let env = Env::start().await;
    let folders = folder_count(&env.server_vault());
    let raw: &[(&str, String, &[u8])] = &[
        ("POST", "/smart-folders".into(), b"{\"name\":"),
        ("POST", "/smart-folders".into(), b"not json"),
        ("POST", "/smart-folders".into(), b"{}"),
        ("POST", "/smart-folders".into(), b"{\"name\": 5}"),
        (
            "POST",
            "/smart-folders".into(),
            b"{\"parent_id\": \"01M5DQAYZHJGKWXCJHR5FSDFA0\"}",
        ),
        ("PATCH", format!("/smart-folders/{INBOX}"), b"{\"name\":"),
        (
            "PATCH",
            format!("/smart-folders/{INBOX}"),
            b"{\"pinned\": \"yes\"}",
        ),
        (
            "POST",
            format!("/smart-folders/{INBOX}/members"),
            b"{\"note_id\":",
        ),
        ("POST", format!("/smart-folders/{INBOX}/members"), b"{}"),
        (
            "POST",
            format!("/smart-folders/{INBOX}/members"),
            b"{\"pinned\": true}",
        ),
        ("PUT", format!("/settings/{MAX_DEPTH}"), b"{\"value\":"),
        ("PUT", format!("/settings/{MAX_DEPTH}"), b"{}"),
        ("PUT", format!("/settings/{MAX_DEPTH}"), b"\"3\""),
    ];
    for (method, path, body) in raw {
        let reply = env.call_raw(method, path, body).await;
        assert_eq!(
            (reply.status, reply.c1_code()),
            (400, "invalid_argument".to_string()),
            "{method} {path} {:?}: {}",
            String::from_utf8_lossy(body),
            reply.body
        );
        assert!(
            reply.json()["error"]["message"].is_string(),
            "a C1 message: {}",
            reply.body
        );
    }
    assert_eq!(
        folder_count(&env.server_vault()),
        folders,
        "nothing created"
    );
    assert_eq!(
        frontmatter_of(&env.server_vault(), LOOSE),
        "{}",
        "nothing added"
    );
    let reply = env
        .call("GET", &format!("/settings/{MAX_DEPTH}"), None)
        .await;
    assert_eq!(reply.json()["value"], 2, "nothing stored");
}

// ---------------------------------------------------------------------------
// AC 12: 401 without a token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_topics_route_answers_401_unauthorized_without_a_bearer_token() {
    let env = Env::start().await;
    let rows = load_rows(&topics_dir()).expect("topics/index.json parses");
    let before = folder_tree(&env.server_vault());
    for row in &rows {
        let method = reqwest::Method::from_bytes(row.method.as_bytes()).unwrap();
        let body = row
            .request
            .as_ref()
            .map(|f| std::fs::read(topics_dir().join(f)).unwrap())
            .unwrap_or_default();
        let send = |auth: bool| {
            let mut req = client()
                .request(method.clone(), env.srv.url(&row.path))
                .header("content-type", "application/json")
                .body(body.clone());
            if auth {
                req = req.header("authorization", env.srv.bearer());
            }
            req
        };
        let reply = Reply::read(send(false).send().await.unwrap()).await;
        assert_eq!(
            (reply.status, reply.c1_code()),
            (401, "unauthorized".to_string()),
            "{} {} without a token",
            row.method,
            row.path
        );
        // Only reads are replayed with the token: the route exists.
        if row.method == "GET" {
            let reply = Reply::read(send(true).send().await.unwrap()).await;
            assert_eq!(
                reply.status, row.status,
                "{} {} with the token: {}",
                row.method, row.path, reply.body
            );
        }
    }
    assert_eq!(
        folder_tree(&env.server_vault()),
        before,
        "no tokenless write"
    );
    assert_eq!(frontmatter_of(&env.server_vault(), LOOSE), "{}");
}

// ---------------------------------------------------------------------------
// AC 14: the route inventory
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn topics_router_serves_exactly_the_table_routes() {
    // topics/index.json holds exactly the WI table's routes, with no SQL,
    // argv or other passthrough field in a request body.
    let rows = load_rows(&topics_dir()).expect("topics/index.json parses");
    let served: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    let table: BTreeSet<(String, String)> = ROUTES
        .iter()
        .map(|(m, p)| (m.to_string(), p.to_string()))
        .collect();
    assert_eq!(
        served, table,
        "topics/index.json routes == the WI #83 table"
    );
    let allowed_body: BTreeSet<&str> =
        ["name", "parent_id", "to_root", "pinned", "note_id", "value"].into();
    for row in &rows {
        if let Some(file) = &row.request {
            let body: Value =
                serde_json::from_slice(&std::fs::read(topics_dir().join(file)).unwrap()).unwrap();
            let obj = body.as_object().expect("every request body is an object");
            for key in obj.keys() {
                assert!(allowed_body.contains(key.as_str()), "{file}: field {key}");
            }
        }
        assert!(
            response_json(row).is_object(),
            "{}: every response is an object",
            row.response
        );
    }

    let env = Env::start().await;
    let at = |p: &str| format!("{BASE}{p}");
    // Every method a table path does not serve is the C1 405.
    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (at("/smart-folders").as_str(), &["GET", "POST"]),
            (
                at(&format!("/smart-folders/{INBOX}")).as_str(),
                &["PATCH", "DELETE"],
            ),
            (
                at(&format!("/smart-folders/{INBOX}/members")).as_str(),
                &["POST"],
            ),
            (at("/unsorted").as_str(), &["GET"]),
            (
                at(&format!("/settings/{MAX_DEPTH}")).as_str(),
                &["GET", "PUT"],
            ),
            (at("/prompts/review").as_str(), &["GET"]),
        ],
    )
    .await;
    // No `folder remove` (a member path), `folder ls` or `prompt capture`
    // route, and no settings list.
    for path in [
        format!("/smart-folders/{INBOX}/members/{LOOSE}"),
        "/smart-folders/ls/members/x".to_string(),
        "/folders".to_string(),
        "/folder-ls".to_string(),
        "/prompts/capture".to_string(),
        "/prompts".to_string(),
        "/settings".to_string(),
        "/sql".to_string(),
        "/cli".to_string(),
    ] {
        for method in ["GET", "POST", "DELETE"] {
            let reply = env.call(method, &path, None).await;
            let v = reply.json();
            assert_eq!(
                (reply.status, v["error"]["code"].as_str()),
                (404, Some("not_found")),
                "{method} {path}: {}",
                reply.body
            );
            assert_eq!(
                v["error"]["message"], "not found: no route for this path",
                "{method} {path} has no route"
            );
        }
    }
    // A member stays a member: no removal route answered.
    assert_eq!(
        memberships(&env.server_vault()),
        memberships(&env.cli_vault())
    );
}
