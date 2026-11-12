//! WI #423 (Spec #391 requirement 19, rulings D20, D21a): the vault server's
//! `GET /vaults/{name}/api/v1/notes/{note_id}/echoes?limit=<n>`.
//!
//! - It answers `memex echoes`' JSON (`{echoes, reason, pending}`) from V2's
//!   `echoes()` with `others_cap` 0; `limit` is 1-20 (400
//!   `invalid_argument` otherwise).
//! - It needs the access token, like every `/api/v1` route.
//! - Without an embedder (`--with-embeddings` off) it is `409
//!   embeddings_off`; a missing note is `404 not_found` whose message is not
//!   the no-route body (`not found: no route for this path`, D21a);
//!   inference errors are `503 embedder_unavailable`.
//! - `echoes()` runs on a blocking thread through V3's `VaultLease`, so the
//!   vault lock is never held across inference.
//!
//! The wire fixtures are the `echoes*.json` rows of
//! `app/test/fixtures/api_v1/notes/index.json`. They are `dart_only` for the
//! generic notes runner, because the 200, 404 and 400 rows need a server
//! with an embedder over a seed whose chunks are pre-embedded: this file
//! runs them. The vectors (384-d, single-block chunks) are written in this
//! file's own setup; the shared `seed_vault.sql` is untouched. Every server
//! here is the full `server::router()` (D20). No test runs the real model,
//! and no wait is on the wall clock: the concurrency test gates the
//! embedder, and timeouts are hang guards only.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use memex_core::echoes::echoes;
use memex_core::embedder::{Embedder, GatedEmbedder, TableEmbedder};
use memex_core::indexer;
use memex_core::notes::{create_note_as, CreateNote};
use memex_core::schema;
use memex_core::vectors::embedding_counts;
use memex_core::{Caller, MemexError, Vault};
use memex_mcp::server::{router, ServerConfig};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{
    api_v1_dir, canonical_json, load_rows, materialize_seed, normalize_volatile, FixtureRow,
    SEED_VAULT_NAME,
};
use server::{client, Reply, TEST_TOKEN, WAIT};

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
/// A valid ULID no seed note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

/// Main's unknown-route message (D21a); a missing note must not say this.
const NO_ROUTE_MESSAGE: &str = "not found: no route for this path";

fn notes_dir() -> PathBuf {
    api_v1_dir().join("notes")
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

/// The vector of every seed note's chunks. Loose Thought is the open note
/// (axis 0). Broken Frontmatter (0.9, role-less) and 2026-10-15 (0.8,
/// daily) are its echoes, both single-block chunks; every other note is
/// orthogonal to it.
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

/// The committed seed under `root`, with every chunk pre-embedded with
/// [`seed_vectors`]. Returns the vault folder.
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

/// An embedder that must never be called: every batch is an
/// `EmbedderInfer` error, and the calls are counted.
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
    _root: TempDir,
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
        Self {
            _root: root,
            addr,
            task,
        }
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

    /// GET `path` without any token.
    async fn get_without_token(&self, path: &str) -> Reply {
        Reply::read(client().get(self.url(path)).send().await.expect("send")).await
    }
}

impl Drop for Srv {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn echoes_path(vault: &str, note: &str, limit: &str) -> String {
    format!("/vaults/{vault}/api/v1/notes/{note}/echoes?limit={limit}")
}

// ---------------------------------------------------------------- fixture rows

/// The notes/index.json row answering with `response`; it is an echoes row.
fn row(response: &str) -> FixtureRow {
    let rows = load_rows(&notes_dir()).expect("notes/index.json parses");
    let matching: Vec<FixtureRow> = rows
        .into_iter()
        .filter(|r| r.response == response)
        .collect();
    assert_eq!(
        matching.len(),
        1,
        "notes/index.json has exactly one row answering {response}"
    );
    let row = matching.into_iter().next().unwrap();
    assert_eq!(row.method, "GET", "{response}");
    assert!(
        row.path.starts_with(&format!("{SEED}/notes/")) && row.path.contains("/echoes?limit="),
        "{response} is an echoes row: {}",
        row.path
    );
    row
}

/// The stored form of a JSON body: volatile values normalized, keys sorted,
/// pretty printed.
fn comparable(body: &str) -> String {
    let v: Value =
        serde_json::from_str(body).unwrap_or_else(|e| panic!("body is not JSON ({e}): {body:?}"));
    canonical_json(&normalize_volatile(&v))
}

fn fixture_text(response: &str) -> String {
    let path = notes_dir().join(response);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// Replays `row` on `srv` and asserts its status and response file.
async fn assert_row(srv: &Srv, row: &FixtureRow) -> Reply {
    let reply = srv.get(&row.path).await;
    assert_eq!(
        reply.status, row.status,
        "GET {}: status; body {}",
        row.path, reply.body
    );
    assert_eq!(
        comparable(&reply.body),
        comparable(&fixture_text(&row.response)),
        "GET {} matches {}",
        row.path,
        row.response
    );
    reply
}

#[test]
fn notes_index_registers_the_four_echoes_rows() {
    // Guards the fixture rows themselves (D21: compat/ is not touched).
    let rows = load_rows(&notes_dir()).expect("notes/index.json parses");
    let mut echoes: Vec<(String, u16, bool)> = rows
        .iter()
        .filter(|r| r.path.contains("/echoes"))
        .map(|r| (r.response.clone(), r.status, r.dart_only))
        .collect();
    echoes.sort();
    assert_eq!(
        echoes,
        vec![
            ("echoes.json".to_string(), 200, true),
            ("echoes_embeddings_off.json".to_string(), 409, true),
            ("echoes_limit_invalid.json".to_string(), 400, true),
            ("echoes_not_found.json".to_string(), 404, true),
        ]
    );
}

#[test]
fn wi423_echoes_fixture_is_what_core_echoes_answers_on_the_pre_embedded_seed() {
    // Guards the 200 fixture, not the route: it is the core result for
    // Loose Thought on the pre-embedded seed, with no embedding at all.
    let root = tempfile::tempdir().unwrap();
    let dir = pre_embed_seed(root.path());
    let mut vault = Vault::open(&dir).unwrap();
    let embedder = TableEmbedder::new(DIM);
    let mut conn: &mut Connection = vault.connection_mut();
    let got = echoes(&mut conn, &embedder, LOOSE, 8, 0).unwrap();
    assert_eq!(embedder.calls(), 0, "no model is needed");
    assert_eq!(
        comparable(&serde_json::to_string(&got).unwrap()),
        comparable(&fixture_text("echoes.json"))
    );
}

// ---------------------------------------------------------------- AC 8

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_200_matches_notes_echoes_json() {
    let embedder = Arc::new(NoCall::default());
    let srv = Srv::seed_with(embedder.clone()).await;
    let row = row("echoes.json");
    assert_eq!(row.path, echoes_path(SEED_VAULT_NAME, LOOSE, "8"));
    let reply = assert_row(&srv, &row).await;
    assert_eq!(
        reply.header("content-type"),
        Some("application/json"),
        "{}",
        reply.body
    );
    assert_eq!(
        embedder.calls.load(Ordering::SeqCst),
        0,
        "a pre-embedded single-block read loads no model"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_404_for_a_missing_note_matches_echoes_not_found_json_and_is_not_the_no_route_body() {
    let srv = Srv::seed_with(Arc::new(NoCall::default())).await;
    let row = row("echoes_not_found.json");
    assert_eq!(row.path, echoes_path(SEED_VAULT_NAME, UNKNOWN, "8"));
    let reply = assert_row(&srv, &row).await;
    let v = reply.json();
    assert_eq!(v["error"]["code"], json!("not_found"));
    assert_ne!(
        v["error"]["message"],
        json!(NO_ROUTE_MESSAGE),
        "a missing note is told apart from an older server (D21a)"
    );
    assert_eq!(
        v["error"]["message"],
        json!(format!("not found: note {UNKNOWN}"))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_409_embeddings_off_on_a_server_without_embeddings_matches_its_fixture() {
    let srv = Srv::seed_without_embeddings().await;
    let row = row("echoes_embeddings_off.json");
    assert_row(&srv, &row).await;
    // The open note of the 200 row is off too: no embedder, no echoes.
    let reply = srv.get(&echoes_path(SEED_VAULT_NAME, LOOSE, "8")).await;
    assert_eq!(
        (reply.status, reply.c1_code()),
        (409, "embeddings_off".to_string()),
        "{}",
        reply.body
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_limit_0_and_21_are_400_invalid_argument_and_1_and_20_are_served() {
    let srv = Srv::seed_with(Arc::new(NoCall::default())).await;
    let row = row("echoes_limit_invalid.json");
    assert_eq!(row.path, echoes_path(SEED_VAULT_NAME, LOOSE, "0"));
    assert_row(&srv, &row).await;

    let over = srv.get(&echoes_path(SEED_VAULT_NAME, LOOSE, "21")).await;
    assert_eq!(over.status, 400, "{}", over.body);
    assert_eq!(
        over.json(),
        json!({"error": {"code": "invalid_argument", "message": "invalid limit: 21 (1 to 20)"}})
    );

    let one = srv.get(&echoes_path(SEED_VAULT_NAME, LOOSE, "1")).await;
    assert_eq!(one.status, 200, "{}", one.body);
    let ids: Vec<Value> = one.json()["echoes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["note_id"].clone())
        .collect();
    assert_eq!(ids, vec![json!(BROKEN)], "limit=1 keeps the best echo");

    let twenty = srv.get(&echoes_path(SEED_VAULT_NAME, LOOSE, "20")).await;
    assert_eq!(twenty.status, 200, "{}", twenty.body);
    assert_eq!(
        comparable(&twenty.body),
        comparable(&fixture_text("echoes.json")),
        "limit=20 is served: both echoes"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_without_a_limit_is_400_invalid_argument_like_the_other_list_reads() {
    let srv = Srv::seed_with(Arc::new(NoCall::default())).await;
    let path = format!("/vaults/{SEED_VAULT_NAME}/api/v1/notes/{LOOSE}/echoes");
    let reply = srv.get(&path).await;
    assert_eq!(
        (reply.status, reply.c1_code()),
        (400, "invalid_argument".to_string()),
        "{}",
        reply.body
    );
}

// ---------------------------------------------------------------- AC 9

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_answers_401_unauthorized_without_the_access_token() {
    let srv = Srv::seed_with(Arc::new(NoCall::default())).await;
    let path = echoes_path(SEED_VAULT_NAME, LOOSE, "8");
    let reply = srv.get_without_token(&path).await;
    assert_eq!(
        (reply.status, reply.c1_code()),
        (401, "unauthorized".to_string()),
        "{}",
        reply.body
    );
    let wrong = Reply::read(
        client()
            .get(srv.url(&path))
            .header("authorization", "Bearer not-the-token")
            .send()
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(wrong.status, 401, "{}", wrong.body);
    // The same request with the token is served by the route.
    let ok = srv.get(&path).await;
    assert_eq!(ok.status, 200, "with the token: {}", ok.body);
}

// ---------------------------------------------------------------- AC 10

/// A vault `v` under a new root: `Open` (one chunk, axis 0) and `Multi`, one
/// chunk of two blocks scoring 0.9, all pre-embedded. Returns the root and
/// the two note ids.
fn multi_block_root() -> (TempDir, String, String) {
    let root = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(root.path().join("v")).unwrap();
    let mut create = |title: &str, body: &str| -> String {
        let note = create_note_as(
            &mut vault,
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
    };
    let open = create("Open", "The open passage.");
    let multi = create("Multi", "First block text.\n\nSecond block text.");
    let conn = vault.connection_ref();
    schema::ensure_vector_table(conn, DIM).unwrap();
    assert_eq!(embed_note(conn, &open, &e(0)), 1);
    assert_eq!(embed_note(conn, &multi, &near(0, 1, 0.9)), 1, "one chunk");
    drop(vault);
    (root, open, multi)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn another_request_on_the_vault_completes_while_the_routes_echoes_is_inside_the_embedder() {
    let (root, open, multi) = multi_block_root();
    // The best-block batch is the read's only inference: every chunk has a
    // vector, so neither the read's embed_missing nor the backfill embeds.
    let table = TableEmbedder::new(DIM)
        .with("First block text.", e(1))
        .with("Second block text.", e(0));
    let gate = Arc::new(GatedEmbedder::new(table));
    let _open_gate = OpenOnDrop(gate.clone());
    let srv = Arc::new(Srv::start(root, Some(gate.clone())).await);

    let echo_srv = srv.clone();
    let echo_path = echoes_path("v", &open, "8");
    let mut echo = tokio::spawn(async move { echo_srv.get(&echo_path).await });

    let probe = gate.clone();
    let entered = tokio::task::spawn_blocking(move || probe.wait_entered());
    tokio::select! {
        r = &mut echo => {
            let r = r.unwrap();
            panic!(
                "the echoes request answered before reaching the embedder: {} {}",
                r.status, r.body
            );
        }
        waited = tokio::time::timeout(WAIT, entered) => {
            match waited {
                Ok(Ok(true)) => {}
                other => panic!("no echoes batch reached embed_batch: {other:?}"),
            }
        }
    }

    // The vault lock is free while echoes() is inside the embedder.
    let note = tokio::time::timeout(
        Duration::from_secs(10),
        srv.get(&format!("/vaults/v/api/v1/notes/{multi}")),
    )
    .await
    .expect("GET …/notes/{id} completed while the echoes batch was held");
    assert_eq!(note.status, 200, "{}", note.body);
    assert_eq!(note.json()["note_id"], json!(multi));
    assert_eq!(gate.calls(), 1, "the echoes batch is still held");
    assert!(!echo.is_finished(), "the echoes request is still waiting");

    gate.release();
    let reply = tokio::time::timeout(WAIT, echo)
        .await
        .expect("the echoes request finished after release")
        .unwrap();
    assert_eq!(reply.status, 200, "{}", reply.body);
    let body = "First block text.\n\nSecond block text.";
    assert_eq!(
        reply.json()["echoes"],
        json!([{
            "note_id": multi,
            "note_title": "Multi",
            "note_role": null,
            "day": null,
            "passage": "Second block text.",
            "start_byte": body.find("Second").unwrap(),
            "note_updated_at": reply.json()["echoes"][0]["note_updated_at"].clone(),
        }])
    );
}

// ---------------------------------------------------------------- others_cap 0 and 503

/// A vault `v` under a new root whose open note has one unembedded chunk,
/// next to three other notes with unembedded chunks. Returns the root, the
/// open note id and the open note's chunk text.
fn unembedded_root() -> (TempDir, String, String) {
    let root = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(root.path().join("v")).unwrap();
    let mut create = |title: &str, body: &str| -> String {
        let note = create_note_as(
            &mut vault,
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
    };
    let text = "The open passage, not embedded yet.";
    let open = create("Open", text);
    for i in 0..3 {
        create(&format!("Other {i}"), &format!("Other passage {i}."));
    }
    let c = embedding_counts(vault.connection_ref()).unwrap();
    assert_eq!((c.chunks, c.embedded), (4, 0));
    drop(vault);
    (root, open, text.to_string())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_embeds_only_the_open_notes_chunks_with_others_cap_0() {
    // The table knows only the open note's text: a read that also picked
    // other notes' chunks (others_cap > 0) would fail on them. The server's
    // backfill batches always include the others, so it never writes.
    let (root, open, text) = unembedded_root();
    let table = TableEmbedder::new(DIM).with(text, e(0));
    let srv = Srv::start(root, Some(Arc::new(table))).await;

    let reply = srv.get(&echoes_path("v", &open, "8")).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    assert_eq!(
        reply.json(),
        json!({"echoes": [], "reason": null, "pending": 3}),
        "the others are left to the backfill"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn route_inference_error_is_503_embedder_unavailable_with_the_cause() {
    let (root, open, _) = unembedded_root();
    let srv = Srv::start(root, Some(Arc::new(NoCall::default()))).await;

    let reply = srv.get(&echoes_path("v", &open, "8")).await;
    assert_eq!(
        (reply.status, reply.c1_code()),
        (503, "embedder_unavailable".to_string()),
        "{}",
        reply.body
    );
    let message = reply.json()["error"]["message"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        message.starts_with("embedder inference failed: ") && message.contains("NoCall"),
        "the cause is in the message: {message}"
    );
}
