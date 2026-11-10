//! WI #316 (R0, ruling D18): every shared backup fixture exists under
//! `app/test/fixtures`, parses from Rust through `../../app/test/fixtures`,
//! holds its listed rows, and the ones with a Rust reader go through it.
//! The Dart half is `app/test/seams/backup_d18_fixtures_test.dart`.

use std::fs;
use std::path::{Path, PathBuf};

use memex_core::backup::state::{is_due, read_state};
use memex_core::backup::STATE_FILE;
use serde_json::{json, Value};

const THIS: &str = "01JCB7Q4M8V2X5N9R3T6W0YZAE";
const SEED: &str = "01M5DK9Z8CWPQGFA893JX9VRZF";
const BACKUP_PATH: &str = "/vaults/seed/api/v1/backup";

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../app/test/fixtures")
}

fn json_at(rel: &str) -> Value {
    let path = fixtures().join(rel);
    let raw = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&raw).unwrap_or_else(|e| panic!("{rel}: {e}"))
}

/// (method, path, response, status, dart_only) of one `index.json`, every
/// response file read.
fn rows(domain: &str) -> Vec<(String, String, Value, u64, bool)> {
    let index = json_at(&format!("api_v1/{domain}/index.json"));
    index
        .as_array()
        .unwrap_or_else(|| panic!("{domain}/index.json is an array"))
        .iter()
        .map(|r| {
            let response = r["response"].as_str().unwrap();
            (
                r["method"].as_str().unwrap().to_string(),
                r["path"].as_str().unwrap().to_string(),
                json_at(&format!("api_v1/{domain}/{response}")),
                r["status"].as_u64().unwrap(),
                r["dart_only"].as_bool().unwrap_or(false),
            )
        })
        .collect()
}

const GET_KEYS: [&str; 10] = [
    "enabled",
    "keep",
    "in_progress",
    "last_attempt_at",
    "last_success_at",
    "last_result",
    "last_error",
    "last_file",
    "last_file_created_at",
    "last_bytes",
];

fn assert_get_body(body: &Value, what: &str) {
    let obj = body.as_object().unwrap_or_else(|| panic!("{what}: object"));
    let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
    keys.sort();
    let mut want = GET_KEYS.to_vec();
    want.sort();
    assert_eq!(keys, want, "{what}: exactly the D17 GET keys");
}

#[test]
fn d18_backup_state_and_due_cases_fixtures_parse_through_the_rust_readers() {
    // backup_state.json: the five cases, through the real reader.
    let tmp = tempfile::TempDir::new().unwrap();
    fs::copy(
        fixtures().join("backup/backup_state.json"),
        tmp.path().join(STATE_FILE),
    )
    .unwrap();
    let state = read_state(tmp.path());
    assert_eq!(state.format, 1);
    let results: Vec<&str> = state
        .destinations
        .values()
        .map(|d| d.last_result.as_str())
        .collect();
    assert_eq!(
        results,
        vec![
            "created",
            "unchanged",
            "backup_failed",
            "backup_destination_unavailable",
            "backup_destination_unavailable"
        ]
    );
    let never = &state.destinations["/Volumes/backups/memex"];
    assert!(never.last_success_at.is_none() && never.last_file.is_none());
    assert!(never.last_bytes.is_none() && never.last_fingerprint.is_none());
    assert!(never.last_file_created_at.is_none() && never.last_error.is_some());

    // due_cases.json: every row through the real rule.
    let due = json_at("backup/due_cases.json");
    for c in due["cases"].as_array().unwrap() {
        assert_eq!(
            is_due(c["last_success_at"].as_i64(), c["now"].as_i64().unwrap()),
            c["due"].as_bool().unwrap(),
            "{c}"
        );
    }
}

#[test]
fn d18_file_names_fixture_lists_valid_names_look_alikes_and_folder_labels() {
    let v = json_at("backup/file_names.json");
    assert_eq!(v["vault_id"], json!(THIS));
    for (k, min) in [
        ("valid", 3),
        ("look_alikes", 6),
        ("partials", 2),
        ("file_names", 1),
        ("labels", 3),
    ] {
        assert!(
            v[k].as_array().map(Vec::len).unwrap_or(0) >= min,
            "file_names.json `{k}` has at least {min} rows"
        );
    }
    let looks: Vec<&str> = v["look_alikes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["name"].as_str().unwrap())
        .collect();
    let has = |pred: &dyn Fn(&str) -> bool, what: &str| {
        assert!(
            looks.iter().any(|n| pred(n)),
            "look-alike: {what}: {looks:?}"
        );
    };
    has(
        &|n| n.ends_with(".memex.zip") && !n.contains(THIS),
        "another vault_id",
    );
    has(&|n| n.ends_with(".MEMEX.ZIP"), ".MEMEX.ZIP");
    has(&|n| n.ends_with(".partial"), ".partial");
    has(&|n| n.contains("T090000-"), "no Z");
    has(&|n| n.starts_with(&"a".repeat(65)), "65-char label");
    has(&|n| n == "x.memex.zip", "x.memex.zip");
    for r in v["valid"].as_array().unwrap() {
        let name = r["name"].as_str().unwrap();
        let want = format!(
            "{}-{}-{}.memex.zip",
            r["label"].as_str().unwrap(),
            r["timestamp"].as_str().unwrap(),
            r["vault_id"].as_str().unwrap()
        );
        assert_eq!(name, want);
    }
    for r in v["labels"].as_array().unwrap() {
        assert!(r["folder"].is_string() && r["label"].is_string(), "{r}");
    }
}

#[test]
fn d18_cli_fixtures_exist_with_the_requirement_17_and_34_shapes() {
    let created = json_at("backup/cli/backup_created.json");
    assert_eq!(created["result"], json!("created"));
    assert_eq!(created.as_object().unwrap().len(), 6);
    let unchanged = json_at("backup/cli/backup_unchanged.json");
    assert_eq!(unchanged["result"], json!("unchanged"));
    assert!(unchanged["last_file"].is_string());
    let never = json_at("backup/cli/backup_unchanged_never.json");
    assert!(never["last_file"].is_null());
    let restore = json_at("backup/cli/restore_ok.json");
    assert_eq!(restore.as_object().unwrap().len(), 3);
    let too_new = json_at("backup/cli/errors/backup_too_new.json");
    assert_eq!(too_new["error"]["code"], json!("backup_too_new"));
    assert!(too_new["error"]["schema_version"].is_i64());
    assert!(too_new["error"]["supported_schema_version"].is_i64());
}

#[test]
fn d18_api_v1_backup_domains_and_the_compat_row_hold_their_listed_rows() {
    // api_v1/backup: a server with --backup-dir, keep 30, vault `seed`.
    let backup = rows("backup");
    let summary: Vec<(&str, u64, bool)> = backup
        .iter()
        .map(|(m, _, _, s, d)| (m.as_str(), *s, *d))
        .collect();
    assert_eq!(
        summary,
        vec![
            ("GET", 200, false),
            ("POST", 202, false),
            ("GET", 200, true),
            ("GET", 200, true),
            ("GET", 200, true),
            ("POST", 409, true),
        ]
    );
    assert!(backup.iter().all(|(_, p, _, _, _)| p == BACKUP_PATH));
    for (m, _, body, s, _) in &backup {
        if *s == 409 {
            assert_eq!(body["error"]["code"], json!("backup_in_progress"));
            continue;
        }
        assert_get_body(body, &format!("{m} {s}"));
        assert_eq!(body["enabled"], json!(true));
        assert_eq!(body["keep"], json!(30));
        if let Some(file) = body["last_file"].as_str() {
            assert!(file.starts_with("seed-") && file.contains(SEED), "{file}");
        }
    }
    let never = &backup[0].2;
    assert!(GET_KEYS[3..].iter().all(|k| never[*k].is_null()), "{never}");
    assert_eq!(never["in_progress"], json!(false));
    let mut accepted = never.clone();
    accepted["in_progress"] = json!(true);
    assert_eq!(
        backup[1].2, accepted,
        "POST 202 = the GET body + in_progress"
    );
    let results: Vec<&Value> = backup[2..5].iter().map(|r| &r.2["last_result"]).collect();
    assert_eq!(results[0], &json!("created"));
    assert!(results[1]
        .as_str()
        .is_some_and(|c| c.starts_with("backup_")));
    assert_eq!(backup[4].2["in_progress"], json!(true));

    // api_v1/backup_off: no --backup-dir.
    let off = rows("backup_off");
    assert_eq!(off.len(), 2);
    assert_eq!((off[0].0.as_str(), off[0].3, off[0].4), ("GET", 200, false));
    assert_get_body(&off[0].2, "backup_off GET");
    assert_eq!(off[0].2["enabled"], json!(false));
    assert_eq!(off[0].2["in_progress"], json!(false));
    assert!(off[0].2["keep"].is_null());
    assert!(GET_KEYS[3..].iter().all(|k| off[0].2[*k].is_null()));
    assert_eq!(
        (off[1].0.as_str(), off[1].3, off[1].4),
        ("POST", 409, false)
    );
    assert_eq!(off[1].2["error"]["code"], json!("backups_not_configured"));

    // compat: an old server has no /backup route.
    let compat = rows("compat");
    let old: Vec<_> = compat
        .iter()
        .filter(|(_, p, _, _, _)| p == BACKUP_PATH)
        .collect();
    assert_eq!(old.len(), 1);
    let (m, _, body, status, dart_only) = old[0];
    assert_eq!((m.as_str(), *status, *dart_only), ("GET", 404, true));
    assert_eq!(body["error"]["code"], json!("not_found"));
    assert!(Path::new(&fixtures().join("api_v1/compat/info_unknown_key.json")).is_file());
}
