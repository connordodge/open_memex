//! WI #403 (Spec #394 requirement 43; rulings D6, D22, D39, D40):
//! `memex embeddings status --vault <path>`.
//!
//! Drives the built `memex` binary against temp vaults. The contract: exit 0
//! and one compact JSON line on stdout,
//! `{"server_embeddings": null, "chunks", "embedded", "model_cached", "model_bytes"}`:
//!
//! - `chunks` / `embedded`: K0's `embedding_counts` (orphan vectors excluded,
//!   `embedded` 0 without `chunk_vec`);
//! - `model_cached`: K0's `FastEmbedder::is_cached` on
//!   `model_cache_dir(<vault>)`, which follows `$HF_HOME` when it is set;
//! - `model_bytes`: the size on disk of that same directory
//!   (`FastEmbedder::load_cache_dir(&model_cache_dir(<vault>))`, D40): the
//!   lengths of its regular files, symlinks never followed, 0 when missing,
//!   unreadable entries skipped.
//!
//! Model caches come from K0's `hf_cache_fixture` (never a hand-made file
//! list). Every run removes `HF_HOME` from the child's environment unless the
//! test sets it, and points `HF_ENDPOINT` at a tripwire that counts any
//! download attempt. The help texts are pinned against
//! `tests/golden/help/embeddings*.txt` (D22: `cli_golden.rs` is not edited).

#[path = "support/embeddings_vault.rs"]
mod embeddings_vault;
#[path = "../../memex-core/tests/hf_cache_fixture/mod.rs"]
mod hf_cache_fixture;

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;

use embeddings_vault::{
    build_counted_vault, build_vault_without_chunk_vec, linked_cache_bytes,
    linked_cache_bytes_if_links_followed, plain_cache_bytes,
};
use hf_cache_fixture as fx;
use memex_mcp::state::model_cache_dir;
use serde_json::{json, Value};

// ---------- harness ----------

/// One tripwire for the whole test binary: every child gets `HF_ENDPOINT`
/// pointed at it, so any hf-hub request is counted and fails at once.
fn tripwire() -> &'static fx::Tripwire {
    static T: OnceLock<fx::Tripwire> = OnceLock::new();
    T.get_or_init(fx::Tripwire::start)
}

/// `memex <args>` with `HF_HOME` removed (or set to `hf_home`), `HF_ENDPOINT`
/// at the tripwire, stdin closed and both outputs captured.
fn memex(args: &[&str], hf_home: Option<&Path>) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args)
        .env_remove("HF_HOME")
        .env("HF_ENDPOINT", &tripwire().url)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(home) = hf_home {
        cmd.env("HF_HOME", home);
    }
    cmd
}

fn run(args: &[&str]) -> Output {
    memex(args, None).output().expect("run memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Success: exit 0, an empty stderr, and stdout exactly one JSON line;
/// returns it parsed.
fn ok_json(out: Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty; {}",
        describe(&out)
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let line = stdout
        .strip_suffix('\n')
        .unwrap_or_else(|| panic!("stdout ends with one newline: {stdout:?}"));
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be exactly one JSON line, got {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {stdout}"))
}

/// The C1 failure: exit 1, nothing on stdout, one JSON line on stderr.
/// Returns `(code, message)`.
fn c1_error(out: &Output) -> (String, String) {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a failure exits 1; {}",
        describe(out)
    );
    assert!(
        out.stdout.is_empty(),
        "a failure prints nothing on stdout; {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be one line; {}",
        describe(out)
    );
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)));
    (
        v["error"]["code"].as_str().expect("error.code").to_string(),
        v["error"]["message"]
            .as_str()
            .expect("error.message")
            .to_string(),
    )
}

/// `memex embeddings status --vault <vault>` with `HF_HOME` removed, parsed.
fn status(vault: &Path) -> Value {
    status_with_hf_home(vault, None)
}

fn status_with_hf_home(vault: &Path, hf_home: Option<&Path>) -> Value {
    let out = memex(
        &["embeddings", "status", "--vault", vault.to_str().unwrap()],
        hf_home,
    )
    .output()
    .expect("run memex embeddings status");
    ok_json(out)
}

fn keys_of(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn int(v: &Value, key: &str) -> i64 {
    v[key]
        .as_i64()
        .unwrap_or_else(|| panic!("{key} is a JSON integer: {v}"))
}

fn uint(v: &Value, key: &str) -> u64 {
    v[key]
        .as_u64()
        .unwrap_or_else(|| panic!("{key} is a non-negative JSON integer: {v}"))
}

/// A temp dir holding one vault folder, `<tmp>/vault`.
fn vault_dir() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let vault = tmp.path().join("vault");
    (tmp, vault)
}

// ---------- AC 1: counts, orphans excluded, server_embeddings null ----------

#[test]
fn embeddings_status_reports_chunks_and_joined_vectors_without_orphans() {
    let (_tmp, vault) = vault_dir();
    let built = build_counted_vault(&vault);

    let v = status(&vault);

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
    assert!(
        v.get("server_embeddings").is_some_and(Value::is_null),
        "server_embeddings is present and JSON null on the CLI: {v}"
    );
    assert_eq!(int(&v, "chunks"), built.chunks, "chunks is N: {v}");
    assert_eq!(
        int(&v, "embedded"),
        built.joined,
        "embedded is M, the vectors whose chunk exists; the {} orphans are not counted: {v}",
        built.orphans
    );
    assert_eq!(
        v,
        json!({
            "server_embeddings": null,
            "chunks": built.chunks,
            "embedded": built.joined,
            "model_cached": false,
            "model_bytes": 0,
        }),
        "no model cache in this vault"
    );
}

#[test]
fn embeddings_status_counts_follow_the_vault_it_is_given() {
    // Two vaults with different counts: each run reports its own.
    let (_tmp, a) = vault_dir();
    let built_a = build_counted_vault(&a);
    let b_tmp = tempfile::tempdir().unwrap();
    let b = b_tmp.path().join("other vault");
    let built_b = build_vault_without_chunk_vec(&b);
    assert_ne!(built_a.chunks, built_b.chunks, "fixture: different N");

    let va = status(&a);
    let vb = status(&b);
    assert_eq!(
        (int(&va, "chunks"), int(&va, "embedded")),
        (built_a.chunks, built_a.joined)
    );
    assert_eq!(
        (int(&vb, "chunks"), int(&vb, "embedded")),
        (built_b.chunks, 0)
    );
}

// ---------- AC 2: no chunk_vec ----------

#[test]
fn embeddings_status_without_chunk_vec_reports_zero_embedded_and_exits_0() {
    let (_tmp, vault) = vault_dir();
    let built = build_vault_without_chunk_vec(&vault);

    let v = status(&vault);

    assert_eq!(
        v,
        json!({
            "server_embeddings": null,
            "chunks": built.chunks,
            "embedded": 0,
            "model_cached": false,
            "model_bytes": 0,
        })
    );
}

#[test]
fn embeddings_status_on_an_empty_vault_reports_all_zero() {
    let (_tmp, vault) = vault_dir();
    memex_core::Vault::create(&vault).unwrap();

    let v = status(&vault);

    assert_eq!(
        v,
        json!({
            "server_embeddings": null,
            "chunks": 0,
            "embedded": 0,
            "model_cached": false,
            "model_bytes": 0,
        })
    );
}

// ---------- AC 3: model_cached and model_bytes ----------

#[cfg(unix)]
#[test]
fn embeddings_status_with_a_complete_cache_reports_cached_and_its_size_on_disk() {
    let (_tmp, vault) = vault_dir();
    let built = build_counted_vault(&vault);
    let cache = model_cache_dir(&vault);
    // Exactly as hf-hub writes it: blobs, plus snapshot symlinks to them.
    fx::write_complete_linked(&cache);
    let want = linked_cache_bytes(&cache);
    assert!(want > 0, "fixture: the cache holds bytes");
    let before = fx::tree(&cache);

    let v = status(&vault);

    assert_eq!(v["model_cached"], json!(true), "{v}");
    assert_eq!(
        uint(&v, "model_bytes"),
        want,
        "model_bytes is every blob once plus refs/main; symlinks are not \
         followed (following them would give {})",
        linked_cache_bytes_if_links_followed(&cache)
    );
    assert_eq!(
        v,
        json!({
            "server_embeddings": null,
            "chunks": built.chunks,
            "embedded": built.joined,
            "model_cached": true,
            "model_bytes": want,
        })
    );
    assert_eq!(fx::tree(&cache), before, "the cache was left as it was");
}

#[test]
fn embeddings_status_with_a_plain_file_cache_counts_every_file() {
    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let cache = model_cache_dir(&vault);
    fx::write_complete(&cache);
    let want = plain_cache_bytes(&cache);

    let v = status(&vault);

    assert_eq!(v["model_cached"], json!(true), "{v}");
    assert_eq!(uint(&v, "model_bytes"), want, "{v}");
}

#[test]
fn embeddings_status_model_bytes_sums_every_regular_file_at_any_depth() {
    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let cache = model_cache_dir(&vault);
    fx::write_complete(&cache);
    let complete = plain_cache_bytes(&cache);

    // Files outside the model repo, at the top and nested deep, count too:
    // the size is the whole directory's.
    fs::write(cache.join("top.bin"), vec![7u8; 1000]).unwrap();
    let deep = cache.join("a").join("b").join("c");
    fs::create_dir_all(&deep).unwrap();
    fs::write(deep.join("deep.bin"), vec![1u8; 2345]).unwrap();
    fs::write(deep.join("empty.bin"), b"").unwrap();

    let v = status(&vault);

    assert_eq!(v["model_cached"], json!(true), "{v}");
    assert_eq!(uint(&v, "model_bytes"), complete + 1000 + 2345, "{v}");
}

#[test]
fn embeddings_status_without_a_cache_reports_false_and_zero() {
    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let cache = model_cache_dir(&vault);
    assert!(!cache.exists(), "fixture: no cache dir");

    let v = status(&vault);
    assert_eq!(v["model_cached"], json!(false), "{v}");
    assert_eq!(uint(&v, "model_bytes"), 0, "{v}");

    // An empty cache dir is no cache either, and holds no bytes.
    fs::create_dir_all(&cache).unwrap();
    let v = status(&vault);
    assert_eq!(v["model_cached"], json!(false), "{v}");
    assert_eq!(uint(&v, "model_bytes"), 0, "{v}");
}

#[test]
fn embeddings_status_with_a_partial_cache_reports_not_cached_and_its_bytes() {
    let files = fx::required_files();
    for missing in &files {
        let (_tmp, vault) = vault_dir();
        build_vault_without_chunk_vec(&vault);
        let cache = model_cache_dir(&vault);
        fx::write_complete(&cache);
        fs::remove_file(fx::snapshot_file(&cache, missing)).unwrap();
        let want = plain_cache_bytes_without(&cache, missing);
        assert!(want > 0, "fixture: the partial cache holds bytes");

        let v = status(&vault);

        assert_eq!(
            v["model_cached"],
            json!(false),
            "a cache without {missing} reads not cached: {v}"
        );
        assert_eq!(
            uint(&v, "model_bytes"),
            want,
            "the partial cache's bytes are still its size on disk: {v}"
        );
    }
}

fn plain_cache_bytes_without(cache: &Path, missing: &str) -> u64 {
    let files: u64 = fx::required_files()
        .iter()
        .filter(|f| f.as_str() != missing)
        .map(|f| fs::metadata(fx::snapshot_file(cache, f)).unwrap().len())
        .sum();
    files
        + fs::metadata(embeddings_vault::ref_file(cache))
            .unwrap()
            .len()
}

#[cfg(unix)]
#[test]
fn embeddings_status_with_an_unfinished_download_reports_not_cached() {
    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let cache = model_cache_dir(&vault);
    let files = fx::required_files();
    let (model_file, rest) = files.split_first().unwrap();
    for f in rest {
        fx::write_linked_file(&cache, f);
    }
    fx::write_ref(&cache, fx::COMMIT);
    let blob = fx::blob_path(&cache, &fx::etag_for(model_file));
    fs::write(blob.with_extension("part"), vec![3u8; 4096]).unwrap();
    fs::write(blob.with_extension("lock"), b"").unwrap();
    let finished: u64 = rest
        .iter()
        .map(|f| {
            fs::metadata(fx::blob_path(&cache, &fx::etag_for(f)))
                .unwrap()
                .len()
        })
        .sum();
    let refs = fs::metadata(embeddings_vault::ref_file(&cache))
        .unwrap()
        .len();

    let v = status(&vault);

    assert_eq!(
        v["model_cached"],
        json!(false),
        "{model_file} still downloading reads not cached: {v}"
    );
    assert_eq!(
        uint(&v, "model_bytes"),
        finished + refs + 4096,
        "the finished blobs, refs/main and the .part bytes: {v}"
    );
}

#[cfg(unix)]
#[test]
fn embeddings_status_model_bytes_never_follows_a_symlink_out_of_the_cache() {
    let (tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let cache = model_cache_dir(&vault);
    fx::write_complete_linked(&cache);
    let want = linked_cache_bytes(&cache);

    // A directory and a file outside the cache, linked from inside it, and a
    // dangling link: none of their bytes are the cache's.
    let outside = tmp.path().join("outside");
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("big.bin"), vec![9u8; 50_000]).unwrap();
    std::os::unix::fs::symlink(&outside, cache.join("dir-link")).unwrap();
    std::os::unix::fs::symlink(outside.join("big.bin"), cache.join("file-link")).unwrap();
    std::os::unix::fs::symlink(tmp.path().join("nowhere"), cache.join("dangling")).unwrap();

    let v = status(&vault);

    assert_eq!(v["model_cached"], json!(true), "{v}");
    assert_eq!(
        uint(&v, "model_bytes"),
        want,
        "symlinks add nothing, whatever they point at: {v}"
    );
}

#[cfg(unix)]
#[test]
fn embeddings_status_skips_an_unreadable_entry_instead_of_failing() {
    use std::os::unix::fs::PermissionsExt;

    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let cache = model_cache_dir(&vault);
    fx::write_complete(&cache);
    let complete = plain_cache_bytes(&cache);

    let locked = cache.join("locked");
    fs::create_dir_all(&locked).unwrap();
    fs::write(locked.join("hidden.bin"), vec![5u8; 777]).unwrap();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    struct Unlock(PathBuf);
    impl Drop for Unlock {
        fn drop(&mut self) {
            let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
        }
    }
    let _unlock = Unlock(locked.clone());
    // Running as root reads it anyway; then its bytes count like any other.
    let readable = fs::read_dir(&locked).is_ok();

    let v = status(&vault);

    assert_eq!(v["model_cached"], json!(true), "{v}");
    let want = if readable { complete + 777 } else { complete };
    assert_eq!(
        uint(&v, "model_bytes"),
        want,
        "the unreadable folder is skipped, the rest is counted: {v}"
    );
}

#[test]
fn embeddings_status_with_hf_home_set_reads_cache_and_size_from_hf_home() {
    let (tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);

    // The model is complete under HF_HOME; the vault's own cache is missing.
    let hf_home = tmp.path().join("hf-home");
    fx::write_complete(&hf_home);
    let want = plain_cache_bytes(&hf_home);
    let v = status_with_hf_home(&vault, Some(&hf_home));
    assert_eq!(v["model_cached"], json!(true), "HF_HOME is checked: {v}");
    assert_eq!(
        uint(&v, "model_bytes"),
        want,
        "HF_HOME is measured, the same dir is_cached checks: {v}"
    );
    assert!(
        !model_cache_dir(&vault).exists(),
        "the vault's cache dir is not created"
    );

    // The other way round: the vault's cache is complete, HF_HOME is empty.
    fx::write_complete(&model_cache_dir(&vault));
    let empty_home = tmp.path().join("empty-home");
    fs::create_dir_all(&empty_home).unwrap();
    let v = status_with_hf_home(&vault, Some(&empty_home));
    assert_eq!(
        v["model_cached"],
        json!(false),
        "the vault cache does not count while HF_HOME is set: {v}"
    );
    assert_eq!(
        uint(&v, "model_bytes"),
        0,
        "nor do its bytes: HF_HOME is empty: {v}"
    );

    // HF_HOME naming a folder that does not exist: 0, and still not created.
    let missing_home = tmp.path().join("no-such-home");
    let v = status_with_hf_home(&vault, Some(&missing_home));
    assert_eq!(v["model_cached"], json!(false), "{v}");
    assert_eq!(uint(&v, "model_bytes"), 0, "{v}");
    assert!(!missing_home.exists(), "HF_HOME is never created");

    // Control: HF_HOME unset, the vault's own cache is measured.
    let v = status(&vault);
    assert_eq!(v["model_cached"], json!(true), "{v}");
    assert_eq!(
        uint(&v, "model_bytes"),
        plain_cache_bytes(&model_cache_dir(&vault)),
        "{v}"
    );
}

// ---------- AC 4: no cache dir, no model ----------

#[test]
fn embeddings_status_never_creates_the_cache_dir_or_builds_an_embedder() {
    let (_tmp, vault) = vault_dir();
    let built = build_counted_vault(&vault);
    let cache = model_cache_dir(&vault);
    assert!(!cache.exists(), "fixture: no cache dir");
    let hits = tripwire().hits();

    let v = status(&vault);

    assert_eq!(int(&v, "chunks"), built.chunks, "{v}");
    assert_eq!(v["model_cached"], json!(false), "{v}");
    // `build_embedder_in` creates <vault>/.memex/models, so the dir still
    // being absent shows no embedder was built.
    assert!(
        !cache.exists(),
        "memex embeddings status created {cache:?}: it built an embedder"
    );
    assert_eq!(
        tripwire().hits(),
        hits,
        "no model download was attempted (HF_ENDPOINT tripwire)"
    );
}

#[test]
fn embeddings_status_never_loads_the_cached_model() {
    // The fixture's model files are fake: loading them fails. A complete
    // cache still reads cached, the command still exits 0, and nothing in
    // the cache changes.
    let (_tmp, vault) = vault_dir();
    let built = build_counted_vault(&vault);
    let cache = model_cache_dir(&vault);
    fx::write_complete(&cache);
    let before = fx::tree(&cache);
    let before_bytes = plain_cache_bytes(&cache);
    let hits = tripwire().hits();

    let v = status(&vault);

    assert_eq!(v["model_cached"], json!(true), "{v}");
    assert_eq!(int(&v, "embedded"), built.joined, "{v}");
    assert_eq!(uint(&v, "model_bytes"), before_bytes, "{v}");
    assert_eq!(fx::tree(&cache), before, "the cache is untouched");
    assert_eq!(plain_cache_bytes(&cache), before_bytes);
    assert_eq!(tripwire().hits(), hits, "no download attempted");
}

#[test]
fn embeddings_status_writes_nothing_to_the_vault() {
    let (_tmp, vault) = vault_dir();
    let built = build_counted_vault(&vault);
    let before = fx::tree(&vault);

    let first = status(&vault);
    let second = status(&vault);

    assert_eq!(first, second, "a read: the same answer twice");
    assert_eq!(int(&first, "embedded"), built.joined);
    let after = fx::tree(&vault);
    let created: Vec<&PathBuf> = after.iter().filter(|p| !before.contains(p)).collect();
    assert!(
        created
            .iter()
            .all(|p| !p.starts_with(Path::new(".memex").join("models"))),
        "nothing under .memex/models: {created:?}"
    );
}

// ---------- errors and output ----------

#[test]
fn embeddings_status_on_a_path_that_is_not_a_vault_gives_the_existing_vault_error_code() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("nope");
    // Control: a real vault answers.
    let (_vtmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    ok_json(run(&[
        "embeddings",
        "status",
        "--vault",
        vault.to_str().unwrap(),
    ]));

    for path in [dir.path().to_str().unwrap(), missing.to_str().unwrap()] {
        let (want, _) = c1_error(&run(&["tag", "ls", "--vault", path]));
        let (code, message) = c1_error(&run(&["embeddings", "status", "--vault", path]));
        assert_eq!(code, want, "{path}: {message}");
    }
    assert!(!missing.exists(), "a failed status creates no vault");
    assert!(
        !model_cache_dir(dir.path()).exists(),
        "a failed status creates no cache dir"
    );
}

#[test]
fn embeddings_status_takes_only_a_vault_argument() {
    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let path = vault.to_str().unwrap();
    // Control.
    ok_json(run(&["embeddings", "status", "--vault", path]));

    for args in [
        vec!["embeddings", "status"],
        vec!["embeddings", "status", "--vault", path, "--json"],
        vec!["embeddings", "status", "--vault", path, "extra"],
        vec!["embeddings"],
        vec!["embeddings", "nope", "--vault", path],
    ] {
        let out = run(&args);
        assert_eq!(
            out.status.code(),
            Some(2),
            "memex {} is a clap usage error; {}",
            args.join(" "),
            describe(&out)
        );
        assert!(out.stdout.is_empty(), "{}", describe(&out));
    }
}

#[test]
fn embeddings_status_with_a_closed_stdout_exits_0_and_prints_no_error() {
    // A reader that went away is not an error (Spec #315 req 17a): the
    // command still exits 0 with nothing on stderr, never a panic.
    let (_tmp, vault) = vault_dir();
    build_vault_without_chunk_vec(&vault);
    let (reader, writer) = std::io::pipe().expect("pipe");
    drop(reader);
    let out = memex(
        &["embeddings", "status", "--vault", vault.to_str().unwrap()],
        None,
    )
    .stdout(writer)
    .output()
    .expect("run memex embeddings status");
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
}

// ---------- AC 5: help (D22) ----------

fn golden(file: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/help")
        .join(format!("{file}.txt"));
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn embeddings_help_texts_match_their_goldens() {
    let mut mismatches = Vec::new();
    for (args, file) in [
        ("embeddings", "embeddings"),
        ("embeddings status", "embeddings_status"),
    ] {
        let mut argv: Vec<&str> = args.split(' ').collect();
        argv.push("--help");
        let out = run(&argv);
        assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
        let got = String::from_utf8(out.stdout).unwrap();
        let want = golden(file);
        if got != want {
            mismatches.push(format!(
                "memex {args} --help\n--- golden\n{want}--- got\n{got}"
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn top_level_help_lists_embeddings_after_restore_and_before_serve() {
    let out = run(&["--help"]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    let help = String::from_utf8(out.stdout).unwrap();
    let rows: Vec<&str> = help
        .lines()
        .map(str::trim_start)
        .filter(|l| {
            l.starts_with("restore ") || l.starts_with("embeddings ") || l.starts_with("serve ")
        })
        .map(|l| l.split_whitespace().next().unwrap())
        .collect();
    assert_eq!(rows, ["restore", "embeddings", "serve"], "{help}");
}
