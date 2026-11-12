//! #417 AC 5 (Spec #391, ruling D6): `model_cache_dir(root)` is
//! `<root>/.memex/models`, and it is the one place that path is joined:
//! `build_embedder_in`, `memex echoes` and #394's status all go through it.

use std::fs;
use std::path::{Path, PathBuf};

use memex_mcp::state::{build_embedder_in, model_cache_dir};

#[test]
fn model_cache_dir_is_root_dot_memex_models() {
    for root in ["/vaults/alpha", "relative/root", "/vaults/My Vault ü", "."] {
        let root = Path::new(root);
        assert_eq!(
            model_cache_dir(root),
            root.join(".memex").join("models"),
            "root {root:?}"
        );
    }

    let tmp = tempfile::tempdir().unwrap();
    let root: PathBuf = tmp.path().join(format!("vault-{}", std::process::id()));
    fs::create_dir(&root).unwrap();
    let dir = model_cache_dir(&root);
    assert_eq!(dir, root.join(".memex/models"));
    assert!(dir.starts_with(&root), "{dir:?} is under its root");
    // A path, not a side effect: status callers (#394) must not create it.
    assert_eq!(
        fs::read_dir(&root).unwrap().count(),
        0,
        "model_cache_dir creates nothing under the root"
    );
}

#[test]
fn build_embedder_in_creates_model_cache_dir() {
    let root = tempfile::tempdir().unwrap();
    let _embedder = build_embedder_in(root.path());
    let dir = model_cache_dir(root.path());
    assert_eq!(dir, root.path().join(".memex").join("models"));
    assert!(dir.is_dir(), "build_embedder_in created {dir:?}");
    assert_eq!(fs::read_dir(&dir).unwrap().count(), 0, "nothing downloaded");
}

/// Code lines (comments dropped) of every non-test source file in both
/// crates, as (path, line) pairs.
fn source_lines() -> Vec<(PathBuf, String)> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        for e in fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else if p.extension().is_some_and(|x| x == "rs") {
                out.push(p);
            }
        }
    }
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = Vec::new();
    walk(&crates.join("memex-core/src"), &mut files);
    walk(&crates.join("memex-mcp/src"), &mut files);
    assert!(
        files.len() > 20,
        "found the crates' sources: {}",
        files.len()
    );
    let mut out = Vec::new();
    for f in files {
        for line in fs::read_to_string(&f).unwrap().lines() {
            let code = line.split("//").next().unwrap_or("");
            out.push((f.clone(), code.to_string()));
        }
    }
    out
}

/// The body of `fn <name>(` in `src`, up to the first line that is a bare `}`.
fn fn_body<'a>(src: &'a str, name: &str) -> &'a str {
    let start = src
        .find(&format!("fn {name}("))
        .unwrap_or_else(|| panic!("fn {name} exists"));
    let rest = &src[start..];
    let end = rest.find("\n}\n").expect("fn body ends");
    &rest[..end]
}

#[test]
fn memex_models_path_is_joined_only_in_model_cache_dir() {
    let joins: Vec<_> = source_lines()
        .into_iter()
        .filter(|(_, code)| code.contains("\"models\"") || code.contains(".memex/models"))
        .collect();
    assert_eq!(
        joins.len(),
        1,
        "exactly one `.memex/models` join in non-test code: {joins:#?}"
    );

    let state = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/state.rs")).unwrap();
    let model_cache_dir_body = fn_body(&state, "model_cache_dir");
    assert!(
        model_cache_dir_body.contains("\"models\"")
            || model_cache_dir_body.contains(".memex/models"),
        "the one join is in model_cache_dir: {joins:#?}"
    );
    let build_body = fn_body(&state, "build_embedder_in");
    assert!(
        build_body.contains("model_cache_dir("),
        "build_embedder_in builds its cache path through model_cache_dir:\n{build_body}"
    );
}
