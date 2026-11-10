//! WI #316 (R0): the frozen backup API (ruling D5) and the module layout
//! (D4). R1a, R1b, R2 and R3 build against exactly these signatures; a
//! filler that changes one breaks this file at compile time.

use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use memex_core::backup::fingerprint::Fingerprinter;
use memex_core::backup::lock::{self, BackupLock};
use memex_core::backup::names::{self, ParsedName};
use memex_core::backup::snapshot::{self, Snapshot};
use memex_core::backup::state::{self, BackupState, DestinationState};
use memex_core::backup::{
    self, ArchiveSink, BackupOutcome, BackupRequest, BackupSeams, BackupSource, RestoreOutcome,
    RestoreRequest, DUE_AFTER_MS, FORMAT, KEEP_DEFAULT, KEEP_MAX, LOCK_FILE, STATE_FILE,
};
use memex_core::fs_guard::{self, FsClass, FsInfo};
use memex_core::{now_unix_ms, MemexError, Result};
use serde_json::json;

/// Pins every frozen signature by coercing it to its function type.
#[test]
fn frozen_backup_api_has_its_exact_signatures_and_constants() {
    let _: i64 = FORMAT;
    let _: &str = STATE_FILE;
    let _: &str = LOCK_FILE;
    let _: u16 = KEEP_DEFAULT;
    let _: u16 = KEEP_MAX;
    let _: i64 = DUE_AFTER_MS;
    assert_eq!(FORMAT, 1);
    assert_eq!(STATE_FILE, "backup-state.json");
    assert_eq!(LOCK_FILE, "backup.lock");
    assert_eq!(KEEP_DEFAULT, 30);
    assert_eq!(KEEP_MAX, 365);
    assert_eq!(DUE_AFTER_MS, 86_400_000);

    let _: fn(&BackupRequest) -> Result<BackupOutcome> = backup::backup;
    let _: fn(&BackupRequest, &BackupSeams) -> Result<BackupOutcome> = backup::backup_with;
    let _: fn(&RestoreRequest) -> Result<RestoreOutcome> = backup::restore;
    type Probe = dyn Fn(&Path) -> io::Result<FsInfo>;
    let _: fn(&RestoreRequest, &Probe) -> Result<RestoreOutcome> = backup::restore_with;
    let _: fn() -> BackupSeams<'static> = BackupSeams::system;
    let _: fn(&BackupOutcome) -> serde_json::Value = BackupOutcome::to_json;
    let _: fn(&RestoreOutcome) -> serde_json::Value = RestoreOutcome::to_json;

    let _: fn(&Path) -> Result<String> = state::destination_key;
    let _: fn(&Path) -> BackupState = state::read_state;
    let _: fn(&Path, &Path) -> Option<DestinationState> = state::destination_state;
    let _: fn(Option<i64>, i64) -> bool = state::is_due;
    let _: fn(&Path, &Path, i64, &str, u64, &str) -> Result<()> = state::record_created;
    let _: fn(&Path, &Path, i64) -> Result<()> = state::record_unchanged;
    let _: fn(&Path, &Path, i64, &MemexError) -> Result<()> = state::record_failed;

    let _: fn(&str) -> String = names::label_for;
    let _: fn(&str, i64, &str) -> String = names::file_name;
    let _: fn(&str) -> String = names::partial_name;
    let _: fn(&str) -> Option<ParsedName> = names::parse_file_name;
    let _: fn(&str, &str) -> bool = names::is_partial_for;
    let _ = |p: ParsedName| -> (String, String, String) { (p.label, p.timestamp, p.vault_id) };

    let _: fn(&Path) -> Result<BackupLock> = lock::try_lock;
    let _: fn(&Path) -> Result<Snapshot> = snapshot::take_snapshot;
    let _ = |s: Snapshot| -> (PathBuf, i64) { (s.path.clone(), s.schema_version) };

    let _: fn() -> Fingerprinter = Fingerprinter::new;
    let _: fn(&mut Fingerprinter, &mut dyn Read) -> Result<()> = Fingerprinter::snapshot;
    let _: fn(&mut Fingerprinter, &[u8]) = Fingerprinter::manifest;
    let _: fn(&mut Fingerprinter, &str, &mut dyn Read) -> Result<()> = Fingerprinter::object;
    let _: fn(Fingerprinter) -> String = Fingerprinter::finish;

    // The structs' public fields, by name and type.
    let vault = Path::new("/v");
    let request = BackupRequest {
        vault,
        destination: Path::new("/d"),
        keep: KEEP_DEFAULT,
        if_changed: true,
        source: BackupSource::Hosted,
    };
    let _: (&Path, &Path, u16, bool, BackupSource) = (
        request.vault,
        request.destination,
        request.keep,
        request.if_changed,
        request.source,
    );
    let restore = RestoreRequest {
        from: Path::new("/f.memex.zip"),
        to: Path::new("/t"),
    };
    let _: (&Path, &Path) = (restore.from, restore.to);
    let _ = BackupState {
        format: FORMAT,
        destinations: Default::default(),
    };
    let _ = DestinationState {
        last_attempt_at: 0,
        last_success_at: None,
        last_result: String::new(),
        last_error: None,
        last_file: None,
        last_file_created_at: None,
        last_bytes: None,
        last_fingerprint: None,
    };
    fn sink_is_write_and_seek<T: ArchiveSink + ?Sized>() {}
    sink_is_write_and_seek::<File>();
    sink_is_write_and_seek::<io::Cursor<Vec<u8>>>();
    sink_is_write_and_seek::<dyn ArchiveSink>();
}

#[test]
fn backup_source_serializes_as_local_and_hosted() {
    assert_eq!(
        serde_json::to_value(BackupSource::Local).unwrap(),
        json!("local")
    );
    assert_eq!(
        serde_json::to_value(BackupSource::Hosted).unwrap(),
        json!("hosted")
    );
    let back: BackupSource = serde_json::from_value(json!("hosted")).unwrap();
    assert_eq!(back, BackupSource::Hosted);
    assert!(serde_json::from_value::<BackupSource>(json!("Local")).is_err());
}

/// `BackupSeams::system()` is the production wiring: the system clock, the
/// real `fs_guard` probe and the `.partial` file itself as the sink.
#[test]
fn backup_seams_system_uses_the_system_clock_the_real_probe_and_the_plain_file() {
    let seams = BackupSeams::system();

    let before = now_unix_ms();
    let got = seams.clock.now_ms();
    let after = now_unix_ms();
    assert!(
        before <= got && got <= after,
        "system clock: {before} <= {got} <= {after}"
    );

    let tmp = tempfile::TempDir::new().unwrap();
    let info = (seams.probe)(tmp.path()).expect("probe a local temp folder");
    assert_eq!(info, fs_guard::probe(tmp.path()).unwrap());
    assert_eq!(fs_guard::classify(&info), FsClass::Local, "{info:?}");

    let path = tmp.path().join(".x.memex.zip.partial");
    let file = File::create(&path).unwrap();
    {
        let mut sink = (seams.wrap_archive)(file).expect("wrap the plain file");
        sink.write_all(b"hello world").unwrap();
        sink.seek(SeekFrom::Start(0)).unwrap();
        sink.write_all(b"HELLO").unwrap();
        sink.flush().unwrap();
    }
    assert_eq!(fs::read(&path).unwrap(), b"HELLO world");
}

/// R1b and R2 fill `run.rs` and `restore.rs`; until then `backup` and
/// `restore` return a C1 error rather than panicking, so the CLI can route it.
#[test]
fn backup_and_restore_return_errors_not_panics() {
    let tmp = tempfile::TempDir::new().unwrap();
    let r = BackupRequest {
        vault: &tmp.path().join("missing-vault"),
        destination: tmp.path(),
        keep: KEEP_DEFAULT,
        if_changed: false,
        source: BackupSource::Local,
    };
    assert!(backup::backup(&r).is_err());
    let r = RestoreRequest {
        from: &tmp.path().join("missing.memex.zip"),
        to: &tmp.path().join("restored"),
    };
    assert!(backup::restore(&r).is_err());
    assert!(!tmp.path().join("restored").exists());
}

// ---------------------------------------------------------------------------
// vault.rs: only the four items' visibility changes (D4)
// ---------------------------------------------------------------------------

#[test]
fn vault_rs_makes_exactly_the_four_backup_items_pub_crate() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/vault.rs");
    let src = fs::read_to_string(&path).unwrap();
    for line in [
        "pub(crate) const MANIFEST_FILENAME: &str = \"manifest.json\";",
        "pub(crate) const DB_FILENAME: &str = \"memex.db\";",
        "pub(crate) const OBJECTS_DIR: &str = \"objects\";",
        "pub(crate) fn ensure_sqlite_vec_registered() {",
    ] {
        assert_eq!(
            src.lines().filter(|l| *l == line).count(),
            1,
            "vault.rs has `{line}` once"
        );
    }
    for item in [
        "const MANIFEST_FILENAME",
        "const DB_FILENAME",
        "const OBJECTS_DIR",
        "fn ensure_sqlite_vec_registered",
    ] {
        assert!(
            !src.lines().any(|l| l.starts_with(&format!("pub {item}"))),
            "{item} is pub(crate), not pub"
        );
    }
}
