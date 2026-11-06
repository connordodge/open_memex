//! WI #82 (V2): daily notes, review state, blocks, the Topics footer and
//! excerpts over the app API, Rust half.
//!
//! The daily routes under `/vaults/{name}/api/v1`, served by the in-process
//! vault server (`127.0.0.1:0`) over #74's frozen seed:
//!
//! | Route | Response |
//! |---|---|
//! | `GET /daily-notes` | `{"daily_notes":[{date,note_id,preview,review_state}]}` |
//! | `GET /daily-notes/{date}` | `{"daily_note":{…}}` or `{"daily_note":null}` |
//! | `GET /notes/{note_id}/review` | `{"state","reviewed_at"}` |
//! | `GET /notes/{note_id}/blocks` | `{"blocks":[{block_id,ord,text,source,created_version,created_at,start_byte,end_byte}]}` |
//! | `GET /notes/{note_id}/footer-chips` | `{"chips":[{topic_note_id,topic_title,origin}]}` |
//! | `DELETE /notes/{topic_note_id}/excerpts?date=&block_ids=from[,to]` | the `memex excerpt rm` object |
//! | `POST /notes/{daily_note_id}/footer-chips {topic_note_id}` | the `memex footer add` object (200) |
//!
//! Errors are the C1 body the CLI prints for the same failure. The fixture
//! rows in `app/test/fixtures/api_v1/daily/index.json` were made from the
//! app's local `DailyReads` on `seededFakeVaultDb()` and from the `memex`
//! CLI on a copy of the seed (in row order), then frozen: never rebless them
//! to fit the server.
//!
//! Every CLI parity test runs the real `memex` binary on a second copy of the
//! seed (temp dirs only).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use axum::Router;
use chrono::{Local, NaiveDate, TimeZone};
use memex_core::caller::Caller;
use memex_core::notes::NoteId;
use memex_core::{excerpts, Clock, Vault};
use memex_mcp::server::{router, ServerConfig};
use regex::Regex;
use rusqlite::Connection;
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

const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
const DAY_17: &str = "01M5DQAYZ5T5B865CDF2RWAC37";
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
const DAY_19: &str = "01M5DQAYZ51PF87XFZWSV5PWXK";
/// A valid ULID no seed note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

fn daily_dir() -> PathBuf {
    api_v1_dir().join("daily")
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

    /// `DELETE /notes/{topic}/excerpts?date=&block_ids=` on the server.
    async fn excerpt_rm(&self, topic: &str, date: &str, block_ids: &str) -> Reply {
        self.call(
            "DELETE",
            &format!("/notes/{topic}/excerpts?date={date}&block_ids={block_ids}"),
            None,
        )
        .await
    }

    /// `memex excerpt rm` on the CLI's copy.
    fn cli_excerpt_rm(&self, topic: &str, date: &str, block_ids: &str) -> Cli {
        self.cli(&[
            "excerpt",
            "rm",
            "--topic-note-id",
            topic,
            "--date",
            date,
            "--block-ids",
            block_ids,
        ])
    }

    /// `POST /notes/{daily}/footer-chips {"topic_note_id": topic}`.
    async fn footer_add(&self, daily: &str, topic: &str) -> Reply {
        self.call(
            "POST",
            &format!("/notes/{daily}/footer-chips"),
            Some(&json!({ "topic_note_id": topic })),
        )
        .await
    }

    /// `memex footer add` on the CLI's copy.
    fn cli_footer_add(&self, daily: &str, topic: &str) -> Cli {
        self.cli(&[
            "footer",
            "add",
            "--daily-note-id",
            daily,
            "--topic-note-id",
            topic,
        ])
    }

    /// Runs `memex <sub> <cmd> --vault <cli copy> <args…>`.
    fn cli(&self, args: &[&str]) -> Cli {
        let out = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(&args[..2])
            .arg("--vault")
            .arg(self.cli_vault())
            .args(&args[2..])
            .output()
            .expect("run memex");
        Cli {
            ok: out.status.success(),
            stdout: String::from_utf8(out.stdout).unwrap(),
            stderr: String::from_utf8(out.stderr).unwrap(),
        }
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

/// `SELECT <cols> FROM <table> ORDER BY <order>` as JSON rows.
fn table(vault: &Path, cols: &str, from: &str, order: &str) -> Value {
    let conn = db(vault);
    let mut stmt = conn
        .prepare(&format!("SELECT {cols} FROM {from} ORDER BY {order}"))
        .unwrap();
    let n = stmt.column_count();
    let rows = stmt
        .query_map([], |r| {
            let mut row = Vec::with_capacity(n);
            for i in 0..n {
                let v: rusqlite::types::Value = r.get(i)?;
                row.push(match v {
                    rusqlite::types::Value::Null => Value::Null,
                    rusqlite::types::Value::Integer(i) => json!(i),
                    rusqlite::types::Value::Real(f) => json!(f),
                    rusqlite::types::Value::Text(s) => json!(s),
                    rusqlite::types::Value::Blob(b) => json!(b),
                });
            }
            Ok(Value::Array(row))
        })
        .unwrap();
    Value::Array(rows.map(|r| r.unwrap()).collect())
}

/// What a daily write may touch, without the wall-clock columns: notes,
/// blocks, review rows, footer chips (rowid order), agent changes.
fn daily_state(vault: &Path) -> Value {
    json!({
        "notes": table(vault, "id, title, content_md, frontmatter, version", "notes", "id"),
        "blocks": table(
            vault,
            "note_id, block_id, ord, start_byte, end_byte, text, source, created_version",
            "blocks",
            "note_id, ord",
        ),
        "day_reviews": table(
            vault,
            "note_id, content_version, reviewed_content_version, reviewed_at",
            "day_reviews",
            "note_id",
        ),
        "footer_chips": table(
            vault,
            "daily_note_id, topic_note_id, origin",
            "footer_chips",
            "rowid",
        ),
        "agent_changes": table(vault, "note_id, day, bullets_json", "agent_changes", "note_id, day"),
    })
}

/// `(version, updated_at)` of a note.
fn version_and_stamp(vault: &Path, id: &str) -> (i64, i64) {
    db(vault)
        .query_row(
            "SELECT version, updated_at FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

fn content_of(vault: &Path, id: &str) -> String {
    db(vault)
        .query_row("SELECT content_md FROM notes WHERE id = ?", [id], |r| {
            r.get(0)
        })
        .unwrap()
}

/// Files two more excerpts into Economy Design, as an agent would: block
/// `v4vv62` of 2026-10-19 (so that day holds two single-block tokens) and
/// the range `6v4mr7..65a642` of 2026-10-18 (whose chip is `person`).
fn add_extra_excerpts(vault_dir: &Path) {
    let mut vault = Vault::open(vault_dir).expect("open the seed copy");
    let economy = NoteId::parse(ECONOMY).unwrap();
    excerpts::add_excerpt(
        &mut vault,
        &economy,
        "2026-10-19",
        &["v4vv62".to_string()],
        Caller::Agent,
        None,
    )
    .expect("file v4vv62");
    excerpts::add_excerpt(
        &mut vault,
        &economy,
        "2026-10-18",
        &["6v4mr7".to_string(), "65a642".to_string()],
        Caller::Agent,
        None,
    )
    .expect("file the 2026-10-18 range");
}

// ---------------------------------------------------------------------------
// AC 1, 5 and 7: the fixture rows
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

/// `(METHOD, path template)` of a row: ULIDs become `{id}`, the segment
/// after `/daily-notes/` becomes `{date}`, and the query is reduced to its
/// parameter names.
fn template(row: &FixtureRow) -> (String, String) {
    let ulid = Regex::new(r"[0-7][0-9A-HJKMNP-TV-Z]{25}").unwrap();
    let date = Regex::new(r"^/daily-notes/[^/?]+").unwrap();
    let path = row
        .path
        .strip_prefix(BASE)
        .unwrap_or_else(|| panic!("row path {} is not under {BASE}", row.path));
    let (p, q) = path.split_once('?').unwrap_or((path, ""));
    let t = ulid.replace_all(p, "{id}").into_owned();
    let mut t = date.replace(&t, "/daily-notes/{date}").into_owned();
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

/// The routes of the WI #82 table, as `(METHOD, path)` under `BASE`.
const ROUTES: &[(&str, &str)] = &[
    ("GET", "/daily-notes"),
    ("GET", "/daily-notes/{date}"),
    ("GET", "/notes/{id}/review"),
    ("GET", "/notes/{id}/blocks"),
    ("GET", "/notes/{id}/footer-chips"),
    ("POST", "/notes/{id}/footer-chips"),
    ("DELETE", "/notes/{id}/excerpts"),
];

#[test]
fn daily_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&daily_dir()).expect("daily/index.json parses");
    let seen: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    for want in [
        ("GET", "/daily-notes"),
        ("GET", "/daily-notes/{date}"),
        ("GET", "/notes/{id}/review"),
        ("GET", "/notes/{id}/blocks"),
        ("GET", "/notes/{id}/footer-chips"),
        ("POST", "/notes/{id}/footer-chips"),
        ("DELETE", "/notes/{id}/excerpts?date&block_ids"),
    ] {
        let want = (want.0.to_string(), want.1.to_string());
        assert!(seen.contains(&want), "daily/ has a row for {want:?}");
    }
    // The edge rows the AC names are there: a miss for a real date and for
    // a string that isn't one, every review state, and both chip origins.
    let file = |name: &str| -> Value {
        serde_json::from_slice(&std::fs::read(daily_dir().join(name)).unwrap()).unwrap()
    };
    for path in ["/daily-notes/2026-10-20", "/daily-notes/not-a-date"] {
        let row = rows
            .iter()
            .find(|r| r.path == format!("{BASE}{path}"))
            .unwrap_or_else(|| panic!("a row for {path}"));
        assert_eq!(file(&row.response), json!({"daily_note": null}), "{path}");
    }
    let states: BTreeSet<String> = rows
        .iter()
        .filter(|r| r.path.ends_with("/review"))
        .map(|r| file(&r.response)["state"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        states,
        ["Changed since review", "Reviewed", "Unreviewed"]
            .map(String::from)
            .into()
    );
    let origins: BTreeSet<String> = rows
        .iter()
        .filter(|r| r.method == "GET" && r.path.ends_with("/footer-chips"))
        .flat_map(|r| {
            file(&r.response)["chips"]
                .as_array()
                .unwrap()
                .iter()
                .map(|c| c["origin"].as_str().unwrap().to_string())
                .collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(origins, ["excerpt", "person"].map(String::from).into());
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every daily row runs in Rust"
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&daily_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn daily_notes_answers_newest_date_first_with_the_unreviewed_day() {
    let env = Env::start().await;
    let reply = env.call("GET", "/daily-notes", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    let days: Vec<(&str, &str)> = v["daily_notes"]
        .as_array()
        .expect("daily_notes is a list inside an object")
        .iter()
        .map(|d| {
            (
                d["date"].as_str().unwrap(),
                d["review_state"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        days,
        vec![
            ("2026-10-19", "Unreviewed"),
            ("2026-10-18", "Reviewed"),
            ("2026-10-17", "Changed since review"),
            ("2026-10-16", "Unreviewed"),
            ("2026-10-15", "Unreviewed"),
        ]
    );
    // The multi-line first block previews its first line only; the pre-V5
    // day (no blocks) previews as empty.
    assert_eq!(
        v["daily_notes"][3]["preview"],
        "Morning playtest with the new crafting tree"
    );
    assert_eq!(v["daily_notes"][4]["preview"], "");
}

// ---------------------------------------------------------------------------
// AC 4: a daily note for a date that has none
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn daily_note_for_a_date_without_one_is_daily_note_null() {
    let env = Env::start().await;
    for segment in [
        "2026-10-20",
        "2026-02-30",
        "not-a-date",
        "Loose%20Thought",
        "Broken%20Frontmatter",
        "Economy%20Design",
        "%20",
    ] {
        let reply = env
            .call("GET", &format!("/daily-notes/{segment}"), None)
            .await;
        assert_eq!(reply.status, 200, "{segment}: {}", reply.body);
        assert_eq!(reply.json(), json!({"daily_note": null}), "{segment}");
    }
    let hit = env.call("GET", "/daily-notes/2026-10-18", None).await;
    assert_eq!(
        hit.json(),
        json!({"daily_note": {
            "date": "2026-10-18",
            "note_id": DAY_18,
            "preview": "Played the prototype for an hour.",
            "review_state": "Reviewed",
        }})
    );
}

// ---------------------------------------------------------------------------
// AC 11: the route inventory
// ---------------------------------------------------------------------------

#[test]
fn daily_index_routes_are_exactly_the_wi_table() {
    let rows = load_rows(&daily_dir()).expect("daily/index.json parses");
    let served: BTreeSet<(String, String)> = rows
        .iter()
        .map(|r| {
            let (m, t) = template(r);
            (m, t.split('?').next().unwrap().to_string())
        })
        .collect();
    let table: BTreeSet<(String, String)> = ROUTES
        .iter()
        .map(|(m, p)| (m.to_string(), p.to_string()))
        .collect();
    assert_eq!(served, table, "daily/index.json routes == the WI #82 table");

    let allowed_query: BTreeSet<&str> = ["date", "block_ids"].into();
    for row in &rows {
        let (_, t) = template(row);
        if let Some((_, q)) = t.split_once('?') {
            for name in q.split('&') {
                assert!(allowed_query.contains(name), "{}: query {name}", row.path);
            }
        }
        if let Some(file) = &row.request {
            let body: Value =
                serde_json::from_slice(&std::fs::read(daily_dir().join(file)).unwrap()).unwrap();
            let keys: Vec<&String> = body
                .as_object()
                .expect("every request body is an object")
                .keys()
                .collect();
            assert_eq!(keys, vec!["topic_note_id"], "{file}");
        }
    }
}

/// Serves only `api::daily::router()`, nested where the server nests it,
/// with no vault guard: a served route answers anything but 404 and 405.
async fn serve_daily_router_alone() -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let app = Router::new().nest(
        "/vaults/{name}/api/v1",
        memex_mcp::server::api::daily::router(),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (addr, task)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn daily_router_serves_exactly_the_table_routes_and_no_prompt_append_or_review_write() {
    let (addr, task) = serve_daily_router_alone().await;
    let http = client();
    let concrete = |p: &str| {
        p.replace("{id}", DAY_19)
            .replace("{date}", "2026-10-19")
            .to_string()
    };
    let paths: BTreeSet<&str> = ROUTES.iter().map(|(_, p)| *p).collect();
    for path in paths {
        for method in PROBE_METHODS {
            let served = ROUTES.iter().any(|(m, p)| *p == path && *m == method);
            let url = format!("http://{addr}{BASE}{}", concrete(path));
            let req = http.request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                &url,
            );
            let status = req.send().await.unwrap().status().as_u16();
            if served {
                assert!(
                    status != 404 && status != 405,
                    "{method} {path} is a daily route (got {status})"
                );
            } else {
                assert_eq!(status, 405, "{method} {path} is not a daily route");
            }
        }
    }
    // No review prompt (#83), prompt capture, append or review-write route
    // lives in the daily router.
    for path in [
        "/review-prompt".to_string(),
        "/review_prompt".to_string(),
        "/prompts/review".to_string(),
        "/prompt".to_string(),
        "/prompt/capture".to_string(),
        "/prompt-capture".to_string(),
        "/capture".to_string(),
        "/append".to_string(),
        "/daily-notes/2026-10-19/append".to_string(),
        "/daily-notes/2026-10-19/review".to_string(),
        format!("/notes/{DAY_19}/append"),
        format!("/notes/{DAY_19}/reviewed"),
        format!("/notes/{DAY_19}/mark-reviewed"),
        format!("/notes/{DAY_19}/review/prompt"),
        "/reviews".to_string(),
        "/review".to_string(),
    ] {
        for method in ["GET", "POST", "PUT"] {
            let url = format!("http://{addr}{BASE}{path}");
            let req = http.request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                &url,
            );
            let status = req.send().await.unwrap().status().as_u16();
            assert_eq!(status, 404, "{method} {path} has no daily route");
        }
    }
    task.abort();
}

/// Every `/notes/…` route names its parameter `{note_id}`, as the notes
/// slice (#81) does, because axum panics when merged routers name one
/// segment differently. The name is internal: the wire URLs stay
/// `/notes/<id>/…` on the merged `api::router()`, and the id a handler acts
/// on is the URL segment.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn daily_routes_keep_their_wire_urls_on_the_merged_api_router() {
    // Merging every domain router panics here on a parameter-name clash.
    let app = Router::new().nest("/vaults/{name}/api/v1", memex_mcp::server::api::router());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let http = client();
    for (method, path) in ROUTES {
        let concrete = path.replace("{id}", DAY_19).replace("{date}", "2026-10-19");
        let url = format!("http://{addr}{BASE}{concrete}");
        let status = http
            .request(
                reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
                &url,
            )
            .send()
            .await
            .unwrap()
            .status()
            .as_u16();
        assert!(
            status != 404 && status != 405,
            "{method} {concrete} is served by the merged api router (got {status})"
        );
    }
    task.abort();

    // Through the real server, the writes act on the id in the URL.
    let env = Env::start().await;
    let added = env.footer_add(DAY_17, PLAYER_LOOP).await;
    assert_eq!(added.status, 200, "{}", added.body);
    assert_eq!(added.json()["daily_note_id"], DAY_17);
    let removed = env.excerpt_rm(ECONOMY, "2026-10-19", "et8g8y").await;
    assert_eq!(removed.status, 200, "{}", removed.body);
    assert_eq!(removed.json()["topic_note_id"], ECONOMY);
    // A literal template segment is just a note id no note has.
    for literal in ["%7Bnote_id%7D", "%7Bid%7D"] {
        let reply = env
            .call("GET", &format!("/notes/{literal}/blocks"), None)
            .await;
        assert_eq!(
            (reply.status, reply.json()),
            (200, json!({ "blocks": [] })),
            "{literal}"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn daily_routes_answer_wrong_methods_with_the_c1_405() {
    let env = Env::start().await;
    let daily_notes = format!("{BASE}/daily-notes");
    let for_date = format!("{BASE}/daily-notes/2026-10-19");
    let review = format!("{BASE}/notes/{DAY_19}/review");
    let blocks = format!("{BASE}/notes/{DAY_19}/blocks");
    let chips = format!("{BASE}/notes/{DAY_19}/footer-chips");
    let excerpts = format!("{BASE}/notes/{ECONOMY}/excerpts");
    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (daily_notes.as_str(), &["GET"][..]),
            (for_date.as_str(), &["GET"][..]),
            (review.as_str(), &["GET"][..]),
            (blocks.as_str(), &["GET"][..]),
            (chips.as_str(), &["GET", "POST"][..]),
            (excerpts.as_str(), &["DELETE"][..]),
        ],
    )
    .await;
    // The probes wrote nothing.
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault())
    );
}

// ---------------------------------------------------------------------------
// AC 9: 401 without a token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_daily_route_answers_401_unauthorized_without_a_bearer_token() {
    let env = Env::start().await;
    let rows = load_rows(&daily_dir()).expect("daily/index.json parses");
    for row in &rows {
        let method = reqwest::Method::from_bytes(row.method.as_bytes()).unwrap();
        let body = row
            .request
            .as_ref()
            .map(|f| std::fs::read(daily_dir().join(f)).unwrap())
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
                reply.status, 200,
                "{} {} with the token: {}",
                row.method, row.path, reply.body
            );
        }
    }
    // Nothing was written without the token.
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault())
    );
}

// ---------------------------------------------------------------------------
// AC 5: excerpt removal answers like `memex excerpt rm`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_rm_answers_like_memex_excerpt_rm_and_takes_the_day_chip_with_the_last_excerpt() {
    let env = Env::start().await;
    let (version_before, _) = version_and_stamp(&env.server_vault(), ECONOMY);
    assert!(content_of(&env.server_vault(), ECONOMY).contains("![[2026-10-19#^et8g8y]]"));

    let reply = env.excerpt_rm(ECONOMY, "2026-10-19", "et8g8y").await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli_excerpt_rm(ECONOMY, "2026-10-19", "et8g8y");
    assert_eq!(
        norm(&reply.json()),
        norm(&cli.json()),
        "== memex excerpt rm"
    );
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": api_fixtures::seed_vault_id(),
            "topic_note_id": ECONOMY,
            "version": version_before + 1,
        })
    );

    let content = content_of(&env.server_vault(), ECONOMY);
    assert!(!content.contains("2026-10-19#^et8g8y"), "{content}");
    assert!(!content.contains("## 2026-10-19"), "empty heading goes too");
    assert_eq!(
        version_and_stamp(&env.server_vault(), ECONOMY).0,
        version_before + 1
    );
    // The topic's last excerpt from 2026-10-19 is gone, so is its chip.
    let chips = env
        .call("GET", &format!("/notes/{DAY_19}/footer-chips"), None)
        .await;
    assert_eq!(chips.json(), json!({"chips": []}));
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault()),
        "the server and the CLI left identical vaults"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_rm_keeps_the_chip_while_the_topic_holds_another_excerpt_from_that_day() {
    let env = Env::start_with(add_extra_excerpts).await;
    let chip_of_19 = || async {
        env.call("GET", &format!("/notes/{DAY_19}/footer-chips"), None)
            .await
            .json()
    };
    let excerpt_chip = json!({"chips": [{
        "topic_note_id": ECONOMY,
        "topic_title": "Economy Design",
        "origin": "excerpt",
    }]});

    // Two tokens from 2026-10-19: removing one keeps the chip.
    let reply = env.excerpt_rm(ECONOMY, "2026-10-19", "et8g8y").await;
    let cli = env.cli_excerpt_rm(ECONOMY, "2026-10-19", "et8g8y");
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
    assert_eq!(chip_of_19().await, excerpt_chip);
    let content = content_of(&env.server_vault(), ECONOMY);
    assert!(content.contains("![[2026-10-19#^v4vv62]]"), "{content}");
    assert!(content.contains("## 2026-10-19"), "{content}");

    // The last one takes the chip.
    let reply = env.excerpt_rm(ECONOMY, "2026-10-19", "v4vv62").await;
    let cli = env.cli_excerpt_rm(ECONOMY, "2026-10-19", "v4vv62");
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
    assert_eq!(chip_of_19().await, json!({"chips": []}));

    // A range token matches only by both endpoints: one id is not_found.
    let reply = env.excerpt_rm(ECONOMY, "2026-10-18", "6v4mr7").await;
    let cli = env.cli_excerpt_rm(ECONOMY, "2026-10-18", "6v4mr7");
    assert_c1(&reply, 404, "not_found");
    assert_eq!(reply.json(), cli.error());

    // `block_ids=from,to` removes the range; the day's person chip stays.
    let reply = env.excerpt_rm(ECONOMY, "2026-10-18", "6v4mr7,65a642").await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli_excerpt_rm(ECONOMY, "2026-10-18", "6v4mr7,65a642");
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
    let content = content_of(&env.server_vault(), ECONOMY);
    assert!(!content.contains("2026-10-18#^"), "{content}");
    let chips18 = env
        .call("GET", &format!("/notes/{DAY_18}/footer-chips"), None)
        .await;
    assert_eq!(
        chips18.json(),
        json!({"chips": [{
            "topic_note_id": ECONOMY,
            "topic_title": "Economy Design",
            "origin": "person",
        }]})
    );
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault())
    );
}

// ---------------------------------------------------------------------------
// AC 6: excerpt removal errors match the CLI
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_rm_errors_are_the_cli_c1_bodies() {
    let env = Env::start().await;
    // (topic, date, block_ids, status, code)
    let cases: &[(&str, &str, &str, u16, &str)] = &[
        // The topic is a daily note, or has no role.
        (DAY_18, "2026-10-18", "6v4mr7", 422, "role_rule"),
        (LOOSE, "2026-10-19", "et8g8y", 422, "role_rule"),
        // Unknown topic; no such transclusion; no daily note that day.
        (UNKNOWN, "2026-10-19", "et8g8y", 404, "not_found"),
        (ECONOMY, "2026-10-19", "v4vv62", 404, "not_found"),
        (ECONOMY, "2026-10-21", "et8g8y", 404, "not_found"),
        // Not a calendar date.
        (ECONOMY, "2026-13-01", "et8g8y", 400, "invalid_date"),
        (ECONOMY, "2026-02-30", "et8g8y", 400, "invalid_date"),
        (ECONOMY, "yesterday", "et8g8y", 400, "invalid_date"),
        // A blank block id, before anything else is checked.
        (ECONOMY, "2026-10-19", "et8g8y,", 400, "invalid_argument"),
        (ECONOMY, "2026-10-19", ",et8g8y", 400, "invalid_argument"),
        (ECONOMY, "2026-10-19", "", 400, "invalid_argument"),
        (ECONOMY, "2026-10-19", "%20", 400, "invalid_argument"),
        (DAY_18, "2026-13-01", "et8g8y,", 400, "invalid_argument"),
    ];
    for (topic, date, ids, status, code) in cases {
        let reply = env.excerpt_rm(topic, date, ids).await;
        let what = format!("{topic} {date} {ids:?}");
        assert_eq!(
            (reply.status, reply.c1_code()),
            (*status, code.to_string()),
            "{what}: {}",
            reply.body
        );
        let cli_ids = ids.replace("%20", " ");
        let cli = env.cli_excerpt_rm(topic, date, &cli_ids);
        assert_eq!(reply.json(), cli.error(), "{what}: the CLI's C1 body");
    }
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault()),
        "no failed removal wrote anything"
    );
    assert_eq!(
        daily_state(&env.server_vault())["notes"],
        {
            let fresh = tempfile::tempdir().unwrap();
            daily_state(&materialize_seed(fresh.path()))["notes"].clone()
        },
        "the seed notes are untouched"
    );
}

// ---------------------------------------------------------------------------
// AC 7: footer add answers like `memex footer add`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn footer_add_answers_like_memex_footer_add_and_a_repeat_changes_nothing() {
    let env = Env::start().await;
    let (v17, _) = version_and_stamp(&env.server_vault(), DAY_17);

    let reply = env.footer_add(DAY_17, PLAYER_LOOP).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli_footer_add(DAY_17, PLAYER_LOOP);
    assert_eq!(
        norm(&reply.json()),
        norm(&cli.json()),
        "== memex footer add"
    );
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": api_fixtures::seed_vault_id(),
            "daily_note_id": DAY_17,
            "topic_note_id": PLAYER_LOOP,
            "origin": "person",
            "version": v17 + 1,
        })
    );
    assert!(content_of(&env.server_vault(), DAY_17).contains("[[Player Loop~about]]"));

    // A repeat answers the same and writes nothing.
    let before = daily_state(&env.server_vault());
    let stamp = version_and_stamp(&env.server_vault(), DAY_17);
    let again = env.footer_add(DAY_17, PLAYER_LOOP).await;
    let cli_again = env.cli_footer_add(DAY_17, PLAYER_LOOP);
    assert_eq!(again.status, 200, "{}", again.body);
    assert_eq!(norm(&again.json()), norm(&cli_again.json()));
    assert_eq!(again.json(), reply.json(), "a repeat answers the same");
    assert_eq!(daily_state(&env.server_vault()), before);
    assert_eq!(version_and_stamp(&env.server_vault(), DAY_17), stamp);

    let chips = env
        .call("GET", &format!("/notes/{DAY_17}/footer-chips"), None)
        .await;
    assert_eq!(
        chips.json(),
        json!({"chips": [{
            "topic_note_id": PLAYER_LOOP,
            "topic_title": "Player Loop",
            "origin": "person",
        }]})
    );
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn footer_add_upgrades_an_excerpt_chip_to_person_in_place() {
    let env = Env::start().await;
    // Day 19 holds Economy Design as an `excerpt` chip; add a second chip
    // after it, then upgrade the first.
    let reply = env.footer_add(DAY_19, PLAYER_LOOP).await;
    let cli = env.cli_footer_add(DAY_19, PLAYER_LOOP);
    assert_eq!(norm(&reply.json()), norm(&cli.json()));

    let reply = env.footer_add(DAY_19, ECONOMY).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli_footer_add(DAY_19, ECONOMY);
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
    assert_eq!(reply.json()["origin"], "person");

    let chips = env
        .call("GET", &format!("/notes/{DAY_19}/footer-chips"), None)
        .await;
    assert_eq!(
        chips.json(),
        json!({"chips": [
            {"topic_note_id": ECONOMY, "topic_title": "Economy Design", "origin": "person"},
            {"topic_note_id": PLAYER_LOOP, "topic_title": "Player Loop", "origin": "person"},
        ]}),
        "the upgraded chip keeps its place"
    );
    // A person chip outlives the topic's last excerpt from that day.
    let rm = env.excerpt_rm(ECONOMY, "2026-10-19", "et8g8y").await;
    assert_eq!(rm.status, 200, "{}", rm.body);
    let cli = env.cli_excerpt_rm(ECONOMY, "2026-10-19", "et8g8y");
    assert_eq!(norm(&rm.json()), norm(&cli.json()));
    let chips = env
        .call("GET", &format!("/notes/{DAY_19}/footer-chips"), None)
        .await;
    assert_eq!(chips.json()["chips"].as_array().unwrap().len(), 2);
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn footer_add_errors_are_the_cli_c1_bodies() {
    let env = Env::start().await;
    // (daily, topic, status, code). Since WI #238 any note but a guide may
    // hold chips, so a non-daily host is no longer an error; a non-topic
    // target still is.
    let cases: &[(&str, &str, u16, &str)] = &[
        (DAY_18, DAY_19, 422, "role_rule"),
        (DAY_18, LOOSE, 422, "role_rule"),
        (UNKNOWN, PLAYER_LOOP, 404, "not_found"),
        (DAY_18, UNKNOWN, 404, "not_found"),
    ];
    for (daily, topic, status, code) in cases {
        let reply = env.footer_add(daily, topic).await;
        let what = format!("{daily} <- {topic}");
        assert_eq!(
            (reply.status, reply.c1_code()),
            (*status, code.to_string()),
            "{what}: {}",
            reply.body
        );
        let cli = env.cli_footer_add(daily, topic);
        assert_eq!(reply.json(), cli.error(), "{what}: the CLI's C1 body");
    }
    assert_eq!(
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault())
    );
}

// ---------------------------------------------------------------------------
// AC 8: malformed requests
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_bodies_and_missing_queries_get_400_invalid_argument() {
    let env = Env::start().await;
    let chips = format!("/notes/{DAY_17}/footer-chips");
    let json_ct = Some("application/json");
    let cases: Vec<(&str, String, Option<&str>, Vec<u8>)> = vec![
        (
            "POST",
            chips.clone(),
            json_ct,
            b"{\"topic_note_id\": ".to_vec(),
        ),
        ("POST", chips.clone(), json_ct, b"not json".to_vec()),
        ("POST", chips.clone(), json_ct, b"[]".to_vec()),
        ("POST", chips.clone(), json_ct, b"{}".to_vec()),
        ("POST", chips.clone(), json_ct, b"".to_vec()),
        (
            "POST",
            chips.clone(),
            json_ct,
            br#"{"topic_note_id": 7}"#.to_vec(),
        ),
        (
            "POST",
            chips.clone(),
            json_ct,
            br#"{"topic_note_id": null}"#.to_vec(),
        ),
        (
            "POST",
            chips.clone(),
            json_ct,
            format!(r#"{{"topic": "{PLAYER_LOOP}"}}"#).into_bytes(),
        ),
        // A JSON body without the JSON content type.
        (
            "POST",
            chips.clone(),
            None,
            format!(r#"{{"topic_note_id": "{PLAYER_LOOP}"}}"#).into_bytes(),
        ),
        ("DELETE", format!("/notes/{ECONOMY}/excerpts"), None, vec![]),
        (
            "DELETE",
            format!("/notes/{ECONOMY}/excerpts?block_ids=et8g8y"),
            None,
            vec![],
        ),
        (
            "DELETE",
            format!("/notes/{ECONOMY}/excerpts?date=2026-10-19"),
            None,
            vec![],
        ),
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
        daily_state(&env.server_vault()),
        daily_state(&env.cli_vault()),
        "no malformed request wrote anything"
    );
}

// ---------------------------------------------------------------------------
// Dates: no daily route reads "today" from the request clock
// ---------------------------------------------------------------------------

/// A clock stopped at one instant.
struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// Unix ms of `date` `h:m:s.ms` in this machine's local time.
fn local_ms(date: &str, h: u32, m: u32, s: u32, ms: u32) -> i64 {
    let naive = NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .unwrap()
        .and_hms_milli_opt(h, m, s, ms)
        .unwrap();
    Local
        .from_local_datetime(&naive)
        .earliest()
        .expect("a local time")
        .timestamp_millis()
}

/// A vault server over a fresh seed copy whose base clock is `now_ms`.
async fn serve_seed_at(
    now_ms: i64,
) -> (TempDir, std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN)
        .with_clock(Arc::new(FixedClock(now_ms)));
    let app = router(config);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (root, addr, task)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn daily_routes_answer_the_same_on_either_side_of_midnight_and_never_default_the_date() {
    let fixture = |name: &str| -> Value {
        serde_json::from_slice(&std::fs::read(daily_dir().join(name)).unwrap()).unwrap()
    };
    // The last millisecond of 2026-10-19 and the first of 2026-10-20, in the
    // server's local time (the base clock's own mapping, req 59 fallback).
    for now in [
        local_ms("2026-10-19", 23, 59, 59, 999),
        local_ms("2026-10-20", 0, 0, 0, 0),
    ] {
        let (_root, addr, task) = serve_seed_at(now).await;
        let get = |path: &str| {
            let url = format!("http://{addr}{BASE}{path}");
            async move {
                Reply::read(
                    client()
                        .get(url)
                        .header("authorization", format!("Bearer {TEST_TOKEN}"))
                        .send()
                        .await
                        .unwrap(),
                )
                .await
            }
        };
        let list = get("/daily-notes").await;
        assert_eq!(
            canonical_json(&list.json()),
            canonical_json(&fixture("daily_notes.json")),
            "at {now}"
        );
        for date in ["2026-10-19", "2026-10-20"] {
            let want = if date == "2026-10-19" {
                fixture("daily_note_2026_10_19.json")
            } else {
                json!({"daily_note": null})
            };
            assert_eq!(
                get(&format!("/daily-notes/{date}")).await.json(),
                want,
                "{date} at {now}"
            );
        }
        // An excerpt removal never takes "today" for a missing date.
        let reply = Reply::read(
            client()
                .delete(format!(
                    "http://{addr}{BASE}/notes/{ECONOMY}/excerpts?block_ids=et8g8y"
                ))
                .header("authorization", format!("Bearer {TEST_TOKEN}"))
                .send()
                .await
                .unwrap(),
        )
        .await;
        assert_c1(&reply, 400, "invalid_argument");
        task.abort();
    }
}
