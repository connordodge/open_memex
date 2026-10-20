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
use memex_mcp::server::registry::{validate_vault_name, Registry, VaultEntry};
use memex_mcp::server::request_clock::{BaseClock, RequestClock, SharedClock};
use memex_mcp::server::ServerConfig;
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
    assert_eq!(manifest_version, 5, "migrated on open");
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
