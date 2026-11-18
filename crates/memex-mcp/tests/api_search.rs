//! WI #73 (Spec #59 requirements 34, 37, 38; rulings D10, D18): the vault
//! server's `GET /vaults/{name}/api/v1/search?q=<text>&limit=<n>`.
//!
//! - It answers `memex_core::note_search`'s JSON (requirement 34):
//!   `{query, semantic, hits: [{note_id, note_title, note_role, day,
//!   chunk_id, snippet, start_byte, via, note_updated_at}], truncated}`.
//! - `limit` is optional (default 8) and validated like echoes' (1 to 20,
//!   else 400 `invalid_argument`); a missing `q` is an empty query, which
//!   answers `hits: []`.
//! - With the server's embedder it is `semantic: "on"`; without one
//!   (`--with-embeddings` off) it is keyword only with `"embeddings_off"`,
//!   answered 200 (not echoes' 409); an embedder failure is keyword only
//!   with `"unavailable"`. It never downloads a model and never embeds a
//!   pending chunk (`pending_cap` 0).
//! - The vault lock is never held across the query embedding.
//!
//! The wire fixtures are `app/test/fixtures/api_v1/search/` (run here
//! through `run_rows`, rewritten under `MEMEX_BLESS=1`) and
//! `app/test/fixtures/api_v1/compat/search_not_found.json` (the body an
//! older server answers). Vectors are written in this file's own setup; the
//! shared `seed_vault.sql` is untouched. Every server is the full
//! `server::router()`. No test runs the real model, and no wait is on the
//! wall clock: the concurrency test gates the embedder, and timeouts are
//! hang guards only.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use memex_core::embedder::{Embedder, FastEmbedder, GatedEmbedder, TableEmbedder};
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote};
use memex_core::schema;
use memex_core::vectors::embedding_counts;
use memex_core::{note_search, Caller, MemexError, SearchEmbedder, Vault};
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::model_cache_dir;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{
    api_v1_dir, bless_requested, canonical_json, load_rows, materialize_seed, normalize_volatile,
    run_rows, FixtureRequest, FixtureResponse, SEED_VAULT_NAME,
};
use server::{
    assert_wrong_method_is_c1_405_at, client, wait_for_logs, Reply, ServeCommand, ANY_PORT,
    TEST_TOKEN, TOKEN_ENV, WAIT,
};

/// The BGE-small-en-v1.5 vector width the seed vectors use.
const DIM: usize = 384;

const SEED: &str = "/vaults/seed/api/v1";

const PLAYER_LOOP: &str = "01M5DQAYZ3WP7H0NXZZV9M2315";
const ECONOMY: &str = "01M5DQAYZ47QW55S90ZF0A56AH";
const PACING: &str = "01M5DQAYZ4YAPYMEDWXP8WCNGJ";
const LOOSE: &str = "01M5DQAYZ4RYSGA8T0YEEF8QRS";
const DAY_18: &str = "01M5DQAYZ4TAPTHDWE5PNWE4W5";
const DAY_19: &str = "01M5DQAYZ51PF87XFZWSV5PWXK";
const DAY_17: &str = "01M5DQAYZ5T5B865CDF2RWAC37";
const DAY_16: &str = "01M5DQAYZ50YGKE126FXV02TEY";
const DAY_15: &str = "01M5DQAYZ592W2515HPSDF5Q16";
const BROKEN: &str = "01M5DQAYZ5RH88SRZGPY15XXVM";

/// The seed query of every fixture row: it matches two daily notes, and
/// one of them is transcluded by Economy Design (a `via` hit).
const QUERY: &str = "prices";

/// Main's unknown-route message (the body of an older server).
const NO_ROUTE_MESSAGE: &str = "not found: no route for this path";

/// The fixture response files, by the server that answers them.
const OFF_RESPONSE: &str = "search_embeddings_off.json";
const ON_RESPONSE: &str = "search_on.json";
const UNAVAILABLE_RESPONSE: &str = "search_unavailable.json";
const TRUNCATED_RESPONSE: &str = "search_truncated.json";
const EMPTY_RESPONSE: &str = "search_empty.json";
const LIMIT_INVALID_RESPONSE: &str = "search_limit_invalid.json";

fn search_dir() -> PathBuf {
    api_v1_dir().join("search")
}

fn compat_dir() -> PathBuf {
    api_v1_dir().join("compat")
}

fn search_path(vault: &str, query: &str) -> String {
    format!("/vaults/{vault}/api/v1/search{query}")
}

// ---------------------------------------------------------------- vectors

/// The unit vector on `axis`.
fn e(axis: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIM];
    v[axis] = 1.0;
    v
}

/// A unit vector with cosine `s` to `e(axis)`, the rest on `e(side)`.
fn near(axis: usize, side: usize, s: f32) -> Vec<f32> {
    assert_ne!(axis, side);
    let mut v = vec![0.0; DIM];
    v[axis] = s;
    v[side] = (1.0 - s * s).sqrt();
    v
}

fn le_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

/// The vector of every seed note's chunk (each seed note has one chunk).
fn seed_vectors() -> Vec<(&'static str, Vec<f32>)> {
    vec![
        (LOOSE, e(0)),
        (BROKEN, near(0, 1, 0.9)),
        (DAY_15, near(0, 2, 0.8)),
        (PLAYER_LOOP, e(3)),
        (ECONOMY, e(4)),
        (PACING, e(5)),
        (DAY_16, e(6)),
        (DAY_17, e(7)),
        (DAY_18, e(8)),
        (DAY_19, e(9)),
    ]
}

/// The vector of [`QUERY`]: a distinct cosine to every seed chunk (Pacing
/// Notes, which never says "prices", is the nearest), so the kNN order and
/// the fused order have no ties.
fn query_vec() -> Vec<f32> {
    let weights = [1.0, 2.0, 3.0, 6.0, 7.0, 10.0, 4.0, 9.0, 5.0, 8.0];
    let norm = weights.iter().map(|w: &f32| w * w).sum::<f32>().sqrt();
    let mut v = vec![0.0; DIM];
    for (axis, w) in weights.iter().enumerate() {
        v[axis] = w / norm;
    }
    v
}

/// Writes `v` as the vector of every chunk of `note`; returns how many.
fn embed_note(conn: &Connection, note: &str, v: &[f32]) -> usize {
    let mut stmt = conn
        .prepare("SELECT id FROM chunks WHERE note_id = ?")
        .unwrap();
    let ids = stmt
        .query_map([note], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    for id in &ids {
        conn.execute(
            "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
            params![id, le_bytes(v)],
        )
        .unwrap();
    }
    ids.len()
}

/// The committed seed under `root`, every chunk pre-embedded with
/// [`seed_vectors`], so the server's backfill has nothing to embed. Returns
/// the vault folder.
fn pre_embed_seed(root: &Path) -> PathBuf {
    let dir = std::path::absolute(materialize_seed(root)).unwrap();
    let vault = Vault::open(&dir).unwrap();
    let conn = vault.connection_ref();
    schema::ensure_vector_table(conn, DIM).unwrap();
    for (note, v) in seed_vectors() {
        assert!(
            embed_note(conn, note, &v) > 0,
            "seed note {note} has chunks"
        );
    }
    let counts = embedding_counts(conn).unwrap();
    assert_eq!(
        counts.chunks, counts.embedded,
        "every seed chunk is pre-embedded"
    );
    dir
}

// ---------------------------------------------------------------- embedders

/// An embedder that always fails: every batch is an `EmbedderInfer` error,
/// and the calls are counted.
#[derive(Default)]
struct NoCall {
    calls: AtomicUsize,
}

impl Embedder for NoCall {
    fn model_version(&self) -> &str {
        "no-call-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Err(MemexError::EmbedderInfer(format!(
            "NoCall was asked to embed {texts:?}"
        )))
    }
}

/// The embedder of the `on` rows: it knows only [`QUERY`].
fn query_table() -> TableEmbedder {
    TableEmbedder::new(DIM).with(QUERY, query_vec())
}

/// A working embedder, counting its batches: [`QUERY`] gets [`query_vec`]
/// and any other text (a blank query's load probe, say) gets `e(1)`.
struct CountingTable {
    calls: AtomicUsize,
}

impl CountingTable {
    fn new() -> Self {
        Self {
            calls: AtomicUsize::new(0),
        }
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl Embedder for CountingTable {
    fn model_version(&self) -> &str {
        "counting-table-v1"
    }

    fn dimension(&self) -> usize {
        DIM
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(texts
            .iter()
            .map(|t| if t == QUERY { query_vec() } else { e(1) })
            .collect())
    }
}

// ---------------------------------------------------------------- model cache

/// A local port that counts and drops every connection, for `HF_ENDPOINT`.
/// Any hf-hub request fails at once and is counted.
struct Tripwire {
    url: String,
    hits: Arc<AtomicUsize>,
}

impl Tripwire {
    fn start() -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        std::thread::spawn(move || {
            for s in listener.incoming() {
                h.fetch_add(1, Ordering::SeqCst);
                drop(s);
            }
        });
        Self { url, hits }
    }

    fn hits(&self) -> usize {
        self.hits.load(Ordering::SeqCst)
    }
}

/// Serializes the tests that read `HF_HOME` / `HF_ENDPOINT` (a blank query
/// asks `FastEmbedder::is_cached`, which reads `HF_HOME`), and fixes both
/// for the test: `HF_HOME` unset, `HF_ENDPOINT` at `hub` when given, else
/// unset. The old values come back on drop.
struct HfEnv {
    saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    _lock: tokio::sync::MutexGuard<'static, ()>,
}

static HF_ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

impl HfEnv {
    async fn set(hub: Option<&Tripwire>) -> Self {
        let lock = HF_ENV_LOCK.lock().await;
        let saved = ["HF_HOME", "HF_ENDPOINT"]
            .into_iter()
            .map(|k| (k, std::env::var_os(k)))
            .collect();
        std::env::remove_var("HF_HOME");
        match hub {
            Some(hub) => std::env::set_var("HF_ENDPOINT", &hub.url),
            None => std::env::remove_var("HF_ENDPOINT"),
        }
        Self { saved, _lock: lock }
    }
}

impl Drop for HfEnv {
    fn drop(&mut self) {
        for (k, v) in &self.saved {
            match v {
                Some(v) => std::env::set_var(k, v),
                None => std::env::remove_var(k),
            }
        }
    }
}

/// A complete, fake BGE-small-en-v1.5 cache under `cache` in hf-hub's layout
/// (`refs/main` -> a snapshot holding every file fastembed reads).
/// `FastEmbedder::is_cached` reads it as cached; loading it would fail on
/// the fake bytes, with no network access.
fn write_fake_cached_model(cache: &Path) {
    const COMMIT: &str = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a";
    let repo = cache.join("models--Xenova--bge-small-en-v1.5");
    for file in [
        "onnx/model.onnx",
        "tokenizer.json",
        "config.json",
        "special_tokens_map.json",
        "tokenizer_config.json",
    ] {
        let path = repo.join("snapshots").join(COMMIT).join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("fake {file}\n")).unwrap();
    }
    fs::create_dir_all(repo.join("refs")).unwrap();
    fs::write(repo.join("refs/main"), COMMIT).unwrap();
}

/// Every path under `dir`, relative and sorted.
fn tree(dir: &Path) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            out.push(path.strip_prefix(base).unwrap().display().to_string());
            if path.is_dir() {
                walk(base, &path, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

/// Opens the gate when dropped, so a failing test never leaves a blocking
/// thread parked inside `embed_batch`.
struct OpenOnDrop(Arc<GatedEmbedder>);

impl Drop for OpenOnDrop {
    fn drop(&mut self) {
        self.0.release();
    }
}

// ---------------------------------------------------------------- servers

/// `server::router()` on `127.0.0.1:0` over `root`, with `embedder` as the
/// shared embedder (`--with-embeddings`), or with embeddings off.
struct Srv {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl Srv {
    async fn start(root: TempDir, embedder: Option<Arc<dyn Embedder>>) -> Self {
        let mut config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN);
        if let Some(embedder) = embedder {
            config = config.with_embeddings(true).with_embedder(embedder);
        }
        let app = router(config);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self { root, addr, task }
    }

    /// A server with `embedder` over the pre-embedded seed.
    async fn seed_with(embedder: Arc<dyn Embedder>) -> Self {
        let root = tempfile::tempdir().unwrap();
        pre_embed_seed(root.path());
        Self::start(root, Some(embedder)).await
    }

    /// A server without embeddings over the plain seed.
    async fn seed_without_embeddings() -> Self {
        let root = tempfile::tempdir().unwrap();
        materialize_seed(root.path());
        Self::start(root, None).await
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }

    /// GET `path` with the token.
    async fn get(&self, path: &str) -> Reply {
        let req = client()
            .get(self.url(path))
            .header("authorization", format!("Bearer {TEST_TOKEN}"));
        Reply::read(req.send().await.expect("send request")).await
    }
}

impl Drop for Srv {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Replays one fixture request against the server at `addr`.
async fn exec(addr: SocketAddr, req: &FixtureRequest) -> FixtureResponse {
    let method = reqwest::Method::from_bytes(req.method.as_bytes()).unwrap();
    let mut builder = client().request(method, format!("http://{addr}{}", req.path));
    if !req
        .headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("authorization"))
    {
        builder = builder.header("authorization", format!("Bearer {TEST_TOKEN}"));
    }
    for (k, v) in &req.headers {
        builder = builder.header(k.as_str(), v.as_str());
    }
    if let Some(body) = &req.body {
        builder = builder
            .header("content-type", "application/json")
            .body(body.clone());
    }
    let resp = builder.send().await.expect("send fixture request");
    let status = resp.status().as_u16();
    let body = resp.bytes().await.expect("read body").to_vec();
    FixtureResponse { status, body }
}

// ---------------------------------------------------------------- temp vaults

/// Creates and indexes a note as the person; returns its id.
fn create(vault: &mut Vault, title: &str, body: &str) -> String {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: None,
        },
        Caller::Person,
    )
    .unwrap();
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note.id.as_str().to_string()
}

/// A vault `v` under a new root with ten short notes that say "lantern"
/// and one long note whose second chunk (at a byte offset above 0) says it.
/// Nothing is embedded.
fn lantern_root() -> TempDir {
    let root = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(root.path().join("v")).unwrap();
    for i in 0..10 {
        create(
            &mut vault,
            &format!("Lantern {i}"),
            &format!("The lantern number {i} burns."),
        );
    }
    let long = format!(
        "{}\n\nA brass lantern hangs past the long first part.",
        vec!["alpha"; 300].join(" ")
    );
    let id = create(&mut vault, "Long Lantern", &long);
    let offset: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT start_byte FROM chunks WHERE note_id = ? AND content LIKE '%brass lantern%'",
            [&id],
            |r| r.get(0),
        )
        .unwrap();
    assert!(offset > 0, "the long note's lantern chunk starts past 0");
    drop(vault);
    root
}

/// `note_search` on the vault at `<root>/v`, as the core answers it, in
/// JSON.
fn core_answer(root: &Path, q: &str, limit: usize) -> Value {
    let mut vault = Vault::open(root.join("v")).unwrap();
    let mut conn: &mut Connection = vault.connection_mut();
    let got = note_search(&mut conn, q, limit, SearchEmbedder::Off, 0).unwrap();
    serde_json::to_value(got).unwrap()
}

/// A vault `v` under a new root: `Lit` (embedded) and two notes whose
/// chunks have no vector yet, all three saying "lantern". Returns the root.
fn pending_root() -> TempDir {
    let root = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(root.path().join("v")).unwrap();
    let lit = create(&mut vault, "Lit", "A lit lantern.");
    create(&mut vault, "Dark One", "A dark lantern, not embedded.");
    create(
        &mut vault,
        "Dark Two",
        "Another dark lantern, not embedded.",
    );
    let conn = vault.connection_ref();
    schema::ensure_vector_table(conn, DIM).unwrap();
    assert_eq!(embed_note(conn, &lit, &e(0)), 1);
    let c = embedding_counts(conn).unwrap();
    assert_eq!((c.chunks, c.embedded), (3, 1));
    drop(vault);
    root
}

/// `(chunks, embedded)` of the vault at `<root>/v`, read beside the server.
fn counts_of(root: &Path) -> (i64, i64) {
    let conn = Connection::open(root.join("v").join("memex.db")).unwrap();
    let c = embedding_counts(&conn).unwrap();
    (c.chunks, c.embedded)
}

fn note_ids(v: &Value) -> Vec<String> {
    v["hits"]
        .as_array()
        .unwrap_or_else(|| panic!("no hits array: {v}"))
        .iter()
        .map(|h| h["note_id"].as_str().unwrap().to_string())
        .collect()
}

// ---------------------------------------------------------------- fixture text

/// The stored form of a JSON body: volatile values normalized, keys sorted,
/// pretty printed.
fn comparable(body: &str) -> String {
    let v: Value =
        serde_json::from_str(body).unwrap_or_else(|e| panic!("body is not JSON ({e}): {body:?}"));
    canonical_json(&normalize_volatile(&v))
}

fn fixture_text(dir: &Path, response: &str) -> String {
    let path = dir.join(response);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The `prices` keyword hits on the seed, as requirement 34 prints them.
fn seed_keyword_hits() -> Value {
    json!([
        {
            "note_id": DAY_17,
            "note_title": "2026-10-17",
            "note_role": "daily",
            "day": "2026-10-17",
            "chunk_id": "01M5DQAYZKVWVP01WR8GCXZ6KZ",
            "snippet": "Tuned the shop prices.\n\nThen undid half of it.",
            "start_byte": 0,
            "via": null,
            "note_updated_at": 1792535788530_i64
        },
        {
            "note_id": DAY_19,
            "note_title": "2026-10-19",
            "note_role": "daily",
            "day": "2026-10-19",
            "chunk_id": "01M5DQAYZG5BY1XHQ8EB1ZKK52",
            "snippet": "Sketched a crafting tree.\n\nPrices felt too low in town.",
            "start_byte": 0,
            "via": null,
            "note_updated_at": 1792535788528_i64
        },
        {
            "note_id": ECONOMY,
            "note_title": "Economy Design",
            "note_role": "topic",
            "day": null,
            "chunk_id": "01M5DQAYZFW5NANWNHESXCHD7R",
            "snippet": "Sketched a crafting tree.",
            "start_byte": 0,
            "via": "2026-10-19",
            "note_updated_at": 1792535788527_i64
        }
    ])
}

// ---------------------------------------------------------------- AC 1

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_answers_200_with_the_requirement_34_json_and_keyword_hits() {
    let srv = Srv::seed_without_embeddings().await;
    let reply = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=8"))
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.header("content-type"),
        Some("application/json"),
        "{}",
        reply.body
    );
    let v = reply.json();
    assert_eq!(
        v,
        json!({
            "query": "prices",
            "semantic": "embeddings_off",
            "hits": seed_keyword_hits(),
            "truncated": false
        })
    );
    // Exactly the frozen keys, at both levels (requirement 34).
    let mut top: Vec<&str> = v.as_object().unwrap().keys().map(|k| k.as_str()).collect();
    top.sort_unstable();
    assert_eq!(top, ["hits", "query", "semantic", "truncated"]);
    for hit in v["hits"].as_array().unwrap() {
        let mut keys: Vec<&str> = hit
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "chunk_id",
                "day",
                "note_id",
                "note_role",
                "note_title",
                "note_updated_at",
                "snippet",
                "start_byte",
                "via"
            ]
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_answers_what_core_note_search_answers_on_the_same_vault() {
    let root = lantern_root();
    let expected_8 = core_answer(root.path(), "lantern", 8);
    let expected_3 = core_answer(root.path(), "brass lantern", 3);
    assert!(
        expected_3["hits"][0]["start_byte"].as_u64().unwrap() > 0,
        "the long note hit starts past byte 0: {expected_3}"
    );
    let srv = Srv::start(root, None).await;

    let reply = srv.get(&search_path("v", "?q=lantern&limit=8")).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json(), expected_8);

    let reply = srv
        .get(&search_path("v", "?q=brass%20lantern&limit=3"))
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        expected_3,
        "a two-word query, url-encoded, keeps its start_byte"
    );
}

// ---------------------------------------------------------------- AC 2

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_without_embeddings_answers_keyword_hits_with_semantic_embeddings_off() {
    let srv = Srv::seed_without_embeddings().await;
    let reply = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=8"))
        .await;
    assert_eq!(
        reply.status, 200,
        "embeddings off is an answer, not the echoes 409: {}",
        reply.body
    );
    let v = reply.json();
    assert_eq!(v["semantic"], json!("embeddings_off"));
    assert_eq!(v["hits"], seed_keyword_hits());
    // A query with no keyword match is an empty answer, not an error.
    let none = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=zeppelin&limit=8"))
        .await;
    assert_eq!(none.status, 200, "{}", none.body);
    assert_eq!(
        none.json(),
        json!({"query": "zeppelin", "semantic": "embeddings_off", "hits": [], "truncated": false})
    );
    assert!(
        !model_cache_dir(srv.root.path()).exists(),
        "the route never fetches a model"
    );
}

// ---------------------------------------------------------------- AC 3

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_with_an_embedder_answers_semantic_on_and_runs_the_vector_arm() {
    let table = Arc::new(query_table());
    let srv = Srv::seed_with(table.clone()).await;
    let reply = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=8"))
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(v["semantic"], json!("on"), "{v}");
    let ids = note_ids(&v);
    assert!(
        ids.contains(&PACING.to_string()),
        "Pacing Notes never says prices; only the vector arm finds it: {ids:?}"
    );
    assert_eq!(
        table.calls(),
        1,
        "one batch: the query, and no pending chunk is embedded"
    );
    assert_eq!(
        comparable(&reply.body),
        comparable(&fixture_text(&search_dir(), ON_RESPONSE)),
        "the on answer is the search_on.json row"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_embeds_no_pending_chunk_with_pending_cap_0() {
    // The table knows only the query: a request that also embedded the two
    // pending chunks (pending_cap > 0) would fail on them and answer
    // "unavailable". The server's backfill fails on them too, so it never
    // writes a vector either.
    let root = pending_root();
    let table = TableEmbedder::new(DIM).with("lantern", e(0));
    let srv = Srv::start(root, Some(Arc::new(table))).await;

    let reply = srv.get(&search_path("v", "?q=lantern&limit=8")).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(
        v["semantic"],
        json!("on"),
        "the query alone was embedded: {v}"
    );
    assert_eq!(
        v["hits"].as_array().unwrap().len(),
        3,
        "all three lantern notes are keyword hits: {v}"
    );
    assert_eq!(
        counts_of(srv.root.path()),
        (3, 1),
        "the two pending chunks still have no vector"
    );
}

// ---------------------------------------------------------------- AC 4

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_with_a_failing_embedder_answers_200_keyword_hits_with_semantic_unavailable() {
    let embedder = Arc::new(NoCall::default());
    let srv = Srv::seed_with(embedder.clone()).await;
    let reply = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=8"))
        .await;
    assert_eq!(
        reply.status, 200,
        "an embedder failure is not echoes' 503: {}",
        reply.body
    );
    assert_eq!(
        reply.json(),
        json!({
            "query": "prices",
            "semantic": "unavailable",
            "hits": seed_keyword_hits(),
            "truncated": false
        })
    );
    assert_eq!(
        embedder.calls.load(Ordering::SeqCst),
        1,
        "only the query was offered to the embedder"
    );
}

// ---------------------------------------------------------------- AC 5

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_limit_0_and_21_answer_400_invalid_argument_and_1_and_20_are_served() {
    let srv = Srv::seed_without_embeddings().await;
    for (limit, message) in [
        ("0", "invalid limit: 0 (1 to 20)"),
        ("21", "invalid limit: 21 (1 to 20)"),
        ("-1", "invalid limit: -1 (1 to 20)"),
    ] {
        let reply = srv
            .get(&search_path(
                SEED_VAULT_NAME,
                &format!("?q=QUERYMARKlimit&limit={limit}"),
            ))
            .await;
        assert_eq!(reply.status, 400, "limit={limit}: {}", reply.body);
        assert_eq!(
            reply.json(),
            json!({"error": {"code": "invalid_argument", "message": message}}),
            "limit={limit}"
        );
        assert!(
            !reply.body.contains("QUERYMARK"),
            "the query text stays out of the error: {}",
            reply.body
        );
    }

    let one = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=1"))
        .await;
    assert_eq!(one.status, 200, "{}", one.body);
    let v = one.json();
    assert_eq!(note_ids(&v), vec![DAY_17.to_string()], "the best hit");
    assert_eq!(v["truncated"], json!(true), "more matched than limit=1");

    let twenty = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=20"))
        .await;
    assert_eq!(twenty.status, 200, "{}", twenty.body);
    assert_eq!(twenty.json()["hits"], seed_keyword_hits());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_rejects_a_non_numeric_limit_with_400_invalid_argument() {
    let srv = Srv::seed_without_embeddings().await;
    let reply = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=eight"))
        .await;
    assert_eq!(
        (reply.status, reply.c1_code()),
        (400, "invalid_argument".to_string()),
        "{}",
        reply.body
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_without_a_limit_answers_at_most_8_hits() {
    let srv = Srv::start(lantern_root(), None).await;
    let reply = srv.get(&search_path("v", "?q=lantern")).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let v = reply.json();
    assert_eq!(
        v["hits"].as_array().unwrap().len(),
        8,
        "the default limit is 8: {v}"
    );
    assert_eq!(v["truncated"], json!(true), "eleven notes matched");

    let nine = srv.get(&search_path("v", "?q=lantern&limit=9")).await;
    assert_eq!(nine.status, 200, "{}", nine.body);
    assert_eq!(nine.json()["hits"].as_array().unwrap().len(), 9);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_without_q_answers_200_with_no_hits() {
    let srv = Srv::seed_without_embeddings().await;
    for query in ["", "?limit=8", "?q=&limit=8"] {
        let reply = srv.get(&search_path(SEED_VAULT_NAME, query)).await;
        assert_eq!(reply.status, 200, "{query:?}: {}", reply.body);
        assert_eq!(
            reply.json(),
            json!({"query": "", "semantic": "embeddings_off", "hits": [], "truncated": false}),
            "{query:?}"
        );
    }
    let blank = srv
        .get(&search_path(SEED_VAULT_NAME, "?q=%20%20&limit=8"))
        .await;
    assert_eq!(blank.status, 200, "{}", blank.body);
    assert_eq!(blank.json()["hits"], json!([]), "a whitespace query");

    // With an embedder and no cached model, a blank query answers no hits
    // and never reaches the embedder (the model cannot load: unavailable).
    let _env = HfEnv::set(None).await;
    let embedder = Arc::new(NoCall::default());
    let on = Srv::seed_with(embedder.clone()).await;
    let reply = on.get(&search_path(SEED_VAULT_NAME, "?limit=8")).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(reply.json()["hits"], json!([]));
    assert_eq!(reply.json()["semantic"], json!("unavailable"));
    assert_eq!(embedder.calls.load(Ordering::SeqCst), 0);
}

/// Blank queries: a missing q, an empty q, a whitespace q (and the query
/// echoed back as given).
const BLANK_PATHS: [(&str, &str); 4] = [
    ("", ""),
    ("?limit=8", ""),
    ("?q=&limit=8", ""),
    ("?q=%20%09%20", " \t "),
];

fn blank_body(semantic: &str, query: &str) -> Value {
    json!({"query": query, "semantic": semantic, "hits": [], "truncated": false})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn blank_query_with_a_failing_embedder_and_a_cached_model_answers_200_unavailable() {
    let _env = HfEnv::set(None).await;
    let embedder = Arc::new(NoCall::default());
    let srv = Srv::seed_with(embedder.clone()).await;
    write_fake_cached_model(&model_cache_dir(srv.root.path()));

    for (i, (query, echoed)) in BLANK_PATHS.iter().enumerate() {
        let reply = srv.get(&search_path(SEED_VAULT_NAME, query)).await;
        assert_eq!(reply.status, 200, "{query:?}: {}", reply.body);
        assert_eq!(reply.json(), blank_body("unavailable", echoed), "{query:?}");
        assert_eq!(
            embedder.calls.load(Ordering::SeqCst),
            i + 1,
            "{query:?}: the model is cached, so the probe reaches the embedder once"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn blank_query_with_a_working_embedder_and_a_cached_model_answers_200_on() {
    let _env = HfEnv::set(None).await;
    let embedder = Arc::new(CountingTable::new());
    let srv = Srv::seed_with(embedder.clone()).await;
    write_fake_cached_model(&model_cache_dir(srv.root.path()));

    for (i, (query, echoed)) in BLANK_PATHS.iter().enumerate() {
        let reply = srv.get(&search_path(SEED_VAULT_NAME, query)).await;
        assert_eq!(reply.status, 200, "{query:?}: {}", reply.body);
        assert_eq!(reply.json(), blank_body("on", echoed), "{query:?}");
        assert_eq!(embedder.calls(), i + 1, "{query:?}: one probe per request");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn blank_query_with_a_working_embedder_but_no_cached_model_answers_unavailable_unprobed() {
    let _env = HfEnv::set(None).await;
    let embedder = Arc::new(CountingTable::new());
    let srv = Srv::seed_with(embedder.clone()).await;
    let cache = model_cache_dir(srv.root.path());
    assert!(!FastEmbedder::is_cached(&cache), "precondition: no model");

    for (query, echoed) in BLANK_PATHS {
        let reply = srv.get(&search_path(SEED_VAULT_NAME, query)).await;
        assert_eq!(reply.status, 200, "{query:?}: {}", reply.body);
        assert_eq!(reply.json(), blank_body("unavailable", echoed), "{query:?}");
    }
    assert_eq!(embedder.calls(), 0, "an uncached model is never asked");

    // A non-blank query is not guarded: it reaches the embedder as before.
    let reply = srv
        .get(&search_path(SEED_VAULT_NAME, &format!("?q={QUERY}")))
        .await;
    assert_eq!(reply.json()["semantic"], json!("on"), "{}", reply.body);
    assert_eq!(embedder.calls(), 1, "the query vector was computed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn blank_query_on_a_server_with_the_real_embedder_and_no_model_never_touches_the_network() {
    let hub = Tripwire::start();
    let _env = HfEnv::set(Some(&hub)).await;
    let root = tempfile::tempdir().unwrap();
    pre_embed_seed(root.path());
    let cache = model_cache_dir(root.path());
    fs::create_dir_all(&cache).unwrap();
    assert!(!FastEmbedder::is_cached(&cache), "precondition: no model");
    let real: Arc<dyn Embedder> = Arc::new(FastEmbedder::bge_small_en_v15(Some(cache.clone())));
    let srv = Srv::start(root, Some(real)).await;
    let before = tree(&cache);

    for (query, echoed) in BLANK_PATHS {
        let reply = srv.get(&search_path(SEED_VAULT_NAME, query)).await;
        assert_eq!(reply.status, 200, "{query:?}: {}", reply.body);
        assert_eq!(reply.json(), blank_body("unavailable", echoed), "{query:?}");
    }
    assert_eq!(hub.hits(), 0, "nothing contacted HF_ENDPOINT");
    assert_eq!(tree(&cache), before, "no model file was created");
}

// ---------------------------------------------------------------- AC 6

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn another_request_on_the_vault_completes_while_the_search_query_embedding_is_held() {
    // Every seed chunk has a vector, so the query is the only inference:
    // neither the request nor the backfill embeds anything else.
    let gate = Arc::new(GatedEmbedder::new(query_table()));
    let _open_gate = OpenOnDrop(gate.clone());
    let srv = Arc::new(Srv::seed_with(gate.clone()).await);

    let search_srv = srv.clone();
    let path = search_path(SEED_VAULT_NAME, "?q=prices&limit=8");
    let mut search = tokio::spawn(async move { search_srv.get(&path).await });

    let probe = gate.clone();
    let entered = tokio::task::spawn_blocking(move || probe.wait_entered());
    tokio::select! {
        r = &mut search => {
            let r = r.unwrap();
            panic!(
                "the search answered before reaching the embedder: {} {}",
                r.status, r.body
            );
        }
        waited = tokio::time::timeout(WAIT, entered) => {
            match waited {
                Ok(Ok(true)) => {}
                other => panic!("the query embedding never reached embed_batch: {other:?}"),
            }
        }
    }

    // The vault lock is free while the query is inside the embedder.
    let note = tokio::time::timeout(
        Duration::from_secs(10),
        srv.get(&format!("{SEED}/notes/{PLAYER_LOOP}")),
    )
    .await
    .expect("GET …/notes/{id} completed while the query embedding was held");
    assert_eq!(note.status, 200, "{}", note.body);
    assert_eq!(note.json()["note_id"], json!(PLAYER_LOOP));
    assert_eq!(gate.calls(), 1, "the query embedding is still held");
    assert!(!search.is_finished(), "the search is still waiting");

    gate.release();
    let reply = tokio::time::timeout(WAIT, search)
        .await
        .expect("the search finished after release")
        .unwrap();
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        comparable(&reply.body),
        comparable(&fixture_text(&search_dir(), ON_RESPONSE))
    );
}

// ---------------------------------------------------------------- AC 7

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_starts_with_the_search_route_and_keeps_the_existing_routes() {
    // The nested api router builds on its own (an axum path clash panics here).
    let _ = memex_mcp::server::api::router();
    for embedder in [None, Some(Arc::new(query_table()) as Arc<dyn Embedder>)] {
        let srv = match embedder {
            None => Srv::seed_without_embeddings().await,
            Some(e) => Srv::seed_with(e).await,
        };
        let search = srv
            .get(&search_path(SEED_VAULT_NAME, "?q=prices&limit=8"))
            .await;
        assert_eq!(search.status, 200, "{}", search.body);
        // Released clients' routes still answer as before.
        let notes = srv.get(&format!("{SEED}/notes?limit=3")).await;
        assert_eq!(notes.status, 200, "{}", notes.body);
        assert_eq!(
            comparable(&notes.body),
            comparable(&fixture_text(
                &api_v1_dir().join("notes"),
                "list_notes_limit_3.json"
            ))
        );
        let note = srv.get(&format!("{SEED}/notes/{PLAYER_LOOP}")).await;
        assert_eq!(note.status, 200, "{}", note.body);
        // Only GET is served on /search, with the C1 405 elsewhere.
        assert_wrong_method_is_c1_405_at(
            srv.addr,
            &format!("Bearer {TEST_TOKEN}"),
            &[(&search_path(SEED_VAULT_NAME, "?q=prices"), &["GET"])],
        )
        .await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn search_route_answers_401_unauthorized_without_the_access_token() {
    let srv = Srv::seed_without_embeddings().await;
    let path = search_path(SEED_VAULT_NAME, "?q=prices&limit=8");
    let reply = Reply::read(client().get(srv.url(&path)).send().await.unwrap()).await;
    assert_eq!(
        (reply.status, reply.c1_code()),
        (401, "unauthorized".to_string()),
        "{}",
        reply.body
    );
    let ok = srv.get(&path).await;
    assert_eq!(ok.status, 200, "with the token: {}", ok.body);
}

#[tokio::test]
async fn search_query_text_stays_out_of_the_server_log() {
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let token = "search-log-token-7c1e5a9d3b2f4e6a8c0d";
    let mut child = ServeCommand::new(&[
        "--root",
        root.path().to_str().unwrap(),
        "--listen",
        ANY_PORT,
        "--log-level",
        "debug",
    ])
    .env(TOKEN_ENV, token)
    .spawn();
    let addr = child.ready().await;
    let bearer = format!("Bearer {token}");
    let base = format!("http://{addr}");

    let hit = server::get(
        &format!("{base}{SEED}/search?q=QUERYMARKprices&limit=8"),
        Some(&bearer),
    )
    .await;
    assert_eq!(hit.status, 200, "{}", hit.body);
    assert_eq!(hit.json()["query"], json!("QUERYMARKprices"));
    let bad = server::get(
        &format!("{base}{SEED}/search?q=QUERYMARKbad&limit=0"),
        Some(&bearer),
    )
    .await;
    assert_eq!(bad.status, 400, "{}", bad.body);

    let logs = wait_for_logs(root.path(), |logs| {
        logs.lines()
            .filter(|l| l.contains(&format!("{SEED}/search")))
            .count()
            >= 2
    })
    .await;
    assert!(
        !logs.contains("QUERYMARK") && !logs.contains("/search?"),
        "the query text is never logged:\n{logs}"
    );
    let stderr = child.stderr();
    assert!(
        !stderr.contains("QUERYMARK"),
        "nor printed on stderr:\n{stderr}"
    );
    drop(child);
}

// ---------------------------------------------------------------- AC 8

#[test]
fn search_index_registers_the_six_search_rows() {
    let rows = load_rows(&search_dir()).expect("search/index.json parses");
    let got: Vec<(&str, &str, &str, u16, bool)> = rows
        .iter()
        .map(|r| {
            (
                r.method.as_str(),
                r.path.as_str(),
                r.response.as_str(),
                r.status,
                r.dart_only,
            )
        })
        .collect();
    assert_eq!(
        got,
        vec![
            (
                "GET",
                "/vaults/seed/api/v1/search?q=prices&limit=8",
                OFF_RESPONSE,
                200,
                false
            ),
            (
                "GET",
                "/vaults/seed/api/v1/search?q=prices&limit=8",
                ON_RESPONSE,
                200,
                false
            ),
            (
                "GET",
                "/vaults/seed/api/v1/search?q=prices&limit=8",
                UNAVAILABLE_RESPONSE,
                200,
                false
            ),
            (
                "GET",
                "/vaults/seed/api/v1/search?q=prices&limit=1",
                TRUNCATED_RESPONSE,
                200,
                false
            ),
            (
                "GET",
                "/vaults/seed/api/v1/search?limit=8",
                EMPTY_RESPONSE,
                200,
                false
            ),
            (
                "GET",
                "/vaults/seed/api/v1/search?q=prices&limit=0",
                LIMIT_INVALID_RESPONSE,
                400,
                false
            ),
        ]
    );
}

#[test]
fn search_fixtures_are_what_core_note_search_answers_on_the_seed() {
    // Guards the fixture files, not the route: each is the core answer on
    // the seed for its row (under MEMEX_BLESS=1 it is rewritten from it).
    let plain = tempfile::tempdir().unwrap();
    let plain_dir = std::path::absolute(materialize_seed(plain.path())).unwrap();
    let embedded = tempfile::tempdir().unwrap();
    let embedded_dir = pre_embed_seed(embedded.path());
    let table = query_table();
    let failing = NoCall::default();

    let answer = |dir: &Path, q: &str, limit: usize, embedder: SearchEmbedder<'_>| -> Value {
        let mut vault = Vault::open(dir).unwrap();
        let mut conn: &mut Connection = vault.connection_mut();
        serde_json::to_value(note_search(&mut conn, q, limit, embedder, 0).unwrap()).unwrap()
    };
    let cases = [
        (
            OFF_RESPONSE,
            answer(&plain_dir, QUERY, 8, SearchEmbedder::Off),
        ),
        (
            ON_RESPONSE,
            answer(&embedded_dir, QUERY, 8, SearchEmbedder::Ready(&table)),
        ),
        (
            UNAVAILABLE_RESPONSE,
            answer(&embedded_dir, QUERY, 8, SearchEmbedder::Ready(&failing)),
        ),
        (
            TRUNCATED_RESPONSE,
            answer(&plain_dir, QUERY, 1, SearchEmbedder::Off),
        ),
        (
            EMPTY_RESPONSE,
            answer(&plain_dir, "", 8, SearchEmbedder::Off),
        ),
        (
            LIMIT_INVALID_RESPONSE,
            json!({"error": {"code": "invalid_argument", "message": "invalid limit: 0 (1 to 20)"}}),
        ),
    ];
    assert_eq!(cases[1].1["semantic"], json!("on"));
    assert_eq!(cases[2].1["semantic"], json!("unavailable"));
    assert_eq!(cases[3].1["truncated"], json!(true));
    for (file, value) in cases {
        let want = canonical_json(&normalize_volatile(&value));
        if bless_requested() {
            std::fs::write(search_dir().join(file), &want).unwrap();
            continue;
        }
        assert_eq!(
            fixture_text(&search_dir(), file),
            want,
            "{file} is the core answer on the seed"
        );
    }
}

#[test]
fn search_fixture_rows_match_the_full_router_on_the_seed() {
    let rows = load_rows(&search_dir()).expect("search/index.json parses");
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every search row runs in Rust"
    );
    // run_rows calls the executor once per row, in row order.
    let responses: Vec<String> = rows.iter().map(|r| r.response.clone()).collect();

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let off = rt.block_on(Srv::seed_without_embeddings());
    let on = rt.block_on(Srv::seed_with(Arc::new(query_table())));
    let unavailable = rt.block_on(Srv::seed_with(Arc::new(NoCall::default())));
    let mut i = 0;
    let result = run_rows(&search_dir(), bless_requested(), |req| {
        let addr = match responses[i].as_str() {
            ON_RESPONSE => on.addr,
            UNAVAILABLE_RESPONSE => unavailable.addr,
            _ => off.addr,
        };
        i += 1;
        rt.block_on(exec(addr, req))
    });
    assert_eq!(i, responses.len(), "every row ran");
    drop(off);
    drop(on);
    drop(unavailable);
    result.unwrap_or_else(|e| panic!("{e}"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn compat_search_not_found_is_the_older_server_body_and_the_route_now_serves_its_path() {
    let rows = load_rows(&compat_dir()).expect("compat/index.json parses");
    let row = rows
        .iter()
        .find(|r| r.response == "search_not_found.json")
        .expect("compat/index.json has the search row");
    assert_eq!(
        (
            row.method.as_str(),
            row.path.as_str(),
            row.status,
            row.dart_only
        ),
        (
            "GET",
            "/vaults/seed/api/v1/search?q=prices&limit=8",
            404,
            true
        )
    );
    let fixture: Value =
        serde_json::from_str(&fixture_text(&compat_dir(), "search_not_found.json")).unwrap();
    let expected = json!({"error": {"code": "not_found", "message": NO_ROUTE_MESSAGE}});
    assert_eq!(fixture, expected);
    assert_eq!(
        fixture_text(&compat_dir(), "search_not_found.json"),
        fixture_text(&compat_dir(), "backup_not_found.json"),
        "byte-shaped like the other not-found fixtures"
    );

    let srv = Srv::seed_without_embeddings().await;
    // A server without the route answers the fallback body for any path it
    // does not serve; the fallback does not depend on the path.
    let unrouted = srv
        .get(&search_path(
            SEED_VAULT_NAME,
            "-zz-no-such-route?q=prices&limit=8",
        ))
        .await;
    assert_eq!(
        (unrouted.status, unrouted.json()),
        (404, fixture.clone()),
        "search_not_found.json is what an older router answers"
    );
    // This server has the route: the compat row path is served.
    let served = srv.get(&row.path).await;
    assert_eq!(served.status, 200, "{}", served.body);
    assert_ne!(served.json(), fixture);
}
