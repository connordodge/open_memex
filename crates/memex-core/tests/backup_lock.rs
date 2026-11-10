//! WI #317 (R1a): the per-vault backup lock (Spec #315 req 5a, technical
//! decision 11; architecture D8).
//!
//! `lock::try_lock(vault)` takes `flock(LOCK_EX | LOCK_NB)` on
//! `<vault>/backup.lock`; a held lock is `backup_in_progress`; dropping the
//! `BackupLock` or the death of its process releases it. The cross-process
//! cases re-exec this test binary as a child that holds the lock and reports
//! on stdout; the parent waits on that line (an event), never on wall time.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::{Mutex, MutexGuard};

use memex_core::backup::lock::{self, BackupLock};
use memex_core::backup::LOCK_FILE;

/// The vault folder a child process locks.
const CHILD_VAULT_ENV: &str = "MEMEX_317_LOCK_CHILD_VAULT";
const CHILD_LOCKED: &str = "MEMEX_317_LOCK_CHILD_LOCKED";
const CHILD_FAILED: &str = "MEMEX_317_LOCK_CHILD_FAILED:";

/// One test at a time in this binary. A process spawned by one test holds
/// a copy of every open file description between its fork and exec, the
/// lock file's included, so a lock another test just dropped can look held
/// for that moment. Serialising keeps each test's lock state its own.
fn serial() -> MutexGuard<'static, ()> {
    static SERIAL: Mutex<()> = Mutex::new(());
    SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A vault-like folder whose path has a space in it.
fn vault_dir() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().expect("temp dir");
    let vault = tmp.path().join("My Vault");
    std::fs::create_dir(&vault).expect("create vault folder");
    (tmp, vault)
}

fn take(vault: &Path) -> BackupLock {
    lock::try_lock(vault).unwrap_or_else(|e| panic!("try_lock({}) failed: {e:?}", vault.display()))
}

fn assert_in_progress(vault: &Path, why: &str) {
    match lock::try_lock(vault) {
        Ok(_) => panic!("{why}: try_lock succeeded on a held lock"),
        Err(e) => assert_eq!(e.code(), "backup_in_progress", "{why}: {e:?}"),
    }
}

/// Child half of the cross-process tests: takes the lock on
/// `$MEMEX_317_LOCK_CHILD_VAULT`, says so on stdout and holds it until its
/// stdin closes (the parent's end) or it is killed. Run by its parent.
#[test]
#[ignore = "child process of the cross-process lock tests"]
fn lock_317_child_holds_the_lock() {
    let Some(vault) = std::env::var_os(CHILD_VAULT_ENV) else {
        return;
    };
    let held = lock::try_lock(Path::new(&vault));
    match &held {
        Ok(_) => println!("{CHILD_LOCKED}"),
        Err(e) => println!("{CHILD_FAILED}{}", e.code()),
    }
    io::stdout().flush().expect("flush stdout");
    if held.is_ok() {
        // Blocks until the parent closes stdin or the process is killed.
        let mut rest = Vec::new();
        let _ = io::stdin().read_to_end(&mut rest);
    }
    drop(held);
}

/// A child process holding the lock, and the rest of its stdout (kept open so
/// the child's later output never meets a closed pipe).
struct Holder {
    child: Child,
    out: BufReader<ChildStdout>,
}

/// Spawns the child and waits until it reports that it holds the lock.
fn spawn_holder(vault: &Path) -> Holder {
    let mut child = Command::new(std::env::current_exe().expect("test binary path"))
        .args([
            "--ignored",
            "--exact",
            "lock_317_child_holds_the_lock",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_VAULT_ENV, vault)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("re-exec the test binary");
    let mut out = BufReader::new(child.stdout.take().expect("child stdout"));
    let mut seen = Vec::new();
    loop {
        let mut line = String::new();
        if out.read_line(&mut line).expect("read child stdout") == 0 {
            break;
        }
        // libtest prints `test <name> ... ` before the child's own line.
        if line.trim_end().ends_with(CHILD_LOCKED) {
            return Holder { child, out };
        }
        if let Some((_, code)) = line.trim_end().split_once(CHILD_FAILED) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("child could not take the lock: {code}");
        }
        seen.push(line);
    }
    let status = child.wait().expect("wait for child");
    panic!(
        "child exited ({status:?}) without taking the lock; stdout:\n{}",
        seen.join("\n")
    );
}

#[test]
fn second_try_lock_on_a_held_vault_is_backup_in_progress_until_the_first_drops() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    let first = take(&vault);
    assert_in_progress(&vault, "second try_lock while the first is held");
    assert_in_progress(&vault, "third try_lock while the first is held");
    drop(first);
    let again = take(&vault);
    assert_in_progress(&vault, "try_lock while the re-taken lock is held");
    drop(again);
    drop(take(&vault));
}

#[test]
fn try_lock_creates_backup_lock_in_the_vault_folder() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    let lock_path = vault.join(LOCK_FILE);
    assert!(!lock_path.exists());
    let held = take(&vault);
    assert!(
        lock_path.is_file(),
        "{} is created by try_lock",
        lock_path.display()
    );
    drop(held);
}

#[test]
fn try_lock_takes_an_existing_backup_lock_file() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    std::fs::write(vault.join(LOCK_FILE), b"").expect("seed backup.lock");
    let held = take(&vault);
    assert_in_progress(&vault, "second try_lock on a pre-existing lock file");
    drop(held);
}

#[test]
fn try_lock_keeps_the_lock_files_content_and_never_deletes_it() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    let lock_path = vault.join(LOCK_FILE);
    std::fs::write(&lock_path, b"seeded").expect("seed backup.lock");
    let held = take(&vault);
    assert_eq!(
        std::fs::read(&lock_path).unwrap(),
        b"seeded",
        "taking the lock does not truncate the file"
    );
    drop(held);
    assert_eq!(
        std::fs::read(&lock_path).unwrap(),
        b"seeded",
        "releasing the lock does not delete or rewrite the file"
    );
    drop(take(&vault));
    assert!(lock_path.is_file());
}

#[test]
fn backup_in_progress_names_the_lock_file() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    let held = take(&vault);
    let err = lock::try_lock(&vault).expect_err("the lock is held");
    assert_eq!(err.code(), "backup_in_progress");
    let message = err.to_string();
    assert!(
        message.contains(&vault.join(LOCK_FILE).display().to_string()),
        "{message:?} names the lock file"
    );
    drop(held);
}

#[test]
fn try_lock_that_cannot_open_the_lock_file_is_backup_failed_not_in_progress() {
    let _serial = serial();
    let tmp = tempfile::tempdir().expect("temp dir");
    // The vault folder does not exist.
    let missing = tmp.path().join("No Such Vault");
    let err = lock::try_lock(&missing).expect_err("no vault folder");
    assert_eq!(err.code(), "backup_failed", "{err:?}");
    assert!(!missing.exists(), "try_lock never creates the vault folder");
    // The lock path is a folder: it cannot be opened for writing.
    let (_tmp2, vault) = vault_dir();
    std::fs::create_dir(vault.join(LOCK_FILE)).expect("folder named backup.lock");
    let err = lock::try_lock(&vault).expect_err("backup.lock is a folder");
    assert_eq!(err.code(), "backup_failed", "{err:?}");
}

#[test]
fn a_held_lock_on_one_vault_does_not_block_another_vault() {
    let _serial = serial();
    let (_tmp_a, a) = vault_dir();
    let (_tmp_b, b) = vault_dir();
    let held_a = take(&a);
    let held_b = take(&b);
    assert_in_progress(&a, "vault A stays locked");
    assert_in_progress(&b, "vault B stays locked");
    drop(held_a);
    drop(take(&a));
    drop(held_b);
}

#[test]
fn a_lock_held_by_another_process_is_backup_in_progress_and_freed_when_it_exits() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    let Holder { mut child, mut out } = spawn_holder(&vault);
    assert_in_progress(&vault, "while another process holds the lock");
    // Closing stdin lets the child drop the lock and exit normally.
    drop(child.stdin.take());
    let mut rest = String::new();
    out.read_to_string(&mut rest).expect("drain child stdout");
    let status = child.wait().expect("wait for child");
    assert!(status.success(), "child exited with {status:?}");
    drop(take(&vault));
}

#[test]
fn a_lock_held_by_a_child_process_that_is_sigkilled_does_not_block_the_next_try_lock() {
    let _serial = serial();
    let (_tmp, vault) = vault_dir();
    let Holder { mut child, out } = spawn_holder(&vault);
    assert_in_progress(&vault, "while the child holds the lock");
    child.kill().expect("SIGKILL the child");
    let status = child.wait().expect("wait for child");
    drop(out);
    assert_eq!(
        status.signal(),
        Some(libc::SIGKILL),
        "the child died by SIGKILL, never running a drop: {status:?}"
    );
    let held = take(&vault);
    assert_in_progress(&vault, "after re-taking the dead child's lock");
    drop(held);
}
