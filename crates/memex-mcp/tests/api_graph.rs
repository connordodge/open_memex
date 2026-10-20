//! WI #85 (V5): the graph view's reads and the Activity tab's read over the
//! app API, Rust half.
//!
//! The graph routes under `/vaults/{name}/api/v1`, served by the in-process
//! vault server (`127.0.0.1:0`) over #74's frozen seed:
//!
//! | Route | Response |
//! |---|---|
//! | `GET /graph/notes` | `{"notes":[{id,title,role}]}` (role: string or null) |
//! | `GET /graph/links` | `{"links":[{from,to,kind,label}]}` (label: string or null) |
//! | `GET /notes/{note_id}/agent-changes` | `{"changes":[{id,note_id,day,created_at,bullets}]}` |
//!
//! There is no route for the schema version (the app reads `schema_version`
//! from #72's `GET /vaults/{name}/api/v1/info`), for `hasTables`, `isVault`,
//! `vaultId` or the BFS `graph::neighbors`.
//!
//! The fixture rows in `app/test/fixtures/api_v1/graph/index.json` were made
//! from the app's local `GraphReads` / `ActivityReads` on
//! `seededFakeVaultDb()`, then frozen: never rebless them to fit the server.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use axum::Router;
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tokio::net::TcpListener;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, run_rows, FixtureRequest,
    FixtureResponse, FixtureRow, SEED_VAULT_NAME,
};
use server::{
    assert_wrong_method_is_c1_405, client, raw_request, Reply, TestServer, PROBE_METHODS,
    TEST_TOKEN,
};

const BASE: &str = "/vaults/seed/api/v1";

const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
const PACING: &str = "01M5DQAYZ4YAPYMEDWXP8WCNGJ";
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
const DAY_15: &str = "01M5DQAYZ592W2515HPSDF5Q16";
const DAY_16: &str = "01M5DQAYZ50YGKE126FXV02TEY";
const DAY_17: &str = "01M5DQAYZ5T5B865CDF2RWAC37";
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
const DAY_19: &str = "01M5DQAYZ51PF87XFZWSV5PWXK";
const BROKEN: &str = "01M5DQAYZ5RH88SRZGPY15XXVM";
/// The seed's ghost link: Player Loop → "Unwritten Idea" (no target note).
const GHOST_LINK: &str = "01M5DQAYZCV1DXWK1CFVDNP0SS";
/// A valid ULID no seed note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

/// The routes of the WI #85 table, as `(METHOD, path)` under `BASE`.
const ROUTES: &[(&str, &str)] = &[
    ("GET", "/graph/notes"),
    ("GET", "/graph/links"),
    ("GET", "/notes/{id}/agent-changes"),
];

fn graph_dir() -> PathBuf {
    api_v1_dir().join("graph")
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// The server over one seed copy.
struct Env {
    srv: TestServer,
}

impl Env {
    async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    /// Like [`Env::start`], running `prepare` on the seed copy first.
    async fn start_with(prepare: impl Fn(&Path)) -> Self {
        let root = tempfile::tempdir().unwrap();
        prepare(&materialize_seed(root.path()));
        Self {
            srv: TestServer::start_in(root).await,
        }
    }

    fn vault(&self) -> PathBuf {
        self.srv.root().join(SEED_VAULT_NAME)
    }

    /// `GET <BASE><path>` with the token.
    async fn get(&self, path: &str) -> Reply {
        let req = client()
            .get(self.srv.url(&format!("{BASE}{path}")))
            .header("authorization", self.srv.bearer());
        Reply::read(req.send().await.expect("send request")).await
    }

    /// `GET <BASE><path>` with the token, answered 200 with a JSON body.
    async fn get_ok(&self, path: &str) -> Value {
        let reply = self.get(path).await;
        assert_eq!(reply.status, 200, "GET {path}: {}", reply.body);
        assert!(
            reply
                .header("content-type")
                .is_some_and(|ct| ct.starts_with("application/json")),
            "GET {path}: content-type {:?}",
            reply.header("content-type")
        );
        reply.json()
    }

    async fn changes(&self, note_id: &str) -> Value {
        self.get_ok(&format!("/notes/{note_id}/agent-changes"))
            .await
    }
}

/// A writable connection to a vault's database (the server keeps its own
/// connection open; WAL lets both work).
fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

fn add_change(vault: &Path, id: &str, note_id: &str, day: &str, created_at: i64, bullets: &str) {
    db(vault)
        .execute(
            "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES (?, ?, ?, ?, ?)",
            params![id, note_id, day, created_at, bullets],
        )
        .unwrap();
}

// ---------------------------------------------------------------------------
// AC 1: the fixture rows
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

/// `(METHOD, path template)` of a row: ULIDs become `{id}` and the query is
/// reduced to its parameter names.
fn template(row: &FixtureRow) -> (String, String) {
    let ulid = Regex::new(r"[0-7][0-9A-HJKMNP-TV-Z]{25}").unwrap();
    let path = row
        .path
        .strip_prefix(BASE)
        .unwrap_or_else(|| panic!("row path {} is not under {BASE}", row.path));
    let (p, q) = path.split_once('?').unwrap_or((path, ""));
    let mut t = ulid.replace_all(p, "{id}").into_owned();
    let names: Vec<&str> = q
        .split('&')
        .filter(|kv| !kv.is_empty())
        .map(|kv| kv.split('=').next().unwrap())
        .collect();
    if !names.is_empty() {
        t.push('?');
        t.push_str(&names.join("&"));
    }
    (row.method.clone(), t)
}

/// The keys of a JSON object.
fn keys(v: &Value) -> BTreeSet<&str> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .map(String::as_str)
        .collect()
}

fn fixture(name: &str) -> Value {
    serde_json::from_slice(&std::fs::read(graph_dir().join(name)).unwrap()).unwrap()
}

#[test]
fn graph_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&graph_dir()).expect("graph/index.json parses");
    let seen: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    for (m, p) in ROUTES {
        let want = (m.to_string(), p.to_string());
        assert!(seen.contains(&want), "graph/ has a row for {want:?}");
    }
    // Every seed note has an agent-changes row, and so does an unknown id.
    let with_rows: BTreeSet<String> = rows
        .iter()
        .filter_map(|r| {
            r.path
                .strip_prefix(&format!("{BASE}/notes/"))
                .and_then(|p| p.strip_suffix("/agent-changes"))
                .map(str::to_string)
        })
        .collect();
    let want: BTreeSet<String> = [
        PLAYER_LOOP,
        ECONOMY,
        PACING,
        LOOSE,
        DAY_15,
        DAY_16,
        DAY_17,
        DAY_18,
        DAY_19,
        BROKEN,
        UNKNOWN,
    ]
    .map(String::from)
    .into();
    assert_eq!(with_rows, want);
    assert!(
        rows.iter().all(|r| !r.dart_only && r.status == 200),
        "every graph row runs in Rust and answers 200"
    );
    // The frozen links fixture leaves the ghost link out.
    let links = fixture("graph_links.json");
    assert!(links["links"]
        .as_array()
        .unwrap()
        .iter()
        .all(|l| l["to"].is_string()));

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&graph_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn graph_notes_answers_every_seed_note_by_id_with_its_role_or_null() {
    let env = Env::start().await;
    let v = env.get_ok("/graph/notes").await;
    let notes: Vec<(&str, &str, Value)> = v["notes"]
        .as_array()
        .expect("notes is a list inside an object")
        .iter()
        .map(|n| {
            assert_eq!(keys(n), BTreeSet::from(["id", "role", "title"]), "{n}");
            (
                n["id"].as_str().unwrap(),
                n["title"].as_str().unwrap(),
                n["role"].clone(),
            )
        })
        .collect();
    assert_eq!(
        notes,
        vec![
            (PLAYER_LOOP, "Player Loop", json!("topic")),
            (ECONOMY, "Economy Design", json!("topic")),
            (LOOSE, "Loose Thought", Value::Null),
            (DAY_18, "2026-10-18", json!("daily")),
            (PACING, "Pacing Notes", json!("topic")),
            (DAY_16, "2026-10-16", json!("daily")),
            (DAY_19, "2026-10-19", json!("daily")),
            (DAY_15, "2026-10-15", json!("daily")),
            // Invalid-JSON frontmatter: role-less, never an error.
            (BROKEN, "Broken Frontmatter", Value::Null),
            (DAY_17, "2026-10-17", json!("daily")),
        ]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn graph_links_leaves_out_the_seed_ghost_link() {
    let env = Env::start().await;
    // The seed holds the ghost link: a row with no target note.
    let ghost: (String, Option<String>) = db(&env.vault())
        .query_row(
            "SELECT from_note_id, to_note_id FROM links WHERE id = ?",
            [GHOST_LINK],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(ghost, (PLAYER_LOOP.to_string(), None));
    let total: i64 = db(&env.vault())
        .query_row("SELECT COUNT(*) FROM links", [], |r| r.get(0))
        .unwrap();

    let v = env.get_ok("/graph/links").await;
    let links = v["links"]
        .as_array()
        .expect("links is a list inside an object");
    assert_eq!(links.len() as i64, total - 1, "every link but the ghost");
    for l in links {
        assert_eq!(
            keys(l),
            BTreeSet::from(["from", "kind", "label", "to"]),
            "{l}"
        );
        assert!(l["to"].is_string(), "{l}");
    }
    // Player Loop links out only to Economy Design.
    let from_loop: Vec<&Value> = links.iter().filter(|l| l["from"] == PLAYER_LOOP).collect();
    assert_eq!(
        from_loop,
        vec![&json!({"from": PLAYER_LOOP, "to": ECONOMY, "kind": "references", "label": null})]
    );
    // Ordered by source note, then position.
    let order: Vec<(&str, &str)> = links
        .iter()
        .map(|l| (l["from"].as_str().unwrap(), l["kind"].as_str().unwrap()))
        .collect();
    assert_eq!(
        order,
        vec![
            (PLAYER_LOOP, "references"),
            (ECONOMY, "extends"),
            (ECONOMY, "from-day"),
            (DAY_18, "references"),
            (DAY_18, "about"),
            (PACING, "references"),
            (DAY_19, "about"),
        ]
    );
    assert_eq!(links[5]["label"], "the loop");
}

// ---------------------------------------------------------------------------
// AC 6: no changes, or an unknown id
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_changes_for_a_note_without_changes_or_an_unknown_id_is_an_empty_list() {
    let env = Env::start().await;
    for id in [
        PLAYER_LOOP,
        LOOSE,
        DAY_19,
        BROKEN,
        UNKNOWN,
        // Not a ULID: still just an unknown note, like the local read.
        "not-a-ulid",
        "01m5dqayz4tapthdwe5pnwe4w5",
        "a%2Fb%3Fc%20d",
    ] {
        assert_eq!(
            env.changes(id).await,
            json!({"changes": []}),
            "GET /notes/{id}/agent-changes"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_changes_answer_the_seed_rows_with_every_field() {
    let env = Env::start().await;
    assert_eq!(
        env.changes(DAY_18).await,
        json!({"changes": [{
            "id": "01M5DQAYZJJSN6WG9XFPXXFBNC",
            "note_id": DAY_18,
            "day": "2026-10-18",
            "created_at": 1760000960000_i64,
            "bullets": ["Filed the prototype notes"],
        }]})
    );
    assert_eq!(
        env.changes(DAY_17).await["changes"][0]["bullets"],
        json!(["Noted the price tuning"])
    );
    assert_eq!(
        env.changes(ECONOMY).await["changes"][0]["id"],
        "01M5DQAYZJKNYY386G5CXYKNMX"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_changes_come_newest_first_and_decode_bad_bullets_to_empty_over_the_wire() {
    let env = Env::start().await;
    assert_eq!(env.changes(LOOSE).await, json!({"changes": []}));

    // Written after the first read: the route reads the vault, not a cache.
    let vault = env.vault();
    add_change(
        &vault,
        "01M5DQAYZKZZZZZZZZZZZZZZZZ",
        LOOSE,
        "2026-10-18",
        1000,
        r#"["z"]"#,
    );
    add_change(
        &vault,
        "01M5DQAYZKAAAAAAAAAAAAAAAA",
        LOOSE,
        "2026-10-18",
        1000,
        "not json",
    );
    add_change(
        &vault,
        "01M5DQAYZKMMMMMMMMMMMMMMMM",
        LOOSE,
        "2026-10-18",
        1000,
        r#"{"a":1}"#,
    );
    add_change(
        &vault,
        "01M5DQAYZKNEWNEWNEWNEWNEWN",
        LOOSE,
        "2026-10-19",
        2000,
        r#"["b","a"]"#,
    );
    add_change(
        &vault,
        "01M5DQAYZKQQQQQQQQQQQQQQQQ",
        LOOSE,
        "2026-10-17",
        1,
        r#"[1,true,null]"#,
    );

    let v = env.changes(LOOSE).await;
    let got: Vec<(&str, Value)> = v["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["id"].as_str().unwrap(), c["bullets"].clone()))
        .collect();
    assert_eq!(
        got,
        vec![
            ("01M5DQAYZKNEWNEWNEWNEWNEWN", json!(["b", "a"])),
            ("01M5DQAYZKMMMMMMMMMMMMMMMM", json!([])),
            ("01M5DQAYZKAAAAAAAAAAAAAAAA", json!([])),
            ("01M5DQAYZKZZZZZZZZZZZZZZZZ", json!(["z"])),
            ("01M5DQAYZKQQQQQQQQQQQQQQQQ", json!(["1", "true", "null"])),
        ]
    );
}

// ---------------------------------------------------------------------------
// AC 9: the route inventory
// ---------------------------------------------------------------------------

#[test]
fn graph_index_routes_are_exactly_the_wi_table() {
    let rows = load_rows(&graph_dir()).expect("graph/index.json parses");
    let served: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    let table: BTreeSet<(String, String)> = ROUTES
        .iter()
        .map(|(m, p)| (m.to_string(), p.to_string()))
        .collect();
    assert_eq!(served, table, "graph/index.json routes == the WI #85 table");
    assert!(
        rows.iter()
            .all(|r| r.request.is_none() && r.headers.is_empty()),
        "graph reads send no body and no extra headers"
    );
}

/// Serves only `api::graph::router()`, nested where the server nests it,
/// with no vault guard: a served route answers anything but 404 and 405.
async fn serve_graph_router_alone() -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let app = Router::new().nest(
        "/vaults/{name}/api/v1",
        memex_mcp::server::api::graph::router(),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (addr, task)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn graph_router_serves_exactly_the_table_routes_and_no_schema_version_or_has_tables_route() {
    let (addr, task) = serve_graph_router_alone().await;
    let http = client();
    for (route_method, path) in ROUTES {
        let concrete = path.replace("{id}", DAY_18);
        for method in PROBE_METHODS {
            let url = format!("http://{addr}{BASE}{concrete}");
            let req = http.request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                &url,
            );
            let status = req.send().await.unwrap().status().as_u16();
            if method == *route_method {
                assert!(
                    status != 404 && status != 405,
                    "{method} {path} is a graph route (got {status})"
                );
            } else {
                assert_eq!(status, 405, "{method} {path} is not a graph route");
            }
        }
    }
    // No schema version, hasTables, isVault, vaultId, info or BFS route
    // lives in the graph router.
    for path in [
        "/schema-version".to_string(),
        "/schema_version".to_string(),
        "/schema".to_string(),
        "/graph/schema-version".to_string(),
        "/has-tables".to_string(),
        "/tables".to_string(),
        "/is-vault".to_string(),
        "/vault-id".to_string(),
        "/info".to_string(),
        "/graph".to_string(),
        "/graph/neighbors".to_string(),
        format!("/graph/neighbors/{DAY_18}"),
        format!("/notes/{DAY_18}/neighbors"),
        format!("/graph/notes/{DAY_18}"),
        "/agent-changes".to_string(),
        "/activity".to_string(),
        format!("/notes/{DAY_18}/agent-changes/latest"),
        format!("/notes/{DAY_18}/activity"),
    ] {
        for method in ["GET", "POST", "PUT"] {
            let url = format!("http://{addr}{BASE}{path}");
            let req = http.request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                &url,
            );
            let status = req.send().await.unwrap().status().as_u16();
            assert_eq!(status, 404, "{method} {path} has no graph route");
        }
    }
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn graph_routes_answer_wrong_methods_with_the_c1_405() {
    let env = Env::start().await;
    let notes = format!("{BASE}/graph/notes");
    let links = format!("{BASE}/graph/links");
    let changes = format!("{BASE}/notes/{DAY_18}/agent-changes");
    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (notes.as_str(), &["GET"][..]),
            (links.as_str(), &["GET"][..]),
            (changes.as_str(), &["GET"][..]),
        ],
    )
    .await;
}

// ---------------------------------------------------------------------------
// AC 8: 401 without a token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_graph_route_answers_401_unauthorized_without_a_bearer_token() {
    let env = Env::start().await;
    let rows = load_rows(&graph_dir()).expect("graph/index.json parses");
    assert!(!rows.is_empty());
    for row in &rows {
        let method = reqwest::Method::from_bytes(row.method.as_bytes()).unwrap();
        let send = |auth: Option<String>| {
            let mut req = client().request(method.clone(), env.srv.url(&row.path));
            if let Some(a) = auth {
                req = req.header("authorization", a);
            }
            req
        };
        for auth in [
            None,
            Some("Bearer not-the-token".to_string()),
            Some(TEST_TOKEN.to_string()),
        ] {
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
        // With the token the route exists and answers.
        let reply = Reply::read(send(Some(env.srv.bearer())).send().await.unwrap()).await;
        assert_eq!(
            reply.status, 200,
            "{} {} with the token: {}",
            row.method, row.path, reply.body
        );
    }
}
