//! WI #317 (R1a): the backup fingerprint (Spec #315 req 7, technical
//! decision 4; architecture D7).
//!
//! `Fingerprinter` is SHA-256 over the tag `b"memex-backup-fp-1\0"`, then
//! each part length-prefixed as a little-endian u64: the snapshot with bytes
//! 24–27 and 92–99 zeroed, then `manifest.json`, then each `objects/` file as
//! (path length, `/`-joined UTF-8 relative path, content length, bytes), fed
//! by the caller sorted bytewise by path. `finish()` is lowercase hex.
//!
//! The pinned digests were computed outside Rust (Python `hashlib`) from the
//! layout above. `reference` below is the same layout, for inputs the pins
//! don't cover.

use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use memex_core::backup::fingerprint::Fingerprinter;
use memex_core::backup::{self, snapshot, BackupOutcome};
use memex_core::fs_guard::FsInfo;
use memex_core::Vault;
use rusqlite::params;
use sha2::{Digest, Sha256};

/// `fixed_input()` digested by the D7 layout (Python `hashlib.sha256`).
const PINNED_DIGEST: &str = "224d69d3a625d0e098ab9b23aada9080dcea84ff377029e5be9cc6d868d7c483";
/// An empty snapshot, an empty manifest and no objects: the tag and two
/// zero length prefixes.
const PINNED_EMPTY_DIGEST: &str =
    "785a44ad0b9396adc6f263292b6725c0206892cd4674efb9a143b0093f4c6124";

const MANIFEST: &[u8] =
    br#"{"vault_id":"01JCB7Q4M8V2X5N9R3T6W0YZAE","schema_version":6,"created_at":1794214800000}"#;

/// The header bytes that are zeroed while hashing.
const ZEROED: [usize; 12] = [24, 25, 26, 27, 92, 93, 94, 95, 96, 97, 98, 99];

struct Input {
    snapshot: Vec<u8>,
    manifest: Vec<u8>,
    objects: Vec<(String, Vec<u8>)>,
}

fn fixed_input() -> Input {
    Input {
        snapshot: (0..200u32).map(|i| ((i * 37 + 11) % 256) as u8).collect(),
        manifest: MANIFEST.to_vec(),
        objects: vec![
            ("a b/note one.md".to_string(), b"hello\n".to_vec()),
            ("a b/\u{fc}.bin".to_string(), vec![0, 1, 2, 255]),
            ("z/empty".to_string(), Vec::new()),
        ],
    }
}

/// A reader that hands out at most `chunk` bytes per `read` call.
struct Trickle<'a> {
    bytes: &'a [u8],
    chunk: usize,
}

impl Read for Trickle<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.chunk.min(buf.len()).min(self.bytes.len());
        buf[..n].copy_from_slice(&self.bytes[..n]);
        self.bytes = &self.bytes[n..];
        Ok(n)
    }
}

/// A reader that fails after handing out `ok` bytes.
struct Failing {
    ok: usize,
}

impl Read for Failing {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.ok == 0 {
            return Err(io::Error::other("disk went away"));
        }
        let n = self.ok.min(buf.len());
        buf[..n].fill(7);
        self.ok -= n;
        Ok(n)
    }
}

fn digest_chunked(input: &Input, chunk: usize) -> String {
    let mut fp = Fingerprinter::new();
    fp.snapshot(&mut Trickle {
        bytes: &input.snapshot,
        chunk,
    })
    .expect("snapshot part");
    fp.manifest(&input.manifest);
    for (rel, bytes) in &input.objects {
        fp.object(rel, &mut Trickle { bytes, chunk })
            .expect("object part");
    }
    fp.finish()
}

fn digest(input: &Input) -> String {
    let mut fp = Fingerprinter::new();
    fp.snapshot(&mut input.snapshot.as_slice())
        .expect("snapshot part");
    fp.manifest(&input.manifest);
    for (rel, bytes) in &input.objects {
        fp.object(rel, &mut bytes.as_slice()).expect("object part");
    }
    fp.finish()
}

/// The D7 layout, written out independently of the implementation.
fn reference(input: &Input) -> String {
    let (mut h, part) = reference_head(input);
    for (rel, bytes) in &input.objects {
        part(&mut h, rel.as_bytes());
        part(&mut h, bytes);
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

type Part = fn(&mut Sha256, &[u8]);

/// The D7 layout up to the first object: tag, snapshot, manifest.
fn reference_head(input: &Input) -> (Sha256, Part) {
    let mut h = Sha256::new();
    h.update(b"memex-backup-fp-1\0");
    let mut snap = input.snapshot.clone();
    for i in ZEROED {
        if i < snap.len() {
            snap[i] = 0;
        }
    }
    fn part(h: &mut Sha256, bytes: &[u8]) {
        h.update((bytes.len() as u64).to_le_bytes());
        h.update(bytes);
    }
    let part: Part = part;
    part(&mut h, &snap);
    part(&mut h, &input.manifest);
    (h, part)
}

fn assert_lower_hex_sha256(d: &str) {
    assert_eq!(d.len(), 64, "{d:?} is 64 hex characters");
    assert!(
        d.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "{d:?} is lowercase hex"
    );
}

#[test]
fn a_fixed_input_produces_the_pinned_digest() {
    let input = fixed_input();
    assert_eq!(
        reference(&input),
        PINNED_DIGEST,
        "the test's reference layout"
    );
    let d = digest(&input);
    assert_lower_hex_sha256(&d);
    assert_eq!(d, PINNED_DIGEST);
    // Zero-length parts are still length-prefixed.
    let empty = Input {
        snapshot: Vec::new(),
        manifest: Vec::new(),
        objects: Vec::new(),
    };
    assert_eq!(digest(&empty), PINNED_EMPTY_DIGEST);
}

#[test]
fn the_digest_does_not_depend_on_how_the_readers_split_their_bytes() {
    let input = fixed_input();
    // 1 byte at a time; reads that end inside and straddle 24–27 and 92–99.
    for chunk in [1, 3, 25, 26, 93, 97, 100, 4096] {
        assert_eq!(
            digest_chunked(&input, chunk),
            PINNED_DIGEST,
            "chunk {chunk}"
        );
    }
    // A snapshot larger than any one read buffer.
    let mut big = fixed_input();
    big.snapshot = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    let want = reference(&big);
    assert_eq!(digest(&big), want);
    assert_eq!(digest_chunked(&big, 7), want);
}

#[test]
fn changing_a_snapshot_byte_outside_24_to_27_and_92_to_99_changes_the_digest() {
    let base = fixed_input();
    let last = base.snapshot.len() - 1;
    for at in [0, 1, 23, 28, 50, 91, 100, 101, last] {
        let mut changed = fixed_input();
        changed.snapshot[at] ^= 0x01;
        let d = digest(&changed);
        assert_ne!(d, PINNED_DIGEST, "snapshot byte {at} is covered");
        assert_eq!(d, reference(&changed), "snapshot byte {at}");
    }
    // A longer or shorter snapshot is another snapshot.
    let mut longer = fixed_input();
    longer.snapshot.push(0);
    assert_ne!(digest(&longer), PINNED_DIGEST);
    let mut shorter = fixed_input();
    shorter.snapshot.pop();
    assert_ne!(digest(&shorter), PINNED_DIGEST);
}

#[test]
fn changing_snapshot_bytes_24_to_27_or_92_to_99_does_not_change_the_digest() {
    for at in ZEROED {
        let mut changed = fixed_input();
        changed.snapshot[at] ^= 0xA5;
        assert_eq!(
            digest(&changed),
            PINNED_DIGEST,
            "snapshot byte {at} is zeroed"
        );
    }
    let mut all = fixed_input();
    for at in ZEROED {
        all.snapshot[at] = 0xFF;
    }
    assert_eq!(
        digest(&all),
        PINNED_DIGEST,
        "all of 24–27 and 92–99 at once"
    );
    assert_eq!(digest_chunked(&all, 1), PINNED_DIGEST);
}

#[test]
fn a_snapshot_shorter_than_the_header_fields_hashes_without_panicking() {
    for len in [0, 1, 24, 25, 27, 28, 92, 95, 99, 100] {
        let mut input = fixed_input();
        input.snapshot.truncate(len);
        assert_eq!(digest(&input), reference(&input), "snapshot of {len} bytes");
        assert_eq!(
            digest_chunked(&input, 1),
            reference(&input),
            "{len} bytes, trickled"
        );
    }
}

/// `input` differs from `fixed_input()` in one part: its digest is the D7
/// digest of `input`, so not the pinned one.
fn assert_changed(input: &Input, why: &str) {
    let d = digest(input);
    assert_lower_hex_sha256(&d);
    assert_eq!(
        d,
        reference(input),
        "{why}: the D7 digest of the changed input"
    );
    assert_ne!(d, PINNED_DIGEST, "{why}: the change is covered");
}

#[test]
fn changing_a_manifest_byte_changes_the_digest() {
    let base = fixed_input();
    for at in [0, base.manifest.len() / 2, base.manifest.len() - 1] {
        let mut changed = fixed_input();
        changed.manifest[at] ^= 0x01;
        assert_changed(&changed, &format!("manifest byte {at}"));
    }
    let mut longer = fixed_input();
    longer.manifest.push(b'\n');
    assert_changed(&longer, "manifest gains a byte");
}

#[test]
fn changing_an_object_path_changes_the_digest() {
    let renames = [
        (0, "a b/note one.MD"),
        (0, "a_b/note one.md"),
        (0, "a b/note one.m"),
        (1, "a b/u.bin"),
        (2, "z/empty2"),
    ];
    for (i, path) in renames {
        let mut changed = fixed_input();
        changed.objects[i].0 = path.to_string();
        assert_changed(&changed, &format!("object {i} renamed to {path:?}"));
    }
    // Adding or dropping an object, even an empty one, changes it.
    let mut fewer = fixed_input();
    fewer.objects.pop();
    assert_changed(&fewer, "the empty object dropped");
    let mut more = fixed_input();
    more.objects.push(("zz".to_string(), Vec::new()));
    assert_changed(&more, "an empty object added");
}

#[test]
fn changing_an_object_byte_changes_the_digest() {
    for (i, at) in [(0, 0), (0, 5), (1, 3)] {
        let mut changed = fixed_input();
        changed.objects[i].1[at] ^= 0x01;
        assert_changed(&changed, &format!("object {i} byte {at}"));
    }
    let mut grown = fixed_input();
    grown.objects[2].1.push(0);
    assert_changed(&grown, "an empty object gains a byte");
}

#[test]
fn length_prefixes_keep_every_part_boundary_distinct() {
    // Moving bytes across a boundary keeps the concatenation but changes
    // the lengths, so the digest changes.
    let base = Input {
        snapshot: vec![1; 120],
        manifest: b"{}".to_vec(),
        objects: vec![
            ("ab".to_string(), b"cd".to_vec()),
            ("e".to_string(), b"f".to_vec()),
        ],
    };
    let base_d = digest(&base);
    assert_eq!(base_d, reference(&base));
    let moved = [
        // snapshot | manifest
        Input {
            snapshot: vec![1; 121],
            manifest: b"}".to_vec(),
            objects: base.objects.clone(),
        },
        // path | content
        Input {
            snapshot: base.snapshot.clone(),
            manifest: base.manifest.clone(),
            objects: vec![
                ("a".to_string(), b"bcd".to_vec()),
                ("e".to_string(), b"f".to_vec()),
            ],
        },
        // content | next path
        Input {
            snapshot: base.snapshot.clone(),
            manifest: base.manifest.clone(),
            objects: vec![
                ("ab".to_string(), b"cde".to_vec()),
                ("".to_string(), b"f".to_vec()),
            ],
        },
        // one object split in two
        Input {
            snapshot: base.snapshot.clone(),
            manifest: base.manifest.clone(),
            objects: vec![("abcde".to_string(), b"f".to_vec())],
        },
    ];
    for (i, input) in moved.iter().enumerate() {
        let d = digest(input);
        assert_eq!(d, reference(input), "case {i}");
        assert_ne!(d, base_d, "case {i}: moved bytes across a part boundary");
    }
}

#[test]
fn a_read_error_in_the_snapshot_or_an_object_is_returned() {
    let mut fp = Fingerprinter::new();
    let err = fp
        .snapshot(&mut Failing { ok: 50 })
        .expect_err("a snapshot read error is an error, not a short snapshot");
    assert_eq!(err.code(), "backup_failed", "{err:?}");
    assert!(
        err.to_string().contains("disk went away"),
        "{err} keeps the cause"
    );
    let mut fp = Fingerprinter::new();
    fp.snapshot(&mut [1u8; 10].as_slice()).unwrap();
    fp.manifest(b"{}");
    let err = fp
        .object("a b/c", &mut Failing { ok: 3 })
        .expect_err("an object read error is an error, not a short object");
    assert_eq!(err.code(), "backup_failed", "{err:?}");
    assert!(
        err.to_string().contains("a b/c") && err.to_string().contains("disk went away"),
        "{err} names the object and keeps the cause"
    );
}

// ---- technical decision 4's proof on real snapshots -----------------------------------------

/// The fingerprint of a fresh snapshot of `root`, its manifest and objects.
fn vault_fingerprint(root: &Path) -> String {
    let snap = snapshot::take_snapshot(root)
        .unwrap_or_else(|e| panic!("take_snapshot({}): {e:?}", root.display()));
    let mut fp = Fingerprinter::new();
    let mut file = File::open(&snap.path).expect("open snapshot");
    fp.snapshot(&mut file).expect("hash snapshot");
    fp.manifest(&std::fs::read(root.join("manifest.json")).unwrap());
    let rel = "ab/image one.png";
    let mut obj = File::open(root.join("objects").join(rel)).unwrap();
    fp.object(rel, &mut obj).expect("hash object");
    let d = fp.finish();
    assert_lower_hex_sha256(&d);
    d
}

fn td4_vault() -> (tempfile::TempDir, std::path::PathBuf, Vault) {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("My Vault");
    let vault = Vault::create(&root).unwrap();
    std::fs::create_dir_all(root.join("objects/ab")).unwrap();
    std::fs::write(root.join("objects/ab/image one.png"), b"png bytes").unwrap();
    for i in 0..30 {
        vault
            .connection_ref()
            .execute(
                "INSERT INTO notes (id, title, content_md, created_at, updated_at)
                 VALUES (?1, ?2, 'body', 1, 1)",
                params![format!("N{i:025}"), format!("note {i}")],
            )
            .unwrap();
    }
    (tmp, root, vault)
}

#[test]
fn two_snapshots_of_an_unwritten_vault_have_equal_fingerprints() {
    // Open (rows in the WAL, as with the app running) and closed.
    let (_tmp, root, vault) = td4_vault();
    let first = vault_fingerprint(&root);
    let second = vault_fingerprint(&root);
    assert_eq!(
        first, second,
        "no write between two snapshots of an open vault"
    );
    drop(vault);
    let closed_first = vault_fingerprint(&root);
    let closed_second = vault_fingerprint(&root);
    assert_eq!(
        closed_first, closed_second,
        "no write between two snapshots of a closed vault"
    );
}

#[test]
fn one_committed_write_between_two_snapshots_changes_the_fingerprint() {
    let (_tmp, root, vault) = td4_vault();
    let before = vault_fingerprint(&root);
    vault
        .connection_ref()
        .execute(
            "UPDATE notes SET content_md = 'edited' WHERE title = 'note 7'",
            [],
        )
        .unwrap();
    let after = vault_fingerprint(&root);
    assert_ne!(before, after, "one committed write changes the fingerprint");
    assert_eq!(after, vault_fingerprint(&root), "and the new one is stable");
}

// ---- WI #134 (Spec #123 R51): content-addressed objects by path and size -----------------------

/// `fixed_input()`'s snapshot and manifest with no objects, digested on
/// main @ 3b6bbfd (Python `hashlib`, the layout above). R51 must not change
/// it: no vault held objects before #121.
const PINNED_NO_OBJECTS_DIGEST: &str =
    "1954dd8a10bca47b3221d06b5e33f2373cac79bb503de2d247adbdeff805514c";

/// The hash part of a content-addressed object path `<2 hex>/<64 hex>/<name>`.
const CA_HASH: &str = "66bc7611813b7443f25c4af21004864b3975eb83fb7c74be572b9d6aa74bd462";

fn ca_rel(name: &str) -> String {
    format!("66/{CA_HASH}/{name}")
}

/// Snapshot and manifest of `fixed_input()`, then one object through
/// `object_with_len`.
fn digest_with_len(rel: &str, len: u64, bytes: &mut dyn Read) -> memex_core::Result<String> {
    let input = fixed_input();
    let mut fp = Fingerprinter::new();
    fp.snapshot(&mut input.snapshot.as_slice()).unwrap();
    fp.manifest(&input.manifest);
    fp.object_with_len(rel, len, bytes)?;
    Ok(fp.finish())
}

#[test]
fn a_vault_with_no_objects_has_the_same_fingerprint_as_on_main() {
    let mut input = fixed_input();
    input.objects.clear();
    assert_eq!(
        reference(&input),
        PINNED_NO_OBJECTS_DIGEST,
        "the reference layout"
    );
    assert_eq!(digest(&input), PINNED_NO_OBJECTS_DIGEST);
}

#[test]
fn a_content_addressed_object_is_fingerprinted_by_path_and_size_never_its_bytes() {
    let rel = ca_rel("Q3 report.pdf");
    // Never read: a reader that fails on the first read still fingerprints.
    let never_read = digest_with_len(&rel, 9, &mut Failing { ok: 0 })
        .expect("a content-addressed object's bytes are never read");
    // Same size, other bytes: unchanged.
    let a = digest_with_len(&rel, 9, &mut b"123456789".as_slice()).unwrap();
    let b = digest_with_len(&rel, 9, &mut b"abcdefghi".as_slice()).unwrap();
    assert_eq!(a, b, "same size with changed bytes: unchanged");
    assert_eq!(a, never_read, "the bytes play no part");
    // Changed size: changed.
    let grown = digest_with_len(&rel, 10, &mut b"abcdefghij".as_slice()).unwrap();
    assert_ne!(a, grown, "changed size: changed");
    let empty = digest_with_len(&rel, 0, &mut b"".as_slice()).unwrap();
    assert_ne!(a, empty, "size 0 is a size too");
    // Another path: changed.
    let other = digest_with_len(&ca_rel("Q4 report.pdf"), 9, &mut b"abcdefghi".as_slice()).unwrap();
    assert_ne!(a, other, "another name: changed");
    let other_hash = format!("ab/ab{}/Q3 report.pdf", &CA_HASH[2..]);
    let other = digest_with_len(&other_hash, 9, &mut b"abcdefghi".as_slice()).unwrap();
    assert_ne!(a, other, "another hash: changed");
    // Not today's layout for the same bytes.
    let mut input = fixed_input();
    input.objects = vec![(rel.clone(), b"abcdefghi".to_vec())];
    assert_ne!(a, reference(&input), "not hashed by its bytes");
    assert_lower_hex_sha256(&a);
}

#[test]
fn a_content_addressed_object_is_hashed_as_its_path_part_then_its_size_as_a_le_u64_part() {
    let rel = ca_rel("Q3 report.pdf");
    let (mut h, part) = reference_head(&fixed_input());
    part(&mut h, rel.as_bytes());
    part(&mut h, &9u64.to_le_bytes());
    let want: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        digest_with_len(&rel, 9, &mut b"123456789".as_slice()).unwrap(),
        want,
        "path part, then the size's 8 little-endian bytes as a part"
    );
    // A size over 255 shows the byte order.
    let (mut h, part) = reference_head(&fixed_input());
    part(&mut h, rel.as_bytes());
    part(&mut h, &0x0102u64.to_le_bytes());
    let want: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        digest_with_len(&rel, 0x0102, &mut std::io::empty()).unwrap(),
        want
    );
}

#[test]
fn objects_that_are_not_content_addressed_are_fingerprinted_as_today() {
    for rel in [
        "a b/note one.md".to_string(),
        "ab/cdef0123".to_string(),
        "image one.png".to_string(),
        format!("66/{}/x.txt", &CA_HASH[..63]),
        format!("66/{CA_HASH}0/x.txt"),
        format!("66/{}g/x.txt", &CA_HASH[..63]),
        format!("zz/{CA_HASH}/x.txt"),
        format!("6/{CA_HASH}/x.txt"),
        format!("66/{CA_HASH}"),
        format!("66/{CA_HASH}/sub/x.txt"),
    ] {
        let bytes = b"same size".to_vec();
        let mut input = fixed_input();
        input.objects = vec![(rel.clone(), bytes.clone())];
        let got = digest_with_len(&rel, bytes.len() as u64, &mut bytes.as_slice()).unwrap();
        assert_eq!(
            got,
            reference(&input),
            "{rel}: hashed by its bytes as today"
        );
        let flipped =
            digest_with_len(&rel, bytes.len() as u64, &mut b"SAME SIZE".as_slice()).unwrap();
        assert_ne!(got, flipped, "{rel}: changed bytes change the digest");
    }
}

struct FixedClock(i64);

impl memex_core::Clock for FixedClock {
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

fn backup_at(vault: &Path, dest: &Path, at_ms: i64, if_changed: bool) -> BackupOutcome {
    let clock = FixedClock(at_ms);
    let seams = backup::BackupSeams {
        clock: &clock,
        probe: &local_probe,
        wrap_archive: &plain_sink,
    };
    let request = backup::BackupRequest {
        vault,
        destination: dest,
        keep: 30,
        if_changed,
        source: backup::BackupSource::Local,
    };
    backup::backup_with(&request, &seams).expect("the backup succeeds")
}

/// A closed vault `My Vault` and a destination `Backup Drive`.
fn backup_fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(tmp.path()).unwrap();
    let vault = root.join("My Vault");
    drop(Vault::create(&vault).unwrap());
    let dest = root.join("Backup Drive");
    std::fs::create_dir(&dest).unwrap();
    (tmp, vault, dest)
}

fn sha_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn zip_member(file: &Path, name: &str) -> Vec<u8> {
    let mut zip = zip::ZipArchive::new(File::open(file).unwrap()).unwrap();
    let mut out = Vec::new();
    zip.by_name(name).unwrap().read_to_end(&mut out).unwrap();
    out
}

/// 2026-11-10T10:00:00.250Z, then an hour apart.
const H1: i64 = 1_794_304_800_250;
const HOUR: i64 = 3_600_000;

#[test]
fn if_changed_ignores_same_size_byte_changes_in_content_addressed_objects_but_not_size_changes() {
    let (_tmp, vault, dest) = backup_fixture();
    let bytes = b"an attachment's bytes";
    let h = sha_hex(bytes);
    let rel = format!("objects/{}/{h}/attached file.pdf", &h[..2]);
    let object = vault.join(&rel);
    std::fs::create_dir_all(object.parent().unwrap()).unwrap();
    std::fs::write(&object, bytes).unwrap();

    let first = backup_at(&vault, &dest, H1, false);
    assert!(matches!(first, BackupOutcome::Created { .. }), "{first:?}");
    let unchanged = backup_at(&vault, &dest, H1 + HOUR, true);
    assert!(
        matches!(unchanged, BackupOutcome::Unchanged { .. }),
        "no change: the pre-pass equals the recorded write-pass fingerprint: {unchanged:?}"
    );

    // Same size, other bytes: the path holds the content hash, so unchanged.
    let mut flipped = bytes.to_vec();
    flipped[0] ^= 0x20;
    std::fs::write(&object, &flipped).unwrap();
    let same_size = backup_at(&vault, &dest, H1 + 2 * HOUR, true);
    assert!(
        matches!(same_size, BackupOutcome::Unchanged { .. }),
        "same size with changed bytes: unchanged: {same_size:?}"
    );

    // Changed size: a new backup, whose zip still carries the bytes in full.
    let mut grown = bytes.to_vec();
    grown.push(b'!');
    std::fs::write(&object, &grown).unwrap();
    let changed = backup_at(&vault, &dest, H1 + 3 * HOUR, true);
    let BackupOutcome::Created { file, .. } = changed else {
        panic!("changed size: a new backup: {changed:?}");
    };
    assert_eq!(
        zip_member(&file, &rel),
        grown,
        "the zip member holds the bytes"
    );
}

#[test]
fn if_changed_still_sees_byte_changes_in_objects_that_are_not_content_addressed() {
    let (_tmp, vault, dest) = backup_fixture();
    let object = vault.join("objects/ab/image one.png");
    std::fs::create_dir_all(object.parent().unwrap()).unwrap();
    std::fs::write(&object, b"png bytes").unwrap();
    let first = backup_at(&vault, &dest, H1, false);
    assert!(matches!(first, BackupOutcome::Created { .. }), "{first:?}");
    std::fs::write(&object, b"PNG BYTES").unwrap();
    let second = backup_at(&vault, &dest, H1 + HOUR, true);
    assert!(
        matches!(second, BackupOutcome::Created { .. }),
        "same size, other bytes, not content-addressed: changed: {second:?}"
    );
}

#[test]
fn a_backup_of_a_vault_with_no_objects_records_the_fingerprint_main_computes() {
    let (_tmp, vault, dest) = backup_fixture();
    let outcome = backup_at(&vault, &dest, H1, false);
    let BackupOutcome::Created {
        file, fingerprint, ..
    } = outcome
    else {
        panic!("a first backup creates a file: {outcome:?}");
    };
    let input = Input {
        snapshot: zip_member(&file, "memex.db"),
        manifest: zip_member(&file, "manifest.json"),
        objects: Vec::new(),
    };
    assert_eq!(fingerprint, reference(&input), "main's layout, unchanged");
}
