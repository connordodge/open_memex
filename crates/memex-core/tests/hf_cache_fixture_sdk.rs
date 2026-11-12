//! #417: the `hf_cache_fixture` layouts checked against the real SDKs, so an
//! hf-hub or fastembed upgrade that changes the cache layout fails here
//! instead of leaving `FastEmbedder::is_cached` reading a stale layout.
//!
//! These guard the fixtures, not `is_cached`, so they pass on main and are
//! not mapped to an AC. They live in their own test binary because the
//! fastembed check makes network attempts to its tripwire, and
//! `embedding_status.rs` asserts its own tripwire sees none.

mod hf_cache_fixture;

use std::fs;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use hf_cache_fixture as fx;
use memex_core::embedder::FastEmbedder;

/// The fastembed tests set process-global env vars (`HF_ENDPOINT`,
/// `HF_HOME`); they hold this lock for their whole body.
static ENV_LOCK: Mutex<()> = Mutex::new(());

fn env_lock() -> MutexGuard<'static, ()> {
    ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn hf_hub_finds(cache_dir: &Path, file: &str) -> bool {
    hf_hub::Cache::new(cache_dir.to_path_buf())
        .model(fx::model_code())
        .get(file)
        .is_some()
}

#[test]
fn fixture_layouts_match_hf_hub_cache_lookup() {
    let files = fx::required_files();

    let plain = tempfile::tempdir().unwrap();
    fx::write_complete(plain.path());
    for f in &files {
        assert!(
            hf_hub_finds(plain.path(), f),
            "plain fixture: hf-hub finds {f}"
        );
    }

    #[cfg(unix)]
    {
        let linked = tempfile::tempdir().unwrap();
        fx::write_complete_linked(linked.path());
        for f in &files {
            assert!(
                hf_hub_finds(linked.path(), f),
                "linked fixture: hf-hub finds {f}"
            );
        }
        // A dangling pointer is a miss for hf-hub too (it would download).
        fs::remove_file(fx::blob_path(linked.path(), &fx::etag_for(&files[0]))).unwrap();
        assert!(
            !hf_hub_finds(linked.path(), &files[0]),
            "dangling pointer is a miss"
        );
    }

    // One file removed: hf-hub misses exactly that one.
    let partial = tempfile::tempdir().unwrap();
    fx::write_complete(partial.path());
    fs::remove_file(fx::snapshot_file(partial.path(), &files[1])).unwrap();
    assert!(!hf_hub_finds(partial.path(), &files[1]));
    assert!(hf_hub_finds(partial.path(), &files[0]));

    // No refs/main: hf-hub misses everything.
    let no_ref = tempfile::tempdir().unwrap();
    fx::write_snapshot_files(no_ref.path(), fx::COMMIT, &files);
    for f in &files {
        assert!(!hf_hub_finds(no_ref.path(), f), "no ref: hf-hub misses {f}");
    }
}

fn try_load(cache_dir: &Path) -> Result<(), String> {
    let dir = cache_dir.to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let r = fastembed::TextEmbedding::try_new(
            fastembed::InitOptions::new(fastembed::EmbeddingModel::BGESmallENV15)
                .with_cache_dir(dir)
                .with_show_download_progress(false),
        )
        .map(|_| ())
        .map_err(|e| format!("{e:#}"));
        tx.send(r).unwrap();
    });
    // Hang guard only.
    rx.recv_timeout(Duration::from_secs(120))
        .expect("fastembed returned (hang guard)")
}

#[test]
fn fastembed_resolves_the_fixture_model_files_without_network() {
    let _env = env_lock();
    let wire = fx::Tripwire::start();
    std::env::set_var("HF_ENDPOINT", &wire.url);
    std::env::remove_var("HF_HOME");

    // Complete: fastembed finds every model-info file locally and only then
    // fails, on the fake onnx bytes. No request reached the endpoint.
    let complete = tempfile::tempdir().unwrap();
    fx::write_complete(complete.path());
    let err = try_load(complete.path()).expect_err("fake onnx bytes never load");
    assert_eq!(
        wire.hits(),
        0,
        "complete fixture: no download attempt ({err})"
    );
    assert!(
        !err.contains("Failed to retrieve") && err.contains(&fx::required_files()[0]),
        "it got as far as loading the cached model file: {err}"
    );

    // Model file missing: fastembed goes to the endpoint for it.
    let partial = tempfile::tempdir().unwrap();
    fx::write_complete(partial.path());
    fs::remove_file(fx::snapshot_file(partial.path(), &fx::required_files()[0])).unwrap();
    let perr = try_load(partial.path()).expect_err("the tripwire serves nothing");
    assert!(
        perr.contains("Failed to retrieve"),
        "a retrieve error: {perr}"
    );
    assert!(
        wire.hits() > 0,
        "partial fixture: fastembed tried to download ({perr})"
    );
}

#[test]
fn fastembed_reads_every_file_the_fixture_names_and_no_other() {
    let _env = env_lock();
    let wire = fx::Tripwire::start();
    std::env::set_var("HF_ENDPOINT", &wire.url);
    std::env::remove_var("HF_HOME");

    // With a model onnxruntime loads, fastembed goes on to fetch the four
    // tokenizer files. Complete fixture: it finds them all locally (no
    // request), then fails parsing the fake tokenizer bytes.
    let complete = tempfile::tempdir().unwrap();
    fx::write_complete_loadable(complete.path());
    let err = try_load(complete.path()).expect_err("fake tokenizer bytes never load");
    assert_eq!(
        wire.hits(),
        0,
        "complete fixture: fastembed asked for a file the fixture does not name ({err})"
    );
    assert!(
        !err.contains("Failed to retrieve"),
        "it got past every file fetch: {err}"
    );

    // Each named file (model file, additional files, each tokenizer file) is
    // one fastembed really fetches: without it, fastembed goes to the
    // endpoint. So TOKENIZER_FILES cannot drift from fastembed unnoticed.
    for missing in fx::required_files() {
        let dir = tempfile::tempdir().unwrap();
        fx::write_complete_loadable(dir.path());
        fs::remove_file(fx::snapshot_file(dir.path(), &missing)).unwrap();
        let before = wire.hits();
        let err = try_load(dir.path()).expect_err("the tripwire serves nothing");
        assert!(
            wire.hits() > before,
            "without {missing} fastembed tried to download it ({err})"
        );
    }
}

#[test]
fn fastembed_loads_from_hf_home_ahead_of_the_given_cache_dir() {
    let _env = env_lock();
    let wire = fx::Tripwire::start();
    std::env::set_var("HF_ENDPOINT", &wire.url);

    // HF_HOME complete, the cache dir fastembed is given empty: it loads
    // from HF_HOME, so no request. is_cached agrees with the loader.
    let home = tempfile::tempdir().unwrap();
    fx::write_complete_loadable(home.path());
    let empty_dir = tempfile::tempdir().unwrap();
    std::env::set_var("HF_HOME", home.path());
    let err = try_load(empty_dir.path()).expect_err("fake tokenizer bytes never load");
    assert_eq!(
        wire.hits(),
        0,
        "HF_HOME holds the model: no download ({err})"
    );
    assert!(
        FastEmbedder::is_cached(empty_dir.path()),
        "is_cached agrees with the loader: HF_HOME complete reads cached"
    );

    // HF_HOME empty, the given cache dir complete: fastembed ignores the
    // given dir and goes to the endpoint. is_cached agrees: not cached.
    let empty_home = tempfile::tempdir().unwrap();
    let full_dir = tempfile::tempdir().unwrap();
    fx::write_complete_loadable(full_dir.path());
    std::env::set_var("HF_HOME", empty_home.path());
    let before = wire.hits();
    let err = try_load(full_dir.path()).expect_err("the tripwire serves nothing");
    assert!(
        wire.hits() > before,
        "HF_HOME empty: fastembed downloads despite the complete cache dir ({err})"
    );
    assert!(
        !FastEmbedder::is_cached(full_dir.path()),
        "is_cached agrees with the loader: HF_HOME empty reads not cached"
    );
    std::env::remove_var("HF_HOME");
}
