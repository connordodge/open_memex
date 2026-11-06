//! WI #72 (R0b): the vault registry, the name rule, the shared embedder and
//! the request clock, called directly (D8, D9; lead rulings on the base
//! clock and `RequestClock`).
//!
//! - AC 4 / 8: `validate_vault_name`, the one name rule.
//! - AC 9: a vanished vault is evicted; a reopen mints a new `open_id`.
//! - AC 11: concurrent first gets open a vault once (one `VaultEntry`).
//! - AC 12: `build_embedder_in` and the embedder every entry shares.
//! - AC 13: the base clock in `ServerConfig` and the `RequestClock`
//!   extractor.

#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::extract::FromRequestParts;
use axum::response::IntoResponse;
use memex_core::daily::today_with_clock;
use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::{Clock, SystemClock};
use memex_mcp::server::registry::{
    validate_vault_name, with_vault, Registry, ServedVault, VaultEntry,
};
use memex_mcp::server::request_clock::{BaseClock, CallerUtcOffset, RequestClock, SharedClock};
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::build_embedder_in;
use serde_json::Value;
use tokio::sync::Barrier;

use server::{make_v4_vault, make_vault};

/// `(status, C1 code)` of an error response.
async fn reply_of(resp: axum::response::Response) -> (u16, String) {
    let status = resp.status().as_u16();
    let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20)
        .await
        .expect("read body");
    let v: Value = serde_json::from_slice(&bytes).expect("C1 JSON body");
    (
        status,
        v["error"]["code"].as_str().unwrap_or_default().to_string(),
    )
}

async fn get_entry(registry: &Registry, name: &str) -> Arc<VaultEntry> {
    match registry.get(name).await {
        Ok(entry) => entry,
        Err(e) => panic!("get {name}: {:?}", reply_of(e.into_response()).await),
    }
}

async fn assert_get_is_vault_not_found(registry: &Registry, name: &str) {
    match registry.get(name).await {
        Ok(_) => panic!("get {name:?} returned an entry"),
        Err(e) => assert_eq!(
            reply_of(e.into_response()).await,
            (404, "vault_not_found".to_string()),
            "get {name:?}"
        ),
    }
}

// ---------------------------------------------------------------------------
// AC 4 / 8: the name rule
// ---------------------------------------------------------------------------

#[test]
fn vault_name_rule_accepts_letters_digits_dash_and_underscore_up_to_64() {
    let max = format!(
        "a{}9",
        "Z_-".repeat(21).chars().take(62).collect::<String>()
    );
    assert_eq!(max.len(), 64);
    for name in [
        "a",
        "Z",
        "0",
        "-",
        "_",
        "work",
        "Work",
        "WORK",
        "my-vault_2",
        "-dash",
        "9lives",
        max.as_str(),
    ] {
        assert!(validate_vault_name(name).is_ok(), "{name:?} is valid");
    }
}

#[tokio::test]
async fn vault_name_rule_rejects_everything_else_as_invalid_vault_name() {
    let long = "a".repeat(65);
    let names = [
        "",
        long.as_str(),
        ".",
        "..",
        ".hidden",
        ".memex",
        ".incoming",
        "../x",
        "x/..",
        "x/y",
        "/abs",
        "x\\y",
        "a\0b",
        "\0",
        "a b",
        " work",
        "work ",
        "work\n",
        "work\r\n",
        "tab\tx",
        "a.b",
        "a+b",
        "a@b",
        "x:y",
        "%2e%2e",
        "ü",
        "naïve",
        "ß",
        "\u{FB00}",        // LATIN SMALL LIGATURE FF
        "\u{212A}elvin",   // KELVIN SIGN, lowercases to ASCII `k`
        "\u{0130}stanbul", // dotted capital I
        "\u{FF57}ork",     // fullwidth w
        "wor\u{200B}k",    // zero-width space
        "е",               // Cyrillic e
    ];
    for name in names {
        match validate_vault_name(name) {
            Ok(()) => panic!("{name:?} must be rejected"),
            Err(e) => assert_eq!(
                reply_of(e.into_response()).await,
                (400, "invalid_vault_name".to_string()),
                "{name:?}"
            ),
        }
    }
}

// ---------------------------------------------------------------------------
// AC 9 / 11: one entry per open, eviction, open_id
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_first_gets_of_one_vault_return_one_entry() {
    let root = tempfile::tempdir().unwrap();
    // A V4 vault: the first open migrates, which widens the race window.
    make_v4_vault(root.path(), "busy");
    let registry = Arc::new(Registry::new(root.path().to_path_buf(), None));
    let barrier = Arc::new(Barrier::new(16));
    let tasks: Vec<_> = (0..16)
        .map(|i| {
            let registry = registry.clone();
            let barrier = barrier.clone();
            let name = ["busy", "BUSY", "Busy", "bUsY"][i % 4];
            tokio::spawn(async move {
                barrier.wait().await;
                get_entry(&registry, name).await
            })
        })
        .collect();
    let mut entries = Vec::new();
    for t in tasks {
        entries.push(t.await.expect("get task"));
    }
    let first = &entries[0];
    for e in &entries {
        assert!(Arc::ptr_eq(e, first), "every get shares one VaultEntry");
        assert_eq!(e.open_id, first.open_id);
    }
    let manifest_version = first.state.vault.lock().await.manifest().schema_version;
    assert_eq!(
        manifest_version,
        memex_core::schema::APP_SCHEMA_VERSION,
        "migrated on open"
    );
}

#[tokio::test]
async fn get_returns_the_same_entry_while_the_vault_stays() {
    let root = tempfile::tempdir().unwrap();
    let id = make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let a = get_entry(&registry, "work").await;
    let b = get_entry(&registry, "WORK").await;
    assert!(Arc::ptr_eq(&a, &b));
    let open_id = a.open_id.to_string();
    assert!(
        open_id.len() == 26 && ulid::Ulid::from_string(&open_id).is_ok(),
        "open_id {open_id:?} is a ULID"
    );
    assert_eq!(a.state.vault.lock().await.manifest().vault_id, id);
}

#[tokio::test]
async fn get_of_an_unknown_or_invalid_name_is_vault_not_found() {
    let outer = tempfile::tempdir().unwrap();
    let root = outer.path().join("root");
    std::fs::create_dir(&root).unwrap();
    make_vault(outer.path(), "secret");
    let registry = Registry::new(root.clone(), None);
    for name in ["nope", "secret", "../secret", "..", "", ".memex", "a/b"] {
        assert_get_is_vault_not_found(&registry, name).await;
    }
}

#[tokio::test]
async fn get_after_the_folder_vanishes_evicts_and_reopens_with_a_new_open_id() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let old = get_entry(&registry, "work").await;

    std::fs::remove_dir_all(root.path().join("work")).unwrap();
    assert_get_is_vault_not_found(&registry, "work").await;

    let new_id = make_vault(root.path(), "work");
    let new = get_entry(&registry, "work").await;
    assert!(!Arc::ptr_eq(&old, &new), "a new entry, not the old handle");
    assert_ne!(new.open_id, old.open_id, "a reopen mints a new open_id");
    assert_eq!(new.state.vault.lock().await.manifest().vault_id, new_id);
}

#[tokio::test]
async fn each_registry_open_mints_its_own_open_id() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let mut ids = BTreeSet::new();
    for _ in 0..3 {
        let registry = Registry::new(root.path().to_path_buf(), None);
        let entry = get_entry(&registry, "work").await;
        ids.insert(entry.open_id.to_string());
    }
    assert_eq!(ids.len(), 3, "open_id is per open, not per vault: {ids:?}");
}

// ---------------------------------------------------------------------------
// AC 12: the embedder
// ---------------------------------------------------------------------------

#[test]
fn build_embedder_in_creates_the_root_models_dir_without_downloading() {
    let root = tempfile::tempdir().unwrap();
    let embedder = build_embedder_in(root.path());
    let models = root.path().join(".memex/models");
    assert!(models.is_dir(), "{} is a directory", models.display());
    assert_eq!(
        std::fs::read_dir(&models).unwrap().count(),
        0,
        "nothing downloaded"
    );
    assert_eq!(
        std::fs::read_dir(root.path()).unwrap().count(),
        1,
        "only .memex under the root"
    );
    assert_eq!(embedder.model_version(), "BAAI/bge-small-en-v1.5");
    assert_eq!(embedder.dimension(), 384);
}

#[tokio::test]
async fn every_registry_entry_shares_the_one_embedder() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "alpha");
    make_vault(root.path(), "beta");
    let shared: Arc<dyn Embedder> = Arc::new(FakeEmbedder::new(8));
    let registry = Registry::new(root.path().to_path_buf(), Some(shared.clone()));
    for name in ["alpha", "beta"] {
        let entry = get_entry(&registry, name).await;
        let embedder = entry.state.embedder.clone().expect("an embedder");
        assert!(
            Arc::ptr_eq(&embedder, &shared),
            "{name} uses the shared one"
        );
    }

    let plain = Registry::new(root.path().to_path_buf(), None);
    let entry = get_entry(&plain, "alpha").await;
    assert!(entry.state.embedder.is_none());
}

// ---------------------------------------------------------------------------
// AC 13: base clock and RequestClock
// ---------------------------------------------------------------------------

/// 2026-03-01T10:30:00Z.
const FIXED_MS: i64 = 1_772_361_000_000;

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// Returns `steps[i]` on the i-th read (the last one after that).
struct SteppingClock {
    steps: Vec<i64>,
    reads: AtomicUsize,
}

impl Clock for SteppingClock {
    fn now_ms(&self) -> i64 {
        let i = self.reads.fetch_add(1, Ordering::SeqCst);
        self.steps[i.min(self.steps.len() - 1)]
    }
}

/// What a handler extracts on a server whose base clock is `base`, for a
/// request with no caller offset in its extensions.
async fn extract(base: SharedClock) -> RequestClock {
    let (mut parts, ()) = axum::http::Request::builder()
        .uri("/vaults/work/api/v1/info")
        .extension(BaseClock(base))
        .body(())
        .unwrap()
        .into_parts();
    match RequestClock::from_request_parts(&mut parts, &()).await {
        Ok(clock) => clock,
        Err(_) => panic!("RequestClock extraction failed"),
    }
}

#[tokio::test]
async fn request_clock_with_the_default_base_and_no_offset_is_system_time_and_local_date() {
    let config = ServerConfig::new("/tmp/unused-root", "token");
    let before = SystemClock.now_ms();
    let from_config = config.clock().now_ms();
    let clock = extract(config.clock()).await;
    let now = clock.now_ms();
    let after = SystemClock.now_ms();
    assert!(
        (before..=after).contains(&from_config),
        "the default base clock is the system clock"
    );
    assert!(
        (before..=after).contains(&now),
        "{before} <= {now} <= {after}"
    );

    let day_before = today_with_clock(&SystemClock);
    let today = today_with_clock(&clock);
    let day_after = today_with_clock(&SystemClock);
    assert!(
        today == day_before || today == day_after,
        "the server's local date: {today} vs {day_before}/{day_after}"
    );
}

#[tokio::test]
async fn request_clock_on_a_fixed_base_clock_server_is_that_instant() {
    let fixed: SharedClock = Arc::new(FixedClock(FIXED_MS));
    let config = ServerConfig::new("/tmp/unused-root", "token")
        .with_embeddings(false)
        .with_clock(fixed);
    assert_eq!(config.clock().now_ms(), FIXED_MS);
    assert_eq!(config.clone().clock().now_ms(), FIXED_MS, "kept by clone");

    let clock = extract(config.clock()).await;
    assert_eq!(clock.now_ms(), FIXED_MS);
    assert_eq!(clock.now_ms(), FIXED_MS);
    assert_eq!(
        today_with_clock(&clock),
        today_with_clock(&FixedClock(FIXED_MS)),
        "no offset: the server's local date of the fixed instant"
    );
}

#[tokio::test]
async fn request_clock_reads_the_base_clock_on_every_call_even_when_it_jumps_back() {
    // NTP or a manual change moves the base clock back an hour.
    let base: SharedClock = Arc::new(SteppingClock {
        steps: vec![FIXED_MS, FIXED_MS - 3_600_000, FIXED_MS + 1],
        reads: AtomicUsize::new(0),
    });
    let clock = extract(base).await;
    assert_eq!(clock.now_ms(), FIXED_MS);
    assert_eq!(
        clock.now_ms(),
        FIXED_MS - 3_600_000,
        "no clamping or caching"
    );
    assert_eq!(clock.now_ms(), FIXED_MS + 1);
}

// ---------------------------------------------------------------------------
// Verify: contracts from the implementer's handoff
// ---------------------------------------------------------------------------

/// What a handler extracts from `req`, whatever its extensions hold.
async fn extract_from(req: axum::http::Request<()>) -> RequestClock {
    let (mut parts, ()) = req.into_parts();
    match RequestClock::from_request_parts(&mut parts, &()).await {
        Ok(clock) => clock,
        Err(_) => panic!("RequestClock extraction failed"),
    }
}

/// A request with nothing in its extensions.
fn bare_request() -> axum::http::Request<()> {
    axum::http::Request::builder()
        .uri("/vaults/work/api/v1/info")
        .body(())
        .unwrap()
}

#[tokio::test]
async fn request_clock_without_a_base_clock_extension_falls_back_to_system_time() {
    let before = SystemClock.now_ms();
    let day_before = today_with_clock(&SystemClock);
    let clock = extract_from(bare_request()).await;
    let now = clock.now_ms();
    let today = today_with_clock(&clock);
    let after = SystemClock.now_ms();
    let day_after = today_with_clock(&SystemClock);
    assert!(
        (before..=after).contains(&now),
        "{before} <= {now} <= {after}"
    );
    assert_eq!(clock.caller_offset(), None);
    assert!(
        today == day_before || today == day_after,
        "the server's local date: {today} vs {day_before}/{day_after}"
    );
}

#[tokio::test]
async fn request_clock_caller_offset_is_none_by_default_and_the_inserted_offset_otherwise() {
    let fixed: SharedClock = Arc::new(FixedClock(FIXED_MS));
    let clock = extract(fixed.clone()).await;
    assert_eq!(clock.caller_offset(), None, "no offset unless inserted");
    assert_eq!(clock.now_ms(), FIXED_MS);

    for minutes in [330, -480, 0, 765, -720] {
        let req = axum::http::Request::builder()
            .uri("/vaults/work/api/v1/info")
            .extension(BaseClock(fixed.clone()))
            .extension(CallerUtcOffset(minutes))
            .body(())
            .unwrap();
        let clock = extract_from(req).await;
        assert_eq!(clock.caller_offset(), Some(CallerUtcOffset(minutes)));
        assert_eq!(
            clock.now_ms(),
            FIXED_MS,
            "the offset never moves the instant"
        );
    }

    // An offset but no base clock: the system time, offset kept.
    let req = axum::http::Request::builder()
        .uri("/")
        .extension(CallerUtcOffset(60))
        .body(())
        .unwrap();
    let before = SystemClock.now_ms();
    let clock = extract_from(req).await;
    let now = clock.now_ms();
    assert!((before..=SystemClock.now_ms()).contains(&now));
    assert_eq!(clock.caller_offset(), Some(CallerUtcOffset(60)));
}

#[tokio::test]
async fn served_vault_outside_the_vault_guard_is_500_internal() {
    let (mut parts, ()) = bare_request().into_parts();
    match ServedVault::from_request_parts(&mut parts, &()).await {
        Ok(_) => panic!("no vault was resolved for this request"),
        Err(e) => assert_eq!(
            reply_of(e.into_response()).await,
            (500, "internal".to_string())
        ),
    }
}

#[tokio::test]
async fn a_vault_replaced_on_disk_is_reopened_with_a_new_open_id() {
    let root = tempfile::tempdir().unwrap();
    let old_id = make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let old = get_entry(&registry, "work").await;
    assert_eq!(old.state.vault.lock().await.manifest().vault_id, old_id);

    // Replaced at the same folder with no request in between, so nothing
    // ever saw it missing.
    std::fs::remove_dir_all(root.path().join("work")).unwrap();
    let new_id = make_vault(root.path(), "work");
    assert_ne!(new_id, old_id);

    let new = get_entry(&registry, "WORK").await;
    assert!(!Arc::ptr_eq(&old, &new), "not the old handle");
    assert_ne!(new.open_id, old.open_id, "a reopen mints a new open_id");
    assert_eq!(new.state.vault.lock().await.manifest().vault_id, new_id);
    let again = get_entry(&registry, "work").await;
    assert!(Arc::ptr_eq(&new, &again), "then kept");
}

#[tokio::test]
async fn an_unreadable_manifest_on_an_open_vault_keeps_its_entry() {
    let root = tempfile::tempdir().unwrap();
    let id = make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let open = get_entry(&registry, "work").await;
    // Mid-rewrite or damaged: still a file, but not a manifest.
    std::fs::write(root.path().join("work/manifest.json"), b"{not json").unwrap();
    let again = get_entry(&registry, "work").await;
    assert!(Arc::ptr_eq(&open, &again), "kept, not reopened");
    assert_eq!(again.state.vault.lock().await.manifest().vault_id, id);
}

#[tokio::test]
async fn a_symlink_to_a_vault_inside_the_root_is_never_served() {
    let root = tempfile::tempdir().unwrap();
    let r = root.path();
    let work = make_vault(r, "work");
    std::fs::create_dir(r.join(".incoming")).unwrap();
    make_vault(&r.join(".incoming"), "staged");
    std::os::unix::fs::symlink(r.join("work"), r.join("alias")).unwrap();
    std::os::unix::fs::symlink("work", r.join("relalias")).unwrap();
    std::os::unix::fs::symlink(r.join(".incoming/staged"), r.join("staged")).unwrap();
    let registry = Registry::new(r.to_path_buf(), None);

    let listed: Vec<(String, String)> = match registry.list().await {
        Ok(vaults) => vaults.into_iter().map(|v| (v.name, v.vault_id)).collect(),
        Err(_) => panic!("list failed"),
    };
    assert_eq!(listed, [("work".to_string(), work)]);
    for name in ["alias", "ALIAS", "relalias", "staged"] {
        assert_get_is_vault_not_found(&registry, name).await;
    }
    assert!(
        !r.join(".incoming/staged/memex.db-wal").exists(),
        "never opened"
    );
    get_entry(&registry, "work").await;
}

/// A current-thread runtime with one blocking thread, so blocking tasks
/// run one at a time in the order they were queued.
fn one_blocking_thread() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .max_blocking_threads(1)
        .enable_all()
        .build()
        .unwrap()
}

/// Polls `fut` once, on `rt`; true if it is still pending.
fn poll_once<F: std::future::Future>(
    rt: &tokio::runtime::Runtime,
    fut: &mut std::pin::Pin<Box<F>>,
) -> bool {
    rt.block_on(std::future::poll_fn(|cx| {
        std::task::Poll::Ready(fut.as_mut().poll(cx).is_pending())
    }))
}

/// Waits until every blocking task queued on `rt` before this call has run.
fn drain_blocking(rt: &tokio::runtime::Runtime) {
    rt.block_on(rt.spawn_blocking(|| ())).unwrap();
}

/// A task holding `rt`'s one blocking thread. The blocking pool starts a
/// task as soon as it is queued, so a scan or open queued by a poll can
/// finish before the poll returns; queued behind this task, it waits (in
/// order) until [`release`].
struct Held {
    release: std::sync::mpsc::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}

fn hold_blocking(rt: &tokio::runtime::Runtime) -> Held {
    let (release, held) = std::sync::mpsc::channel::<()>();
    let task = rt.spawn_blocking(move || {
        held.recv().ok();
    });
    Held { release, task }
}

/// Lets every blocking task queued behind `held` run, and waits for them.
fn release(rt: &tokio::runtime::Runtime, held: Held) {
    held.release.send(()).unwrap();
    rt.block_on(held.task).unwrap();
    drain_blocking(rt);
}

#[test]
fn a_vault_deleted_between_the_scan_and_the_open_is_vault_not_found() {
    let rt = one_blocking_thread();
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);

    let mut first = Box::pin(registry.get("work"));
    let held = hold_blocking(&rt);
    assert!(poll_once(&rt, &mut first), "waiting on the scan");
    release(&rt, held); // the scan has seen the vault
    std::fs::remove_dir_all(root.path().join("work")).unwrap();
    // The open runs now, on a folder that is gone. AC 9 / D8: a missing
    // manifest is 404 `vault_not_found`, never 500.
    match rt.block_on(first) {
        Ok(_) => panic!("served a deleted vault"),
        Err(e) => assert_eq!(
            rt.block_on(reply_of(e.into_response())),
            (404, "vault_not_found".to_string())
        ),
    }
    match rt.block_on(registry.get("work")) {
        Ok(_) => panic!("served a deleted vault"),
        Err(e) => assert_eq!(
            rt.block_on(reply_of(e.into_response())),
            (404, "vault_not_found".to_string()),
            "the next request"
        ),
    }
    assert!(!root.path().join("work").exists(), "nothing recreated");
}

#[test]
fn an_eviction_racing_a_reopen_keeps_one_entry_per_vault() {
    let rt = one_blocking_thread();
    let root = tempfile::tempdir().unwrap();
    let registry = Registry::new(root.path().to_path_buf(), None);

    // A request scans while the folder is not there yet...
    let mut late = Box::pin(registry.get("work"));
    let held = hold_blocking(&rt);
    assert!(poll_once(&rt, &mut late), "waiting on the scan");
    release(&rt, held);
    // ...the vault appears and another request opens it...
    make_vault(root.path(), "work");
    let opened = match rt.block_on(registry.get("work")) {
        Ok(entry) => entry,
        Err(_) => panic!("open work"),
    };
    // ...then the first request finishes: 404 for what it saw.
    assert!(rt.block_on(late).is_err(), "the scan saw no vault");
    // D8: one connection per vault; the open entry stays.
    let next = match rt.block_on(registry.get("work")) {
        Ok(entry) => entry,
        Err(_) => panic!("get work"),
    };
    assert!(
        Arc::ptr_eq(&opened, &next),
        "a stale not-found evicted the entry another request opened \
         (open_id {} then {}): two connections to one vault",
        opened.open_id,
        next.open_id
    );
}

#[tokio::test]
async fn with_vault_runs_the_closure_off_the_async_worker() {
    // One runtime thread: a closure run on it would stall every request.
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let other_id = make_vault(root.path(), "other");
    let registry = Arc::new(Registry::new(root.path().to_path_buf(), None));
    let work = get_entry(&registry, "work").await;

    let (started_tx, started_rx) = tokio::sync::oneshot::channel::<()>();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let held = tokio::spawn(async move {
        with_vault(&work, move |_vault| {
            started_tx.send(()).ok();
            Ok(release_rx
                .recv_timeout(std::time::Duration::from_secs(5))
                .is_ok())
        })
        .await
    });
    started_rx.await.expect("the closure started");

    // While `work` is held, a request for another vault completes on this
    // same runtime thread.
    let other = get_entry(&registry, "other").await;
    let id = match with_vault(&other, |vault| Ok(vault.manifest().vault_id.clone())).await {
        Ok(id) => id,
        Err(_) => panic!("with_vault other failed"),
    };
    assert_eq!(id, other_id);
    release_tx.send(()).unwrap();

    match held.await.unwrap() {
        Ok(released) => assert!(released, "the runtime stalled while the vault was held"),
        Err(_) => panic!("with_vault work failed"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_vault_gives_one_closure_the_vault_at_a_time() {
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let entry = get_entry(&registry, "work").await;
    let inside = Arc::new(AtomicUsize::new(0));
    let most = Arc::new(AtomicUsize::new(0));
    let tasks: Vec<_> = (0..8)
        .map(|_| {
            let entry = entry.clone();
            let inside = inside.clone();
            let most = most.clone();
            tokio::spawn(async move {
                with_vault(&entry, move |vault| {
                    let now = inside.fetch_add(1, Ordering::SeqCst) + 1;
                    most.fetch_max(now, Ordering::SeqCst);
                    vault
                        .connection_mut()
                        .execute_batch(
                            "CREATE TABLE IF NOT EXISTS wi72_probe (x);
                             INSERT INTO wi72_probe VALUES (1);",
                        )
                        .map_err(|e| anyhow::anyhow!("write: {e}"))?;
                    std::thread::yield_now();
                    inside.fetch_sub(1, Ordering::SeqCst);
                    Ok(())
                })
                .await
            })
        })
        .collect();
    for t in tasks {
        if t.await.unwrap().is_err() {
            panic!("with_vault failed");
        }
    }
    assert_eq!(most.load(Ordering::SeqCst), 1, "never two at once");
}

#[tokio::test]
async fn with_vault_releases_the_vault_after_a_panicking_closure() {
    let root = tempfile::tempdir().unwrap();
    let id = make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let entry = get_entry(&registry, "work").await;
    let failed: Result<(), _> = with_vault(&entry, |_vault| panic!("wi72 closure panic")).await;
    match failed {
        Ok(()) => panic!("a panicking closure succeeded"),
        Err(e) => assert_eq!(
            reply_of(e.into_response()).await,
            (500, "internal".to_string())
        ),
    }
    let got = with_vault(&entry, |vault| Ok(vault.manifest().vault_id.clone())).await;
    assert_eq!(got.ok(), Some(id), "the vault is usable again");
}

#[test]
fn router_builds_the_root_embedder_only_when_embeddings_are_on_and_none_was_given() {
    let off = tempfile::tempdir().unwrap();
    drop(router(ServerConfig::new(off.path().to_path_buf(), "token")));
    assert!(!off.path().join(".memex").exists(), "embeddings off");

    let given = tempfile::tempdir().unwrap();
    let shared: Arc<dyn Embedder> = Arc::new(FakeEmbedder::new(8));
    drop(router(
        ServerConfig::new(given.path().to_path_buf(), "token")
            .with_embeddings(true)
            .with_embedder(shared),
    ));
    assert!(
        !given.path().join(".memex").exists(),
        "the given embedder wins over building one"
    );

    let on = tempfile::tempdir().unwrap();
    drop(router(
        ServerConfig::new(on.path().to_path_buf(), "token").with_embeddings(true),
    ));
    assert!(
        on.path().join(".memex/models").is_dir(),
        "with_embeddings(true) alone builds build_embedder_in(root)"
    );
}

// ---------------------------------------------------------------------------
// Verify (fix round): an eviction removes only the slot its request saw
// ---------------------------------------------------------------------------

/// `(status, C1 code)` of a `get` that must fail, on `rt`.
fn failed_get(
    rt: &tokio::runtime::Runtime,
    got: Result<Arc<VaultEntry>, memex_mcp::server::error::ApiError>,
    what: &str,
) -> (u16, String) {
    match got {
        Ok(entry) => panic!("{what}: served entry {}", entry.open_id),
        Err(e) => rt.block_on(reply_of(e.into_response())),
    }
}

/// The entry `get(name)` returns, on `rt`.
fn entry_on(rt: &tokio::runtime::Runtime, registry: &Registry, name: &str) -> Arc<VaultEntry> {
    match rt.block_on(registry.get(name)) {
        Ok(entry) => entry,
        Err(e) => panic!("get {name}: {:?}", rt.block_on(reply_of(e.into_response()))),
    }
}

#[test]
fn a_vault_gone_at_its_open_evicts_only_its_own_slot_not_a_later_entry() {
    let rt = one_blocking_thread();
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);

    // A scans and sees the vault, then queues its open, which can't start
    // until the blocking thread is released.
    let mut a = Box::pin(registry.get("work"));
    let held = hold_blocking(&rt);
    assert!(poll_once(&rt, &mut a), "A waits on its scan");
    release(&rt, held);
    let held = hold_blocking(&rt);
    assert!(poll_once(&rt, &mut a), "A waits on its open");
    // The vault is deleted before A's open runs: A's open finds it gone.
    std::fs::remove_dir_all(root.path().join("work")).unwrap();
    release(&rt, held);
    // C scans the empty root and evicts A's slot (the one it saw).
    assert_eq!(
        failed_get(&rt, rt.block_on(registry.get("work")), "C"),
        (404, "vault_not_found".to_string())
    );
    // The vault is recreated and B opens it in a new slot.
    make_vault(root.path(), "work");
    let b = entry_on(&rt, &registry, "work");
    // Only now does A finish: 404, and its eviction must not touch B's slot.
    assert_eq!(
        failed_get(&rt, rt.block_on(a), "A"),
        (404, "vault_not_found".to_string())
    );
    let next = entry_on(&rt, &registry, "work");
    assert!(
        Arc::ptr_eq(&b, &next),
        "A's gone-at-open eviction removed the entry B opened \
         (open_id {} then {}): two connections to one vault",
        b.open_id,
        next.open_id
    );
}

#[test]
fn a_not_found_scan_evicts_only_the_slot_it_saw_not_a_newer_one() {
    let rt = one_blocking_thread();
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    let registry = Registry::new(root.path().to_path_buf(), None);
    let first = entry_on(&rt, &registry, "work");

    // The vault is deleted; L notes the old slot, then scans an empty root.
    std::fs::remove_dir_all(root.path().join("work")).unwrap();
    let mut late = Box::pin(registry.get("work"));
    let held = hold_blocking(&rt);
    assert!(poll_once(&rt, &mut late), "L waits on its scan");
    release(&rt, held);
    // A new vault takes the name; M replaces the old slot with its own.
    make_vault(root.path(), "work");
    let reopened = entry_on(&rt, &registry, "work");
    assert_ne!(reopened.open_id, first.open_id, "M reopened the new vault");
    // L finishes: 404 for what it saw; the slot it saw is already gone.
    assert_eq!(
        failed_get(&rt, rt.block_on(late), "L"),
        (404, "vault_not_found".to_string())
    );
    let next = entry_on(&rt, &registry, "work");
    assert!(
        Arc::ptr_eq(&reopened, &next),
        "L's stale not-found evicted the slot M opened \
         (open_id {} then {}): two connections to one vault",
        reopened.open_id,
        next.open_id
    );
}

#[test]
fn an_open_failure_with_the_vault_files_present_is_500_and_never_404() {
    let rt = one_blocking_thread();
    let root = tempfile::tempdir().unwrap();
    make_vault(root.path(), "work");
    // Both vault files are there, but the manifest is not JSON.
    std::fs::write(root.path().join("work/manifest.json"), b"{ not json").unwrap();
    let registry = Registry::new(root.path().to_path_buf(), None);
    for attempt in 0..2 {
        assert_eq!(
            failed_get(&rt, rt.block_on(registry.get("work")), "corrupt manifest"),
            (500, "internal".to_string()),
            "attempt {attempt}"
        );
    }
    assert!(
        root.path().join("work/memex.db").is_file(),
        "nothing removed"
    );
}
