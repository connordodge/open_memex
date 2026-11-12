//! WI #403 (Spec #394 requirement 43; rulings D6, D20, D22, D39, D40):
//! `GET /vaults/{name}/api/v1/embeddings`.
//!
//! Every test serves the full `memex_mcp::server::router()` (in-process on
//! `127.0.0.1:0`, or the built `memex serve` binary for the `HF_HOME` case).
//! The body is `memex embeddings status`' shape:
//! `{"server_embeddings", "chunks", "embedded", "model_cached", "model_bytes"}`,
//! with `server_embeddings` whether the server runs with an embedder (always
//! 200, never `embeddings_off`), the counts from the served vault, and the
//! model fields from the server's own cache dir `model_cache_dir(<root>)`
//! (`$HF_HOME` when set), never a vault's `<vault>/.memex/models`.
//!
//! This process never has `HF_HOME` set (removed once, before any request),
//! and `HF_ENDPOINT` points at a tripwire. The wire fixture
//! `app/test/fixtures/api_v1/embeddings/` is shared with the Dart side;
//! [`embeddings_fixture_rows_match_the_full_router_on_the_seed`] checks it
//! against servers with and without an embedder (and rewrites it under
//! `MEMEX_BLESS=1`).

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/embeddings_vault.rs"]
mod embeddings_vault;
#[path = "../../memex-core/tests/hf_cache_fixture/mod.rs"]
mod hf_cache_fixture;
#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use memex_core::embedder::{Embedder, FakeEmbedder, GatedEmbedder};
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::model_cache_dir;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use api_fixtures::{
    api_v1_dir, bless_requested, canonical_json, load_rows, materialize_seed, run_rows,
    FixtureRequest, FixtureResponse, SEED_VAULT_NAME,
};
use embeddings_vault::{
    build_counted_vault, build_vault_without_chunk_vec, linked_cache_bytes, plain_cache_bytes,
    Built,
};
use hf_cache_fixture as fx;
use server::{
    assert_wrong_method_is_c1_405_at, client, raw_request, Reply, ServeCommand, ANY_PORT,
    TEST_TOKEN, TOKEN_ENV,
};

const SEED_PATH: &str = "/vaults/seed/api/v1/embeddings";

fn embeddings_dir() -> PathBuf {
    api_v1_dir().join("embeddings")
}

/// The process environment every in-process test runs under: `HF_HOME`
/// removed (a developer's must not leak in), `HF_ENDPOINT` at a tripwire.
/// No test in this binary sets `HF_HOME`; the set case runs in a child.
/// Every test calls it first, before it builds a vault or spawns a thread,
/// so the one process-wide env change completes (the `OnceLock` blocks the
/// other test threads) before any of them reads the environment.
fn clean_env() -> &'static fx::Tripwire {
    static T: OnceLock<fx::Tripwire> = OnceLock::new();
    T.get_or_init(|| {
        let t = fx::Tripwire::start();
        std::env::remove_var("HF_HOME");
        std::env::set_var("HF_ENDPOINT", &t.url);
        t
    })
}

// ---------- harness ----------

/// The full router over `root`, with or without a (fake) embedder.
///
/// `server::app()` starts the background embedding backfill (#422) for any
/// server with an embedder: once the first request opens a vault it embeds
/// every chunk that has no vector. [`Srv::start`] therefore serves a
/// [`GatedEmbedder`] whose gate stays closed, so the backfill holds inside
/// its first `embed_batch` and writes nothing: the counts a test builds are
/// the counts the handler reads, however slow the host. The gate opens when
/// the server is dropped. [`Srv::start_draining`] serves an open embedder for
/// the one test that watches the live counts follow the backfill.
struct Srv {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
    gate: Option<Arc<GatedEmbedder>>,
}

impl Srv {
    async fn start(root: TempDir, with_embedder: bool) -> Self {
        let gate = with_embedder
            .then(|| Arc::new(GatedEmbedder::new(FakeEmbedder::new(embeddings_vault::DIM))));
        let embedder = gate.clone().map(|g| g as Arc<dyn Embedder>);
        Self::start_with(root, embedder, gate).await
    }

    /// A server whose backfill runs freely.
    async fn start_draining(root: TempDir) -> Self {
        let embedder: Arc<dyn Embedder> = Arc::new(FakeEmbedder::new(embeddings_vault::DIM));
        Self::start_with(root, Some(embedder), None).await
    }

    async fn start_with(
        root: TempDir,
        embedder: Option<Arc<dyn Embedder>>,
        gate: Option<Arc<GatedEmbedder>>,
    ) -> Self {
        clean_env();
        let mut config = ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN);
        if let Some(embedder) = embedder {
            config = config.with_embedder(embedder);
        }
        let app = router(config);
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local addr");
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self {
            root,
            addr,
            task,
            gate,
        }
    }

    fn root(&self) -> &Path {
        self.root.path()
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    async fn get(&self, path: &str, authorization: Option<&str>) -> Reply {
        let mut req = client().get(self.url(path));
        if let Some(value) = authorization {
            req = req.header("authorization", value);
        }
        Reply::read(req.send().await.expect("send GET")).await
    }

    async fn get_ok(&self, path: &str) -> Value {
        let reply = self.get(path, Some(&bearer())).await;
        assert_eq!(reply.status, 200, "GET {path}: {}", reply.body);
        assert!(
            reply
                .header("content-type")
                .is_some_and(|ct| ct.starts_with("application/json")),
            "a JSON body, got {:?}",
            reply.header("content-type")
        );
        reply.json()
    }
}

impl Drop for Srv {
    fn drop(&mut self) {
        self.task.abort();
        // Never leave a blocking thread parked inside `embed_batch`: the
        // runtime would wait for it.
        if let Some(gate) = &self.gate {
            gate.release();
        }
    }
}

fn bearer() -> String {
    format!("Bearer {TEST_TOKEN}")
}

fn path_for(vault: &str) -> String {
    format!("/vaults/{vault}/api/v1/embeddings")
}

/// A root with `alpha` (N chunks, M joined vectors, K orphans) and `beta`
/// (no `chunk_vec`).
fn two_vault_root() -> (TempDir, Built, Built) {
    let root = tempfile::tempdir().unwrap();
    let alpha = build_counted_vault(&root.path().join("alpha"));
    let beta = build_vault_without_chunk_vec(&root.path().join("beta"));
    assert_ne!(alpha.chunks, beta.chunks, "fixture: different N");
    (root, alpha, beta)
}

fn uint(v: &Value, key: &str) -> u64 {
    v[key]
        .as_u64()
        .unwrap_or_else(|| panic!("{key} is a non-negative JSON integer: {v}"))
}

fn keys_of(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

// ---------- AC 6: server_embeddings, counts, model fields ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_reports_server_embeddings_true_with_an_embedder() {
    clean_env();
    let (root, alpha, _) = two_vault_root();
    let srv = Srv::start(root, true).await;

    let v = srv.get_ok(&path_for("alpha")).await;

    assert_eq!(
        keys_of(&v),
        [
            "server_embeddings",
            "chunks",
            "embedded",
            "model_cached",
            "model_bytes"
        ]
        .into_iter()
        .map(String::from)
        .collect(),
        "exactly the five contract keys: {v}"
    );
    assert_eq!(
        v,
        json!({
            "server_embeddings": true,
            "chunks": alpha.chunks,
            "embedded": alpha.joined,
            "model_cached": false,
            "model_bytes": 0,
        }),
        "embedder on; counts from alpha with its {} orphans excluded",
        alpha.orphans
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_reports_server_embeddings_false_without_an_embedder_and_still_200() {
    clean_env();
    let (root, alpha, _) = two_vault_root();
    let srv = Srv::start(root, false).await;

    // 200, never the E0 `embeddings_off` 409: the route reports status.
    let v = srv.get_ok(&path_for("alpha")).await;

    assert_eq!(
        v,
        json!({
            "server_embeddings": false,
            "chunks": alpha.chunks,
            "embedded": alpha.joined,
            "model_cached": false,
            "model_bytes": 0,
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_counts_come_from_the_served_vault() {
    clean_env();
    let (root, alpha, beta) = two_vault_root();
    let srv = Srv::start(root, true).await;

    let a = srv.get_ok(&path_for("alpha")).await;
    let b = srv.get_ok(&path_for("beta")).await;

    assert_eq!(
        (a["chunks"].clone(), a["embedded"].clone()),
        (json!(alpha.chunks), json!(alpha.joined)),
        "alpha: {a}"
    );
    assert_eq!(
        (b["chunks"].clone(), b["embedded"].clone()),
        (json!(beta.chunks), json!(0)),
        "beta has no chunk_vec: embedded 0: {b}"
    );
    // A second read answers the same (it is a read).
    assert_eq!(srv.get_ok(&path_for("alpha")).await, a);
}

/// The body is read live on every request: while the server's backfill embeds
/// the vault's missing chunks, `embedded` rises from the built M to N and
/// stops there (the K orphan vectors never count).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_embedded_follows_the_servers_backfill_live() {
    clean_env();
    let (root, alpha, _) = two_vault_root();
    assert!(alpha.joined < alpha.chunks, "fixture: chunks left to embed");
    assert!(alpha.orphans > 0, "fixture: orphans that must not count");
    let srv = Srv::start_draining(root).await;

    let started = std::time::Instant::now();
    let done = loop {
        let v = srv.get_ok(&path_for("alpha")).await;
        assert_eq!(v["chunks"], json!(alpha.chunks), "{v}");
        let embedded = uint(&v, "embedded") as i64;
        assert!(
            (alpha.joined..=alpha.chunks).contains(&embedded),
            "embedded stays within M..=N (orphans excluded): {v}"
        );
        if embedded == alpha.chunks {
            break v;
        }
        assert!(
            started.elapsed() < std::time::Duration::from_secs(30),
            "the backfill did not embed alpha: {v}"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    };
    assert_eq!(done["server_embeddings"], json!(true), "{done}");
    // Settled: a later read answers the same.
    assert_eq!(srv.get_ok(&path_for("alpha")).await, done);
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_model_fields_come_from_the_root_cache_not_the_vault_cache() {
    clean_env();
    let (root, alpha, _) = two_vault_root();
    let root_cache = model_cache_dir(root.path());
    fx::write_complete_linked(&root_cache);
    let want = linked_cache_bytes(&root_cache);
    // A complete cache inside a vault is not the server's cache.
    let beta_cache = model_cache_dir(&root.path().join("beta"));
    fx::write_complete(&beta_cache);
    fs_write(&beta_cache.join("extra.bin"), 10_000);
    let before = fx::tree(&root_cache);
    let srv = Srv::start(root, false).await;

    let a = srv.get_ok(&path_for("alpha")).await;
    assert_eq!(
        a,
        json!({
            "server_embeddings": false,
            "chunks": alpha.chunks,
            "embedded": alpha.joined,
            "model_cached": true,
            "model_bytes": want,
        }),
        "<root>/.memex/models: every blob once plus refs/main"
    );
    let b = srv.get_ok(&path_for("beta")).await;
    assert_eq!(b["model_cached"], json!(true), "{b}");
    assert_eq!(
        uint(&b, "model_bytes"),
        want,
        "beta's own cache is not the server's: {b}"
    );
    assert_eq!(fx::tree(&model_cache_dir(srv.root())), before, "untouched");
}

fn fs_write(path: &Path, n: usize) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![1u8; n]).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_with_only_a_vault_cache_reports_not_cached_and_zero() {
    clean_env();
    let (root, _, _) = two_vault_root();
    let alpha_cache = model_cache_dir(&root.path().join("alpha"));
    fx::write_complete(&alpha_cache);
    assert!(plain_cache_bytes(&alpha_cache) > 0);
    let srv = Srv::start(root, true).await;

    let a = srv.get_ok(&path_for("alpha")).await;

    assert_eq!(
        (a["model_cached"].clone(), a["model_bytes"].clone()),
        (json!(false), json!(0)),
        "the server's cache is <root>/.memex/models, which does not exist: {a}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_with_a_partial_root_cache_reports_not_cached() {
    clean_env();
    let (root, _, _) = two_vault_root();
    let cache = model_cache_dir(root.path());
    fx::write_complete(&cache);
    let model_file = fx::required_files()[0].clone();
    let model_len = std::fs::metadata(fx::snapshot_file(&cache, &model_file))
        .unwrap()
        .len();
    let complete = plain_cache_bytes(&cache);
    std::fs::remove_file(fx::snapshot_file(&cache, &model_file)).unwrap();
    let srv = Srv::start(root, true).await;

    let a = srv.get_ok(&path_for("alpha")).await;

    assert_eq!(a["model_cached"], json!(false), "{a}");
    assert_eq!(uint(&a, "model_bytes"), complete - model_len, "{a}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_never_creates_the_cache_dir_or_downloads() {
    clean_env();
    for with_embedder in [true, false] {
        let (root, alpha, _) = two_vault_root();
        let srv = Srv::start(root, with_embedder).await;
        let hits = clean_env().hits();

        let v = srv.get_ok(&path_for("alpha")).await;
        assert_eq!(v["server_embeddings"], json!(with_embedder), "{v}");
        assert_eq!(v["embedded"], json!(alpha.joined), "{v}");

        assert!(
            !model_cache_dir(srv.root()).exists(),
            "embedder {with_embedder}: the root cache dir is not created"
        );
        for vault in ["alpha", "beta"] {
            assert!(
                !model_cache_dir(&srv.root().join(vault)).exists(),
                "embedder {with_embedder}: {vault}'s cache dir is not created"
            );
        }
        assert_eq!(
            clean_env().hits(),
            hits,
            "no model download was attempted (HF_ENDPOINT tripwire)"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_embeddings_on_a_served_hf_home_reads_cache_and_size_from_hf_home() {
    // `HF_HOME` is process-global, so this server is the built binary with
    // `HF_HOME` set on the child only. It runs without --with-embeddings
    // (no model is ever loaded) and with a tripwire HF_ENDPOINT.
    let wire = clean_env();
    let scratch = tempfile::tempdir().unwrap();
    let hf_home = scratch.path().join("hf-home");
    fx::write_complete(&hf_home);
    let want = plain_cache_bytes(&hf_home);
    let empty_home = scratch.path().join("empty-home");
    std::fs::create_dir_all(&empty_home).unwrap();

    let (root, alpha, _) = two_vault_root();
    // The root's own cache is complete too, with a different size: HF_HOME
    // wins while it is set.
    let root_cache = model_cache_dir(root.path());
    fx::write_complete(&root_cache);
    fs_write(&root_cache.join("extra.bin"), 4321);
    let root_bytes = plain_cache_bytes(&root_cache) + 4321;
    assert_ne!(root_bytes, want);

    for (home, cached, bytes) in [
        (Some(hf_home.as_path()), true, want),
        (Some(empty_home.as_path()), false, 0),
        (None, true, root_bytes),
    ] {
        let mut cmd = ServeCommand::new(&[
            "--root",
            root.path().to_str().unwrap(),
            "--listen",
            ANY_PORT,
        ])
        .env(TOKEN_ENV, TEST_TOKEN)
        .env("HF_ENDPOINT", &wire.url)
        .env_remove("HF_HOME");
        if let Some(home) = home {
            cmd = cmd.env("HF_HOME", home.to_str().unwrap());
        }
        let mut child = cmd.spawn();
        let addr = child.ready().await;
        let reply = Reply::read(
            client()
                .get(format!("http://{addr}{}", path_for("alpha")))
                .header("authorization", bearer())
                .send()
                .await
                .expect("send GET"),
        )
        .await;
        child.stop();
        assert_eq!(
            reply.status,
            200,
            "HF_HOME={home:?}: {}; stderr={}",
            reply.body,
            child.stderr()
        );
        assert_eq!(
            reply.json(),
            json!({
                "server_embeddings": false,
                "chunks": alpha.chunks,
                "embedded": alpha.joined,
                "model_cached": cached,
                "model_bytes": bytes,
            }),
            "HF_HOME={home:?}: model_cached and model_bytes both follow it"
        );
    }
}

// ---------- AC 7: token and vault ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn embeddings_route_needs_the_token_and_a_known_vault() {
    clean_env();
    let (root, alpha, _) = two_vault_root();
    let srv = Srv::start(root, true).await;
    let path = path_for("alpha");

    // Control: the right token on a served vault is answered.
    let ok = srv.get_ok(&path).await;
    assert_eq!(ok["chunks"], json!(alpha.chunks), "{ok}");

    let missing = srv.get(&path, None).await;
    assert_eq!(missing.status, 401, "no token: {}", missing.body);
    assert_eq!(missing.c1_code(), "unauthorized");
    assert!(!missing.body.contains("chunks"), "{}", missing.body);

    let wrong = srv
        .get(&path, Some("Bearer wrong-token-not-the-server-token"))
        .await;
    assert_eq!(wrong.status, 401, "wrong token: {}", wrong.body);
    assert_eq!(wrong.c1_code(), "unauthorized");
    assert!(!wrong.body.contains("chunks"), "{}", wrong.body);

    let unknown = srv.get(&path_for("nope"), Some(&bearer())).await;
    assert_eq!(unknown.status, 404, "unknown vault: {}", unknown.body);
    assert_eq!(unknown.c1_code(), "vault_not_found");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_router_starts_with_the_embeddings_route_and_serves_get_only() {
    clean_env();
    // A path parameter clash between merged routers panics only when the
    // merged tree is built and started.
    let root = tempfile::tempdir().unwrap();
    materialize_seed(root.path());
    let srv = Srv::start(root, false).await;

    let v = srv.get_ok(SEED_PATH).await;
    assert_eq!(v["server_embeddings"], json!(false), "{v}");

    assert_wrong_method_is_c1_405_at(srv.addr, &bearer(), &[(SEED_PATH, &["GET"])]).await;

    // Nothing else sits under `/embeddings`.
    let below = srv
        .get(&format!("{SEED_PATH}/status"), Some(&bearer()))
        .await;
    assert_eq!(below.status, 404, "{}", below.body);
    assert_eq!(below.c1_code(), "not_found");
}

// ---------- AC 8: the shared wire fixture ----------

/// One fixture row over a bare socket. The row's own `Authorization` header
/// replaces the token.
async fn exec(addr: SocketAddr, req: &FixtureRequest) -> FixtureResponse {
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        req.method, req.path
    );
    if !req
        .headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("authorization"))
    {
        head.push_str(&format!("Authorization: {}\r\n", bearer()));
    }
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    let reply = raw_request(addr, &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

/// The response file of the row a server without an embedder answers; every
/// other row is answered by a server with one.
const OFF_RESPONSE: &str = "server_embeddings_off.json";
const ON_RESPONSE: &str = "server_embeddings_on.json";
/// The row a server with an embedder, vectors in the seed vault and a
/// complete model cache in its root answers: every field non-zero/true, so
/// the Dart consumer's fixture exercises a populated body.
const READY_RESPONSE: &str = "server_embeddings_ready.json";
/// Seed chunks given a vector (plus one orphan) for [`READY_RESPONSE`].
const READY_EMBEDDED: i64 = 3;

/// A root holding the seed, `READY_EMBEDDED` of its chunks embedded (and one
/// orphan vector), and a complete linked model cache in `<root>/.memex/models`.
fn ready_root() -> (TempDir, u64) {
    let root = tempfile::tempdir().unwrap();
    let vault = materialize_seed(root.path());
    {
        let v = memex_core::Vault::open(&vault).expect("open seed");
        memex_core::schema::ensure_vector_table(v.connection_ref(), embeddings_vault::DIM)
            .expect("chunk_vec");
        let ids: Vec<String> = {
            let mut stmt = v
                .connection_ref()
                .prepare("SELECT id FROM chunks ORDER BY id LIMIT ?")
                .unwrap();
            let rows = stmt
                .query_map([READY_EMBEDDED], |r| r.get::<_, String>(0))
                .unwrap();
            rows.map(|r| r.unwrap()).collect()
        };
        assert_eq!(
            ids.len() as i64,
            READY_EMBEDDED,
            "the seed has enough chunks"
        );
        let mut unit = [0f32; embeddings_vault::DIM];
        unit[0] = 1.0;
        let bytes: Vec<u8> = unit.iter().flat_map(|f| f.to_le_bytes()).collect();
        for id in ids
            .iter()
            .map(String::as_str)
            .chain(["01ORPHANCHUNK0000000000000"])
        {
            v.connection_ref()
                .execute(
                    "INSERT INTO chunk_vec (chunk_id, embedding) VALUES (?, ?)",
                    rusqlite::params![id, bytes],
                )
                .unwrap();
        }
    }
    let cache = model_cache_dir(root.path());
    fx::write_complete_linked(&cache);
    let bytes = linked_cache_bytes(&cache);
    (root, bytes)
}

#[test]
fn embeddings_fixture_rows_match_the_full_router_on_the_seed() {
    clean_env();
    let rows = load_rows(&embeddings_dir()).expect("embeddings/index.json parses");
    let seen: BTreeSet<(String, String, u16, String)> = rows
        .iter()
        .map(|r| {
            (
                r.method.clone(),
                r.path.clone(),
                r.status,
                r.response.clone(),
            )
        })
        .collect();
    for (path, status, response) in [
        (SEED_PATH, 200, ON_RESPONSE),
        (SEED_PATH, 200, OFF_RESPONSE),
        (SEED_PATH, 200, READY_RESPONSE),
        (SEED_PATH, 401, "unauthorized.json"),
        (
            "/vaults/nope/api/v1/embeddings",
            404,
            "vault_not_found.json",
        ),
    ] {
        let want = (
            "GET".to_string(),
            path.to_string(),
            status,
            response.to_string(),
        );
        assert!(seen.contains(&want), "embeddings/ has a row {want:?}");
    }
    assert!(
        rows.iter().all(|r| !r.dart_only),
        "every embeddings row runs in Rust"
    );
    // run_rows calls the executor once per row, in row order.
    let row_responses: Vec<String> = rows.iter().map(|r| r.response.clone()).collect();

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let seeded = || {
        let root = tempfile::tempdir().unwrap();
        materialize_seed(root.path());
        root
    };
    let on = rt.block_on(Srv::start(seeded(), true));
    let off = rt.block_on(Srv::start(seeded(), false));
    let (ready_root, ready_bytes) = ready_root();
    let ready = rt.block_on(Srv::start(ready_root, true));
    let mut i = 0;
    let result = run_rows(&embeddings_dir(), bless_requested(), |req| {
        let addr = match row_responses[i].as_str() {
            OFF_RESPONSE => off.addr,
            READY_RESPONSE => ready.addr,
            _ => on.addr,
        };
        i += 1;
        rt.block_on(exec(addr, req))
    });
    assert!(
        !model_cache_dir(on.root()).exists() && !model_cache_dir(off.root()).exists(),
        "serving the rows created no cache dir"
    );
    drop(on);
    drop(off);
    drop(ready);
    // The populated row is not a blessed accident: its numbers are the
    // seed's counts, the vectors written above and the cache's size on disk.
    let committed = std::fs::read_to_string(embeddings_dir().join(READY_RESPONSE));
    if !bless_requested() {
        let committed = committed.unwrap_or_else(|e| panic!("{READY_RESPONSE}: {e}"));
        let body: Value = serde_json::from_str(&committed).expect("ready fixture is JSON");
        assert_eq!(body["embedded"], json!(READY_EMBEDDED), "{body}");
        assert_eq!(body["model_cached"], json!(true), "{body}");
        assert_eq!(body["model_bytes"], json!(ready_bytes), "{body}");
        assert_eq!(body["server_embeddings"], json!(true), "{body}");
        assert!(body["chunks"].as_i64().unwrap() > READY_EMBEDDED, "{body}");
    }
    if let Err(e) = result {
        panic!("{e}");
    }
}

/// Not an AC row: the committed 200 bodies are the seed's own counts with no
/// model cache, so a reblessed fixture can't carry wrong numbers.
#[test]
fn embeddings_fixture_bodies_are_the_seed_counts_without_a_model_cache() {
    clean_env();
    let root = tempfile::tempdir().unwrap();
    let vault = materialize_seed(root.path());
    let counts = {
        let v = memex_core::Vault::open(&vault).expect("open seed");
        memex_core::vectors::embedding_counts(v.connection_ref()).expect("counts")
    };
    assert!(counts.chunks > 0, "the seed has chunks");
    for (file, on) in [(ON_RESPONSE, true), (OFF_RESPONSE, false)] {
        let path = embeddings_dir().join(file);
        let committed =
            std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        assert_eq!(
            committed,
            canonical_json(&json!({
                "server_embeddings": on,
                "chunks": counts.chunks,
                "embedded": counts.embedded,
                "model_cached": false,
                "model_bytes": 0,
            })),
            "{file}"
        );
    }
    assert_eq!(SEED_VAULT_NAME, "seed");
}
