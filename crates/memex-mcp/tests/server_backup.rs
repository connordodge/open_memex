//! WI #320 (R3): vault-server backups, in process (Spec #315 req 28, 29, 30;
//! architecture D15, D16, D17 and the R3 guard ACs).
//!
//! Every test runs `memex_mcp::server::app()` in this process over a temp
//! vault root, with a fake clock ([`SetClock`]) and the archive hook
//! ([`Hooks`]), and calls `BackupService::run_due_checks()` directly (Spec
//! technical decision 12). Results are read back from the vault's
//! `backup-state.json`, the backup folder and `GET …/backup`.
//!
//! Waiting: every wait is for a hook event or a polled condition, up to
//! [`WAIT`]. The only bounded wait for something *not* to happen is
//! [`GRACE`] (a second backup must not start while the first is held); on a
//! loaded machine it can only miss a bug, never fail a correct server.
//!
//! This file never forks a child process: a fork copies every open `flock`
//! fd until exec, so a just-released backup lock could look held to the next
//! backup in this process. The `memex serve` binary tests (flags, start-up
//! validation, the server log, SIGTERM) are in `serve_backup_args.rs`.

#[path = "support/api_fixtures.rs"]
mod api_fixtures;
#[path = "support/server.rs"]
mod server;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::{self, File};
use std::io;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use memex_core::backup::{self as core_backup, state, ArchiveSink, BackupRequest, BackupSource};
use memex_core::Clock;
use memex_mcp::server::backup::{BackupConfig, BackupService};
use memex_mcp::server::{app, ServerConfig};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::task::JoinHandle;

use api_fixtures::{
    api_v1_dir, bless_requested, canonical_json, materialize_seed, run_rows, FixtureRequest,
    FixtureResponse, SEED_VAULT_NAME,
};
use server::{
    assert_wrong_method_is_c1_405_at, client, make_vault, raw_request, Reply, TEST_TOKEN, WAIT,
};

/// 2026-11-09T09:00:00Z, the fake clock's start.
const T0: i64 = 1_794_214_800_000;
const SECOND: i64 = 1_000;
const MINUTE: i64 = 60 * SECOND;
const HOUR: i64 = 60 * MINUTE;
const DAY: i64 = 24 * HOUR;

/// How long a held backup is given to let a second one start wrongly.
const GRACE: Duration = Duration::from_secs(1);

/// The keys of `GET …/backup` (D17), exactly.
const D17_KEYS: [&str; 10] = [
    "enabled",
    "keep",
    "in_progress",
    "last_attempt_at",
    "last_success_at",
    "last_result",
    "last_error",
    "last_file",
    "last_file_created_at",
    "last_bytes",
];

const NOT_CONFIGURED: &str =
    "backups are not configured on this vault server; start it with --backup-dir";

// ---------------------------------------------------------------------------
// Clock and hooks
// ---------------------------------------------------------------------------

/// A clock the test sets.
struct SetClock(AtomicI64);

impl SetClock {
    fn set(&self, ms: i64) {
        self.0.store(ms, Ordering::SeqCst);
    }
}

impl Clock for SetClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// A one-way gate a held backup waits on.
#[derive(Default)]
struct Gate {
    open: Mutex<bool>,
    cv: Condvar,
}

impl Gate {
    fn open(&self) {
        *self.open.lock().unwrap() = true;
        self.cv.notify_all();
    }

    fn wait(&self) {
        let mut open = self.open.lock().unwrap();
        while !*open {
            open = self.cv.wait(open).unwrap();
        }
    }
}

/// Called at every hook entry with the vault folder name and the folder
/// names entered before it.
type Check = Box<dyn Fn(&str, &[String]) + Send + Sync>;

/// The archive hook's state: which backups reached the write step (one
/// entry per backup that writes a file), and which to hold or panic.
#[derive(Default)]
struct Hooks {
    entries: Mutex<Vec<String>>,
    holds: Mutex<HashMap<String, Arc<Gate>>>,
    hold_next: Mutex<Option<Arc<Gate>>>,
    panics: Mutex<HashSet<String>>,
    checks: Mutex<Vec<Check>>,
}

impl Hooks {
    /// Every backup of `folder` waits at the write step until the gate opens.
    fn hold(&self, folder: &str) -> Arc<Gate> {
        let gate = Arc::new(Gate::default());
        self.holds
            .lock()
            .unwrap()
            .insert(folder.to_string(), gate.clone());
        gate
    }

    /// The next backup of any vault waits at the write step until the gate
    /// opens.
    fn hold_next(&self) -> Arc<Gate> {
        let gate = Arc::new(Gate::default());
        *self.hold_next.lock().unwrap() = Some(gate.clone());
        gate
    }

    /// The next backup of `folder` panics at the write step.
    fn panic_once(&self, folder: &str) {
        self.panics.lock().unwrap().insert(folder.to_string());
    }

    fn check(&self, check: impl Fn(&str, &[String]) + Send + Sync + 'static) {
        self.checks.lock().unwrap().push(Box::new(check));
    }

    fn entries(&self) -> Vec<String> {
        self.entries.lock().unwrap().clone()
    }

    fn count(&self, folder: &str) -> usize {
        self.entries().iter().filter(|e| *e == folder).count()
    }

    fn release_all(&self) {
        for gate in self.holds.lock().unwrap().values() {
            gate.open();
        }
        if let Some(gate) = self.hold_next.lock().unwrap().as_ref() {
            gate.open();
        }
    }

    /// The hook itself, on the backup's own thread.
    fn enter(&self, vault: &Path, file: File) -> io::Result<Box<dyn ArchiveSink>> {
        let name = vault
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let before = self.entries();
        for check in self.checks.lock().unwrap().iter() {
            check(&name, &before);
        }
        self.entries.lock().unwrap().push(name.clone());
        let panics = self.panics.lock().unwrap().remove(&name);
        if panics {
            panic!("test hook: the backup of {name} panics");
        }
        let held = self.holds.lock().unwrap().get(&name).cloned();
        let next = self.hold_next.lock().unwrap().take();
        if let Some(gate) = held.or(next) {
            gate.wait();
        }
        Ok(Box::new(file))
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

struct Opts {
    /// `with_backups` at all (else: a server without `--backup-dir`).
    backups: bool,
    keep: u16,
    /// Whether the backup dir exists at start.
    dir_exists: bool,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            backups: true,
            keep: 30,
            dir_exists: true,
        }
    }
}

/// The vault server from `app()`, served on `127.0.0.1:0`, with its
/// `BackupService`.
struct Env {
    tmp: TempDir,
    /// `<tmp>/vault root`.
    root: PathBuf,
    /// `<tmp>/backup dir`, the `--backup-dir`.
    dir: PathBuf,
    clock: Arc<SetClock>,
    hooks: Arc<Hooks>,
    service: Arc<BackupService>,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl Env {
    /// Backups on (keep 30) into an existing dir, over the vaults `names`.
    async fn start(names: &[&str]) -> Env {
        let names: Vec<String> = names.iter().map(|n| n.to_string()).collect();
        Env::start_with(Opts::default(), move |root| {
            for name in &names {
                make_vault(root, name);
            }
        })
        .await
    }

    async fn start_with(opts: Opts, prepare: impl FnOnce(&Path)) -> Env {
        let tmp = tempfile::tempdir().expect("temp dir");
        let root = tmp.path().join("vault root");
        let dir = tmp.path().join("backup dir");
        fs::create_dir(&root).unwrap();
        if opts.dir_exists {
            fs::create_dir(&dir).unwrap();
        }
        prepare(&root);

        let clock = Arc::new(SetClock(AtomicI64::new(T0)));
        let hooks = Arc::new(Hooks::default());
        let hook_state = hooks.clone();
        let mut config = ServerConfig::new(root.clone(), TEST_TOKEN)
            .with_clock(clock.clone())
            .with_backup_archive_hook(move |vault: &Path, file: File| {
                hook_state.enter(vault, file)
            });
        if opts.backups {
            config = config.with_backups(BackupConfig {
                dir: dir.clone(),
                keep: opts.keep,
            });
        }
        let (router, service) = app(config);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local addr");
        let task = tokio::spawn(async move {
            axum::serve(listener, router).await.expect("serve");
        });
        Env {
            tmp,
            root,
            dir,
            clock,
            hooks,
            service,
            addr,
            task,
        }
    }

    fn vault(&self, folder: &str) -> PathBuf {
        self.root.join(folder)
    }

    /// `<backup-dir>/<folder>`.
    fn dest(&self, folder: &str) -> PathBuf {
        self.dir.join(folder)
    }

    fn state(&self, folder: &str) -> Option<state::DestinationState> {
        state::destination_state(&self.vault(folder), &self.dest(folder))
    }

    fn recorded(&self, folder: &str) -> state::DestinationState {
        self.state(folder)
            .unwrap_or_else(|| panic!("{folder}: no backup recorded for {:?}", self.dest(folder)))
    }

    fn zips(&self, folder: &str) -> Vec<String> {
        zips_in(&self.dest(folder))
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    fn bearer(&self) -> String {
        format!("Bearer {TEST_TOKEN}")
    }

    async fn call(&self, method: &str, path: &str, auth: Option<&str>) -> Reply {
        let mut req = client().request(
            reqwest::Method::from_bytes(method.as_bytes()).unwrap(),
            self.url(path),
        );
        if let Some(value) = auth {
            req = req.header("authorization", value);
        }
        let resp = req
            .send()
            .await
            .unwrap_or_else(|e| panic!("{method} {path}: {e}"));
        Reply::read(resp).await
    }

    /// `GET /vaults/<name>/api/v1/backup` with the token.
    async fn get(&self, name: &str) -> Reply {
        let bearer = self.bearer();
        self.call("GET", &backup_path(name), Some(&bearer)).await
    }

    /// `POST /vaults/<name>/api/v1/backup` with the token, which must answer
    /// within [`WAIT`] whatever the backup is doing.
    async fn post(&self, name: &str) -> Reply {
        let bearer = self.bearer();
        tokio::time::timeout(WAIT, self.call("POST", &backup_path(name), Some(&bearer)))
            .await
            .unwrap_or_else(|_| panic!("POST {name}: no answer within {WAIT:?}"))
    }

    /// `run_due_checks()`, which must resolve within [`WAIT`].
    async fn run_due_checks(&self) {
        tokio::time::timeout(WAIT, self.service.run_due_checks())
            .await
            .expect("run_due_checks resolved");
    }

    /// Waits until the hook saw `n` backups of `folder`.
    async fn wait_entered(&self, folder: &str, n: usize) {
        let hooks = self.hooks.clone();
        wait_until(
            &format!("{n} backup(s) of {folder} reach the write step"),
            || hooks.count(folder) >= n,
        )
        .await;
    }

    /// Polls `GET …/backup` until `in_progress` is false; returns that body.
    async fn wait_idle(&self, name: &str) -> Value {
        let started = Instant::now();
        loop {
            let r = self.get(name).await;
            assert_eq!(r.status, 200, "GET backup of {name}: {}", r.body);
            let v = r.json();
            if v["in_progress"] == json!(false) {
                return v;
            }
            assert!(
                started.elapsed() < WAIT,
                "{name} still in progress after {WAIT:?}: {v}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        // Never leave a backup thread blocked on a gate after a failed test.
        self.hooks.release_all();
        self.task.abort();
    }
}

fn backup_path(name: &str) -> String {
    format!("/vaults/{name}/api/v1/backup")
}

/// The `.memex.zip` file names in `dir`, sorted (none when it's missing).
fn zips_in(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.ends_with(".memex.zip"))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// Every entry name directly in `dir`, sorted.
fn names_in(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    out.sort();
    out
}

/// A backup of `vault` into `dest` finished: its file is in place and its
/// `created` result is recorded.
fn backup_done(vault: &Path, dest: &Path) -> bool {
    !zips_in(dest).is_empty()
        && state::destination_state(vault, dest).is_some_and(|s| s.last_result == "created")
}

async fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < WAIT, "{what}: not after {WAIT:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn assert_d17_keys(v: &Value) {
    let keys: BTreeSet<&str> = v
        .as_object()
        .unwrap_or_else(|| panic!("a JSON object: {v}"))
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        D17_KEYS.into_iter().collect::<BTreeSet<_>>(),
        "exactly the D17 keys (no fingerprint): {v}"
    );
}

/// A body of a vault never backed up, on a server with backups on.
fn never(keep: u16, in_progress: bool) -> Value {
    json!({
        "enabled": true,
        "keep": keep,
        "in_progress": in_progress,
        "last_attempt_at": null,
        "last_success_at": null,
        "last_result": null,
        "last_error": null,
        "last_file": null,
        "last_file_created_at": null,
        "last_bytes": null,
    })
}

/// Changes a vault's content (a new object file), so its next backup writes.
fn touch(vault: &Path, what: &str) {
    let objects = vault.join("objects");
    fs::create_dir_all(&objects).unwrap();
    fs::write(objects.join(format!("{what}.txt")), what).unwrap();
}

// ---------------------------------------------------------------------------
// AC 1: without --backup-dir
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_backup_dir_due_checks_make_no_attempt_get_is_disabled_and_post_is_409_not_configured(
) {
    let env = Env::start_with(
        Opts {
            backups: false,
            ..Opts::default()
        },
        |root| {
            make_vault(root, "notes");
        },
    )
    .await;
    let state_file = env.vault("notes").join(core_backup::STATE_FILE);

    env.run_due_checks().await;
    assert!(env.hooks.entries().is_empty(), "no backup ran");
    assert!(!state_file.exists(), "nothing recorded");

    let r = env.get("notes").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(
        r.json(),
        json!({
            "enabled": false,
            "keep": null,
            "in_progress": false,
            "last_attempt_at": null,
            "last_success_at": null,
            "last_result": null,
            "last_error": null,
            "last_file": null,
            "last_file_created_at": null,
            "last_bytes": null,
        })
    );

    let r = env.post("notes").await;
    assert_eq!(r.status, 409, "{}", r.body);
    assert_eq!(r.c1_code(), "backups_not_configured");
    assert_eq!(r.json()["error"]["message"], NOT_CONFIGURED);

    env.run_due_checks().await;
    assert!(
        env.hooks.entries().is_empty(),
        "neither the POST nor a later check ran a backup"
    );
    assert!(!state_file.exists(), "still nothing recorded");
    assert!(
        names_in(&env.dir).is_empty(),
        "nothing is written into a folder the server was never given"
    );
}

// ---------------------------------------------------------------------------
// AC 2: the due rule through run_due_checks and the fake clock
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn first_due_check_backs_up_each_vault_once_an_immediate_second_makes_none_and_24h_later_each_once_more(
) {
    let env = Env::start(&["alpha", "Beta"]).await;
    let vaults = ["alpha", "Beta"];

    env.run_due_checks().await;
    for v in vaults {
        assert_eq!(env.hooks.count(v), 1, "{v}: exactly one backup");
        let s = env.recorded(v);
        // A second attempt in the same call would have recorded `unchanged`.
        assert_eq!(s.last_result, "created", "{v}: {s:?}");
        assert_eq!(s.last_attempt_at, T0, "{v}");
        assert_eq!(s.last_success_at, Some(T0), "{v}");
        assert_eq!(env.zips(v).len(), 1, "{v}: one file");
    }
    assert_eq!(
        names_in(&env.dir),
        vec!["Beta".to_string(), "alpha".to_string()],
        "one folder per vault, named as the vault folder on disk"
    );

    env.clock.set(T0 + MINUTE);
    env.run_due_checks().await;
    env.clock.set(T0 + DAY - 1);
    env.run_due_checks().await;
    for v in vaults {
        assert_eq!(env.hooks.count(v), 1, "{v}: not due again before 24 h");
        assert_eq!(
            env.recorded(v).last_attempt_at,
            T0,
            "{v}: no attempt before 24 h"
        );
    }

    // Both change, so each backup at +24 h writes a file, and a second
    // attempt in that call would record `unchanged`.
    for v in vaults {
        touch(&env.vault(v), "changed");
    }
    env.clock.set(T0 + DAY);
    env.run_due_checks().await;
    for v in vaults {
        assert_eq!(env.hooks.count(v), 2, "{v}: exactly one more backup");
        let s = env.recorded(v);
        assert_eq!(s.last_result, "created", "{v}: {s:?}");
        assert_eq!(s.last_attempt_at, T0 + DAY, "{v}");
        assert_eq!(s.last_success_at, Some(T0 + DAY), "{v}");
        assert_eq!(env.zips(v).len(), 2, "{v}: two files");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unchanged_vault_24h_later_is_checked_with_if_changed_and_writes_no_file() {
    let env = Env::start(&["notes"]).await;
    env.run_due_checks().await;
    let first = env.recorded("notes");
    assert_eq!(first.last_result, "created");

    env.clock.set(T0 + DAY);
    env.run_due_checks().await;
    let s = env.recorded("notes");
    assert_eq!(s.last_result, "unchanged", "{s:?}");
    assert_eq!(s.last_attempt_at, T0 + DAY);
    assert_eq!(s.last_success_at, Some(T0 + DAY));
    assert_eq!(
        s.last_file, first.last_file,
        "the last file stays the first"
    );
    assert_eq!(env.hooks.count("notes"), 1, "no second file was written");
    assert_eq!(env.zips("notes").len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_clock_that_jumps_back_before_the_last_success_makes_the_vault_due() {
    let env = Env::start(&["notes"]).await;
    env.run_due_checks().await;
    assert_eq!(env.recorded("notes").last_attempt_at, T0);

    // NTP or a manual change puts the clock an hour before the last success.
    env.clock.set(T0 - HOUR);
    env.run_due_checks().await;
    let s = env.recorded("notes");
    assert_eq!(s.last_attempt_at, T0 - HOUR, "checked again: {s:?}");
    assert_eq!(s.last_success_at, Some(T0 - HOUR));

    env.clock.set(T0 - HOUR + MINUTE);
    env.run_due_checks().await;
    assert_eq!(
        env.recorded("notes").last_attempt_at,
        T0 - HOUR,
        "a minute after that success, not due"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_check_runs_again_at_the_next_hourly_check() {
    let env = Env::start_with(
        Opts {
            dir_exists: false,
            ..Opts::default()
        },
        |root| {
            make_vault(root, "notes");
        },
    )
    .await;
    env.run_due_checks().await;
    let s = env.recorded("notes");
    assert_eq!(s.last_result, "backup_destination_unavailable", "{s:?}");
    assert_eq!(s.last_attempt_at, T0);

    env.clock.set(T0 + HOUR);
    env.run_due_checks().await;
    let s = env.recorded("notes");
    assert_eq!(s.last_attempt_at, T0 + HOUR, "retried an hour later: {s:?}");
    assert_eq!(s.last_result, "backup_destination_unavailable");

    // Once the folder exists, the next check backs up into
    // `<dir>/<folder>`, which the server creates.
    fs::create_dir(&env.dir).unwrap();
    env.clock.set(T0 + 2 * HOUR);
    env.run_due_checks().await;
    let s = env.recorded("notes");
    assert_eq!(s.last_result, "created", "{s:?}");
    assert_eq!(s.last_success_at, Some(T0 + 2 * HOUR));
    assert_eq!(env.zips("notes").len(), 1);
}

// ---------------------------------------------------------------------------
// AC 3: a backup held by a POST
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_post_answers_202_in_progress_before_its_held_backup_finishes_and_a_second_post_is_409() {
    let env = Env::start(&["alpha", "bravo"]).await;
    let gate = env.hooks.hold("alpha");

    let r = env.post("alpha").await;
    assert_eq!(r.status, 202, "{}", r.body);
    let body = r.json();
    assert_d17_keys(&body);
    assert_eq!(body, never(30, true), "the GET body, in_progress true");

    env.wait_entered("alpha", 1).await;
    assert!(env.zips("alpha").is_empty(), "the held backup is not done");

    let r = env.get("alpha").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["in_progress"], json!(true));
    let r = env.get("bravo").await;
    assert_eq!(r.json()["in_progress"], json!(false), "only alpha is busy");

    let r = env.post("alpha").await;
    assert_eq!(r.status, 409, "{}", r.body);
    assert_eq!(r.c1_code(), "backup_in_progress");

    // The backup never takes the vault's lock: the vault serves meanwhile.
    let bearer = env.bearer();
    let r = env
        .call("GET", "/vaults/alpha/api/v1/notes", Some(&bearer))
        .await;
    assert_eq!(r.status, 200, "notes during the backup: {}", r.body);
    let r = env
        .call("GET", "/vaults/alpha/api/v1/info", Some(&bearer))
        .await;
    assert_eq!(r.status, 200, "info during the backup: {}", r.body);

    gate.open();
    let done = env.wait_idle("alpha").await;
    assert_eq!(done["last_result"], "created", "{done}");
    assert_eq!(env.zips("alpha").len(), 1);
    assert_eq!(env.hooks.count("alpha"), 1, "the 409 POST started nothing");

    // Finished, the vault takes a POST again.
    env.clock.set(T0 + SECOND);
    let r = env.post("alpha").await;
    assert_eq!(r.status, 202, "{}", r.body);
    env.wait_idle("alpha").await;
    assert_eq!(env.hooks.count("alpha"), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn due_checks_during_a_held_post_skip_that_vault_and_start_the_next_only_after_it_ends() {
    let env = Env::start(&["alpha", "bravo"]).await;
    let gate = env.hooks.hold("alpha");
    let violations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (alpha_vault, alpha_dest) = (env.vault("alpha"), env.dest("alpha"));
    let seen = violations.clone();
    env.hooks.check(move |name, _| {
        if name == "bravo" && !backup_done(&alpha_vault, &alpha_dest) {
            seen.lock()
                .unwrap()
                .push("bravo's backup started before alpha's had finished".into());
        }
    });

    let r = env.post("alpha").await;
    assert_eq!(r.status, 202, "{}", r.body);
    env.wait_entered("alpha", 1).await;

    env.clock.set(T0 + MINUTE);
    let service = env.service.clone();
    let mut checks = tokio::spawn(async move { service.run_due_checks().await });
    let early = tokio::time::timeout(GRACE, &mut checks).await;
    assert!(
        early.is_err(),
        "run_due_checks finished while alpha's backup was held: bravo did not wait for the runner"
    );
    assert_eq!(
        env.hooks.count("bravo"),
        0,
        "bravo waits for the one runner"
    );

    gate.open();
    tokio::time::timeout(WAIT, checks)
        .await
        .expect("run_due_checks resolved once alpha's backup ended")
        .expect("run_due_checks did not panic");

    assert!(violations.lock().unwrap().is_empty(), "{violations:?}");
    assert_eq!(env.hooks.entries(), vec!["alpha", "bravo"]);
    let alpha = env.recorded("alpha");
    assert_eq!(
        (alpha.last_result.as_str(), alpha.last_attempt_at),
        ("created", T0),
        "only the POST's backup of alpha ran: {alpha:?}"
    );
    let bravo = env.recorded("bravo");
    assert_eq!(
        (bravo.last_result.as_str(), bravo.last_attempt_at),
        ("created", T0 + MINUTE),
        "{bravo:?}"
    );
    assert_eq!(env.wait_idle("alpha").await["in_progress"], json!(false));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn due_checks_back_up_one_vault_at_a_time() {
    let env = Env::start(&["alpha", "bravo"]).await;
    let gate = env.hooks.hold_next();
    let violations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (root, dir) = (env.root.clone(), env.dir.clone());
    let seen = violations.clone();
    env.hooks.check(move |name, before| {
        for earlier in before {
            if !backup_done(&root.join(earlier), &dir.join(earlier)) {
                seen.lock().unwrap().push(format!(
                    "{name}'s backup started before {earlier}'s had finished"
                ));
            }
        }
    });

    let service = env.service.clone();
    let mut checks = tokio::spawn(async move { service.run_due_checks().await });
    let hooks = env.hooks.clone();
    wait_until("the first backup reaches the write step", || {
        hooks.entries().len() == 1
    })
    .await;
    let early = tokio::time::timeout(GRACE, &mut checks).await;
    assert!(
        early.is_err(),
        "run_due_checks finished while its first backup was held"
    );
    assert_eq!(
        env.hooks.entries().len(),
        1,
        "the second vault waits while the first is held"
    );

    gate.open();
    tokio::time::timeout(WAIT, checks)
        .await
        .expect("run_due_checks resolved")
        .expect("no panic");
    assert!(violations.lock().unwrap().is_empty(), "{violations:?}");
    let mut entries = env.hooks.entries();
    entries.sort();
    assert_eq!(entries, vec!["alpha", "bravo"], "each vault once");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_in_flight_set_is_keyed_by_the_lowercased_name_and_backups_go_to_the_on_disk_folder_name(
) {
    let env = Env::start(&["Notes"]).await;
    let gate = env.hooks.hold("Notes");

    let r = env.post("Notes").await;
    assert_eq!(r.status, 202, "{}", r.body);
    env.wait_entered("Notes", 1).await;
    let r = env.post("notes").await;
    assert_eq!(r.status, 409, "another case of the same name: {}", r.body);
    assert_eq!(r.c1_code(), "backup_in_progress");
    assert_eq!(env.get("NOTES").await.json()["in_progress"], json!(true));

    gate.open();
    let done = env.wait_idle("notes").await;
    assert_eq!(done["last_result"], "created", "{done}");
    assert_eq!(
        names_in(&env.dir),
        vec!["Notes".to_string()],
        "the vault's folder name as on disk"
    );
    assert_eq!(env.zips("Notes").len(), 1);
    assert_eq!(env.hooks.count("Notes"), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_post_backup_that_panics_frees_its_vault_and_the_runner() {
    let env = Env::start(&["alpha", "bravo"]).await;
    env.hooks.panic_once("alpha");

    let r = env.post("alpha").await;
    assert_eq!(r.status, 202, "{}", r.body);
    let idle = env.wait_idle("alpha").await;
    assert_eq!(env.hooks.count("alpha"), 1, "the panicking backup ran");
    assert_eq!(idle["last_result"], Value::Null, "nothing recorded: {idle}");

    let r = env.post("alpha").await;
    assert_eq!(r.status, 202, "not 409 after the panic: {}", r.body);
    let done = env.wait_idle("alpha").await;
    assert_eq!(done["last_result"], "created", "{done}");

    env.clock.set(T0 + MINUTE);
    env.run_due_checks().await;
    assert_eq!(env.recorded("bravo").last_result, "created");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_scheduled_backup_that_panics_frees_its_vault_and_the_runner() {
    let env = Env::start(&["alpha", "bravo"]).await;
    env.hooks.panic_once("alpha");

    env.run_due_checks().await;
    assert_eq!(env.hooks.count("alpha"), 1, "the panicking backup ran");
    assert!(env.state("alpha").is_none(), "a panic records nothing");
    assert_eq!(
        env.recorded("bravo").last_result,
        "created",
        "the next vault still ran"
    );
    assert_eq!(env.wait_idle("alpha").await["in_progress"], json!(false));

    env.clock.set(T0 + MINUTE);
    env.run_due_checks().await;
    assert_eq!(
        env.recorded("alpha").last_result,
        "created",
        "alpha retried"
    );
    assert_eq!(env.hooks.count("bravo"), 1, "bravo is not due yet");
}

// ---------------------------------------------------------------------------
// AC 4: a lock held outside the server
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_backup_lock_held_outside_the_server_records_nothing_and_the_next_check_backs_up() {
    let env = Env::start(&["notes"]).await;
    let vault = env.vault("notes");
    let lock = core_backup::lock::try_lock(&vault).expect("take the vault's backup lock");

    env.run_due_checks().await;
    assert!(
        env.hooks.entries().is_empty(),
        "no backup reached the write step"
    );
    assert!(
        !vault.join(core_backup::STATE_FILE).exists(),
        "backup_in_progress is never recorded"
    );
    assert!(env.zips("notes").is_empty());
    let v = env.wait_idle("notes").await;
    assert_eq!(v["last_result"], Value::Null, "{v}");

    drop(lock);
    env.clock.set(T0 + HOUR);
    env.run_due_checks().await;
    let s = env.recorded("notes");
    assert_eq!(s.last_result, "created", "{s:?}");
    assert_eq!(s.last_attempt_at, T0 + HOUR);
}

// ---------------------------------------------------------------------------
// AC 5: a missing --backup-dir
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_backup_dir_records_destination_unavailable_for_each_vault_and_the_server_keeps_serving(
) {
    let env = Env::start_with(
        Opts {
            dir_exists: false,
            ..Opts::default()
        },
        |root| {
            make_vault(root, "alpha");
            make_vault(root, "bravo");
        },
    )
    .await;

    env.run_due_checks().await;
    for v in ["alpha", "bravo"] {
        let s = env.recorded(v);
        assert_eq!(
            s.last_result, "backup_destination_unavailable",
            "{v}: {s:?}"
        );
        assert_eq!(s.last_attempt_at, T0, "{v}");
        assert_eq!(s.last_success_at, None, "{v}");
        assert!(
            s.last_error.as_deref().is_some_and(|m| !m.is_empty()),
            "{v}: {s:?}"
        );
        assert_eq!(s.last_file, None, "{v}");
    }
    assert!(
        !env.dir.exists(),
        "the server never creates --backup-dir itself"
    );

    let bearer = env.bearer();
    let r = env.call("GET", "/api/v1/info", Some(&bearer)).await;
    assert_eq!(r.status, 200, "{}", r.body);
    let r = env.get("alpha").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let v = r.json();
    assert_d17_keys(&v);
    assert_eq!(v["enabled"], json!(true));
    assert_eq!(v["in_progress"], json!(false));
    assert_eq!(v["last_result"], "backup_destination_unavailable", "{v}");
    assert_eq!(v["last_attempt_at"], json!(T0));
    assert!(
        v["last_error"].as_str().is_some_and(|m| !m.is_empty()),
        "{v}"
    );
    let r = env
        .call("GET", "/vaults/bravo/api/v1/notes", Some(&bearer))
        .await;
    assert_eq!(r.status, 200, "{}", r.body);
}

// ---------------------------------------------------------------------------
// AC 7: a never-requested V5 vault
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_scheduler_backs_up_a_never_requested_v5_vault_and_leaves_it_at_schema_version_5() {
    let env = Env::start_with(Opts::default(), |root| v5_vault(root, "old")).await;
    let vault = env.vault("old");
    let manifest_before = fs::read(vault.join("manifest.json")).unwrap();

    env.run_due_checks().await;
    let s = env.recorded("old");
    assert_eq!(s.last_result, "created", "{s:?}");
    assert_eq!(env.zips("old").len(), 1);

    let manifest_after = fs::read(vault.join("manifest.json")).unwrap();
    assert_eq!(
        manifest_after, manifest_before,
        "manifest.json is byte-identical"
    );
    let manifest: Value = serde_json::from_slice(&manifest_after).unwrap();
    assert_eq!(manifest["schema_version"], json!(5));
    let conn =
        Connection::open_with_flags(vault.join("memex.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    let version: i64 = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 5, "memex.db was not migrated");
}

// ---------------------------------------------------------------------------
// AC 8: the wire contract
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn get_answers_exactly_the_d17_keys_from_the_state_recorded_for_its_own_backup_folder() {
    let env = Env::start_with(
        Opts {
            keep: 12,
            ..Opts::default()
        },
        |root| {
            make_vault(root, "notes");
        },
    )
    .await;
    // A `memex backup` into another folder is in the vault's state, but is
    // not the server's.
    let elsewhere = env.tmp.path().join("cli backups");
    fs::create_dir(&elsewhere).unwrap();
    let vault = env.vault("notes");
    core_backup::backup(&BackupRequest {
        vault: &vault,
        destination: &elsewhere,
        keep: 3,
        if_changed: false,
        source: BackupSource::Local,
    })
    .expect("a local backup");

    let r = env.get("notes").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_d17_keys(&r.json());
    assert_eq!(r.json(), never(12, false));

    env.run_due_checks().await;
    let r = env.get("notes").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let v = r.json();
    assert_d17_keys(&v);
    let zips = env.zips("notes");
    assert_eq!(zips.len(), 1, "{zips:?}");
    let bytes = fs::metadata(env.dest("notes").join(&zips[0]))
        .unwrap()
        .len();
    assert_eq!(
        v,
        json!({
            "enabled": true,
            "keep": 12,
            "in_progress": false,
            "last_attempt_at": T0,
            "last_success_at": T0,
            "last_result": "created",
            "last_error": null,
            "last_file": zips[0],
            "last_file_created_at": T0,
            "last_bytes": bytes,
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_post_always_writes_a_new_backup_and_the_server_keeps_backup_keep_of_them() {
    let env = Env::start_with(
        Opts {
            keep: 1,
            ..Opts::default()
        },
        |root| {
            make_vault(root, "notes");
        },
    )
    .await;

    let r = env.post("notes").await;
    assert_eq!(r.status, 202, "{}", r.body);
    let first = env.wait_idle("notes").await;
    assert_eq!(first["last_result"], "created", "{first}");
    assert_eq!(first["last_attempt_at"], json!(T0));
    let first_zips = env.zips("notes");
    assert_eq!(first_zips.len(), 1);

    // Nothing changed, and the POST still writes (as "Back up now").
    env.clock.set(T0 + SECOND);
    let r = env.post("notes").await;
    assert_eq!(r.status, 202, "{}", r.body);
    let mut expected = first.clone();
    expected["in_progress"] = json!(true);
    assert_eq!(r.json(), expected, "the GET body with in_progress true");

    let second = env.wait_idle("notes").await;
    assert_eq!(second["last_result"], "created", "{second}");
    assert_eq!(second["last_attempt_at"], json!(T0 + SECOND));
    assert_eq!(env.hooks.count("notes"), 2, "two backups wrote");
    let zips = env.zips("notes");
    assert_eq!(zips.len(), 1, "keep 1: {zips:?}");
    assert_ne!(zips, first_zips, "the newer file is the one kept");
    assert_eq!(second["last_file"], json!(zips[0]));
}

#[test]
fn backup_fixture_rows_match_a_server_with_backup_dir() {
    let rt = runtime();
    let env = rt.block_on(Env::start_with(Opts::default(), |root| {
        materialize_seed(root);
    }));
    // The POST's backup is held so the rows see a stable state.
    let gate = env.hooks.hold(SEED_VAULT_NAME);
    let dir = api_v1_dir().join("backup");
    let result = run_rows(&dir, bless_requested(), |req| rt.block_on(exec(&env, req)));
    if let Err(e) = result {
        panic!("{e}");
    }

    // The dart_only 409 row, while that backup is still held.
    rt.block_on(env.wait_entered(SEED_VAULT_NAME, 1));
    let r = rt.block_on(env.post(SEED_VAULT_NAME));
    assert_eq!(r.status, 409, "{}", r.body);
    let expected: Value =
        serde_json::from_slice(&fs::read(dir.join("start_in_progress.json")).unwrap()).unwrap();
    assert_eq!(canonical_json(&r.json()), canonical_json(&expected));

    gate.open();
    let done = rt.block_on(env.wait_idle(SEED_VAULT_NAME));
    assert_eq!(done["last_result"], "created", "{done}");
    drop(env);
}

#[test]
fn backup_off_fixture_rows_match_a_server_without_backup_dir() {
    let rt = runtime();
    let env = rt.block_on(Env::start_with(
        Opts {
            backups: false,
            ..Opts::default()
        },
        |root| {
            materialize_seed(root);
        },
    ));
    let result = run_rows(&api_v1_dir().join("backup_off"), bless_requested(), |req| {
        rt.block_on(exec(&env, req))
    });
    assert!(env.hooks.entries().is_empty(), "no backup ran");
    drop(env);
    if let Err(e) = result {
        panic!("{e}");
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime")
}

/// One fixture row against `env`, with the token unless the row sets
/// `Authorization` itself.
async fn exec(env: &Env, req: &FixtureRequest) -> FixtureResponse {
    let has = |name: &str| req.headers.keys().any(|k| k.eq_ignore_ascii_case(name));
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        req.method, req.path
    );
    if !has("authorization") {
        head.push_str(&format!("Authorization: {}\r\n", env.bearer()));
    }
    for (k, v) in &req.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    let body = req.body.clone().unwrap_or_default();
    if !has("content-length") {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    let reply = raw_request(env.addr, &head, &body).await;
    FixtureResponse {
        status: reply.status,
        body: reply.body.into_bytes(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_backup_route_answers_c1_405_for_every_other_method() {
    let env = Env::start(&["notes"]).await;
    assert_wrong_method_is_c1_405_at(
        env.addr,
        &env.bearer(),
        &[("/vaults/notes/api/v1/backup", &["GET", "POST"])],
    )
    .await;
    assert!(env.hooks.entries().is_empty());
}

// ---------------------------------------------------------------------------
// AC 9: the access token
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn both_backup_routes_answer_401_without_the_access_token() {
    let env = Env::start(&["notes"]).await;
    let path = backup_path("notes");
    for method in ["GET", "POST"] {
        for auth in [
            None,
            Some("Bearer not-the-token"),
            Some("Basic bm90ZXM6eA=="),
        ] {
            let r = env.call(method, &path, auth).await;
            assert_eq!(r.status, 401, "{method} with {auth:?}: {}", r.body);
            assert_eq!(r.c1_code(), "unauthorized", "{method} with {auth:?}");
        }
    }
    assert!(
        env.hooks.entries().is_empty(),
        "an unauthenticated POST starts nothing"
    );
    assert!(!env.vault("notes").join(core_backup::STATE_FILE).exists());

    let r = env.get("notes").await;
    assert_eq!(r.status, 200, "with the token: {}", r.body);
    let r = env.post("notes").await;
    assert_eq!(r.status, 202, "with the token: {}", r.body);
    env.wait_idle("notes").await;
}

// ---------------------------------------------------------------------------
// The V5 schema, as shipped (copied from memex-core's backup_run.rs, which
// copied it from migration_v6.rs)
// ---------------------------------------------------------------------------

/// `<root>/<name>`: a vault on schema V5 (database and manifest), as a
/// person who installed the V6 `memex` but has not opened it yet has.
fn v5_vault(root: &Path, name: &str) {
    let vault = root.join(name);
    fs::create_dir_all(vault.join("objects")).unwrap();
    let conn = Connection::open(vault.join("memex.db")).unwrap();
    conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    conn.execute_batch(V5_DDL).unwrap();
    conn.execute(
        "INSERT INTO notes (id, title, content_md, frontmatter, version, created_at, updated_at)
         VALUES ('01J9V5000000000000000000N1', 'A V5 note', 'body', '{}', 1, 1, 1)",
        [],
    )
    .unwrap();
    drop(conn);
    let manifest = json!({
        "vault_id": "01JCB7Q4M8V2X5N9R3T6W0Y5V5",
        "schema_version": 5,
        "created_at": 1_700_000_000_000_i64,
    });
    fs::write(
        vault.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();
    fs::write(vault.join("objects").join("a.txt"), "object").unwrap();
}

/// The shipped V5 schema (v1..v5), FTS included, pinned at version 5.
const V5_DDL: &str = "CREATE TABLE schema_version (version INTEGER PRIMARY KEY);

     CREATE TABLE notes (
         id           TEXT PRIMARY KEY,
         title        TEXT NOT NULL,
         content_md   TEXT NOT NULL,
         frontmatter  TEXT NOT NULL DEFAULT '{}',
         version      INTEGER NOT NULL DEFAULT 1,
         created_at   INTEGER NOT NULL,
         updated_at   INTEGER NOT NULL,
         crdt_state   BLOB,
         has_open_questions      INTEGER NOT NULL DEFAULT 0,
         frontmatter_parse_error INTEGER NOT NULL DEFAULT 0
     );
     CREATE INDEX idx_notes_updated_at ON notes(updated_at DESC);
     CREATE UNIQUE INDEX idx_notes_title_unique ON notes(title);

     CREATE TABLE chunks (
         id                  TEXT PRIMARY KEY,
         note_id             TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         ord                 INTEGER NOT NULL,
         content             TEXT NOT NULL,
         token_count         INTEGER NOT NULL,
         embed_model_version TEXT,
         start_byte          INTEGER,
         end_byte            INTEGER
     );
     CREATE INDEX idx_chunks_note ON chunks(note_id, ord);

     CREATE VIRTUAL TABLE chunk_fts USING fts5(
         content,
         chunk_id UNINDEXED,
         note_id UNINDEXED,
         tokenize = 'porter unicode61'
     );

     CREATE TABLE tags (
         note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         tag     TEXT NOT NULL,
         PRIMARY KEY (note_id, tag)
     );
     CREATE INDEX idx_tags_tag ON tags(tag);

     CREATE TABLE pending_index (
         note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         enqueued_at INTEGER NOT NULL
     );

     CREATE TABLE notes_dedup_log (
         note_id      TEXT PRIMARY KEY,
         old_title    TEXT NOT NULL,
         new_title    TEXT NOT NULL,
         migrated_at  INTEGER NOT NULL
     );

     CREATE TABLE links (
         id            TEXT PRIMARY KEY,
         from_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         to_note_id    TEXT NULL REFERENCES notes(id) ON DELETE SET NULL,
         link_text     TEXT NOT NULL,
         link_kind     TEXT NOT NULL
                       CHECK (link_kind GLOB '[a-z][a-z0-9-]*' AND length(link_kind) <= 64),
         label         TEXT NULL,
         position      INTEGER NOT NULL,
         source        TEXT NOT NULL
                       CHECK (source IN ('inline_body','inline_section','frontmatter','auto_added')),
         UNIQUE (from_note_id, position)
     );
     CREATE INDEX idx_links_from ON links(from_note_id);
     CREATE INDEX idx_links_to   ON links(to_note_id);
     CREATE INDEX idx_links_kind ON links(link_kind, to_note_id);

     CREATE TABLE canvases (
         id          TEXT PRIMARY KEY,
         title       TEXT NOT NULL,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL,
         version     INTEGER NOT NULL DEFAULT 1
     );
     CREATE UNIQUE INDEX idx_canvases_title_unique ON canvases(title);
     CREATE INDEX idx_canvases_updated_at ON canvases(updated_at DESC);

     CREATE TABLE canvas_nodes (
         canvas_id   TEXT NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
         note_id     TEXT NOT NULL REFERENCES notes(id)    ON DELETE CASCADE,
         x           REAL NOT NULL,
         y           REAL NOT NULL,
         z_order     INTEGER NOT NULL DEFAULT 0,
         placed_at   INTEGER NOT NULL,
         PRIMARY KEY (canvas_id, note_id)
     );
     CREATE INDEX idx_canvas_nodes_note ON canvas_nodes(note_id);

     CREATE TABLE blocks (
         note_id          TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         block_id         TEXT NOT NULL,
         ord              INTEGER NOT NULL,
         start_byte       INTEGER NOT NULL,
         end_byte         INTEGER NOT NULL,
         text             TEXT NOT NULL,
         content_hash     TEXT NOT NULL,
         source           TEXT NOT NULL
                          CHECK (source IN ('person','agent','quick-entry')),
         created_version  INTEGER NOT NULL,
         created_at       INTEGER NOT NULL,
         PRIMARY KEY (note_id, block_id)
     );
     CREATE INDEX idx_blocks_note_ord ON blocks(note_id, ord);

     CREATE TABLE day_reviews (
         note_id                   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
         content_version           INTEGER NOT NULL DEFAULT 0,
         reviewed_content_version  INTEGER NULL,
         reviewed_at               INTEGER NULL
     );

     CREATE TABLE day_review_blocks (
         note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         block_id      TEXT NOT NULL,
         content_hash  TEXT NOT NULL,
         text          TEXT NOT NULL,
         PRIMARY KEY (note_id, block_id)
     );

     CREATE TABLE footer_chips (
         daily_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         topic_note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         origin         TEXT NOT NULL CHECK (origin IN ('excerpt','person')),
         created_at     INTEGER NOT NULL,
         PRIMARY KEY (daily_note_id, topic_note_id)
     );
     CREATE INDEX idx_footer_chips_topic ON footer_chips(topic_note_id);

     CREATE TABLE agent_changes (
         id            TEXT PRIMARY KEY,
         note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         day           TEXT NOT NULL,
         created_at    INTEGER NOT NULL,
         bullets_json  TEXT NOT NULL
     );
     CREATE INDEX idx_agent_changes_note ON agent_changes(note_id, created_at DESC);

     CREATE TABLE smart_folders (
         id          TEXT PRIMARY KEY,
         name        TEXT NOT NULL,
         parent_id   TEXT NULL REFERENCES smart_folders(id),
         pinned      INTEGER NOT NULL DEFAULT 0,
         created_at  INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL
     );
     CREATE UNIQUE INDEX idx_smart_folders_sibling_name
         ON smart_folders(COALESCE(parent_id, ''), name COLLATE NOCASE);

     CREATE TABLE smart_folder_members (
         smart_folder_id  TEXT NOT NULL REFERENCES smart_folders(id) ON DELETE CASCADE,
         note_id          TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
         pinned           INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (smart_folder_id, note_id)
     );
     CREATE INDEX idx_smart_folder_members_note ON smart_folder_members(note_id);

     CREATE TABLE vault_settings (
         key    TEXT PRIMARY KEY,
         value  TEXT NOT NULL
     );

     CREATE UNIQUE INDEX idx_notes_daily_title ON notes(title)
         WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'daily';

     INSERT INTO vault_settings(key, value) VALUES ('smart_folder_max_depth', '2');
     INSERT INTO schema_version(version) VALUES (1);
     INSERT INTO schema_version(version) VALUES (2);
     INSERT INTO schema_version(version) VALUES (3);
     INSERT INTO schema_version(version) VALUES (4);
     INSERT INTO schema_version(version) VALUES (5);";
