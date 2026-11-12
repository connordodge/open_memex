//! Agent presence core (#444, Spec #390 req 3, 4, 5, 6, 9): presence records,
//! their atomic file storage, expiry, sweep, identity truncation and the
//! activity entry struct. Every test runs in a fresh temp dir.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use memex_core::agents::activity::ActivityEntry;
use memex_core::agents::presence::{
    expires_at, is_expired, presence_dir, read_all, remove, sweep, truncate_identity, write,
    PresenceRecord, Transport, BRIDGE_TTL_MS, HEARTBEAT_MS, HTTP_TTL_MS, IDENTITY_MAX_CHARS,
    STDIO_TTL_MS,
};
use memex_core::Clock;
use serde_json::{json, Value};

/// Fake clock: the tests read `now_ms` from it, the way callers will.
struct FakeClock(std::cell::Cell<i64>);

impl FakeClock {
    fn at(ms: i64) -> Self {
        Self(std::cell::Cell::new(ms))
    }
    fn set(&self, ms: i64) {
        self.0.set(ms);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.get()
    }
}

const ALL_TRANSPORTS: [Transport; 3] = [Transport::Stdio, Transport::Bridge, Transport::Http];

fn transport_str(t: Transport) -> &'static str {
    match t {
        Transport::Stdio => "stdio",
        Transport::Bridge => "bridge",
        Transport::Http => "http",
    }
}

fn new_session_id() -> String {
    ulid::Ulid::new().to_string()
}

/// `<vault>/.memex/agents`, spelled out so tests never write relative to the
/// working directory, whatever `presence_dir` returns.
fn agents_dir(vault: &Path) -> PathBuf {
    vault.join(".memex").join("agents")
}

/// A record built from run-time values. `expires_at` is set explicitly so the
/// fixture does not depend on the `expires_at` function under test.
#[allow(clippy::too_many_arguments)]
fn record(
    transport: Transport,
    client_name: &str,
    client_version: Option<&str>,
    started_at: i64,
    last_seen_at: i64,
    last_request_at: i64,
    last_tool_at: Option<i64>,
    expires: i64,
    embeddings: bool,
) -> PresenceRecord {
    PresenceRecord {
        session_id: new_session_id(),
        client_name: client_name.to_string(),
        client_version: client_version.map(str::to_string),
        transport,
        started_at,
        last_seen_at,
        last_request_at,
        last_tool_at,
        expires_at: expires,
        embeddings,
    }
}

/// A simple record that expires at `expires`.
fn record_expiring_at(transport: Transport, expires: i64) -> PresenceRecord {
    record(
        transport,
        "test-agent",
        Some("1.2.3"),
        expires - 40_000,
        expires - 15_000,
        expires - 20_000,
        None,
        expires,
        false,
    )
}

/// The on-disk JSON shape of Spec #390 req 3, written by hand so the read
/// side is tested against the contract, not against `write`.
fn record_json(r: &PresenceRecord) -> Value {
    json!({
        "session_id": r.session_id,
        "client_name": r.client_name,
        "client_version": r.client_version,
        "transport": transport_str(r.transport),
        "started_at": r.started_at,
        "last_seen_at": r.last_seen_at,
        "last_request_at": r.last_request_at,
        "last_tool_at": r.last_tool_at,
        "expires_at": r.expires_at,
        "embeddings": r.embeddings,
    })
}

/// Writes `r` as `<dir>/<session_id>.json` without going through `write`.
fn put_fixture(dir: &Path, r: &PresenceRecord) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let path = dir.join(format!("{}.json", r.session_id));
    fs::write(&path, serde_json::to_vec(&record_json(r)).unwrap()).unwrap();
    path
}

fn sorted(mut v: Vec<PresenceRecord>) -> Vec<PresenceRecord> {
    v.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    v
}

fn file_names(dir: &Path) -> BTreeSet<String> {
    fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

fn json_keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("expected a JSON object, got {v}"))
        .keys()
        .cloned()
        .collect()
}

fn keys(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|s| s.to_string()).collect()
}

const RECORD_KEYS: [&str; 10] = [
    "session_id",
    "client_name",
    "client_version",
    "transport",
    "started_at",
    "last_seen_at",
    "last_request_at",
    "last_tool_at",
    "expires_at",
    "embeddings",
];

// ---------------------------------------------------------------- AC 1

#[test]
fn write_then_read_all_round_trips_every_field_with_exact_json_keys() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let base = 1_762_000_000_000_i64;

    let full = record(
        Transport::Stdio,
        "claude-code",
        Some("2.0.14"),
        base,
        base + 5_000,
        base + 4_000,
        Some(base + 3_000),
        base + 20_000,
        true,
    );
    let sparse = record(
        Transport::Bridge,
        "Claude Desktop",
        None,
        base + 1,
        base + 2,
        base + 3,
        None,
        base + 15_002,
        false,
    );
    let http = record(
        Transport::Http,
        "http client",
        Some("8.4.0"),
        base + 10,
        base + 11,
        base + 12,
        Some(base + 12),
        base + 60_012,
        true,
    );
    let written = vec![full.clone(), sparse.clone(), http.clone()];
    for r in &written {
        write(&dir, r).expect("write presence record");
    }

    assert_eq!(sorted(read_all(&dir)), sorted(written.clone()));

    for r in &written {
        let path = dir.join(format!("{}.json", r.session_id));
        let text = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("{} should exist after write: {e}", path.display()));
        let v: Value = serde_json::from_str(&text).expect("record file is JSON");
        assert_eq!(json_keys(&v), keys(&RECORD_KEYS), "exact keys in {text}");
        assert_eq!(v, record_json(r), "on-disk JSON for {:?}", r.transport);
        assert_eq!(v["transport"], json!(transport_str(r.transport)));
    }

    // The nullable fields are present as null, not omitted.
    let sparse_v: Value = serde_json::from_str(
        &fs::read_to_string(dir.join(format!("{}.json", sparse.session_id))).unwrap(),
    )
    .unwrap();
    assert_eq!(sparse_v["client_version"], Value::Null);
    assert_eq!(sparse_v["last_tool_at"], Value::Null);

    // Transport on its own serializes lowercase both ways.
    for t in ALL_TRANSPORTS {
        assert_eq!(serde_json::to_value(t).unwrap(), json!(transport_str(t)));
        assert_eq!(
            serde_json::from_value::<Transport>(json!(transport_str(t))).unwrap(),
            t
        );
    }
}

// ---------------------------------------------------------------- AC 2

#[test]
fn write_leaves_only_the_session_json_and_a_second_write_replaces_it() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    assert_eq!(presence_dir(vault.path()), dir);
    assert!(!dir.exists(), "precondition: no .memex/agents yet");

    let first = record(
        Transport::Stdio,
        "test-agent",
        Some("1.2.3"),
        1_000,
        1_000,
        1_000,
        None,
        16_000,
        false,
    );
    write(&dir, &first).expect("first write creates the dir");

    let name = format!("{}.json", first.session_id);
    assert_eq!(file_names(&dir), keys(&[name.as_str()]));

    let mut second = first.clone();
    second.last_seen_at = 6_000;
    second.last_request_at = 5_500;
    second.last_tool_at = Some(5_500);
    second.expires_at = 21_000;
    second.embeddings = true;
    second.client_version = None;
    write(&dir, &second).expect("second write");

    assert_eq!(
        file_names(&dir),
        keys(&[name.as_str()]),
        "no .tmp left behind"
    );
    let on_disk: Value =
        serde_json::from_str(&fs::read_to_string(dir.join(&name)).unwrap()).unwrap();
    assert_eq!(on_disk, record_json(&second));
    assert_eq!(read_all(&dir), vec![second]);
}

/// Atomic replace: a reader holding the old file keeps reading the old
/// contents, because the writer renames a new file over the name instead of
/// truncating and rewriting the old one in place.
#[cfg(unix)]
#[test]
fn second_write_replaces_the_file_by_rename_not_in_place() {
    use std::io::Read;

    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let first = record_expiring_at(Transport::Stdio, 50_000);
    write(&dir, &first).unwrap();
    let path = dir.join(format!("{}.json", first.session_id));
    let mut held = fs::File::open(&path).expect("first write made the file");

    let mut second = first.clone();
    second.last_seen_at += 5_000;
    second.expires_at += 5_000;
    write(&dir, &second).unwrap();

    let mut old = String::new();
    held.read_to_string(&mut old).unwrap();
    let old: Value = serde_json::from_str(&old).expect("held handle still reads a whole record");
    assert_eq!(old, record_json(&first), "the old inode was not rewritten");
    let new: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(new, record_json(&second));
}

#[test]
fn write_replaces_a_stale_tmp_left_by_a_crashed_writer() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let r = record_expiring_at(Transport::Bridge, 70_000);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join(format!("{}.json.tmp", r.session_id)),
        b"{\"half\":",
    )
    .unwrap();

    write(&dir, &r).unwrap();

    assert_eq!(
        file_names(&dir),
        keys(&[format!("{}.json", r.session_id).as_str()])
    );
    assert_eq!(read_all(&dir), vec![r]);
}

#[test]
fn write_into_a_dir_path_that_is_a_file_is_an_error() {
    let vault = tempfile::tempdir().unwrap();
    let not_a_dir = vault.path().join("agents");
    fs::write(&not_a_dir, b"a file, not a dir").unwrap();
    let r = record_expiring_at(Transport::Stdio, 30_000);

    assert!(write(&not_a_dir, &r).is_err());
}

/// Same-process concurrent writers for one session share the `<id>.json.tmp`
/// staging path, so `write` must serialize them: every call succeeds, a
/// reader never sees a missing, empty or partial record, and no tmp is left.
/// Counts are fixed (no wall-clock), so the test is deterministic in shape.
#[test]
fn concurrent_writes_for_the_same_sessions_never_error_or_expose_a_partial_record() {
    use std::sync::atomic::{AtomicBool, Ordering};

    const SESSIONS: usize = 2;
    const WRITERS_PER_SESSION: usize = 3;
    const WRITES_EACH: i64 = 2_500;

    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let bases: Vec<PresenceRecord> = (0..SESSIONS)
        .map(|_| record_expiring_at(Transport::Http, 90_000))
        .collect();
    for base in &bases {
        write(&dir, base).expect("seed write");
    }
    assert_eq!(read_all(&dir).len(), SESSIONS, "precondition: both seeded");

    let done = AtomicBool::new(false);
    let (write_errors, bad_reads) = std::thread::scope(|scope| {
        let reader = scope.spawn(|| {
            let mut bad = 0usize;
            while !done.load(Ordering::SeqCst) {
                if read_all(&dir).len() != SESSIONS {
                    bad += 1;
                }
            }
            bad
        });
        let mut writers = Vec::new();
        for base in &bases {
            for w in 0..WRITERS_PER_SESSION as i64 {
                let dir = &dir;
                writers.push(scope.spawn(move || {
                    let mut errors = Vec::new();
                    for i in 0..WRITES_EACH {
                        let mut r = base.clone();
                        r.last_request_at = 1_000 + w * 100_000 + i;
                        r.expires_at = r.last_request_at + HTTP_TTL_MS;
                        r.client_name = format!("writer-{w}-{}", "x".repeat((i % 50) as usize));
                        if let Err(e) = write(dir, &r) {
                            errors.push(e.to_string());
                        }
                    }
                    errors
                }));
            }
        }
        let errors: Vec<String> = writers
            .into_iter()
            .flat_map(|h| h.join().unwrap())
            .collect();
        done.store(true, Ordering::SeqCst);
        (errors, reader.join().unwrap())
    });

    assert!(
        write_errors.is_empty(),
        "{} write errors, first: {:?}",
        write_errors.len(),
        write_errors.first()
    );
    assert_eq!(
        bad_reads, 0,
        "reads that missed or could not parse a record"
    );
    let expected_files: BTreeSet<String> = bases
        .iter()
        .map(|b| format!("{}.json", b.session_id))
        .collect();
    assert_eq!(file_names(&dir), expected_files, "no tmp left behind");
    for base in &bases {
        let finals: Vec<PresenceRecord> = read_all(&dir)
            .into_iter()
            .filter(|r| r.session_id == base.session_id)
            .collect();
        assert_eq!(finals.len(), 1);
        let last = &finals[0];
        let w = (last.last_request_at - 1_000) / 100_000;
        assert_eq!(
            last.last_request_at,
            1_000 + w * 100_000 + (WRITES_EACH - 1),
            "the surviving record is some writer's final write"
        );
        assert_eq!(last.expires_at, last.last_request_at + HTTP_TTL_MS);
    }
}

#[test]
fn presence_dir_is_dot_memex_agents_under_the_vault() {
    let root = PathBuf::from("/some/vault root");
    assert_eq!(
        presence_dir(&root),
        PathBuf::from("/some/vault root/.memex/agents")
    );
}

// ---------------------------------------------------------------- AC 3

#[test]
fn read_all_skips_tmp_non_json_and_malformed_files_and_missing_dir_is_empty() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let a = record_expiring_at(Transport::Stdio, 100_000);
    let b = record_expiring_at(Transport::Http, 200_000);
    put_fixture(&dir, &a);
    put_fixture(&dir, &b);

    // A complete, valid record under a .json.tmp name: an in-flight write.
    let tmp = record_expiring_at(Transport::Bridge, 300_000);
    fs::write(
        dir.join(format!("{}.json.tmp", tmp.session_id)),
        serde_json::to_vec(&record_json(&tmp)).unwrap(),
    )
    .unwrap();
    // A valid record under a non-.json name.
    let txt = record_expiring_at(Transport::Stdio, 400_000);
    fs::write(
        dir.join(format!("{}.txt", txt.session_id)),
        serde_json::to_vec(&record_json(&txt)).unwrap(),
    )
    .unwrap();
    fs::write(dir.join("README"), b"not a record").unwrap();
    // Malformed .json files.
    fs::write(dir.join("broken.json"), b"{\"session_id\": ").unwrap();
    fs::write(dir.join("empty.json"), b"").unwrap();
    fs::write(dir.join("wrong-shape.json"), b"{\"session_id\": \"x\"}").unwrap();
    let mut bad_transport = record_json(&record_expiring_at(Transport::Stdio, 500_000));
    bad_transport["transport"] = json!("carrier-pigeon");
    fs::write(
        dir.join("bad-transport.json"),
        serde_json::to_vec(&bad_transport).unwrap(),
    )
    .unwrap();
    // An unreadable .json entry: a directory with that name.
    fs::create_dir(dir.join("subdir.json")).unwrap();

    assert_eq!(sorted(read_all(&dir)), sorted(vec![a, b]));

    let missing = vault.path().join("no-such-dir");
    assert_eq!(read_all(&missing), Vec::<PresenceRecord>::new());
    assert!(!missing.exists(), "read_all never creates the dir");
}

// ---------------------------------------------------------------- AC 4

#[test]
fn expires_at_adds_15s_to_last_seen_for_stdio_and_bridge_and_60s_to_last_request_for_http() {
    // last_request_at after last_seen_at ...
    let (seen, req) = (1_762_000_000_000_i64, 1_762_000_090_000_i64);
    assert_eq!(expires_at(Transport::Stdio, seen, req), seen + 15_000);
    assert_eq!(expires_at(Transport::Bridge, seen, req), seen + 15_000);
    assert_eq!(expires_at(Transport::Http, seen, req), req + 60_000);
    // ... and before it, so each transport is shown to read its own field.
    let (seen, req) = (2_000_000, 1_000_000);
    assert_eq!(expires_at(Transport::Stdio, seen, req), 2_015_000);
    assert_eq!(expires_at(Transport::Bridge, seen, req), 2_015_000);
    assert_eq!(expires_at(Transport::Http, seen, req), 1_060_000);
}

#[test]
fn presence_constants_match_the_spec() {
    assert_eq!(HEARTBEAT_MS, 5_000);
    assert_eq!(STDIO_TTL_MS, 15_000);
    assert_eq!(BRIDGE_TTL_MS, 15_000);
    assert_eq!(HTTP_TTL_MS, 60_000);
    assert_eq!(IDENTITY_MAX_CHARS, 64);
    let (seen, req) = (7_000, 9_000);
    assert_eq!(expires_at(Transport::Stdio, seen, req), seen + STDIO_TTL_MS);
    assert_eq!(
        expires_at(Transport::Bridge, seen, req),
        seen + BRIDGE_TTL_MS
    );
    assert_eq!(expires_at(Transport::Http, seen, req), req + HTTP_TTL_MS);
}

// ---------------------------------------------------------------- AC 5

#[test]
fn is_expired_is_false_one_ms_before_expires_at_and_true_at_it_for_each_transport() {
    let clock = FakeClock::at(0);
    for (transport, seen, req, expected_expiry) in [
        (
            Transport::Stdio,
            1_000_000_i64,
            1_100_000_i64,
            1_015_000_i64,
        ),
        (Transport::Bridge, 2_000_000, 2_100_000, 2_015_000),
        (Transport::Http, 3_000_000, 2_900_000, 2_960_000),
    ] {
        let r = record(
            transport,
            "test-agent",
            None,
            seen - 1_000,
            seen,
            req,
            None,
            expected_expiry,
            false,
        );

        clock.set(expected_expiry - 10_000);
        assert!(!is_expired(&r, clock.now_ms()), "{transport:?} fresh");
        clock.set(expected_expiry - 1);
        assert!(
            !is_expired(&r, clock.now_ms()),
            "{transport:?} at expires_at - 1"
        );
        clock.set(expected_expiry);
        assert!(
            is_expired(&r, clock.now_ms()),
            "{transport:?} at expires_at"
        );
        clock.set(expected_expiry + 3_600_000);
        assert!(is_expired(&r, clock.now_ms()), "{transport:?} long after");
    }
}

/// `is_expired` compares against the record's stored `expires_at`, not a
/// value recomputed from its other timestamps.
#[test]
fn is_expired_reads_the_stored_expires_at() {
    let r = record(
        Transport::Stdio,
        "test-agent",
        None,
        0,
        0,
        0,
        None,
        100_000,
        false,
    );
    assert!(!is_expired(&r, 50_000));
    assert!(!is_expired(&r, 99_999));
    assert!(is_expired(&r, 100_000));
}

// ---------------------------------------------------------------- AC 6

#[test]
fn sweep_deletes_exactly_the_expired_records_and_missing_dir_is_ok() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let clock = FakeClock::at(1_762_000_000_000);
    let now = clock.now_ms();

    let long_gone = record_expiring_at(Transport::Stdio, now - 3_600_000);
    let at_boundary = record_expiring_at(Transport::Http, now);
    let one_ms_left = record_expiring_at(Transport::Bridge, now + 1);
    let fresh_http = record_expiring_at(Transport::Http, now + 59_000);
    let gone_paths = [
        put_fixture(&dir, &long_gone),
        put_fixture(&dir, &at_boundary),
    ];
    let kept_paths = [
        put_fixture(&dir, &one_ms_left),
        put_fixture(&dir, &fresh_http),
    ];

    sweep(&dir, now).expect("sweep");

    for p in &gone_paths {
        assert!(!p.exists(), "{} should be swept", p.display());
    }
    for p in &kept_paths {
        assert!(p.exists(), "{} should be kept", p.display());
    }
    assert_eq!(
        sorted(read_all(&dir)),
        sorted(vec![one_ms_left, fresh_http])
    );

    let missing = vault.path().join("no-such-dir");
    assert!(sweep(&missing, now).is_ok());
    assert!(!missing.exists(), "sweep never creates the dir");
}

/// Sweep deletes expired records only: an in-flight `.json.tmp` (whose
/// rename would otherwise fail), non-record files and unparseable `.json`
/// files stay, and none of them make the sweep fail.
#[test]
fn sweep_leaves_tmp_and_non_record_files_alone() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let now = 10_000_000;
    let expired = record_expiring_at(Transport::Stdio, now - 1);
    let expired_path = put_fixture(&dir, &expired);

    // An expired record mid-write under its .tmp name.
    let in_flight = record_expiring_at(Transport::Stdio, now - 1);
    let tmp_path = dir.join(format!("{}.json.tmp", in_flight.session_id));
    fs::write(
        &tmp_path,
        serde_json::to_vec(&record_json(&in_flight)).unwrap(),
    )
    .unwrap();
    // An expired record under a non-.json name.
    let txt_path = dir.join("old.txt");
    fs::write(
        &txt_path,
        serde_json::to_vec(&record_json(&expired)).unwrap(),
    )
    .unwrap();
    let broken_path = dir.join("broken.json");
    fs::write(&broken_path, b"{not json").unwrap();

    assert!(sweep(&dir, now).is_ok());

    assert!(!expired_path.exists());
    assert!(tmp_path.exists(), ".json.tmp is not swept");
    assert!(txt_path.exists(), "non-.json file is not swept");
    assert!(broken_path.exists(), "malformed .json is not swept");
}

// ---------------------------------------------------------------- AC 7

#[test]
fn remove_deletes_the_session_file_and_absent_session_is_ok() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let gone = record_expiring_at(Transport::Stdio, 90_000);
    let other = record_expiring_at(Transport::Bridge, 90_000);
    let gone_path = put_fixture(&dir, &gone);
    let other_path = put_fixture(&dir, &other);

    remove(&dir, &gone.session_id).expect("remove");

    assert!(!gone_path.exists());
    assert!(other_path.exists(), "only the named session is removed");
    assert_eq!(read_all(&dir), vec![other.clone()]);

    assert!(remove(&dir, &gone.session_id).is_ok(), "already removed");
    assert!(remove(&dir, &new_session_id()).is_ok(), "never existed");
    let missing = vault.path().join("no-such-dir");
    assert!(remove(&missing, &other.session_id).is_ok(), "missing dir");
    assert!(other_path.exists());
}

#[cfg(unix)]
#[test]
fn sweep_returns_the_error_when_an_expired_record_cannot_be_deleted() {
    use std::os::unix::fs::PermissionsExt;

    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let now = 10_000_000;
    let expired = record_expiring_at(Transport::Stdio, now - 1);
    let expired_path = put_fixture(&dir, &expired);

    // A read-only dir: the record stays readable but cannot be unlinked.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o555)).unwrap();
    let probe = dir.join("probe");
    let can_write = fs::write(&probe, b"x").is_ok();
    let result = sweep(&dir, now);
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    if can_write {
        return; // running as a user that ignores dir permissions (root)
    }

    let err = result.expect_err("a failed delete is reported, not swallowed");
    assert_ne!(err.kind(), std::io::ErrorKind::NotFound);
    assert!(expired_path.exists(), "the record is still there");
}

/// `sweep` keeps going after a failed delete: with undeletable expired
/// records mixed among deletable ones, every deletable one is gone and the
/// error is still returned. macOS only: `chflags uchg` makes one file
/// undeletable without touching the dir, which no portable unprivileged
/// setup can do. Half the records are undeletable, so a sweep that stopped at
/// the first failure would almost surely leave a deletable record behind.
#[cfg(target_os = "macos")]
#[test]
fn sweep_deletes_every_deletable_expired_record_even_when_others_fail_to_delete() {
    use std::process::Command;

    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let now = 10_000_000;
    let mut locked = Vec::new();
    let mut deletable = Vec::new();
    for i in 0..12 {
        let r = record_expiring_at(Transport::Stdio, now - 1 - i);
        let path = put_fixture(&dir, &r);
        if i % 2 == 0 {
            locked.push(path);
        } else {
            deletable.push(path);
        }
    }
    let survivor = record_expiring_at(Transport::Stdio, now + 1);
    let survivor_path = put_fixture(&dir, &survivor);

    let chflags = |flag: &str| {
        Command::new("chflags")
            .arg(flag)
            .args(&locked)
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    if !chflags("uchg") {
        return; // no chflags available: cannot make a file undeletable
    }
    let result = sweep(&dir, now);
    let unlocked = chflags("nouchg");
    assert!(unlocked, "test cleanup: could not clear the immutable flag");

    let err = result.expect_err("the failed deletes are reported");
    assert_ne!(err.kind(), std::io::ErrorKind::NotFound);
    for path in &deletable {
        assert!(!path.exists(), "deletable expired record {path:?} was kept");
    }
    for path in &locked {
        assert!(path.exists(), "undeletable record {path:?} is still there");
    }
    assert!(survivor_path.exists(), "unexpired record kept");
}

#[cfg(unix)]
#[test]
fn remove_returns_the_error_when_the_record_path_cannot_be_unlinked() {
    let vault = tempfile::tempdir().unwrap();
    let dir = agents_dir(vault.path());
    let id = new_session_id();
    // A directory where the record file should be: unlinking it fails with an
    // error that is not NotFound.
    fs::create_dir_all(dir.join(format!("{id}.json"))).unwrap();

    let err = remove(&dir, &id).expect_err("a non-NotFound failure is reported");
    assert_ne!(err.kind(), std::io::ErrorKind::NotFound);
}

// ---------------------------------------------------------------- AC 8

#[test]
fn truncate_identity_cuts_to_64_chars_on_char_boundaries() {
    let exactly_64 = "a".repeat(64);
    assert_eq!(truncate_identity(&exactly_64), exactly_64);

    let sixty_five = format!("{}Z", "b".repeat(64));
    assert_eq!(truncate_identity(&sixty_five), "b".repeat(64));

    // 70 two-byte chars: a byte slice at 64 would cut mid-char.
    let accents = "é".repeat(70);
    let cut = truncate_identity(&accents);
    assert_eq!(cut, "é".repeat(64));
    assert_eq!(cut.chars().count(), 64);
    assert_eq!(cut.len(), 128);

    // Odd byte offset: 1-byte prefix then 2-byte chars.
    let mixed = format!("x{}", "é".repeat(70));
    assert_eq!(truncate_identity(&mixed), format!("x{}", "é".repeat(63)));

    // 4-byte chars.
    let emoji = "🤖".repeat(65);
    assert_eq!(truncate_identity(&emoji), "🤖".repeat(64));

    assert_eq!(truncate_identity("claude-code"), "claude-code");
    assert_eq!(truncate_identity(""), "");
}

// ---------------------------------------------------------------- AC 9

#[test]
fn activity_entry_round_trips_through_json_with_snake_case_keys_and_nullable_note_id() {
    let created_at = 1_762_000_000_000_i64 + i64::from(std::process::id() % 1000);
    let with_note = ActivityEntry {
        id: ulid::Ulid::new().to_string(),
        session_id: new_session_id(),
        client_name: "claude-code".to_string(),
        tool: "add_excerpt".to_string(),
        summary: format!("filed {} blocks into Reading", 3),
        note_id: Some(ulid::Ulid::new().to_string()),
        created_at,
    };
    let without_note = ActivityEntry {
        note_id: None,
        tool: "delete_smart_folder".to_string(),
        summary: "deleted Smart Folder Inbox".to_string(),
        ..with_note.clone()
    };
    let expected_keys = keys(&[
        "id",
        "session_id",
        "client_name",
        "tool",
        "summary",
        "note_id",
        "created_at",
    ]);

    for entry in [&with_note, &without_note] {
        let v = serde_json::to_value(entry).unwrap();
        assert_eq!(json_keys(&v), expected_keys, "keys of {v}");
        assert_eq!(v["id"], json!(entry.id));
        assert_eq!(v["session_id"], json!(entry.session_id));
        assert_eq!(v["client_name"], json!(entry.client_name));
        assert_eq!(v["tool"], json!(entry.tool));
        assert_eq!(v["summary"], json!(entry.summary));
        assert_eq!(v["note_id"], json!(entry.note_id));
        assert_eq!(v["created_at"], json!(entry.created_at));
        let back: ActivityEntry = serde_json::from_value(v).unwrap();
        assert_eq!(&back, entry);
    }
    assert_eq!(
        serde_json::to_value(&without_note).unwrap()["note_id"],
        Value::Null
    );

    // And from the wire shape directly.
    let parsed: ActivityEntry = serde_json::from_value(json!({
        "id": "01JC0000000000000000000000",
        "session_id": "01JC0000000000000000000001",
        "client_name": "Claude Desktop",
        "tool": "tag_note",
        "summary": "tagged Ideas with #rust",
        "note_id": null,
        "created_at": 42,
    }))
    .unwrap();
    assert_eq!(
        parsed,
        ActivityEntry {
            id: "01JC0000000000000000000000".to_string(),
            session_id: "01JC0000000000000000000001".to_string(),
            client_name: "Claude Desktop".to_string(),
            tool: "tag_note".to_string(),
            summary: "tagged Ideas with #rust".to_string(),
            note_id: None,
            created_at: 42,
        }
    );
}

// ---------------------------------------------------------------- AC 10

fn normalize(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

#[test]
fn glossary_has_agents_section_directly_before_vault_management() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../GLOSSARY.md");
    let text = fs::read_to_string(&path).expect("GLOSSARY.md at the repo root");
    let lines: Vec<&str> = text.lines().collect();

    let starts: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.trim_end() == "## Agents (#390)")
        .map(|(i, _)| i)
        .collect();
    assert_eq!(starts.len(), 1, "exactly one `## Agents (#390)` heading");
    let start = starts[0];

    let next = lines[start + 1..]
        .iter()
        .position(|l| l.starts_with("## "))
        .map(|p| start + 1 + p)
        .expect("a heading after the Agents section");
    assert_eq!(lines[next].trim_end(), "## Vault management (#355)");

    let section = normalize(&lines[start + 1..next].join("\n"));
    for needle in [
        "**Agent presence**:",
        "the expiring record that says an MCP client is connected to a vault right now, one per `memex serve` session, bridge or HTTP client.",
        "_Avoid_: session, connection",
        "**Agent activity log**:",
        "the `agent_activity` table of one-line summaries of agent writes, shown in the sidebar footer and the Agents sheet. It is not the per-note Activity tab, which shows `agent_changes`.",
        "_Avoid_: activity feed, audit log",
    ] {
        assert!(
            section.contains(&normalize(needle)),
            "Agents section should contain {needle:?}; got {section:?}"
        );
    }
}
