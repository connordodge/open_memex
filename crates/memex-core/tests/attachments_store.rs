//! WI #134 (Spec #123 R1, R2, R3, R15): `attachments::store_file` and
//! `store_bytes` write content-addressed files into a vault's `objects/`
//! folder, and the backup walk skips their `objects/.tmp-*` files.
//!
//! Vaults are temp folders whose names carry a space. The midway-failure
//! test runs the store in a re-exec'd copy of this test binary under an
//! `RLIMIT_FSIZE` limit (the write fails with `EFBIG` part-way), so nothing
//! here depends on timing.

use std::collections::BTreeSet;
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, UNIX_EPOCH};

use memex_core::attachments::{self, StoredAttachment};
use memex_core::backup::{self, BackupOutcome, BackupRequest, BackupSeams, BackupSource};
use memex_core::fs_guard::FsInfo;
use memex_core::{Clock, MemexError, Vault};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

const MAX: usize = 104_857_600;

// ---- helpers ------------------------------------------------------------------------------------

/// A canonical temp root with a vault folder `My Vault` (created, closed).
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    vault: PathBuf,
}

impl Fx {
    fn new() -> Self {
        let tmp = tempfile::Builder::new()
            .prefix("memex attach ")
            .tempdir()
            .unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let vault = root.join("My Vault");
        drop(Vault::create(&vault).unwrap());
        Fx {
            _tmp: tmp,
            root,
            vault,
        }
    }

    fn objects(&self) -> PathBuf {
        self.vault.join("objects")
    }

    /// A source file outside the vault.
    fn source(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let dir = self.root.join("Desktop files");
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join(name);
        fs::write(&p, bytes).unwrap();
        p
    }
}

fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn rel_path(bytes: &[u8], name: &str) -> String {
    let h = sha(bytes);
    format!("objects/{}/{h}/{name}", &h[..2])
}

/// Every regular file under `dir`, by `/`-joined path relative to `dir`.
fn files_under(dir: &Path) -> BTreeSet<String> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeSet<String>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries {
            let entry = entry.unwrap();
            let path = entry.path();
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                walk(base, &path, out);
            } else {
                let rel = path.strip_prefix(base).unwrap();
                out.insert(rel.to_string_lossy().into_owned());
            }
        }
    }
    let mut out = BTreeSet::new();
    walk(dir, dir, &mut out);
    out
}

fn tmp_entries(objects: &Path) -> Vec<String> {
    fs::read_dir(objects)
        .map(|rd| {
            rd.map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with(".tmp-"))
                .collect()
        })
        .unwrap_or_default()
}

/// The R15 refusal: the crate's invalid-argument form (`Io` with
/// `InvalidInput`) whose message is the exact Spec text.
fn refusal<T: std::fmt::Debug>(result: memex_core::Result<T>, what: &str) -> String {
    match result {
        Err(MemexError::Io(e)) if e.kind() == io::ErrorKind::InvalidInput => e.to_string(),
        other => panic!("{what}: expected a refusal, got {other:?}"),
    }
}

fn assert_stored(fx: &Fx, got: &StoredAttachment, bytes: &[u8], name: &str, mime: &str) {
    let path = rel_path(bytes, name);
    assert_eq!(got.path, path, "path");
    assert_eq!(got.name, name, "name");
    assert_eq!(got.size, bytes.len() as u64, "size");
    assert_eq!(got.mime, mime, "type");
    assert_eq!(
        got.markdown,
        attachments::markdown_for(name, &sha(bytes)),
        "markdown"
    );
    assert_eq!(
        fs::read(fx.vault.join(&path)).unwrap_or_else(|e| panic!("read {path}: {e}")),
        bytes,
        "the file holds the bytes"
    );
}

/// Restores a path's mode when dropped (so the temp dir can be removed).
struct Mode {
    path: PathBuf,
    mode: u32,
}

impl Mode {
    fn set(path: &Path, mode: u32) -> Self {
        let old = fs::metadata(path).unwrap().permissions().mode();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
        Mode {
            path: path.to_path_buf(),
            mode: old,
        }
    }
}

impl Drop for Mode {
    fn drop(&mut self) {
        let _ = fs::set_permissions(&self.path, fs::Permissions::from_mode(self.mode));
    }
}

// ---- AC: store writes objects/<h2>/<h>/<name> and returns its fields (R1) -----------------------

#[test]
fn store_bytes_writes_objects_h2_h_name_and_returns_path_name_size_type_and_markdown() {
    let fx = Fx::new();
    let bytes = b"%PDF-1.4 invented quarterly report";
    let got = attachments::store_bytes(&fx.vault, bytes, "Q3 report.pdf").unwrap();
    assert_stored(&fx, &got, bytes, "Q3 report.pdf", "application/pdf");
    let h = sha(bytes);
    assert_eq!(
        got.markdown,
        format!("[Q3 report.pdf](objects/{}/{h}/Q3%20report.pdf)", &h[..2])
    );
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::from([format!("{}/{h}/Q3 report.pdf", &h[..2])]),
        "exactly one file under objects/"
    );
}

#[test]
fn store_bytes_of_an_image_returns_image_markdown_and_its_type() {
    let fx = Fx::new();
    let bytes = b"\x89PNG\r\n\x1a\ninvented screenshot";
    let got = attachments::store_bytes(&fx.vault, bytes, "Screenshot 2026-11-18.png").unwrap();
    assert_stored(&fx, &got, bytes, "Screenshot 2026-11-18.png", "image/png");
    let h = sha(bytes);
    assert_eq!(
        got.markdown,
        format!(
            "![Screenshot 2026-11-18.png](objects/{}/{h}/Screenshot%202026-11-18.png)",
            &h[..2]
        )
    );
}

#[test]
fn store_file_uses_the_source_base_name_or_the_given_name() {
    let fx = Fx::new();
    let bytes = b"plain text notes\n";
    let src = fx.source("meeting notes.txt", bytes);
    let got = attachments::store_file(&fx.vault, &src, None).unwrap();
    assert_stored(&fx, &got, bytes, "meeting notes.txt", "text/plain");

    let got = attachments::store_file(&fx.vault, &src, Some("Renamed.md")).unwrap();
    assert_stored(&fx, &got, bytes, "Renamed.md", "text/markdown");
    assert_eq!(fs::read(&src).unwrap(), bytes, "the source is untouched");
}

#[test]
fn store_applies_the_stored_name_rule_and_returns_the_stored_name() {
    let fx = Fx::new();
    let bytes = b"rule bytes";
    let got = attachments::store_bytes(&fx.vault, bytes, " dir\\a/b\u{1}.txt ").unwrap();
    assert_stored(&fx, &got, bytes, "dir_a_b_.txt", "text/plain");
    let got = attachments::store_bytes(&fx.vault, bytes, "   ").unwrap();
    assert_stored(&fx, &got, bytes, "file", "application/octet-stream");
    let src = fx.source("x.bin", bytes);
    let got = attachments::store_file(&fx.vault, &src, Some("")).unwrap();
    assert_eq!(got.name, "file", "an empty given name is file");
}

#[test]
fn stored_attachment_serializes_as_markdown_path_name_size_type() {
    let fx = Fx::new();
    let bytes = b"json shape";
    let got = attachments::store_bytes(&fx.vault, bytes, "shape.json").unwrap();
    let v = serde_json::to_value(&got).unwrap();
    let keys: BTreeSet<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(
        keys,
        BTreeSet::from(["markdown", "path", "name", "size", "type"])
    );
    assert_eq!(v["type"], "application/json");
    assert_eq!(v["size"], bytes.len() as u64);
    assert_eq!(v["path"], rel_path(bytes, "shape.json"));
}

// ---- AC: dedupe and rewrites (R2) ---------------------------------------------------------------

#[test]
fn the_same_bytes_under_the_same_name_twice_leave_one_file_and_the_second_store_writes_nothing() {
    let fx = Fx::new();
    let bytes = b"stored once";
    let first = attachments::store_bytes(&fx.vault, bytes, "once.txt").unwrap();
    let final_path = fx.vault.join(&first.path);
    let hdir = final_path.parent().unwrap().to_path_buf();
    let h2dir = hdir.parent().unwrap().to_path_buf();
    let ino = fs::metadata(&final_path).unwrap().ino();

    // With objects/ and both hash folders read-only, any write fails.
    let second = {
        let _a = Mode::set(&hdir, 0o555);
        let _b = Mode::set(&h2dir, 0o555);
        let _c = Mode::set(&fx.objects(), 0o555);
        attachments::store_bytes(&fx.vault, bytes, "once.txt")
    };
    let second = second.expect("a second store of the same bytes and name writes nothing");
    assert_eq!(second, first, "the same result");
    assert_eq!(
        fs::metadata(&final_path).unwrap().ino(),
        ino,
        "the same file"
    );
    assert_eq!(files_under(&fx.objects()).len(), 1, "one file");
}

#[test]
fn store_file_of_the_same_bytes_and_name_twice_keeps_the_first_file_untouched() {
    let fx = Fx::new();
    let bytes = b"stored once from a file";
    let src = fx.source("once.txt", bytes);
    let first = attachments::store_file(&fx.vault, &src, None).unwrap();
    let final_path = fx.vault.join(&first.path);
    let old = UNIX_EPOCH + Duration::from_secs(1_000_000);
    File::options()
        .write(true)
        .open(&final_path)
        .unwrap()
        .set_modified(old)
        .unwrap();
    let ino = fs::metadata(&final_path).unwrap().ino();

    let second = attachments::store_file(&fx.vault, &src, None).unwrap();
    assert_eq!(second, first);
    let meta = fs::metadata(&final_path).unwrap();
    assert_eq!(meta.ino(), ino, "not replaced");
    assert_eq!(meta.modified().unwrap(), old, "not written");
    assert_eq!(files_under(&fx.objects()).len(), 1, "one file");
}

#[test]
fn the_same_bytes_under_another_name_give_a_second_file_in_the_same_hash_folder() {
    let fx = Fx::new();
    let bytes = b"two names, one content";
    let a = attachments::store_bytes(&fx.vault, bytes, "first name.txt").unwrap();
    let b = attachments::store_bytes(&fx.vault, bytes, "second name.txt").unwrap();
    assert_stored(&fx, &a, bytes, "first name.txt", "text/plain");
    assert_stored(&fx, &b, bytes, "second name.txt", "text/plain");
    let h = sha(bytes);
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::from([
            format!("{}/{h}/first name.txt", &h[..2]),
            format!("{}/{h}/second name.txt", &h[..2]),
        ])
    );
}

#[test]
fn an_existing_final_path_whose_size_differs_is_rewritten() {
    let fx = Fx::new();
    let bytes = b"the real content";
    let path = fx.vault.join(rel_path(bytes, "real.txt"));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, b"truncated").unwrap();
    let got = attachments::store_bytes(&fx.vault, bytes, "real.txt").unwrap();
    assert_stored(&fx, &got, bytes, "real.txt", "text/plain");

    // Larger than the content, from a file source.
    let more = b"other real content";
    let path = fx.vault.join(rel_path(more, "more.txt"));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, b"a leftover that is longer than the content").unwrap();
    let src = fx.source("more.txt", more);
    let got = attachments::store_file(&fx.vault, &src, None).unwrap();
    assert_stored(&fx, &got, more, "more.txt", "text/plain");
}

#[test]
fn an_existing_final_path_with_the_same_size_is_reused_as_it_is() {
    let fx = Fx::new();
    let bytes = b"0123456789";
    let path = fx.vault.join(rel_path(bytes, "same size.txt"));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, b"abcdefghij").unwrap();
    let got = attachments::store_bytes(&fx.vault, bytes, "same size.txt").unwrap();
    assert_eq!(got.path, rel_path(bytes, "same size.txt"));
    assert_eq!(got.size, 10);
    assert_eq!(
        fs::read(&path).unwrap(),
        b"abcdefghij",
        "same size: reused, not rewritten"
    );
}

// ---- AC: temp file and rename (R2) --------------------------------------------------------------

#[test]
fn after_a_successful_store_no_tmp_file_remains() {
    let fx = Fx::new();
    attachments::store_bytes(&fx.vault, b"one", "one.txt").unwrap();
    let src = fx.source("two.txt", b"two");
    attachments::store_file(&fx.vault, &src, None).unwrap();
    attachments::store_file(&fx.vault, &src, None).unwrap();
    assert_eq!(tmp_entries(&fx.objects()), Vec::<String>::new());
    assert_eq!(files_under(&fx.objects()).len(), 2);
    for f in files_under(&fx.objects()) {
        assert!(!f.contains(".tmp-"), "{f}");
    }
}

const FSIZE_ENV: &str = "MEMEX_134_FSIZE_STORE_VAULT";
/// Large enough that a direct write leaves a partial file, small enough to
/// keep the run quick.
const BIG: usize = 1 << 20;
const LIMIT: u64 = 64 * 1024;

fn big_bytes() -> Vec<u8> {
    (0..BIG).map(|i| (i * 31 % 251) as u8).collect()
}

/// Not a check of its own. Run by the midway-failure test with
/// `FSIZE_ENV` set: limits this process's file size to `LIMIT` (ignoring
/// SIGXFSZ, so the write fails with EFBIG), stores `BIG` bytes from memory
/// and from a file, and prints each result. Without the variable it
/// returns at once.
#[test]
fn fsize_limited_store_child_process() {
    let Some(vault) = std::env::var_os(FSIZE_ENV) else {
        return;
    };
    let vault = PathBuf::from(vault);
    let source = PathBuf::from(std::env::var_os("MEMEX_134_FSIZE_SOURCE").unwrap());
    unsafe {
        libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
        let lim = libc::rlimit {
            rlim_cur: LIMIT as libc::rlim_t,
            rlim_max: libc::RLIM_INFINITY,
        };
        assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &lim), 0);
    }
    let bytes = big_bytes();
    // The limit itself works: a plain write of the same bytes fails.
    let probe = vault.parent().unwrap().join("limit probe.bin");
    let limited = fs::write(&probe, &bytes).is_err();
    println!("LIMIT-WORKS {}", if limited { "yes" } else { "no" });
    let _ = fs::remove_file(&probe);
    let r = attachments::store_bytes(&vault, &bytes, "big from bytes.bin");
    println!("STORE-BYTES {}", if r.is_err() { "err" } else { "ok" });
    let r = attachments::store_file(&vault, &source, Some("big from file.bin"));
    println!("STORE-FILE {}", if r.is_err() { "err" } else { "ok" });
    io::stdout().flush().unwrap();
}

#[test]
fn after_a_write_that_fails_midway_no_file_exists_at_the_final_path() {
    let fx = Fx::new();
    let bytes = big_bytes();
    let source = fx.source("big source.bin", &bytes);
    let out = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "fsize_limited_store_child_process",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(FSIZE_ENV, &fx.vault)
        .env("MEMEX_134_FSIZE_SOURCE", &source)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .output()
        .expect("re-exec the test binary");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("LIMIT-WORKS yes"),
        "the file size limit makes a plain write fail: {stdout}"
    );
    assert!(
        stdout.contains("STORE-BYTES err") && stdout.contains("STORE-FILE err"),
        "both stores fail part-way under the file size limit: {stdout}"
    );
    for name in ["big from bytes.bin", "big from file.bin"] {
        let path = fx.vault.join(rel_path(&bytes, name));
        assert!(
            fs::symlink_metadata(&path).is_err(),
            "no file at the final path {}",
            path.display()
        );
    }
    // Anything left behind is a temp file directly under objects/.
    for f in files_under(&fx.objects()) {
        assert!(
            f.starts_with(".tmp-") && !f.contains('/'),
            "only objects/.tmp-* may remain after a failed write, found objects/{f}"
        );
    }
    // A later store succeeds and leaves the whole file.
    let got = attachments::store_bytes(&fx.vault, &bytes, "big from bytes.bin").unwrap();
    assert_stored(
        &fx,
        &got,
        &bytes,
        "big from bytes.bin",
        "application/octet-stream",
    );
}

// ---- AC: refusals (R15) -------------------------------------------------------------------------

/// A sparse file of `len` bytes.
fn sparse(fx: &Fx, name: &str, len: u64) -> PathBuf {
    let dir = fx.root.join("Desktop files");
    fs::create_dir_all(&dir).unwrap();
    let p = dir.join(name);
    File::create(&p).unwrap().set_len(len).unwrap();
    p
}

#[test]
fn a_file_over_104857600_bytes_is_refused_with_the_spec_text_and_nothing_is_stored() {
    let fx = Fx::new();
    let big = sparse(&fx, "huge video.mov", MAX as u64 + 1);
    let msg = refusal(
        attachments::store_file(&fx.vault, &big, None),
        "over 100 MB",
    );
    assert_eq!(
        msg,
        "huge video.mov is larger than 100 MB and wasn't attached."
    );
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::new(),
        "nothing stored"
    );
    assert_eq!(tmp_entries(&fx.objects()), Vec::<String>::new());
}

#[test]
fn a_file_of_exactly_104857600_bytes_is_stored() {
    let fx = Fx::new();
    let at = sparse(&fx, "exactly 100 MiB.bin", MAX as u64);
    let got = attachments::store_file(&fx.vault, &at, None).expect("exactly 100 MiB is allowed");
    assert_eq!(got.size, MAX as u64);
    let zeros = vec![0u8; MAX];
    assert_eq!(got.path, rel_path(&zeros, "exactly 100 MiB.bin"));
    assert_eq!(
        fs::metadata(fx.vault.join(&got.path)).unwrap().len(),
        MAX as u64
    );
}

#[test]
fn bytes_over_104857600_are_refused_and_exactly_104857600_are_stored() {
    let fx = Fx::new();
    let mut bytes = vec![7u8; MAX + 1];
    let msg = refusal(
        attachments::store_bytes(&fx.vault, &bytes, "big upload.bin"),
        "bytes over 100 MB",
    );
    assert_eq!(
        msg,
        "big upload.bin is larger than 100 MB and wasn't attached."
    );
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::new(),
        "nothing stored"
    );

    bytes.pop();
    let got = attachments::store_bytes(&fx.vault, &bytes, "big upload.bin")
        .expect("exactly 100 MiB is allowed");
    assert_eq!(got.size, MAX as u64);
    assert_eq!(got.path, rel_path(&bytes, "big upload.bin"));
}

#[test]
fn a_folder_is_refused_with_the_spec_text() {
    let fx = Fx::new();
    let dir = fx.root.join("Project folder");
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("inside.txt"), b"inside").unwrap();
    let msg = refusal(attachments::store_file(&fx.vault, &dir, None), "folder");
    assert_eq!(msg, "Folders can't be attached.");
    let link = fx.root.join("link to folder");
    symlink(&dir, &link).unwrap();
    let msg = refusal(
        attachments::store_file(&fx.vault, &link, None),
        "symlink to a folder",
    );
    assert_eq!(msg, "Folders can't be attached.");
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::new(),
        "nothing stored"
    );
}

fn mkfifo(path: &Path) {
    let c = CString::new(path.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o644) }, 0, "mkfifo");
}

#[test]
fn a_fifo_is_refused_with_the_spec_text_without_blocking_on_open() {
    let fx = Fx::new();
    let fifo = fx.root.join("pipe one");
    mkfifo(&fifo);
    let (tx, rx) = mpsc::channel();
    let vault = fx.vault.clone();
    let path = fifo.clone();
    std::thread::spawn(move || {
        let _ = tx.send(attachments::store_file(&vault, &path, None));
    });
    let result = match rx.recv_timeout(Duration::from_secs(20)) {
        Ok(r) => r,
        Err(_) => {
            // Release the blocked open so the thread ends, then fail.
            let _ = fs::OpenOptions::new().write(true).open(&fifo);
            panic!("store_file blocked on a FIFO with no writer");
        }
    };
    let msg = refusal(result, "FIFO");
    assert_eq!(msg, "pipe one isn't a regular file and wasn't attached.");
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::new(),
        "nothing stored"
    );
}

#[test]
fn a_socket_a_device_and_a_symlink_to_a_fifo_are_refused_as_not_regular_files() {
    let fx = Fx::new();
    let sock = fx.root.join("agent sock");
    let _listener = UnixListener::bind(&sock).unwrap();
    let msg = refusal(attachments::store_file(&fx.vault, &sock, None), "socket");
    assert_eq!(msg, "agent sock isn't a regular file and wasn't attached.");

    let msg = refusal(
        attachments::store_file(&fx.vault, Path::new("/dev/null"), None),
        "device",
    );
    assert_eq!(msg, "null isn't a regular file and wasn't attached.");

    let fifo = fx.root.join("pipe two");
    mkfifo(&fifo);
    let link = fx.root.join("link to pipe");
    symlink(&fifo, &link).unwrap();
    let (tx, rx) = mpsc::channel();
    let vault = fx.vault.clone();
    let path = link.clone();
    std::thread::spawn(move || {
        let _ = tx.send(attachments::store_file(&vault, &path, None));
    });
    let result = match rx.recv_timeout(Duration::from_secs(20)) {
        Ok(r) => r,
        Err(_) => {
            let _ = fs::OpenOptions::new().write(true).open(&fifo);
            panic!("store_file blocked on a symlink to a FIFO");
        }
    };
    let msg = refusal(result, "symlink to a FIFO");
    assert_eq!(
        msg,
        "link to pipe isn't a regular file and wasn't attached."
    );
    assert_eq!(
        files_under(&fx.objects()),
        BTreeSet::new(),
        "nothing stored"
    );
}

#[test]
fn a_symlink_to_a_regular_file_stores_the_targets_bytes() {
    let fx = Fx::new();
    let bytes = b"the target's own bytes";
    let target = fx.source("target report.pdf", bytes);
    let link = fx.root.join("shortcut.pdf");
    symlink(&target, &link).unwrap();
    let got = attachments::store_file(&fx.vault, &link, Some("shortcut.pdf")).unwrap();
    assert_stored(&fx, &got, bytes, "shortcut.pdf", "application/pdf");
    let stored = fx.vault.join(&got.path);
    assert!(
        fs::symlink_metadata(&stored).unwrap().file_type().is_file(),
        "a regular file is stored, not a link"
    );
}

#[test]
fn a_missing_source_file_is_an_error_and_stores_nothing() {
    let fx = Fx::new();
    let missing = fx.root.join("not here.txt");
    let r = attachments::store_file(&fx.vault, &missing, None);
    assert!(r.is_err(), "a missing file fails: {r:?}");
    assert_eq!(files_under(&fx.objects()), BTreeSet::new());
}

// ---- AC: the backup walk skips objects/.tmp-* (R2) ----------------------------------------------

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

fn local_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(FsInfo::MacOs {
        fstypename: "apfs".into(),
        local: true,
    })
}

fn plain_sink(file: File) -> io::Result<Box<dyn backup::ArchiveSink>> {
    Ok(Box::new(file))
}

fn run_backup(vault: &Path, dest: &Path, at_ms: i64, if_changed: bool) -> BackupOutcome {
    let clock = FixedClock(at_ms);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        vault,
        destination: dest,
        keep: 30,
        if_changed,
        source: BackupSource::Local,
    };
    backup::backup_with(&request, &seams).expect("the backup succeeds")
}

fn zip_names(path: &Path) -> BTreeSet<String> {
    let zip = zip::ZipArchive::new(File::open(path).unwrap()).unwrap();
    zip.file_names().map(|n| n.unwrap().into_owned()).collect()
}

fn zip_member(path: &Path, name: &str) -> Vec<u8> {
    let mut zip = zip::ZipArchive::new(File::open(path).unwrap()).unwrap();
    let mut out = Vec::new();
    zip.by_name(name).unwrap().read_to_end(&mut out).unwrap();
    out
}

/// An attachment written straight to its content address (not through
/// `store`, so these tests check only the backup walk).
fn put_object(fx: &Fx, bytes: &[u8], name: &str) {
    let path = fx.vault.join(rel_path(bytes, name));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

/// 2026-11-10T10:00:00.250Z and later.
const T1: i64 = 1_794_304_800_250;
const T2: i64 = T1 + 3_600_000;

#[test]
fn a_backup_taken_while_an_objects_tmp_file_exists_succeeds_and_leaves_it_out() {
    let fx = Fx::new();
    let dest = fx.root.join("Backup Drive");
    fs::create_dir(&dest).unwrap();
    let bytes = b"kept attachment";
    put_object(&fx, bytes, "kept.txt");
    fs::write(
        fx.objects().join(".tmp-01JCB7Q4M8V2X5N9R3T6W0YZAE"),
        b"half an upload",
    )
    .unwrap();

    let outcome = run_backup(&fx.vault, &dest, T1, false);
    let BackupOutcome::Created { file, .. } = outcome else {
        panic!("a first backup creates a file: {outcome:?}");
    };
    let names = zip_names(&file);
    assert!(
        names.iter().all(|n| !n.contains(".tmp-")),
        "no .tmp-* member: {names:?}"
    );
    let member = rel_path(bytes, "kept.txt");
    assert!(names.contains(&member), "the attachment is in the backup");
    assert_eq!(zip_member(&file, &member), bytes);
    assert!(
        fx.objects()
            .join(".tmp-01JCB7Q4M8V2X5N9R3T6W0YZAE")
            .exists(),
        "the backup leaves the temp file alone"
    );
}

#[test]
fn a_new_objects_tmp_file_alone_does_not_change_the_if_changed_fingerprint() {
    let fx = Fx::new();
    let dest = fx.root.join("Backup Drive");
    fs::create_dir(&dest).unwrap();
    put_object(&fx, b"kept attachment", "kept.txt");
    let first = run_backup(&fx.vault, &dest, T1, false);
    assert!(matches!(first, BackupOutcome::Created { .. }), "{first:?}");
    fs::write(fx.objects().join(".tmp-zzzz"), b"a store in progress").unwrap();
    let second = run_backup(&fx.vault, &dest, T2, true);
    assert!(
        matches!(second, BackupOutcome::Unchanged { .. }),
        "a temp file is not part of the backup: {second:?}"
    );
}

#[test]
fn only_tmp_entries_directly_under_objects_are_skipped() {
    // A deeper file whose name happens to start with `.tmp-` is not a store
    // temp file (those live directly in objects/), so it is backed up: the
    // walk never drops anything else (architecture D9 of #315).
    let fx = Fx::new();
    let dest = fx.root.join("Backup Drive");
    fs::create_dir(&dest).unwrap();
    let bytes = b"kept attachment";
    put_object(&fx, bytes, ".tmp-looking name.txt");
    fs::create_dir_all(fx.objects().join("ab")).unwrap();
    fs::write(fx.objects().join("ab/.tmp-other"), b"other").unwrap();
    fs::write(fx.objects().join(".tmp-skipped"), b"temp").unwrap();
    let outcome = run_backup(&fx.vault, &dest, T1, false);
    let BackupOutcome::Created { file, .. } = outcome else {
        panic!("a first backup creates a file: {outcome:?}");
    };
    let names = zip_names(&file);
    let deep = rel_path(bytes, ".tmp-looking name.txt");
    assert!(names.contains(&deep), "{deep} is backed up: {names:?}");
    assert!(
        names.contains("objects/ab/.tmp-other"),
        "objects/ab/.tmp-other is backed up: {names:?}"
    );
    assert!(
        !names.contains("objects/.tmp-skipped"),
        "objects/.tmp-skipped is left out: {names:?}"
    );
}
