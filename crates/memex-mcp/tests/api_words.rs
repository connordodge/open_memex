//! WI #431 (W2): learned words over the hosted API, on the full
//! `memex_mcp::server::router()` (Spec #392 requirement 16; rulings D20,
//! D21, D22).
//!
//! Under `/vaults/{name}/api/v1`:
//!
//! | Route | Body | Response |
//! |---|---|---|
//! | `GET /words` | | the `memex words ls` object `{"vault_id","words":[{"word","created_at"}]}`, by `word_key` |
//! | `POST /words` | `{"word"}` | the `memex words add` object `{"vault_id","word","changed"}` |
//! | `DELETE /words/{word}` | | the `memex words rm` object `{"vault_id","word","changed"}` |
//!
//! `{word}` arrives percent-decoded. `word_invalid` is 400. A `DELETE` never
//! answers `word_invalid` (lead ruling): an empty, spaced or over-long word
//! is 200 `changed: false` and writes nothing.
//!
//! Every CLI parity test runs the real `memex` binary on a second copy of the
//! seed (temp dirs only). The rows of `app/test/fixtures/api_v1/words/index.json`
//! hold the W3 client's contract: never rebless them to fit the server.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

use api_fixtures::{
    api_v1_dir, bless_requested, load_rows, materialize_seed, run_rows, seed_vault_id,
    FixtureRequest, FixtureResponse, FixtureRow, SEED_VAULT_NAME,
};
use server::{assert_wrong_method_is_c1_405, encode_segment, raw_request, Reply, TestServer};

const BASE: &str = "/vaults/seed/api/v1";

/// A wrong but well-formed bearer token.
const WRONG_TOKEN: &str = "Bearer not-the-token-0000000000000000000000000000";

/// `(word, created_at)` rows written straight into `learned_words` before the
/// server opens the vault, so `created_at` is exact.
type Learned<'a> = &'a [(&'a str, i64)];

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
        Self::start_with(&[]).await
    }

    /// Writes `learned` into both seed copies, with the vault closed, before
    /// the server opens its copy.
    async fn start_with(learned: Learned<'_>) -> Self {
        let root = tempfile::tempdir().unwrap();
        let cli_root = tempfile::tempdir().unwrap();
        for dir in [root.path(), cli_root.path()] {
            let vault = materialize_seed(dir);
            let conn = db(&vault);
            for (word, created_at) in learned {
                conn.execute(
                    "INSERT INTO learned_words (word_key, word, created_at) VALUES (?1, ?2, ?3)",
                    params![word.to_lowercase(), word, created_at],
                )
                .expect("seed a learned word");
            }
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
        self.call_as(Some(&self.srv.bearer()), method, path, body)
            .await
    }

    /// `METHOD <BASE><path>` with `authorization` (none when `None`).
    async fn call_as(
        &self,
        authorization: Option<&str>,
        method: &str,
        path: &str,
        body: Option<&Value>,
    ) -> Reply {
        let mut head =
            format!("{method} {BASE}{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
        if let Some(auth) = authorization {
            head.push_str(&format!("Authorization: {auth}\r\n"));
        }
        let bytes = body.map(|b| serde_json::to_vec(b).unwrap());
        self.send(head, bytes.as_deref()).await
    }

    /// `POST <BASE>/words` with the token and raw `body` bytes.
    async fn post_raw(&self, body: &[u8]) -> Reply {
        let head = format!(
            "POST {BASE}/words HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\
             Authorization: {}\r\n",
            self.srv.bearer()
        );
        self.send(head, Some(body)).await
    }

    async fn send(&self, mut head: String, body: Option<&[u8]>) -> Reply {
        if let Some(bytes) = body {
            head.push_str(&format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                bytes.len()
            ));
        }
        raw_request(self.srv.addr(), &head, body.unwrap_or_default()).await
    }

    async fn ls(&self) -> Reply {
        self.call("GET", "/words", None).await
    }

    async fn add(&self, word: &str) -> Reply {
        self.call("POST", "/words", Some(&json!({ "word": word })))
            .await
    }

    /// `DELETE /words/<word, every byte outside A-Za-z0-9-_ percent-encoded>`.
    async fn rm(&self, word: &str) -> Reply {
        self.rm_raw(&encode_segment(word)).await
    }

    /// `DELETE /words/<segment>`, the segment sent exactly as given.
    async fn rm_raw(&self, segment: &str) -> Reply {
        self.call("DELETE", &format!("/words/{segment}"), None)
            .await
    }

    /// The server copy's `(word_key, word, created_at)` rows, by `word_key`.
    fn rows(&self) -> Vec<(String, String, i64)> {
        rows_of(&self.server_vault())
    }

    /// The server copy's `content_revision.n`.
    fn revision(&self) -> i64 {
        db(&self.server_vault())
            .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// `memex words <sub> --vault <cli copy> <rest…>`.
    fn cli(&self, sub: &str, rest: &[&str]) -> Cli {
        let out = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["words", sub])
            .arg("--vault")
            .arg(self.cli_vault())
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
}

/// What a `memex` run printed.
struct Cli {
    ok: bool,
    stdout: String,
    stderr: String,
}

impl Cli {
    /// The one stdout line of a successful run, without its newline.
    fn line(&self) -> &str {
        assert!(self.ok, "memex failed: {}", self.stderr);
        self.stdout
            .strip_suffix('\n')
            .unwrap_or_else(|| panic!("stdout ends with a newline: {:?}", self.stdout))
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

fn rows_of(vault: &Path) -> Vec<(String, String, i64)> {
    let conn = db(vault);
    let mut stmt = conn
        .prepare("SELECT word_key, word, created_at FROM learned_words ORDER BY word_key")
        .unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    rows
}

/// `(word_key, word)` of each row, dropping `created_at`.
fn keys(rows: &[(String, String, i64)]) -> Vec<(&str, &str)> {
    rows.iter()
        .map(|(k, w, _)| (k.as_str(), w.as_str()))
        .collect()
}

/// The exact `add|rm` object.
fn write_object(word: &str, changed: bool) -> Value {
    json!({"vault_id": seed_vault_id(), "word": word, "changed": changed})
}

/// A 200 JSON reply's body.
fn ok_json(reply: &Reply, what: &str) -> Value {
    assert_eq!(reply.status, 200, "{what}: {}", reply.body);
    assert!(
        reply
            .header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "{what}: a JSON body, got content-type {:?}",
        reply.header("content-type")
    );
    reply.json()
}

fn long_word(chars: usize) -> String {
    "a".repeat(chars)
}

// ---------------------------------------------------------------------------
// AC1: GET /words
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_words_on_the_seed_is_200_with_the_vault_id_and_no_words() {
    let env = Env::start().await;
    let body = ok_json(&env.ls().await, "GET /words");
    assert_eq!(body, json!({"vault_id": seed_vault_id(), "words": []}));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_words_lists_every_learned_word_by_word_key_with_its_created_at() {
    // Byte order of `word` would put `Apple`, `Memex` before `banana`;
    // `word_key` order is apple, banana, memex, zebra, émile (é is U+00E9).
    let env = Env::start_with(&[
        ("zebra", 1_000),
        ("Émile", 2_000),
        ("Memex", 3_000),
        ("banana", 4_000),
        ("Apple", 5_000),
    ])
    .await;
    let body = ok_json(&env.ls().await, "GET /words");
    assert_eq!(
        body,
        json!({
            "vault_id": seed_vault_id(),
            "words": [
                {"word": "Apple", "created_at": 5_000},
                {"word": "banana", "created_at": 4_000},
                {"word": "Memex", "created_at": 3_000},
                {"word": "zebra", "created_at": 1_000},
                {"word": "Émile", "created_at": 2_000},
            ],
        })
    );
}

// ---------------------------------------------------------------------------
// AC2: POST /words, then the same POST again
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_words_memex_is_changed_true_then_the_same_post_is_changed_false() {
    let env = Env::start().await;
    let first = ok_json(&env.add("memex").await, "first POST");
    assert_eq!(first, write_object("memex", true));
    assert_eq!(keys(&env.rows()), vec![("memex", "memex")]);
    let n = env.revision();

    let again = ok_json(&env.add("memex").await, "second POST");
    assert_eq!(again, write_object("memex", false));
    assert_eq!(keys(&env.rows()), vec![("memex", "memex")], "one row");
    assert_eq!(env.revision(), n, "a repeat learn writes nothing");

    // Another capitalisation, padded: trimmed, same key, first spelling kept.
    let other = ok_json(&env.add("  Memex ").await, "POST of Memex");
    assert_eq!(other, write_object("Memex", false));
    assert_eq!(keys(&env.rows()), vec![("memex", "memex")]);
    assert_eq!(env.revision(), n);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn words_routes_answer_the_same_json_as_the_memex_words_cli() {
    let env = Env::start_with(&[("Kept", 1_234), ("zymurgy", 5_678)]).await;

    // `ls`, byte for byte (created_at is fixed in both copies).
    let api = env.ls().await;
    assert_eq!(api.status, 200, "{}", api.body);
    assert_eq!(api.body, env.cli("ls", &[]).line(), "GET /words == ls");

    for (method, word) in [
        ("add", "memex"),
        ("add", "memex"),
        ("add", "Émile"),
        ("rm", "émile"),
        ("rm", "émile"),
        ("rm", "KEPT"),
    ] {
        let api = match method {
            "add" => env.add(word).await,
            _ => env.rm(word).await,
        };
        let cli = env.cli(method, &["--word", word]);
        assert_eq!(api.status, 200, "{method} {word}: {}", api.body);
        assert_eq!(
            api.body,
            cli.line(),
            "{method} {word}: API body == CLI stdout"
        );
    }

    // The same C1 body as the CLI's `word_invalid` line.
    let long = long_word(65);
    let api = env.add(&long).await;
    assert_eq!(api.status, 400, "{}", api.body);
    assert_eq!(api.json(), env.cli("add", &["--word", &long]).error());

    assert_eq!(
        keys(&env.rows()),
        keys(&rows_of(&env.cli_vault())),
        "both copies hold the same words"
    );
}

// ---------------------------------------------------------------------------
// AC3: a non-ASCII word
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_words_emile_stores_word_key_emile_and_a_later_get_lists_emile() {
    let env = Env::start().await;
    let added = ok_json(&env.add("Émile").await, "POST Émile");
    assert_eq!(added, write_object("Émile", true));
    assert_eq!(keys(&env.rows()), vec![("émile", "Émile")]);

    let listed = ok_json(&env.ls().await, "GET /words");
    let words: Vec<&str> = listed["words"]
        .as_array()
        .expect("words is an array")
        .iter()
        .map(|w| w["word"].as_str().expect("word is a string"))
        .collect();
    assert_eq!(words, vec!["Émile"]);
    let created_at = &listed["words"][0]["created_at"];
    assert_eq!(
        created_at.as_i64(),
        Some(env.rows()[0].2),
        "created_at is the stored Unix ms: {listed}"
    );

    // The lowercase spelling is the same key.
    let again = ok_json(&env.add("émile").await, "POST émile");
    assert_eq!(again, write_object("émile", false));
    assert_eq!(keys(&env.rows()), vec![("émile", "Émile")]);
}

// ---------------------------------------------------------------------------
// AC4: word_invalid
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_a_65_character_word_is_400_word_invalid_and_writes_nothing() {
    let env = Env::start().await;
    let n = env.revision();
    let long = long_word(65);
    let reply = env.add(&long).await;
    assert_eq!(reply.status, 400, "{}", reply.body);
    assert_eq!(reply.c1_code(), "word_invalid");
    assert_eq!(env.rows(), vec![], "a rejected word writes nothing");
    assert_eq!(env.revision(), n, "a rejected word moves no revision");

    for (word, what) in [
        ("", "empty"),
        ("   ", "empty after trimming"),
        ("spell check", "inner space"),
        ("spell\tcheck", "inner tab"),
    ] {
        let reply = env.add(word).await;
        assert_eq!(reply.status, 400, "{what}: {}", reply.body);
        assert_eq!(reply.c1_code(), "word_invalid", "{what}");
    }
    assert_eq!(env.rows(), vec![]);
    assert_eq!(env.revision(), n);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_a_64_character_non_ascii_word_is_learned() {
    // 64 characters but 128 bytes: the limit counts characters.
    let env = Env::start().await;
    let word = "é".repeat(64);
    let reply = ok_json(&env.add(&word).await, "POST 64 × é");
    assert_eq!(reply, write_object(&word, true));
    assert_eq!(keys(&env.rows()), vec![(word.as_str(), word.as_str())]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn post_words_with_a_malformed_body_is_400_invalid_argument_and_writes_nothing() {
    let env = Env::start().await;
    let n = env.revision();
    for (body, what) in [
        (&b"{}"[..], "no word field"),
        (&br#"{"word": 5}"#[..], "word is not a string"),
        (&br#"{"words": "memex"}"#[..], "wrong field name"),
        (&b"memex"[..], "not JSON"),
    ] {
        let reply = env.post_raw(body).await;
        assert_eq!(reply.status, 400, "{what}: {}", reply.body);
        assert_eq!(reply.c1_code(), "invalid_argument", "{what}");
    }
    assert_eq!(env.rows(), vec![]);
    assert_eq!(env.revision(), n);
}

// ---------------------------------------------------------------------------
// AC5: DELETE /words/{word}
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_percent_encoded_emile_removes_the_emile_row_and_a_missing_word_is_changed_false() {
    let env = Env::start_with(&[("Émile", 1_000), ("memex", 2_000)]).await;
    let removed = ok_json(&env.rm_raw("%C3%A9mile").await, "DELETE %C3%A9mile");
    assert_eq!(removed, write_object("émile", true));
    assert_eq!(
        keys(&env.rows()),
        vec![("memex", "memex")],
        "only Émile goes"
    );
    let n = env.revision();

    let gone = ok_json(&env.rm_raw("%C3%A9mile").await, "DELETE again");
    assert_eq!(gone, write_object("émile", false));
    let never = ok_json(&env.rm("serendipity").await, "DELETE serendipity");
    assert_eq!(never, write_object("serendipity", false));
    assert_eq!(keys(&env.rows()), vec![("memex", "memex")]);
    assert_eq!(env.revision(), n, "a word that isn't there writes nothing");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_matches_the_word_key_in_any_case_and_decodes_a_slash_inside_the_segment() {
    let env = Env::start_with(&[("Memex", 1_000), ("Émile", 2_000), ("and/or", 3_000)]).await;
    let memex = ok_json(&env.rm("MEMEX").await, "DELETE MEMEX");
    assert_eq!(memex, write_object("MEMEX", true));
    let emile = ok_json(&env.rm_raw("%C3%89MILE").await, "DELETE %C3%89MILE");
    assert_eq!(emile, write_object("ÉMILE", true));
    // `%2F` stays inside the one `{word}` segment and decodes to `/`.
    let slash = ok_json(&env.rm_raw("and%2For").await, "DELETE and%2For");
    assert_eq!(slash, write_object("and/or", true));
    assert_eq!(env.rows(), vec![]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delete_an_empty_spaced_or_65_character_word_is_200_changed_false_and_writes_nothing() {
    // Lead ruling: `rm` never runs the word_invalid check.
    let env = Env::start_with(&[("memex", 1_000)]).await;
    let n = env.revision();
    let long = long_word(65);
    for (segment, word, what) in [
        ("%20", "", "a space, empty after trimming"),
        ("spell%20check", "spell check", "an inner space"),
        ("spell%09check", "spell\tcheck", "an inner tab"),
        (long.as_str(), long.as_str(), "65 characters"),
    ] {
        let reply = ok_json(&env.rm_raw(segment).await, what);
        assert_eq!(reply, write_object(word, false), "{what}");
    }
    assert_eq!(keys(&env.rows()), vec![("memex", "memex")]);
    assert_eq!(env.revision(), n, "nothing is written");
}

// ---------------------------------------------------------------------------
// AC6: the access token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn each_words_route_without_the_token_is_401_and_writes_nothing_and_200_with_it() {
    let env = Env::start_with(&[("memex", 1_000)]).await;
    let n = env.revision();
    let routes: [(&str, &str, Option<Value>); 3] = [
        ("GET", "/words", None),
        ("POST", "/words", Some(json!({"word": "serendipity"}))),
        ("DELETE", "/words/memex", None),
    ];
    for (method, path, body) in &routes {
        for (auth, what) in [(None, "no token"), (Some(WRONG_TOKEN), "a wrong token")] {
            let reply = env.call_as(auth, method, path, body.as_ref()).await;
            assert_eq!(
                reply.status, 401,
                "{method} {path} with {what}: {}",
                reply.body
            );
            assert_eq!(
                reply.c1_code(),
                "unauthorized",
                "{method} {path} with {what}"
            );
        }
    }
    assert_eq!(
        keys(&env.rows()),
        vec![("memex", "memex")],
        "a refused request writes nothing"
    );
    assert_eq!(env.revision(), n, "a refused request moves no revision");

    // The token is what was missing: the same requests with it are served.
    for (method, path, body) in &routes {
        let reply = env.call(method, path, body.as_ref()).await;
        assert_eq!(
            reply.status, 200,
            "{method} {path} with the token: {}",
            reply.body
        );
    }
    assert_eq!(keys(&env.rows()), vec![("serendipity", "serendipity")]);
}

// ---------------------------------------------------------------------------
// The full router (D20)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_serves_the_words_routes_on_their_paths_only_and_other_methods_are_c1_405() {
    // `TestServer` is `memex_mcp::server::router()`: a path parameter clash
    // panics only when it starts.
    let env = Env::start().await;
    assert_wrong_method_is_c1_405(
        &env.srv,
        &[
            (format!("{BASE}/words").as_str(), &["GET", "POST"]),
            (format!("{BASE}/words/memex").as_str(), &["DELETE"]),
        ],
    )
    .await;
    for path in ["/words/memex/extra", "/word", "/words/memex/notes"] {
        let reply = env.call("GET", path, None).await;
        assert_eq!(reply.status, 404, "GET {path}: {}", reply.body);
        assert_eq!(reply.c1_code(), "not_found", "GET {path}");
    }
    // A vault the root doesn't hold is the guard's 404, not a words reply.
    let reply = Reply::read(
        server::client()
            .get(env.srv.url("/vaults/nope/api/v1/words"))
            .header("authorization", env.srv.bearer())
            .send()
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(reply.status, 404, "{}", reply.body);
    // And the seed's own route answers.
    assert_eq!(env.ls().await.status, 200);
}

// ---------------------------------------------------------------------------
// AC7: the contract fixtures
// ---------------------------------------------------------------------------

fn words_dir() -> PathBuf {
    api_v1_dir().join("words")
}

/// A row's `(method, path template)`.
fn template(row: &FixtureRow) -> (String, String) {
    let path = row
        .path
        .strip_prefix(BASE)
        .expect("every row is under BASE");
    let segments: Vec<&str> = path.split('/').collect();
    let templated: Vec<&str> = match segments.as_slice() {
        ["", "words"] => vec!["", "words"],
        ["", "words", _] => vec!["", "words", "{word}"],
        other => panic!("a words row on an unexpected path: {other:?}"),
    };
    (row.method.clone(), templated.join("/"))
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

#[test]
fn words_fixture_rows_cover_every_route_and_match_the_server_on_the_seed() {
    let rows = load_rows(&words_dir()).expect("words/index.json parses");
    let served: BTreeSet<(String, String)> = rows.iter().map(template).collect();
    let table: BTreeSet<(String, String)> = [
        ("GET", "/words"),
        ("POST", "/words"),
        ("DELETE", "/words/{word}"),
    ]
    .iter()
    .map(|(m, p)| (m.to_string(), p.to_string()))
    .collect();
    assert_eq!(served, table, "words/index.json routes == the D20 table");
    assert!(
        rows.iter()
            .any(|r| r.method == "DELETE" && r.path == format!("{BASE}/words/%C3%A9mile")),
        "a row DELETEs the percent-encoded émile"
    );
    assert!(rows.iter().all(|r| !r.dart_only), "every row runs here");

    // Spec #392 requirement 16's fixture names, each served by a row.
    let files: BTreeSet<&str> = rows
        .iter()
        .flat_map(|r| [Some(r.response.as_str()), r.request.as_deref()])
        .flatten()
        .collect();
    for name in [
        "words_ls.json",
        "words_add.json",
        "words_add.request.json",
        "words_add_repeat.json",
        "words_add_non_ascii.json",
        "words_add_non_ascii.request.json",
        "words_add_too_long.json",
        "words_add_too_long.request.json",
        "words_rm.json",
        "words_rm_gone.json",
        "words_rm_non_ascii.json",
    ] {
        assert!(files.contains(name), "no words row names {name}: {files:?}");
    }

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = rt.block_on(TestServer::start_in(root));
    let result = run_rows(&words_dir(), bless_requested(), |req| {
        rt.block_on(exec(&srv, req))
    });
    drop(srv);
    if let Err(e) = result {
        panic!("{e}");
    }
}
