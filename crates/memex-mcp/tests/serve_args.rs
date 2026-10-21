//! WI #71 (R0a): `memex serve` modes (req 6, 7; D3).
//!
//! - AC 1: `memex serve --vault <path>` is unchanged: stdio MCP serving the
//!   same 26 tools, logging to `<vault>/.memex/mcp.log*`.
//! - AC 2: flags from different modes, a missing mode and any token flag are
//!   clap usage errors (exit 2) that bind and create nothing. What `--remote
//!   <url>` alone does is #95's (`tests/serve_remote.rs`).

#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use memex_core::Vault;
use serde_json::{json, Value};

use server::{free_port, ServeCommand, TOKEN_ENV};

/// The tools stdio `memex serve` listed before this WI (base 66cc84b).
const STDIO_TOOLS: [&str; 26] = [
    "add_excerpt",
    "add_link",
    "add_to_canvas",
    "add_to_smart_folder",
    "append_to_daily_note",
    "create_canvas",
    "create_note",
    "create_smart_folder",
    "delete_canvas",
    "delete_smart_folder",
    "get_canvas",
    "get_daily_note_changes",
    "get_note",
    "get_vault_settings",
    "list_canvases",
    "list_smart_folders",
    "list_unreviewed_days",
    "mark_day_reviewed",
    "move_node",
    "neighbors",
    "remove_excerpt",
    "remove_from_canvas",
    "remove_from_smart_folder",
    "search",
    "update_link",
    "update_smart_folder",
];

const LIMIT: Duration = Duration::from_secs(30);

/// Every path under `dir`, relative to it.
fn tree(dir: &Path) -> BTreeSet<PathBuf> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeSet<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            out.insert(path.strip_prefix(base).unwrap().to_path_buf());
            if path.is_dir() {
                walk(base, &path, out);
            }
        }
    }
    let mut out = BTreeSet::new();
    walk(dir, dir, &mut out);
    out
}

// ---------- AC 1: stdio mode unchanged ----------

#[test]
fn serve_vault_over_stdio_lists_the_same_26_tools() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--vault", vault.to_str().unwrap()])
        .env_remove(TOKEN_ENV)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn memex serve --vault");
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut send = move |msg: Value| {
        writeln!(stdin, "{msg}").expect("write to server");
        stdin.flush().unwrap();
    };
    let recv = |id: i64| -> Value {
        loop {
            let line = rx
                .recv_timeout(LIMIT)
                .unwrap_or_else(|e| panic!("no response to request {id}: {e}"));
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if v["id"] == json!(id) {
                    return v;
                }
            }
        }
    };

    send(json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": { "name": "wi71-test", "version": "0" },
        },
    }));
    let init = recv(1);
    assert!(init["result"].is_object(), "initialize failed: {init}");
    send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
    send(json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} }));
    let resp = recv(2);
    let names: Vec<String> = resp["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
        .iter()
        .filter_map(|t| t["name"].as_str().map(str::to_string))
        .collect();
    let mut sorted = names.clone();
    sorted.sort();
    assert_eq!(
        sorted,
        STDIO_TOOLS
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>(),
        "stdio serve lists exactly the base tool set"
    );

    // Closing stdin ends the session; the process exits cleanly.
    send(json!({ "jsonrpc": "2.0", "id": 3, "method": "ping" }));
    let _ = recv(3);
    drop(send); // closes stdin
    let started = std::time::Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if started.elapsed() > LIMIT {
            let _ = child.kill();
            let _ = child.wait();
            panic!("stdio serve did not exit after stdin closed");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "stdio serve exits 0 on EOF: {status}");

    // It still logs to <vault>/.memex/mcp.log* and serves no HTTP state.
    let memex_dir = vault.join(".memex");
    let logs: Vec<String> = std::fs::read_dir(&memex_dir)
        .unwrap()
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(str::to_string))
        .collect();
    assert!(
        logs.iter().any(|n| n.starts_with("mcp.log")),
        "stdio serve logs to .memex/mcp.log*: {logs:?}"
    );
    assert!(
        !logs
            .iter()
            .any(|n| n == "access-token" || n.starts_with("server.log")),
        "stdio serve creates no vault-server files: {logs:?}"
    );
}

// ---------- AC 2: mode conflicts are clap usage errors ----------

#[test]
fn serve_mode_conflicts_are_usage_errors_that_create_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();
    let root = dir.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let v = vault.to_str().unwrap().to_string();
    let r = root.to_str().unwrap().to_string();
    let listen = format!("127.0.0.1:{}", free_port());
    let remote = "http://127.0.0.1:9/vaults/work/mcp".to_string();

    let s = |xs: &[&str]| xs.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    // (case, args, is_token_flag)
    let cases: Vec<(&str, Vec<String>, bool)> = vec![
        (
            "--vault with --root",
            s(&["--vault", &v, "--root", &r]),
            false,
        ),
        (
            "--vault with --root --listen",
            s(&["--vault", &v, "--root", &r, "--listen", &listen]),
            false,
        ),
        (
            "--vault with --listen",
            s(&["--vault", &v, "--listen", &listen]),
            false,
        ),
        ("--listen without --root", s(&["--listen", &listen]), false),
        ("--root without --listen", s(&["--root", &r]), false),
        (
            "--root --with-embeddings without --listen",
            s(&["--root", &r, "--with-embeddings"]),
            false,
        ),
        (
            "--root --log-level without --listen",
            s(&["--root", &r, "--log-level", "debug"]),
            false,
        ),
        (
            "--remote with --vault",
            s(&["--remote", &remote, "--vault", &v]),
            false,
        ),
        (
            "--remote with --root --listen",
            s(&["--remote", &remote, "--root", &r, "--listen", &listen]),
            false,
        ),
        (
            "--remote with --root",
            s(&["--remote", &remote, "--root", &r]),
            false,
        ),
        (
            "--remote with --listen",
            s(&["--remote", &remote, "--listen", &listen]),
            false,
        ),
        (
            "--remote with --with-embeddings",
            s(&["--remote", &remote, "--with-embeddings"]),
            false,
        ),
        (
            "--remote with --log-level",
            s(&["--remote", &remote, "--log-level", "info"]),
            false,
        ),
        ("no mode", s(&[]), false),
        (
            "no mode, --with-embeddings only",
            s(&["--with-embeddings"]),
            false,
        ),
        (
            "no mode, --log-level only",
            s(&["--log-level", "debug"]),
            false,
        ),
        (
            "--token on the vault server",
            s(&[
                "--root",
                &r,
                "--listen",
                &listen,
                "--token",
                "argv-secret-1",
            ]),
            true,
        ),
        (
            "--access-token on the vault server",
            s(&[
                "--root",
                &r,
                "--listen",
                &listen,
                "--access-token",
                "argv-secret-2",
            ]),
            true,
        ),
        (
            "--token=… on the vault server",
            s(&["--root", &r, "--listen", &listen, "--token=argv-secret-3"]),
            true,
        ),
        (
            "--token on stdio",
            s(&["--vault", &v, "--token", "argv-secret-4"]),
            true,
        ),
        (
            "--token on --remote",
            s(&["--remote", &remote, "--token", "argv-secret-5"]),
            true,
        ),
    ];

    for (case, args, is_token_flag) in cases {
        let before = tree(dir.path());
        let argv: Vec<&str> = args.iter().map(String::as_str).collect();
        let out = ServeCommand::new(&argv)
            .env(TOKEN_ENV, "env-token-for-conflict-cases")
            .run_within(LIMIT);
        assert_eq!(out.code, Some(2), "{case}: usage error\n{}", out.describe());
        assert!(
            !out.stderr.trim().is_empty(),
            "{case}: clap explains the usage error\n{}",
            out.describe()
        );
        assert!(
            serde_json::from_str::<Value>(out.stderr.trim()).is_err(),
            "{case}: a usage error is clap output, not a C1 line\n{}",
            out.describe()
        );
        if !is_token_flag {
            // Every flag in these cases exists; the error is the mode conflict.
            assert!(
                !out.stderr.contains("unexpected argument"),
                "{case}: every mode flag is known to clap\n{}",
                out.describe()
            );
        }
        assert_eq!(
            tree(dir.path()),
            before,
            "{case}: a usage error creates nothing\n{}",
            out.describe()
        );
    }
}

// ---------- Mutation round: the stdio log is plain text ----------

#[test]
fn serve_vault_stdio_log_file_holds_no_ansi_escape_bytes() {
    // mcp.log is a file, not a terminal: tracing's colour codes (ESC [ ... m
    // around the level, dimmed targets) must never be written into it.
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();
    // Stdin is closed, so the session ends before initialize (exit 1); the
    // startup line is logged before that.
    let out = ServeCommand::new(&["--vault", vault.to_str().unwrap(), "--log-level", "debug"])
        .run_within(LIMIT);
    assert!(out.code.is_some(), "exited on its own\n{}", out.describe());

    let mut logs = Vec::new();
    for entry in std::fs::read_dir(vault.join(".memex")).unwrap().flatten() {
        if entry.file_name().to_string_lossy().starts_with("mcp.log") {
            logs.extend(std::fs::read(entry.path()).unwrap());
        }
    }
    let text = String::from_utf8_lossy(&logs);
    assert!(
        text.contains("starting memex-mcp") && text.contains("INFO"),
        "the startup line was logged at info:\n{text}"
    );
    assert!(
        !logs.contains(&0x1b),
        "mcp.log holds no ANSI escape (0x1b) bytes:\n{text:?}"
    );
}
