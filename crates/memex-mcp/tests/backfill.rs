//! #422 (Spec #391 req 6 and 7): the background embedding backfill of
//! `memex serve --with-embeddings`, on stdio and on the vault server.
//!
//! - AC 1: stdio embeds every unembedded chunk in batches of at most 64 and
//!   `pending` reaches 0 (`backfill::spawn_stdio`; the binary test proves
//!   `serve --vault --with-embeddings` starts it).
//! - AC 2: a vault the server opens after start is backfilled with no
//!   further request, whether it opened before or after the task started.
//! - AC 3, AC 4: with a `GatedEmbedder` holding a batch, a vault-server API
//!   request and an MCP tool call on the same vault complete before the
//!   embedder is released (`backfill::VaultLease` holds the vault lock only
//!   inside each lease call).
//! - AC 5: two open vaults are both backfilled, in alternating batches.
//! - AC 6: without an embedder no task starts and no vector is written.
//! - AC 7: the backfill does not move `content_revision.n` (the
//!   `GET …/revision` arm belongs to RV #419 AC 1, lead ruling 2026-11-11).
//! - AC 8: an embedder error is logged and stops that vault's pass; the
//!   server and the stdio session keep serving.
//! - Ruling D48: every backfill `embed_batch` call gets at most
//!   [`BACKFILL_EMBED_SUB_BATCH`] (8) texts, so a lease cycle of 64 chunks is
//!   up to 8 calls. [`Batches::sizes`], [`Batches::tags`] and
//!   [`Batches::of`] speak of lease cycles (see [`Batches::cycles`]);
//!   [`Batches::call_sizes`] speaks of calls.
//!
//! No test runs the real model: embedders are `FakeEmbedder` wrappers and
//! `GatedEmbedder`; the binary test points `HF_ENDPOINT` at a dead port.
//! Waits are on the gate's entered signal or a bounded poll of 10 ms steps
//! (never a fixed sleep), each capped at [`WAIT`].

#[path = "support/server.rs"]
mod server;

use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use memex_core::embedder::{Embedder, FakeEmbedder, GatedEmbedder};
use memex_core::notes::{create_note, CreateNote};
use memex_core::vectors::{
    embed_missing, embedding_counts, ConnLease, EmbedMissing, EmbeddingCounts,
};
use memex_core::{MemexError, Vault};
use memex_mcp::backfill::{
    spawn_server, spawn_stdio, SubBatchEmbedder, VaultLease, BACKFILL_EMBED_SUB_BATCH,
};
use memex_mcp::server::registry::Registry;
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use server::{free_port, get, Reply, TEST_TOKEN, WAIT};

/// Vector width of every test embedder.
const DIM: usize = 8;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The text of chunk `i` of the vault tagged `tag`. The tag is the first
/// word, so a recorded batch names its vault.
fn passage(tag: &str, i: usize) -> String {
    format!("{tag} passage {i}")
}

/// Creates a vault at `dir` holding exactly `n` unembedded chunks (texts
/// [`passage`]`(tag, i)`), all in one note, and closes it. Returns the note
/// id.
fn seed(dir: &Path, tag: &str, n: usize) -> String {
    let mut vault = Vault::create(dir).unwrap_or_else(|e| panic!("create {}: {e}", dir.display()));
    let note = create_note(
        &mut vault,
        CreateNote {
            title: Some(format!("{tag} note")),
            content_md: String::new(),
            ..Default::default()
        },
    )
    .expect("create the seed note");
    let id = note.id.as_str().to_string();
    let conn = vault.connection_ref();
    conn.execute("DELETE FROM chunks", []).unwrap();
    for i in 0..n {
        let content = passage(tag, i);
        conn.execute(
            "INSERT INTO chunks
                (id, note_id, ord, content, token_count, embed_model_version,
                 start_byte, end_byte)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                format!("01K{i:023}"),
                id,
                i as i64,
                content,
                3,
                None::<String>,
                0,
                content.len() as i64
            ],
        )
        .unwrap();
    }
    id
}

/// A read-only connection to the vault at `dir` (sqlite-vec is registered
/// process-wide by the fixture's `Vault::create`).
fn read_db(dir: &Path) -> Connection {
    let conn = Connection::open_with_flags(dir.join("memex.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap_or_else(|e| panic!("open {}: {e}", dir.display()));
    conn.busy_timeout(Duration::from_secs(5)).unwrap();
    conn
}

fn counts(dir: &Path) -> EmbeddingCounts {
    embedding_counts(&read_db(dir)).expect("embedding_counts")
}

/// Whether every chunk of the vault at `dir` has a vector.
fn fully_embedded(dir: &Path, n: usize) -> bool {
    let c = counts(dir);
    c.chunks == n as i64 && c.embedded == n as i64
}

fn has_chunk_vec(dir: &Path) -> bool {
    read_db(dir)
        .query_row(
            "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'chunk_vec')",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

fn revision_n(dir: &Path) -> i64 {
    read_db(dir)
        .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
            r.get(0)
        })
        .expect("content_revision row")
}

/// The stdio state for the vault at `dir`.
fn state(dir: &Path, embedder: Option<Arc<dyn Embedder>>) -> AppState {
    let vault = Vault::open(dir).unwrap_or_else(|e| panic!("open {}: {e}", dir.display()));
    AppState::new(vault, dir.to_path_buf(), embedder)
}

// ---------------------------------------------------------------------------
// Embedders
// ---------------------------------------------------------------------------

/// Every `embed_batch` call an embedder saw, in call order.
#[derive(Clone, Default)]
struct Batches(Arc<Mutex<Vec<Vec<String>>>>);

/// One lease cycle of a backfill pass: up to 64 chunks of one vault, embedded
/// in calls of at most 8 texts.
#[derive(Debug, PartialEq, Eq)]
struct Cycle {
    tag: String,
    texts: usize,
}

impl Batches {
    fn all(&self) -> Vec<Vec<String>> {
        self.0.lock().unwrap().clone()
    }

    /// The text count of each `embed_batch` call.
    fn call_sizes(&self) -> Vec<usize> {
        self.all().iter().map(Vec::len).collect()
    }

    /// The vault tag of each call, asserting no call mixes vaults.
    fn call_tags(&self) -> Vec<String> {
        self.all()
            .iter()
            .map(|batch| {
                let tag = batch[0].split(' ').next().unwrap().to_string();
                assert!(
                    batch.iter().all(|t| t.starts_with(&format!("{tag} "))),
                    "one call embeds one vault's chunks: {batch:?}"
                );
                tag
            })
            .collect()
    }

    /// The calls grouped into lease cycles. A cycle is the run of calls of
    /// one vault up to 64 texts, or up to the first call of fewer than 8
    /// texts (the last call of a cycle that picked fewer than 64 chunks).
    /// Every call is asserted to hold at most
    /// [`BACKFILL_EMBED_SUB_BATCH`] texts (ruling D48).
    fn cycles(&self) -> Vec<Cycle> {
        let calls = self.all();
        let tags = self.call_tags();
        let mut cycles: Vec<Cycle> = Vec::new();
        let mut open = false;
        for (call, tag) in calls.iter().zip(tags) {
            assert!(
                call.len() <= BACKFILL_EMBED_SUB_BATCH,
                "no backfill embed_batch call gets more than {BACKFILL_EMBED_SUB_BATCH} texts: {} in {:?}",
                call.len(),
                self.call_sizes()
            );
            match cycles.last_mut() {
                Some(c) if open && c.tag == tag => c.texts += call.len(),
                _ => cycles.push(Cycle {
                    tag,
                    texts: call.len(),
                }),
            }
            let last = cycles.last().unwrap();
            open = last.texts < 64 && call.len() == BACKFILL_EMBED_SUB_BATCH;
        }
        cycles
    }

    /// The text count of each lease cycle.
    fn sizes(&self) -> Vec<usize> {
        self.cycles().iter().map(|c| c.texts).collect()
    }

    /// The vault tag of each lease cycle.
    fn tags(&self) -> Vec<String> {
        self.cycles().into_iter().map(|c| c.tag).collect()
    }

    /// How many lease cycles worked the vault tagged `tag`.
    fn of(&self, tag: &str) -> usize {
        self.cycles().iter().filter(|c| c.tag == tag).count()
    }
}

/// A `FakeEmbedder` that records every batch and, with `fail_on`, answers
/// any batch holding a text of that vault tag with an `EmbedderInfer` error
/// carrying `token`.
struct Recording {
    inner: FakeEmbedder,
    batches: Batches,
    fail_on: Option<(String, String)>,
}

impl Recording {
    fn new(batches: &Batches) -> Self {
        Self {
            inner: FakeEmbedder::new(DIM),
            batches: batches.clone(),
            fail_on: None,
        }
    }

    fn failing_on(batches: &Batches, tag: &str, token: &str) -> Self {
        Self {
            fail_on: Some((format!("{tag} "), token.to_string())),
            ..Self::new(batches)
        }
    }
}

impl Embedder for Recording {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        self.batches.0.lock().unwrap().push(texts.to_vec());
        if let Some((prefix, token)) = &self.fail_on {
            if texts.iter().any(|t| t.starts_with(prefix.as_str())) {
                return Err(MemexError::EmbedderInfer(token.clone()));
            }
        }
        self.inner.embed_batch(texts)
    }
}

/// A gated [`Recording`]: the batch log only grows once the gate opens.
fn gated(batches: &Batches) -> Arc<GatedEmbedder> {
    Arc::new(GatedEmbedder::new(Recording::new(batches)))
}

/// Opens the gate when dropped, so a failing test never leaves a blocking
/// thread parked inside `embed_batch` (the runtime would wait for it).
struct OpenOnDrop(Arc<GatedEmbedder>);

impl Drop for OpenOnDrop {
    fn drop(&mut self) {
        self.0.release();
    }
}

/// Waits (on the gate's own signal, capped at [`WAIT`]) until a batch is
/// held inside `embed_batch`.
async fn wait_entered(gate: &Arc<GatedEmbedder>, what: &str) {
    let probe = gate.clone();
    let waiting = tokio::task::spawn_blocking(move || probe.wait_entered());
    match tokio::time::timeout(WAIT, waiting).await {
        Ok(Ok(true)) => {}
        Ok(Ok(false)) => panic!("{what}: the gate opened with no batch held"),
        Ok(Err(e)) => panic!("{what}: the gate waiter failed: {e}"),
        Err(_) => {
            gate.release();
            panic!("{what}: no backfill batch reached embed_batch within {WAIT:?}");
        }
    }
}

/// Polls `done` every 10 ms until it holds; fails after [`WAIT`].
async fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < WAIT, "{what} within {WAIT:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Awaits a backfill task, capped at [`WAIT`]; it must end without a panic.
async fn finished(task: JoinHandle<()>, what: &str) {
    match tokio::time::timeout(WAIT, task).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => panic!("{what}: the backfill task failed: {e}"),
        Err(_) => panic!("{what}: the backfill task did not end within {WAIT:?}"),
    }
}

// ---------------------------------------------------------------------------
// Log capture (the backfill logs from its own task and threads, so the
// recorder is the process-wide subscriber)
// ---------------------------------------------------------------------------

static EVENTS: Mutex<Vec<(tracing::Level, String)>> = Mutex::new(Vec::new());

struct Recorder;

struct Fields(String);

impl tracing::field::Visit for Fields {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        self.0.push_str(&format!(" {}={value:?}", field.name()));
    }
}

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for Recorder {
    fn on_event(&self, event: &tracing::Event<'_>, _: tracing_subscriber::layer::Context<'_, S>) {
        let mut fields = Fields(String::new());
        event.record(&mut fields);
        EVENTS
            .lock()
            .unwrap()
            .push((*event.metadata().level(), fields.0));
    }
}

fn install_log() {
    use tracing_subscriber::layer::SubscriberExt;
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let subscriber = tracing_subscriber::registry()
            .with(tracing_subscriber::filter::LevelFilter::WARN)
            .with(Recorder);
        tracing::subscriber::set_global_default(subscriber)
            .expect("no other subscriber in this test binary");
    });
}

/// Whether a WARN or ERROR event carrying `token` was logged.
fn logged(token: &str) -> bool {
    EVENTS.lock().unwrap().iter().any(|(level, text)| {
        (*level == tracing::Level::WARN || *level == tracing::Level::ERROR) && text.contains(token)
    })
}

// ---------------------------------------------------------------------------
// The vault server in-process
// ---------------------------------------------------------------------------

/// `server::router()` on `127.0.0.1:0` over `root`, with `embedder` as the
/// shared embedder (embeddings off when `None`).
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

    fn vault(&self, name: &str) -> PathBuf {
        self.root.path().join(name)
    }

    async fn get(&self, path: &str) -> Reply {
        get(
            &format!("http://{}{path}", self.addr),
            Some(&format!("Bearer {TEST_TOKEN}")),
        )
        .await
    }

    /// GET `path`, asserting a 200, within `limit`.
    async fn get_ok_within(&self, path: &str, limit: Duration) -> Value {
        let reply = tokio::time::timeout(limit, self.get(path))
            .await
            .unwrap_or_else(|_| panic!("GET {path} did not complete within {limit:?}"));
        assert_eq!(reply.status, 200, "GET {path}: {}", reply.body);
        reply.json()
    }

    async fn get_ok(&self, path: &str) -> Value {
        self.get_ok_within(path, WAIT).await
    }

    /// Opens the vault `name` with a request.
    async fn open(&self, name: &str) {
        self.get_ok(&format!("/vaults/{name}/api/v1/info")).await;
    }
}

impl Drop for Srv {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A vault root holding `vaults` (name, chunk count), each seeded with
/// [`seed`]. Returns the root and the seed note ids in order.
fn root_with(vaults: &[(&str, usize)]) -> (TempDir, Vec<String>) {
    let root = tempfile::tempdir().unwrap();
    let ids = vaults
        .iter()
        .map(|(name, n)| seed(&root.path().join(name), name, *n))
        .collect();
    (root, ids)
}

// ---------------------------------------------------------------------------
// MCP tool call in-process
// ---------------------------------------------------------------------------

async fn get_note_tool(memex: &Memex, note_id: &str) -> Value {
    let params =
        Parameters(serde_json::from_value(json!({ "note_id": note_id })).expect("get_note params"));
    let text = memex.get_note(params).await;
    let v: Value =
        serde_json::from_str(&text).unwrap_or_else(|e| panic!("get_note non-JSON ({e}): {text}"));
    assert!(v.get("error").is_none(), "get_note errored: {v}");
    assert_eq!(
        v["note_id"],
        json!(note_id),
        "get_note answered the note: {v}"
    );
    v
}

// ---------------------------------------------------------------------------
// AC 1: stdio backfills every chunk in batches of at most 64
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_embeds_every_chunk_in_batches_of_at_most_64() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 150);
    let batches = Batches::default();
    let st = state(&vault, Some(Arc::new(Recording::new(&batches))));

    let task = spawn_stdio(&st).expect("spawn_stdio starts a task when there is an embedder");
    finished(task, "stdio backfill").await;

    assert_eq!(
        counts(&vault),
        EmbeddingCounts {
            chunks: 150,
            embedded: 150
        },
        "every chunk has a vector: pending reached 0"
    );
    assert_eq!(
        batches.sizes(),
        vec![64, 64, 22],
        "lease cycles of 64 (embed_missing(None, 0, 64)) until pending is 0"
    );
    // Ruling D48: each cycle embeds in calls of at most 8 texts.
    let mut calls = vec![8; 8];
    calls.extend([8; 8]);
    calls.extend([8, 8, 6]);
    assert_eq!(
        batches.call_sizes(),
        calls,
        "calls of 8, the last of a cycle short"
    );
}

// ---------------------------------------------------------------------------
// AC 2: a vault opened by a request after start is backfilled
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfills_a_vault_a_request_opens_after_start() {
    let (root, _) = root_with(&[("alpha", 100)]);
    let batches = Batches::default();
    let srv = Srv::start(root, Some(Arc::new(Recording::new(&batches)))).await;

    srv.open("alpha").await;

    // No further request: the backfill alone fills the vault.
    let alpha = srv.vault("alpha");
    wait_until("alpha fully embedded after one request", || {
        fully_embedded(&alpha, 100)
    })
    .await;
    assert_eq!(batches.sizes(), vec![64, 36], "cycles of at most 64");
    assert!(
        batches.call_sizes().iter().all(|&n| n <= 8),
        "calls of at most 8: {:?}",
        batches.call_sizes()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_covers_vaults_opened_before_and_after_it_starts() {
    let (root, _) = root_with(&[("alpha", 70), ("beta", 30)]);
    let batches = Batches::default();
    let registry = Arc::new(Registry::new(
        root.path().to_path_buf(),
        Some(Arc::new(Recording::new(&batches))),
    ));

    // Opened before the task starts: its first pass covers it.
    registry.get("alpha").await.expect("open alpha");
    let task = spawn_server(registry.clone())
        .expect("spawn_server starts a task when the registry has an embedder");
    let alpha = root.path().join("alpha");
    wait_until("alpha (open before the task) fully embedded", || {
        fully_embedded(&alpha, 70)
    })
    .await;

    // Opened after the task went idle: the open signal wakes it.
    registry.get("beta").await.expect("open beta");
    let beta = root.path().join("beta");
    wait_until("beta (opened later) fully embedded", || {
        fully_embedded(&beta, 30)
    })
    .await;
    task.abort();
}

// ---------------------------------------------------------------------------
// AC 3: a vault-server request completes while a batch is held
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_request_completes_while_a_backfill_batch_is_held() {
    let (root, ids) = root_with(&[("alpha", 100)]);
    let batches = Batches::default();
    let gate = gated(&batches);
    let _open = OpenOnDrop(gate.clone());
    let srv = Srv::start(root, Some(gate.clone())).await;

    srv.open("alpha").await;
    wait_entered(&gate, "alpha's first batch").await;

    // The note read takes the vault lock (`with_vault`).
    let note = srv
        .get_ok_within(
            &format!("/vaults/alpha/api/v1/notes/{}", ids[0]),
            Duration::from_secs(10),
        )
        .await;
    assert_eq!(note["note_id"], json!(ids[0]), "the read answered: {note}");
    assert!(
        batches.all().is_empty() && gate.calls() == 1,
        "the request completed while the batch was still held"
    );

    gate.release();
    let alpha = srv.vault("alpha");
    wait_until("alpha fully embedded after release", || {
        fully_embedded(&alpha, 100)
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn vault_lease_holds_the_vault_lock_only_inside_each_lease_call() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 70);
    let st = state(&vault, None);

    // Inside a lease call the vault lock is held, on the vault's connection.
    let probe = st.vault.clone();
    let lock = st.vault.clone();
    let (locked, chunks) = tokio::task::spawn_blocking(move || {
        let mut lease = VaultLease::new(lock);
        lease.lease(|conn| {
            let chunks: i64 = conn.query_row("SELECT COUNT(*) FROM chunks", [], |r| r.get(0))?;
            Ok((probe.try_lock().is_err(), chunks))
        })
    })
    .await
    .unwrap()
    .expect("a lease call runs its closure");
    assert!(locked, "the vault lock is held inside a lease call");
    assert_eq!(chunks, 70, "the closure gets the vault's connection");
    assert!(
        st.vault.try_lock().is_ok(),
        "the vault lock is released when the lease call returns"
    );

    // Across inference no lease is held: the lock is free while a batch
    // waits inside embed_batch.
    let batches = Batches::default();
    let gate = gated(&batches);
    let _open = OpenOnDrop(gate.clone());
    let lock = st.vault.clone();
    let embedder = gate.clone();
    let run = tokio::task::spawn_blocking(move || {
        let mut lease = VaultLease::new(lock);
        let out = embed_missing(&mut lease, &*embedder, None, 0, 64);
        embedder.release();
        out
    });
    wait_entered(&gate, "embed_missing through a VaultLease").await;
    assert!(
        st.vault.try_lock().is_ok(),
        "the vault lock is free while the batch is inside embed_batch"
    );
    gate.release();
    let out = run.await.unwrap().expect("embed_missing through the lease");
    assert_eq!(
        out,
        EmbedMissing {
            embedded: 64,
            pending: 6
        }
    );
}

// ---------------------------------------------------------------------------
// AC 4: an MCP tool call completes while a stdio batch is held
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_tool_call_completes_while_a_backfill_batch_is_held() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    let note_id = seed(&vault, "alpha", 100);
    let batches = Batches::default();
    let gate = gated(&batches);
    let _open = OpenOnDrop(gate.clone());
    let st = state(&vault, Some(gate.clone()));
    let memex = Memex::new(Arc::new(st.clone()));

    let task = spawn_stdio(&st).expect("spawn_stdio starts a task when there is an embedder");
    wait_entered(&gate, "the stdio backfill's first batch").await;

    // get_note takes the vault lock.
    tokio::time::timeout(Duration::from_secs(10), get_note_tool(&memex, &note_id))
        .await
        .expect("get_note completed while the batch was held");
    assert!(
        batches.all().is_empty() && gate.calls() == 1,
        "the tool call completed while the batch was still held"
    );

    gate.release();
    finished(task, "stdio backfill after release").await;
    assert!(fully_embedded(&vault, 100), "{:?}", counts(&vault));
}

// ---------------------------------------------------------------------------
// AC 5: two open vaults are backfilled in alternating batches
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_open_vaults_are_backfilled_in_alternating_batches() {
    // alpha needs 5 batches, beta 2.
    let (root, _) = root_with(&[("alpha", 320), ("beta", 100)]);
    let batches = Batches::default();
    let gate = gated(&batches);
    let _open = OpenOnDrop(gate.clone());
    let srv = Srv::start(root, Some(gate.clone())).await;

    srv.open("alpha").await;
    wait_entered(&gate, "alpha's first batch").await;
    // beta opens while alpha's first batch is held: the open itself never
    // waits on the backfill.
    srv.open("beta").await;
    gate.release();

    let (alpha, beta) = (srv.vault("alpha"), srv.vault("beta"));
    wait_until("both vaults fully embedded", || {
        fully_embedded(&alpha, 320) && fully_embedded(&beta, 100)
    })
    .await;

    let tags = batches.tags();
    assert!(
        batches.sizes().iter().all(|&n| n <= 64),
        "{:?}",
        batches.sizes()
    );
    assert_eq!(batches.of("alpha"), 5, "{tags:?}");
    assert_eq!(batches.of("beta"), 2, "{tags:?}");
    let first_beta = tags.iter().position(|t| t == "beta").unwrap();
    let last_alpha = tags.iter().rposition(|t| t == "alpha").unwrap();
    assert!(
        first_beta < last_alpha,
        "beta did not wait for alpha's whole backlog: {tags:?}"
    );
    // Once both have work, a vault runs two batches in a row only when the
    // other has none left.
    for i in first_beta..tags.len() - 1 {
        if tags[i] == tags[i + 1] {
            assert!(
                tags[i + 1..].iter().all(|t| *t == tags[i]),
                "batches alternate while both vaults have work: {tags:?}"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// AC 6: without embeddings, no task and no vector
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_without_an_embedder_starts_no_backfill_task() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 10);

    let off = state(&vault, None);
    assert!(
        spawn_stdio(&off).is_none(),
        "no backfill task without an embedder"
    );
    drop(off);
    assert!(!has_chunk_vec(&vault), "no vector table, so no vector");

    // Control: the same vault with an embedder does get a task and vectors.
    let batches = Batches::default();
    let on = state(&vault, Some(Arc::new(Recording::new(&batches))));
    let task = spawn_stdio(&on).expect("a task once there is an embedder");
    finished(task, "stdio backfill (control)").await;
    assert!(fully_embedded(&vault, 10), "{:?}", counts(&vault));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_without_embeddings_starts_no_backfill_and_writes_no_vector() {
    let (off_root, _) = root_with(&[("alpha", 10)]);
    let (on_root, _) = root_with(&[("alpha", 10)]);

    assert!(
        spawn_server(Arc::new(Registry::new(off_root.path().to_path_buf(), None))).is_none(),
        "no backfill task for a registry without an embedder"
    );
    let batches = Batches::default();
    let control = spawn_server(Arc::new(Registry::new(
        on_root.path().to_path_buf(),
        Some(Arc::new(Recording::new(&batches))),
    )))
    .expect("a task for a registry with an embedder");
    control.abort();

    // Two servers side by side; the one with embeddings is the clock for
    // "a backfill would have run by now".
    let off = Srv::start(off_root, None).await;
    let on = Srv::start(on_root, Some(Arc::new(Recording::new(&batches)))).await;
    off.open("alpha").await;
    on.open("alpha").await;
    let on_alpha = on.vault("alpha");
    wait_until("the server with embeddings backfilled alpha", || {
        fully_embedded(&on_alpha, 10)
    })
    .await;

    let off_alpha = off.vault("alpha");
    assert!(
        !has_chunk_vec(&off_alpha),
        "no vector table, so no vector, without --with-embeddings"
    );
    assert!(
        !off.root.path().join(".memex").join("models").exists()
            && !off_alpha.join(".memex").join("models").exists(),
        "no model cache without --with-embeddings"
    );
}

// ---------------------------------------------------------------------------
// AC 7: the backfill does not move content_revision.n
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn backfill_does_not_move_content_revision() {
    // stdio
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 100);
    let st = state(&vault, Some(Arc::new(FakeEmbedder::new(DIM))));
    let before = revision_n(&vault);
    finished(spawn_stdio(&st).expect("a stdio task"), "stdio backfill").await;
    assert!(fully_embedded(&vault, 100), "{:?}", counts(&vault));
    assert_eq!(revision_n(&vault), before, "stdio: content_revision.n");

    // vault server
    let (root, _) = root_with(&[("alpha", 100)]);
    let batches = Batches::default();
    let gate = gated(&batches);
    let _open = OpenOnDrop(gate.clone());
    let srv = Srv::start(root, Some(gate.clone())).await;
    srv.open("alpha").await;
    wait_entered(&gate, "alpha's first batch").await;
    let alpha = srv.vault("alpha");
    let before = revision_n(&alpha);
    gate.release();
    wait_until("alpha fully embedded", || fully_embedded(&alpha, 100)).await;
    assert_eq!(revision_n(&alpha), before, "server: content_revision.n");
}

// ---------------------------------------------------------------------------
// AC 8: an embedder error is logged and stops that vault's pass
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_logs_an_embedder_error_and_stops_that_vaults_pass() {
    install_log();
    let token = "wi422-server-embedder-down-7c1f";
    let (root, ids) = root_with(&[("alpha", 100), ("beta", 100)]);
    let batches = Batches::default();
    let srv = Srv::start(
        root,
        Some(Arc::new(Recording::failing_on(&batches, "alpha", token))),
    )
    .await;

    srv.open("alpha").await;
    wait_until("the alpha batch error is logged at WARN or ERROR", || {
        logged(token)
    })
    .await;

    // The server keeps serving, alpha included.
    srv.get_ok(&format!("/vaults/alpha/api/v1/notes/{}", ids[0]))
        .await;
    // The task keeps working: a vault opened later is backfilled.
    srv.open("beta").await;
    let beta = srv.vault("beta");
    wait_until("beta fully embedded after alpha's error", || {
        fully_embedded(&beta, 100)
    })
    .await;

    let alpha = srv.vault("alpha");
    assert_eq!(
        counts(&alpha).embedded,
        0,
        "alpha's failed batch wrote nothing"
    );
    assert_eq!(
        batches.of("alpha"),
        1,
        "alpha's pass stopped at its first error instead of retrying: {:?}",
        batches.tags()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_logs_an_embedder_error_and_ends_without_panicking() {
    install_log();
    let token = "wi422-stdio-embedder-down-3a9e";
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    let note_id = seed(&vault, "alpha", 100);
    let batches = Batches::default();
    let st = state(
        &vault,
        Some(Arc::new(Recording::failing_on(&batches, "alpha", token))),
    );
    let memex = Memex::new(Arc::new(st.clone()));

    let task = spawn_stdio(&st).expect("spawn_stdio starts a task when there is an embedder");
    finished(task, "stdio backfill with a failing embedder").await;

    assert!(
        logged(token),
        "the embedder error is logged at WARN or ERROR"
    );
    assert_eq!(
        batches.all().len(),
        1,
        "the pass stopped at the first error"
    );
    assert_eq!(counts(&vault).embedded, 0, "the failed batch wrote nothing");
    // The session keeps serving.
    get_note_tool(&memex, &note_id).await;
}

// ---------------------------------------------------------------------------
// The binary: `memex serve --vault … --with-embeddings` starts the backfill
// ---------------------------------------------------------------------------

/// `memex serve --vault <vault> --with-embeddings` over newline-delimited
/// JSON-RPC, with the model hub at a dead port.
struct StdioServe {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    next_id: i64,
}

impl StdioServe {
    fn start(vault: &Path, hub: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args([
                "serve",
                "--vault",
                vault.to_str().unwrap(),
                "--with-embeddings",
            ])
            .env("HF_ENDPOINT", hub)
            .env_remove("HF_HOME")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve --vault");
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut serve = Self {
            child,
            stdin,
            lines,
            next_id: 1,
        };
        let init = serve.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi422-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        serve.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        serve
    }

    fn send(&mut self, msg: Value) {
        let stdin = self.stdin.as_mut().expect("stdin open");
        writeln!(stdin, "{msg}").expect("write to memex serve");
        stdin.flush().unwrap();
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let line = self
                .lines
                .recv_timeout(WAIT)
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }

    /// `get_note`'s JSON payload, asserting it is the note.
    fn get_note(&mut self, note_id: &str) -> Value {
        let resp = self.request(
            "tools/call",
            json!({ "name": "get_note", "arguments": { "note_id": note_id } }),
        );
        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("get_note returned no text: {resp}"));
        let v: Value = serde_json::from_str(text).expect("get_note JSON");
        assert_eq!(v["note_id"], json!(note_id), "get_note answered: {v}");
        v
    }

    /// Closes stdin (EOF) and waits for the exit, polling every 10 ms.
    fn close_and_wait(&mut self, limit: Duration) -> Option<ExitStatus> {
        self.stdin.take();
        let started = Instant::now();
        while started.elapsed() < limit {
            if let Some(status) = self.child.try_wait().expect("try_wait") {
                return Some(status);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        None
    }
}

impl Drop for StdioServe {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Every `mcp.log*` file under `<vault>/.memex/`, concatenated.
fn mcp_logs(vault: &Path) -> String {
    let mut names: Vec<PathBuf> = std::fs::read_dir(vault.join(".memex"))
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with("mcp.log"))
                })
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
        .iter()
        .map(|p| std::fs::read_to_string(p).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n")
}

/// A WARN or ERROR line carrying the model-load failure.
fn has_backfill_error_line(logs: &str) -> bool {
    logs.lines().any(|line| {
        (line.contains("ERROR") || line.contains("WARN")) && line.contains("embedder init failed")
    })
}

#[test]
fn stdio_serve_with_embeddings_starts_the_backfill_and_logs_its_embedder_error() {
    let dir = tempfile::tempdir().unwrap();
    let vault = std::path::absolute(dir.path().join("v")).unwrap();
    let note_id = seed(&vault, "alpha", 10);
    // Nothing listens there: the model download is refused at once.
    let hub = format!("http://127.0.0.1:{}", free_port());

    let mut serve = StdioServe::start(&vault, &hub);
    serve.get_note(&note_id);

    // The backfill started on its own and logged the model-load failure.
    let started = Instant::now();
    while !has_backfill_error_line(&mcp_logs(&vault)) {
        assert!(
            started.elapsed() < WAIT,
            "no WARN/ERROR line with the backfill's embedder error in mcp.log:\n{}",
            mcp_logs(&vault)
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    // The session keeps serving, and EOF still ends the process.
    serve.get_note(&note_id);
    let status = serve
        .close_and_wait(WAIT)
        .expect("memex serve exited after stdin EOF");
    assert!(status.success(), "exit status {status:?}");
    assert_eq!(counts(&vault).embedded, 0, "no vector without a model");
}

// ---------------------------------------------------------------------------
// Verify round: pass-control contracts the implementer listed as unpinned
// (no-progress stop, panicking batch, no runtime, eviction, finished pass)
// ---------------------------------------------------------------------------

/// A step run inside `embed_batch` of the call it is scripted for.
type Hook = Box<dyn FnOnce(&[String]) + Send>;

/// A `FakeEmbedder` that records every batch and runs one [`Hook`] per call,
/// in call order (calls past the script answer normally).
struct Scripted {
    inner: FakeEmbedder,
    batches: Batches,
    hooks: Mutex<std::collections::VecDeque<Hook>>,
}

impl Scripted {
    fn new(batches: &Batches, hooks: Vec<Hook>) -> Arc<Self> {
        Arc::new(Self {
            inner: FakeEmbedder::new(DIM),
            batches: batches.clone(),
            hooks: Mutex::new(hooks.into()),
        })
    }
}

impl Embedder for Scripted {
    fn model_version(&self) -> &str {
        self.inner.model_version()
    }

    fn dimension(&self) -> usize {
        self.inner.dimension()
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        self.batches.0.lock().unwrap().push(texts.to_vec());
        let hook = self.hooks.lock().unwrap().pop_front();
        if let Some(hook) = hook {
            hook(texts);
        }
        self.inner.embed_batch(texts)
    }
}

/// A call that answers normally.
fn plain() -> Hook {
    Box::new(|_| {})
}

/// `n` hooks from `make`: one per call of a lease cycle (a cycle of 64
/// chunks is 8 calls of 8 texts).
fn times(n: usize, make: impl Fn() -> Hook) -> Vec<Hook> {
    (0..n).map(|_| make()).collect()
}

/// The hooks of `parts`, in order, as one script.
fn script<const N: usize>(parts: [Vec<Hook>; N]) -> Vec<Hook> {
    parts.into_iter().flatten().collect()
}

/// A call that panics inside `embed_batch`.
fn panics() -> Hook {
    Box::new(|_| panic!("wi422 scripted embedder panic"))
}

/// A read-write connection to the vault at `dir`, as a concurrent writer.
fn read_write(dir: &Path) -> Connection {
    let conn = Connection::open(dir.join("memex.db")).expect("open the vault for writing");
    conn.busy_timeout(Duration::from_secs(5)).unwrap();
    conn
}

/// A call that deletes the chunks it was handed from the vault at `dir`,
/// and with `replace` adds an unembedded copy of each, so the count of
/// unembedded chunks stays the same.
fn meddles(dir: &Path, replace: bool) -> Hook {
    let dir = dir.to_path_buf();
    Box::new(move |texts| {
        let conn = read_write(&dir);
        for text in texts {
            if replace {
                conn.execute(
                    "INSERT INTO chunks
                        (id, note_id, ord, content, token_count, embed_model_version,
                         start_byte, end_byte)
                     SELECT 'Z' || id, note_id, ord + 100000, content, token_count, NULL,
                            start_byte, end_byte
                       FROM chunks WHERE content = ?1 AND id NOT LIKE 'Z%'",
                    [text],
                )
                .expect("copy the picked chunk");
            }
            conn.execute(
                "DELETE FROM chunks WHERE content = ?1 AND id NOT LIKE 'Z%'",
                [text],
            )
            .expect("delete the picked chunk");
        }
    })
}

/// A call that tells the test it is inside `embed_batch`, then waits for
/// the test's release (a dropped sender releases it too).
fn holds(entered: tokio::sync::mpsc::UnboundedSender<()>, release: mpsc::Receiver<()>) -> Hook {
    Box::new(move |_| {
        let _ = entered.send(());
        let _ = release.recv();
    })
}

/// Waits for the next held call, capped at [`WAIT`].
async fn held(entered: &mut tokio::sync::mpsc::UnboundedReceiver<()>, what: &str) {
    match tokio::time::timeout(WAIT, entered.recv()).await {
        Ok(Some(())) => {}
        other => panic!("{what}: no call reached embed_batch within {WAIT:?} ({other:?})"),
    }
}

/// Whether a `level` event carrying every one of `tokens` was logged.
fn logged_at(level: tracing::Level, tokens: &[&str]) -> bool {
    EVENTS
        .lock()
        .unwrap()
        .iter()
        .any(|(l, text)| *l == level && tokens.iter().all(|t| text.contains(t)))
}

/// The unique last component of a temp dir: part of every path logged for a
/// vault inside it.
fn unique(dir: &TempDir) -> String {
    dir.path()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_stops_a_pass_whose_batch_makes_no_progress() {
    install_log();
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 100);
    let batches = Batches::default();
    // Cycle 1 (calls 1-8) answers normally. Cycle 2 (calls 9-13: its 36
    // chunks in calls of 8, 8, 8, 8, 4) swaps every chunk it is handed for
    // an unembedded copy: it writes no vector and leaves `pending` where
    // it was.
    let embedder = Scripted::new(
        &batches,
        script([times(8, plain), times(5, || meddles(&vault, true))]),
    );
    let st = state(&vault, Some(embedder));

    let task = spawn_stdio(&st).expect("a stdio task");
    finished(task, "stdio backfill").await;

    assert_eq!(
        batches.sizes(),
        vec![64, 36],
        "the pass stopped after the cycle that made no progress instead of spinning on"
    );
    assert_eq!(
        batches.call_sizes(),
        [vec![8; 8], vec![8, 8, 8, 8, 4]].concat(),
        "no cycle 3 started"
    );
    assert_eq!(
        counts(&vault),
        EmbeddingCounts {
            chunks: 100,
            embedded: 64
        },
        "the swapped-in copies stay unembedded"
    );
    assert!(
        logged_at(tracing::Level::WARN, &["made no progress", &unique(&dir)]),
        "the stop is logged at WARN: {:?}",
        EVENTS.lock().unwrap()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_goes_on_while_batches_lose_their_chunks_and_pending_drops() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 200);
    let batches = Batches::default();
    // Cycles 1 and 2 (calls 1-16) find their chunks deleted before the
    // insert: no vector is written (`embedded` 0) but `pending` falls, 136
    // then 72.
    let embedder = Scripted::new(&batches, times(16, || meddles(&vault, false)));
    let st = state(&vault, Some(embedder));

    let task = spawn_stdio(&st).expect("a stdio task");
    finished(task, "stdio backfill").await;

    assert_eq!(
        batches.sizes(),
        vec![64, 64, 64, 8],
        "a batch that wrote nothing still counts as progress while chunks are left to do"
    );
    assert_eq!(
        batches.call_sizes().len(),
        8 + 8 + 8 + 1,
        "calls of 8: three cycles of 64 and one of 8"
    );
    assert_eq!(
        counts(&vault),
        EmbeddingCounts {
            chunks: 72,
            embedded: 72
        },
        "the 72 chunks nobody deleted all have a vector"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_logs_an_error_and_ends_when_a_batch_panics() {
    install_log();
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 100);
    let batches = Batches::default();
    let st = state(&vault, Some(Scripted::new(&batches, vec![panics()])));

    let task = spawn_stdio(&st).expect("a stdio task");
    finished(task, "stdio backfill whose first batch panics").await;

    assert_eq!(
        batches.call_sizes(),
        vec![8],
        "the panic ended the batch at its first call; no retry after it"
    );
    assert_eq!(
        counts(&vault).embedded,
        0,
        "the panicked batch wrote nothing"
    );
    assert!(
        logged_at(tracing::Level::ERROR, &["did not finish", &unique(&dir)]),
        "the panic is logged at ERROR: {:?}",
        EVENTS.lock().unwrap()
    );
    // The vault lock was not left held by the panic.
    assert!(st.vault.try_lock().is_ok(), "the vault lock is free");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_survives_a_panicking_batch_and_backfills_the_next_vault() {
    install_log();
    let (root, _) = root_with(&[("alpha", 100), ("beta", 100)]);
    let batches = Batches::default();
    let registry = Arc::new(Registry::new(
        root.path().to_path_buf(),
        Some(Scripted::new(&batches, vec![panics()])),
    ));
    let task = spawn_server(registry.clone()).expect("a server task");

    registry.get("alpha").await.expect("open alpha");
    wait_until("alpha's panicked batch is logged at ERROR", || {
        logged_at(tracing::Level::ERROR, &["did not finish", &unique(&root)])
    })
    .await;

    registry.get("beta").await.expect("open beta");
    let beta = root.path().join("beta");
    wait_until("beta fully embedded after alpha's panic", || {
        fully_embedded(&beta, 100)
    })
    .await;
    assert!(!task.is_finished(), "the server task outlives the panic");
    assert_eq!(counts(&root.path().join("alpha")).embedded, 0);
    assert_eq!(
        batches.of("alpha"),
        1,
        "alpha's pass ended at the panic: {:?}",
        batches.tags()
    );
    task.abort();
}

#[test]
fn spawn_server_outside_a_tokio_runtime_starts_no_task() {
    let root = tempfile::tempdir().unwrap();
    let registry = Arc::new(Registry::new(
        root.path().to_path_buf(),
        Some(Arc::new(FakeEmbedder::new(DIM))),
    ));
    assert!(
        spawn_server(registry).is_none(),
        "no runtime to spawn on, so no task (and no panic)"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_drops_a_queued_vault_the_registry_evicted() {
    let (root, _) = root_with(&[("alpha", 200), ("beta", 200)]);
    let parking = tempfile::tempdir().unwrap();
    let batches = Batches::default();
    let (entered_tx, mut entered) = tokio::sync::mpsc::unbounded_channel();
    let (release_1, hold_1) = mpsc::channel();
    let (release_2, hold_2) = mpsc::channel();
    // Calls 1-8 are alpha's first cycle (call 1 held); call 9 is beta's
    // first call (held).
    let embedder = Scripted::new(
        &batches,
        script([
            vec![holds(entered_tx.clone(), hold_1)],
            times(7, plain),
            vec![holds(entered_tx, hold_2)],
        ]),
    );
    let registry = Arc::new(Registry::new(root.path().to_path_buf(), Some(embedder)));

    registry.get("alpha").await.expect("open alpha");
    let task = spawn_server(registry.clone()).expect("a server task");
    held(&mut entered, "alpha's first batch").await;
    // beta opens while alpha's batch is held; it queues ahead of alpha.
    registry.get("beta").await.expect("open beta");
    release_1.send(()).unwrap();
    held(&mut entered, "beta's first batch").await;

    // alpha now waits in the queue behind beta's held batch. It vanishes.
    std::fs::rename(root.path().join("alpha"), parking.path().join("alpha")).unwrap();
    assert!(
        registry.get("alpha").await.is_err(),
        "the registry evicts a vanished vault"
    );
    release_2.send(()).unwrap();

    let beta = root.path().join("beta");
    wait_until("beta fully embedded", || fully_embedded(&beta, 200)).await;
    assert_eq!(
        batches.of("alpha"),
        1,
        "the evicted vault's queued pass was dropped: {:?}",
        batches.tags()
    );
    assert_eq!(batches.of("beta"), 4);
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_ends_the_pass_of_a_vault_evicted_during_its_own_batch() {
    let (root, _) = root_with(&[("alpha", 200), ("beta", 200)]);
    let parking = tempfile::tempdir().unwrap();
    let batches = Batches::default();
    let (entered_tx, mut entered) = tokio::sync::mpsc::unbounded_channel();
    let (release, hold) = mpsc::channel();
    let embedder = Scripted::new(&batches, vec![holds(entered_tx, hold)]);
    let registry = Arc::new(Registry::new(root.path().to_path_buf(), Some(embedder)));

    registry.get("alpha").await.expect("open alpha");
    let task = spawn_server(registry.clone()).expect("a server task");
    held(&mut entered, "alpha's first batch").await;
    // beta opens and queues; it is the vault the task works while alpha's
    // pass would otherwise go on.
    registry.get("beta").await.expect("open beta");

    // alpha vanishes while its own batch is held, and the registry evicts it.
    std::fs::rename(root.path().join("alpha"), parking.path().join("alpha")).unwrap();
    assert!(
        registry.get("alpha").await.is_err(),
        "the registry evicts a vanished vault"
    );
    release.send(()).unwrap();

    let beta = root.path().join("beta");
    wait_until("beta fully embedded", || fully_embedded(&beta, 200)).await;
    assert_eq!(
        batches.of("alpha"),
        1,
        "the evicted vault's pass ended with its in-flight batch: {:?}",
        batches.tags()
    );
    assert_eq!(batches.of("beta"), 4);

    // The vault comes back: the registry opens it afresh, and that open
    // starts a new pass over what the first pass left (200 - 64 chunks).
    std::fs::rename(parking.path().join("alpha"), root.path().join("alpha")).unwrap();
    registry.get("alpha").await.expect("reopen alpha");
    let alpha = root.path().join("alpha");
    wait_until("the reopened alpha fully embedded", || {
        fully_embedded(&alpha, 200)
    })
    .await;
    assert_eq!(
        batches.of("alpha"),
        1 + 3,
        "the reopened vault's pass: 64 + 64 + 8 more: {:?}",
        batches.tags()
    );
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_does_not_revisit_a_finished_vault_while_it_stays_open() {
    let (root, _) = root_with(&[("alpha", 70), ("beta", 100)]);
    let batches = Batches::default();
    let registry = Arc::new(Registry::new(
        root.path().to_path_buf(),
        Some(Arc::new(Recording::new(&batches))),
    ));
    registry.get("alpha").await.expect("open alpha");
    let task = spawn_server(registry.clone()).expect("a server task");
    let alpha = root.path().join("alpha");
    wait_until("alpha fully embedded", || fully_embedded(&alpha, 70)).await;

    // A chunk with no vector appears after alpha's pass ended.
    read_write(&alpha)
        .execute(
            "INSERT INTO chunks
                (id, note_id, ord, content, token_count, embed_model_version,
                 start_byte, end_byte)
             SELECT 'Yextra', note_id, 100000, 'alpha late chunk', 3, NULL, 0, 16
               FROM chunks LIMIT 1",
            [],
        )
        .expect("add a late chunk");

    // beta's open wakes the task and beta's pass runs to its end: by then a
    // task that kept revisiting alpha would have embedded the late chunk.
    registry.get("beta").await.expect("open beta");
    let beta = root.path().join("beta");
    wait_until("beta fully embedded", || fully_embedded(&beta, 100)).await;
    assert_eq!(
        counts(&alpha),
        EmbeddingCounts {
            chunks: 71,
            embedded: 70
        },
        "a finished pass is not run again until the vault is reopened"
    );
    assert_eq!(batches.of("alpha"), 2, "alpha's own batches: 64 + 6");
    task.abort();
}

// ---------------------------------------------------------------------------
// Verify round 1: dropping the task cancels its batch (stdin EOF, shutdown)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_dropped_mid_batch_writes_nothing_and_frees_the_vault() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 100);
    let batches = Batches::default();
    let (entered_tx, mut entered) = tokio::sync::mpsc::unbounded_channel();
    let (release, hold) = mpsc::channel();
    let embedder = Scripted::new(&batches, vec![holds(entered_tx, hold)]);
    let st = state(&vault, Some(embedder.clone()));
    // The test's handle, `st.embedder`, and the task's clone.
    let others = Arc::strong_count(&embedder);

    let task = spawn_stdio(&st).expect("a stdio task");
    held(&mut entered, "the first batch").await;
    assert!(
        Arc::strong_count(&embedder) > others,
        "the batch thread holds the embedder while it is inside embed_batch"
    );

    // The runtime drops the task at stdin EOF or shutdown; abort is the same.
    task.abort();
    // The join completes once the task's future is dropped (the drop is what
    // cancels the batch), so release the batch only after it.
    let joined = task.await.expect_err("the aborted task ends cancelled");
    assert!(joined.is_cancelled(), "{joined:?}");
    release.send(()).unwrap();
    // The batch thread ends (its embedder clone is dropped) without a vector.
    wait_until("the cancelled batch thread ends", || {
        Arc::strong_count(&embedder) == others
    })
    .await;

    assert_eq!(
        counts(&vault),
        EmbeddingCounts {
            chunks: 100,
            embedded: 0
        },
        "the dropped task's batch wrote no vector once released"
    );
    assert_eq!(
        batches.sizes(),
        vec![64],
        "and no further batch started: the cancelled cycle only ran its own calls"
    );
    assert!(st.vault.try_lock().is_ok(), "the vault lock is free");
}

/// A model hub that accepts one connection and never answers it: the
/// download connects, then hangs. Sends once when the connection arrives.
fn hanging_hub() -> (String, Receiver<()>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind the hub");
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (accepted, arrived) = mpsc::channel();
    std::thread::spawn(move || {
        let mut held = Vec::new();
        while let Ok((stream, _)) = listener.accept() {
            held.push(stream);
            let _ = accepted.send(());
        }
    });
    (url, arrived)
}

#[test]
fn stdio_serve_exits_at_stdin_eof_while_the_model_download_hangs() {
    let dir = tempfile::tempdir().unwrap();
    let vault = std::path::absolute(dir.path().join("v")).unwrap();
    let note_id = seed(&vault, "alpha", 10);
    let (hub, arrived) = hanging_hub();

    let mut serve = StdioServe::start(&vault, &hub);
    serve.get_note(&note_id);
    // The backfill's first batch is inside the model download.
    arrived
        .recv_timeout(WAIT)
        .expect("the backfill's model download reached the hub");

    // The session keeps serving while the batch hangs.
    serve.get_note(&note_id);
    let status = serve
        .close_and_wait(WAIT)
        .expect("memex serve exited at stdin EOF although a batch is in flight");
    assert!(status.success(), "exit status {status:?}");
    assert_eq!(counts(&vault).embedded, 0, "no vector without a model");
}

// ---------------------------------------------------------------------------
// Ruling D48: backfill inference runs in sub-batches of at most 8 texts
// ---------------------------------------------------------------------------

/// `n` texts of the vault tagged `tag`, as `embed_missing` would hand them.
fn texts(tag: &str, n: usize) -> Vec<String> {
    (0..n).map(|i| passage(tag, i)).collect()
}

/// An embedder with its own model version and width, to pin delegation.
struct Versioned;

impl Embedder for Versioned {
    fn model_version(&self) -> &str {
        "wi422-model-v9"
    }

    fn dimension(&self) -> usize {
        3
    }

    fn embed_batch(&self, texts: &[String]) -> memex_core::Result<Vec<Vec<f32>>> {
        Ok(texts.iter().map(|_| vec![0.0; 3]).collect())
    }
}

#[test]
fn backfill_embed_sub_batch_is_eight() {
    assert_eq!(BACKFILL_EMBED_SUB_BATCH, 8, "ruling D48 names 8");
}

#[test]
fn sub_batch_embedder_makes_ceil_n_over_8_calls_of_at_most_8_in_order() {
    // (texts, the sizes of the calls the inner embedder sees)
    let cases: [(usize, Vec<usize>); 9] = [
        (0, vec![]),
        (1, vec![1]),
        (7, vec![7]),
        (8, vec![8]),
        (9, vec![8, 1]),
        (16, vec![8, 8]),
        (17, vec![8, 8, 1]),
        (64, vec![8; 8]),
        (65, [vec![8; 8], vec![1]].concat()),
    ];
    for (n, expected) in cases {
        let batches = Batches::default();
        let sub = SubBatchEmbedder::new(Arc::new(Recording::new(&batches)));
        let input = texts("alpha", n);

        let out = sub.embed_batch(&input).expect("embed through the adapter");

        assert_eq!(
            batches.call_sizes(),
            expected,
            "{n} texts: inner call sizes"
        );
        assert_eq!(
            batches.all().concat(),
            input,
            "{n} texts: every text reaches the inner embedder once, in order"
        );
        assert_eq!(
            out,
            FakeEmbedder::new(DIM).embed_batch(&input).unwrap(),
            "{n} texts: one vector per text, in the order of the texts"
        );
    }
}

#[test]
fn sub_batch_embedder_returns_the_first_inner_error_and_stops_calling() {
    let token = "wi422-sub-batch-error-5d2b";
    let batches = Batches::default();
    // 8 alpha texts embed; the second call (beta texts) fails.
    let sub = SubBatchEmbedder::new(Arc::new(Recording::failing_on(&batches, "beta", token)));
    let input = [texts("alpha", 8), texts("beta", 8), texts("beta", 1)].concat();

    let err = sub.embed_batch(&input).expect_err("the second call fails");

    assert!(
        matches!(&err, MemexError::EmbedderInfer(t) if t == token),
        "the inner error is returned as is: {err:?}"
    );
    assert_eq!(
        batches.call_sizes(),
        vec![8, 8],
        "no call after the one that failed"
    );
}

#[test]
fn sub_batch_embedder_reports_the_inner_model_version_and_dimension() {
    let sub = SubBatchEmbedder::new(Arc::new(Versioned));
    assert_eq!(sub.model_version(), "wi422-model-v9");
    assert_eq!(sub.dimension(), 3);
    let out = sub.embed_batch(&texts("alpha", 9)).unwrap();
    assert_eq!(out.len(), 9);
    assert!(out.iter().all(|v| v.len() == 3));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_embed_calls_never_exceed_8_texts_over_20_chunks() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");
    seed(&vault, "alpha", 20);
    let batches = Batches::default();
    let st = state(&vault, Some(Arc::new(Recording::new(&batches))));

    finished(spawn_stdio(&st).expect("a stdio task"), "stdio backfill").await;

    assert_eq!(batches.call_sizes(), vec![8, 8, 4]);
    assert_eq!(
        counts(&vault),
        EmbeddingCounts {
            chunks: 20,
            embedded: 20
        },
        "every chunk still ends embedded: pending reached 0"
    );
    assert_eq!(batches.sizes(), vec![20], "all in one lease cycle");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_backfill_embed_calls_never_exceed_8_texts_over_more_than_64_chunks() {
    let (root, _) = root_with(&[("alpha", 70), ("beta", 9)]);
    let batches = Batches::default();
    let srv = Srv::start(root, Some(Arc::new(Recording::new(&batches)))).await;

    srv.open("alpha").await;
    srv.open("beta").await;
    let (alpha, beta) = (srv.vault("alpha"), srv.vault("beta"));
    wait_until("both vaults fully embedded", || {
        fully_embedded(&alpha, 70) && fully_embedded(&beta, 9)
    })
    .await;

    // `cycles` asserts every call holds at most 8 texts.
    let cycles = batches.cycles();
    assert_eq!(batches.of("alpha"), 2, "{cycles:?}: 64 + 6");
    assert_eq!(batches.of("beta"), 1, "{cycles:?}: 9 in one lease cycle");
    let beta_calls: Vec<usize> = batches
        .all()
        .iter()
        .filter(|call| call[0].starts_with("beta "))
        .map(Vec::len)
        .collect();
    assert_eq!(beta_calls, vec![8, 1], "9 chunks: 8 + 1");
    assert_eq!(
        batches.call_sizes().iter().sum::<usize>(),
        79,
        "every chunk embedded once"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stdio_backfill_makes_one_call_for_8_chunks_and_two_for_9() {
    // (chunks, the sizes of the embed_batch calls)
    let cases: [(usize, Vec<usize>); 5] = [
        (1, vec![1]),
        (8, vec![8]),
        (9, vec![8, 1]),
        (16, vec![8, 8]),
        (17, vec![8, 8, 1]),
    ];
    for (n, expected) in cases {
        let dir = tempfile::tempdir().unwrap();
        let vault = dir.path().join("v");
        seed(&vault, "alpha", n);
        let batches = Batches::default();
        let st = state(&vault, Some(Arc::new(Recording::new(&batches))));

        finished(spawn_stdio(&st).expect("a stdio task"), "stdio backfill").await;

        assert_eq!(batches.call_sizes(), expected, "{n} chunks");
        assert!(
            fully_embedded(&vault, n),
            "{n} chunks: {:?}",
            counts(&vault)
        );
    }
}
