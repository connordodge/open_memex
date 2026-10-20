//! WI #75 (R6): `memex vault check`, the network-drive guard on every CLI
//! path, and the vault server's `--root` check (req 8, 30; D4, D19).
//!
//! - AC 6, 10: the `vault check` handler and the server's root validation
//!   driven in-process with an injected probe ("network" or "statfs failed").
//! - AC 8, 9: the built binary on local temp dirs: exit 0, empty stderr,
//!   nothing created, SQLite never opened.
//! - AC 10–12: the built binary on the real non-local autofs `/home` mount
//!   macOS ships (its `statfs` lacks `MNT_LOCAL`), so the real probe's
//!   refusal reaches every entry point. Skipped where that mount is absent.
//! - D19: `vault check` exits only 0, 1 (C1 error) or clap's 2 for a usage
//!   error; a refusal is never 2.

#[path = "support/server.rs"]
mod server;

use std::collections::BTreeSet;
use std::io::{self, BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::mpsc;
use std::time::{Duration, SystemTime};

use memex_core::fs_guard::FsInfo;
use memex_core::{MemexError, Vault};
use memex_mcp::cli;
use memex_mcp::server::RunOptions;
use serde_json::{json, Value};

use server::{free_port, ServeCommand, ANY_PORT, TOKEN_ENV};

const LIMIT: Duration = Duration::from_secs(30);

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn network_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(FsInfo::MacOs {
        fstypename: "smbfs".to_string(),
        local: false,
    })
}

fn local_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(FsInfo::MacOs {
        fstypename: "apfs".to_string(),
        local: true,
    })
}

/// A probe whose `statfs` call fails (EIO).
fn failing_probe(_: &Path) -> io::Result<FsInfo> {
    Err(io::Error::from_raw_os_error(5))
}

fn memex(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .env_remove(TOKEN_ENV)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Exit 1 with exactly one C1 line on stderr; returns its `error` object.
fn c1_failure(code: Option<i32>, stderr: &str, what: &str) -> Value {
    assert_eq!(code, Some(1), "{what}: a refusal exits 1, never 2");
    let lines: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(lines.len(), 1, "{what}: one C1 line on stderr: {stderr:?}");
    let v: Value = serde_json::from_str(lines[0])
        .unwrap_or_else(|e| panic!("{what}: stderr is not JSON ({e}): {stderr:?}"));
    assert_eq!(
        v.as_object().unwrap().keys().collect::<Vec<_>>(),
        vec!["error"],
        "{what}: top level holds only `error`: {v}"
    );
    assert!(v["error"]["message"].is_string(), "{what}: {v}");
    v["error"].clone()
}

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

fn mtime(p: &Path) -> SystemTime {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .unwrap_or_else(|e| panic!("mtime of {}: {e}", p.display()))
}

fn sidecars(vault: &Path) -> Vec<PathBuf> {
    ["memex.db-wal", "memex.db-shm", "memex.db-journal"]
        .iter()
        .map(|n| vault.join(n))
        .filter(|p| p.exists())
        .collect()
}

/// A real vault at `<dir>/v`, closed again, with no SQLite sidecar files.
fn closed_vault(dir: &Path) -> PathBuf {
    let root = dir.join("v");
    drop(Vault::create(&root).expect("create a local vault"));
    assert!(
        sidecars(&root).is_empty(),
        "precondition: a closed vault has no -wal/-shm: {:?}",
        sidecars(&root)
    );
    root
}

fn s(p: &Path) -> &str {
    p.to_str().expect("utf8 path")
}

/// The autofs `/home` mount every macOS install has: `mount` lists it
/// without `local`, so its `statfs` lacks `MNT_LOCAL` and req 30 calls it a
/// network filesystem. `None` (and a note on stderr) where it isn't mounted.
fn autofs_home() -> Option<PathBuf> {
    const HOME: &str = "/System/Volumes/Data/home";
    if !cfg!(target_os = "macos") {
        return None;
    }
    let out = Command::new("/sbin/mount").output().ok()?;
    let listed = String::from_utf8_lossy(&out.stdout)
        .lines()
        .any(|l| l.starts_with("map auto_home on /System/Volumes/Data/home (autofs"));
    if listed {
        Some(PathBuf::from(HOME))
    } else {
        eprintln!("skipped: no autofs mount at {HOME}");
        None
    }
}

/// A name under the autofs mount that matches no user record.
fn absent_on(home: &Path) -> PathBuf {
    home.join(format!("wi75-absent-{}", std::process::id()))
}

// ---------------------------------------------------------------------------
// AC 8: a local folder checks 0 and nothing is created
// ---------------------------------------------------------------------------

#[test]
fn vault_check_on_a_local_temp_dir_exits_0_with_empty_stderr() {
    let dir = tempfile::tempdir().unwrap();
    let out = memex(&["vault", "check", "--vault", s(dir.path())]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
    assert!(tree(dir.path()).is_empty(), "nothing was created");
}

#[test]
fn vault_check_on_a_non_vault_folder_exits_0_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("notes.txt"), "just a folder").unwrap();
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    let before = tree(dir.path());

    let out = memex(&["vault", "check", "--vault", s(dir.path())]);

    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
    assert_eq!(
        tree(dir.path()),
        before,
        "no memex.db, manifest or .memex/ was created"
    );
}

#[test]
fn vault_check_on_a_missing_path_exits_0_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("a").join("b");

    let out = memex(&["vault", "check", "--vault", s(&target)]);

    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
    assert!(
        tree(dir.path()).is_empty(),
        "no folder, memex.db or .memex/ was created: {:?}",
        tree(dir.path())
    );
}

#[test]
fn vault_check_without_vault_is_a_clap_usage_error() {
    // Exit 2 stays reserved for usage errors: the app reads 2 as "this memex
    // is too old" (D19).
    let out = memex(&["vault", "check"]);
    assert_eq!(out.status.code(), Some(2), "{}", describe(&out));
}

// ---------------------------------------------------------------------------
// AC 9: an existing vault checks 0 without SQLite being opened
// ---------------------------------------------------------------------------

#[test]
fn vault_check_on_an_existing_vault_does_not_open_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let root = closed_vault(dir.path());
    let db = root.join("memex.db");
    let (bytes, stamp, files) = (std::fs::read(&db).unwrap(), mtime(&db), tree(&root));

    let out = memex(&["vault", "check", "--vault", s(&root)]);

    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
    assert!(sidecars(&root).is_empty(), "{:?}", sidecars(&root));
    assert_eq!(mtime(&db), stamp, "memex.db mtime changed");
    assert!(std::fs::read(&db).unwrap() == bytes, "memex.db changed");
    assert_eq!(tree(&root), files, "the vault folder changed");
}

#[test]
fn vault_check_passes_a_vault_whose_db_is_not_sqlite() {
    // Opening SQLite on a non-database memex.db fails; `vault check` never
    // opens it, so it still exits 0.
    let dir = tempfile::tempdir().unwrap();
    let root = closed_vault(dir.path());
    let db = root.join("memex.db");
    std::fs::write(&db, b"not a sqlite database at all").unwrap();
    let stamp = mtime(&db);

    let out = memex(&["vault", "check", "--vault", s(&root)]);

    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
    assert!(sidecars(&root).is_empty(), "{:?}", sidecars(&root));
    assert_eq!(mtime(&db), stamp, "memex.db mtime changed");
}

// ---------------------------------------------------------------------------
// AC 10: a network probe makes `vault check` fail with network_filesystem
// ---------------------------------------------------------------------------

#[test]
fn vault_check_handler_returns_network_filesystem_when_the_probe_reports_network() {
    let dir = tempfile::tempdir().unwrap();
    for target in [dir.path().to_path_buf(), dir.path().join("a").join("b")] {
        let err = cli::vault::check_with(&target, &network_probe).expect_err("network is refused");
        assert!(
            matches!(
                err.downcast_ref::<MemexError>(),
                Some(MemexError::NetworkFilesystem(_))
            ),
            "{}: got {err:#}",
            target.display()
        );
        // The binary's error path prints `cli::error_json` as one line.
        let body = cli::error_json(&err);
        assert_eq!(body["error"]["code"], "network_filesystem", "{body}");
        assert_eq!(
            body.as_object().unwrap().keys().collect::<Vec<_>>(),
            vec!["error"]
        );
        assert!(!body.to_string().contains('\n'), "one line: {body}");
    }
    assert!(tree(dir.path()).is_empty(), "nothing was created");
}

#[test]
fn vault_check_handler_passes_a_local_probe() {
    let dir = tempfile::tempdir().unwrap();
    let root = closed_vault(dir.path());
    cli::vault::check_with(&root, &local_probe).expect("local is safe");
    cli::vault::check_with(&dir.path().join("new"), &local_probe).expect("local is safe");
    assert!(!dir.path().join("new").exists());
}

#[test]
fn vault_check_on_a_non_local_mount_exits_1_with_network_filesystem() {
    let Some(home) = autofs_home() else { return };
    for target in [home.clone(), absent_on(&home)] {
        let out = memex(&["vault", "check", "--vault", s(&target)]);
        let what = format!("vault check --vault {}", target.display());
        let err = c1_failure(
            out.status.code(),
            &String::from_utf8_lossy(&out.stderr),
            &what,
        );
        assert_eq!(err["code"], "network_filesystem", "{what}: {err}");
        assert!(out.stdout.is_empty(), "{what}: {}", describe(&out));
    }
}

// ---------------------------------------------------------------------------
// AC 6: a failing probe is an error, never safe and never network
// ---------------------------------------------------------------------------

#[test]
fn vault_check_handler_reports_a_probe_error_as_a_non_network_error() {
    let dir = tempfile::tempdir().unwrap();
    for target in [dir.path().to_path_buf(), dir.path().join("a")] {
        let err = cli::vault::check_with(&target, &failing_probe)
            .expect_err("a statfs failure is never reported as safe");
        let body = cli::error_json(&err);
        assert!(body["error"]["code"].is_string(), "{body}");
        assert_ne!(body["error"]["code"], "network_filesystem", "{body}");
    }
}

#[tokio::test]
async fn server_root_probe_error_is_not_reported_as_network() {
    let root = tempfile::tempdir().unwrap();
    // Hold the port, so a server that wrongly went on to bind fails fast
    // (with a bind error, not the probe's EIO) instead of serving forever.
    let held = TcpListener::bind("127.0.0.1:0").expect("hold a port");
    let opts = RunOptions {
        root: root.path().to_path_buf(),
        listen: held.local_addr().unwrap().to_string(),
        with_embeddings: false,
        log_level: "info".to_string(),
    };
    let err = tokio::time::timeout(
        LIMIT,
        memex_mcp::server::run_with_probe(opts, &failing_probe),
    )
    .await
    .expect("run_with_probe returned")
    .expect_err("a statfs failure on --root is never treated as safe");
    let body = cli::error_json(&err);
    assert_ne!(body["error"]["code"], "network_filesystem", "{body}");
    let eio = io::Error::from_raw_os_error(5).to_string();
    assert!(
        format!("{err:#}").contains(&eio),
        "the statfs failure itself is reported: {err:#}"
    );
    drop(held);
    assert!(
        tree(root.path()).is_empty(),
        "nothing was created in --root"
    );
}

// ---------------------------------------------------------------------------
// AC 11: local folders still work
// ---------------------------------------------------------------------------

/// Starts stdio `memex serve --vault <vault>` and returns the `initialize`
/// result.
fn stdio_initialize(vault: &Path) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--vault", s(vault)])
        .env_remove(TOKEN_ENV)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
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
    let msg = json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": { "name": "wi75-test", "version": "0" },
        },
    });
    writeln!(stdin, "{msg}").expect("write initialize");
    stdin.flush().unwrap();
    let reply = loop {
        match rx.recv_timeout(LIMIT) {
            Ok(line) => {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    if v["id"] == json!(1) {
                        break v;
                    }
                }
            }
            Err(e) => {
                let _ = child.kill();
                let out = child.wait_with_output().unwrap();
                panic!(
                    "no initialize reply ({e}); stderr={}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
        }
    };
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    reply
}

#[test]
fn local_init_ls_and_stdio_serve_still_work() {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("v");

    let out = memex(&["init", s(&vault)]);
    assert_eq!(out.status.code(), Some(0), "init: {}", describe(&out));
    assert!(vault.join("manifest.json").exists() && vault.join("memex.db").exists());

    let out = memex(&["ls", "--vault", s(&vault)]);
    assert_eq!(out.status.code(), Some(0), "ls: {}", describe(&out));

    let init = stdio_initialize(&vault);
    assert!(init["result"].is_object(), "initialize failed: {init}");

    let out = memex(&["vault", "check", "--vault", s(&vault)]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "vault check: {}",
        describe(&out)
    );
}

#[test]
fn vault_subcommands_refuse_a_non_local_mount_with_network_filesystem() {
    let Some(home) = autofs_home() else { return };
    let target = absent_on(&home);
    let t = s(&target);
    let ulid = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";
    let cases: Vec<Vec<&str>> = vec![
        vec!["init", t],
        vec!["ls", "--vault", t],
        vec!["get", "--vault", t, "--note-id", ulid],
        vec![
            "settings",
            "get",
            "--vault",
            t,
            "--key",
            "smart_folder_max_depth",
        ],
        vec!["folder", "ls", "--vault", t],
        vec!["canvas", "ls", "--vault", t],
    ];
    for args in cases {
        let what = format!("memex {}", args.join(" "));
        let out = memex(&args);
        let err = c1_failure(
            out.status.code(),
            &String::from_utf8_lossy(&out.stderr),
            &what,
        );
        assert_eq!(err["code"], "network_filesystem", "{what}: {err}");
        assert!(!target.exists(), "{what}: nothing was created");
    }
}

#[test]
fn stdio_serve_refuses_a_non_local_mount_before_creating_its_log_dir() {
    // stdio serve creates `<vault>/.memex/` for mcp.log before it opens the
    // vault, so the guard has to run before that, not only in Vault::open.
    let Some(home) = autofs_home() else { return };
    let target = absent_on(&home);
    let out = memex(&["serve", "--vault", s(&target)]);
    let err = c1_failure(
        out.status.code(),
        &String::from_utf8_lossy(&out.stderr),
        "serve --vault <autofs>",
    );
    assert_eq!(err["code"], "network_filesystem", "{err}");
    assert!(!target.exists(), "nothing was created");
}

// ---------------------------------------------------------------------------
// AC 12: the vault server refuses a network --root before binding
// ---------------------------------------------------------------------------

#[tokio::test]
async fn server_root_on_network_fails_with_network_filesystem_before_binding() {
    let root = tempfile::tempdir().unwrap();
    // Hold the port: were the guard after the bind, the error would be the
    // bind failure instead of `network_filesystem`.
    let held = TcpListener::bind("127.0.0.1:0").expect("hold a port");
    let addr = held.local_addr().unwrap();
    let probed = std::sync::Mutex::new(Vec::<PathBuf>::new());
    let probe = |p: &Path| {
        probed.lock().unwrap().push(p.to_path_buf());
        network_probe(p)
    };
    let opts = RunOptions {
        root: root.path().to_path_buf(),
        listen: addr.to_string(),
        with_embeddings: false,
        log_level: "info".to_string(),
    };

    let err = memex_mcp::server::run_with_probe(opts, &probe)
        .await
        .expect_err("a network --root is refused");

    assert!(
        matches!(
            err.downcast_ref::<MemexError>(),
            Some(MemexError::NetworkFilesystem(_))
        ),
        "got {err:#}"
    );
    assert_eq!(cli::error_json(&err)["error"]["code"], "network_filesystem");
    let canonical_root = std::fs::canonicalize(root.path()).unwrap();
    assert!(
        probed
            .lock()
            .unwrap()
            .iter()
            .any(|p| std::fs::canonicalize(p).ok() == Some(canonical_root.clone())),
        "--root itself was probed: {:?}",
        probed.lock().unwrap()
    );
    assert!(
        tree(root.path()).is_empty(),
        "no token, log or .memex/ was created in --root"
    );
    drop(held);
}

#[tokio::test]
async fn server_with_a_local_root_still_starts() {
    let root = tempfile::tempdir().unwrap();
    let mut child = ServeCommand::new(&["--root", s(root.path()), "--listen", ANY_PORT])
        .env(TOKEN_ENV, "wi75-local-root-token")
        .spawn();
    let addr = child.ready().await;
    let status = reqwest::Client::builder()
        .no_proxy()
        .timeout(LIMIT)
        .build()
        .unwrap()
        .get(format!("http://{addr}/api/v1/info"))
        .header("authorization", "Bearer wi75-local-root-token")
        .send()
        .await
        .expect("GET /api/v1/info")
        .status()
        .as_u16();
    assert_eq!(status, 200, "stderr={}", child.stderr());
    child.stop();
}

#[test]
fn serve_root_on_a_non_local_mount_exits_1_with_network_filesystem() {
    let Some(home) = autofs_home() else { return };
    let port = free_port();
    let finished =
        ServeCommand::new(&["--root", s(&home), "--listen", &format!("127.0.0.1:{port}")])
            .env(TOKEN_ENV, "wi75-network-root-token")
            .run_within(LIMIT);

    let err = c1_failure(finished.code, &finished.stderr, "serve --root <autofs>");
    assert_eq!(err["code"], "network_filesystem", "{}", finished.describe());
    assert!(
        !finished.stderr.contains("listening"),
        "the server never listened: {}",
        finished.describe()
    );
}
