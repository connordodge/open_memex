//! WI #318 (R1b): one backup run, `backup::backup_with` (Spec #315 req 1-17a;
//! architecture D7, D9, D10, D11 and the R1b block of "Required guard and
//! call-count ACs").
//!
//! Every test drives the frozen entry point `backup::backup_with` through its
//! seams: a test clock (counts its reads), a probe that classifies paths as
//! local or network through `fs_guard`'s `FsInfo`, and an archive sink that
//! can watch the destination while the zip is written and fail part-way.
//! Vaults and destinations are temp folders whose names contain a space;
//! paths are compared canonical (`/private/var/...` on macOS).
//!
//! The lock tests hold `<vault>/backup.lock` with `flock` (D8) in a re-exec'd
//! copy of this test binary (`lock_holder_child_process`), never wall time:
//! the parent waits for the child's "LOCK-HELD" line, then SIGKILLs it.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Lines, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use memex_core::backup::fingerprint::Fingerprinter;
use memex_core::backup::state::{self, DestinationState};
use memex_core::backup::{
    self, ArchiveSink, BackupOutcome, BackupRequest, BackupSeams, BackupSource, FORMAT, LOCK_FILE,
    STATE_FILE,
};
use memex_core::fs_guard::FsInfo;
use memex_core::notes::{self, CreateNote};
use memex_core::{schema, Clock, MemexError, Vault};
use rusqlite::Connection;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---- constants --------------------------------------------------------------------------------

/// The vault_id of the shared `file_names.json` fixture.
const THIS: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAE";
/// The fixture's other vault.
const OTHER: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAF";
/// The vault folder's name and its label (D10: space -> `-`).
const VAULT_FOLDER: &str = "my notes";
const LABEL: &str = "my-notes";

/// 2026-11-10T10:00:00.250Z: newer than every name in `file_names.json`.
const T1: i64 = 1_794_304_800_250;
/// 2026-11-10T11:30:00.000Z.
const T2: i64 = 1_794_310_200_000;
/// 2026-11-11T08:00:00.999Z.
const T3: i64 = 1_794_384_000_999;

/// The objects/ files every fixture vault carries, by `/`-joined path
/// relative to `objects/`. Bytewise order is B.txt, a.txt, a/x.bin,
/// ab/cdef0123, sub dir/photo 1.png: a walk that sorts each folder's entries
/// by name puts a/x.bin before a.txt and is wrong (D7).
const OBJECTS: [(&str, &[u8]); 5] = [
    ("a.txt", b"alpha object"),
    ("a/x.bin", &[0, 1, 2, 3, 254, 255]),
    ("B.txt", b"bravo object"),
    ("ab/cdef0123", b"hashed object content"),
    ("sub dir/photo 1.png", b"\x89PNG\r\n\x1a\nnot really a png"),
];

/// The zip's file members, in order (req 1, D7).
const MEMBER_ORDER: [&str; 8] = [
    "memex.db",
    "manifest.json",
    "objects/B.txt",
    "objects/a.txt",
    "objects/a/x.bin",
    "objects/ab/cdef0123",
    "objects/sub dir/photo 1.png",
    "backup.json",
];

/// Directory members a zip may carry for that tree (`name/`).
const DIR_MEMBERS: [&str; 4] = ["objects/", "objects/a/", "objects/ab/", "objects/sub dir/"];

// ---- seams ------------------------------------------------------------------------------------

/// A clock that returns `start`, then `start + step`, ... and counts reads.
struct TestClock {
    next: AtomicI64,
    step: i64,
    reads: AtomicUsize,
}

impl TestClock {
    fn fixed(at_ms: i64) -> Self {
        Self::stepping(at_ms, 0)
    }

    fn stepping(start: i64, step: i64) -> Self {
        TestClock {
            next: AtomicI64::new(start),
            step,
            reads: AtomicUsize::new(0),
        }
    }

    fn reads(&self) -> usize {
        self.reads.load(Ordering::SeqCst)
    }
}

impl Clock for TestClock {
    fn now_ms(&self) -> i64 {
        self.reads.fetch_add(1, Ordering::SeqCst);
        self.next.fetch_add(self.step, Ordering::SeqCst)
    }
}

fn local_info() -> FsInfo {
    FsInfo::MacOs {
        fstypename: "apfs".into(),
        local: true,
    }
}

fn network_info() -> FsInfo {
    FsInfo::MacOs {
        fstypename: "smbfs".into(),
        local: false,
    }
}

fn local_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(local_info())
}

fn plain_sink(file: File) -> io::Result<Box<dyn ArchiveSink>> {
    Ok(Box::new(file))
}

/// What a [`WatchedSink`] saw while the zip was written.
#[derive(Default)]
struct Watch {
    dest: PathBuf,
    final_name: String,
    partial_name: String,
    /// Fail every write once this many bytes went through.
    fail_after: Option<usize>,
    wraps: AtomicUsize,
    bytes: AtomicUsize,
    writes: AtomicUsize,
    saw_partial: AtomicBool,
    saw_final: AtomicBool,
}

impl Watch {
    fn new(dest: &Path, final_name: &str, fail_after: Option<usize>) -> Arc<Self> {
        Arc::new(Watch {
            dest: dest.to_path_buf(),
            final_name: final_name.to_string(),
            partial_name: partial_of(final_name),
            fail_after,
            ..Default::default()
        })
    }

    fn wraps(&self) -> usize {
        self.wraps.load(Ordering::SeqCst)
    }

    fn bytes(&self) -> usize {
        self.bytes.load(Ordering::SeqCst)
    }
}

/// The `.partial` file, checking the destination on every write.
struct WatchedSink {
    file: File,
    watch: Arc<Watch>,
}

impl Write for WatchedSink {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let w = &self.watch;
        w.writes.fetch_add(1, Ordering::SeqCst);
        if w.dest.join(&w.partial_name).exists() {
            w.saw_partial.store(true, Ordering::SeqCst);
        }
        if w.dest.join(&w.final_name).exists() {
            w.saw_final.store(true, Ordering::SeqCst);
        }
        let n = match w.fail_after {
            Some(limit) => {
                let done = w.bytes.load(Ordering::SeqCst);
                if done >= limit {
                    return Err(io::Error::other("test sink: disk full mid-archive"));
                }
                self.file.write(&buf[..buf.len().min(limit - done)])?
            }
            None => self.file.write(buf)?,
        };
        w.bytes.fetch_add(n, Ordering::SeqCst);
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Seek for WatchedSink {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.file.seek(pos)
    }
}

/// A `wrap_archive` seam around `watch`.
fn watched(watch: &Arc<Watch>) -> impl Fn(File) -> io::Result<Box<dyn ArchiveSink>> {
    let watch = Arc::clone(watch);
    move |file| {
        watch.wraps.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(WatchedSink {
            file,
            watch: Arc::clone(&watch),
        }) as Box<dyn ArchiveSink>)
    }
}

// ---- names (computed here, independently of names.rs) -----------------------------------------

/// `YYYYMMDDTHHMMSSZ` for `at_ms` (UTC, milliseconds dropped).
fn stamp(at_ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at_ms)
        .unwrap()
        .format("%Y%m%dT%H%M%SZ")
        .to_string()
}

fn final_of(label: &str, at_ms: i64, vault_id: &str) -> String {
    format!("{label}-{}-{vault_id}.memex.zip", stamp(at_ms))
}

fn partial_of(final_name: &str) -> String {
    format!(".{final_name}.partial")
}

// ---- fixture vault ----------------------------------------------------------------------------

/// A canonical temp root (its name has a space) holding the vault folder
/// `my notes` and the destination `My Drive`.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    vault: PathBuf,
    dest: PathBuf,
    vault_id: String,
}

impl Fx {
    /// A current-schema vault with one note and [`OBJECTS`], closed.
    fn new() -> Self {
        let tmp = tempfile::Builder::new()
            .prefix("memex backup ")
            .tempdir()
            .unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let vault = root.join(VAULT_FOLDER);
        let dest = root.join("My Drive");
        fs::create_dir(&dest).unwrap();
        let vault_id = {
            let mut v = Vault::create(&vault).unwrap();
            notes::create_note(
                &mut v,
                CreateNote {
                    title: Some("Before the backup".into()),
                    content_md: "# Before the backup\n\nFirst note.".into(),
                    ..Default::default()
                },
            )
            .unwrap();
            v.vault_id().to_string()
        };
        write_objects(&vault);
        Fx {
            _tmp: tmp,
            root,
            vault,
            dest,
            vault_id,
        }
    }

    /// [`Fx::new`] with the manifest's vault_id set to `id` (the fixture's).
    fn with_id(id: &str) -> Self {
        let mut fx = Fx::new();
        let path = fx.vault.join("manifest.json");
        let mut manifest: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        manifest["vault_id"] = json!(id);
        fs::write(&path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
        fx.vault_id = id.to_string();
        fx
    }

    fn request(&self, keep: u16, if_changed: bool) -> BackupRequest<'_> {
        BackupRequest {
            vault: &self.vault,
            destination: &self.dest,
            keep,
            if_changed,
            source: BackupSource::Local,
        }
    }

    /// One backup into `My Drive` at `at_ms` through plain seams.
    fn run(&self, at_ms: i64, keep: u16, if_changed: bool) -> memex_core::Result<BackupOutcome> {
        let clock = TestClock::fixed(at_ms);
        let seams = BackupSeams {
            clock: &clock,
            probe: &local_probe,
            wrap_archive: &plain_sink,
        };
        backup::backup_with(&self.request(keep, if_changed), &seams)
    }

    /// One backup of `request` at `at_ms` whose sink is watched by `watch`.
    fn run_watched(
        &self,
        request: &BackupRequest,
        at_ms: i64,
        watch: &Arc<Watch>,
    ) -> memex_core::Result<BackupOutcome> {
        let clock = TestClock::fixed(at_ms);
        let wrap = watched(watch);
        let seams = BackupSeams {
            clock: &clock,
            probe: &local_probe,
            wrap_archive: &wrap,
        };
        backup::backup_with(request, &seams)
    }

    fn final_name(&self, at_ms: i64) -> String {
        final_of(LABEL, at_ms, &self.vault_id)
    }

    fn final_path(&self, at_ms: i64) -> PathBuf {
        self.dest.join(self.final_name(at_ms))
    }

    fn state(&self) -> Option<DestinationState> {
        state::destination_state(&self.vault, &self.dest)
    }

    fn state_bytes(&self) -> Option<Vec<u8>> {
        fs::read(self.vault.join(STATE_FILE)).ok()
    }

    /// Seeds `name` in the destination with content naming it.
    fn seed(&self, name: &str) -> PathBuf {
        let p = self.dest.join(name);
        fs::write(&p, format!("seeded {name}")).unwrap();
        p
    }
}

fn write_objects(vault: &Path) {
    for (rel, bytes) in OBJECTS {
        let p = vault.join("objects").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, bytes).unwrap();
    }
}

/// The names in `dir` (not recursive).
fn names(dir: &Path) -> BTreeSet<String> {
    fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

/// Every entry under `dir` by relative path: `None` for a folder, its bytes
/// for a file, `->target` bytes for a symlink.
fn tree(dir: &Path) -> BTreeMap<String, Option<Vec<u8>>> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeMap<String, Option<Vec<u8>>>) {
        for entry in fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            let rel = path
                .strip_prefix(base)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.file_type().is_symlink() {
                let target = fs::read_link(&path).unwrap();
                out.insert(rel, Some(format!("->{}", target.display()).into_bytes()));
            } else if meta.is_dir() {
                out.insert(rel, None);
                walk(base, &path, out);
            } else {
                out.insert(rel, Some(fs::read(&path).unwrap()));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

/// The `.memex.zip` files of `vault_id` in `dir`, by name.
fn backups_of(dir: &Path, vault_id: &str) -> BTreeSet<String> {
    names(dir)
        .into_iter()
        .filter(|n| n.ends_with(&format!("-{vault_id}.memex.zip")) && !n.starts_with('.'))
        .collect()
}

fn partials(dir: &Path) -> BTreeSet<String> {
    names(dir)
        .into_iter()
        .filter(|n| n.ends_with(".partial"))
        .collect()
}

fn code(result: &memex_core::Result<BackupOutcome>) -> &'static str {
    match result {
        Ok(_) => "ok",
        Err(e) => e.code(),
    }
}

fn created(outcome: BackupOutcome) -> (String, PathBuf, u64, String, Vec<PathBuf>) {
    match outcome {
        BackupOutcome::Created {
            vault_id,
            file,
            bytes,
            fingerprint,
            removed,
        } => (vault_id, file, bytes, fingerprint, removed),
        other => panic!("expected created, got {other:?}"),
    }
}

/// Restores the mode of a path on drop, so a test that made something
/// unreadable or unwritable cleans up even when it fails.
struct ModeGuard {
    path: PathBuf,
    mode: u32,
}

impl ModeGuard {
    fn set(path: &Path, mode: u32) -> Self {
        let old = fs::metadata(path).unwrap().permissions().mode();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
        ModeGuard {
            path: path.to_path_buf(),
            mode: old,
        }
    }
}

impl Drop for ModeGuard {
    fn drop(&mut self) {
        let _ = fs::set_permissions(&self.path, fs::Permissions::from_mode(self.mode));
    }
}

// ---- reading a backup -------------------------------------------------------------------------

struct Member {
    name: String,
    is_dir: bool,
    is_symlink: bool,
    deflated: bool,
    bytes: Vec<u8>,
}

fn read_zip(path: &Path) -> Vec<Member> {
    let mut zip = zip::ZipArchive::new(File::open(path).unwrap())
        .unwrap_or_else(|e| panic!("{} is a zip: {e}", path.display()));
    let mut out = Vec::new();
    for i in 0..zip.len() {
        let mut f = zip.by_index(i).unwrap();
        let name = String::from_utf8(f.name_raw().to_vec()).expect("UTF-8 member name");
        let is_dir = f.is_dir();
        let is_symlink = f.is_symlink();
        let deflated = f.compression() == zip::CompressionMethod::Deflated;
        let mut bytes = Vec::new();
        if !is_dir {
            f.read_to_end(&mut bytes).unwrap();
        }
        out.push(Member {
            name,
            is_dir,
            is_symlink,
            deflated,
            bytes,
        });
    }
    out
}

fn member<'m>(members: &'m [Member], name: &str) -> &'m Member {
    members
        .iter()
        .find(|m| m.name == name)
        .unwrap_or_else(|| panic!("no member {name}"))
}

fn backup_json(members: &[Member]) -> Value {
    serde_json::from_slice(&member(members, "backup.json").bytes).expect("backup.json is JSON")
}

/// The fingerprint of the zip's own bytes, fed to R1a's `Fingerprinter` in
/// D7's order: snapshot, manifest, then each objects/ file (path relative to
/// `objects/`) in member order.
fn fingerprint_of(members: &[Member]) -> String {
    let mut fp = Fingerprinter::new();
    fp.snapshot(&mut &member(members, "memex.db").bytes[..])
        .unwrap();
    fp.manifest(&member(members, "manifest.json").bytes);
    for m in members {
        if let Some(rel) = m.name.strip_prefix("objects/") {
            if !m.is_dir {
                fp.object(rel, &mut &m.bytes[..]).unwrap();
            }
        }
    }
    fp.finish()
}

/// Unzips every member under `into` (which must not exist).
fn unzip(members: &[Member], into: &Path) {
    fs::create_dir_all(into).unwrap();
    for m in members {
        let p = into.join(m.name.trim_end_matches('/'));
        if m.is_dir {
            fs::create_dir_all(&p).unwrap();
        } else {
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, &m.bytes).unwrap();
        }
    }
}

/// The snapshot in `members`, written to a temp folder and opened.
fn snapshot_db(members: &[Member]) -> (TempDir, Connection) {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("snapshot.db");
    fs::write(&path, &member(members, "memex.db").bytes).unwrap();
    let conn = Connection::open(&path).unwrap();
    (tmp, conn)
}

fn quick_check(conn: &Connection) -> String {
    conn.query_row("PRAGMA quick_check", [], |r| r.get(0))
        .unwrap()
}

fn count_titled(conn: &Connection, title: &str) -> i64 {
    conn.query_row(
        "SELECT COUNT(*) FROM notes WHERE title = ?1",
        [title],
        |r| r.get(0),
    )
    .unwrap()
}

// ---- the lock holder (a re-exec'd copy of this binary) ----------------------------------------

const HOLDER_ENV: &str = "MEMEX_318_LOCK_HOLDER_VAULT";

/// Not a check of its own. Run by [`LockHolder::spawn`] with `HOLDER_ENV`
/// set: takes `flock(LOCK_EX | LOCK_NB)` on `<vault>/backup.lock` (D8),
/// prints `LOCK-HELD`, then blocks on stdin until it is killed. Without the
/// variable it returns at once.
#[test]
fn lock_holder_child_process() {
    let Some(vault) = std::env::var_os(HOLDER_ENV) else {
        return;
    };
    let path = Path::new(&vault).join(LOCK_FILE);
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .unwrap();
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(
        rc,
        0,
        "child takes the lock: {}",
        io::Error::last_os_error()
    );
    println!("LOCK-HELD");
    io::stdout().flush().unwrap();
    let mut byte = [0u8; 1];
    let _ = io::stdin().read(&mut byte);
    drop(file);
}

/// Another process holding the vault's backup lock.
struct LockHolder {
    child: Child,
    _stdout: Lines<BufReader<ChildStdout>>,
}

impl LockHolder {
    fn spawn(vault: &Path) -> Self {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "lock_holder_child_process",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(HOLDER_ENV, vault)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("re-exec the test binary");
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        loop {
            match lines.next() {
                // libtest prints "test lock_holder_child_process ... " first.
                Some(Ok(line)) if line.ends_with("LOCK-HELD") => break,
                Some(Ok(_)) => continue,
                other => panic!("lock holder ended before taking the lock: {other:?}"),
            }
        }
        LockHolder {
            child,
            _stdout: lines,
        }
    }

    /// SIGKILL: the holder never runs any cleanup.
    fn kill(mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }
}

impl Drop for LockHolder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---- AC 1: the zip's members ------------------------------------------------------------------

#[test]
fn zip_holds_exactly_db_manifest_objects_and_backup_json_in_member_order() {
    let fx = Fx::new();
    // A first backup leaves backup-state.json and backup.lock in the vault.
    fx.run(T1, 30, false).unwrap();
    // The app's own folder and a stray file: never in a backup.
    fs::create_dir(fx.vault.join(".memex")).unwrap();
    fs::write(fx.vault.join(".memex/ui-state.json"), "{}").unwrap();
    fs::write(fx.vault.join("stray.txt"), "not a vault file").unwrap();
    // The vault is open (WAL kept, not checkpointed): -wal and -shm exist.
    let mut open = Vault::open(&fx.vault).unwrap();
    open.connection_ref()
        .pragma_update(None, "wal_autocheckpoint", 0)
        .unwrap();
    notes::create_note(
        &mut open,
        CreateNote {
            title: Some("While open".into()),
            content_md: "written while the vault is open".into(),
            ..Default::default()
        },
    )
    .unwrap();
    for f in ["memex.db-wal", "memex.db-shm", STATE_FILE, LOCK_FILE] {
        assert!(fx.vault.join(f).exists(), "precondition: {f} exists");
    }

    let (_, file, ..) = created(fx.run(T2, 30, false).unwrap());
    let members = read_zip(&file);

    let files: Vec<&str> = members
        .iter()
        .filter(|m| !m.is_dir)
        .map(|m| m.name.as_str())
        .collect();
    assert_eq!(files, MEMBER_ORDER, "file members, in order");
    assert_eq!(members.first().unwrap().name, "memex.db", "first member");
    assert_eq!(members.last().unwrap().name, "backup.json", "last member");
    assert_eq!(members[1].name, "manifest.json", "second member");
    let middle: Vec<&str> = members[2..members.len() - 1]
        .iter()
        .map(|m| m.name.as_str())
        .collect();
    for pair in middle.windows(2) {
        assert!(
            pair[0].as_bytes() < pair[1].as_bytes(),
            "objects/ members sorted bytewise: {middle:?}"
        );
    }
    for m in &members {
        assert!(!m.is_symlink, "{} is not a symlink member", m.name);
        if m.is_dir {
            assert!(
                DIR_MEMBERS.contains(&m.name.as_str()),
                "folder member {} is a folder of objects/",
                m.name
            );
        } else {
            assert!(m.deflated, "{} is deflate-compressed", m.name);
        }
    }
    for banned in [
        "memex.db-wal",
        "memex.db-shm",
        STATE_FILE,
        LOCK_FILE,
        "stray.txt",
    ] {
        assert!(
            !members.iter().any(|m| m.name.contains(banned)),
            "{banned} is never in a backup"
        );
    }
    assert!(
        !members.iter().any(|m| m.name.starts_with(".memex")),
        ".memex/ is never in a backup"
    );
    assert_eq!(
        member(&members, "manifest.json").bytes,
        fs::read(fx.vault.join("manifest.json")).unwrap(),
        "manifest.json is copied"
    );
    for (rel, bytes) in OBJECTS {
        assert_eq!(
            member(&members, &format!("objects/{rel}")).bytes,
            bytes,
            "objects/{rel} is copied"
        );
    }
    drop(open);
}

#[test]
fn unzipped_backup_opens_as_a_vault_with_the_same_notes() {
    let fx = Fx::new();
    let (_, file, ..) = created(fx.run(T1, 30, false).unwrap());
    let members = read_zip(&file);
    let into = fx.root.join("unzipped vault");
    unzip(&members, &into);

    let opened = Vault::open(&into).expect("an unzipped backup opens as a vault");
    assert_eq!(opened.vault_id(), fx.vault_id);
    let titles: BTreeSet<String> = notes::list_notes(&opened, 100)
        .unwrap()
        .into_iter()
        .map(|n| n.title)
        .collect();
    let original = Vault::open(&fx.vault).unwrap();
    let expected: BTreeSet<String> = notes::list_notes(&original, 100)
        .unwrap()
        .into_iter()
        .map(|n| n.title)
        .collect();
    assert!(titles.contains("Before the backup"), "{titles:?}");
    assert_eq!(titles, expected);
    assert_eq!(
        quick_check(opened.connection_ref()),
        "ok",
        "the snapshot passes quick_check"
    );
}

// ---- AC 2: backup.json ------------------------------------------------------------------------

#[test]
fn backup_json_has_exactly_the_requirement_3_keys_and_values() {
    let fx = Fx::new();
    let (vault_id, file, _, fingerprint, _) = created(fx.run(T1, 30, false).unwrap());
    let members = read_zip(&file);
    let bj = backup_json(&members);

    let keys: BTreeSet<&str> = bj.as_object().unwrap().keys().map(|k| k.as_str()).collect();
    assert_eq!(
        keys,
        BTreeSet::from([
            "format",
            "vault_id",
            "schema_version",
            "created_at",
            "memex_version",
            "fingerprint",
            "source",
        ]),
        "{bj}"
    );
    assert_eq!(bj["format"], json!(FORMAT));
    assert_eq!(bj["vault_id"], json!(fx.vault_id));
    assert_eq!(vault_id, fx.vault_id);
    assert_eq!(bj["schema_version"], json!(schema::APP_SCHEMA_VERSION));
    assert_eq!(bj["created_at"], json!(T1));
    assert_eq!(bj["memex_version"], json!(env!("CARGO_PKG_VERSION")));
    assert_eq!(bj["source"], json!("local"));

    let recorded = fx.state().expect("recorded").last_fingerprint;
    assert_eq!(
        bj["fingerprint"],
        json!(fingerprint),
        "backup.json = outcome"
    );
    assert_eq!(
        recorded.as_deref(),
        Some(fingerprint.as_str()),
        "recorded = outcome"
    );
    assert_eq!(fingerprint.len(), 64, "hex SHA-256: {fingerprint}");
    assert!(
        fingerprint
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
        "lowercase hex: {fingerprint}"
    );
    assert_eq!(
        fingerprint,
        fingerprint_of(&members),
        "the fingerprint is of the zip's own bytes"
    );
}

#[test]
fn backup_json_source_is_hosted_for_a_hosted_request() {
    let fx = Fx::new();
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        source: BackupSource::Hosted,
        ..fx.request(30, false)
    };
    let (_, file, ..) = created(backup::backup_with(&request, &seams).unwrap());
    assert_eq!(backup_json(&read_zip(&file))["source"], json!("hosted"));
}

#[test]
fn backup_json_schema_version_comes_from_the_snapshot_not_the_manifest() {
    let fx = Fx::new();
    let path = fx.vault.join("manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    manifest["schema_version"] = json!(4);
    fs::write(&path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();

    let (_, file, ..) = created(fx.run(T1, 30, false).unwrap());
    let bj = backup_json(&read_zip(&file));
    assert_eq!(bj["schema_version"], json!(schema::APP_SCHEMA_VERSION));
}

/// The recorded and printed fingerprint is the write pass's (D7): an
/// objects/ file that changes after the `--if-changed` pre-pass (here, while
/// the sink is being set up) is fingerprinted as the zip holds it.
#[test]
fn recorded_fingerprint_is_the_write_pass_fingerprint_of_the_zip_bytes() {
    let fx = Fx::new();
    let changed = fx.vault.join("objects/B.txt");
    let wrap = |file: File| -> io::Result<Box<dyn ArchiveSink>> {
        fs::write(&changed, b"bravo object, changed after the pre-pass")?;
        Ok(Box::new(file))
    };
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &wrap,
    };
    let (_, file, _, fingerprint, _) =
        created(backup::backup_with(&fx.request(30, true), &seams).unwrap());
    let members = read_zip(&file);
    assert_eq!(fingerprint, fingerprint_of(&members), "outcome = zip bytes");
    assert_eq!(backup_json(&members)["fingerprint"], json!(fingerprint));
    assert_eq!(
        fx.state().unwrap().last_fingerprint.as_deref(),
        Some(fingerprint.as_str())
    );
}

// ---- AC 3: WAL rows ---------------------------------------------------------------------------

#[test]
fn rows_only_in_the_wal_of_an_open_vault_are_in_the_backup() {
    let fx = Fx::new();
    let mut open = Vault::open(&fx.vault).unwrap();
    open.connection_ref()
        .pragma_update(None, "wal_autocheckpoint", 0)
        .unwrap();
    notes::create_note(
        &mut open,
        CreateNote {
            title: Some("Only in the WAL".into()),
            content_md: "never checkpointed".into(),
            ..Default::default()
        },
    )
    .unwrap();
    // Precondition: memex.db alone (without its -wal) lacks the row.
    let main_only = TempDir::new().unwrap();
    let copy = main_only.path().join("memex.db");
    fs::copy(fx.vault.join("memex.db"), &copy).unwrap();
    assert_eq!(
        count_titled(&Connection::open(&copy).unwrap(), "Only in the WAL"),
        0,
        "precondition: the row is only in the WAL"
    );
    assert!(fs::metadata(fx.vault.join("memex.db-wal")).unwrap().len() > 0);

    let (_, file, ..) = created(fx.run(T1, 30, false).unwrap());
    let members = read_zip(&file);
    let (_tmp, snap) = snapshot_db(&members);
    assert_eq!(count_titled(&snap, "Only in the WAL"), 1);
    assert_eq!(quick_check(&snap), "ok");
    drop(open);
}

// ---- AC 4: a concurrent writer ----------------------------------------------------------------

#[test]
fn backup_completes_and_is_consistent_while_another_connection_writes_in_a_loop() {
    let fx = Fx::new();
    let db = fx.vault.join("memex.db");
    {
        let c = Connection::open(&db).unwrap();
        c.execute_batch("CREATE TABLE t318_pairs (n INTEGER NOT NULL);")
            .unwrap();
    }
    let stop = Arc::new(AtomicBool::new(false));
    let commits = Arc::new(AtomicUsize::new(0));
    let writer = {
        let (stop, commits, db) = (Arc::clone(&stop), Arc::clone(&commits), db.clone());
        thread::spawn(move || {
            let c = Connection::open(&db).unwrap();
            c.busy_timeout(std::time::Duration::from_secs(5)).unwrap();
            c.pragma_update(None, "journal_mode", "WAL").unwrap();
            let mut i: i64 = 1;
            while !stop.load(Ordering::SeqCst) {
                let tx = c.unchecked_transaction().unwrap();
                tx.execute("INSERT INTO t318_pairs (n) VALUES (?1)", [i])
                    .unwrap();
                tx.execute("INSERT INTO t318_pairs (n) VALUES (?1)", [-i])
                    .unwrap();
                tx.commit().unwrap();
                commits.fetch_add(1, Ordering::SeqCst);
                i += 1;
            }
        })
    };
    // Wait on the writer's own progress (an event), never on wall time.
    while commits.load(Ordering::SeqCst) < 3 {
        assert!(!writer.is_finished(), "the writer stopped early");
        thread::yield_now();
    }
    let before = commits.load(Ordering::SeqCst);
    let result = fx.run(T1, 30, false);
    let after = commits.load(Ordering::SeqCst);
    stop.store(true, Ordering::SeqCst);
    writer.join().unwrap();

    let (_, file, ..) = created(result.expect("the backup completes under a writer"));
    let members = read_zip(&file);
    let (_tmp, snap) = snapshot_db(&members);
    assert_eq!(quick_check(&snap), "ok");
    let (rows, sum): (i64, i64) = snap
        .query_row(
            "SELECT COUNT(*), COALESCE(SUM(n), 0) FROM t318_pairs",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(rows % 2, 0, "whole transactions only: {rows} rows");
    assert_eq!(sum, 0, "whole transactions only");
    let pairs = (rows / 2) as usize;
    assert!(
        pairs >= before && pairs <= after + 1,
        "one moment between {before} and {after} commits: {pairs}"
    );
}

// ---- AC 5: the vault is never written ---------------------------------------------------------

/// SQLite's own files and the two backup files are the only entries a
/// backup may add to the vault folder.
const ALLOWED_NEW: [&str; 4] = [LOCK_FILE, STATE_FILE, "memex.db-wal", "memex.db-shm"];

fn assert_vault_untouched(
    vault: &Path,
    top_before: &BTreeSet<String>,
    files_before: &BTreeMap<&str, Vec<u8>>,
    objects_before: &BTreeMap<String, Option<Vec<u8>>>,
) {
    for (name, bytes) in files_before {
        assert_eq!(
            &fs::read(vault.join(name)).unwrap(),
            bytes,
            "{name} is byte-identical"
        );
    }
    assert_eq!(
        &tree(&vault.join("objects")),
        objects_before,
        "objects/ is identical"
    );
    let top_after = names(vault);
    let removed: Vec<_> = top_before.difference(&top_after).collect();
    assert!(removed.is_empty(), "nothing removed: {removed:?}");
    let added: BTreeSet<&str> = top_after
        .difference(top_before)
        .map(|s| s.as_str())
        .collect();
    for name in &added {
        assert!(
            ALLOWED_NEW.contains(name),
            "only backup.lock, backup-state.json, -wal, -shm are new; got {added:?}"
        );
    }
    assert!(added.contains(STATE_FILE), "the attempt is recorded");
}

#[test]
fn backup_leaves_a_current_schema_vault_byte_identical() {
    let fx = Fx::new();
    let top = names(&fx.vault);
    let files = BTreeMap::from([
        ("memex.db", fs::read(fx.vault.join("memex.db")).unwrap()),
        (
            "manifest.json",
            fs::read(fx.vault.join("manifest.json")).unwrap(),
        ),
    ]);
    let objects = tree(&fx.vault.join("objects"));
    assert!(!top.contains(STATE_FILE) && !top.contains(LOCK_FILE));

    let (_, file, ..) = created(fx.run(T1, 30, false).unwrap());
    assert_vault_untouched(&fx.vault, &top, &files, &objects);
    let bj = backup_json(&read_zip(&file));
    assert_eq!(bj["schema_version"], json!(schema::APP_SCHEMA_VERSION));
}

/// A vault folder on the previous schema (V5), never opened by this memex.
fn v5_vault(root: &Path) -> PathBuf {
    let vault = root.join("old notes");
    fs::create_dir(&vault).unwrap();
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
    write_objects(&vault);
    vault
}

#[test]
fn backup_leaves_a_v5_vault_byte_identical_and_records_schema_version_5() {
    let fx = Fx::new();
    let vault = v5_vault(&fx.root);
    let top = names(&vault);
    let files = BTreeMap::from([
        ("memex.db", fs::read(vault.join("memex.db")).unwrap()),
        (
            "manifest.json",
            fs::read(vault.join("manifest.json")).unwrap(),
        ),
    ]);
    let objects = tree(&vault.join("objects"));

    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        vault: &vault,
        ..fx.request(30, false)
    };
    let (_, file, ..) = created(backup::backup_with(&request, &seams).unwrap());

    assert_vault_untouched(&vault, &top, &files, &objects);
    let members = read_zip(&file);
    assert_eq!(backup_json(&members)["schema_version"], json!(5));
    let (_tmp, snap) = snapshot_db(&members);
    let version: i64 = snap
        .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 5, "the snapshot is not migrated");
    assert_eq!(count_titled(&snap, "A V5 note"), 1);
}

// ---- AC 6: the lock ---------------------------------------------------------------------------

#[test]
fn lock_held_by_another_process_fails_backup_in_progress_and_touches_nothing() {
    let fx = Fx::new();
    fx.run(T1, 30, false).unwrap();
    let leftover = fx.seed(&partial_of(&fx.final_name(T1 - 86_400_000)));
    let listing = names(&fx.dest);
    let state = fx.state_bytes().expect("state from the first backup");

    let holder = LockHolder::spawn(&fx.vault);
    let watch = Watch::new(&fx.dest, &fx.final_name(T2), None);
    let result = fx.run_watched(&fx.request(1, false), T2, &watch);

    assert_eq!(code(&result), "backup_in_progress", "{result:?}");
    assert_eq!(names(&fx.dest), listing, "no .partial created or deleted");
    assert!(leftover.exists(), "the leftover partial is not deleted");
    assert_eq!(fx.state_bytes(), Some(state), "backup-state.json unchanged");
    assert_eq!(watch.wraps(), 0, "nothing is written");
    holder.kill();
}

#[test]
fn lock_held_on_a_never_backed_up_vault_leaves_backup_state_absent() {
    let fx = Fx::new();
    let listing = names(&fx.dest);
    let holder = LockHolder::spawn(&fx.vault);
    let result = fx.run(T1, 30, false);
    assert_eq!(code(&result), "backup_in_progress", "{result:?}");
    assert_eq!(fx.state_bytes(), None, "backup-state.json still absent");
    assert_eq!(names(&fx.dest), listing);
    holder.kill();
}

#[test]
fn lock_left_by_a_sigkilled_process_does_not_block_the_next_backup() {
    let fx = Fx::new();
    let holder = LockHolder::spawn(&fx.vault);
    assert_eq!(code(&fx.run(T1, 30, false)), "backup_in_progress");
    holder.kill();

    let (_, file, ..) = created(
        fx.run(T2, 30, false)
            .expect("the dead holder's lock is gone"),
    );
    assert_eq!(file, fx.final_path(T2));
    assert_eq!(fx.state().unwrap().last_result, "created");
}

// ---- AC 7: --if-changed -----------------------------------------------------------------------

#[test]
fn if_changed_with_no_writes_creates_no_file_and_records_unchanged() {
    let fx = Fx::new();
    let (_, first_file, first_bytes, first_fp, _) = created(fx.run(T1, 30, false).unwrap());
    let before = fx.state().unwrap();
    let listing = names(&fx.dest);

    let watch = Watch::new(&fx.dest, &fx.final_name(T2), None);
    let outcome = fx.run_watched(&fx.request(30, true), T2, &watch).unwrap();

    assert_eq!(
        outcome,
        BackupOutcome::Unchanged {
            vault_id: fx.vault_id.clone(),
            fingerprint: first_fp.clone(),
            last_file: Some(first_file.clone()),
        }
    );
    assert_eq!(names(&fx.dest), listing, "0 new files, no .partial left");
    assert_eq!(watch.wraps(), 0, "an unchanged run writes no zip");
    let after = fx.state().unwrap();
    assert_eq!(after.last_result, "unchanged");
    assert_eq!(after.last_attempt_at, T2);
    assert_eq!(after.last_success_at, Some(T2), "last_success_at advances");
    assert_eq!(after.last_error, None);
    assert_eq!(after.last_file, before.last_file, "last_file unchanged");
    assert_eq!(after.last_file, Some(fx.final_name(T1)));
    assert_eq!(after.last_file_created_at, Some(T1));
    assert_eq!(after.last_bytes, Some(first_bytes));
    assert_eq!(after.last_fingerprint, Some(first_fp));
}

#[test]
fn if_changed_after_one_write_creates_exactly_one_new_file() {
    let fx = Fx::new();
    let (.., first_fp, _) = created(fx.run(T1, 30, false).unwrap());
    {
        let mut v = Vault::open(&fx.vault).unwrap();
        notes::create_note(
            &mut v,
            CreateNote {
                title: Some("One write".into()),
                content_md: "between the two backups".into(),
                ..Default::default()
            },
        )
        .unwrap();
    }
    let listing = names(&fx.dest);
    let (_, file, _, fp, _) = created(fx.run(T2, 30, true).unwrap());
    let new: Vec<String> = names(&fx.dest).difference(&listing).cloned().collect();
    assert_eq!(new, vec![fx.final_name(T2)], "exactly 1 new file");
    assert_eq!(file, fx.final_path(T2));
    assert_ne!(fp, first_fp);
    assert_eq!(fx.state().unwrap().last_result, "created");
}

#[test]
fn if_changed_with_no_recorded_fingerprint_creates_a_file() {
    let fx = Fx::new();
    let (_, file, ..) = created(fx.run(T1, 30, true).unwrap());
    assert!(file.exists());
}

#[test]
fn if_changed_compares_with_this_destination_only() {
    let fx = Fx::new();
    fx.run(T1, 30, false).unwrap();
    let other = fx.root.join("Other Drive");
    fs::create_dir(&other).unwrap();
    let clock = TestClock::fixed(T2);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        destination: &other,
        ..fx.request(30, true)
    };
    let (_, file, ..) = created(backup::backup_with(&request, &seams).unwrap());
    assert_eq!(file, other.join(fx.final_name(T2)));
}

#[test]
fn if_changed_after_a_failed_attempt_still_compares_with_the_last_success() {
    let fx = Fx::new();
    let (_, first_file, ..) = created(fx.run(T1, 30, false).unwrap());
    let watch = Watch::new(&fx.dest, &fx.final_name(T2), Some(64));
    assert_eq!(
        code(&fx.run_watched(&fx.request(30, false), T2, &watch)),
        "backup_failed"
    );
    match fx.run(T3, 30, true).unwrap() {
        BackupOutcome::Unchanged { last_file, .. } => assert_eq!(last_file, Some(first_file)),
        other => panic!("expected unchanged, got {other:?}"),
    }
}

#[test]
fn without_if_changed_an_unchanged_vault_still_gets_a_new_file() {
    let fx = Fx::new();
    fx.run(T1, 30, false).unwrap();
    fx.run(T2, 30, false).unwrap();
    assert_eq!(
        backups_of(&fx.dest, &fx.vault_id),
        BTreeSet::from([fx.final_name(T1), fx.final_name(T2)])
    );
}

// ---- D9: one clock read -----------------------------------------------------------------------

#[test]
fn clock_is_read_once_and_stamps_every_time_field() {
    let fx = Fx::new();
    // Each read is a second later than the one before.
    let clock = TestClock::stepping(T1, 1_000);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let (_, file, ..) = created(backup::backup_with(&fx.request(30, false), &seams).unwrap());
    assert_eq!(clock.reads(), 1, "the clock is read once");
    assert_eq!(file, fx.final_path(T1), "file name timestamp");
    assert_eq!(backup_json(&read_zip(&file))["created_at"], json!(T1));
    let s = fx.state().unwrap();
    assert_eq!(s.last_attempt_at, T1);
    assert_eq!(s.last_success_at, Some(T1));
    assert_eq!(s.last_file_created_at, Some(T1));

    let clock = TestClock::stepping(T2, 1_000);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    backup::backup_with(&fx.request(30, true), &seams).unwrap();
    assert_eq!(clock.reads(), 1, "an unchanged run reads the clock once");
    let s = fx.state().unwrap();
    assert_eq!((s.last_attempt_at, s.last_success_at), (T2, Some(T2)));
}

// ---- AC 8: the same second --------------------------------------------------------------------

#[test]
fn two_backups_in_the_same_second_leave_one_file_and_retention_counts_it_once() {
    let fx = Fx::new();
    let old_a = fx.seed(&final_of(LABEL, T1 - 2 * 86_400_000, &fx.vault_id));
    let old_b = fx.seed(&final_of(LABEL, T1 - 86_400_000, &fx.vault_id));
    let first = T1; // ...:00.250
    let second = T1 + 600; // ...:00.850, the same second
    assert_eq!(fx.final_name(first), fx.final_name(second));

    let (.., removed_1) = created(fx.run(first, 3, false).unwrap());
    let (_, file, bytes, _, removed_2) = created(fx.run(second, 3, false).unwrap());

    assert_eq!(removed_1, Vec::<PathBuf>::new());
    assert_eq!(
        removed_2,
        Vec::<PathBuf>::new(),
        "the replaced file counts once"
    );
    assert!(old_a.exists() && old_b.exists());
    assert_eq!(backups_of(&fx.dest, &fx.vault_id).len(), 3);
    assert_eq!(file, fx.final_path(second));
    assert_eq!(fs::metadata(&file).unwrap().len(), bytes);
    assert_eq!(
        backup_json(&read_zip(&file))["created_at"],
        json!(second),
        "the second backup replaced the first"
    );
    assert!(partials(&fx.dest).is_empty());
}

#[test]
fn a_leftover_partial_with_this_runs_name_is_truncated_not_appended() {
    let fx = Fx::new();
    let partial = fx.dest.join(partial_of(&fx.final_name(T1)));
    fs::write(&partial, vec![0xAB; 200_000]).unwrap();
    let (_, file, bytes, ..) = created(fx.run(T1, 30, false).unwrap());
    let len = fs::metadata(&file).unwrap().len();
    assert_eq!(len, bytes);
    assert!(len < 200_000, "the leftover bytes are gone: {len}");
    let files = read_zip(&file).into_iter().filter(|m| !m.is_dir).count();
    assert_eq!(files, MEMBER_ORDER.len(), "a whole zip");
    assert!(!partial.exists());
}

// ---- AC 9: the network-drive guard ------------------------------------------------------------

#[test]
fn destination_the_probe_calls_a_network_filesystem_succeeds() {
    let fx = Fx::new();
    let dest = fx.dest.clone();
    let probe = move |p: &Path| -> io::Result<FsInfo> {
        Ok(if p.starts_with(&dest) {
            network_info()
        } else {
            local_info()
        })
    };
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &probe,
        wrap_archive: &plain_sink,
    };
    let (_, file, ..) = created(backup::backup_with(&fx.request(30, false), &seams).unwrap());
    assert_eq!(file, fx.final_path(T1));
}

#[test]
fn vault_the_probe_calls_a_network_filesystem_fails_and_creates_nothing() {
    let fx = Fx::new();
    let vault_listing = names(&fx.vault);
    let dest_listing = names(&fx.dest);
    let asked = Mutex::new(Vec::<PathBuf>::new());
    let vault = fx.vault.clone();
    let probe = |p: &Path| -> io::Result<FsInfo> {
        asked.lock().unwrap().push(p.to_path_buf());
        Ok(if p.starts_with(&vault) {
            network_info()
        } else {
            local_info()
        })
    };
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &probe,
        wrap_archive: &plain_sink,
    };
    let result = backup::backup_with(&fx.request(30, false), &seams);

    assert_eq!(code(&result), "network_filesystem", "{result:?}");
    assert!(
        asked
            .lock()
            .unwrap()
            .iter()
            .any(|p| p.starts_with(&fx.vault)),
        "the vault was probed"
    );
    assert!(!fx.vault.join(LOCK_FILE).exists(), "not even backup.lock");
    assert_eq!(fx.state_bytes(), None, "nothing recorded");
    assert_eq!(names(&fx.vault), vault_listing);
    assert_eq!(names(&fx.dest), dest_listing);
}

// ---- pre-lock failures (D9 steps 1-3) are never recorded --------------------------------------

#[test]
fn vault_id_that_is_not_a_ulid_fails_backup_failed_before_the_lock() {
    let fx = Fx::with_id("not-a-ulid");
    let result = fx.run(T1, 30, false);
    match &result {
        Err(e @ MemexError::BackupFailed(msg)) => {
            assert_eq!(e.code(), "backup_failed");
            assert!(
                msg.contains("vault_id"),
                "the message names vault_id: {msg}"
            );
        }
        other => panic!("expected backup_failed, got {other:?}"),
    }
    assert!(!fx.vault.join(LOCK_FILE).exists(), "before the lock");
    assert_eq!(fx.state_bytes(), None, "not recorded");
    assert!(names(&fx.dest).is_empty());
}

#[test]
fn missing_vault_folder_fails_internal_and_creates_nothing() {
    let fx = Fx::new();
    let missing = fx.root.join("no such vault");
    let request = BackupRequest {
        vault: &missing,
        ..fx.request(30, false)
    };
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let result = backup::backup_with(&request, &seams);
    assert_eq!(code(&result), "internal", "{result:?}");
    assert!(!missing.exists(), "the vault folder is not created");
    assert!(names(&fx.dest).is_empty());
}

// ---- AC 10: destinations ----------------------------------------------------------------------

/// A failure recorded under the destination's key at `at_ms`, with no
/// success or file history.
fn assert_recorded_failure(fx: &Fx, dest: &Path, code: &str, at_ms: i64) {
    let s = state::destination_state(&fx.vault, dest)
        .unwrap_or_else(|| panic!("{code} is recorded for {}", dest.display()));
    assert_eq!(s.last_result, code);
    assert_eq!(s.last_attempt_at, at_ms);
    assert!(
        s.last_error.as_deref().is_some_and(|m| !m.is_empty()),
        "last_error is the message: {s:?}"
    );
    assert_eq!(s.last_success_at, None);
    assert_eq!(s.last_file, None);
    assert_eq!(s.last_file_created_at, None);
    assert_eq!(s.last_bytes, None);
    assert_eq!(s.last_fingerprint, None);
}

/// Runs a backup into `dest` with `memex.db` unreadable: a run that took the
/// snapshot before checking the destination would fail `backup_failed`
/// instead (D9: steps 4 and 5 come before step 7).
fn run_before_snapshot(fx: &Fx, dest: &Path) -> memex_core::Result<BackupOutcome> {
    let _db = ModeGuard::set(&fx.vault.join("memex.db"), 0o000);
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        destination: dest,
        ..fx.request(30, false)
    };
    backup::backup_with(&request, &seams)
}

#[test]
fn missing_destination_fails_unavailable_before_any_snapshot_and_is_recorded() {
    let fx = Fx::new();
    let missing = fx.root.join("No Such Folder");
    let result = run_before_snapshot(&fx, &missing);
    assert_eq!(
        code(&result),
        "backup_destination_unavailable",
        "{result:?}"
    );
    assert!(
        !missing.exists(),
        "memex backup never creates the destination"
    );
    assert_recorded_failure(&fx, &missing, "backup_destination_unavailable", T1);
    let recorded = state::read_state(&fx.vault);
    let key = fx
        .root
        .join("No Such Folder")
        .to_string_lossy()
        .into_owned();
    assert!(
        recorded.destinations.contains_key(&key),
        "recorded under destination_key: {:?}",
        recorded.destinations.keys()
    );
}

#[test]
fn file_as_destination_fails_unavailable_and_is_recorded() {
    let fx = Fx::new();
    let file = fx.root.join("a file.txt");
    fs::write(&file, "not a folder").unwrap();
    let result = run_before_snapshot(&fx, &file);
    assert_eq!(
        code(&result),
        "backup_destination_unavailable",
        "{result:?}"
    );
    assert_eq!(fs::read(&file).unwrap(), b"not a folder");
    assert_recorded_failure(&fx, &file, "backup_destination_unavailable", T1);
}

#[test]
fn unwritable_destination_fails_unavailable_with_no_partial_and_is_recorded() {
    let fx = Fx::new();
    let leftover = fx.seed(&partial_of(&fx.final_name(T1 - 86_400_000)));
    let listing = names(&fx.dest);
    let result = {
        let _dest = ModeGuard::set(&fx.dest, 0o555);
        run_before_snapshot(&fx, &fx.dest)
    };
    assert_eq!(
        code(&result),
        "backup_destination_unavailable",
        "{result:?}"
    );
    assert_eq!(names(&fx.dest), listing, "no .partial");
    assert!(leftover.exists());
    assert_recorded_failure(&fx, &fx.dest, "backup_destination_unavailable", T1);
}

/// A folder macOS won't let memex look into (a refused Files and Folders
/// prompt): `backup_destination_unavailable`, never `internal`, recorded
/// under the key `destination_key` walks up to (lesson, R0 #330 r1).
#[test]
fn destination_behind_a_refused_folder_fails_unavailable_not_internal() {
    let fx = Fx::new();
    let locked = fx.root.join("Locked Drive");
    let dest = locked.join("Open Memex Backups");
    fs::create_dir_all(&dest).unwrap();
    let result = {
        let _locked = ModeGuard::set(&locked, 0o000);
        let result = run_before_snapshot(&fx, &dest);
        let recorded = state::read_state(&fx.vault);
        let key = dest.to_string_lossy().into_owned();
        assert!(
            recorded.destinations.contains_key(&key),
            "recorded under {key}: {:?}",
            recorded.destinations.keys()
        );
        assert_eq!(recorded.destinations[&key].last_result, code(&result));
        result
    };
    assert_eq!(
        code(&result),
        "backup_destination_unavailable",
        "{result:?}"
    );
    assert!(names(&dest).is_empty(), "nothing written");
}

#[test]
fn destination_inside_the_vault_fails_inside_vault_and_is_recorded() {
    let fx = Fx::new();
    let inside = fx.vault.join("backups here");
    fs::create_dir(&inside).unwrap();
    let result = run_before_snapshot(&fx, &inside);
    assert_eq!(
        code(&result),
        "backup_destination_inside_vault",
        "{result:?}"
    );
    assert!(
        names(&inside).is_empty(),
        "nothing written inside the vault"
    );
    assert_recorded_failure(&fx, &inside, "backup_destination_inside_vault", T1);
}

#[test]
fn destination_equal_to_the_vault_fails_inside_vault_and_is_recorded() {
    let fx = Fx::new();
    let top = names(&fx.vault);
    let result = run_before_snapshot(&fx, &fx.vault);
    assert_eq!(
        code(&result),
        "backup_destination_inside_vault",
        "{result:?}"
    );
    let added: BTreeSet<String> = names(&fx.vault).difference(&top).cloned().collect();
    assert!(
        added.iter().all(|n| n == LOCK_FILE || n == STATE_FILE),
        "no partial or zip in the vault: {added:?}"
    );
    assert_recorded_failure(&fx, &fx.vault, "backup_destination_inside_vault", T1);
}

#[test]
fn destination_reached_through_a_symlink_into_the_vault_fails_inside_vault() {
    let fx = Fx::new();
    fs::create_dir(fx.vault.join("inner")).unwrap();
    let link = fx.root.join("vault link");
    symlink(&fx.vault, &link).unwrap();
    for dest in [link.join("inner"), link.clone()] {
        let result = run_before_snapshot(&fx, &dest);
        assert_eq!(
            code(&result),
            "backup_destination_inside_vault",
            "{}: {result:?}",
            dest.display()
        );
    }
}

#[test]
fn sibling_folder_sharing_the_vault_name_prefix_is_not_inside_the_vault() {
    let fx = Fx::new();
    let sibling = fx.root.join(format!("{VAULT_FOLDER} backups"));
    fs::create_dir(&sibling).unwrap();
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        destination: &sibling,
        ..fx.request(30, false)
    };
    let (_, file, ..) = created(backup::backup_with(&request, &seams).unwrap());
    assert_eq!(file, sibling.join(fx.final_name(T1)));
}

// ---- the created outcome ----------------------------------------------------------------------

#[test]
fn created_outcome_uses_the_destination_key_for_file_and_removed() {
    let fx = Fx::new();
    let old = fx.seed(&final_of(LABEL, T1 - 86_400_000, &fx.vault_id));
    let link = fx.root.join("Drive link");
    symlink(&fx.dest, &link).unwrap();
    let clock = TestClock::fixed(T1);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        destination: &link,
        ..fx.request(1, false)
    };
    let (vault_id, file, bytes, fingerprint, removed) =
        created(backup::backup_with(&request, &seams).unwrap());

    assert_eq!(vault_id, fx.vault_id);
    assert_eq!(file, fx.final_path(T1), "absolute, symlinks resolved");
    assert_eq!(removed, vec![old.clone()], "absolute, symlinks resolved");
    assert!(!old.exists());
    assert_eq!(bytes, fs::metadata(&file).unwrap().len());
    let recorded = state::read_state(&fx.vault);
    let key = fx.dest.to_string_lossy().into_owned();
    let s = recorded
        .destinations
        .get(&key)
        .unwrap_or_else(|| panic!("keyed by destination_key: {recorded:?}"));
    assert_eq!(s.last_result, "created");
    assert_eq!(s.last_file, Some(fx.final_name(T1)));
    assert_eq!(s.last_bytes, Some(bytes));
    assert_eq!(s.last_fingerprint, Some(fingerprint));
    assert_eq!(s.last_error, None);

    let clock = TestClock::fixed(T2);
    let seams = BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = BackupRequest {
        destination: &link,
        ..fx.request(1, true)
    };
    match backup::backup_with(&request, &seams).unwrap() {
        BackupOutcome::Unchanged { last_file, .. } => {
            assert_eq!(last_file, Some(fx.final_path(T1)))
        }
        other => panic!("expected unchanged, got {other:?}"),
    }
}

#[test]
fn the_zip_appears_under_its_final_name_only_when_complete() {
    let fx = Fx::new();
    let watch = Watch::new(&fx.dest, &fx.final_name(T1), None);
    let (_, file, ..) = created(fx.run_watched(&fx.request(30, false), T1, &watch).unwrap());
    assert_eq!(watch.wraps(), 1, "one archive");
    assert!(watch.writes.load(Ordering::SeqCst) > 0);
    assert!(
        watch.saw_partial.load(Ordering::SeqCst),
        "written as {}",
        partial_of(&fx.final_name(T1))
    );
    assert!(
        !watch.saw_final.load(Ordering::SeqCst),
        "no final name while writing"
    );
    assert!(file.exists());
    assert!(partials(&fx.dest).is_empty(), "the partial was renamed");
}

// ---- AC 11: retention -------------------------------------------------------------------------

fn file_names_fixture() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/backup/file_names.json");
    serde_json::from_slice(&fs::read(&path).unwrap()).unwrap()
}

/// Every name in `file_names.json` (valid, look-alikes, partials), once.
fn fixture_names(fx: &Value) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for list in ["valid", "look_alikes", "partials"] {
        for row in fx[list].as_array().unwrap() {
            out.insert(row["name"].as_str().unwrap().to_string());
        }
    }
    out
}

/// This vault's backups in the fixture, as (timestamp, name).
fn fixture_matching(fx: &Value) -> Vec<(String, String)> {
    fx["valid"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["vault_id"] == json!(THIS))
        .map(|r| {
            (
                r["timestamp"].as_str().unwrap().to_string(),
                r["name"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

/// Whether `dir` treats names that differ only by case as one file.
fn case_insensitive(dir: &Path) -> bool {
    let probe = dir.join("case-probe");
    fs::write(&probe, b"").unwrap();
    let folded = dir.join("CASE-PROBE").exists();
    fs::remove_file(&probe).unwrap();
    folded
}

#[test]
fn retention_keeps_the_newest_keep_and_spares_every_look_alike() {
    let fixture = file_names_fixture();
    assert_eq!(fixture["vault_id"], json!(THIS));
    let all = fixture_names(&fixture);
    let mut matching = fixture_matching(&fixture);
    matching.sort_by(|a, b| b.0.cmp(&a.0)); // newest first
    assert_eq!(matching.len(), 6, "fixture: six backups of this vault");
    let this_partial = partial_of(&matching[0].1);
    assert!(
        all.contains(&this_partial),
        "fixture: this vault's .partial"
    );

    // keep values whose cut never falls inside a run of equal timestamps.
    for keep in [1_u16, 5, 6, 7, 30] {
        let fx = Fx::with_id(THIS);
        // A case-insensitive folder (macOS APFS by default) holds one file for
        // `x.memex.zip` and `x.MEMEX.ZIP` (and for their `.partial`s), so an
        // upper-case look-alike can't be seeded beside its twin there: the
        // lower-case name is seeded and the other skipped. The upper-case
        // look-alikes get their own tests (this one covers them wherever the
        // folder is case-sensitive).
        let folded = case_insensitive(&fx.dest);
        let all: BTreeSet<String> = all
            .iter()
            .filter(|n| !(folded && all.iter().any(|m| m > *n && m.eq_ignore_ascii_case(n))))
            .cloned()
            .collect();
        for name in &all {
            fx.seed(name);
        }
        // A look-alike nobody may read.
        let sealed = ModeGuard::set(&fx.dest.join("x.memex.zip"), 0o000);

        let kept_old = (keep as usize - 1).min(matching.len());
        if kept_old > 0 && kept_old < matching.len() {
            assert_ne!(
                matching[kept_old - 1].0,
                matching[kept_old].0,
                "keep {keep} cuts between distinct timestamps"
            );
        }
        let expected_removed: BTreeSet<String> = matching[kept_old..]
            .iter()
            .map(|(_, n)| n.clone())
            .collect();
        assert_eq!(
            expected_removed.len(),
            (matching.len() + 1).saturating_sub(keep as usize),
            "matching + 1 - keep"
        );

        let (_, file, _, _, removed) = created(
            fx.run(T1, keep, false)
                .unwrap_or_else(|e| panic!("keep {keep}: {e:?}")),
        );
        drop(sealed);

        let removed: BTreeSet<PathBuf> = removed.into_iter().collect();
        let want: BTreeSet<PathBuf> = expected_removed.iter().map(|n| fx.dest.join(n)).collect();
        assert_eq!(removed, want, "keep {keep}: removed lists exactly those");
        for name in &all {
            let p = fx.dest.join(name);
            if expected_removed.contains(name) {
                assert!(!p.exists(), "keep {keep}: {name} removed");
            } else if *name == this_partial {
                assert!(
                    !p.exists(),
                    "keep {keep}: this vault's leftover .partial is cleaned"
                );
            } else {
                assert_eq!(
                    fs::read(&p).unwrap_or_else(|e| panic!("keep {keep}: {name} kept: {e}")),
                    format!("seeded {name}").into_bytes(),
                    "keep {keep}: {name} survives byte-identical"
                );
            }
        }
        assert!(file.exists(), "keep {keep}: the new backup is kept");
        assert!(
            !removed.contains(&fx.dest.join(&this_partial)),
            "partial cleanup is not retention"
        );
    }
}

#[test]
fn retention_orders_by_the_file_name_timestamp_not_the_modification_time() {
    let fx = Fx::new();
    let day = 86_400_000;
    let oldest = fx.seed(&final_of(LABEL, T1 - 3 * day, &fx.vault_id));
    let middle = fx.seed(&final_of(LABEL, T1 - 2 * day, &fx.vault_id));
    let newest = fx.seed(&final_of(LABEL, T1 - day, &fx.vault_id));
    let now = std::time::SystemTime::now();
    let ago = |secs| now - std::time::Duration::from_secs(secs);
    for (path, mtime) in [
        (&oldest, now),
        (&middle, ago(3_600)),
        (&newest, ago(86_400 * 30)),
    ] {
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
    }
    let (.., removed) = created(fx.run(T1, 2, false).unwrap());
    let removed: BTreeSet<PathBuf> = removed.into_iter().collect();
    assert_eq!(removed, BTreeSet::from([oldest, middle]));
    assert!(newest.exists());
}

#[test]
fn unchanged_run_removes_no_backup_files() {
    let fx = Fx::new();
    fx.run(T1, 30, false).unwrap();
    let day = 86_400_000;
    for back in 1..=3 {
        fx.seed(&final_of(LABEL, T1 - back * day, &fx.vault_id));
    }
    let before = backups_of(&fx.dest, &fx.vault_id);
    assert_eq!(before.len(), 4);
    match fx.run(T2, 1, true).unwrap() {
        BackupOutcome::Unchanged { .. } => {}
        other => panic!("expected unchanged, got {other:?}"),
    }
    assert_eq!(backups_of(&fx.dest, &fx.vault_id), before, "0 removed");
}

#[test]
fn failed_run_removes_no_backup_files() {
    let fx = Fx::new();
    let day = 86_400_000;
    for back in 1..=3 {
        fx.seed(&final_of(LABEL, T1 - back * day, &fx.vault_id));
    }
    let before = backups_of(&fx.dest, &fx.vault_id);
    let watch = Watch::new(&fx.dest, &fx.final_name(T1), Some(64));
    let result = fx.run_watched(&fx.request(1, false), T1, &watch);
    assert_eq!(code(&result), "backup_failed", "{result:?}");
    assert_eq!(watch.wraps(), 1, "the run failed while writing the zip");
    assert_eq!(backups_of(&fx.dest, &fx.vault_id), before, "0 removed");
    assert_eq!(fx.state().expect("recorded").last_result, "backup_failed");
}

// ---- AC 12: an interrupted write --------------------------------------------------------------

#[test]
fn interrupted_write_leaves_no_final_name_deletes_the_partial_and_records_backup_failed() {
    let fx = Fx::new();
    let (_, older, older_bytes, older_fp, _) = created(fx.run(T1, 30, false).unwrap());
    let older_content = fs::read(&older).unwrap();
    // Fail half-way through an archive of this size.
    let fail_at = (older_bytes / 2) as usize;

    let watch = Watch::new(&fx.dest, &fx.final_name(T2), Some(fail_at));
    let result = fx.run_watched(&fx.request(1, false), T2, &watch);

    assert_eq!(code(&result), "backup_failed", "{result:?}");
    assert_eq!(watch.wraps(), 1);
    assert!(watch.bytes() > 0, "the write failed mid-archive");
    assert!(watch.saw_partial.load(Ordering::SeqCst));
    assert!(!watch.saw_final.load(Ordering::SeqCst));
    assert!(!fx.final_path(T2).exists(), "the final name never appears");
    assert!(partials(&fx.dest).is_empty(), "the partial is deleted");
    assert_eq!(
        fs::read(&older).unwrap(),
        older_content,
        "older backup untouched"
    );
    assert_eq!(
        backups_of(&fx.dest, &fx.vault_id),
        BTreeSet::from([fx.final_name(T1)])
    );

    let s = fx.state().unwrap();
    assert_eq!(s.last_result, "backup_failed");
    assert_eq!(s.last_attempt_at, T2);
    assert!(s.last_error.is_some());
    assert_eq!(s.last_success_at, Some(T1), "a failure keeps the rest");
    assert_eq!(s.last_file, Some(fx.final_name(T1)));
    assert_eq!(s.last_fingerprint, Some(older_fp));
}

#[test]
fn a_later_run_deletes_a_leftover_partial_for_this_vault_id_only() {
    let fx = Fx::with_id(THIS);
    let ours = fx.seed(&partial_of(&final_of(LABEL, T1 - 86_400_000, THIS)));
    let ours_other_label = fx.seed(&partial_of(&final_of("notes", T1 - 3_600_000, THIS)));
    let theirs = fx.seed(&partial_of(&final_of(LABEL, T1 - 86_400_000, OTHER)));
    let no_dot = fx.seed(&format!(
        "{}.partial",
        final_of(LABEL, T1 - 86_400_000, THIS)
    ));
    let upper = fx.seed(&format!(
        ".{LABEL}-20261101T000000Z-{THIS}.MEMEX.ZIP.partial"
    ));

    fx.run(T1, 30, false).unwrap();

    assert!(!ours.exists(), "this vault's leftover partial is deleted");
    assert!(!ours_other_label.exists(), "matched by vault_id, any label");
    for p in [&theirs, &no_dot, &upper] {
        let name = p.file_name().unwrap().to_string_lossy();
        assert_eq!(
            fs::read(p).unwrap(),
            format!("seeded {name}").into_bytes(),
            "{name} is not this vault's partial"
        );
    }
}

#[test]
fn an_unchanged_run_also_deletes_a_leftover_partial() {
    let fx = Fx::new();
    fx.run(T1, 30, false).unwrap();
    let ours = fx.seed(&partial_of(&fx.final_name(T1 - 86_400_000)));
    match fx.run(T2, 30, true).unwrap() {
        BackupOutcome::Unchanged { .. } => {}
        other => panic!("expected unchanged, got {other:?}"),
    }
    assert!(!ours.exists());
    assert!(partials(&fx.dest).is_empty());
}

#[test]
fn snapshot_failure_is_recorded_and_leaves_no_partial() {
    let fx = Fx::new();
    fs::write(fx.vault.join("memex.db"), vec![0x5A; 8192]).unwrap();
    let result = fx.run(T1, 30, false);
    assert_eq!(code(&result), "backup_failed", "{result:?}");
    assert!(names(&fx.dest).is_empty(), "no partial, no zip");
    let s = fx.state().expect("recorded");
    assert_eq!(s.last_result, "backup_failed");
    assert_eq!(s.last_attempt_at, T1);
}

// ---- AC 13: objects/ entries that aren't files or folders -------------------------------------

/// The run fails `backup_failed`, is recorded, and leaves the destination
/// as it was (no zip, no partial).
fn assert_objects_entry_fails(fx: &Fx) {
    let listing = names(&fx.dest);
    let result = fx.run(T2, 30, false);
    assert_eq!(code(&result), "backup_failed", "{result:?}");
    assert_eq!(names(&fx.dest), listing, "no zip, no partial");
    assert!(!fx.final_path(T2).exists());
    let s = fx.state().expect("recorded");
    assert_eq!(s.last_result, "backup_failed");
    assert_eq!(s.last_attempt_at, T2);
}

#[test]
fn objects_symlink_fails_backup_failed_and_is_recorded() {
    let fx = Fx::new();
    let outside = fx.root.join("outside.txt");
    fs::write(&outside, "outside the vault").unwrap();
    symlink(&outside, fx.vault.join("objects/ab/link to outside")).unwrap();
    assert_objects_entry_fails(&fx);
}

#[test]
fn objects_symlink_to_a_folder_fails_backup_failed() {
    let fx = Fx::new();
    symlink(fx.vault.join("objects/a"), fx.vault.join("objects/a link")).unwrap();
    assert_objects_entry_fails(&fx);
}

#[test]
fn objects_fifo_fails_backup_failed_and_is_recorded() {
    let fx = Fx::new();
    let fifo = fx.vault.join("objects/sub dir/a fifo");
    let c_path = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o644) }, 0);
    // If the run opens the FIFO for reading, this writer lets it see EOF
    // instead of blocking; the reader opened below releases the writer.
    let writer = {
        let fifo = fifo.clone();
        thread::spawn(move || {
            let _ = OpenOptions::new().write(true).open(&fifo);
        })
    };
    assert_objects_entry_fails(&fx);
    {
        use std::os::unix::fs::OpenOptionsExt;
        let _reader = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&fifo)
            .unwrap();
        writer.join().unwrap();
    }
}

#[cfg(target_os = "linux")]
#[test]
fn objects_non_utf8_name_fails_backup_failed_and_is_recorded() {
    use std::os::unix::ffi::OsStrExt;
    let fx = Fx::new();
    let name = std::ffi::OsStr::from_bytes(b"bad \xff name.bin");
    fs::write(fx.vault.join("objects").join(name), b"bytes").unwrap();
    assert_objects_entry_fails(&fx);
}

// ---- the V5 schema, as shipped (copied from migration_v6.rs) ----------------------------------

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
