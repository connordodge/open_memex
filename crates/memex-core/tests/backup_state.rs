//! WI #316 (R0): `backup-state.json` (Spec #315 req 10, 10a, 23; rulings
//! D11, D12).
//!
//! The state file is written by `state::record_created`, `record_unchanged`
//! and `record_failed`, read by `state::read_state`, and keyed by
//! `state::destination_key`. The shared fixtures under
//! `app/test/fixtures/backup/` are the Dart reader's too.
//!
//! On-disk form (pinned byte for byte by the round-trip test): the
//! `BackupState` value as `serde_json::to_string_pretty` (two-space indent,
//! destinations sorted by key, every 10a field present, `null` for none)
//! followed by one `"\n"`.
//!
//! Temp paths are compared canonical (`/private/var/...` on macOS).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use memex_core::backup::state::{
    self, destination_key, destination_state, is_due, read_state, record_created, record_failed,
    record_unchanged, BackupState, DestinationState,
};
use memex_core::backup::{DUE_AFTER_MS, FORMAT, STATE_FILE};
use memex_core::MemexError;
use serde_json::Value;
use tempfile::TempDir;

const THIS: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAE";
const NOV09_0900: i64 = 1_794_214_800_000;
const NOV08_0900: i64 = 1_794_128_400_000;
const NOV09_1000: i64 = 1_794_218_400_000;
const JUN01_0800: i64 = 1_780_300_800_000;
const JUN02_0800: i64 = 1_780_387_200_000;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../app/test/fixtures/backup")
}

fn fixture_text(name: &str) -> String {
    let path = fixtures().join(name);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn fixture_json(name: &str) -> Value {
    serde_json::from_str(&fixture_text(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// A temp root, canonical, with an empty vault folder.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    vault: PathBuf,
}

impl Fx {
    fn new() -> Self {
        let tmp = TempDir::new().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        let vault = root.join("vault");
        fs::create_dir(&vault).unwrap();
        Fx {
            _tmp: tmp,
            root,
            vault,
        }
    }

    /// A destination folder `<root>/<rel>` that exists.
    fn dest(&self, rel: &str) -> PathBuf {
        let p = self.root.join(rel);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn state_path(&self) -> PathBuf {
        self.vault.join(STATE_FILE)
    }

    fn state_bytes(&self) -> Vec<u8> {
        fs::read(self.state_path()).expect("backup-state.json exists")
    }

    fn vault_entries(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(&self.vault)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }
}

fn key(p: &Path) -> String {
    p.to_str().unwrap().to_string()
}

fn empty_state() -> BackupState {
    BackupState {
        format: FORMAT,
        destinations: BTreeMap::new(),
    }
}

fn created(at: i64, file: &str, bytes: u64, fp: &str) -> DestinationState {
    DestinationState {
        last_attempt_at: at,
        last_success_at: Some(at),
        last_result: "created".to_string(),
        last_error: None,
        last_file: Some(file.to_string()),
        last_file_created_at: Some(at),
        last_bytes: Some(bytes),
        last_fingerprint: Some(fp.to_string()),
    }
}

fn file_name(stamp: &str) -> String {
    format!("notes-{stamp}-{THIS}.memex.zip")
}

fn sha(tag: &str) -> String {
    // The fixture's fingerprints, by the tag they were made from.
    let v = fixture_json("backup_state.json");
    let wanted = match tag {
        "created" => "GoogleDrive",
        "unchanged" => "OneDrive",
        "icloud" => "Mobile Documents",
        "old-disk" => "old-disk",
        _ => unreachable!(),
    };
    v["destinations"]
        .as_object()
        .unwrap()
        .iter()
        .find(|(k, _)| k.contains(wanted))
        .map(|(_, d)| d["last_fingerprint"].as_str().unwrap().to_string())
        .unwrap()
}

// ---------------------------------------------------------------------------
// AC5: read_state
// ---------------------------------------------------------------------------

#[test]
fn read_state_of_a_vault_without_a_state_file_is_empty() {
    let fx = Fx::new();
    assert_eq!(read_state(&fx.vault), empty_state());
    assert!(!fx.state_path().exists(), "reading never creates the file");

    // Control: the same vault with the shared fixture copied in has history.
    fs::write(fx.state_path(), fixture_text("backup_state.json")).unwrap();
    assert_eq!(read_state(&fx.vault).destinations.len(), 5);
}

#[test]
fn read_state_of_malformed_json_is_empty_and_the_next_record_rewrites_it() {
    for bad in [
        "",
        "{",
        "not json",
        "[]",
        "{\"format\":1,\"destinations\":[]}",
        "{\"format\":1}",
    ] {
        let fx = Fx::new();
        fs::write(fx.state_path(), bad).unwrap();
        assert_eq!(read_state(&fx.vault), empty_state(), "{bad:?}");

        let dest = fx.dest("dest");
        record_created(
            &fx.vault,
            &dest,
            NOV09_0900,
            &file_name("20261109T090000Z"),
            10,
            "ab",
        )
        .unwrap();
        let got = read_state(&fx.vault);
        let mut want = empty_state();
        want.destinations.insert(
            key(&dest),
            created(NOV09_0900, &file_name("20261109T090000Z"), 10, "ab"),
        );
        assert_eq!(got, want, "{bad:?} is rewritten as a fresh file");
    }
}

#[test]
fn read_state_of_format_2_is_empty() {
    let fx = Fx::new();
    let mut v = fixture_json("backup_state.json");
    v["format"] = Value::from(2);
    fs::write(fx.state_path(), serde_json::to_string(&v).unwrap()).unwrap();
    assert_eq!(read_state(&fx.vault), empty_state());

    // Control: the same body with format 1 reads back all five destinations.
    v["format"] = Value::from(1);
    fs::write(fx.state_path(), serde_json::to_string(&v).unwrap()).unwrap();
    let got = read_state(&fx.vault);
    assert_eq!(got.format, 1);
    assert_eq!(got.destinations.len(), 5);
}

#[test]
fn read_state_of_the_shared_fixture_gives_every_case() {
    let fx = Fx::new();
    fs::write(fx.state_path(), fixture_text("backup_state.json")).unwrap();
    let got = read_state(&fx.vault);

    let mut want = empty_state();
    let d = &mut want.destinations;
    d.insert(
        "/Users/person/Library/CloudStorage/GoogleDrive-person@example.com/My Drive/Open Memex Backups"
            .into(),
        created(NOV09_0900, &file_name("20261109T090000Z"), 48213, &sha("created")),
    );
    let mut unchanged = created(
        NOV08_0900,
        &file_name("20261108T090000Z"),
        47990,
        &sha("unchanged"),
    );
    unchanged.last_attempt_at = NOV09_0900;
    unchanged.last_success_at = Some(NOV09_0900);
    unchanged.last_result = "unchanged".into();
    d.insert(
        "/Users/person/Library/CloudStorage/OneDrive-Personal/Open Memex Backups".into(),
        unchanged,
    );
    let mut failed = created(
        NOV08_0900,
        &file_name("20261108T090000Z"),
        47990,
        &sha("icloud"),
    );
    failed.last_attempt_at = NOV09_1000;
    failed.last_result = "backup_failed".into();
    failed.last_error = Some("backup failed: quick_check failed on the snapshot".into());
    d.insert(
        "/Users/person/Library/Mobile Documents/com~apple~CloudDocs/Open Memex Backups".into(),
        failed,
    );
    d.insert(
        "/Volumes/backups/memex".into(),
        DestinationState {
            last_attempt_at: NOV09_0900,
            last_success_at: None,
            last_result: "backup_destination_unavailable".into(),
            last_error: Some(
                "backup destination unavailable: /Volumes/backups/memex is not writable".into(),
            ),
            last_file: None,
            last_file_created_at: None,
            last_bytes: None,
            last_fingerprint: None,
        },
    );
    let mut old = created(
        JUN01_0800,
        &file_name("20260601T080000Z"),
        30112,
        &sha("old-disk"),
    );
    old.last_attempt_at = JUN02_0800;
    old.last_result = "backup_destination_unavailable".into();
    old.last_error = Some(
        "backup destination unavailable: /Volumes/old-disk/Open Memex Backups does not exist"
            .into(),
    );
    d.insert("/Volumes/old-disk/Open Memex Backups".into(), old);

    assert_eq!(got, want);
}

/// The five fixture cases, made by the writers against real temp
/// destinations whose names sort like the fixture's keys, then the temp keys
/// swapped for the fixture's: the bytes must equal the fixture exactly.
#[test]
fn written_state_round_trips_byte_for_byte_through_the_fixture_cases() {
    let fx = Fx::new();
    let d1 = fx.dest("d1-created");
    let d2 = fx.dest("d2-unchanged");
    let d3 = fx.dest("d3-failed-after-success");
    let d4 = fx.dest("d4-failed-never");
    let d5 = fx.dest("d5-old");

    let v = &fx.vault;
    record_created(
        v,
        &d1,
        NOV09_0900,
        &file_name("20261109T090000Z"),
        48213,
        &sha("created"),
    )
    .unwrap();

    record_created(
        v,
        &d2,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        47990,
        &sha("unchanged"),
    )
    .unwrap();
    record_unchanged(v, &d2, NOV09_0900).unwrap();

    record_created(
        v,
        &d3,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        47990,
        &sha("icloud"),
    )
    .unwrap();
    record_failed(
        v,
        &d3,
        NOV09_1000,
        &MemexError::BackupFailed("quick_check failed on the snapshot".into()),
    )
    .unwrap();

    record_failed(
        v,
        &d4,
        NOV09_0900,
        &MemexError::BackupDestinationUnavailable("/Volumes/backups/memex is not writable".into()),
    )
    .unwrap();

    record_created(
        v,
        &d5,
        JUN01_0800,
        &file_name("20260601T080000Z"),
        30112,
        &sha("old-disk"),
    )
    .unwrap();
    record_failed(
        v,
        &d5,
        JUN02_0800,
        &MemexError::BackupDestinationUnavailable(
            "/Volumes/old-disk/Open Memex Backups does not exist".into(),
        ),
    )
    .unwrap();

    let mut written = String::from_utf8(fx.state_bytes()).unwrap();
    for (dest, fixture_key) in [
        (&d1, "/Users/person/Library/CloudStorage/GoogleDrive-person@example.com/My Drive/Open Memex Backups"),
        (&d2, "/Users/person/Library/CloudStorage/OneDrive-Personal/Open Memex Backups"),
        (&d3, "/Users/person/Library/Mobile Documents/com~apple~CloudDocs/Open Memex Backups"),
        (&d4, "/Volumes/backups/memex"),
        (&d5, "/Volumes/old-disk/Open Memex Backups"),
    ] {
        let quoted = format!("\"{}\"", key(dest));
        assert!(written.contains(&quoted), "keyed by {quoted}: {written}");
        written = written.replace(&quoted, &format!("\"{fixture_key}\""));
    }
    assert_eq!(written, fixture_text("backup_state.json"));
}

// ---------------------------------------------------------------------------
// AC6: the writers
// ---------------------------------------------------------------------------

#[test]
fn record_created_sets_every_10a_field_for_the_destination() {
    let fx = Fx::new();
    let dest = fx.dest("My Drive/Open Memex Backups");
    // Run-time values, not literals.
    let at = NOV09_0900 + i64::from(std::hint::black_box(7u8));
    let bytes = u64::from(std::hint::black_box(48_213u32));
    let name = file_name("20261109T090000Z");
    let fp = "f".repeat(std::hint::black_box(64));
    record_created(&fx.vault, &dest, at, &name, bytes, &fp).unwrap();

    let got = read_state(&fx.vault);
    assert_eq!(got.format, 1);
    assert_eq!(
        got.destinations.keys().collect::<Vec<_>>(),
        vec![&key(&dest)]
    );
    assert_eq!(
        got.destinations[&key(&dest)],
        created(at, &name, bytes, &fp)
    );
    assert_eq!(
        destination_state(&fx.vault, &dest),
        Some(created(at, &name, bytes, &fp))
    );

    // Every 10a key is present, nulls included.
    let raw: Value = serde_json::from_slice(&fx.state_bytes()).unwrap();
    let entry = raw["destinations"][key(&dest)].as_object().unwrap();
    assert_eq!(entry.keys().map(String::as_str).collect::<Vec<_>>(), {
        let mut k = vec![
            "last_attempt_at",
            "last_bytes",
            "last_error",
            "last_file",
            "last_file_created_at",
            "last_fingerprint",
            "last_result",
            "last_success_at",
        ];
        k.sort();
        k
    });
    assert!(entry["last_error"].is_null());
}

#[test]
fn record_unchanged_keeps_last_file_fields_and_fingerprint_and_clears_the_error() {
    let fx = Fx::new();
    let dest = fx.dest("dest");
    let name = file_name("20261108T090000Z");
    record_created(&fx.vault, &dest, NOV08_0900, &name, 47990, "aa").unwrap();
    record_failed(
        &fx.vault,
        &dest,
        NOV08_0900 + 3_600_000,
        &MemexError::BackupFailed("disk full".into()),
    )
    .unwrap();
    record_unchanged(&fx.vault, &dest, NOV09_0900).unwrap();

    let got = destination_state(&fx.vault, &dest).expect("recorded");
    assert_eq!(
        got,
        DestinationState {
            last_attempt_at: NOV09_0900,
            last_success_at: Some(NOV09_0900),
            last_result: "unchanged".into(),
            last_error: None,
            last_file: Some(name),
            last_file_created_at: Some(NOV08_0900),
            last_bytes: Some(47990),
            last_fingerprint: Some("aa".into()),
        }
    );
}

#[test]
fn record_unchanged_with_no_history_leaves_the_file_fields_null() {
    let fx = Fx::new();
    let dest = fx.dest("dest");
    record_unchanged(&fx.vault, &dest, NOV09_0900).unwrap();
    assert_eq!(
        destination_state(&fx.vault, &dest),
        Some(DestinationState {
            last_attempt_at: NOV09_0900,
            last_success_at: Some(NOV09_0900),
            last_result: "unchanged".into(),
            last_error: None,
            last_file: None,
            last_file_created_at: None,
            last_bytes: None,
            last_fingerprint: None,
        })
    );
}

#[test]
fn record_failed_changes_only_attempt_result_and_error() {
    let fx = Fx::new();
    let dest = fx.dest("dest");
    let name = file_name("20261108T090000Z");
    record_created(&fx.vault, &dest, NOV08_0900, &name, 47990, "aa").unwrap();
    let before = destination_state(&fx.vault, &dest).expect("recorded");

    let err = MemexError::NetworkFilesystem("/Volumes/share (smbfs)".into());
    record_failed(&fx.vault, &dest, NOV09_1000, &err).unwrap();
    let got = destination_state(&fx.vault, &dest).expect("recorded");

    let mut want = before;
    want.last_attempt_at = NOV09_1000;
    want.last_result = "network_filesystem".into();
    want.last_error = Some(err.to_string());
    assert_eq!(got, want);
    assert_eq!(got.last_success_at, Some(NOV08_0900));
}

#[test]
fn record_failed_with_no_history_leaves_success_and_file_fields_null() {
    let fx = Fx::new();
    let dest = fx.dest("dest");
    let err = MemexError::BackupDestinationUnavailable("dest is not writable".into());
    record_failed(&fx.vault, &dest, NOV09_0900, &err).unwrap();
    assert_eq!(
        destination_state(&fx.vault, &dest),
        Some(DestinationState {
            last_attempt_at: NOV09_0900,
            last_success_at: None,
            last_result: "backup_destination_unavailable".into(),
            last_error: Some("backup destination unavailable: dest is not writable".into()),
            last_file: None,
            last_file_created_at: None,
            last_bytes: None,
            last_fingerprint: None,
        })
    );
}

#[test]
fn record_created_after_a_failure_replaces_the_file_fields_and_clears_the_error() {
    let fx = Fx::new();
    let dest = fx.dest("dest");
    record_created(
        &fx.vault,
        &dest,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        1,
        "aa",
    )
    .unwrap();
    record_failed(
        &fx.vault,
        &dest,
        NOV09_0900,
        &MemexError::BackupFailed("x".into()),
    )
    .unwrap();
    let name = file_name("20261109T100000Z");
    record_created(&fx.vault, &dest, NOV09_1000, &name, 2, "bb").unwrap();
    assert_eq!(
        destination_state(&fx.vault, &dest),
        Some(created(NOV09_1000, &name, 2, "bb"))
    );
}

#[test]
fn record_on_one_destination_leaves_other_destinations_untouched() {
    let fx = Fx::new();
    fs::write(fx.state_path(), fixture_text("backup_state.json")).unwrap();
    let fixture = read_state(&fx.vault);
    assert_eq!(fixture.destinations.len(), 5, "control: the fixture reads");

    let dest = fx.dest("new");
    record_failed(
        &fx.vault,
        &dest,
        NOV09_1000,
        &MemexError::BackupFailed("x".into()),
    )
    .unwrap();
    let got = read_state(&fx.vault);
    assert_eq!(got.destinations.len(), 6);
    for (k, d) in &fixture.destinations {
        assert_eq!(got.destinations.get(k), Some(d), "{k}");
    }
}

#[test]
fn records_leave_no_temp_file_in_the_vault_folder() {
    let fx = Fx::new();
    fs::write(fx.vault.join("manifest.json"), "{}").unwrap();
    let dest = fx.dest("dest");
    record_created(
        &fx.vault,
        &dest,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        1,
        "aa",
    )
    .unwrap();
    assert_eq!(
        fx.vault_entries(),
        vec!["backup-state.json", "manifest.json"]
    );
    record_unchanged(&fx.vault, &dest, NOV09_0900).unwrap();
    assert_eq!(
        fx.vault_entries(),
        vec!["backup-state.json", "manifest.json"]
    );
    record_failed(
        &fx.vault,
        &dest,
        NOV09_1000,
        &MemexError::BackupFailed("x".into()),
    )
    .unwrap();
    assert_eq!(
        fx.vault_entries(),
        vec!["backup-state.json", "manifest.json"]
    );
    assert_eq!(
        destination_state(&fx.vault, &dest).map(|d| d.last_result),
        Some("backup_failed".to_string())
    );
}

/// Atomic: a temp file in the vault folder, then a rename. A vault folder
/// that refuses new entries makes the write fail and leaves the old file
/// byte-identical (an in-place rewrite of the writable file would succeed).
#[test]
fn record_into_a_vault_folder_that_refuses_new_files_fails_and_keeps_the_old_state_file() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fx::new();
    let dest = fx.dest("dest");
    record_created(
        &fx.vault,
        &dest,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        1,
        "aa",
    )
    .unwrap();
    let before = fx.state_bytes();
    assert!(
        !before.is_empty(),
        "control: the first record wrote the file"
    );

    fs::set_permissions(&fx.vault, fs::Permissions::from_mode(0o555)).unwrap();
    if fs::write(fx.vault.join("probe"), "x").is_ok() {
        // Running as root: permissions don't apply; nothing to prove here.
        let _ = fs::remove_file(fx.vault.join("probe"));
        fs::set_permissions(&fx.vault, fs::Permissions::from_mode(0o755)).unwrap();
        eprintln!("skipped: directory permissions are not enforced for this user");
        return;
    }
    let result = record_failed(
        &fx.vault,
        &dest,
        NOV09_0900,
        &MemexError::BackupFailed("x".into()),
    );
    fs::set_permissions(&fx.vault, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(result.is_err(), "the write must fail: {result:?}");
    assert_eq!(fx.state_bytes(), before, "the old file is untouched");
    assert_eq!(fx.vault_entries(), vec!["backup-state.json"]);
}

#[test]
fn records_key_a_symlinked_and_a_missing_destination_by_destination_key() {
    let fx = Fx::new();
    let real = fx.dest("real dest");
    let link = fx.root.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let missing = fx.root.join("not there/Open Memex Backups");

    record_created(
        &fx.vault,
        &link,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        1,
        "aa",
    )
    .unwrap();
    record_failed(
        &fx.vault,
        &missing,
        NOV09_0900,
        &MemexError::BackupDestinationUnavailable("missing".into()),
    )
    .unwrap();

    let got = read_state(&fx.vault);
    let keys: Vec<&String> = got.destinations.keys().collect();
    assert_eq!(
        keys,
        vec![
            &key(&fx.root.join("not there/Open Memex Backups")),
            &key(&real)
        ]
    );
    // Lookups resolve the same way, whichever spelling is used.
    assert!(destination_state(&fx.vault, &real).is_some());
    assert!(destination_state(&fx.vault, &link).is_some());
    assert_eq!(
        destination_state(&fx.vault, &missing).map(|d| d.last_result),
        Some("backup_destination_unavailable".to_string())
    );
}

#[test]
fn destination_state_of_an_unrecorded_destination_is_none() {
    let fx = Fx::new();
    let a = fx.dest("a");
    let b = fx.dest("b");
    record_created(
        &fx.vault,
        &a,
        NOV08_0900,
        &file_name("20261108T090000Z"),
        1,
        "aa",
    )
    .unwrap();
    assert!(destination_state(&fx.vault, &a).is_some(), "control");
    assert_eq!(destination_state(&fx.vault, &b), None);
}

/// The fixture's keys don't exist on this machine: each resolves through the
/// missing-destination rule to itself, so the lookup finds the fixture rows.
#[test]
fn destination_state_finds_the_fixture_rows_by_their_absolute_paths() {
    let fx = Fx::new();
    fs::write(fx.state_path(), fixture_text("backup_state.json")).unwrap();
    let got = destination_state(&fx.vault, Path::new("/Volumes/backups/memex"))
        .expect("the failed-never row");
    assert_eq!(got.last_result, "backup_destination_unavailable");
    assert_eq!(got.last_success_at, None);
    let got = destination_state(
        &fx.vault,
        Path::new("/Users/person/Library/CloudStorage/OneDrive-Personal/Open Memex Backups"),
    )
    .expect("the unchanged row");
    assert_eq!(got.last_result, "unchanged");
}

// ---------------------------------------------------------------------------
// AC7: destination_key
// ---------------------------------------------------------------------------

#[test]
fn destination_key_of_an_existing_folder_is_its_canonical_path() {
    let tmp = TempDir::new().unwrap();
    let dest = tmp.path().join("dest");
    fs::create_dir(&dest).unwrap();
    // tmp.path() itself may be a symlinked path (/var → /private/var).
    let want = key(&fs::canonicalize(&dest).unwrap());
    assert_eq!(destination_key(&dest).unwrap(), want);
    assert!(Path::new(&want).is_absolute());
}

#[test]
fn destination_key_resolves_a_symlinked_destination_to_its_target() {
    let fx = Fx::new();
    let real = fx.dest("Mobile Documents/com~apple~CloudDocs/Open Memex Backups");
    let link = fx.root.join("iCloud Drive");
    std::os::unix::fs::symlink(fx.root.join("Mobile Documents/com~apple~CloudDocs"), &link)
        .unwrap();
    let via_link = link.join("Open Memex Backups");
    assert_eq!(destination_key(&via_link).unwrap(), key(&real));

    let direct_link = fx.root.join("backups-link");
    std::os::unix::fs::symlink(&real, &direct_link).unwrap();
    assert_eq!(destination_key(&direct_link).unwrap(), key(&real));
}

#[test]
fn destination_key_of_a_missing_destination_is_the_canonical_parent_plus_the_missing_name() {
    let tmp = TempDir::new().unwrap();
    let canon_root = fs::canonicalize(tmp.path()).unwrap();
    // Spelled through the (possibly symlinked) temp path, so the existing
    // part must be canonicalized.
    let missing = tmp.path().join("Open Memex Backups");
    assert_eq!(
        destination_key(&missing).unwrap(),
        key(&canon_root.join("Open Memex Backups"))
    );
    let nested = tmp.path().join("a/b c/d");
    assert_eq!(
        destination_key(&nested).unwrap(),
        key(&canon_root.join("a/b c/d"))
    );
    assert!(!nested.exists(), "destination_key creates nothing");
}

#[test]
fn destination_key_of_a_missing_destination_under_a_symlinked_parent_resolves_the_parent() {
    let fx = Fx::new();
    let real = fx.dest("real");
    let link = fx.root.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert_eq!(
        destination_key(&link.join("Open Memex Backups")).unwrap(),
        key(&real.join("Open Memex Backups"))
    );
}

#[test]
fn destination_key_keeps_spaces_in_existing_and_missing_paths() {
    let fx = Fx::new();
    let existing = fx.dest("My Drive/Open Memex Backups");
    assert_eq!(destination_key(&existing).unwrap(), key(&existing));
    let missing = fx.root.join("My Drive/Not Yet Made");
    assert_eq!(destination_key(&missing).unwrap(), key(&missing));
    assert!(key(&missing).contains("My Drive/Not Yet Made"));
}

#[test]
fn destination_key_ignores_a_trailing_slash() {
    let fx = Fx::new();
    let existing = fx.dest("dest");
    let spelled = format!("{}/", key(&existing));
    assert_eq!(
        destination_key(Path::new(&spelled)).unwrap(),
        key(&existing)
    );
    let missing = format!("{}/missing/", key(&fx.root));
    assert_eq!(
        destination_key(Path::new(&missing)).unwrap(),
        key(&fx.root.join("missing"))
    );
}

/// Verify-mode pin: a destination spelled below a regular file (a typo, or
/// a file where a folder was) is walked up like a missing one, so the key is
/// still the canonical existing part plus the remaining names and the start-up
/// validation can report `backup_destination_unavailable` rather than an
/// I/O error from the key.
#[test]
fn destination_key_below_a_regular_file_is_the_canonical_file_plus_the_remaining_names() {
    let fx = Fx::new();
    let file = fx.root.join("notes.txt");
    fs::write(&file, "x").unwrap();
    assert_eq!(
        destination_key(&file.join("sub").join("deeper")).unwrap(),
        key(&file.join("sub").join("deeper"))
    );
    assert_eq!(
        destination_key(&file.join("sub")).unwrap(),
        key(&file.join("sub"))
    );
}

/// Verify-mode pin: an I/O error other than "missing" is reported, not
/// skipped as if the folder were merely absent.
#[test]
fn destination_key_returns_an_io_error_when_a_folder_on_the_path_cannot_be_searched() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fx::new();
    let locked = fx.dest("locked");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let readable = fs::read_dir(&locked).is_ok();
    let result = destination_key(&locked.join("sub"));
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
    if readable {
        eprintln!("skipped: directory permissions are not enforced for this user");
        return;
    }
    let err = result.expect_err("a folder that cannot be searched is an error, not a missing path");
    assert_eq!(err.code(), "internal", "{err}");
}

/// Verify-mode pin: a key is JSON text, so a non-UTF-8 destination is an
/// error (never a lossy key that two different folders could share).
#[cfg(unix)]
#[test]
fn destination_key_of_a_non_utf8_missing_destination_is_an_invalid_path_error() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    let fx = Fx::new();
    let bad = fx.root.join(OsStr::from_bytes(b"caf\xe9"));
    let err = destination_key(&bad).expect_err("not UTF-8");
    assert_eq!(err.code(), "internal", "{err}");
    assert!(matches!(err, MemexError::InvalidPath(_)), "{err:?}");
}

// ---------------------------------------------------------------------------
// AC8: is_due and due_cases.json
// ---------------------------------------------------------------------------

#[test]
fn is_due_matches_every_row_of_due_cases_json() {
    let v = fixture_json("due_cases.json");
    assert_eq!(v["due_after_ms"].as_i64(), Some(DUE_AFTER_MS));
    let cases = v["cases"].as_array().expect("cases");
    assert!(cases.len() >= 10, "{}", cases.len());
    let mut failures = Vec::new();
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let last = c["last_success_at"].as_i64();
        let now = c["now"].as_i64().unwrap();
        let want = c["due"].as_bool().unwrap();
        if is_due(last, now) != want {
            failures.push(format!("{name}: is_due({last:?}, {now}) != {want}"));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn due_cases_json_has_the_backward_jump_and_both_sides_of_the_24_hour_boundary() {
    let v = fixture_json("due_cases.json");
    let cases = v["cases"].as_array().unwrap();
    let has = |pred: &dyn Fn(Option<i64>, i64, bool) -> bool| {
        cases.iter().any(|c| {
            pred(
                c["last_success_at"].as_i64(),
                c["now"].as_i64().unwrap(),
                c["due"].as_bool().unwrap(),
            )
        })
    };
    assert!(
        has(&|l, n, d| l.is_some_and(|l| l > n) && d),
        "backward jump"
    );
    assert!(
        has(&|l, n, d| l.is_some_and(|l| n - l == DUE_AFTER_MS) && d),
        "exactly 24 h"
    );
    assert!(
        has(&|l, n, d| l.is_some_and(|l| n - l == DUE_AFTER_MS - 1) && !d),
        "24 h - 1 ms"
    );
    assert!(has(&|l, _, d| l.is_none() && d), "never backed up");
    // And the rule itself, on the backward jump.
    assert!(is_due(Some(NOV09_0900), NOV09_0900 - 1));
    assert!(is_due(Some(NOV09_0900), NOV09_0900 - DUE_AFTER_MS));
    assert!(!is_due(Some(NOV09_0900), NOV09_0900));
}

#[test]
fn is_due_needs_a_full_day_after_the_last_success() {
    let last = NOV08_0900 + i64::from(std::hint::black_box(1u8));
    assert!(is_due(None, last));
    assert!(!is_due(Some(last), last + DUE_AFTER_MS - 1));
    assert!(is_due(Some(last), last + DUE_AFTER_MS));
    assert!(is_due(Some(last), last + DUE_AFTER_MS + 1));
    assert!(!is_due(Some(last), last + 1));
    assert!(is_due(Some(last), last - 1), "the clock went backwards");
    // A far-future success (clock jumped back years) is due, not an overflow.
    assert!(is_due(Some(i64::MAX), 0));
}

#[test]
fn record_into_a_vault_path_that_is_not_a_folder_fails_with_an_io_error() {
    // Through the module path R1b and R3 call (`backup::state::…`).
    let fx = Fx::new();
    let file = fx.vault.join("not-a-dir");
    fs::write(&file, "x").unwrap();
    let dest = fx.dest("dest");
    let err = state::record_created(&file, &dest, NOV09_0900, "f", 1, "aa")
        .expect_err("a vault path that is a file cannot hold backup-state.json");
    assert_eq!(err.code(), "internal", "{err}");
}
