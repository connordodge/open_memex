//! WI #75 (R6): the network-drive guard (req 30, ruling D4).
//!
//! - AC 1–2: the pure classifier over a `statfs` description, table-tested
//!   with every constant from req 30 (macOS `f_fstypename` + `MNT_LOCAL`,
//!   Linux `f_type` + `fuseblk`).
//! - AC 3: a path that doesn't exist yet probes its nearest existing ancestor
//!   and creates nothing.
//! - AC 4–6: `Vault::create` / `Vault::open` run the guard first, through an
//!   injected probe: a "network" probe refuses before anything is created or
//!   SQLite is opened; a failing probe is an error, never safe and never
//!   `network_filesystem`.
//! - The real `statfs` probe: a temp dir is local, a missing path is an
//!   error, and (macOS) the non-local autofs `/home` mount is network.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use memex_core::fs_guard::{self, classify, FsClass, FsInfo};
use memex_core::{MemexError, Vault};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn mac(fstypename: &str, local: bool) -> FsInfo {
    FsInfo::MacOs {
        fstypename: fstypename.to_string(),
        local,
    }
}

fn linux(f_type: u32, fuseblk: bool) -> FsInfo {
    FsInfo::Linux { f_type, fuseblk }
}

/// A probe that reports a local APFS volume for every path.
fn local_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(mac("apfs", true))
}

/// A probe that reports an SMB share for every path.
fn network_probe(_: &Path) -> io::Result<FsInfo> {
    Ok(mac("smbfs", false))
}

/// A probe whose `statfs` call fails (EIO).
fn failing_probe(_: &Path) -> io::Result<FsInfo> {
    Err(io::Error::from_raw_os_error(5))
}

/// The macOS `f_fstypename` values req 30 lists as network.
const MAC_NETWORK_TYPES: [&str; 8] = [
    "smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs", "macfuse", "osxfuse",
];

/// The Linux `f_type` magics req 30 lists as network (FUSE aside).
const LINUX_NETWORK_MAGICS: [(u32, &str); 10] = [
    (0x6969, "NFS"),
    (0x517B, "SMB"),
    (0xFF53_4D42, "CIFS"),
    (0xFE53_4D42, "SMB2"),
    (0x5346_414F, "AFS"),
    (0x6B41_4653, "kAFS"),
    (0x7375_7245, "Coda"),
    (0x564C, "NCP"),
    (0x00C3_6400, "Ceph"),
    (0x0102_1997, "9P"),
];

const LINUX_FUSE: u32 = 0x6573_5546;

/// Local Linux filesystems: ext4, xfs, btrfs and tmpfs (close to 9P).
const LINUX_LOCAL_MAGICS: [(u32, &str); 4] = [
    (0xEF53, "ext4"),
    (0x5846_5342, "xfs"),
    (0x9123_683E, "btrfs"),
    (0x0102_1994, "tmpfs"),
];

/// Every path under `dir`, relative to it.
fn tree(dir: &Path) -> BTreeSet<PathBuf> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeSet<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else {
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

fn canonical(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap_or_else(|e| panic!("canonicalize {}: {e}", p.display()))
}

/// The paths a probe was asked about, canonicalized.
fn canonical_all(calls: &[PathBuf]) -> Vec<PathBuf> {
    calls.iter().map(|p| canonical(p)).collect()
}

fn mtime(p: &Path) -> SystemTime {
    fs::metadata(p)
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

/// The state of a closed vault's files that a guard refusal must not touch.
struct VaultFiles {
    db: Vec<u8>,
    db_mtime: SystemTime,
    manifest: Vec<u8>,
    tree: BTreeSet<PathBuf>,
}

impl VaultFiles {
    fn read(root: &Path) -> Self {
        Self {
            db: fs::read(root.join("memex.db")).unwrap(),
            db_mtime: mtime(&root.join("memex.db")),
            manifest: fs::read(root.join("manifest.json")).unwrap(),
            tree: tree(root),
        }
    }

    fn assert_unchanged(&self, root: &Path, what: &str) {
        assert!(
            sidecars(root).is_empty(),
            "{what}: SQLite was opened (sidecars {:?})",
            sidecars(root)
        );
        assert_eq!(
            mtime(&root.join("memex.db")),
            self.db_mtime,
            "{what}: memex.db mtime changed"
        );
        assert!(
            fs::read(root.join("memex.db")).unwrap() == self.db,
            "{what}: memex.db bytes changed"
        );
        assert!(
            fs::read(root.join("manifest.json")).unwrap() == self.manifest,
            "{what}: manifest.json changed"
        );
        assert_eq!(tree(root), self.tree, "{what}: vault folder changed");
    }
}

/// The autofs `/home` mount every macOS install has: `mount` lists it
/// without `local`, so its `statfs` lacks `MNT_LOCAL`. `None` (and a note on
/// stderr) where it isn't mounted.
fn autofs_home() -> Option<PathBuf> {
    const HOME: &str = "/System/Volumes/Data/home";
    if !cfg!(target_os = "macos") {
        return None;
    }
    let out = std::process::Command::new("/sbin/mount").output().ok()?;
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

// ---------------------------------------------------------------------------
// AC 1: macOS classifier
// ---------------------------------------------------------------------------

#[test]
fn macos_network_types_are_network_even_with_mnt_local() {
    for name in MAC_NETWORK_TYPES {
        for local in [true, false] {
            assert_eq!(
                classify(&mac(name, local)),
                FsClass::Network,
                "{name} (MNT_LOCAL={local})"
            );
        }
    }
}

#[test]
fn macos_apfs_and_hfs_with_mnt_local_are_local() {
    // apfs and hfs are the AC's; msdos, exfat and nullfs are other local
    // types a person may pick, and nothing in req 30 lists them.
    for name in ["apfs", "hfs", "msdos", "exfat", "nullfs"] {
        assert_eq!(
            classify(&mac(name, true)),
            FsClass::Local,
            "{name} with MNT_LOCAL"
        );
    }
}

#[test]
fn macos_any_type_without_mnt_local_is_network() {
    for name in ["apfs", "hfs", "autofs", "msdos", "exfat", "nullfs", ""] {
        assert_eq!(
            classify(&mac(name, false)),
            FsClass::Network,
            "{name:?} without MNT_LOCAL"
        );
    }
}

#[test]
fn macos_type_names_match_exactly() {
    // A local mount whose type merely contains or extends a listed name is
    // not on the list.
    for name in ["nfsd", "smbfs2", "xftp", "apfs_nfs", "macfuse "] {
        assert_eq!(
            classify(&mac(name, true)),
            FsClass::Local,
            "{name:?} with MNT_LOCAL is not a listed network type"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 2: Linux classifier
// ---------------------------------------------------------------------------

#[test]
fn linux_network_magics_are_network() {
    for (magic, name) in LINUX_NETWORK_MAGICS {
        // `fuseblk` only matters for FUSE.
        for fuseblk in [false, true] {
            assert_eq!(
                classify(&linux(magic, fuseblk)),
                FsClass::Network,
                "{name} {magic:#x} (fuseblk={fuseblk})"
            );
        }
    }
}

#[test]
fn linux_fuse_is_network_without_fuseblk_and_local_with_it() {
    assert_eq!(classify(&linux(LINUX_FUSE, false)), FsClass::Network);
    assert_eq!(classify(&linux(LINUX_FUSE, true)), FsClass::Local);
}

#[test]
fn linux_local_magics_are_local() {
    for (magic, name) in LINUX_LOCAL_MAGICS {
        for fuseblk in [false, true] {
            assert_eq!(
                classify(&linux(magic, fuseblk)),
                FsClass::Local,
                "{name} {magic:#x} (fuseblk={fuseblk})"
            );
        }
    }
}

#[test]
fn linux_magics_one_away_from_a_listed_magic_are_local() {
    let listed: BTreeSet<u32> = LINUX_NETWORK_MAGICS
        .iter()
        .map(|(m, _)| *m)
        .chain([LINUX_FUSE])
        .collect();
    for magic in listed.iter().copied() {
        for near in [magic.wrapping_sub(1), magic.wrapping_add(1)] {
            if listed.contains(&near) {
                continue;
            }
            assert_eq!(
                classify(&linux(near, false)),
                FsClass::Local,
                "{near:#x} is one away from {magic:#x} and not listed"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// AC 3: missing paths probe the nearest existing ancestor
// ---------------------------------------------------------------------------

#[test]
fn missing_path_probes_nearest_existing_ancestor_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("a").join("b").join("c");
    let calls = RefCell::new(Vec::new());
    let probe = |p: &Path| {
        calls.borrow_mut().push(p.to_path_buf());
        local_probe(p)
    };

    fs_guard::check_with(&target, &probe).expect("a local ancestor is safe");

    assert_eq!(
        canonical_all(&calls.borrow()),
        vec![canonical(dir.path())],
        "only the nearest existing ancestor is probed"
    );
    assert!(tree(dir.path()).is_empty(), "the check creates nothing");
}

#[test]
fn missing_path_under_a_network_ancestor_is_refused_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("a")).unwrap();
    let target = dir.path().join("a").join("b").join("c");
    let calls = RefCell::new(Vec::new());
    let probe = |p: &Path| {
        calls.borrow_mut().push(p.to_path_buf());
        network_probe(p)
    };

    let err = fs_guard::check_with(&target, &probe).expect_err("network is refused");

    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "got {err:?}"
    );
    assert_eq!(err.code(), "network_filesystem");
    assert_eq!(
        canonical_all(&calls.borrow()),
        vec![canonical(&dir.path().join("a"))],
        "the nearest existing ancestor is <tmp>/a"
    );
    assert_eq!(
        tree(dir.path()),
        BTreeSet::from([PathBuf::from("a")]),
        "the check creates nothing"
    );
}

#[test]
fn existing_path_probes_itself() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("v");
    fs::create_dir(&target).unwrap();
    let calls = RefCell::new(Vec::new());
    let probe = |p: &Path| {
        calls.borrow_mut().push(p.to_path_buf());
        local_probe(p)
    };

    fs_guard::check_with(&target, &probe).expect("local is safe");

    assert_eq!(canonical_all(&calls.borrow()), vec![canonical(&target)]);
}

#[test]
fn check_with_maps_each_class_to_its_result() {
    let dir = tempfile::tempdir().unwrap();
    let cases: Vec<(FsInfo, bool)> = vec![
        (mac("apfs", true), true),
        (mac("hfs", true), true),
        (linux(0xEF53, false), true),
        (linux(LINUX_FUSE, true), true),
        (mac("nfs", true), false),
        (mac("apfs", false), false),
        (linux(0x6969, false), false),
        (linux(LINUX_FUSE, false), false),
    ];
    for (info, safe) in cases {
        let answer = info.clone();
        let probe = move |_: &Path| Ok(answer.clone());
        let got = fs_guard::check_with(dir.path(), &probe);
        if safe {
            assert!(got.is_ok(), "{info:?} is safe, got {got:?}");
        } else {
            let err = got.expect_err("network is refused");
            assert!(
                matches!(err, MemexError::NetworkFilesystem(_)),
                "{info:?}: got {err:?}"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// AC 4: Vault::create refuses a network filesystem before creating anything
// ---------------------------------------------------------------------------

#[test]
fn vault_create_on_network_returns_network_filesystem_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let empty = dir.path().join("empty");
    fs::create_dir(&empty).unwrap();
    let targets = [
        dir.path().join("v"),
        dir.path().join("x").join("y").join("v"),
        empty.clone(),
    ];
    for target in targets {
        let probed = RefCell::new(0usize);
        let probe = |p: &Path| {
            *probed.borrow_mut() += 1;
            network_probe(p)
        };
        let err = Vault::create_with_probe(&target, &probe)
            .err()
            .unwrap_or_else(|| panic!("{}: create on network must fail", target.display()));
        assert!(
            matches!(err, MemexError::NetworkFilesystem(_)),
            "{}: got {err:?}",
            target.display()
        );
        assert_eq!(err.code(), "network_filesystem");
        assert!(*probed.borrow() >= 1, "the probe was consulted");
    }
    assert_eq!(
        tree(dir.path()),
        BTreeSet::from([PathBuf::from("empty")]),
        "no folder, manifest, objects/ or memex.db was created"
    );
}

// ---------------------------------------------------------------------------
// AC 5: Vault::open refuses before reading the manifest or opening SQLite
// ---------------------------------------------------------------------------

#[test]
fn vault_open_on_network_returns_network_filesystem_without_opening_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let root = closed_vault(dir.path());
    let before = VaultFiles::read(&root);

    let err = Vault::open_with_probe(&root, &network_probe)
        .err()
        .expect("open on network must fail");

    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "got {err:?}"
    );
    assert_eq!(err.code(), "network_filesystem");
    before.assert_unchanged(&root, "open on network");
}

#[test]
fn vault_open_on_network_refuses_even_when_the_db_is_not_sqlite() {
    // Were SQLite opened first, a non-database memex.db would fail with a
    // sqlite error instead of `network_filesystem`.
    let dir = tempfile::tempdir().unwrap();
    let root = closed_vault(dir.path());
    fs::write(root.join("memex.db"), b"not a sqlite database at all").unwrap();
    let before = VaultFiles::read(&root);

    let err = Vault::open_with_probe(&root, &network_probe)
        .err()
        .expect("open on network must fail");

    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "got {err:?}"
    );
    before.assert_unchanged(&root, "open on network (non-database memex.db)");
}

#[test]
fn vault_open_on_network_checks_before_reading_the_manifest() {
    let dir = tempfile::tempdir().unwrap();
    let cases: [(&str, Option<&[u8]>); 3] = [
        ("garbage manifest", Some(b"{ this is not json")),
        (
            "newer schema",
            Some(
                br#"{"vault_id":"01J9Z8Y7X6W5V4T3S2R1Q0P9N8","schema_version":99,"created_at":0}"#,
            ),
        ),
        ("no manifest", None),
    ];
    for (what, manifest) in cases {
        let root = dir.path().join(what.replace(' ', "-"));
        fs::create_dir(&root).unwrap();
        if let Some(bytes) = manifest {
            fs::write(root.join("manifest.json"), bytes).unwrap();
        }
        let before = tree(&root);

        let err = Vault::open_with_probe(&root, &network_probe)
            .err()
            .unwrap_or_else(|| panic!("{what}: open on network must fail"));

        assert!(
            matches!(err, MemexError::NetworkFilesystem(_)),
            "{what}: got {err:?}"
        );
        assert_eq!(tree(&root), before, "{what}: nothing was created");
    }
    let missing = dir.path().join("missing").join("v");
    let err = Vault::open_with_probe(&missing, &network_probe)
        .err()
        .expect("open of a missing path on network must fail");
    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "missing vault: got {err:?}"
    );
    assert!(!dir.path().join("missing").exists());
}

// ---------------------------------------------------------------------------
// AC 6: a failing probe is an error, never safe and never network
// ---------------------------------------------------------------------------

fn assert_probe_error(err: &MemexError, what: &str) {
    assert!(
        !matches!(err, MemexError::NetworkFilesystem(_)),
        "{what}: a statfs failure is not a network drive: {err:?}"
    );
    assert_ne!(err.code(), "network_filesystem", "{what}");
    assert_ne!(
        err.to_error_json()["error"]["code"],
        "network_filesystem",
        "{what}"
    );
    let eio = io::Error::from_raw_os_error(5).to_string();
    assert!(
        err.to_string().contains(&eio),
        "{what}: the statfs failure itself is reported: {err}"
    );
}

#[test]
fn probe_error_is_an_error_never_safe_or_network() {
    let dir = tempfile::tempdir().unwrap();
    for target in [dir.path().to_path_buf(), dir.path().join("a").join("b")] {
        let err = fs_guard::check_with(&target, &failing_probe)
            .expect_err("a statfs failure is never reported as safe");
        assert_probe_error(&err, &target.display().to_string());
    }
    assert!(tree(dir.path()).is_empty(), "the check creates nothing");
}

#[test]
fn vault_create_with_failing_probe_errors_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("v");

    let err = Vault::create_with_probe(&target, &failing_probe)
        .err()
        .expect("a statfs failure is never treated as safe");

    assert_probe_error(&err, "create");
    assert!(tree(dir.path()).is_empty(), "nothing was created");
}

#[test]
fn vault_open_with_failing_probe_errors_without_opening_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let root = closed_vault(dir.path());
    fs::write(root.join("memex.db"), b"not a sqlite database at all").unwrap();
    let before = VaultFiles::read(&root);

    let err = Vault::open_with_probe(&root, &failing_probe)
        .err()
        .expect("a statfs failure is never treated as safe");

    assert_probe_error(&err, "open");
    assert!(
        !matches!(err, MemexError::Sqlite(_)),
        "the probe failed before SQLite was opened: {err:?}"
    );
    before.assert_unchanged(&root, "open with a failing probe");
}

// ---------------------------------------------------------------------------
// Local probe answers keep vaults working
// ---------------------------------------------------------------------------

#[test]
fn vault_create_and_open_with_a_local_probe_still_work() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("v");
    let created = Vault::create_with_probe(&root, &local_probe).expect("create on local");
    let id = created.vault_id().to_string();
    drop(created);
    let opened = Vault::open_with_probe(&root, &local_probe).expect("open on local");
    assert_eq!(opened.vault_id(), id);
}

// ---------------------------------------------------------------------------
// The real statfs probe
// ---------------------------------------------------------------------------

#[test]
fn real_probe_reports_a_temp_dir_as_local() {
    let dir = tempfile::tempdir().unwrap();
    let info = fs_guard::probe(dir.path()).expect("statfs a temp dir");
    assert_eq!(classify(&info), FsClass::Local, "{info:?}");
    if cfg!(target_os = "macos") {
        assert_eq!(info, mac("apfs", true), "macOS temp dirs live on APFS");
    }
}

#[test]
fn real_check_passes_a_temp_dir_and_a_missing_path_under_it() {
    let dir = tempfile::tempdir().unwrap();
    fs_guard::check(dir.path()).expect("a temp dir is safe");
    fs_guard::check(&dir.path().join("a").join("b")).expect("a missing path under it is safe");
    assert!(tree(dir.path()).is_empty(), "the check creates nothing");
}

#[test]
fn real_probe_of_a_missing_path_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let got = fs_guard::probe(&dir.path().join("missing"));
    assert!(got.is_err(), "statfs of a missing path fails: {got:?}");
}

#[test]
fn real_vault_create_and_open_still_work_on_a_temp_dir() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("v");
    drop(Vault::create(&root).expect("create on a local temp dir"));
    Vault::open(&root).expect("open on a local temp dir");
}

#[test]
fn real_probe_reports_the_autofs_home_mount_as_not_local() {
    let Some(home) = autofs_home() else { return };
    let info = fs_guard::probe(&home).expect("statfs the autofs mount");
    assert_eq!(info, mac("autofs", false), "{}", home.display());
    assert_eq!(classify(&info), FsClass::Network);

    let absent = home.join(format!("wi75-absent-{}", std::process::id()));
    let err = fs_guard::check(&absent).expect_err("a path on a non-local mount is refused");
    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "got {err:?}"
    );
    let err = Vault::create(&absent)
        .err()
        .expect("create on a non-local mount is refused");
    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Verify-mode pins: documented contracts of `check_with` and `probe`
// ---------------------------------------------------------------------------

/// Runs `check_with` on `path` with a local probe and returns the one path
/// it probed.
fn probed_path(path: &Path) -> PathBuf {
    let calls = RefCell::new(Vec::new());
    let probe = |p: &Path| {
        calls.borrow_mut().push(p.to_path_buf());
        local_probe(p)
    };
    fs_guard::check_with(path, &probe)
        .unwrap_or_else(|e| panic!("{}: a local probe is safe: {e}", path.display()));
    let calls = calls.into_inner();
    assert_eq!(calls.len(), 1, "{}: probed once: {calls:?}", path.display());
    calls.into_iter().next().unwrap()
}

#[test]
fn relative_path_with_no_existing_ancestor_probes_the_current_dir() {
    // Tests run in the crate directory, where `src` exists and these names
    // don't.
    let missing = format!("wi75-no-such-dir-{}", std::process::id());
    assert!(!Path::new(&missing).exists(), "precondition: {missing}");
    for path in [
        PathBuf::from(&missing),
        Path::new(&missing).join("a").join("b"),
    ] {
        assert_eq!(
            probed_path(&path),
            PathBuf::from("."),
            "{}: no existing ancestor, so `.` is probed",
            path.display()
        );
    }
    assert_eq!(
        probed_path(&Path::new("src").join(&missing).join("x")),
        PathBuf::from("src"),
        "a relative path with an existing ancestor probes that ancestor"
    );
    assert!(!Path::new(&missing).exists(), "the check creates nothing");
}

#[test]
fn network_refusal_message_is_one_line_naming_the_path_and_filesystem() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("a").join("b");
    let cases: [(FsInfo, &str); 7] = [
        (mac("smbfs", true), "smbfs"),
        (mac("nfs", false), "nfs, not a local mount"),
        (mac("apfs", false), "apfs, not a local mount"),
        (mac("macfuse", true), "macfuse"),
        (linux(LINUX_FUSE, false), "fuse"),
        (linux(0x6969, false), "f_type 0x6969"),
        (linux(0xFF53_4D42, true), "f_type 0xff534d42"),
    ];
    for target in [dir.path().to_path_buf(), missing] {
        for (info, fs_name) in &cases {
            let answer = info.clone();
            let probe = move |_: &Path| Ok(answer.clone());
            let err = fs_guard::check_with(&target, &probe).expect_err("network is refused");
            let detail = format!("{} ({fs_name})", target.display());
            match &err {
                MemexError::NetworkFilesystem(d) => assert_eq!(d, &detail, "{info:?}"),
                other => panic!("{info:?}: got {other:?}"),
            }
            let message = err.to_string();
            assert_eq!(
                message,
                format!("vault folder is on a network filesystem: {detail}"),
                "{info:?}"
            );
            assert!(!message.contains('\n'), "one line: {message:?}");
            let json = err.to_error_json();
            assert_eq!(json["error"]["code"], "network_filesystem");
            assert_eq!(json["error"]["message"], message.as_str());
        }
    }
}

#[test]
fn probe_error_is_an_io_error_naming_the_path_the_probed_ancestor_and_the_cause() {
    let dir = tempfile::tempdir().unwrap();
    let cases = [
        (dir.path().to_path_buf(), dir.path().to_path_buf()),
        (dir.path().join("a").join("b"), dir.path().to_path_buf()),
    ];
    for (target, ancestor) in cases {
        let probe = |_: &Path| -> io::Result<FsInfo> {
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "wi75 statfs denied",
            ))
        };
        let err = fs_guard::check_with(&target, &probe).expect_err("a probe error is an error");
        let MemexError::Io(io_err) = &err else {
            panic!(
                "{}: a probe error is MemexError::Io: {err:?}",
                target.display()
            );
        };
        assert_eq!(
            io_err.kind(),
            io::ErrorKind::PermissionDenied,
            "the probe's error kind is kept"
        );
        assert_eq!(
            io_err.to_string(),
            format!(
                "cannot tell which filesystem holds {}: statfs {}: wi75 statfs denied",
                target.display(),
                ancestor.display()
            )
        );
        assert_eq!(err.code(), "internal");
        assert_eq!(err.to_error_json()["error"]["code"], "internal");
        assert!(
            err.to_string().contains(&io_err.to_string()),
            "the message carries the detail: {err}"
        );
    }
    assert!(tree(dir.path()).is_empty(), "the check creates nothing");
}

#[test]
fn real_probe_of_a_path_with_a_nul_byte_is_an_invalid_input_error() {
    let err = fs_guard::probe(Path::new("wi75\0nul")).expect_err("no C path has a NUL");
    assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{err}");
}

#[test]
fn real_vault_open_refuses_the_autofs_home_mount() {
    // `Vault::open` with no probe override reads the real `statfs` probe.
    let Some(home) = autofs_home() else { return };
    let absent = home.join(format!("wi75-absent-open-{}", std::process::id()));
    let err = Vault::open(&absent)
        .err()
        .expect("open on a non-local mount is refused");
    assert!(
        matches!(err, MemexError::NetworkFilesystem(_)),
        "got {err:?}"
    );
    assert_eq!(err.code(), "network_filesystem");
}

/// Not built on the macOS gate: a platform without a `statfs`
/// classification fails closed (an error, never safe, never
/// `network_filesystem`).
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
#[test]
fn real_probe_fails_closed_on_an_unsupported_platform() {
    let dir = tempfile::tempdir().unwrap();
    let err = fs_guard::probe(dir.path()).expect_err("no classification here");
    assert_eq!(err.kind(), io::ErrorKind::Unsupported);
    let err = fs_guard::check(dir.path()).expect_err("never safe");
    assert!(matches!(err, MemexError::Io(_)), "got {err:?}");
    assert!(Vault::create(dir.path().join("v")).is_err());
}
