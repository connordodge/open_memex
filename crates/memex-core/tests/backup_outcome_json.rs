//! WI #316 (R0): `BackupOutcome::to_json` and `RestoreOutcome::to_json`
//! (Spec #315 req 17, 34), equal to the shared fixtures under
//! `app/test/fixtures/backup/cli/` that the app's fake `memex` prints.

use std::fs;
use std::path::PathBuf;

use memex_core::backup::{BackupOutcome, RestoreOutcome};
use serde_json::{json, Value};

fn cli_fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/backup/cli")
        .join(name);
    let raw = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&raw).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn s(v: &Value, k: &str) -> String {
    v[k].as_str()
        .unwrap_or_else(|| panic!("{k} is a string: {v}"))
        .to_string()
}

/// The outcome built from the fixture's values at run time, so the test
/// never compares the fixture with itself.
fn created_from(v: &Value) -> BackupOutcome {
    BackupOutcome::Created {
        vault_id: s(v, "vault_id"),
        file: PathBuf::from(s(v, "file")),
        bytes: v["bytes"].as_u64().unwrap(),
        fingerprint: s(v, "fingerprint"),
        removed: v["removed"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| PathBuf::from(p.as_str().unwrap()))
            .collect(),
    }
}

fn unchanged_from(v: &Value) -> BackupOutcome {
    BackupOutcome::Unchanged {
        vault_id: s(v, "vault_id"),
        fingerprint: s(v, "fingerprint"),
        last_file: v["last_file"].as_str().map(PathBuf::from),
    }
}

#[test]
fn created_outcome_to_json_equals_the_backup_created_fixture() {
    let want = cli_fixture("backup_created.json");
    assert_eq!(want["removed"].as_array().map(Vec::len), Some(2), "fixture");
    assert_eq!(created_from(&want).to_json(), want);
}

#[test]
fn unchanged_outcome_to_json_equals_the_backup_unchanged_fixture() {
    let want = cli_fixture("backup_unchanged.json");
    assert!(want["last_file"].is_string(), "fixture has a last file");
    assert_eq!(unchanged_from(&want).to_json(), want);
}

#[test]
fn unchanged_outcome_without_a_last_file_prints_null_and_equals_the_fixture() {
    let want = cli_fixture("backup_unchanged_never.json");
    assert!(want["last_file"].is_null(), "fixture has no last file");
    let got = unchanged_from(&want).to_json();
    assert_eq!(got, want);
    assert!(
        got.as_object().unwrap().contains_key("last_file"),
        "last_file is present as null, not left out: {got}"
    );
}

#[test]
fn restore_outcome_to_json_equals_the_restore_ok_fixture() {
    let want = cli_fixture("restore_ok.json");
    let got = RestoreOutcome {
        vault_id: s(&want, "vault_id"),
        path: PathBuf::from(s(&want, "path")),
        created_at: want["created_at"].as_i64().unwrap(),
    }
    .to_json();
    assert_eq!(got, want);
}

#[test]
fn created_to_json_has_exactly_the_requirement_17_keys_and_keeps_the_removed_order() {
    let removed = vec![
        PathBuf::from("/b/notes-20261009T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip"),
        PathBuf::from("/b/notes-20261008T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip"),
    ];
    let bytes = u64::from(std::hint::black_box(7u8)) << 33;
    let got = BackupOutcome::Created {
        vault_id: "01JCB7Q4M8V2X5N9R3T6W0YZAE".into(),
        file: PathBuf::from("/b/My Drive/x.memex.zip"),
        bytes,
        fingerprint: "ab".repeat(32),
        removed,
    }
    .to_json();
    assert_eq!(
        got,
        json!({
            "result": "created",
            "vault_id": "01JCB7Q4M8V2X5N9R3T6W0YZAE",
            "file": "/b/My Drive/x.memex.zip",
            "bytes": bytes,
            "fingerprint": "ab".repeat(32),
            "removed": [
                "/b/notes-20261009T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip",
                "/b/notes-20261008T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip"
            ]
        })
    );
    assert!(got["bytes"].is_u64(), "bytes is a number: {got}");
}

#[test]
fn created_to_json_with_nothing_removed_prints_an_empty_array() {
    let got = BackupOutcome::Created {
        vault_id: "01JCB7Q4M8V2X5N9R3T6W0YZAE".into(),
        file: PathBuf::from("/b/x.memex.zip"),
        bytes: 0,
        fingerprint: "00".into(),
        removed: Vec::new(),
    }
    .to_json();
    assert_eq!(got["removed"], json!([]), "{got}");
    assert_eq!(got["result"], json!("created"));
    assert_eq!(got.as_object().unwrap().len(), 6, "{got}");
}

#[test]
fn unchanged_to_json_has_exactly_the_requirement_17_keys() {
    let got = BackupOutcome::Unchanged {
        vault_id: "01JCB7Q4M8V2X5N9R3T6W0YZAE".into(),
        fingerprint: "cd".into(),
        last_file: Some(PathBuf::from("/b/My Drive/y.memex.zip")),
    }
    .to_json();
    assert_eq!(
        got,
        json!({
            "result": "unchanged",
            "vault_id": "01JCB7Q4M8V2X5N9R3T6W0YZAE",
            "fingerprint": "cd",
            "last_file": "/b/My Drive/y.memex.zip"
        })
    );
}

#[test]
fn restore_to_json_has_exactly_the_requirement_34_keys() {
    let created_at = 1_794_214_800_000 + i64::from(std::hint::black_box(5u8));
    let got = RestoreOutcome {
        vault_id: "01JCB7Q4M8V2X5N9R3T6W0YZAE".into(),
        path: PathBuf::from("/Users/person/Documents/notes restored"),
        created_at,
    }
    .to_json();
    assert_eq!(
        got,
        json!({
            "vault_id": "01JCB7Q4M8V2X5N9R3T6W0YZAE",
            "path": "/Users/person/Documents/notes restored",
            "created_at": created_at
        })
    );
    assert!(got["created_at"].is_i64(), "created_at is a number: {got}");
}
