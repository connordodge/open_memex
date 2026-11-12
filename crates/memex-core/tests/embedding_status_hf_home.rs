//! #417: `FastEmbedder::is_cached` checks the directory fastembed's loader
//! reads. fastembed's `pull_from_hf` replaces the cache dir it is given with
//! the raw `$HF_HOME` whenever that is set, so `is_cached` must follow
//! `HF_HOME` too: answering for the vault cache instead would let the
//! `model_not_downloaded` consent gate pass while the load downloads.
//! (`hf_cache_fixture_sdk.rs` pins the fastembed side against the real SDK.)
//!
//! Own test binary: it sets a process-global env var, which would race the
//! other `embedding_status` tests if they shared a process. The tests here
//! take `ENV_LOCK` for the same reason.

mod hf_cache_fixture;

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use hf_cache_fixture as fx;
use memex_core::embedder::FastEmbedder;

static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Runs `f` with `HF_HOME` set to `value` (unset when `None`), and leaves it
/// unset afterwards even when `f` panics.
fn with_hf_home(value: Option<&OsStr>, f: impl FnOnce()) {
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            std::env::remove_var("HF_HOME");
        }
    }
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _reset = Reset;
    match value {
        Some(v) => std::env::set_var("HF_HOME", v),
        None => std::env::remove_var("HF_HOME"),
    }
    f();
}

fn empty_dir(parent: &Path, name: &str) -> PathBuf {
    let d = parent.join(name);
    fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn is_cached_follows_hf_home_when_it_is_set() {
    let tmp = tempfile::tempdir().unwrap();
    let vault_cache = empty_dir(tmp.path(), "vault-models");

    // The model is complete under HF_HOME; the vault's own cache dir is
    // empty. fastembed loads from HF_HOME offline, so this reads true.
    let hf_home = empty_dir(tmp.path(), "hf-home");
    fx::write_complete(&hf_home);
    with_hf_home(Some(hf_home.as_os_str()), || {
        assert!(
            FastEmbedder::is_cached(&vault_cache),
            "a complete model under HF_HOME is what fastembed loads"
        );
    });

    // The other way round: the vault's cache is complete, HF_HOME is empty.
    // fastembed would download into HF_HOME, so this reads false.
    let empty_home = empty_dir(tmp.path(), "empty-home");
    let full_vault = empty_dir(tmp.path(), "full-vault");
    fx::write_complete(&full_vault);
    with_hf_home(Some(empty_home.as_os_str()), || {
        assert!(
            !FastEmbedder::is_cached(&full_vault),
            "the vault's complete cache does not count while HF_HOME is set and empty"
        );
    });

    // Control: the same vault cache reads true once HF_HOME is unset.
    with_hf_home(None, || {
        assert!(
            FastEmbedder::is_cached(&full_vault),
            "control: HF_HOME unset, the vault cache is the one checked"
        );
    });
}

#[test]
fn is_cached_reads_raw_hf_home_not_its_hub_subdir() {
    let tmp = tempfile::tempdir().unwrap();
    let vault_cache = empty_dir(tmp.path(), "vault-models");

    // pull_from_hf passes $HF_HOME itself to hf-hub as the cache dir, so a
    // model that sits only under $HF_HOME/hub (the `huggingface_hub` Python
    // layout) is not where fastembed looks.
    let hf_home = empty_dir(tmp.path(), "hf-home");
    fx::write_complete(&hf_home.join("hub"));
    with_hf_home(Some(hf_home.as_os_str()), || {
        assert!(
            !FastEmbedder::is_cached(&vault_cache),
            "a model only under HF_HOME/hub is not found by fastembed"
        );
    });
}

#[cfg(unix)]
#[test]
fn is_cached_uses_cache_dir_when_hf_home_is_not_unicode() {
    use std::os::unix::ffi::OsStrExt;

    let tmp = tempfile::tempdir().unwrap();
    let full_vault = empty_dir(tmp.path(), "full-vault");
    fx::write_complete(&full_vault);
    let empty_vault = empty_dir(tmp.path(), "empty-vault");

    // `env::var` fails on a non-UTF-8 value, so fastembed's `pull_from_hf`
    // keeps the cache dir it was given; the check must do the same.
    let weird = OsStr::from_bytes(b"/nonexistent/\xff\xfe-hf-home");
    with_hf_home(Some(weird), || {
        assert!(
            FastEmbedder::is_cached(&full_vault),
            "non-UTF-8 HF_HOME is ignored, as fastembed ignores it"
        );
        assert!(
            !FastEmbedder::is_cached(&empty_vault),
            "and the cache dir's own contents still decide"
        );
    });
}
