//! WI #242 (T4b): tags and footers over the hosted API, on the full
//! `memex_mcp::server::router()` (Spec #234 R47; rulings D20, D28, D37, D43).
//!
//! Under `/vaults/{name}/api/v1`:
//!
//! | Route | Body | Response |
//! |---|---|---|
//! | `GET /tags` | | `{"tags":[{"tag","note_count","system"}]}`, `tag COLLATE NOCASE, tag` |
//! | `GET /tags/{tag}/notes` | | `{"notes":[{"note_id","title","role","first_line","updated_at"}]}`, most recently updated first; `first_line` may be null |
//! | `POST /notes/{note_id}/tags` | `{"tag"}` | the `memex tag add` object |
//! | `DELETE /notes/{note_id}/tags/{tag}` | | the `memex tag rm` object; already gone is 200 with `removed: false` |
//!
//! `GET /notes/{note_id}` gains `footer_tags`, and `POST
//! /notes/{note_id}/footer-chips` accepts any note. `{tag}` is percent-decoded.
//!
//! Errors are the C1 body the CLI prints for the same failure. Every CLI
//! parity test runs the real `memex` binary on a second copy of the seed (temp
//! dirs only). The rows of `app/test/fixtures/api_v1/tags/index.json` hold the
//! #249 client's contract: never rebless them to fit the server.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use memex_core::notes::{create_note_as, update_note, CreateNote, NoteId, UpdateNote};
use memex_core::tags::{self, TagOrigin};
use memex_core::{Caller, Vault};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, run_rows, FixtureRequest,
    FixtureResponse, FixtureRow, SEED_VAULT_NAME,
};
use server::{
    assert_wrong_method_is_c1_405, client, encode_segment, raw_get, raw_request, Reply, TestServer,
};

const BASE: &str = "/vaults/seed/api/v1";

/// `role: topic`; tags `core` and `loop`.
const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
/// `role: topic`; no tags.
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
/// No role; tag `idea`.
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
/// `role: topic`; no tags.
const PACING: &str = "01M5DQAYZ4YAPYMEDWXP8WCNGJ";
/// `role: daily`, 2026-10-17.
const DAY_17: &str = "01M5DQAYZ5T5B865CDF2RWAC37";
/// Its frontmatter isn't JSON.
const BROKEN: &str = "01M5DQAYZ5RH88SRZGPY15XXVM";
/// A valid ULID no seed note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

const MARKER: &str = "<!-- memex:topics -->";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// The server over one seed copy, plus a second identical seed copy for the
/// `memex` CLI.
struct Env {
    srv: TestServer,
    cli_root: TempDir,
}

impl Env {
    async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    /// Runs `setup` on both seed copies, with the vault closed, before the
    /// server opens its copy.
    async fn start_with(setup: impl Fn(&mut Vault)) -> Self {
        let root = tempfile::tempdir().unwrap();
        let cli_root = tempfile::tempdir().unwrap();
        for dir in [root.path(), cli_root.path()] {
            let vault = materialize_seed(dir);
            let mut vault = Vault::open(&vault).expect("open the seed copy");
            setup(&mut vault);
        }
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

    /// `METHOD <BASE><path>` with the token and an optional JSON body. The
    /// path goes on the wire as written, so its percent-encoding is the test's.
    async fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Reply {
        let bytes = body.map(|b| serde_json::to_vec(b).unwrap());
        self.send(method, path, bytes.as_deref()).await
    }

    async fn send(&self, method: &str, path: &str, body: Option<&[u8]>) -> Reply {
        let mut head = format!(
            "{method} {BASE}{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\
             Authorization: {}\r\n",
            self.srv.bearer()
        );
        if let Some(bytes) = body {
            head.push_str(&format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                bytes.len()
            ));
        }
        raw_request(self.srv.addr(), &head, body.unwrap_or_default()).await
    }

    async fn post_tag(&self, note: &str, tag: &str) -> Reply {
        self.call(
            "POST",
            &format!("/notes/{note}/tags"),
            Some(&json!({"tag": tag})),
        )
        .await
    }

    async fn delete_tag(&self, note: &str, tag: &str) -> Reply {
        self.call(
            "DELETE",
            &format!("/notes/{note}/tags/{}", encode_segment(tag)),
            None,
        )
        .await
    }

    /// `memex <sub…> --vault <cli copy> <rest…>`.
    fn cli(&self, sub: &[&str], rest: &[&str]) -> Cli {
        let vault = self.cli_vault();
        let out = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(sub)
            .arg("--vault")
            .arg(&vault)
            .args(rest)
            .stdin(Stdio::null())
            .output()
            .expect("run memex");
        Cli {
            ok: out.status.success(),
            stdout: String::from_utf8(out.stdout).unwrap(),
            stderr: String::from_utf8(out.stderr).unwrap(),
        }
    }

    fn cli_tag_add(&self, note: &str, tag: &str) -> Cli {
        self.cli(&["tag", "add"], &["--note-id", note, "--tag", tag])
    }

    fn cli_tag_rm(&self, note: &str, tag: &str) -> Cli {
        self.cli(&["tag", "rm"], &["--note-id", note, "--tag", tag])
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

fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

fn id(s: &str) -> NoteId {
    NoteId::parse(s).unwrap()
}

/// The stored `(origin, first_line)` of a tag on a note.
fn row(vault: &Path, note: &str, tag: &str) -> Option<(String, Option<String>)> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare("SELECT origin, first_line FROM tags WHERE note_id = ? AND tag = ?")
        .unwrap();
    let mut rows = stmt
        .query_map(params![note, tag], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap();
    rows.next().map(|r| r.unwrap())
}

fn body_of(vault: &Path, note: &str) -> String {
    db(vault)
        .query_row("SELECT content_md FROM notes WHERE id = ?", [note], |r| {
            r.get(0)
        })
        .unwrap()
}

fn version_of(vault: &Path, note: &str) -> i64 {
    db(vault)
        .query_row("SELECT version FROM notes WHERE id = ?", [note], |r| {
            r.get(0)
        })
        .unwrap()
}

fn correction_count(vault: &Path) -> i64 {
    db(vault)
        .query_row("SELECT COUNT(*) FROM tag_corrections", [], |r| r.get(0))
        .unwrap()
}

fn set_updated_at(vault: &Path, note: &str, ms: i64) {
    db(vault)
        .execute(
            "UPDATE notes SET updated_at = ? WHERE id = ?",
            params![ms, note],
        )
        .unwrap();
}

fn legacy_row(vault: &Path, note: &str, tag: &str) {
    db(vault)
        .execute(
            "INSERT INTO tags (note_id, tag) VALUES (?, ?)",
            params![note, tag],
        )
        .unwrap();
}

/// A person's save of a seed note, so its text holds `body`.
fn person_save(vault: &mut Vault, note: &str, body: &str) {
    let version: i64 = vault
        .connection_ref()
        .query_row("SELECT version FROM notes WHERE id = ?", [note], |r| {
            r.get(0)
        })
        .unwrap();
    update_note(
        vault,
        &id(note),
        version,
        UpdateNote {
            title: None,
            content_md: Some(body.to_string()),
            frontmatter: None,
        },
    )
    .unwrap();
}

/// A `role: guide` note; returns its id.
fn make_guide(vault: &mut Vault) -> String {
    create_note_as(
        vault,
        CreateNote {
            title: Some("Vault Guide".into()),
            content_md: "How to file things.\n".into(),
            frontmatter: Some(json!({"role": "guide"})),
        },
        Caller::Person,
    )
    .unwrap()
    .id
    .to_string()
}

fn guide_id(vault: &Path) -> String {
    db(vault)
        .query_row(
            "SELECT id FROM notes WHERE title = 'Vault Guide'",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

async fn exec(srv: &TestServer, req: &FixtureRequest) -> FixtureResponse {
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: {}\r\n",
        req.method,
        req.path,
        srv.bearer()
    );
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    if req.body.is_some() {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    let reply = raw_request(srv.addr(), &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

// ---------------------------------------------------------------------------
// The full router (D20)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_starts_and_serves_the_tag_routes_on_their_paths_only() {
    // `TestServer` is `memex_mcp::server::router()`: a path parameter clash
    // panics only when it starts.
    let env = Env::start().await;
    let at = |p: &str| format!("{BASE}{p}");
    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (at("/tags").as_str(), &["GET"]),
            (at("/tags/core/notes").as_str(), &["GET"]),
            (at(&format!("/notes/{LOOSE}/tags")).as_str(), &["POST"]),
            (
                at(&format!("/notes/{LOOSE}/tags/idea")).as_str(),
                &["DELETE"],
            ),
            (
                at(&format!("/notes/{LOOSE}/footer-chips")).as_str(),
                &["GET", "POST"],
            ),
        ],
    )
    .await;

    // No read of a bare tag: only `/tags/{tag}/notes` sits under `/tags`.
    let reply = env.call("GET", "/tags/core", None).await;
    assert_eq!(reply.status, 404, "{}", reply.body);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tag_routes_need_the_token() {
    let env = Env::start().await;
    for (method, path) in [
        ("GET", format!("{BASE}/tags")),
        ("GET", format!("{BASE}/tags/core/notes")),
        ("POST", format!("{BASE}/notes/{LOOSE}/tags")),
        ("DELETE", format!("{BASE}/notes/{LOOSE}/tags/idea")),
    ] {
        let req = client().request(method.parse().unwrap(), env.srv.url(&path));
        let reply = Reply::read(req.send().await.unwrap()).await;
        assert_eq!(reply.status, 401, "{method} {path}");
    }
}

// ---------------------------------------------------------------------------
// The contract fixtures
// ---------------------------------------------------------------------------

fn tags_dir() -> PathBuf {
    api_v1_dir().join("tags")
}

/// A row's `(method, path template)`.
fn template(row: &FixtureRow) -> (String, String) {
    let path = row
        .path
        .strip_prefix(BASE)
        .expect("every row is under BASE");
    let segments: Vec<&str> = path.split('/').collect();
    let templated: Vec<&str> = match segments.as_slice() {
        ["", "tags"] => vec!["", "tags"],
        ["", "tags", _, "notes"] => vec!["", "tags", "{tag}", "notes"],
        ["", "notes", _] => vec!["", "notes", "{note_id}"],
        ["", "notes", _, "tags"] => vec!["", "notes", "{note_id}", "tags"],
        ["", "notes", _, "tags", _] => vec!["", "notes", "{note_id}", "tags", "{tag}"],
        other => panic!("a tags row on an unexpected path: {other:?}"),
    };
    (row.method.clone(), templated.join("/"))
}

#[test]
fn tags_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&tags_dir()).expect("tags/index.json parses");
    let served: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    let table: BTreeSet<(String, String)> = [
        ("GET", "/tags"),
        ("GET", "/tags/{tag}/notes"),
        ("POST", "/notes/{note_id}/tags"),
        ("DELETE", "/notes/{note_id}/tags/{tag}"),
        ("GET", "/notes/{note_id}"),
    ]
    .iter()
    .map(|(m, p)| (m.to_string(), p.to_string()))
    .collect();
    assert_eq!(served, table, "tags/index.json routes == the WI #242 table");

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&tags_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}

// ---------------------------------------------------------------------------
// `GET /tags`, `GET /tags/{tag}/notes`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_tags_returns_the_contract_shape_with_counts_and_system() {
    let env = Env::start_with(|v| {
        person_save(v, ECONOMY, "Sources and #core sinks.\n");
        tags::apply_tag(v, &id(PACING), "inbox", TagOrigin::Agent, None).unwrap();
    })
    .await;

    let reply = env.call("GET", "/tags", None).await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        json!({"tags": [
            {"tag": "core", "note_count": 2, "system": false},
            {"tag": "idea", "note_count": 1, "system": false},
            {"tag": "inbox", "note_count": 1, "system": true},
            {"tag": "loop", "note_count": 1, "system": false},
        ]})
    );
    assert_eq!(
        reply.json(),
        env.cli(&["tag", "ls"], &[]).json(),
        "GET /tags == memex tag ls"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_tag_notes_returns_the_contract_shape_most_recent_first() {
    let env = Env::start_with(|v| {
        person_save(
            v,
            ECONOMY,
            "Sources and #core sinks.\n- Then #core again.\n",
        );
        person_save(v, DAY_17, "- [ ] Tuned the #core prices.\n");
    })
    .await;
    let vault = env.server_vault();
    set_updated_at(&vault, PLAYER_LOOP, 1_000);
    set_updated_at(&vault, DAY_17, 2_000);
    set_updated_at(&vault, ECONOMY, 3_000);

    let reply = env.call("GET", "/tags/core/notes", None).await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        json!({"notes": [
            {
                "note_id": ECONOMY,
                "title": "Economy Design",
                "role": "topic",
                "first_line": "Sources and #core sinks.",
                "updated_at": 3_000,
            },
            {
                "note_id": DAY_17,
                "title": "2026-10-17",
                "role": "daily",
                "first_line": "Tuned the #core prices.",
                "updated_at": 2_000,
            },
            {
                "note_id": PLAYER_LOOP,
                "title": "Player Loop",
                "role": "topic",
                "first_line": null,
                "updated_at": 1_000,
            },
        ]}),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_tag_notes_has_a_null_first_line_and_role_for_a_footer_only_tag() {
    let env = Env::start().await;
    let added = env.post_tag(LOOSE, "footer-only").await;
    assert_eq!(added.status, 200, "{}", added.body);
    set_updated_at(&env.server_vault(), LOOSE, 4_000);

    let reply = env.call("GET", "/tags/footer-only/notes", None).await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        json!({"notes": [{
            "note_id": LOOSE,
            "title": "Loose Thought",
            "role": null,
            "first_line": null,
            "updated_at": 4_000,
        }]})
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_tag_notes_for_a_tag_nobody_has_is_an_empty_list() {
    // The local read is `WHERE t.tag = ?` too: an exact name, no lowercasing.
    let env = Env::start().await;
    assert_eq!(
        env.call("GET", "/tags/core/notes", None).await.json()["notes"]
            .as_array()
            .map(Vec::len),
        Some(1),
        "the exact name finds its note"
    );
    for path in [
        "/tags/nobody/notes",
        "/tags/CORE/notes",
        "/tags/%23core/notes",
    ] {
        let reply = env.call("GET", path, None).await;
        assert_eq!(reply.status, 200, "{path}: {}", reply.body);
        assert_eq!(reply.json(), json!({"notes": []}), "{path}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_tag_notes_percent_decodes_the_tag() {
    let env = Env::start().await;
    let vault = env.server_vault();
    assert_eq!(env.post_tag(LOOSE, "résumé").await.status, 200);
    legacy_row(&vault, PACING, "a/b");
    legacy_row(&vault, ECONOMY, "two words");

    for (path, note) in [
        ("/tags/r%C3%A9sum%C3%A9/notes", LOOSE),
        ("/tags/a%2Fb/notes", PACING),
        ("/tags/two%20words/notes", ECONOMY),
    ] {
        let reply = env.call("GET", path, None).await;
        assert_eq!(reply.status, 200, "{path}: {}", reply.body);
        let notes = reply.json()["notes"].as_array().unwrap().clone();
        assert_eq!(notes.len(), 1, "{path}: {notes:?}");
        assert_eq!(notes[0]["note_id"], note, "{path}");
    }

    // Bytes that aren't UTF-8 can't name a tag.
    let reply = raw_get(&env.srv, "GET", &format!("{BASE}/tags/%FF/notes")).await;
    assert_eq!(reply.status, 400, "{}", reply.body);
    assert_eq!(reply.c1_code(), "invalid_argument");
}

// ---------------------------------------------------------------------------
// `POST /notes/{note_id}/tags`, `DELETE /notes/{note_id}/tags/{tag}`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_note_tag_matches_memex_tag_add() {
    let env = Env::start().await;

    let reply = env.post_tag(LOOSE, "work").await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli_tag_add(LOOSE, "work");
    assert_eq!(reply.json(), cli.json(), "POST == memex tag add");
    assert_eq!(
        reply.json(),
        json!({
            "note_id": LOOSE,
            "tag": "work",
            "origin": "person",
            "changed": true,
            "version": version_of(&env.server_vault(), LOOSE),
        })
    );
    assert_eq!(
        row(&env.server_vault(), LOOSE, "work"),
        Some(("person".to_string(), None))
    );
    let body = body_of(&env.server_vault(), LOOSE);
    assert!(
        body.ends_with(&format!("{MARKER}\n#idea\n#work\n")),
        "the footer holds the tag: {body:?}"
    );
    assert_eq!(body, body_of(&env.cli_vault(), LOOSE), "the stored note");

    // A repeat changes nothing; `#Work` means `work`.
    let version = version_of(&env.server_vault(), LOOSE);
    let reply = env.post_tag(LOOSE, "#Work").await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        env.cli_tag_add(LOOSE, "#Work").json(),
        "the repeat == memex tag add"
    );
    assert_eq!(reply.json()["tag"], "work");
    assert_eq!(reply.json()["changed"], false);
    assert_eq!(reply.json()["version"], version);
    assert_eq!(version_of(&env.server_vault(), LOOSE), version);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_note_tag_lifts_a_block() {
    let env = Env::start_with(|v| {
        person_save(v, ECONOMY, "Sources and #pricing sinks.\n");
        tags::agent_tag_note(v, &id(LOOSE), "pricing", None).unwrap();
    })
    .await;
    let removed = env.delete_tag(LOOSE, "pricing").await;
    assert_eq!(removed.status, 200, "{}", removed.body);
    assert_eq!(correction_count(&env.server_vault()), 1);

    let reply = env.post_tag(LOOSE, "pricing").await;
    assert_eq!(reply.status, 200, "{}", reply.body);

    let cleared_at: Option<i64> = db(&env.server_vault())
        .query_row(
            "SELECT cleared_at FROM tag_corrections WHERE note_id = ? AND tag = 'pricing'",
            [LOOSE],
            |r| r.get(0),
        )
        .unwrap();
    assert!(cleared_at.is_some(), "the person's add clears the block");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_note_tag_matches_memex_tag_rm_on_a_person_tag() {
    let env = Env::start().await;

    let reply = env.delete_tag(LOOSE, "idea").await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        env.cli_tag_rm(LOOSE, "idea").json(),
        "DELETE == memex tag rm"
    );
    assert_eq!(
        reply.json(),
        json!({
            "note_id": LOOSE,
            "tag": "idea",
            "removed": true,
            "correction_id": null,
            "version": version_of(&env.server_vault(), LOOSE),
        })
    );
    assert_eq!(row(&env.server_vault(), LOOSE, "idea"), None);
    assert_eq!(correction_count(&env.server_vault()), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_note_tag_on_an_agent_tag_returns_the_correction_id() {
    let env = Env::start_with(|v| {
        person_save(v, ECONOMY, "Sources and #pricing sinks.\n");
        tags::agent_tag_note(v, &id(LOOSE), "pricing", None).unwrap();
    })
    .await;

    let reply = env.delete_tag(LOOSE, "pricing").await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json(), env.cli_tag_rm(LOOSE, "pricing").json());
    let (stored, title): (i64, String) = db(&env.server_vault())
        .query_row(
            "SELECT id, note_title FROM tag_corrections WHERE note_id = ? AND tag = 'pricing'",
            [LOOSE],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(title, "Loose Thought");
    assert_eq!(correction_count(&env.server_vault()), 1);
    assert_eq!(
        reply.json(),
        json!({
            "note_id": LOOSE,
            "tag": "pricing",
            "removed": true,
            "correction_id": stored,
            "version": version_of(&env.server_vault(), LOOSE),
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_note_tag_on_a_system_tag_returns_a_null_correction_id() {
    let env = Env::start_with(|v| {
        tags::apply_tag(v, &id(LOOSE), "inbox", TagOrigin::Agent, None).unwrap();
    })
    .await;
    let reply = env.delete_tag(LOOSE, "inbox").await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["removed"], true);
    assert_eq!(reply.json()["correction_id"], Value::Null);
    assert_eq!(correction_count(&env.server_vault()), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_note_tag_already_gone_is_200_with_removed_false() {
    let env = Env::start().await;
    let version = version_of(&env.server_vault(), LOOSE);

    let reply = env.delete_tag(LOOSE, "gone").await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json(), env.cli_tag_rm(LOOSE, "gone").json());
    assert_eq!(
        reply.json(),
        json!({
            "note_id": LOOSE,
            "tag": "gone",
            "removed": false,
            "correction_id": null,
            "version": version,
        })
    );
    assert_eq!(version_of(&env.server_vault(), LOOSE), version);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_and_delete_note_tag_work_with_a_non_ascii_name() {
    let env = Env::start().await;

    let reply = env.post_tag(LOOSE, "résumé").await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json(), env.cli_tag_add(LOOSE, "résumé").json());
    assert_eq!(reply.json()["tag"], "résumé");
    assert_eq!(reply.json()["changed"], true);
    let body = body_of(&env.server_vault(), LOOSE);
    assert!(body.contains("\n#résumé\n"), "the footer line: {body:?}");

    let listed = env.call("GET", "/tags", None).await.json();
    assert!(
        listed["tags"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["tag"] == "résumé"),
        "{listed}"
    );

    // An uppercase first letter means the stored lowercase, through the
    // path's decoding too.
    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{LOOSE}/tags/R%C3%A9sum%C3%A9"),
            None,
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json(), env.cli_tag_rm(LOOSE, "Résumé").json());
    assert_eq!(reply.json()["removed"], true);
    assert_eq!(reply.json()["tag"], "résumé");
    assert_eq!(row(&env.server_vault(), LOOSE, "résumé"), None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_note_tag_percent_decodes_a_legacy_name_and_a_hash() {
    let env = Env::start().await;
    let vault = env.server_vault();
    legacy_row(&vault, LOOSE, "a/b");
    legacy_row(&vault, LOOSE, "two words");

    for (path, name) in [
        ("a%2Fb", "a/b"),
        ("two%20words", "two words"),
        ("%23idea", "idea"),
    ] {
        let reply = env
            .call("DELETE", &format!("/notes/{LOOSE}/tags/{path}"), None)
            .await;
        assert_eq!(reply.status, 200, "{path}: {}", reply.body);
        assert_eq!(reply.json()["removed"], true, "{path}");
        assert_eq!(reply.json()["tag"], name, "{path}");
        assert_eq!(row(&vault, LOOSE, name), None, "{path}");
    }
}

// ---------------------------------------------------------------------------
// Rule failures through the hosted error shape
// ---------------------------------------------------------------------------

/// The status and the C1 body shape, for a rule that has one code.
#[track_caller]
fn assert_c1(reply: &Reply, status: u16, code: &str) {
    assert_eq!(reply.status, status, "{code}: {}", reply.body);
    assert_eq!(reply.c1_code(), code, "{}", reply.body);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rule_failures_return_the_code_through_the_hosted_error_shape() {
    let env = Env::start_with(|v| {
        make_guide(v);
        person_save(v, ECONOMY, "Sources and #written sinks.\n");
    })
    .await;
    let vault = env.server_vault();
    let guide = guide_id(&vault);

    // `role: guide`.
    let reply = env.post_tag(&guide, "work").await;
    assert_c1(&reply, 422, "guide_rule");
    assert_eq!(row(&vault, &guide, "work"), None, "nothing written");
    let reply = env
        .call(
            "POST",
            &format!("/notes/{guide}/footer-chips"),
            Some(&json!({"topic_note_id": PLAYER_LOOP})),
        )
        .await;
    assert_c1(&reply, 422, "guide_rule");

    // A footer target that isn't a topic.
    let reply = env
        .call(
            "POST",
            &format!("/notes/{LOOSE}/footer-chips"),
            Some(&json!({"topic_note_id": LOOSE})),
        )
        .await;
    assert_c1(&reply, 422, "role_rule");
    assert_eq!(
        reply.json(),
        env.cli(
            &["footer", "add"],
            &["--note-id", LOOSE, "--topic-note-id", LOOSE]
        )
        .error(),
        "the CLI's body"
    );

    // A note can't chip itself.
    let reply = env
        .call(
            "POST",
            &format!("/notes/{PLAYER_LOOP}/footer-chips"),
            Some(&json!({"topic_note_id": PLAYER_LOOP})),
        )
        .await;
    assert_c1(&reply, 400, "invalid_argument");
    assert_eq!(
        reply.json(),
        env.cli(
            &["footer", "add"],
            &["--note-id", PLAYER_LOOP, "--topic-note-id", PLAYER_LOOP]
        )
        .error(),
        "the CLI's body"
    );

    // A name outside the grammar.
    let version = version_of(&vault, LOOSE);
    for bad in ["not a tag!", "123", ""] {
        let reply = env.post_tag(LOOSE, bad).await;
        assert_c1(&reply, 400, "invalid_argument");
        assert_eq!(
            reply.json(),
            env.cli_tag_add(LOOSE, bad).error(),
            "{bad:?}: the CLI's body"
        );
    }
    assert_eq!(version_of(&vault, LOOSE), version, "nothing written");

    // A tag written in the body.
    let reply = env.delete_tag(ECONOMY, "written").await;
    assert_c1(&reply, 400, "invalid_argument");
    let message = reply.json()["error"]["message"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(message.contains("delete the text"), "{message}");
    assert_eq!(
        reply.json(),
        env.cli_tag_rm(ECONOMY, "written").error(),
        "the CLI's body"
    );
    assert_eq!(row(&vault, ECONOMY, "written").unwrap().0, "body");

    // No such note, and an id that can't be one.
    let reply = env.post_tag(UNKNOWN, "work").await;
    assert_c1(&reply, 404, "not_found");
    assert_eq!(reply.json(), env.cli_tag_add(UNKNOWN, "work").error());
    let reply = env.delete_tag(UNKNOWN, "work").await;
    assert_c1(&reply, 404, "not_found");
    assert_eq!(reply.json(), env.cli_tag_rm(UNKNOWN, "work").error());
    let reply = env.post_tag("not-a-ulid", "work").await;
    assert_c1(&reply, 400, "invalid_id");
    let reply = env.delete_tag("not-a-ulid", "work").await;
    assert_c1(&reply, 400, "invalid_id");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_note_tag_with_a_malformed_body_is_invalid_argument() {
    let env = Env::start().await;
    let path = format!("/notes/{LOOSE}/tags");
    for body in [&b"{}"[..], br#"{"tag": 5}"#, b"not json"] {
        let reply = env.send("POST", &path, Some(body)).await;
        assert_c1(&reply, 400, "invalid_argument");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_notes_rejects_a_tag_outside_the_grammar_like_memex_add() {
    // D43, up front: the good name is not kept, and no note is created.
    let env = Env::start().await;
    let count = |vault: &Path| -> i64 {
        db(vault)
            .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
            .unwrap()
    };
    let before = count(&env.server_vault());
    let reply = env
        .call(
            "POST",
            "/notes",
            Some(&json!({
                "title": "Tag Probe",
                "tags": ["good", "not a tag!"],
                "content_md": "Body.\n",
            })),
        )
        .await;
    assert_c1(&reply, 400, "invalid_argument");
    assert_eq!(count(&env.server_vault()), before, "no note was created");
    let tags = env.call("GET", "/tags", None).await.json();
    assert!(
        !tags.to_string().contains("good"),
        "no tag was written: {tags}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_notes_stores_tags_as_person_with_footer_text_like_memex_add() {
    let env = Env::start().await;
    let reply = env
        .call(
            "POST",
            "/notes",
            Some(&json!({"title": "Tagged", "tags": ["x"], "content_md": "Body.\n"})),
        )
        .await;
    assert_eq!(reply.status, 201, "{}", reply.body);
    let note = reply.json()["note_id"].as_str().unwrap().to_string();
    let vault = env.server_vault();
    assert_eq!(row(&vault, &note, "x"), Some(("person".to_string(), None)));
    assert_eq!(body_of(&vault, &note), format!("Body.\n{MARKER}\n#x\n"));
}

// ---------------------------------------------------------------------------
// `footer_tags`, `footer-chips`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_note_returns_footer_tags_beside_unchanged_tags() {
    let env = Env::start_with(|v| {
        person_save(v, ECONOMY, "Sources and #applied #written sinks.\n");
        tags::agent_tag_note(v, &id(PACING), "applied", None).unwrap();
        tags::apply_tag(v, &id(PACING), "inbox", TagOrigin::Agent, None).unwrap();
        tags::apply_tag(v, &id(PACING), "added", TagOrigin::Person, None).unwrap();
    })
    .await;

    let pacing = env.call("GET", &format!("/notes/{PACING}"), None).await;
    assert_eq!(pacing.status, 200, "{}", pacing.body);
    assert_eq!(
        pacing.json()["footer_tags"],
        json!(["added", "applied"]),
        "agent and person rows, no system tag, sorted"
    );
    assert_eq!(pacing.json()["tags"], json!(["added", "applied", "inbox"]));

    let economy = env.call("GET", &format!("/notes/{ECONOMY}"), None).await;
    assert_eq!(
        economy.json()["footer_tags"],
        json!([]),
        "a tag in the text is not a footer tag"
    );
    assert_eq!(economy.json()["tags"], json!(["applied", "written"]));

    let broken = env.call("GET", &format!("/notes/{BROKEN}"), None).await;
    assert_eq!(broken.status, 200, "{}", broken.body);
    assert_eq!(
        broken.json()["footer_tags"],
        json!([]),
        "a note with broken frontmatter still reads"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_note_footer_tags_follow_a_tag_write() {
    let env = Env::start().await;
    let path = format!("/notes/{ECONOMY}");
    assert_eq!(
        env.call("GET", &path, None).await.json()["footer_tags"],
        json!([])
    );

    assert_eq!(env.post_tag(ECONOMY, "work").await.status, 200);
    assert_eq!(
        env.call("GET", &path, None).await.json()["footer_tags"],
        json!(["work"])
    );

    assert_eq!(env.delete_tag(ECONOMY, "work").await.status, 200);
    assert_eq!(
        env.call("GET", &path, None).await.json()["footer_tags"],
        json!([])
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_footer_chips_accepts_a_plain_note() {
    let env = Env::start().await;
    let reply = env
        .call(
            "POST",
            &format!("/notes/{PACING}/footer-chips"),
            Some(&json!({"topic_note_id": PLAYER_LOOP})),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let cli = env.cli(
        &["footer", "add"],
        &["--daily-note-id", PACING, "--topic-note-id", PLAYER_LOOP],
    );
    assert_eq!(reply.json(), cli.json(), "POST == memex footer add");
    assert_eq!(reply.json()["daily_note_id"], PACING);
    assert_eq!(reply.json()["origin"], "person");
    let body = body_of(&env.server_vault(), PACING);
    assert!(
        body.ends_with(&format!("{MARKER}\n[[Player Loop~about]]\n")),
        "{body:?}"
    );
}

// ---------------------------------------------------------------------------
// D28: one order everywhere
// ---------------------------------------------------------------------------

/// The app's local read, `TagsReads.allTags` (`app/lib/src/db/tags_reads.dart`,
/// #249), as it runs on the vault file.
const LOCAL_ALL_TAGS: &str = "SELECT tag, COUNT(*) AS note_count FROM tags GROUP BY tag \
                              ORDER BY tag COLLATE NOCASE, tag";

fn local_all_tags(vault: &Path) -> Vec<(String, i64)> {
    let conn = db(vault);
    let mut stmt = conn.prepare(LOCAL_ALL_TAGS).unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(|r| r.unwrap());
    rows.collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tag_list_order_matches_across_get_tags_memex_tag_ls_and_the_local_read() {
    // Case folds for ASCII only, ties break on the stored bytes, and non-ASCII
    // letters aren't folded.
    let env = Env::start().await;
    for vault in [env.server_vault(), env.cli_vault()] {
        for name in [
            "Zeta", "beta", "éa", "_under", "BETA", "Eb", "alpha", "Beta", "Éa", "ea",
        ] {
            legacy_row(&vault, PACING, name);
        }
        legacy_row(&vault, ECONOMY, "beta");
    }
    let expected = [
        "_under", "alpha", "BETA", "Beta", "beta", "core", "ea", "Eb", "idea", "loop", "Zeta",
        "Éa", "éa",
    ];

    let reply = env.call("GET", "/tags", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let hosted = reply.json();
    let names: Vec<&str> = hosted["tags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["tag"].as_str().unwrap())
        .collect();
    assert_eq!(names, expected, "GET /tags");

    let cli = env.cli(&["tag", "ls"], &[]).json();
    assert_eq!(cli, hosted, "memex tag ls == GET /tags");

    let local = local_all_tags(&env.server_vault());
    let hosted_rows: Vec<(String, i64)> = hosted["tags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| {
            (
                t["tag"].as_str().unwrap().to_string(),
                t["note_count"].as_i64().unwrap(),
            )
        })
        .collect();
    assert_eq!(local, hosted_rows, "the local read == GET /tags");
}
