//! WI #402 (Spec #394 requirement 35; rulings D11, D12, D20):
//! `GET /vaults/{name}/api/v1/tools`.
//!
//! Every test serves the full `memex_mcp::server::router()` in-process
//! (`127.0.0.1:0`): a path-parameter clash between merged routers panics
//! only when the merged tree is built.
//!
//! The body is `memex tools`' output: `{"tools":[{"name","summary","group",
//! "writes"}],"prompts":[{"name","summary"}]}`, tools and prompts in the
//! composed routers' `list_all()` order, every field from M0's table.
//!
//! The wire fixture `app/test/fixtures/api_v1/tools/` is shared with the
//! Dart side. [`tools_fixture_rows_match_the_full_router_on_the_seed`]
//! checks it against the server (and rewrites it under `MEMEX_BLESS=1`);
//! [`tools_fixture_body_is_the_router_order_list_with_meta_rows`] pins the
//! committed body to the routers and the table, so neither can drift.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use memex_mcp::tools::meta;
use memex_mcp::tools::Memex;
use serde_json::{json, Value};

use api_fixtures::{
    api_v1_dir, bless_requested, canonical_json, load_rows, materialize_seed, run_rows,
    FixtureRequest, FixtureResponse,
};
use server::{assert_wrong_method_is_c1_405, client, make_vault, raw_request, Reply, TestServer};

const BASE: &str = "/vaults/seed/api/v1";
const TOOLS_PATH: &str = "/vaults/seed/api/v1/tools";

fn tools_dir() -> PathBuf {
    api_v1_dir().join("tools")
}

// ---------- expected body ----------

/// The body built from the composed routers (names and order) and M0's
/// table (every other field).
fn expected_body() -> Value {
    let (tools, prompts) = Memex::routers();
    let tools: Vec<Value> = tools
        .list_all()
        .iter()
        .map(|t| {
            let row = meta::tool(&t.name).unwrap_or_else(|| panic!("{} has a meta row", t.name));
            json!({
                "name": row.name,
                "summary": row.summary,
                "group": row.group.id(),
                "writes": row.writes,
            })
        })
        .collect();
    let prompts: Vec<Value> = prompts
        .list_all()
        .iter()
        .map(|p| {
            let row = meta::prompt(&p.name).unwrap_or_else(|| panic!("{} has a meta row", p.name));
            json!({ "name": row.name, "summary": row.summary })
        })
        .collect();
    assert!(!tools.is_empty() && !prompts.is_empty());
    json!({ "tools": tools, "prompts": prompts })
}

fn names_of(v: &Value, key: &str) -> Vec<String> {
    v[key]
        .as_array()
        .unwrap_or_else(|| panic!("{key:?} is an array: {v}"))
        .iter()
        .map(|o| o["name"].as_str().unwrap_or_default().to_string())
        .collect()
}

/// `memex tools`: exit 0, empty stderr, one JSON line; returns it parsed.
fn memex_tools_output() -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .arg("tools")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex tools");
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(
        out.status.code(),
        Some(0),
        "memex tools: stdout={stdout} stderr={stderr}"
    );
    assert!(stderr.is_empty(), "memex tools stderr: {stderr}");
    serde_json::from_str(stdout.trim_end())
        .unwrap_or_else(|e| panic!("memex tools stdout is not JSON ({e}): {stdout}"))
}

// ---------- harness ----------

/// The full router over a seed copy (`seed`) and one fresh vault (`fresh`).
struct Env {
    srv: TestServer,
}

impl Env {
    async fn start() -> Self {
        let root = tempfile::tempdir().unwrap();
        materialize_seed(root.path());
        make_vault(root.path(), "fresh");
        Self {
            srv: TestServer::start_in(root).await,
        }
    }

    /// `GET <path>` with `authorization` as the header value, if any.
    async fn get(&self, path: &str, authorization: Option<&str>) -> Reply {
        let mut req = client().get(self.srv.url(path));
        if let Some(value) = authorization {
            req = req.header("authorization", value);
        }
        Reply::read(req.send().await.expect("send GET")).await
    }

    async fn get_with_token(&self, path: &str) -> Reply {
        self.get(path, Some(&self.srv.bearer())).await
    }
}

/// One fixture row over a bare socket. The row's own `Authorization` header
/// replaces the token.
async fn exec(srv: &TestServer, req: &FixtureRequest) -> FixtureResponse {
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        req.method, req.path
    );
    if !req
        .headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("authorization"))
    {
        head.push_str(&format!("Authorization: {}\r\n", srv.bearer()));
    }
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    let reply = raw_request(srv.addr(), &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

// ---------- AC 4: the body is `memex tools`' output ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_tools_returns_200_and_the_memex_tools_output() {
    let env = Env::start().await;

    let reply = env.get_with_token(TOOLS_PATH).await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert!(
        reply
            .header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "a JSON body, got {:?}",
        reply.header("content-type")
    );
    let body = reply.json();
    let cli = memex_tools_output();
    assert_eq!(
        body, cli,
        "the route answers exactly what memex tools prints"
    );
    assert_eq!(
        names_of(&body, "tools"),
        names_of(&expected_body(), "tools"),
        "same list, same (router) order"
    );
    assert_eq!(body, expected_body());

    // The list is the binary's, not the vault's: any served vault gets it.
    let fresh = env.get_with_token("/vaults/fresh/api/v1/tools").await;
    assert_eq!(fresh.status, 200, "{}", fresh.body);
    assert_eq!(fresh.json(), body);
}

// ---------- AC 5: token and vault ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tools_route_needs_the_token_and_a_known_vault() {
    let env = Env::start().await;

    // Control: the right token on a served vault is answered.
    let ok = env.get_with_token(TOOLS_PATH).await;
    assert_eq!(ok.status, 200, "{}", ok.body);
    assert_eq!(ok.json(), expected_body());

    let missing = env.get(TOOLS_PATH, None).await;
    assert_eq!(missing.status, 401, "no token: {}", missing.body);
    assert_eq!(missing.c1_code(), "unauthorized");

    let wrong = env
        .get(TOOLS_PATH, Some("Bearer wrong-token-not-the-server-token"))
        .await;
    assert_eq!(wrong.status, 401, "wrong token: {}", wrong.body);
    assert_eq!(wrong.c1_code(), "unauthorized");
    assert!(!wrong.body.contains("\"tools\""), "{}", wrong.body);

    let unknown = env.get_with_token("/vaults/nope/api/v1/tools").await;
    assert_eq!(unknown.status, 404, "unknown vault: {}", unknown.body);
    assert_eq!(unknown.c1_code(), "vault_not_found");
}

// ---------- AC 6: the shared wire fixture ----------

#[test]
fn tools_fixture_rows_match_the_full_router_on_the_seed() {
    let rows = load_rows(&tools_dir()).expect("tools/index.json parses");
    let seen: BTreeSet<(String, String, u16)> = rows
        .iter()
        .map(|r| (r.method.clone(), r.path.clone(), r.status))
        .collect();
    for (method, path, status) in [
        ("GET", TOOLS_PATH, 200),
        ("GET", TOOLS_PATH, 401),
        ("GET", "/vaults/nope/api/v1/tools", 404),
    ] {
        let want = (method.to_string(), path.to_string(), status);
        assert!(seen.contains(&want), "tools/ has a row for {want:?}");
    }
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every tools row runs in Rust"
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&tools_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

/// Not an AC row: the committed 200 body is the routers' list with M0's
/// rows, so a reblessed fixture can't carry a wrong list.
#[test]
fn tools_fixture_body_is_the_router_order_list_with_meta_rows() {
    let rows = load_rows(&tools_dir()).expect("tools/index.json parses");
    let row = rows
        .iter()
        .find(|r| r.path == TOOLS_PATH && r.status == 200)
        .expect("a 200 row");
    let path = tools_dir().join(&row.response);
    let committed =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    assert_eq!(committed, canonical_json(&expected_body()));
}

// ---------- AC 7: the full router starts with the route merged ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_starts_with_the_tools_route_and_serves_get_only() {
    // `TestServer` is `memex_mcp::server::router()`: a path parameter clash
    // panics only when it starts.
    let env = Env::start().await;

    let reply = env.get_with_token(TOOLS_PATH).await;
    assert_eq!(reply.status, 200, "{}", reply.body);

    assert_wrong_method_is_c1_405(&env.srv, &[(TOOLS_PATH, &["GET"])]).await;

    // Nothing else sits under `/tools`.
    let below = env.get_with_token(&format!("{BASE}/tools/search")).await;
    assert_eq!(below.status, 404, "{}", below.body);
    assert_eq!(below.c1_code(), "not_found");
}
