//! WI #320 (R3): `memex serve --backup-dir` / `--backup-keep` through the
//! built binary (Spec #315 req 28, 29; architecture D15).
//!
//! - Flag misuse is a clap usage error (exit 2) that starts nothing.
//! - Start-up validation of `--backup-dir` runs before the server binds:
//!   inside the vault root only exactly `<root>/<.name>` is allowed, and
//!   never `.memex` or `.incoming` (`invalid_argument`, exit 1). The refused
//!   cases listen on a port already in use, so a server that validated after
//!   binding would fail with the bind error instead.
//! - What only the real process shows: hosted backups land in
//!   `<backup-dir>/<folder>/` with `source` `"hosted"`, results and failures
//!   go to `<root>/.memex/server.log.<date>`, and SIGTERM never waits for a
//!   running backup.
//!
//! Every wait polls an event (a log line, a file, a GET) up to [`WAIT`];
//! nothing sleeps for a result. In-process behavior is in `server_backup.rs`.

#[path = "support/server.rs"]
mod server;

use std::fs::{self, File};
use std::net::{SocketAddr, TcpListener as StdTcpListener};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::Value;

use server::{
    free_port, make_vault, server_logs, wait_for_logs, Finished, ServeChild, ServeCommand,
    ANY_PORT, TOKEN_ENV, WAIT,
};

const TOKEN: &str = "wi320-backup-token-7c1e9a4d2b";
const LIMIT: Duration = Duration::from_secs(30);

/// `<tmp>/vault root` (with a space) holding the vault `notes`.
struct Root {
    tmp: tempfile::TempDir,
    root: PathBuf,
}

impl Root {
    fn new() -> Root {
        let tmp = tempfile::tempdir().expect("temp dir");
        let root = tmp.path().join("vault root");
        fs::create_dir(&root).unwrap();
        make_vault(&root, "notes");
        Root { tmp, root }
    }

    fn path(&self, rel: &str) -> PathBuf {
        self.tmp.path().join(rel)
    }
}

fn serve(args: &[&str]) -> ServeCommand {
    ServeCommand::new(args).env(TOKEN_ENV, TOKEN)
}

fn s(p: &Path) -> &str {
    p.to_str().expect("UTF-8 path")
}

/// The one C1 line on stderr: `(code, message)`.
fn c1(out: &Finished) -> (String, String) {
    let lines = out.stderr_lines();
    assert_eq!(lines.len(), 1, "one stderr line\n{}", out.describe());
    let v: Value = serde_json::from_str(lines[0])
        .unwrap_or_else(|e| panic!("stderr is C1 JSON ({e})\n{}", out.describe()));
    (
        v["error"]["code"].as_str().unwrap_or_default().to_string(),
        v["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
    )
}

async fn get_json(addr: SocketAddr, path: &str) -> (u16, Value) {
    let r = server::get(
        &format!("http://{addr}{path}"),
        Some(&format!("Bearer {TOKEN}")),
    )
    .await;
    let v = serde_json::from_str(&r.body).unwrap_or(Value::Null);
    (r.status, v)
}

/// Polls `GET /vaults/<name>/api/v1/backup` until `last_result` is set and
/// no backup runs; returns that body.
async fn wait_backup_result(child: &ServeChild, addr: SocketAddr, name: &str) -> Value {
    let started = Instant::now();
    loop {
        let (status, v) = get_json(addr, &format!("/vaults/{name}/api/v1/backup")).await;
        if status == 200 && !v["last_result"].is_null() && v["in_progress"] == Value::Bool(false) {
            return v;
        }
        assert!(
            started.elapsed() < WAIT,
            "no backup result for {name} after {WAIT:?}: {status} {v}\nstderr={}",
            child.stderr()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Entry names in `dir` ending in `suffix`, sorted.
fn named(dir: &Path, suffix: &str) -> Vec<String> {
    let mut out: Vec<String> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.ends_with(suffix))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// `backup.json` of the zip at `file`, read with the system `unzip`.
fn backup_json_of(file: &Path) -> Value {
    let out = Command::new("/usr/bin/unzip")
        .arg("-p")
        .arg(file)
        .arg("backup.json")
        .output()
        .expect("spawn unzip");
    assert!(out.status.success(), "unzip -p {}: {out:?}", file.display());
    serde_json::from_slice(&out.stdout).expect("backup.json is JSON")
}

fn vault_id(vault: &Path) -> String {
    let m: Value = serde_json::from_slice(&fs::read(vault.join("manifest.json")).unwrap()).unwrap();
    m["vault_id"].as_str().unwrap().to_string()
}

/// A log line that names `name` and contains `what`.
fn logged(logs: &str, name: &str, what: &str) -> bool {
    logs.lines().any(|l| l.contains(name) && l.contains(what))
}

// ---------- AC 10: usage errors (exit 2) ----------

#[test]
fn backup_dir_or_backup_keep_without_root_is_a_usage_error_that_creates_nothing() {
    let r = Root::new();
    let vault = r.root.join("notes");
    let dir = r.path("backups");
    let remote = format!("http://127.0.0.1:{}/vaults/notes/mcp", free_port());
    let cases: Vec<(&str, Vec<&str>)> = vec![
        ("--backup-dir alone", vec!["--backup-dir", s(&dir)]),
        (
            "--backup-dir with --vault",
            vec!["--vault", s(&vault), "--backup-dir", s(&dir)],
        ),
        (
            "--backup-dir with --remote",
            vec!["--remote", &remote, "--backup-dir", s(&dir)],
        ),
        (
            "--backup-keep with --vault",
            vec!["--vault", s(&vault), "--backup-keep", "5"],
        ),
        (
            "--backup-keep with --remote",
            vec!["--remote", &remote, "--backup-keep", "5"],
        ),
    ];
    for (case, args) in cases {
        let out = ServeCommand::new(&args).run_within(LIMIT);
        assert_eq!(out.code, Some(2), "{case}: exit 2\n{}", out.describe());
        assert!(!dir.exists(), "{case}: created {}", dir.display());
        assert!(
            !vault.join(".memex").exists(),
            "{case}: the stdio server started"
        );
    }
}

#[test]
fn backup_keep_without_backup_dir_or_outside_1_to_365_is_a_usage_error() {
    let r = Root::new();
    let dir = r.path("backups");
    fs::create_dir(&dir).unwrap();
    // A busy port: anything that gets past clap fails to bind (exit 1).
    let busy = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let listen = busy.local_addr().unwrap().to_string();
    let base = ["--root", s(&r.root), "--listen", &listen];

    let with = |extra: &[&str]| -> Finished {
        let mut args: Vec<&str> = base.to_vec();
        args.extend_from_slice(extra);
        serve(&args).run_within(LIMIT)
    };
    for (case, extra) in [
        (
            "--backup-keep without --backup-dir",
            vec!["--backup-keep", "5"],
        ),
        (
            "--backup-keep 0",
            vec!["--backup-dir", s(&dir), "--backup-keep", "0"],
        ),
        (
            "--backup-keep 366",
            vec!["--backup-dir", s(&dir), "--backup-keep", "366"],
        ),
        (
            "--backup-keep -1",
            vec!["--backup-dir", s(&dir), "--backup-keep", "-1"],
        ),
    ] {
        let out = with(&extra);
        assert_eq!(out.code, Some(2), "{case}: exit 2\n{}", out.describe());
    }
    // The bounds themselves pass clap and validation, and only the busy port
    // stops them.
    for keep in ["1", "365"] {
        let out = with(&["--backup-dir", s(&dir), "--backup-keep", keep]);
        assert_eq!(
            out.code,
            Some(1),
            "--backup-keep {keep} is accepted\n{}",
            out.describe()
        );
        let (code, _) = c1(&out);
        assert_ne!(code, "invalid_argument", "--backup-keep {keep}");
    }
}

// ---------- AC 10: start-up validation (invalid_argument, exit 1) ----------

#[test]
fn a_backup_dir_inside_the_root_other_than_a_top_level_dot_folder_fails_start_up_with_invalid_argument(
) {
    let r = Root::new();
    let root = r.root.clone();
    fs::create_dir(root.join(".memex")).unwrap();
    let link = r.path("link to notes");
    std::os::unix::fs::symlink(root.join("notes"), &link).unwrap();
    let busy = StdTcpListener::bind("127.0.0.1:0").unwrap();
    let listen = busy.local_addr().unwrap().to_string();

    // (case, --backup-dir, current dir)
    let cases: Vec<(&str, PathBuf, Option<&Path>)> = vec![
        ("a plain folder in the root", root.join("backups"), None),
        ("a vault folder", root.join("notes"), None),
        (
            "a folder inside a vault",
            root.join("notes").join("backups"),
            None,
        ),
        ("the root itself", root.clone(), None),
        (
            "a folder inside a top-level dot folder",
            root.join(".backups").join("nested"),
            None,
        ),
        ("the server's own .memex", root.join(".memex"), None),
        ("the import folder .incoming", root.join(".incoming"), None),
        (
            "a relative path, resolved against the working directory",
            PathBuf::from("backups"),
            Some(&root),
        ),
        (
            "a symlink outside the root to a vault folder",
            link.clone(),
            None,
        ),
    ];
    for (case, dir, cwd) in cases {
        let existed = cwd.map_or(dir.clone(), |c| c.join(&dir)).exists();
        let mut cmd = serve(&[
            "--root",
            s(&root),
            "--listen",
            &listen,
            "--backup-dir",
            s(&dir),
        ]);
        if let Some(cwd) = cwd {
            cmd = cmd.current_dir(cwd);
        }
        let out = cmd.run_within(LIMIT);
        assert_eq!(out.code, Some(1), "{case}: exit 1\n{}", out.describe());
        let (code, message) = c1(&out);
        assert_eq!(
            code,
            "invalid_argument",
            "{case}: refused before binding\n{}",
            out.describe()
        );
        assert!(
            message.contains("--backup-dir"),
            "{case}: the message names --backup-dir: {message}"
        );
        assert!(
            !out.stderr.contains("listening"),
            "{case}: never listened\n{}",
            out.describe()
        );
        if !existed {
            let resolved = cwd.map_or(dir.clone(), |c| c.join(&dir));
            assert!(!resolved.exists(), "{case}: created {}", resolved.display());
        }
    }
}

// ---------- AC 10 + AC 8: accepted folders, through a real backup ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relative_top_level_dot_folder_in_the_root_starts_and_receives_hosted_backups_kept_30() {
    let r = Root::new();
    let root = r.root.clone();
    // The server never creates --backup-dir itself.
    fs::create_dir(root.join(".backups")).unwrap();
    let mut child = serve(&[
        "--root",
        s(&root),
        "--listen",
        ANY_PORT,
        "--backup-dir",
        ".backups",
    ])
    .current_dir(&root)
    .spawn();
    let addr = child.ready().await;

    let v = wait_backup_result(&child, addr, "notes").await;
    assert_eq!(v["last_result"], "created", "{v}");
    assert_eq!(v["enabled"], Value::Bool(true));
    assert_eq!(v["keep"], Value::from(30), "--backup-keep defaults to 30");
    let folder = root.join(".backups").join("notes");
    let zips = named(&folder, ".memex.zip");
    assert_eq!(zips.len(), 1, "one backup in <backup-dir>/notes: {zips:?}");
    assert_eq!(v["last_file"], Value::from(zips[0].clone()));

    let bj = backup_json_of(&folder.join(&zips[0]));
    assert_eq!(bj["source"], "hosted", "{bj}");
    assert_eq!(bj["vault_id"], Value::from(vault_id(&root.join("notes"))));

    let (status, vaults) = get_json(addr, "/api/v1/vaults").await;
    assert_eq!(status, 200, "{vaults}");
    let names: Vec<&str> = vaults["vaults"]
        .as_array()
        .unwrap_or_else(|| panic!("a vault list: {vaults}"))
        .iter()
        .filter_map(|v| v["name"].as_str())
        .collect();
    assert_eq!(names, vec!["notes"], ".backups is never served");

    let logs = wait_for_logs(&root, |l| logged(l, "notes", "created")).await;
    assert!(logged(&logs, "notes", "created"), "{logs}");
    child.stop();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_backup_dir_outside_the_root_starts_even_when_its_name_extends_the_roots() {
    let r = Root::new();
    // `<tmp>/vault root-backups` starts with the text `<tmp>/vault root`.
    let dir = r.path("vault root-backups");
    fs::create_dir(&dir).unwrap();
    let mut child = serve(&[
        "--root",
        s(&r.root),
        "--listen",
        ANY_PORT,
        "--backup-dir",
        s(&dir),
        "--backup-keep",
        "7",
    ])
    .spawn();
    let addr = child.ready().await;

    let v = wait_backup_result(&child, addr, "notes").await;
    assert_eq!(v["last_result"], "created", "{v}");
    assert_eq!(v["keep"], Value::from(7));
    assert_eq!(named(&dir.join("notes"), ".memex.zip").len(), 1);
    child.stop();
}

// ---------- AC 5: a missing --backup-dir ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_backup_dir_logs_destination_unavailable_and_the_server_keeps_serving() {
    let r = Root::new();
    let dir = r.path("no such folder");
    let mut child = serve(&[
        "--root",
        s(&r.root),
        "--listen",
        ANY_PORT,
        "--backup-dir",
        s(&dir),
    ])
    .spawn();
    let addr = child.ready().await;

    let logs = wait_for_logs(&r.root, |l| {
        logged(l, "notes", "backup_destination_unavailable")
    })
    .await;
    assert!(
        logged(&logs, "notes", "backup_destination_unavailable"),
        "{logs}"
    );
    let (status, info) = get_json(addr, "/api/v1/info").await;
    assert_eq!(status, 200, "{info}");
    let v = wait_backup_result(&child, addr, "notes").await;
    assert_eq!(v["last_result"], "backup_destination_unavailable", "{v}");
    assert!(
        !dir.exists(),
        "the server never creates --backup-dir itself"
    );
    child.stop();
}

// ---------- AC 4: a lock held outside the server ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_backup_lock_held_outside_the_server_logs_backup_in_progress_and_records_nothing() {
    let r = Root::new();
    let vault = r.root.join("notes");
    let dir = r.path("backups");
    fs::create_dir(&dir).unwrap();
    // Another process's backup (here: this test's) holds the vault's lock.
    let lock = memex_core::backup::lock::try_lock(&vault).expect("take the backup lock");
    let mut child = serve(&[
        "--root",
        s(&r.root),
        "--listen",
        ANY_PORT,
        "--backup-dir",
        s(&dir),
    ])
    .spawn();
    let addr = child.ready().await;

    let logs = wait_for_logs(&r.root, |l| logged(l, "notes", "backup_in_progress")).await;
    assert!(logged(&logs, "notes", "backup_in_progress"), "{logs}");
    assert!(
        !vault.join(memex_core::backup::STATE_FILE).exists(),
        "backup_in_progress is never recorded"
    );
    let folder = dir.join("notes");
    assert!(named(&folder, ".memex.zip").is_empty());
    assert!(named(&folder, ".partial").is_empty());
    let (status, v) = get_json(addr, "/vaults/notes/api/v1/backup").await;
    assert_eq!(status, 200, "{v}");
    assert_eq!(v["last_result"], Value::Null, "{v}");
    assert_eq!(v["in_progress"], Value::Bool(false), "{v}");
    child.stop();
    drop(lock);
}

// ---------- AC 6: SIGTERM during a backup ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sigterm_during_a_backup_exits_without_waiting_for_it_and_no_final_named_file_appears() {
    let r = Root::new();
    let vault = r.root.join("notes");
    // A sparse 3.5 GB object: no disk blocks, but seconds of compressing and
    // hashing, so the backup is still writing when SIGTERM arrives. A server
    // that waited for it would let it finish and rename it into place.
    let big = File::create(vault.join("objects").join("zeros.bin")).unwrap();
    big.set_len(3_500_000_000).unwrap();
    drop(big);
    let dir = r.path("backups");
    fs::create_dir(&dir).unwrap();
    let folder = dir.join("notes");

    let mut child = serve(&[
        "--root",
        s(&r.root),
        "--listen",
        ANY_PORT,
        "--backup-dir",
        s(&dir),
    ])
    .spawn();
    let started = Instant::now();
    while named(&folder, ".partial").is_empty() {
        if let Some(status) = child.wait_exit(Duration::ZERO) {
            panic!(
                "memex serve exited early: {status}\nstderr={}",
                child.stderr()
            );
        }
        assert!(
            started.elapsed() < WAIT,
            "the start-up backup wrote no .partial in {} after {WAIT:?}\nstderr={}\nlogs={}",
            folder.display(),
            child.stderr(),
            server_logs(&r.root)
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        named(&folder, ".memex.zip").is_empty(),
        "the backup finished before SIGTERM; the test vault is too small"
    );

    child.signal("TERM");
    let status = child
        .wait_exit(WAIT)
        .unwrap_or_else(|| panic!("memex serve still running after SIGTERM and {WAIT:?}"));
    assert!(
        status.success(),
        "a clean exit: {status}\nstderr={}",
        child.stderr()
    );
    assert!(
        named(&folder, ".memex.zip").is_empty(),
        "no final-named file: the exit did not wait for the backup"
    );
    assert!(
        memex_core::backup::state::destination_state(&vault, &folder).is_none(),
        "nothing recorded: the backup was still running when the process exited"
    );
}
