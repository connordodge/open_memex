//! WI #446 (Spec #390), review r3: the HTTP server and the stdio server share
//! ONE SIGINT/SIGTERM handler, `server::shutdown_signal`. `cli/serve.rs` once
//! kept a private copy (#445); removing it changes no behaviour, so the
//! behaviour tests (the real-binary SIGTERM and SIGINT tests in
//! `presence_stdio.rs` and `server_backup.rs`) can't see a copy come back.
//! These are hygiene tests over the crate's own source.

use std::fs;
use std::path::{Path, PathBuf};

use regex::Regex;

/// Every `.rs` file under `crates/memex-mcp/src`, as (path relative to
/// `src`, contents).
fn sources() -> Vec<(String, String)> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    walk(&src, &mut files);
    assert!(files.len() > 10, "found the crate's sources: {files:?}");
    files
        .into_iter()
        .map(|p| {
            let rel = p
                .strip_prefix(&src)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            (rel, fs::read_to_string(&p).unwrap())
        })
        .collect()
}

#[test]
fn shutdown_signal_is_defined_once_in_server_mod_and_visible_to_the_crate() {
    let def =
        Regex::new(r"(?m)^\s*(pub(\([a-z]+\))?\s+)?(async\s+)?fn\s+shutdown_signal\b").unwrap();
    let defs: Vec<(String, String)> = sources()
        .into_iter()
        .flat_map(|(path, text)| {
            def.find_iter(&text)
                .map(|m| (path.clone(), m.as_str().trim().to_string()))
                .collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(
        defs,
        vec![(
            "server/mod.rs".to_string(),
            "pub(crate) async fn shutdown_signal".to_string()
        )],
        "one shutdown_signal, in server/mod.rs, pub(crate) so cli/serve.rs can call it"
    );
}

#[test]
fn only_the_shared_shutdown_signal_listens_for_process_signals() {
    // A private copy under another name still has to reach for these.
    let listeners: Vec<String> = sources()
        .into_iter()
        .flat_map(|(path, text)| {
            ["tokio::signal::ctrl_c", "SignalKind::terminate"]
                .into_iter()
                .map(move |needle| (path.clone(), needle, text.matches(needle).count()))
                .filter(|(_, _, n)| *n > 0)
                .map(|(path, needle, n)| format!("{path}: {needle} x{n}"))
                .collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(
        listeners,
        vec![
            "server/mod.rs: tokio::signal::ctrl_c x1".to_string(),
            "server/mod.rs: SignalKind::terminate x1".to_string(),
        ],
        "SIGINT and SIGTERM are awaited in exactly one place"
    );
}

#[test]
fn the_stdio_server_waits_on_the_shared_shutdown_signal() {
    let serve = sources()
        .into_iter()
        .find(|(path, _)| path == "cli/serve.rs")
        .expect("cli/serve.rs")
        .1;
    assert!(
        serve.contains("server::shutdown_signal()"),
        "cli/serve.rs hands server::shutdown_signal() to the stdio server"
    );
    assert!(
        !serve.contains("fn shutdown_signal"),
        "cli/serve.rs keeps no private copy"
    );
}
