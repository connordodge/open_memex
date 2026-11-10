//! WI #317 (R1a): backup file names (Spec #315 req 4, 5; architecture D10).
//!
//! Every row of `app/test/fixtures/backup/file_names.json` (shared with the
//! Dart reader, A1) goes through `label_for`, `file_name`, `partial_name`,
//! `parse_file_name` and `is_partial_for`. Extra cases pin the grammar's edges:
//! parsing from the right, case, non-ASCII input that must never panic, and
//! UTC formatting whatever the process's local time zone.
//!
//! API under test (frozen, D5):
//!   names::label_for(&str) -> String
//!   names::file_name(label, at_ms, vault_id) -> String
//!   names::partial_name(&str) -> String
//!   names::parse_file_name(&str) -> Option<ParsedName { label, timestamp, vault_id }>
//!   names::is_partial_for(name, vault_id) -> bool

use std::path::PathBuf;
use std::process::Command;

use memex_core::backup::names::{self, ParsedName};
use serde_json::Value;

const VAULT_ID: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAE";
const OTHER_ID: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAF";

/// Set in a re-exec'd child to run the fixture rows under another `TZ`.
const TZ_CHILD_ENV: &str = "MEMEX_317_NAMES_TZ_CHILD";
const TZ_CHILD_OK: &str = "MEMEX_317_NAMES_TZ_CHILD_OK";

fn fixture() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/backup/file_names.json");
    let raw =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("file_names.json is JSON")
}

fn rows<'a>(v: &'a Value, key: &str) -> &'a Vec<Value> {
    let rows = v[key]
        .as_array()
        .unwrap_or_else(|| panic!("file_names.json has a {key} array"));
    assert!(!rows.is_empty(), "file_names.json {key} is empty");
    rows
}

fn s<'a>(row: &'a Value, key: &str) -> &'a str {
    row[key]
        .as_str()
        .unwrap_or_else(|| panic!("row {row} has no string {key}"))
}

fn parsed(label: &str, timestamp: &str, vault_id: &str) -> ParsedName {
    ParsedName {
        label: label.to_string(),
        timestamp: timestamp.to_string(),
        vault_id: vault_id.to_string(),
    }
}

/// Asserts every `file_names` row: the final name, its partial, and that the
/// final name parses back to the row's label and vault_id.
fn assert_file_name_rows(v: &Value) {
    for row in rows(v, "file_names") {
        let label = s(row, "label");
        let at_ms = row["at_ms"].as_i64().expect("at_ms is an integer");
        let vault_id = s(row, "vault_id");
        let name = names::file_name(label, at_ms, vault_id);
        assert_eq!(
            name,
            s(row, "name"),
            "file_name({label:?}, {at_ms}, {vault_id:?})"
        );
        assert_eq!(
            names::partial_name(&name),
            s(row, "partial"),
            "partial_name({name:?})"
        );
    }
}

#[test]
fn label_for_matches_every_folder_row_of_file_names_json() {
    let v = fixture();
    for row in rows(&v, "labels") {
        let folder = s(row, "folder");
        assert_eq!(
            names::label_for(folder),
            s(row, "label"),
            "label_for({folder:?})"
        );
    }
}

#[test]
fn file_name_and_partial_name_match_every_row_of_file_names_json() {
    let v = fixture();
    assert_file_name_rows(&v);
    for row in rows(&v, "file_names") {
        let name = s(row, "name");
        let p = names::parse_file_name(name)
            .unwrap_or_else(|| panic!("{name:?} (from file_name) does not parse"));
        assert_eq!(p.label, s(row, "label"), "label of {name:?}");
        assert_eq!(p.vault_id, s(row, "vault_id"), "vault_id of {name:?}");
        assert_eq!(
            names::parse_file_name(s(row, "partial")),
            None,
            "a .partial name is never a final backup name"
        );
    }
}

#[test]
fn every_valid_row_of_file_names_json_parses_to_its_label_timestamp_and_vault_id() {
    let v = fixture();
    for row in rows(&v, "valid") {
        let name = s(row, "name");
        assert_eq!(
            names::parse_file_name(name),
            Some(parsed(
                s(row, "label"),
                s(row, "timestamp"),
                s(row, "vault_id")
            )),
            "parse_file_name({name:?})"
        );
    }
}

#[test]
fn no_look_alike_of_file_names_json_parses_as_this_vaults_backup() {
    let v = fixture();
    let this_vault = s(&v, "vault_id");
    assert_eq!(this_vault, VAULT_ID);
    let mut parsed_some = 0;
    for row in rows(&v, "look_alikes") {
        let name = s(row, "name");
        let got = names::parse_file_name(name);
        let want = match &row["parses"] {
            Value::Null => None,
            p => Some(parsed(s(p, "label"), s(p, "timestamp"), s(p, "vault_id"))),
        };
        assert_eq!(got, want, "parse_file_name({name:?}): {}", s(row, "why"));
        if let Some(p) = got {
            parsed_some += 1;
            assert_ne!(
                p.vault_id, this_vault,
                "{name:?} parsed as this vault's backup"
            );
        }
    }
    assert!(
        parsed_some > 0,
        "the other vault's backup must parse (to its own vault_id)"
    );
}

#[test]
fn is_partial_for_matches_this_vault_ids_partial_names_only() {
    let v = fixture();
    for row in rows(&v, "partials") {
        let name = s(row, "name");
        let vault_id = s(row, "vault_id");
        let want = row["is_partial_for"]
            .as_bool()
            .expect("is_partial_for is a bool");
        assert_eq!(
            names::is_partial_for(name, vault_id),
            want,
            "is_partial_for({name:?}, {vault_id:?})"
        );
    }
    // Every final name and look-alike is never a partial of this vault.
    for key in ["valid", "look_alikes"] {
        for row in rows(&v, key) {
            let name = s(row, "name");
            assert!(
                !names::is_partial_for(name, VAULT_ID),
                "{key} row {name:?} is not a .partial of {VAULT_ID}"
            );
        }
    }
    // The partial of each file_names row belongs to its vault and no other.
    for row in rows(&v, "file_names") {
        let partial = s(row, "partial");
        assert!(
            names::is_partial_for(partial, s(row, "vault_id")),
            "{partial:?} is a .partial of its vault"
        );
        assert!(
            !names::is_partial_for(partial, OTHER_ID),
            "{partial:?} is not a .partial of {OTHER_ID}"
        );
    }
}

#[test]
fn is_partial_for_reads_the_vault_id_at_its_place_not_anywhere_in_the_name() {
    // This vault's id as the label, another vault's at the end.
    let name = format!(".{VAULT_ID}-20261109T090000Z-{OTHER_ID}.memex.zip.partial");
    assert!(!names::is_partial_for(&name, VAULT_ID), "{name:?}");
    assert!(names::is_partial_for(&name, OTHER_ID), "{name:?}");
    // A partial of a 64-character label is still this vault's.
    let label = "c".repeat(64);
    let partial = names::partial_name(&names::file_name(&label, 1_794_214_800_000, VAULT_ID));
    assert_eq!(
        partial,
        format!(".{label}-20261109T090000Z-{VAULT_ID}.memex.zip.partial")
    );
    assert!(names::is_partial_for(&partial, VAULT_ID), "{partial:?}");
    // Case-sensitive: a lower-case vault_id is another vault.
    assert!(!names::is_partial_for(
        &format!(".notes-20261109T090000Z-{VAULT_ID}.memex.zip.partial"),
        &VAULT_ID.to_lowercase()
    ));
}

#[test]
fn parse_file_name_reads_from_the_right_and_is_case_sensitive() {
    // A label may itself look like a timestamp and a vault_id: the last
    // 26 characters are the vault_id, then the timestamp, then the label.
    let label = format!("20261108T080000Z-{OTHER_ID}");
    let name = format!("{label}-20261109T090000Z-{VAULT_ID}.memex.zip");
    assert_eq!(
        names::parse_file_name(&name),
        Some(parsed(&label, "20261109T090000Z", VAULT_ID))
    );
    // `_` and `-` are label characters; label of exactly one character.
    assert_eq!(
        names::parse_file_name(&format!("_--20261109T090000Z-{VAULT_ID}.memex.zip")),
        Some(parsed("_-", "20261109T090000Z", VAULT_ID))
    );
    assert_eq!(
        names::parse_file_name(&format!("Z-20261109T090000Z-{VAULT_ID}.memex.zip")),
        Some(parsed("Z", "20261109T090000Z", VAULT_ID))
    );

    let rejected = [
        // Separators must be `-`.
        format!("notes_20261109T090000Z-{VAULT_ID}.memex.zip"),
        format!("notes-20261109T090000Z_{VAULT_ID}.memex.zip"),
        format!("notes-20261109T090000Z{VAULT_ID}.memex.zip"),
        // Timestamp shape `\d{{8}}T\d{{6}}Z`, case-sensitive.
        format!("notes-20261109t090000Z-{VAULT_ID}.memex.zip"),
        format!("notes-20261109T090000z-{VAULT_ID}.memex.zip"),
        format!("notes-2026110xT090000Z-{VAULT_ID}.memex.zip"),
        format!("notes-20261109T09000xZ-{VAULT_ID}.memex.zip"),
        format!("notes-20261109-090000Z-{VAULT_ID}.memex.zip"),
        format!("notes-20261109T0900000Z-{VAULT_ID}.memex.zip"),
        // Extension, case-sensitive and exact.
        format!("notes-20261109T090000Z-{VAULT_ID}.memex.Zip"),
        format!("notes-20261109T090000Z-{VAULT_ID}.Memex.zip"),
        format!("notes-20261109T090000Z-{VAULT_ID}memex.zip"),
        format!("notes-20261109T090000Z-{VAULT_ID}.memex.zip "),
        // 27-character vault_id.
        format!("notes-20261109T090000Z-{VAULT_ID}X.memex.zip"),
        // Label characters outside [A-Za-z0-9_-].
        format!("no.tes-20261109T090000Z-{VAULT_ID}.memex.zip"),
        format!("no/tes-20261109T090000Z-{VAULT_ID}.memex.zip"),
        format!(".notes-20261109T090000Z-{VAULT_ID}.memex.zip"),
        // Nothing but the suffix.
        ".memex.zip".to_string(),
        String::new(),
    ];
    for name in &rejected {
        assert_eq!(
            names::parse_file_name(name),
            None,
            "{name:?} must not parse"
        );
    }
}

#[test]
fn non_ascii_names_never_parse_and_never_panic() {
    // Multi-byte characters where a byte-offset slice would cut one in half.
    let cases = [
        format!("Café-20261109T090000Z-{VAULT_ID}.memex.zip"),
        "notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZé.memex.zip".to_string(),
        "notes-20261109T090000Z-é1JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip".to_string(),
        format!("notes-2026110éT090000Z-{VAULT_ID}.memex.zip"),
        format!("notes-20261109T090000Z-{VAULT_ID}.memex.zipé"),
        format!("notes-20261109T090000Z-{VAULT_ID}.mémex.zip"),
        "📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚📚.memex.zip"
            .to_string(),
        "é".repeat(60) + ".memex.zip",
        "é.memex.zip".to_string(),
        "é".to_string(),
        format!("notes 📚-20261109T090000Z-{VAULT_ID}.memex.zip"),
        format!("📚-20261109T090000Z-{VAULT_ID}.memex.zip"),
    ];
    for name in &cases {
        assert_eq!(
            names::parse_file_name(name),
            None,
            "{name:?} must not parse"
        );
        assert!(!names::is_partial_for(name, VAULT_ID), "{name:?}");
        let partial = format!(".{name}.partial");
        assert!(!names::is_partial_for(&partial, VAULT_ID), "{partial:?}");
    }
    // A non-ASCII vault_id argument is handled too.
    assert!(!names::is_partial_for(
        &format!(".notes-20261109T090000Z-{VAULT_ID}.memex.zip.partial"),
        "01JCB7Q4M8V2X5N9R3T6W0YZAé"
    ));
    // Still a valid name parses: proves the cases above fail on grammar.
    assert_eq!(
        names::parse_file_name(&format!("Caf--20261109T090000Z-{VAULT_ID}.memex.zip")),
        Some(parsed("Caf-", "20261109T090000Z", VAULT_ID))
    );
}

#[test]
fn file_name_formats_the_utc_timestamp_zero_padded_and_truncated_to_the_second() {
    // (at_ms, timestamp) computed in UTC.
    let cases: [(i64, &str); 7] = [
        (0, "19700101T000000Z"),
        (1_794_214_800_000, "20261109T090000Z"),
        (1_794_214_799_999, "20261109T085959Z"),
        // 2028-02-29T23:59:59.500Z, a leap day.
        (1_835_481_599_500, "20280229T235959Z"),
        // 2027-01-01T00:00:00Z.
        (1_798_761_600_000, "20270101T000000Z"),
        // 2026-03-08T07:30:00Z: 02:30 local time does not exist in US DST.
        (1_772_955_000_000, "20260308T073000Z"),
        // 2026-11-01T06:30:00Z: 01:30 local time happens twice in US DST.
        (1_793_514_600_000, "20261101T063000Z"),
    ];
    for (at_ms, ts) in cases {
        let name = names::file_name("v", at_ms, VAULT_ID);
        assert_eq!(
            name,
            format!("v-{ts}-{VAULT_ID}.memex.zip"),
            "at_ms {at_ms}"
        );
        assert_eq!(
            names::parse_file_name(&name),
            Some(parsed("v", ts, VAULT_ID)),
            "{name:?}"
        );
    }
}

#[test]
fn newest_backup_is_the_lexically_greatest_timestamp() {
    // Later instants always give lexically greater timestamps, across
    // second, minute, hour, day, month and year boundaries.
    let instants: [i64; 8] = [
        1_798_761_599_000, // 2026-12-31T23:59:59Z
        1_798_761_600_000, // 2027-01-01T00:00:00Z
        1_798_761_601_000,
        1_798_761_660_000,
        1_798_765_200_000,
        1_798_848_000_000,
        1_801_440_000_000,
        1_835_481_599_000, // 2028-02-29T23:59:59Z
    ];
    let stamps: Vec<String> = instants
        .iter()
        .map(|&ms| {
            let name = names::file_name("notes", ms, VAULT_ID);
            names::parse_file_name(&name)
                .unwrap_or_else(|| panic!("{name:?} does not parse"))
                .timestamp
        })
        .collect();
    for pair in stamps.windows(2) {
        assert!(
            pair[0] < pair[1],
            "{} must sort before {}",
            pair[0],
            pair[1]
        );
    }
    let v = fixture();
    let newest = rows(&v, "valid")
        .iter()
        .filter(|r| s(r, "label") == "notes" && s(r, "vault_id") == VAULT_ID)
        .map(|r| {
            names::parse_file_name(s(r, "name"))
                .expect("valid row parses")
                .timestamp
        })
        .max()
        .expect("fixture has this vault's notes backups");
    assert_eq!(newest, "20261109T090000Z");
}

#[test]
fn label_for_replaces_each_character_and_cuts_to_64_characters() {
    assert_eq!(names::label_for("A-z_0 9"), "A-z_0-9");
    assert_eq!(names::label_for("a/b\\c:d"), "a-b-c-d");
    assert_eq!(names::label_for("..."), "---");
    assert_eq!(names::label_for(&"d".repeat(63)), "d".repeat(63));
    assert_eq!(names::label_for(&"d".repeat(64)), "d".repeat(64));
    assert_eq!(names::label_for(&"d".repeat(65)), "d".repeat(64));
    // Cut by characters: 63 ASCII then a 4-byte character then more.
    let folder = format!("{}📚tail", "e".repeat(63));
    assert_eq!(names::label_for(&folder), format!("{}-", "e".repeat(63)));
    // Non-ASCII characters whose low byte is a label byte ('A', 'C', 'd', 'z',
    // '0', '_' ...) are still replaced: `c as u8` alone would keep them.
    assert_eq!(names::label_for("Łódź"), "--d-");
    assert_eq!(names::label_for("\u{0141}\u{0143}"), "--");
    assert_eq!(names::label_for("\u{0130}\u{017A}\u{0230}\u{015F}"), "----");
    assert_eq!(names::label_for("\u{0141}ab\u{0143}"), "-ab-");
    // Every label_for result is a label the parser accepts.
    for folder in [
        "My Notes",
        "Notes 📚",
        "Café",
        &"é".repeat(70),
        "x",
        "Łódź",
        "\u{0141}\u{0143}\u{0130}\u{017A}",
    ] {
        let label = names::label_for(folder);
        let name = names::file_name(&label, 1_794_214_800_000, VAULT_ID);
        assert_eq!(
            names::parse_file_name(&name).map(|p| p.label),
            Some(label.clone()),
            "label_for({folder:?}) = {label:?}"
        );
    }
}

/// Child half of the time-zone test: runs the fixture's file_names rows in a
/// process whose local zone is not UTC. Run by its parent, not directly.
#[test]
#[ignore = "child process of file_name_is_utc_whatever_the_local_time_zone"]
fn names_317_tz_child() {
    if std::env::var_os(TZ_CHILD_ENV).is_none() {
        return;
    }
    assert_file_name_rows(&fixture());
    assert_eq!(
        names::file_name("v", 1_793_514_600_000, VAULT_ID),
        format!("v-20261101T063000Z-{VAULT_ID}.memex.zip")
    );
    println!("{TZ_CHILD_OK}");
}

#[test]
fn file_name_is_utc_whatever_the_local_time_zone() {
    // +13:45/+12:45 and -10:00: the local date differs from UTC's.
    for tz in ["Pacific/Chatham", "Pacific/Honolulu", "America/New_York"] {
        let out = Command::new(std::env::current_exe().expect("test binary path"))
            .args([
                "--ignored",
                "--exact",
                "names_317_tz_child",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(TZ_CHILD_ENV, "1")
            .env("TZ", tz)
            .output()
            .expect("re-exec the test binary");
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success() && stdout.contains(TZ_CHILD_OK),
            "TZ={tz}: child failed ({:?})\nstdout:\n{stdout}\nstderr:\n{stderr}",
            out.status
        );
    }
}

#[test]
fn file_name_with_an_out_of_range_instant_falls_back_to_the_epoch_without_panicking() {
    // No clock reads these, but a corrupt value must not panic (chrono's
    // range ends far below `i64::MAX` milliseconds).
    for at_ms in [i64::MAX, i64::MIN] {
        let name = names::file_name("v", at_ms, VAULT_ID);
        assert_eq!(
            name,
            format!("v-19700101T000000Z-{VAULT_ID}.memex.zip"),
            "at_ms {at_ms}"
        );
        assert_eq!(
            names::parse_file_name(&name),
            Some(parsed("v", "19700101T000000Z", VAULT_ID))
        );
    }
}

#[test]
fn parse_file_name_label_length_and_vault_id_class_edges() {
    const TS: &str = "20261109T090000Z";
    // A label of 64 characters parses, 65 does not.
    let max = "m".repeat(64);
    assert_eq!(
        names::parse_file_name(&format!("{max}-{TS}-{VAULT_ID}.memex.zip")),
        Some(parsed(&max, TS, VAULT_ID))
    );
    assert_eq!(
        names::parse_file_name(&format!("{max}m-{TS}-{VAULT_ID}.memex.zip")),
        None,
        "a 65-character label"
    );
    // No label at all: an empty label, or no label separator.
    assert_eq!(
        names::parse_file_name(&format!("-{TS}-{VAULT_ID}.memex.zip")),
        None,
        "empty label"
    );
    assert_eq!(
        names::parse_file_name(&format!("{TS}-{VAULT_ID}.memex.zip")),
        None,
        "no label"
    );
    assert_eq!(
        names::parse_file_name(&format!("{TS}{VAULT_ID}.memex.zip")),
        None,
        "no label and no separator"
    );
    // The vault_id is 26 ASCII letters or digits; `_`, `-` and `.` are not
    // vault_id characters.
    for bad in [
        "01JCB7Q4M8V2X5N9R3T6W0YZ_E",
        "01JCB7Q4M8V2X5N9R3T6W0YZ-E",
        "-1JCB7Q4M8V2X5N9R3T6W0YZAE",
        "01JCB7Q4M8V2X5N9R3T6W0YZ.E",
        "01JCB7Q4M8V2X5N9R3T6W0YZ E",
    ] {
        assert_eq!(
            names::parse_file_name(&format!("notes-{TS}-{bad}.memex.zip")),
            None,
            "vault_id {bad:?}"
        );
    }
    // Letters and digits in either case are taken as given.
    for ok in ["abcdefghijklmnopqrstuvwxyz", "0123456789ABCDEFGHIJKLMNOP"] {
        assert_eq!(
            names::parse_file_name(&format!("notes-{TS}-{ok}.memex.zip")),
            Some(parsed("notes", TS, ok))
        );
    }
    // The shortest valid name has a one-character label.
    assert_eq!(
        names::parse_file_name(&format!("n-{TS}-{VAULT_ID}.memex.zip")),
        Some(parsed("n", TS, VAULT_ID))
    );
}

#[test]
fn is_partial_for_needs_the_dot_the_final_name_and_the_partial_suffix() {
    let name = format!("notes-20261109T090000Z-{VAULT_ID}.memex.zip");
    assert!(names::is_partial_for(&format!(".{name}.partial"), VAULT_ID));
    for not_partial in [
        // No leading dot.
        format!("{name}.partial"),
        // No `.partial` suffix.
        format!(".{name}"),
        name.clone(),
        // Wrong suffix, or a second one.
        format!(".{name}.partial.partial"),
        format!(".{name}.Partial"),
        format!(".{name}.partial "),
        // Two dots.
        format!("..{name}.partial"),
        // The inner name is not a final backup name.
        format!(".notes-20261109T090000Z-{VAULT_ID}.partial"),
        ".partial".to_string(),
        "..partial".to_string(),
        String::new(),
    ] {
        assert!(
            !names::is_partial_for(&not_partial, VAULT_ID),
            "{not_partial:?}"
        );
    }
}
