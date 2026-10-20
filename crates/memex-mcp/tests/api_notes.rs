//! WI #81 (V1): notes and links over the app API, Rust half.
//!
//! The notes routes under `/vaults/{name}/api/v1`, served by the in-process
//! vault server (`127.0.0.1:0`) over #74's frozen seed:
//!
//! | Route | Response |
//! |---|---|
//! | `GET /notes?limit=` | `{"notes":[{id,title,snippet,version,updated_at}]}` |
//! | `GET /notes/{note_id}` | the `memex get` object; unknown id: C1 `not_found` |
//! | `GET /titles?limit=` | `{"titles":[{id,title,updated_at}]}` |
//! | `GET /notes/{note_id}/links/out` | `{"links":[{id,from_note_id,to_note_id,link_text,kind,label,position,source}]}` |
//! | `GET /notes/{note_id}/links/in[?kind=]` | the same |
//! | `POST /titles/lookup {"ids"}` | `{"titles":{"<id>":"<title>"}}` |
//! | `GET /link-kinds` | `{"kinds":[…]}` |
//! | `POST /notes {title?,tags?,role?,content_md}` | 201, `{note_id,title,tags,adopted}` |
//! | `PATCH /notes/{note_id} {expected_version,title?,content_md,no_rename_links?}` | `{note_id,version,updated_at}` |
//! | `DELETE /notes/{note_id}?expected_version=` | `{vault_id,note_id,deleted}` |
//! | `POST /links {from,to,kind?,label?}` | the `memex add-link` object |
//! | `PATCH /links/{link_id} {kind?,label?,clear_label?}` | the `memex update-link` object |
//!
//! Errors are the C1 body the CLI prints for the same failure. The fixture
//! rows in `app/test/fixtures/api_v1/notes/index.json` were made from the
//! local app reads (`VaultDb`, with the D10b snippet guard) and from the
//! `memex` CLI on a copy of the seed, then frozen: never rebless them to fit
//! the server.
//!
//! Every CLI parity test runs the real `memex` binary on a second copy of
//! the seed (temp dirs only).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use regex::Regex;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use tempfile::TempDir;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, normalize_volatile, run_rows,
    FixtureRequest, FixtureResponse, FixtureRow, SEED_VAULT_NAME,
};
use server::{client, raw_request, Reply, TestServer};

const BASE: &str = "/vaults/seed/api/v1";

const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
const PACING: &str = "01M5DQAYZ4YAPYMEDWXP8WCNGJ";
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
const DAY_19: &str = "01M5DQAYZ51PF87XFZWSV5PWXK";
const DAY_15: &str = "01M5DQAYZ592W2515HPSDF5Q16";
const BROKEN: &str = "01M5DQAYZ5RH88SRZGPY15XXVM";
/// A valid ULID no seed note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";
/// Pacing Notes -> Player Loop, label "the loop".
const PACING_LINK: &str = "01M5DQAYZDBGZSDQ7X3PJT783V";
/// Economy Design -> Player Loop, kind extends.
const ECONOMY_LINK: &str = "01M5DQAYZFCB2T0ECN4HG7XFQM";

fn notes_dir() -> PathBuf {
    api_v1_dir().join("notes")
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

    /// Runs `memex <args…>` on the CLI's seed copy (`--vault` is added after
    /// the subcommand) with `stdin`.
    fn cli(&self, args: &[&str], stdin: &str) -> Cli {
        let vault = self.cli_vault();
        let mut full: Vec<String> = vec![args[0].to_string(), "--vault".into()];
        full.push(vault.to_string_lossy().into_owned());
        full.extend(args[1..].iter().map(|s| s.to_string()));
        run_cli(&full, stdin)
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

    /// `memex add`'s text output as its `AddOutput` struct.
    fn add_output(&self) -> Value {
        assert!(self.ok, "memex add failed: {}", self.stderr);
        let field = |k: &str| {
            self.stdout.lines().find_map(|l| {
                l.trim()
                    .strip_prefix(&format!("{k}:"))
                    .map(|v| v.trim().to_string())
            })
        };
        let tags: Vec<String> = field("tags")
            .map(|t| t.split(", ").map(String::from).collect())
            .unwrap_or_default();
        json!({
            "note_id": field("note_id").expect("note_id line"),
            "title": field("title").expect("title line"),
            "tags": tags,
            "adopted": self.stdout.starts_with("Adopted note"),
        })
    }
}

fn run_cli(args: &[String], stdin: &str) -> Cli {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex");
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    drop(child.stdin.take());
    let out = child.wait_with_output().expect("wait for memex");
    Cli {
        ok: out.status.success(),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    }
}

fn norm(v: &Value) -> Value {
    normalize_volatile(v)
}

/// A read-only look at a vault's database (the server keeps its own
/// connection open; WAL lets this one read alongside).
fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

/// `(title, content_md, frontmatter, version)` of a note, or `None`.
fn note_row(vault: &Path, id: &str) -> Option<(String, String, String, i64)> {
    db(vault)
        .query_row(
            "SELECT title, content_md, frontmatter, version FROM notes WHERE id = ?",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .unwrap()
}

/// The id of the note titled `title`.
fn id_of(vault: &Path, title: &str) -> String {
    db(vault)
        .query_row(
            "SELECT id FROM notes WHERE title = ?",
            params![title],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("no note titled {title}: {e}"))
}

fn note_count(vault: &Path) -> i64 {
    db(vault)
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

fn tags_of(vault: &Path, id: &str) -> Vec<String> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare("SELECT tag FROM tags WHERE note_id = ? ORDER BY tag")
        .unwrap();
    let rows = stmt.query_map(params![id], |r| r.get(0)).unwrap();
    rows.map(|r| r.unwrap()).collect()
}

/// `(link_text, kind, label, to_note_id)` of a note's outgoing links, by
/// position.
fn links_of(vault: &Path, id: &str) -> Vec<(String, String, Option<String>, Option<String>)> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare(
            "SELECT link_text, link_kind, label, to_note_id FROM links
             WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap();
    let rows = stmt
        .query_map(params![id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap();
    rows.map(|r| r.unwrap()).collect()
}

fn assert_c1(reply: &Reply, status: u16, code: &str) {
    assert_eq!(
        (reply.status, reply.c1_code()),
        (status, code.to_string()),
        "body: {}",
        reply.body
    );
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

/// The routes of the WI #81 table, as `(METHOD, path)` under `BASE`.
const ROUTES: &[(&str, &str)] = &[
    ("GET", "/notes"),
    ("GET", "/notes/{id}"),
    ("GET", "/titles"),
    ("GET", "/notes/{id}/links/out"),
    ("GET", "/notes/{id}/links/in"),
    ("POST", "/titles/lookup"),
    ("GET", "/link-kinds"),
    ("POST", "/notes"),
    ("PATCH", "/notes/{id}"),
    ("DELETE", "/notes/{id}"),
    ("POST", "/links"),
    ("PATCH", "/links/{id}"),
];

#[test]
fn notes_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&notes_dir()).expect("notes/index.json parses");
    let seen: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    for want in [
        ("GET", "/notes?limit"),
        ("GET", "/notes/{id}"),
        ("GET", "/titles?limit"),
        ("GET", "/notes/{id}/links/out"),
        ("GET", "/notes/{id}/links/in"),
        ("GET", "/notes/{id}/links/in?kind"),
        ("POST", "/titles/lookup"),
        ("GET", "/link-kinds"),
        ("POST", "/notes"),
        ("PATCH", "/notes/{id}"),
        ("DELETE", "/notes/{id}?expected_version"),
        ("POST", "/links"),
        ("PATCH", "/links/{id}"),
    ] {
        let want = (want.0.to_string(), want.1.to_string());
        assert!(seen.contains(&want), "notes/ has a row for {want:?}");
    }
    let statuses: BTreeSet<(String, u16)> =
        rows.iter().map(|r| (template(r).1, r.status)).collect();
    assert!(statuses.contains(&("/notes/{id}".to_string(), 404)));
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every notes row runs in Rust"
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&notes_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

// ---------------------------------------------------------------------------
// AC 14: the route inventory
// ---------------------------------------------------------------------------

#[test]
fn notes_index_routes_are_exactly_the_wi_table_and_take_no_sql_or_argv() {
    let rows = load_rows(&notes_dir()).expect("notes/index.json parses");
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
    assert_eq!(served, table, "notes/index.json routes == the WI #81 table");

    let allowed_query: BTreeSet<&str> = ["limit", "kind", "expected_version"].into();
    let allowed_body: BTreeSet<&str> = [
        "ids",
        "title",
        "tags",
        "role",
        "content_md",
        "expected_version",
        "no_rename_links",
        "from",
        "to",
        "kind",
        "label",
        "clear_label",
    ]
    .into();
    for row in &rows {
        let (_, t) = template(row);
        if let Some((_, q)) = t.split_once('?') {
            for name in q.split('&') {
                assert!(allowed_query.contains(name), "{}: query {name}", row.path);
            }
        }
        if let Some(file) = &row.request {
            let body: Value =
                serde_json::from_slice(&std::fs::read(notes_dir().join(file)).unwrap()).unwrap();
            let obj = body.as_object().expect("every request body is an object");
            for key in obj.keys() {
                assert!(
                    allowed_body.contains(key.as_str()),
                    "{file}: field {key} (no SQL, argv or embedding switch)"
                );
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn notes_router_serves_exactly_the_table_routes() {
    let env = Env::start().await;
    let concrete = |p: &str| p.replace("{id}", LOOSE);
    // Every method a table path does not serve is the C1 405.
    for path in BTreeSet::from_iter(ROUTES.iter().map(|(_, p)| *p)) {
        let served: Vec<&str> = ROUTES
            .iter()
            .filter(|(_, p)| *p == path)
            .map(|(m, _)| *m)
            .collect();
        for method in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
            if served.contains(&method) {
                continue;
            }
            let reply = env.call(method, &concrete(path), None).await;
            assert_eq!(
                (reply.status, reply.c1_code()),
                (405, "method_not_allowed".to_string()),
                "{method} {path}: {}",
                reply.body
            );
        }
    }
    // Nothing else lives under the notes paths: no noteUpdatedAt route, no
    // SQL or CLI passthrough.
    for path in [
        format!("/notes/{LOOSE}/updated_at"),
        format!("/notes/{LOOSE}/updated-at"),
        format!("/notes/{LOOSE}/links"),
        "/sql".to_string(),
        "/query".to_string(),
        "/cli".to_string(),
        "/exec".to_string(),
    ] {
        for method in ["GET", "POST"] {
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
    // And every table route is served (not the no-route fallback).
    let get = env.call("GET", &format!("/notes/{LOOSE}"), None).await;
    assert_eq!(get.status, 200, "{}", get.body);
}

// ---------------------------------------------------------------------------
// AC 12: 401 without a token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_notes_route_answers_401_unauthorized_without_a_bearer_token() {
    let env = Env::start().await;
    let rows = load_rows(&notes_dir()).expect("notes/index.json parses");
    for row in &rows {
        let method = reqwest::Method::from_bytes(row.method.as_bytes()).unwrap();
        let body = row
            .request
            .as_ref()
            .map(|f| std::fs::read(notes_dir().join(f)).unwrap())
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
}

// ---------------------------------------------------------------------------
// AC 5 and the get parity
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_note_answers_like_memex_get_for_every_seed_note() {
    let env = Env::start().await;
    // Broken Frontmatter is left out: `memex get` itself cannot read invalid
    // frontmatter (see the WI #81 handback note).
    for id in [
        PLAYER_LOOP,
        ECONOMY,
        PACING,
        LOOSE,
        DAY_18,
        DAY_19,
        "01M5DQAYZ5T5B865CDF2RWAC37",
        "01M5DQAYZ50YGKE126FXV02TEY",
        DAY_15,
    ] {
        let reply = env.call("GET", &format!("/notes/{id}"), None).await;
        assert_eq!(reply.status, 200, "GET /notes/{id}: {}", reply.body);
        let cli = env.cli(&["get", "--note-id", id], "");
        assert_eq!(reply.json(), cli.json(), "GET /notes/{id} == memex get");
        assert!(reply.json().get("links").is_none(), "no links in the get");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_note_for_an_unknown_id_is_c1_not_found_like_memex_get() {
    let env = Env::start().await;
    let reply = env.call("GET", &format!("/notes/{UNKNOWN}"), None).await;
    assert_c1(&reply, 404, "not_found");
    let cli = env.cli(&["get", "--note-id", UNKNOWN], "");
    assert_eq!(reply.json(), cli.error(), "the CLI's not_found body");
}

// ---------------------------------------------------------------------------
// AC 6: writes answer like the CLI
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn writes_answer_like_the_cli_on_identical_seed_copies() {
    let env = Env::start().await;

    // PATCH /notes == memex update
    let body = "Maybe the map folds like paper?\n\nOr like a fan.\n";
    let reply = env
        .call(
            "PATCH",
            &format!("/notes/{LOOSE}"),
            Some(&json!({"expected_version": 1, "content_md": body})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        &["update", "--note-id", LOOSE, "--expected-version", "1"],
        body,
    );
    assert_eq!(norm(&reply.json()), norm(&cli.json()), "PATCH /notes");

    // POST /links == memex add-link
    let reply = env
        .call(
            "POST",
            "/links",
            Some(&json!({"from": LOOSE, "to": PACING, "kind": "extends", "label": "pacing"})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        &[
            "add-link", "--from", LOOSE, "--to", PACING, "--kind", "extends", "--label", "pacing",
        ],
        "",
    );
    assert_eq!(norm(&reply.json()), norm(&cli.json()), "POST /links");

    // POST /links without kind == memex add-link's default kind
    let reply = env
        .call(
            "POST",
            "/links",
            Some(&json!({"from": LOOSE, "to": PLAYER_LOOP})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(&["add-link", "--from", LOOSE, "--to", PLAYER_LOOP], "");
    assert_eq!(
        norm(&reply.json()),
        norm(&cli.json()),
        "POST /links default kind"
    );
    assert_eq!(reply.json()["kind"], "references");

    // PATCH /links == memex update-link
    let reply = env
        .call(
            "PATCH",
            &format!("/links/{ECONOMY_LINK}"),
            Some(&json!({"kind": "contradicts", "label": "not quite"})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        &[
            "update-link",
            "--link-id",
            ECONOMY_LINK,
            "--kind",
            "contradicts",
            "--label",
            "not quite",
        ],
        "",
    );
    assert_eq!(norm(&reply.json()), norm(&cli.json()), "PATCH /links");

    // DELETE /notes == memex rm
    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{DAY_15}?expected_version=1"),
            None,
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(&["rm", "--note-id", DAY_15, "--expected-version", "1"], "");
    assert_eq!(norm(&reply.json()), norm(&cli.json()), "DELETE /notes");

    // Both copies now hold the same notes and links.
    for id in [LOOSE, PACING, ECONOMY, PLAYER_LOOP] {
        let (a, b) = (
            note_row(&env.server_vault(), id),
            note_row(&env.cli_vault(), id),
        );
        assert_eq!(a, b, "note {id} after the writes");
        assert_eq!(
            links_of(&env.server_vault(), id),
            links_of(&env.cli_vault(), id),
            "links of {id} after the writes"
        );
    }
    assert_eq!(note_row(&env.server_vault(), DAY_15), None, "deleted");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_notes_stores_the_same_note_and_tags_as_memex_add() {
    let env = Env::start().await;
    let content = "# Combat Feel\n\nHit stop and screen shake, see [[Player Loop]].\n";
    let reply = env
        .call(
            "POST",
            "/notes",
            Some(&json!({
                "title": "Combat Feel",
                "tags": ["feel", "combat"],
                "role": "topic",
                "content_md": content,
            })),
        )
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let cli = env.cli(
        &[
            "add",
            "--title",
            "Combat Feel",
            "--tags",
            "feel,combat",
            "--role",
            "topic",
        ],
        content,
    );
    let out = reply.json();
    assert_eq!(norm(&out), norm(&cli.add_output()), "POST /notes output");
    let (sid, cid) = (
        id_of(&env.server_vault(), "Combat Feel"),
        id_of(&env.cli_vault(), "Combat Feel"),
    );
    assert_eq!(out["note_id"], sid.as_str(), "note_id is the stored note");
    assert_eq!(
        note_row(&env.server_vault(), &sid),
        note_row(&env.cli_vault(), &cid),
        "the stored note"
    );
    assert_eq!(
        tags_of(&env.server_vault(), &sid),
        tags_of(&env.cli_vault(), &cid)
    );
    assert_eq!(tags_of(&env.server_vault(), &sid), vec!["combat", "feel"]);
    assert_eq!(
        links_of(&env.server_vault(), &sid),
        links_of(&env.cli_vault(), &cid),
        "the stored note is indexed like memex add's"
    );

    // No title: derived from the first line, as memex add does.
    let content = "Untitled thoughts on loot.\n";
    let reply = env
        .call("POST", "/notes", Some(&json!({"content_md": content})))
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let cli = env.cli(&["add"], content);
    assert_eq!(norm(&reply.json()), norm(&cli.add_output()));
    assert_eq!(reply.json()["tags"], json!([]));
}

// ---------------------------------------------------------------------------
// AC 7: daily notes
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_notes_daily_on_a_taken_date_is_daily_note_exists_with_existing_id() {
    let env = Env::start().await;
    let before = note_count(&env.server_vault());
    let reply = env
        .call(
            "POST",
            "/notes",
            Some(&json!({"title": "2026-10-19", "role": "daily", "content_md": "Again.\n"})),
        )
        .await;
    assert_c1(&reply, 409, "daily_note_exists");
    assert_eq!(reply.json()["error"]["existing_id"], DAY_19);
    let cli = env.cli(
        &["add", "--title", "2026-10-19", "--role", "daily"],
        "Again.\n",
    );
    assert_eq!(
        reply.json(),
        cli.error(),
        "the CLI's daily_note_exists body"
    );
    assert_eq!(note_count(&env.server_vault()), before, "nothing written");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_notes_daily_adopts_a_role_less_note_with_that_title_like_memex_add() {
    let env = Env::start().await;
    let first = "Notes before the day was a daily.\n";
    let reply = env
        .call(
            "POST",
            "/notes",
            Some(&json!({"title": "2026-10-21", "content_md": first})),
        )
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let plain_id = reply.json()["note_id"].as_str().unwrap().to_string();
    let cli_plain = env.cli(&["add", "--title", "2026-10-21"], first);
    let cli_plain_id = cli_plain.add_output()["note_id"]
        .as_str()
        .unwrap()
        .to_string();

    let reply = env
        .call(
            "POST",
            "/notes",
            Some(&json!({"title": "2026-10-21", "role": "daily", "content_md": ""})),
        )
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let out = reply.json();
    assert_eq!(out["adopted"], true);
    assert_eq!(out["note_id"], plain_id.as_str(), "the same note, adopted");
    let cli = env.cli(&["add", "--title", "2026-10-21", "--role", "daily"], "");
    assert_eq!(norm(&out), norm(&cli.add_output()));
    let (_, _, fm, _) = note_row(&env.server_vault(), &plain_id).unwrap();
    let fm: Value = serde_json::from_str(&fm).unwrap();
    assert_eq!(fm["role"], "daily", "adopted as a daily note");
    assert_eq!(
        note_row(&env.server_vault(), &plain_id),
        note_row(&env.cli_vault(), &cli_plain_id),
        "adoption stores what memex add --role daily stores"
    );
}

// ---------------------------------------------------------------------------
// AC 8: version conflicts write nothing
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stale_expected_version_is_version_conflict_with_the_cli_fields_and_writes_nothing() {
    let env = Env::start().await;
    let before = note_row(&env.server_vault(), PLAYER_LOOP).unwrap();
    let stale = before.3 + 1;

    let reply = env
        .call(
            "PATCH",
            &format!("/notes/{PLAYER_LOOP}"),
            Some(&json!({"expected_version": stale, "content_md": "Overwritten.\n", "title": "Gone"})),
        )
        .await;
    assert_c1(&reply, 409, "version_conflict");
    let cli = env.cli(
        &[
            "update",
            "--note-id",
            PLAYER_LOOP,
            "--expected-version",
            &stale.to_string(),
            "--title",
            "Gone",
        ],
        "Overwritten.\n",
    );
    assert_eq!(
        reply.json(),
        cli.error(),
        "PATCH: the CLI's version_conflict"
    );
    assert_eq!(reply.json()["error"]["expected"], stale);
    assert_eq!(reply.json()["error"]["current"], before.3);
    assert_eq!(
        note_row(&env.server_vault(), PLAYER_LOOP).unwrap(),
        before,
        "PATCH wrote nothing"
    );

    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{PLAYER_LOOP}?expected_version={stale}"),
            None,
        )
        .await;
    assert_c1(&reply, 409, "version_conflict");
    let cli = env.cli(
        &[
            "rm",
            "--note-id",
            PLAYER_LOOP,
            "--expected-version",
            &stale.to_string(),
        ],
        "",
    );
    assert_eq!(
        reply.json(),
        cli.error(),
        "DELETE: the CLI's version_conflict"
    );
    assert_eq!(
        note_row(&env.server_vault(), PLAYER_LOOP).unwrap(),
        before,
        "DELETE removed nothing"
    );
}

// ---------------------------------------------------------------------------
// AC 9: title renames
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn patch_title_change_rewrites_linkers_like_memex_update() {
    let env = Env::start().await;
    let (_, content, _, version) = note_row(&env.server_vault(), ECONOMY).unwrap();
    let reply = env
        .call(
            "PATCH",
            &format!("/notes/{ECONOMY}"),
            Some(&json!({
                "expected_version": version,
                "title": "Economy Systems",
                "content_md": content,
            })),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        &[
            "update",
            "--note-id",
            ECONOMY,
            "--expected-version",
            &version.to_string(),
            "--title",
            "Economy Systems",
        ],
        &content,
    );
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
    let (_, linker, _, _) = note_row(&env.server_vault(), PLAYER_LOOP).unwrap();
    assert!(
        linker.contains("[[Economy Systems]]") && !linker.contains("[[Economy Design]]"),
        "Player Loop's link is renamed: {linker}"
    );
    for id in [PLAYER_LOOP, DAY_18, DAY_19, ECONOMY] {
        assert_eq!(
            note_row(&env.server_vault(), id),
            note_row(&env.cli_vault(), id),
            "note {id} after the rename"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn patch_title_change_with_no_rename_links_leaves_linkers_like_memex_update() {
    let env = Env::start().await;
    let (_, content, _, version) = note_row(&env.server_vault(), ECONOMY).unwrap();
    let linker_before = note_row(&env.server_vault(), PLAYER_LOOP).unwrap();
    let reply = env
        .call(
            "PATCH",
            &format!("/notes/{ECONOMY}"),
            Some(&json!({
                "expected_version": version,
                "title": "Economy Systems",
                "content_md": content,
                "no_rename_links": true,
            })),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        &[
            "update",
            "--note-id",
            ECONOMY,
            "--expected-version",
            &version.to_string(),
            "--title",
            "Economy Systems",
            "--no-rename-links",
        ],
        &content,
    );
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
    assert_eq!(
        note_row(&env.server_vault(), PLAYER_LOOP).unwrap(),
        linker_before,
        "Player Loop is untouched"
    );
    assert_eq!(
        note_row(&env.server_vault(), ECONOMY).unwrap().0,
        "Economy Systems"
    );
    for id in [PLAYER_LOOP, DAY_18, DAY_19, ECONOMY] {
        assert_eq!(
            note_row(&env.server_vault(), id),
            note_row(&env.cli_vault(), id),
            "note {id} after the rename"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 10: links
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_links_twice_is_idempotent_and_keeps_the_source_version() {
    let env = Env::start().await;
    let body = json!({"from": LOOSE, "to": PACING, "kind": "extends"});
    let first = env.call("POST", "/links", Some(&body)).await;
    assert_eq!(first.status, 200, "{}", first.body);
    assert_eq!(first.json()["was_existing"], false);
    let after_first = note_row(&env.server_vault(), LOOSE).unwrap();
    assert_eq!(first.json()["note_version"], after_first.3);

    let second = env.call("POST", "/links", Some(&body)).await;
    assert_eq!(second.status, 200, "{}", second.body);
    let v = second.json();
    assert_eq!(v["was_existing"], true);
    assert_eq!(v["link_id"], first.json()["link_id"], "the same link");
    assert_eq!(v["note_version"], after_first.3);
    assert_eq!(
        note_row(&env.server_vault(), LOOSE).unwrap(),
        after_first,
        "the second call wrote nothing"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn patch_links_clear_label_clears_the_label() {
    let env = Env::start().await;
    let reply = env
        .call(
            "PATCH",
            &format!("/links/{PACING_LINK}"),
            Some(&json!({"clear_label": true, "label": "ignored when clearing"})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["label"], Value::Null);
    let links = links_of(&env.server_vault(), PACING);
    assert_eq!(
        links,
        vec![(
            "Player Loop".to_string(),
            "references".to_string(),
            None,
            Some(PLAYER_LOOP.to_string())
        )],
        "the stored link has no label"
    );
    let cli = env.cli(
        &[
            "update-link",
            "--link-id",
            PACING_LINK,
            "--label",
            "ignored when clearing",
            "--clear-label",
        ],
        "",
    );
    assert_eq!(norm(&reply.json()), norm(&cli.json()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invalid_link_kind_is_invalid_argument_like_memex_add_link() {
    let env = Env::start().await;
    let before = note_row(&env.server_vault(), LOOSE).unwrap();
    let reply = env
        .call(
            "POST",
            "/links",
            Some(&json!({"from": LOOSE, "to": PACING, "kind": "bad_kind"})),
        )
        .await;
    assert_c1(&reply, 400, "invalid_argument");
    let cli = env.cli(
        &[
            "add-link", "--from", LOOSE, "--to", PACING, "--kind", "bad_kind",
        ],
        "",
    );
    assert_eq!(reply.json(), cli.error(), "POST /links: the CLI's body");
    assert_eq!(note_row(&env.server_vault(), LOOSE).unwrap(), before);

    let reply = env
        .call(
            "PATCH",
            &format!("/links/{ECONOMY_LINK}"),
            Some(&json!({"kind": "bad_kind"})),
        )
        .await;
    assert_c1(&reply, 400, "invalid_argument");
    let cli = env.cli(
        &[
            "update-link",
            "--link-id",
            ECONOMY_LINK,
            "--kind",
            "bad_kind",
        ],
        "",
    );
    assert_eq!(reply.json(), cli.error(), "PATCH /links: the CLI's body");
}

// ---------------------------------------------------------------------------
// AC 11: malformed requests
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_json_missing_fields_and_unknown_roles_get_400_invalid_argument() {
    let env = Env::start().await;
    let before = note_count(&env.server_vault());
    let loose_before = note_row(&env.server_vault(), LOOSE).unwrap();
    let cases: Vec<(&str, String, Vec<u8>)> = vec![
        ("POST", "/notes".into(), b"{\"content_md\": ".to_vec()),
        ("POST", "/notes".into(), b"[]".to_vec()),
        ("POST", "/notes".into(), br#"{"title": "No body"}"#.to_vec()),
        (
            "POST",
            "/notes".into(),
            br#"{"content_md": "x\n", "role": "weekly"}"#.to_vec(),
        ),
        (
            "POST",
            "/notes".into(),
            br#"{"content_md": "x\n", "tags": "not-a-list"}"#.to_vec(),
        ),
        ("POST", "/notes".into(), br#"{"content_md": 7}"#.to_vec()),
        (
            "PATCH",
            format!("/notes/{LOOSE}"),
            br#"{"content_md": "x\n"}"#.to_vec(),
        ),
        (
            "PATCH",
            format!("/notes/{LOOSE}"),
            br#"{"expected_version": 1}"#.to_vec(),
        ),
        (
            "PATCH",
            format!("/notes/{LOOSE}"),
            br#"{"expected_version": "one", "content_md": "x\n"}"#.to_vec(),
        ),
        (
            "POST",
            "/links".into(),
            format!(r#"{{"from": "{LOOSE}"}}"#).into_bytes(),
        ),
        (
            "POST",
            "/titles/lookup".into(),
            br#"{"ids": "nope"}"#.to_vec(),
        ),
        ("POST", "/titles/lookup".into(), b"{}".to_vec()),
        (
            "PATCH",
            format!("/links/{ECONOMY_LINK}"),
            br#"{"clear_label": "yes"}"#.to_vec(),
        ),
    ];
    for (method, path, body) in &cases {
        let reply = env.call_raw(method, path, body).await;
        assert_eq!(
            (reply.status, reply.c1_code()),
            (400, "invalid_argument".to_string()),
            "{method} {path} {}: {}",
            String::from_utf8_lossy(body),
            reply.body
        );
    }
    for path in [
        format!("/notes/{LOOSE}"),
        format!("/notes/{LOOSE}?expected_version=one"),
    ] {
        let reply = env.call("DELETE", &path, None).await;
        assert_c1(&reply, 400, "invalid_argument");
    }
    for path in ["/notes?limit=many", "/titles?limit=many"] {
        let reply = env.call("GET", path, None).await;
        assert_c1(&reply, 400, "invalid_argument");
    }
    assert_eq!(note_count(&env.server_vault()), before, "nothing created");
    assert_eq!(
        note_row(&env.server_vault(), LOOSE).unwrap(),
        loose_before,
        "nothing changed"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn empty_content_for_a_non_daily_note_is_refused_and_nothing_is_written() {
    let env = Env::start().await;
    let before = note_count(&env.server_vault());
    for body in [
        json!({"title": "Empty", "content_md": ""}),
        json!({"title": "Blank", "content_md": "  \n\t\n"}),
        json!({"title": "Empty Topic", "role": "topic", "content_md": ""}),
    ] {
        let reply = env.call("POST", "/notes", Some(&body)).await;
        assert_c1(&reply, 400, "invalid_argument");
        let mut args = vec!["add", "--title", body["title"].as_str().unwrap()];
        if body.get("role").is_some() {
            args.extend(["--role", "topic"]);
        }
        let cli = env.cli(&args, body["content_md"].as_str().unwrap());
        assert_eq!(reply.json(), cli.error(), "{body}: the CLI's refusal");
    }
    assert_eq!(note_count(&env.server_vault()), before, "nothing written");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn broken_frontmatter_note_stays_listed_and_titled() {
    // The seed's invalid-JSON frontmatter row still lists, titles and links
    // like the local reads (the fixture rows pin the bytes).
    let env = Env::start().await;
    let list = env.call("GET", "/notes?limit=200", None).await;
    assert_eq!(list.status, 200, "{}", list.body);
    assert!(list.json()["notes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|n| n["id"] == BROKEN));
    let lookup = env
        .call("POST", "/titles/lookup", Some(&json!({"ids": [BROKEN]})))
        .await;
    assert_eq!(lookup.status, 200, "{}", lookup.body);
    assert_eq!(
        lookup.json(),
        json!({"titles": {BROKEN: "Broken Frontmatter"}})
    );
}
