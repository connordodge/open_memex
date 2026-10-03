//! WI #3 (architect D2): `chrono` (with local-time support) and `strsim` are
//! direct dependencies of memex-core, resolved to the versions already locked.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn chrono_local_now_is_usable_from_memex_core_tests() {
    let now = chrono::Local::now();
    let sys = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    assert!(
        (now.timestamp() - sys).abs() <= 5,
        "chrono::Local::now() = {now}, system clock = {sys}"
    );
}

#[test]
fn strsim_normalized_levenshtein_is_usable_from_memex_core_tests() {
    let s = strsim::normalized_levenshtein("abc", "abd");
    assert!((s - 2.0 / 3.0).abs() < 1e-9, "normalized_levenshtein = {s}");
    assert!((strsim::normalized_levenshtein("Games", "Games") - 1.0).abs() < 1e-9);
}

/// `[[package]]` entries of the workspace Cargo.lock as (name, version, deps).
fn lock_packages() -> Vec<(String, String, Vec<String>)> {
    let lock =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Cargo.lock"))
            .expect("read workspace Cargo.lock");
    lock.split("[[package]]")
        .skip(1)
        .map(|block| {
            let field = |key: &str| {
                block
                    .lines()
                    .find_map(|l| l.strip_prefix(&format!("{key} = \"")))
                    .map(|v| v.trim_end_matches('"').to_string())
                    .unwrap_or_default()
            };
            let deps = block
                .split_once("dependencies = [")
                .map(|(_, rest)| {
                    rest.split(']')
                        .next()
                        .unwrap_or("")
                        .lines()
                        .filter_map(|l| {
                            let l = l.trim().trim_end_matches(',').trim_matches('"');
                            l.split_whitespace().next().map(str::to_string)
                        })
                        .collect()
                })
                .unwrap_or_default();
            (field("name"), field("version"), deps)
        })
        .collect()
}

#[test]
fn chrono_and_strsim_resolve_to_the_locked_versions() {
    let pkgs = lock_packages();
    let core = pkgs
        .iter()
        .find(|(n, _, _)| n == "memex-core")
        .expect("memex-core in Cargo.lock");
    for dep in ["chrono", "strsim"] {
        assert!(
            core.2.iter().any(|d| d == dep),
            "memex-core does not depend on {dep}: {:?}",
            core.2
        );
    }
    let versions = |name: &str| -> Vec<&str> {
        pkgs.iter()
            .filter(|(n, _, _)| n == name)
            .map(|(_, v, _)| v.as_str())
            .collect()
    };
    assert_eq!(
        versions("chrono"),
        ["0.4.44"],
        "exactly one chrono, the locked one"
    );
    assert_eq!(
        versions("strsim"),
        ["0.11.1"],
        "exactly one strsim, the locked one"
    );
}
