//! WI #256: the hosted half of the frozen Contract, under
//! `/vaults/{name}/api/v1`, served by the in-process vault server over #74's
//! frozen seed:
//!
//! | Route | Response |
//! |---|---|
//! | `GET /daily-notes/{date}/filing` | the `memex filing` object |
//! | `POST /notes/{note_id}/excerpts {date, block_id, note?}` | the `memex excerpt add` object |
//! | `DELETE /notes/{note_id}/excerpts/blocks/{block_id}?date=&note=` | the `memex excerpt remove-block` object |
//! | `POST /notes/{note_id}/excerpts/move {date, block_id, to_topic_note_id, note?}` | the `memex excerpt move` object; `note_id` is the source |
//! | `POST /feedback {note_id, date, change_id, text}` | 201, Feedback |
//! | `PATCH /feedback/{feedback_id} {text}` | Feedback |
//! | `DELETE /feedback/{feedback_id}` | `{vault_id, id}` |
//! | `GET /feedback?note_id=` | `{vault_id, feedback}`; no parameter is the no-note list |
//! | `GET /guide` | `{vault_id, note_id, version, content_md}` |
//! | `GET /guide/revisions` | `{vault_id, revisions}` |
//! | `POST /guide/revisions/{revision_id}/restore` | `{vault_id, note_id, version}` |
//! | `DELETE /smart-folders/{folder_id}/members/{note_id}` | the `memex folder remove` object |
//!
//! Every parity test runs the real `memex` binary on a second copy of the seed
//! (temp dirs only) and compares the two objects after `normalize_volatile`.
//! Hosted failures compare the status to `status_for_code(code)`, never a literal
//! (lead decision 7: #242 pins the 422s for `guide_rule`, `feedback_handled` and
//! `feedback_invalid`, per D37), and the C1 code exactly.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::Router;
use chrono::{TimeZone, Utc};
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::notes::NoteId;
use memex_core::{excerpts, feedback, guide, Caller, Clock, Vault};
use memex_mcp::server::error::status_for_code;
use memex_mcp::server::{router, ServerConfig};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{materialize_seed, normalize_volatile, seed_vault_id, SEED_VAULT_NAME};
use server::{assert_wrong_method_is_c1_405, client, Reply, TestServer, TEST_TOKEN};

const BASE: &str = "/vaults/seed/api/v1";

const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
/// The Activity entry on [`DAY_18`].
const CHANGE_18: &str = "01M5DQAYZJJSN6WG9XFPXXFBNC";
/// The Activity entry on [`ECONOMY`].
const CHANGE_ECONOMY: &str = "01M5DQAYZJKNYY386G5CXYKNMX";
/// Root, pinned; pinned member [`PLAYER_LOOP`].
const DESIGN: &str = "01M5DQAYZHJGKWXCJHR5FSDFA0";
/// Unpinned; unpinned members [`ECONOMY`] and Pacing Notes.
const SYSTEMS: &str = "01M5DQAYZHE33BZ4NA4H5YSBJD";
/// Unpinned, with no members.
const INBOX: &str = "01M5DQAYZHJTTW6PPF4P7GNCHN";
/// A valid ULID nothing in the seed has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

const T0: i64 = 1_790_000_000_000;
const AGENT_TEXT: &str = "## Framework\n\nGames go under Design.\n\n## Decisions\n";

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

    fn server_vault(&self) -> std::path::PathBuf {
        self.srv.root().join(SEED_VAULT_NAME)
    }

    fn cli_vault(&self) -> std::path::PathBuf {
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

/// The route answered C1 `code` with `status_for_code(code)`, and `memex`
/// printed the same C1 body for the same failure.
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
}

fn db(vault: &Path) -> Connection {
    Connection::open(vault.join("memex.db")).expect("open memex.db")
}

fn open(vault: &Path) -> Vault {
    Vault::open(vault).expect("open the seed vault")
}

fn topic(id: &str) -> NoteId {
    NoteId::parse(id).unwrap()
}

/// The agent files `blocks` of `date` into `topic_id`.
fn agent_files(vault: &mut Vault, topic_id: &str, date: &str, blocks: &[&str]) {
    let ids: Vec<String> = blocks.iter().map(|s| s.to_string()).collect();
    excerpts::add_excerpt(vault, &topic(topic_id), date, &ids, Caller::Agent, None)
        .unwrap_or_else(|e| panic!("add_excerpt {blocks:?}: {e}"));
}

/// An Open comment on the 2026-10-18 entry.
fn comment(vault: &mut Vault, text: &str, at: i64) -> feedback::Feedback {
    feedback::add(
        vault,
        DAY_18,
        "2026-10-18",
        CHANGE_18,
        text,
        &FixedClock(at),
    )
    .unwrap()
}

/// An Open comment, a Handled comment, a person's Correction and an open tag
/// Correction, on 2026-10-18's note.
fn feedback_world(dir: &Path) {
    let mut vault = open(dir);
    comment(&mut vault, "Open comment.", T0);
    let handled = comment(&mut vault, "Handled comment.", T0 + 1);
    feedback::resolve(&mut vault, &handled.id, "Done.", &[], &FixedClock(T0 + 2)).unwrap();
    excerpts::add_excerpt_noted(
        &mut vault,
        &topic(PLAYER_LOOP),
        "2026-10-18",
        &["6v4mr7".to_string()],
        Caller::Person,
        None,
        Some("Why."),
    )
    .unwrap();
    vault
        .connection_ref()
        .execute(
            "INSERT INTO tag_corrections (note_id, note_title, tag, kind, created_at, cleared_at)
             VALUES (?, '2026-10-18', 'game-feel', 'removed', ?, NULL)",
            params![DAY_18, T0 + 3],
        )
        .unwrap();
}

/// The guide, with one agent write over its seed text.
fn guide_world(dir: &Path) {
    agent_update_guide(dir);
}

/// An agent write over the guide (created when missing), as `update_vault_guide`.
fn agent_update_guide(dir: &Path) {
    let mut vault = open(dir);
    let clock = FixedClock(T0);
    let doc = guide::get_or_create(&mut vault, &clock, None).unwrap();
    guide::update(
        &mut vault,
        doc.version,
        AGENT_TEXT,
        &["Updated the framework".to_string()],
        "2026-10-18",
        &clock,
        None,
    )
    .unwrap();
}

fn comment_id(vault: &Path, text: &str) -> String {
    db(vault)
        .query_row("SELECT id FROM feedback WHERE text IS ?", [text], |r| {
            r.get(0)
        })
        .unwrap()
}

fn correction_id(vault: &Path) -> String {
    db(vault)
        .query_row(
            "SELECT id FROM feedback WHERE kind = 'correction' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .unwrap()
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

fn newest_revision(vault: &Path) -> String {
    db(vault)
        .query_row(
            "SELECT id FROM vault_guide_revisions ORDER BY new_version DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

fn is_member(vault: &Path, folder: &str, note: &str) -> bool {
    db(vault)
        .query_row(
            "SELECT count(*) FROM smart_folder_members WHERE smart_folder_id = ? AND note_id = ?",
            [folder, note],
            |r| r.get::<_, i64>(0),
        )
        .unwrap()
        == 1
}

/// The flags `memex excerpt add` and `remove-block` share.
fn block_args<'a>(topic: &'a str, date: &'a str, block: &'a str) -> Vec<&'a str> {
    vec![
        "--topic-note-id",
        topic,
        "--date",
        date,
        "--block-id",
        block,
    ]
}

// ---------------------------------------------------------------------------
// AC 6: each route returns its CLI command's object
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn filing_route_answers_like_memex_filing() {
    let env = Env::start_with(|dir| {
        agent_files(&mut open(dir), ECONOMY, "2026-10-18", &["6v4mr7"]);
    })
    .await;

    let reply = env
        .call("GET", "/daily-notes/2026-10-18/filing", None)
        .await;

    assert_same_object(
        &reply,
        200,
        &env.cli(&["filing"], &["--date", "2026-10-18"]),
    );
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": seed_vault_id(),
            "date": "2026-10-18",
            "note_id": DAY_18,
            "reviewed": true,
            "topics": [{
                "topic_note_id": ECONOMY,
                "title": "Economy Design",
                "blocks": [{"id": "6v4mr7", "text": "Played the prototype for an hour."}],
            }],
            "not_filed": [
                {"id": "65a642", "text": "The [[Player Loop]] drags after the third run."},
            ],
        })
    );
}

/// A day never reviewed, and a day changed since its review (only the snapshot's
/// blocks count as not filed).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn filing_route_answers_like_memex_filing_on_other_review_states() {
    let env = Env::start().await;

    for date in ["2026-10-19", "2026-10-17"] {
        let reply = env
            .call("GET", &format!("/daily-notes/{date}/filing"), None)
            .await;
        assert_same_object(&reply, 200, &env.cli(&["filing"], &["--date", date]));
    }

    let unreviewed = env
        .call("GET", "/daily-notes/2026-10-19/filing", None)
        .await;
    assert_eq!(unreviewed.json()["reviewed"], json!(false));
    assert_eq!(unreviewed.json()["topics"], json!([]));
    let changed = env
        .call("GET", "/daily-notes/2026-10-17/filing", None)
        .await;
    assert_eq!(changed.json()["reviewed"], json!(true));
    assert_eq!(
        changed.json()["not_filed"],
        json!([{"id": "40s3hr", "text": "Tuned the shop prices."}])
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_add_route_answers_like_memex_excerpt_add() {
    let env = Env::start().await;

    let reply = env
        .call(
            "POST",
            &format!("/notes/{PLAYER_LOOP}/excerpts"),
            Some(&json!({"date": "2026-10-18", "block_id": "6v4mr7", "note": "Loop notes."})),
        )
        .await;

    let mut args = block_args(PLAYER_LOOP, "2026-10-18", "6v4mr7");
    args.extend(["--note", "Loop notes."]);
    assert_same_object(&reply, 200, &env.cli(&["excerpt", "add"], &args));
    assert_eq!(
        reply.json(),
        json!({"vault_id": seed_vault_id(), "topic_note_id": PLAYER_LOOP, "version": 2})
    );
    // The Correction went the same way on both.
    let hosted = env
        .call("GET", &format!("/feedback?note_id={DAY_18}"), None)
        .await;
    assert_same_object(
        &hosted,
        200,
        &env.cli(&["feedback", "ls"], &["--note-id", DAY_18]),
    );
    let row = &hosted.json()["feedback"][0];
    assert_eq!(row["text"], json!("Loop notes."), "{row}");
    assert_eq!(row["correction"]["kind"], json!("excerpt_added"), "{row}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_remove_block_route_answers_like_memex_excerpt_remove_block() {
    let env = Env::start_with(|dir| {
        agent_files(&mut open(dir), ECONOMY, "2026-10-18", &["6v4mr7", "65a642"]);
    })
    .await;

    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{ECONOMY}/excerpts/blocks/6v4mr7?date=2026-10-18&note=Not%20prices."),
            None,
        )
        .await;

    let cli = env.cli(
        &["excerpt", "remove-block"],
        &[
            "--topic-note-id",
            ECONOMY,
            "--date",
            "2026-10-18",
            "--block-id",
            "6v4mr7",
            "--note",
            "Not prices.",
        ],
    );
    assert_same_object(&reply, 200, &cli);
    assert_eq!(
        reply.json(),
        json!({"vault_id": seed_vault_id(), "topic_note_id": ECONOMY, "version": 4})
    );
    let hosted = env
        .call("GET", &format!("/feedback?note_id={DAY_18}"), None)
        .await;
    assert_same_object(
        &hosted,
        200,
        &env.cli(&["feedback", "ls"], &["--note-id", DAY_18]),
    );
    let row = &hosted.json()["feedback"][0];
    assert_eq!(row["text"], json!("Not prices."), "{row}");
    assert_eq!(row["correction"]["kind"], json!("excerpt_removed"), "{row}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_move_route_answers_like_memex_excerpt_move() {
    let env = Env::start().await;

    let reply = env
        .call(
            "POST",
            &format!("/notes/{ECONOMY}/excerpts/move"),
            Some(&json!({
                "date": "2026-10-19",
                "block_id": "et8g8y",
                "to_topic_note_id": PLAYER_LOOP,
                "note": "About the loop.",
            })),
        )
        .await;

    let cli = env.cli(
        &["excerpt", "move"],
        &[
            "--date",
            "2026-10-19",
            "--block-id",
            "et8g8y",
            "--from-topic-note-id",
            ECONOMY,
            "--to-topic-note-id",
            PLAYER_LOOP,
            "--note",
            "About the loop.",
        ],
    );
    assert_same_object(&reply, 200, &cli);
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": seed_vault_id(),
            "from_topic_note_id": ECONOMY,
            "from_version": 3,
            "to_topic_note_id": PLAYER_LOOP,
            "to_version": 2,
        })
    );
    let hosted_filing: String = db(&env.server_vault())
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [PLAYER_LOOP],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        hosted_filing.contains("![[2026-10-19#^et8g8y]]"),
        "{hosted_filing}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_add_route_answers_like_memex_feedback_add() {
    let env = Env::start().await;

    let reply = env
        .call(
            "POST",
            "/feedback",
            Some(&json!({
                "note_id": DAY_18,
                "date": "2026-10-18",
                "change_id": CHANGE_18,
                "text": "  Wrong topic.\n",
            })),
        )
        .await;

    let cli = env.cli(
        &["feedback", "add"],
        &[
            "--note-id",
            DAY_18,
            "--date",
            "2026-10-18",
            "--change-id",
            CHANGE_18,
            "--text",
            "  Wrong topic.\n",
        ],
    );
    assert_same_object(&reply, 201, &cli);
    let v = reply.json();
    assert_eq!(v.get("vault_id"), None, "Feedback has no vault_id: {v}");
    assert_eq!(v["text"], json!("  Wrong topic.\n"), "{v}");
    assert_eq!(v["status"], json!("open"), "{v}");
    assert_eq!(v["agent_change_id"], json!(CHANGE_18), "{v}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_edit_route_answers_like_memex_feedback_edit() {
    let env = Env::start_with(feedback_world).await;
    let id = comment_id(&env.server_vault(), "Open comment.");
    let cli_id = comment_id(&env.cli_vault(), "Open comment.");

    let reply = env
        .call(
            "PATCH",
            &format!("/feedback/{id}"),
            Some(&json!({"text": "Better words."})),
        )
        .await;

    let cli = env.cli(
        &["feedback", "edit"],
        &["--id", &cli_id, "--text", "Better words."],
    );
    assert_same_object(&reply, 200, &cli);
    let v = reply.json();
    assert_eq!(v["id"], json!(id), "{v}");
    assert_eq!(v["text"], json!("Better words."), "{v}");
    assert_eq!(v.get("vault_id"), None, "Feedback has no vault_id: {v}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_rm_route_answers_like_memex_feedback_rm() {
    let env = Env::start_with(feedback_world).await;
    let id = comment_id(&env.server_vault(), "Open comment.");
    let cli_id = comment_id(&env.cli_vault(), "Open comment.");

    let reply = env.call("DELETE", &format!("/feedback/{id}"), None).await;

    assert_same_object(
        &reply,
        200,
        &env.cli(&["feedback", "rm"], &["--id", &cli_id]),
    );
    assert_eq!(reply.json(), json!({"vault_id": seed_vault_id(), "id": id}));
    let gone = env.call("DELETE", &format!("/feedback/{id}"), None).await;
    assert_status_for_code(&gone, "not_found");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_ls_route_answers_like_memex_feedback_ls() {
    let env = Env::start_with(|dir| {
        feedback_world(dir);
        let mut vault = open(dir);
        feedback::record_chat(
            &mut vault,
            "On no note.",
            None,
            None,
            "Noted.",
            &[],
            &FixedClock(T0),
        )
        .unwrap();
        feedback::record_chat(
            &mut vault,
            "Later, on no note.",
            None,
            None,
            "Noted.",
            &[],
            &FixedClock(T0 + 1),
        )
        .unwrap();
    })
    .await;

    let for_note = env
        .call("GET", &format!("/feedback?note_id={DAY_18}"), None)
        .await;
    assert_same_object(
        &for_note,
        200,
        &env.cli(&["feedback", "ls"], &["--note-id", DAY_18]),
    );
    assert_eq!(for_note.json()["vault_id"], json!(seed_vault_id()));
    let rows = for_note.json()["feedback"].as_array().unwrap().clone();
    assert_eq!(rows.len(), 4, "{rows:?}");
    assert_eq!(
        rows.iter()
            .filter(|r| r["status"] == json!("handled"))
            .count(),
        1,
        "every status is listed: {rows:?}"
    );

    let no_note = env.call("GET", "/feedback", None).await;
    assert_same_object(&no_note, 200, &env.cli(&["feedback", "ls"], &["--no-note"]));
    let texts: Vec<Value> = no_note.json()["feedback"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["text"].clone())
        .collect();
    assert_eq!(
        texts,
        [json!("Later, on no note."), json!("On no note.")],
        "the no-note rows only, newest first"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guide_get_route_answers_like_memex_guide_get_and_creates_on_first_read() {
    let env = Env::start().await;

    let reply = env.call("GET", "/guide", None).await;

    assert_same_object(&reply, 200, &env.cli(&["guide", "get"], &[]));
    let v = reply.json();
    let id = guide_id(&env.server_vault());
    assert_eq!(
        v,
        json!({
            "vault_id": seed_vault_id(),
            "note_id": id,
            "version": v["version"],
            "content_md": "## Framework\n\n## Decisions\n",
        })
    );
    let again = env.call("GET", "/guide", None).await;
    assert_eq!(again.json(), v, "a later read returns the same guide");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guide_revisions_route_answers_like_memex_guide_revisions() {
    let env = Env::start_with(guide_world).await;

    let reply = env.call("GET", "/guide/revisions", None).await;

    assert_same_object(&reply, 200, &env.cli(&["guide", "revisions"], &[]));
    let id = newest_revision(&env.server_vault());
    let change: String = db(&env.server_vault())
        .query_row(
            "SELECT agent_change_id FROM vault_guide_revisions",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": seed_vault_id(),
            "revisions": [{"id": id, "agent_change_id": change, "created_at": T0}],
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guide_restore_route_answers_like_memex_guide_restore() {
    let env = Env::start_with(guide_world).await;
    let id = newest_revision(&env.server_vault());
    let cli_id = newest_revision(&env.cli_vault());
    let before = env.call("GET", "/guide", None).await.json();

    let reply = env
        .call("POST", &format!("/guide/revisions/{id}/restore"), None)
        .await;

    assert_same_object(
        &reply,
        200,
        &env.cli(&["guide", "restore"], &["--revision-id", &cli_id]),
    );
    let version = before["version"].as_i64().unwrap() + 1;
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": seed_vault_id(),
            "note_id": before["note_id"],
            "version": version,
        })
    );
    let after = env.call("GET", "/guide", None).await.json();
    assert_eq!(after["content_md"], json!("## Framework\n\n## Decisions\n"));
    // The replaced text is kept: restoring the new revision brings it back.
    let kept = newest_revision(&env.server_vault());
    assert_ne!(kept, id);
    let back = env
        .call("POST", &format!("/guide/revisions/{kept}/restore"), None)
        .await;
    assert_eq!(back.status, 200, "{}", back.body);
    let after = env.call("GET", "/guide", None).await.json();
    assert_eq!(after["content_md"], json!(AGENT_TEXT));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn member_delete_route_answers_like_memex_folder_remove() {
    let env = Env::start().await;

    let reply = env
        .call(
            "DELETE",
            &format!("/smart-folders/{SYSTEMS}/members/{ECONOMY}"),
            None,
        )
        .await;

    let cli = env.cli(
        &["folder", "remove"],
        &["--id", SYSTEMS, "--note-id", ECONOMY],
    );
    assert_same_object(&reply, 200, &cli);
    assert_eq!(
        reply.json(),
        json!({
            "vault_id": seed_vault_id(),
            "smart_folder_id": SYSTEMS,
            "note_id": ECONOMY,
            "removed": true,
        })
    );
}

// ---------------------------------------------------------------------------
// The optional `note` and the route's own ids
// ---------------------------------------------------------------------------

/// `note` absent or null records `text: null`; given, it is stored as given.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_routes_store_the_note_as_given_and_null_when_absent() {
    let env = Env::start_with(|dir| {
        agent_files(&mut open(dir), ECONOMY, "2026-10-18", &["6v4mr7", "65a642"]);
    })
    .await;
    let texts = |vault: &Path| -> Vec<Option<String>> {
        db(vault)
            .prepare("SELECT text FROM feedback ORDER BY rowid")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    let add = format!("/notes/{PLAYER_LOOP}/excerpts");
    let blocks = format!("/notes/{ECONOMY}/excerpts/blocks");

    // Absent, then null, then given with surrounding space and a line break.
    let absent = env
        .call(
            "POST",
            &add,
            Some(&json!({"date": "2026-10-17", "block_id": "40s3hr"})),
        )
        .await;
    assert_eq!(absent.status, 200, "{}", absent.body);
    let null = env
        .call(
            "POST",
            &add,
            Some(&json!({"date": "2026-10-17", "block_id": "ps0m60", "note": null})),
        )
        .await;
    assert_eq!(null.status, 200, "{}", null.body);
    let given = env
        .call(
            "POST",
            &add,
            Some(&json!({
                "date": "2026-10-19",
                "block_id": "v4vv62",
                "note": "  Why \u{2603}?\nBecause.  ",
            })),
        )
        .await;
    assert_eq!(given.status, 200, "{}", given.body);
    // In the query: decoded, `&` and all; absent is null.
    let encoded = env
        .call(
            "DELETE",
            &format!("{blocks}/6v4mr7?date=2026-10-18&note=a%20%26%20b%20%E2%98%83"),
            None,
        )
        .await;
    assert_eq!(encoded.status, 200, "{}", encoded.body);
    let no_note = env
        .call("DELETE", &format!("{blocks}/65a642?date=2026-10-18"), None)
        .await;
    assert_eq!(no_note.status, 200, "{}", no_note.body);

    assert_eq!(
        texts(&env.server_vault()),
        [
            None,
            None,
            Some("  Why \u{2603}?\nBecause.  ".to_string()),
            Some("a & b \u{2603}".to_string()),
            None,
        ]
    );
}

/// The Correction texts of the vault, oldest first.
fn correction_texts(vault: &Path) -> Vec<Option<String>> {
    db(vault)
        .prepare("SELECT text FROM feedback WHERE kind = 'correction' ORDER BY rowid")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// A vault where all three block writes can run: [`ECONOMY`] holds 2026-10-18's
/// blocks and 2026-10-19's `et8g8y`; [`PLAYER_LOOP`] holds neither.
fn filed_world(dir: &Path) {
    agent_files(&mut open(dir), ECONOMY, "2026-10-18", &["6v4mr7", "65a642"]);
}

/// Lead decision 8: an empty or whitespace-only `note` is no note, through the
/// body and through the query.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_routes_treat_a_blank_note_as_no_note() {
    let env = Env::start_with(filed_world).await;
    let add = format!("/notes/{PLAYER_LOOP}/excerpts");
    let blocks = format!("/notes/{ECONOMY}/excerpts/blocks");
    let moves = format!("/notes/{ECONOMY}/excerpts/move");

    for (method, path, body) in [
        (
            "POST",
            add.clone(),
            Some(json!({"date": "2026-10-17", "block_id": "40s3hr", "note": ""})),
        ),
        (
            "POST",
            add.clone(),
            Some(json!({"date": "2026-10-17", "block_id": "ps0m60", "note": " \n\t "})),
        ),
        (
            "DELETE",
            format!("{blocks}/6v4mr7?date=2026-10-18&note="),
            None,
        ),
        (
            "DELETE",
            format!("{blocks}/65a642?date=2026-10-18&note=%20%20"),
            None,
        ),
        (
            "POST",
            moves.clone(),
            Some(json!({
                "date": "2026-10-19",
                "block_id": "et8g8y",
                "to_topic_note_id": PLAYER_LOOP,
                "note": "   ",
            })),
        ),
    ] {
        let reply = env.call(method, &path, body.as_ref()).await;
        assert_eq!(reply.status, 200, "{method} {path}: {}", reply.body);
    }

    assert_eq!(correction_texts(&env.server_vault()), vec![None; 5]);
}

/// Lead decision 8: the limit counts the raw text's chars, not its bytes, and
/// the text stays verbatim.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_routes_store_a_note_of_exactly_two_thousand_chars() {
    let env = Env::start_with(filed_world).await;
    let longest = "\u{2603}".repeat(2000);
    let padded = format!("  {}  ", "x".repeat(1996));
    let ascii = "x".repeat(2000);

    let add = env
        .call(
            "POST",
            &format!("/notes/{PLAYER_LOOP}/excerpts"),
            Some(&json!({"date": "2026-10-17", "block_id": "40s3hr", "note": longest})),
        )
        .await;
    assert_eq!(add.status, 200, "{}", add.body);
    let remove = env
        .call(
            "DELETE",
            &format!("/notes/{ECONOMY}/excerpts/blocks/6v4mr7?date=2026-10-18&note={ascii}"),
            None,
        )
        .await;
    assert_eq!(remove.status, 200, "{}", remove.body);
    let moved = env
        .call(
            "POST",
            &format!("/notes/{ECONOMY}/excerpts/move"),
            Some(&json!({
                "date": "2026-10-19",
                "block_id": "et8g8y",
                "to_topic_note_id": PLAYER_LOOP,
                "note": padded,
            })),
        )
        .await;
    assert_eq!(moved.status, 200, "{}", moved.body);

    assert_eq!(
        correction_texts(&env.server_vault()),
        [Some(longest), Some(ascii), Some(padded)]
    );
}

/// Lead decision 8: one char over is the CLI's `feedback_invalid`, before any
/// write, even when trimming the text would bring it under the limit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_routes_refuse_a_note_over_two_thousand_chars_as_feedback_invalid() {
    let env = Env::start_with(filed_world).await;
    let before = |vault: &Path| -> (i64, i64) {
        let conn = db(vault);
        (
            conn.query_row("SELECT count(*) FROM feedback", [], |r| r.get(0))
                .unwrap(),
            conn.query_row("SELECT sum(version) FROM notes", [], |r| r.get(0))
                .unwrap(),
        )
    };
    let start = before(&env.server_vault());
    let snowmen = "\u{2603}".repeat(2001);
    let padded = format!("  {}  ", "x".repeat(1997));
    let ascii = "x".repeat(2001);

    for note in [&snowmen, &padded] {
        let reply = env
            .call(
                "POST",
                &format!("/notes/{PLAYER_LOOP}/excerpts"),
                Some(&json!({"date": "2026-10-17", "block_id": "40s3hr", "note": note})),
            )
            .await;
        let mut args = block_args(PLAYER_LOOP, "2026-10-17", "40s3hr");
        args.extend(["--note", note.as_str()]);
        assert_same_failure(
            &reply,
            "feedback_invalid",
            &env.cli(&["excerpt", "add"], &args),
        );

        let reply = env
            .call(
                "POST",
                &format!("/notes/{ECONOMY}/excerpts/move"),
                Some(&json!({
                    "date": "2026-10-19",
                    "block_id": "et8g8y",
                    "to_topic_note_id": PLAYER_LOOP,
                    "note": note,
                })),
            )
            .await;
        let cli = env.cli(
            &["excerpt", "move"],
            &[
                "--date",
                "2026-10-19",
                "--block-id",
                "et8g8y",
                "--from-topic-note-id",
                ECONOMY,
                "--to-topic-note-id",
                PLAYER_LOOP,
                "--note",
                note.as_str(),
            ],
        );
        assert_same_failure(&reply, "feedback_invalid", &cli);
    }
    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{ECONOMY}/excerpts/blocks/6v4mr7?date=2026-10-18&note={ascii}"),
            None,
        )
        .await;
    let mut args = block_args(ECONOMY, "2026-10-18", "6v4mr7");
    args.extend(["--note", ascii.as_str()]);
    assert_same_failure(
        &reply,
        "feedback_invalid",
        &env.cli(&["excerpt", "remove-block"], &args),
    );

    assert_eq!(before(&env.server_vault()), start, "nothing was written");
}

/// Lead decision 8a: a blank block id is the CLI's `invalid_argument`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_routes_with_a_blank_block_id_are_the_cli_invalid_argument() {
    let env = Env::start().await;

    for blank in ["", "   "] {
        let reply = env
            .call(
                "POST",
                &format!("/notes/{PLAYER_LOOP}/excerpts"),
                Some(&json!({"date": "2026-10-18", "block_id": blank})),
            )
            .await;
        let cli = env.cli(
            &["excerpt", "add"],
            &block_args(PLAYER_LOOP, "2026-10-18", blank),
        );
        assert_same_failure(&reply, "invalid_argument", &cli);

        let reply = env
            .call(
                "POST",
                &format!("/notes/{ECONOMY}/excerpts/move"),
                Some(&json!({
                    "date": "2026-10-19",
                    "block_id": blank,
                    "to_topic_note_id": PLAYER_LOOP,
                })),
            )
            .await;
        let cli = env.cli(
            &["excerpt", "move"],
            &[
                "--date",
                "2026-10-19",
                "--block-id",
                blank,
                "--from-topic-note-id",
                ECONOMY,
                "--to-topic-note-id",
                PLAYER_LOOP,
            ],
        );
        assert_same_failure(&reply, "invalid_argument", &cli);
    }
    // An empty path segment is no route; spaces reach the route.
    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{ECONOMY}/excerpts/blocks/%20%20%20?date=2026-10-19"),
            None,
        )
        .await;
    let cli = env.cli(
        &["excerpt", "remove-block"],
        &block_args(ECONOMY, "2026-10-19", "   "),
    );
    assert_same_failure(&reply, "invalid_argument", &cli);
}

/// Lead decision 8b: an id no note has lists nothing, as core's read does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_ls_route_with_an_unknown_note_id_is_an_empty_list() {
    let env = Env::start_with(feedback_world).await;

    let reply = env
        .call("GET", &format!("/feedback?note_id={UNKNOWN}"), None)
        .await;

    assert_same_object(
        &reply,
        200,
        &env.cli(&["feedback", "ls"], &["--note-id", UNKNOWN]),
    );
    assert_eq!(
        reply.json(),
        json!({"vault_id": seed_vault_id(), "feedback": []})
    );
}

/// Lead decision 8b: `?note_id=` is the CLI's `invalid_argument`; only a request
/// with no parameter at all is the no-note list.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_ls_route_with_an_empty_note_id_is_the_cli_invalid_argument() {
    let env = Env::start_with(|dir| {
        feedback::record_chat(
            &mut open(dir),
            "On no note.",
            None,
            None,
            "Noted.",
            &[],
            &FixedClock(T0),
        )
        .unwrap();
    })
    .await;
    let no_note = env.call("GET", "/feedback", None).await;
    assert_eq!(no_note.status, 200, "{}", no_note.body);
    assert_eq!(
        no_note.json()["feedback"].as_array().unwrap().len(),
        1,
        "precondition: a no-note row to leak"
    );

    let reply = env.call("GET", "/feedback?note_id=", None).await;

    assert_same_failure(
        &reply,
        "invalid_argument",
        &env.cli(&["feedback", "ls"], &["--note-id", ""]),
    );
}

/// The route acts on the source in its URL and the target in its body.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_move_route_takes_the_source_from_the_path_and_the_target_from_the_body() {
    let env = Env::start().await;

    let reply = env
        .call(
            "POST",
            &format!("/notes/{ECONOMY}/excerpts/move"),
            Some(&json!({
                "date": "2026-10-19",
                "block_id": "et8g8y",
                "to_topic_note_id": PLAYER_LOOP,
            })),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);

    let body_of = |id: &str| -> String {
        db(&env.server_vault())
            .query_row("SELECT content_md FROM notes WHERE id = ?", [id], |r| {
                r.get(0)
            })
            .unwrap()
    };
    assert!(!body_of(ECONOMY).contains("et8g8y"), "{}", body_of(ECONOMY));
    assert!(
        body_of(PLAYER_LOOP).contains("et8g8y"),
        "{}",
        body_of(PLAYER_LOOP)
    );
    let row: String = db(&env.server_vault())
        .query_row("SELECT correction_json FROM feedback", [], |r| r.get(0))
        .unwrap();
    let correction: Value = serde_json::from_str(&row).unwrap();
    assert_eq!(correction["from_topic_note_id"], json!(ECONOMY));
    assert_eq!(correction["to_topic_note_id"], json!(PLAYER_LOOP));
    assert_eq!(correction["kind"], json!("excerpt_moved"));
}

// ---------------------------------------------------------------------------
// AC 7: failures are the C1 body, with the matching status
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn filing_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start().await;

    for (date, code) in [
        ("2026-13-01", "invalid_date"),
        ("not-a-date", "invalid_date"),
        ("2026-01-01", "not_found"),
    ] {
        let reply = env
            .call("GET", &format!("/daily-notes/{date}/filing"), None)
            .await;
        assert_same_failure(&reply, code, &env.cli(&["filing"], &["--date", date]));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_add_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start().await;

    for (topic_id, date, block, code) in [
        (UNKNOWN, "2026-10-18", "6v4mr7", "not_found"),
        (PLAYER_LOOP, "2026-01-01", "6v4mr7", "not_found"),
        (PLAYER_LOOP, "2026-10-18", "zzzzzz", "block_not_found"),
        (PLAYER_LOOP, "2026-13-01", "6v4mr7", "invalid_date"),
        (DAY_18, "2026-10-18", "6v4mr7", "role_rule"),
        ("not-a-ulid", "2026-10-18", "6v4mr7", "invalid_id"),
    ] {
        let reply = env
            .call(
                "POST",
                &format!("/notes/{topic_id}/excerpts"),
                Some(&json!({"date": date, "block_id": block})),
            )
            .await;
        let cli = env.cli(&["excerpt", "add"], &block_args(topic_id, date, block));
        assert_same_failure(&reply, code, &cli);
    }
    assert_eq!(
        db(&env.server_vault())
            .query_row("SELECT count(*) FROM feedback", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0,
        "no failure recorded a Correction"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_remove_block_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start().await;

    for (topic_id, date, block, code) in [
        (UNKNOWN, "2026-10-19", "et8g8y", "not_found"),
        // A real block of the day that the topic does not hold.
        (ECONOMY, "2026-10-19", "v4vv62", "not_found"),
        (ECONOMY, "2026-10-19", "zzzzzz", "block_not_found"),
        (ECONOMY, "2026-13-01", "et8g8y", "invalid_date"),
        (DAY_18, "2026-10-18", "6v4mr7", "role_rule"),
        ("not-a-ulid", "2026-10-19", "et8g8y", "invalid_id"),
    ] {
        let reply = env
            .call(
                "DELETE",
                &format!("/notes/{topic_id}/excerpts/blocks/{block}?date={date}"),
                None,
            )
            .await;
        let cli = env.cli(
            &["excerpt", "remove-block"],
            &block_args(topic_id, date, block),
        );
        assert_same_failure(&reply, code, &cli);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn excerpt_move_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start().await;

    for (from, to, date, block, code) in [
        (UNKNOWN, PLAYER_LOOP, "2026-10-19", "et8g8y", "not_found"),
        (ECONOMY, UNKNOWN, "2026-10-19", "et8g8y", "not_found"),
        // A real block of the day that the source does not hold.
        (ECONOMY, PLAYER_LOOP, "2026-10-19", "v4vv62", "not_found"),
        (
            ECONOMY,
            PLAYER_LOOP,
            "2026-10-19",
            "zzzzzz",
            "block_not_found",
        ),
        (ECONOMY, PLAYER_LOOP, "2026-13-01", "et8g8y", "invalid_date"),
        (
            "not-a-ulid",
            PLAYER_LOOP,
            "2026-10-19",
            "et8g8y",
            "invalid_id",
        ),
        (ECONOMY, "not-a-ulid", "2026-10-19", "et8g8y", "invalid_id"),
        // Lead decision 4: equal topics are refused up front, with C1
        // `invalid_argument` (not core's `internal`).
        (ECONOMY, ECONOMY, "2026-10-19", "et8g8y", "invalid_argument"),
    ] {
        let reply = env
            .call(
                "POST",
                &format!("/notes/{from}/excerpts/move"),
                Some(&json!({"date": date, "block_id": block, "to_topic_note_id": to})),
            )
            .await;
        let cli = env.cli(
            &["excerpt", "move"],
            &[
                "--date",
                date,
                "--block-id",
                block,
                "--from-topic-note-id",
                from,
                "--to-topic-note-id",
                to,
            ],
        );
        assert_same_failure(&reply, code, &cli);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_add_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start().await;
    let long = "x".repeat(2001);

    for (note, date, change, text, code) in [
        (DAY_18, "2026-10-18", CHANGE_18, "", "feedback_invalid"),
        (DAY_18, "2026-10-18", CHANGE_18, " \n ", "feedback_invalid"),
        (
            DAY_18,
            "2026-10-18",
            CHANGE_18,
            long.as_str(),
            "feedback_invalid",
        ),
        (DAY_18, "2026-13-01", CHANGE_18, "Text.", "invalid_date"),
        (UNKNOWN, "2026-10-18", CHANGE_18, "Text.", "not_found"),
        (DAY_18, "2026-10-18", UNKNOWN, "Text.", "not_found"),
        // An Activity entry of another note is no entry of this one.
        (DAY_18, "2026-10-18", CHANGE_ECONOMY, "Text.", "not_found"),
    ] {
        let reply = env
            .call(
                "POST",
                "/feedback",
                Some(&json!({"note_id": note, "date": date, "change_id": change, "text": text})),
            )
            .await;
        let cli = env.cli(
            &["feedback", "add"],
            &[
                "--note-id",
                note,
                "--date",
                date,
                "--change-id",
                change,
                "--text",
                text,
            ],
        );
        assert_same_failure(&reply, code, &cli);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_edit_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start_with(feedback_world).await;
    let (srv, cli_vault) = (env.server_vault(), env.cli_vault());
    let cases = [
        (
            UNKNOWN.to_string(),
            UNKNOWN.to_string(),
            "New.",
            "not_found",
        ),
        (
            comment_id(&srv, "Handled comment."),
            comment_id(&cli_vault, "Handled comment."),
            "New.",
            "feedback_handled",
        ),
        (
            correction_id(&srv),
            correction_id(&cli_vault),
            "New.",
            "feedback_invalid",
        ),
        (
            "tag-1".to_string(),
            "tag-1".to_string(),
            "New.",
            "feedback_invalid",
        ),
        (
            comment_id(&srv, "Open comment."),
            comment_id(&cli_vault, "Open comment."),
            "  ",
            "feedback_invalid",
        ),
    ];

    for (id, cli_id, text, code) in &cases {
        let reply = env
            .call(
                "PATCH",
                &format!("/feedback/{id}"),
                Some(&json!({ "text": text })),
            )
            .await;
        let cli = env.cli(&["feedback", "edit"], &["--id", cli_id, "--text", text]);
        assert_same_failure(&reply, code, &cli);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_rm_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start_with(feedback_world).await;
    let (srv, cli_vault) = (env.server_vault(), env.cli_vault());
    let cases = [
        (UNKNOWN.to_string(), UNKNOWN.to_string(), "not_found"),
        (
            comment_id(&srv, "Handled comment."),
            comment_id(&cli_vault, "Handled comment."),
            "feedback_handled",
        ),
        (
            correction_id(&srv),
            correction_id(&cli_vault),
            "feedback_invalid",
        ),
        ("tag-1".to_string(), "tag-1".to_string(), "feedback_invalid"),
    ];

    for (id, cli_id, code) in &cases {
        let reply = env.call("DELETE", &format!("/feedback/{id}"), None).await;
        let cli = env.cli(&["feedback", "rm"], &["--id", cli_id]);
        assert_same_failure(&reply, code, &cli);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guide_restore_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    // No guide yet, then a guide without that revision.
    let env = Env::start().await;
    let reply = env
        .call("POST", &format!("/guide/revisions/{UNKNOWN}/restore"), None)
        .await;
    let cli = env.cli(&["guide", "restore"], &["--revision-id", UNKNOWN]);
    assert_same_failure(&reply, "not_found", &cli);

    let env = Env::start_with(guide_world).await;
    let reply = env
        .call("POST", &format!("/guide/revisions/{UNKNOWN}/restore"), None)
        .await;
    let cli = env.cli(&["guide", "restore"], &["--revision-id", UNKNOWN]);
    assert_same_failure(&reply, "not_found", &cli);
}

/// `guide_rule` over the hosted routes the guide can reach.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guide_rule_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start_with(guide_world).await;
    // Read through the route, so the guide's route and the rules agree.
    let reply = env.call("GET", "/guide", None).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let doc = reply.json();
    let id = doc["note_id"].as_str().unwrap().to_string();
    let version = doc["version"].to_string();
    let cli_doc = env.cli(&["guide", "get"], &[]).json();
    let cli_id = cli_doc["note_id"].as_str().unwrap().to_string();

    let reply = env
        .call(
            "DELETE",
            &format!("/notes/{id}?expected_version={version}"),
            None,
        )
        .await;
    let cli = env.cli(
        &["rm"],
        &["--note-id", &cli_id, "--expected-version", &version],
    );
    assert_same_failure(&reply, "guide_rule", &cli);

    let reply = env
        .call(
            "POST",
            &format!("/smart-folders/{INBOX}/members"),
            Some(&json!({ "note_id": id })),
        )
        .await;
    let cli = env.cli(&["folder", "add"], &["--id", INBOX, "--note-id", &cli_id]);
    assert_same_failure(&reply, "guide_rule", &cli);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn member_delete_route_failures_are_the_cli_c1_bodies_with_the_matching_status() {
    let env = Env::start().await;

    for (folder, note) in [
        (UNKNOWN, ECONOMY),
        (SYSTEMS, UNKNOWN),
        // A real note that is not in this folder.
        (INBOX, ECONOMY),
    ] {
        let reply = env
            .call(
                "DELETE",
                &format!("/smart-folders/{folder}/members/{note}"),
                None,
            )
            .await;
        let cli = env.cli(&["folder", "remove"], &["--id", folder, "--note-id", note]);
        assert_same_failure(&reply, "not_found", &cli);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_requests_get_400_invalid_argument_and_write_nothing() {
    let env = Env::start_with(feedback_world).await;
    let open_id = comment_id(&env.server_vault(), "Open comment.");
    let excerpts = format!("/notes/{PLAYER_LOOP}/excerpts");
    let moves = format!("/notes/{ECONOMY}/excerpts/move");
    let edit = format!("/feedback/{open_id}");
    let block = format!("/notes/{ECONOMY}/excerpts/blocks/et8g8y");
    let snapshot = |vault: &Path| -> (i64, i64) {
        let conn = db(vault);
        (
            conn.query_row("SELECT count(*) FROM feedback", [], |r| r.get(0))
                .unwrap(),
            conn.query_row("SELECT sum(version) FROM notes", [], |r| r.get(0))
                .unwrap(),
        )
    };
    let before = snapshot(&env.server_vault());

    let cases: Vec<(&str, &str, Vec<u8>)> = vec![
        ("POST", excerpts.as_str(), b"".to_vec()),
        ("POST", excerpts.as_str(), b"not json".to_vec()),
        ("POST", excerpts.as_str(), b"{}".to_vec()),
        (
            "POST",
            excerpts.as_str(),
            br#"{"date": "2026-10-18"}"#.to_vec(),
        ),
        (
            "POST",
            excerpts.as_str(),
            br#"{"block_id": "6v4mr7"}"#.to_vec(),
        ),
        (
            "POST",
            excerpts.as_str(),
            br#"{"date": "2026-10-18", "block_id": "6v4mr7", "note": 7}"#.to_vec(),
        ),
        ("POST", moves.as_str(), b"{}".to_vec()),
        (
            "POST",
            moves.as_str(),
            br#"{"date": "2026-10-19", "block_id": "et8g8y"}"#.to_vec(),
        ),
        ("POST", "/feedback", b"{}".to_vec()),
        (
            "POST",
            "/feedback",
            format!(r#"{{"note_id": "{DAY_18}", "date": "2026-10-18", "change_id": "{CHANGE_18}"}}"#)
                .into_bytes(),
        ),
        (
            "POST",
            "/feedback",
            format!(
                r#"{{"note_id": "{DAY_18}", "date": "2026-10-18", "change_id": "{CHANGE_18}", "text": null}}"#
            )
            .into_bytes(),
        ),
        ("PATCH", edit.as_str(), b"{}".to_vec()),
        ("PATCH", edit.as_str(), br#"{"text": 7}"#.to_vec()),
        // The block route's date is required: it never defaults to today.
        ("DELETE", block.as_str(), b"".to_vec()),
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

    assert_eq!(snapshot(&env.server_vault()), before, "nothing was written");
}

// ---------------------------------------------------------------------------
// AC 8: removing a membership
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn member_delete_removes_an_agent_placed_membership_and_records_membership_removed() {
    let env = Env::start().await;
    assert!(is_member(&env.server_vault(), SYSTEMS, ECONOMY));

    let reply = env
        .call(
            "DELETE",
            &format!("/smart-folders/{SYSTEMS}/members/{ECONOMY}"),
            None,
        )
        .await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert!(!is_member(&env.server_vault(), SYSTEMS, ECONOMY));
    let listed = env
        .call("GET", &format!("/feedback?note_id={ECONOMY}"), None)
        .await
        .json();
    let rows = listed["feedback"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "exactly one Correction: {listed}");
    let row = &rows[0];
    assert_eq!(row["kind"], json!("correction"), "{row}");
    assert_eq!(row["source"], json!("person"), "{row}");
    assert_eq!(row["status"], json!("open"), "{row}");
    assert_eq!(row["note_id"], json!(ECONOMY), "{row}");
    assert_eq!(row["text"], Value::Null, "{row}");
    assert_eq!(
        row["correction"],
        json!({
            "kind": "membership_removed",
            "note_id": ECONOMY,
            "note_title": "Economy Design",
            "smart_folder_id": SYSTEMS,
            "folder_name": "Systems",
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn member_delete_removes_a_pinned_membership_and_records_nothing() {
    let env = Env::start().await;
    assert!(is_member(&env.server_vault(), DESIGN, PLAYER_LOOP));

    let reply = env
        .call(
            "DELETE",
            &format!("/smart-folders/{DESIGN}/members/{PLAYER_LOOP}"),
            None,
        )
        .await;

    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["removed"], json!(true));
    assert!(!is_member(&env.server_vault(), DESIGN, PLAYER_LOOP));
    let count: i64 = db(&env.server_vault())
        .query_row("SELECT count(*) FROM feedback", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0, "a pinned membership records nothing");
}

// ---------------------------------------------------------------------------
// AC 9: the routes on the full router
// ---------------------------------------------------------------------------

/// Every route the Contract adds, as `(METHOD, path)` with concrete ids.
fn contract_routes() -> Vec<(&'static str, String)> {
    vec![
        ("GET", "/daily-notes/2026-10-18/filing".to_string()),
        ("POST", format!("/notes/{PLAYER_LOOP}/excerpts")),
        ("DELETE", format!("/notes/{ECONOMY}/excerpts/blocks/et8g8y")),
        ("POST", format!("/notes/{ECONOMY}/excerpts/move")),
        ("POST", "/feedback".to_string()),
        ("GET", "/feedback".to_string()),
        ("PATCH", format!("/feedback/{UNKNOWN}")),
        ("DELETE", format!("/feedback/{UNKNOWN}")),
        ("GET", "/guide".to_string()),
        ("GET", "/guide/revisions".to_string()),
        ("POST", format!("/guide/revisions/{UNKNOWN}/restore")),
        (
            "DELETE",
            format!("/smart-folders/{SYSTEMS}/members/{ECONOMY}"),
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

/// Merging every domain router panics here on a path-parameter-name clash (D20).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_api_router_starts_with_every_contract_route_registered() {
    let (addr, task) = serve_nested(memex_mcp::server::api::router()).await;

    for (method, path) in contract_routes() {
        let status = status_at(addr, method, &path).await;
        assert!(
            status != 404 && status != 405,
            "{method} {path} is served by the merged api router (got {status})"
        );
    }

    task.abort();
}

/// D20: `/feedback*` and `/guide*` live in `api/feedback.rs` and nowhere else.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_router_holds_the_feedback_and_guide_paths_and_no_others() {
    let (addr, task) = serve_nested(memex_mcp::server::api::feedback::router()).await;

    for (method, path) in contract_routes() {
        let status = status_at(addr, method, &path).await;
        let own = path.starts_with("/feedback") || path.starts_with("/guide");
        if own {
            assert!(
                status != 404 && status != 405,
                "{method} {path} is in the feedback router (got {status})"
            );
        } else {
            assert_eq!(status, 404, "{method} {path} is not in the feedback router");
        }
    }

    task.abort();
}

/// D20: the members DELETE lives in `api/topics.rs`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn topics_router_holds_the_member_delete_route() {
    let (addr, task) = serve_nested(memex_mcp::server::api::topics::router()).await;

    let status = status_at(
        addr,
        "DELETE",
        &format!("/smart-folders/{SYSTEMS}/members/{ECONOMY}"),
    )
    .await;

    assert!(status != 404 && status != 405, "got {status}");
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn contract_routes_answer_wrong_methods_with_the_c1_405() {
    let env = Env::start().await;
    let at = |p: String| format!("{BASE}{p}");
    let filing = at("/daily-notes/2026-10-18/filing".to_string());
    let excerpts = at(format!("/notes/{PLAYER_LOOP}/excerpts"));
    let block = at(format!("/notes/{ECONOMY}/excerpts/blocks/et8g8y"));
    let moves = at(format!("/notes/{ECONOMY}/excerpts/move"));
    let feedback_all = at("/feedback".to_string());
    let feedback_one = at(format!("/feedback/{UNKNOWN}"));
    let guide_doc = at("/guide".to_string());
    let revisions = at("/guide/revisions".to_string());
    let restore = at(format!("/guide/revisions/{UNKNOWN}/restore"));
    let member = at(format!("/smart-folders/{SYSTEMS}/members/{ECONOMY}"));

    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (filing.as_str(), &["GET"][..]),
            (excerpts.as_str(), &["POST", "DELETE"][..]),
            (block.as_str(), &["DELETE"][..]),
            (moves.as_str(), &["POST"][..]),
            (feedback_all.as_str(), &["GET", "POST"][..]),
            (feedback_one.as_str(), &["PATCH", "DELETE"][..]),
            (guide_doc.as_str(), &["GET"][..]),
            (revisions.as_str(), &["GET"][..]),
            (restore.as_str(), &["POST"][..]),
            (member.as_str(), &["DELETE"][..]),
        ],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn contract_routes_answer_401_without_a_bearer_token_and_serve_with_one() {
    let env = Env::start().await;

    for (method, path) in contract_routes() {
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
        // With the token the route answers, whatever the request's flaws.
        let reply = Reply::read(send(Some(env.srv.bearer())).await.unwrap()).await;
        assert_ne!(reply.status, 401, "{method} {path}");
        assert_ne!(reply.status, 405, "{method} {path}");
        assert_ne!(
            reply.json()["error"]["message"],
            json!("not found: no route for this path"),
            "{method} {path}"
        );
    }
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

    fn vault(&self) -> std::path::PathBuf {
        self.root.path().join(SEED_VAULT_NAME)
    }

    /// Sends a request that succeeds and asserts the embedder ran during it.
    async fn expect_a_batch(
        &self,
        batches: &AtomicUsize,
        what: &str,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) {
        let before = batches.load(Ordering::SeqCst);
        let reply = self.call(method, path, None, body.as_ref()).await;
        assert!(reply.status < 300, "{what}: {}", reply.body);
        assert!(
            batches.load(Ordering::SeqCst) > before,
            "{what} reindexed with the shared embedder"
        );
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

/// Lead decision 5, R40: restore dates its entry today in the request's zone,
/// from the request's clock. 2026-11-05T12:00Z is 2026-11-06 at +14:00 and
/// 2026-11-05 at -12:00. Nothing in the request can name the day.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guide_restore_route_dates_its_entry_in_the_requests_zone() {
    let now = Utc
        .with_ymd_and_hms(2026, 11, 5, 12, 0, 0)
        .unwrap()
        .timestamp_millis();
    let srv =
        ConfiguredServer::start(guide_world, |c| c.with_clock(Arc::new(FixedClock(now)))).await;
    let newest_entry = |vault: &Path| -> (String, i64) {
        db(vault)
            .query_row(
                "SELECT day, created_at FROM agent_changes WHERE note_id = ?
                 ORDER BY rowid DESC LIMIT 1",
                [guide_id(vault)],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    };

    for (offset, day) in [("+14:00", "2026-11-06"), ("-12:00", "2026-11-05")] {
        let id = newest_revision(&srv.vault());
        let reply = srv
            .call(
                "POST",
                &format!("/guide/revisions/{id}/restore?day=1999-01-01"),
                Some(offset),
                Some(&json!({"day": "1999-01-01"})),
            )
            .await;
        assert_eq!(reply.status, 200, "{offset}: {}", reply.body);
        assert_eq!(
            newest_entry(&srv.vault()),
            (day.to_string(), now),
            "at {offset}"
        );
    }
}

/// Hosted writes stamp the request's clock, not the wall clock.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn feedback_and_guide_routes_stamp_the_requests_clock() {
    let now = T0 + 12_345;
    let srv = ConfiguredServer::start(|_| {}, |c| c.with_clock(Arc::new(FixedClock(now)))).await;

    let added = srv
        .call(
            "POST",
            "/feedback",
            None,
            Some(&json!({
                "note_id": DAY_18,
                "date": "2026-10-18",
                "change_id": CHANGE_18,
                "text": "Wrong topic.",
            })),
        )
        .await;
    assert_eq!(added.status, 201, "{}", added.body);
    assert_eq!(added.json()["created_at"], json!(now), "{}", added.body);
    assert_eq!(added.json()["updated_at"], json!(now), "{}", added.body);

    let id = added.json()["id"].as_str().unwrap().to_string();
    let edited = srv
        .call(
            "PATCH",
            &format!("/feedback/{id}"),
            None,
            Some(&json!({"text": "Right topic."})),
        )
        .await;
    assert_eq!(edited.status, 200, "{}", edited.body);
    assert_eq!(edited.json()["updated_at"], json!(now), "{}", edited.body);

    let guide_doc = srv.call("GET", "/guide", None, None).await;
    assert_eq!(guide_doc.status, 200, "{}", guide_doc.body);
    let created: i64 = db(&srv.vault())
        .query_row(
            "SELECT created_at FROM notes WHERE id = ?",
            [guide_id(&srv.vault())],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(created, now, "the first read is stamped by the request");
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

/// Lead decision 6: hosted writes reindex with the registry's shared embedder.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hosted_writes_reindex_with_the_shared_embedder() {
    let batches = Arc::new(AtomicUsize::new(0));
    let embedder = CountingEmbedder {
        inner: FakeEmbedder::new(8),
        batches: batches.clone(),
    };
    let srv = ConfiguredServer::start(
        |dir| {
            agent_files(&mut open(dir), ECONOMY, "2026-10-18", &["6v4mr7", "65a642"]);
        },
        |c| c.with_embeddings(true).with_embedder(Arc::new(embedder)),
    )
    .await;

    // The server's background backfill (#422) shares this embedder and runs
    // an `embed_batch` of its own once the first request opens the vault.
    // Let it finish first, so each count below is the request's own batch.
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

    srv.expect_a_batch(
        &batches,
        "excerpt add",
        "POST",
        &format!("/notes/{PLAYER_LOOP}/excerpts"),
        Some(json!({"date": "2026-10-19", "block_id": "v4vv62"})),
    )
    .await;
    srv.expect_a_batch(
        &batches,
        "excerpt remove-block",
        "DELETE",
        &format!("/notes/{ECONOMY}/excerpts/blocks/6v4mr7?date=2026-10-18"),
        None,
    )
    .await;
    srv.expect_a_batch(
        &batches,
        "excerpt move",
        "POST",
        &format!("/notes/{ECONOMY}/excerpts/move"),
        Some(json!({
            "date": "2026-10-19",
            "block_id": "et8g8y",
            "to_topic_note_id": PLAYER_LOOP,
        })),
    )
    .await;
    srv.expect_a_batch(&batches, "guide first read", "GET", "/guide", None)
        .await;
    agent_update_guide(&srv.vault());
    let id = newest_revision(&srv.vault());
    srv.expect_a_batch(
        &batches,
        "guide restore",
        "POST",
        &format!("/guide/revisions/{id}/restore"),
        None,
    )
    .await;
}
