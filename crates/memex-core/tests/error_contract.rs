//! The shared error contract (CONTRACTS.md C1, architect ruling D4).
//!
//! Every `MemexError` variant has a stable machine-readable `code()` and a
//! JSON form `{"error":{"code":…,"message":…, …rule fields}}` that the CLI
//! prints on stderr and the MCP server returns for rule errors.

use memex_core::error::MemexError;
use serde_json::{json, Value};
use std::collections::BTreeSet;

const DAILY_ID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

/// Every variant, so the compiler forces this file to be updated when a
/// variant is added (no wildcard arm on purpose).
fn variant_name(e: &MemexError) -> &'static str {
    match e {
        MemexError::Io(_) => "Io",
        MemexError::Sqlite(_) => "Sqlite",
        MemexError::Json(_) => "Json",
        MemexError::InvalidId(_) => "InvalidId",
        MemexError::NotFound(_) => "NotFound",
        MemexError::VersionConflict { .. } => "VersionConflict",
        MemexError::ManifestInvalid(_) => "ManifestInvalid",
        MemexError::SchemaUnsupported { .. } => "SchemaUnsupported",
        MemexError::InvalidPath(_) => "InvalidPath",
        MemexError::EmbedderInit(_) => "EmbedderInit",
        MemexError::EmbedderInfer(_) => "EmbedderInfer",
        MemexError::TitleConflict { .. } => "TitleConflict",
        MemexError::TitleInvalid(_) => "TitleInvalid",
        MemexError::TooManyDedupCollisions { .. } => "TooManyDedupCollisions",
        MemexError::InvalidLinkKind(_) => "InvalidLinkKind",
        MemexError::Yaml(_) => "Yaml",
        MemexError::DailyNoteExists { .. } => "DailyNoteExists",
        MemexError::MarkerRule(_) => "MarkerRule",
        MemexError::RoleRule(_) => "RoleRule",
        MemexError::PinnedRule { .. } => "PinnedRule",
        MemexError::DepthExceeded { .. } => "DepthExceeded",
        MemexError::ChangeEntriesInvalid(_) => "ChangeEntriesInvalid",
        MemexError::ReviewStale { .. } => "ReviewStale",
        MemexError::NameConflict(_) => "NameConflict",
        MemexError::FolderCycle(_) => "FolderCycle",
        MemexError::InvalidDate(_) => "InvalidDate",
        MemexError::BlockNotFound(_) => "BlockNotFound",
        MemexError::SettingInvalid(_) => "SettingInvalid",
        MemexError::NetworkFilesystem(_) => "NetworkFilesystem",
        MemexError::UnknownTag(_) => "UnknownTag",
        MemexError::TagRemoved(_) => "TagRemoved",
        MemexError::GuideRule(_) => "GuideRule",
        MemexError::FeedbackHandled(_) => "FeedbackHandled",
        MemexError::FeedbackInvalid(_) => "FeedbackInvalid",
        MemexError::BackupDestinationUnavailable(_) => "BackupDestinationUnavailable",
        MemexError::BackupDestinationInsideVault(_) => "BackupDestinationInsideVault",
        MemexError::BackupInProgress(_) => "BackupInProgress",
        MemexError::BackupFailed(_) => "BackupFailed",
        MemexError::BackupInvalid(_) => "BackupInvalid",
        MemexError::BackupTooNew { .. } => "BackupTooNew",
        MemexError::RestoreTargetNotEmpty(_) => "RestoreTargetNotEmpty",
    }
}

const VARIANT_COUNT: usize = 41;

/// The variants listed in the C1 table, with their code and extra fields.
fn c1_samples() -> Vec<(MemexError, &'static str, Value)> {
    vec![
        (
            MemexError::VersionConflict {
                expected: 3,
                current: 4,
            },
            "version_conflict",
            json!({"expected": 3, "current": 4}),
        ),
        (
            MemexError::NotFound("note 01J9Z8Y7X6W5V4T3S2R1Q0P9N8".into()),
            "not_found",
            json!({}),
        ),
        (
            MemexError::TitleConflict {
                existing_id: DAILY_ID.into(),
                attempted_title: "Taken".into(),
            },
            "title_conflict",
            json!({"existing_id": DAILY_ID}),
        ),
        (
            MemexError::InvalidId("not-a-ulid".into()),
            "invalid_id",
            json!({}),
        ),
        (
            MemexError::DailyNoteExists {
                date: "2026-10-03".into(),
                existing_id: DAILY_ID.into(),
            },
            "daily_note_exists",
            json!({"date": "2026-10-03", "existing_id": DAILY_ID}),
        ),
        (
            MemexError::MarkerRule("agents may not write below the marker".into()),
            "marker_rule",
            json!({}),
        ),
        (
            MemexError::RoleRule("the target is not a topic note".into()),
            "role_rule",
            json!({}),
        ),
        (
            MemexError::PinnedRule {
                item: "01J9FOLDER0000000000000000/01J9NOTE00000000000000000".into(),
                name: "Reading List".into(),
            },
            "pinned_rule",
            json!({"item": "01J9FOLDER0000000000000000/01J9NOTE00000000000000000"}),
        ),
        (
            MemexError::DepthExceeded {
                max_depth: 2,
                required_depth: 3,
            },
            "depth_exceeded",
            json!({"max_depth": 2, "required_depth": 3}),
        ),
        (
            MemexError::ChangeEntriesInvalid("entry 2 overlaps entry 1".into()),
            "change_entries_invalid",
            json!({}),
        ),
        (
            MemexError::ReviewStale {
                version: 5,
                current: 7,
            },
            "review_stale",
            json!({"version": 5, "current": 7}),
        ),
        (
            MemexError::NameConflict("a sibling folder is already named Inbox".into()),
            "name_conflict",
            json!({}),
        ),
        (
            MemexError::FolderCycle("a folder cannot move under its own descendant".into()),
            "folder_cycle",
            json!({}),
        ),
        (
            MemexError::InvalidDate("2026-02-30".into()),
            "invalid_date",
            json!({}),
        ),
        (
            MemexError::BlockNotFound("^abc123 in 2026-10-03".into()),
            "block_not_found",
            json!({}),
        ),
        (
            MemexError::SettingInvalid("smart_folder_max_depth must be >= 1".into()),
            "setting_invalid",
            json!({}),
        ),
        (
            MemexError::NetworkFilesystem("/Volumes/share/vault (smbfs)".into()),
            "network_filesystem",
            json!({}),
        ),
    ]
    .into_iter()
    .chain(v6_samples())
    .chain(backup_samples())
    .collect()
}

/// The seven variants Spec #315 adds for backups (ruling D3). Only
/// `backup_too_new` carries rule fields: the backup's `schema_version` and
/// this memex's `supported_schema_version`.
fn backup_samples() -> Vec<(MemexError, &'static str, Value)> {
    vec![
        (
            MemexError::BackupDestinationUnavailable(
                "/Volumes/backups/memex does not exist".into(),
            ),
            "backup_destination_unavailable",
            json!({}),
        ),
        (
            MemexError::BackupDestinationInsideVault("/Users/person/notes/backups".into()),
            "backup_destination_inside_vault",
            json!({}),
        ),
        (
            MemexError::BackupInProgress("/Users/person/notes".into()),
            "backup_in_progress",
            json!({}),
        ),
        (
            MemexError::BackupFailed("quick_check failed on the snapshot".into()),
            "backup_failed",
            json!({}),
        ),
        (
            MemexError::BackupInvalid("backup.json is missing".into()),
            "backup_invalid",
            json!({}),
        ),
        (
            MemexError::BackupTooNew {
                backup: 7,
                supported: 6,
            },
            "backup_too_new",
            json!({"schema_version": 7, "supported_schema_version": 6}),
        ),
        (
            MemexError::RestoreTargetNotEmpty("/Users/person/notes restored".into()),
            "restore_target_not_empty",
            json!({}),
        ),
    ]
}

/// The five variants schema V6 adds for #234 and #233 (ruling D6): message
/// only, no rule fields.
fn v6_samples() -> Vec<(MemexError, &'static str, Value)> {
    vec![
        (
            MemexError::UnknownTag("pricing is not in the vocabulary".into()),
            "unknown_tag",
            json!({}),
        ),
        (
            MemexError::TagRemoved("the person removed #pricing from this note".into()),
            "tag_removed",
            json!({}),
        ),
        (
            MemexError::GuideRule("the Vault Guide cannot be tagged".into()),
            "guide_rule",
            json!({}),
        ),
        (
            MemexError::FeedbackHandled("feedback 01J9FB0000000000000000000 is handled".into()),
            "feedback_handled",
            json!({}),
        ),
        (
            MemexError::FeedbackInvalid("reply must be one line".into()),
            "feedback_invalid",
            json!({}),
        ),
    ]
}

/// Pre-existing variants that are not in the C1 table: they map to `internal`.
fn internal_samples() -> Vec<MemexError> {
    vec![
        MemexError::Io(std::io::Error::other("disk on fire")),
        MemexError::Sqlite(rusqlite::Error::QueryReturnedNoRows),
        MemexError::Json(serde_json::from_str::<Value>("{").unwrap_err()),
        MemexError::ManifestInvalid("missing vault_id".into()),
        MemexError::SchemaUnsupported { db: 9, app: 4 },
        MemexError::InvalidPath("../escape".into()),
        MemexError::EmbedderInit("model missing".into()),
        MemexError::EmbedderInfer("tensor shape".into()),
        MemexError::TitleInvalid("title cannot be empty".into()),
        MemexError::TooManyDedupCollisions { count: 1000 },
        MemexError::InvalidLinkKind("9bad".into()),
        MemexError::Yaml("bad indent".into()),
    ]
}

fn error_object(v: &Value) -> &serde_json::Map<String, Value> {
    let top = v.as_object().expect("to_error_json returns an object");
    assert_eq!(
        top.keys().collect::<Vec<_>>(),
        vec!["error"],
        "top level has only `error`: {v}"
    );
    top["error"].as_object().expect("`error` is an object")
}

#[test]
fn samples_cover_every_variant() {
    let mut names = BTreeSet::new();
    for (e, _, _) in c1_samples() {
        assert!(names.insert(variant_name(&e)), "duplicate sample");
    }
    for e in internal_samples() {
        assert!(names.insert(variant_name(&e)), "duplicate sample");
    }
    assert_eq!(names.len(), VARIANT_COUNT, "{names:?}");
}

#[test]
fn c1_variants_return_their_listed_code() {
    for (e, code, _) in c1_samples() {
        assert_eq!(e.code(), code, "{}", variant_name(&e));
    }
}

#[test]
fn existing_variants_outside_c1_return_internal() {
    for e in internal_samples() {
        assert_eq!(e.code(), "internal", "{}", variant_name(&e));
    }
}

#[test]
fn to_error_json_carries_code_display_message_and_exactly_the_listed_fields() {
    for (e, code, extras) in c1_samples() {
        let mut expected = serde_json::Map::new();
        expected.insert("code".into(), json!(code));
        expected.insert("message".into(), json!(e.to_string()));
        for (k, v) in extras.as_object().unwrap() {
            expected.insert(k.clone(), v.clone());
        }
        let got = e.to_error_json();
        assert_eq!(error_object(&got), &expected, "{}: {got}", variant_name(&e));
    }
}

#[test]
fn to_error_json_for_internal_variants_has_only_code_and_message() {
    for e in internal_samples() {
        let got = e.to_error_json();
        assert_eq!(
            got,
            json!({"error": {"code": "internal", "message": e.to_string()}}),
            "{}",
            variant_name(&e)
        );
    }
}

#[test]
fn version_conflict_json_matches_c1_sample() {
    let e = MemexError::VersionConflict {
        expected: 3,
        current: 4,
    };
    assert_eq!(
        e.to_error_json(),
        json!({"error": {
            "code": "version_conflict",
            "message": "version conflict: expected 3, current 4",
            "expected": 3,
            "current": 4
        }})
    );
}

#[test]
fn depth_exceeded_json_matches_c1_sample() {
    let e = MemexError::DepthExceeded {
        max_depth: 2,
        required_depth: 3,
    };
    assert_eq!(
        e.to_error_json(),
        json!({"error": {
            "code": "depth_exceeded",
            "message": "Smart Folder depth 3 exceeds the vault maximum of 2",
            "max_depth": 2,
            "required_depth": 3
        }})
    );
}

#[test]
fn daily_note_exists_json_matches_c1_sample() {
    let e = MemexError::DailyNoteExists {
        date: "2026-10-03".into(),
        existing_id: DAILY_ID.into(),
    };
    assert_eq!(
        e.to_error_json(),
        json!({"error": {
            "code": "daily_note_exists",
            "message": "a daily note for 2026-10-03 already exists: 01J9Z8Y7X6W5V4T3S2R1Q0P9N8",
            "date": "2026-10-03",
            "existing_id": DAILY_ID
        }})
    );
}

#[test]
fn json_integer_fields_are_numbers_not_strings() {
    let e = MemexError::ReviewStale {
        version: 5,
        current: 7,
    };
    let got = e.to_error_json();
    let obj = error_object(&got);
    assert_eq!(obj["version"].as_i64(), Some(5));
    assert_eq!(obj["current"].as_i64(), Some(7));
    assert_eq!(obj["code"], json!("review_stale"));
}

#[test]
fn version_conflict_message_still_contains_version_conflict() {
    let e = MemexError::VersionConflict {
        expected: 10,
        current: 11,
    };
    assert!(e.to_string().contains("version conflict"), "{e}");
}

#[test]
fn daily_note_exists_message_contains_existing_note_id() {
    let id = "01JAAAAAAAAAAAAAAAAAAAAAAA";
    let e = MemexError::DailyNoteExists {
        date: "2027-01-31".into(),
        existing_id: id.into(),
    };
    let msg = e.to_string();
    assert!(msg.contains(id), "{msg}");
    assert!(msg.contains("2027-01-31"), "{msg}");
}

#[test]
fn marker_rule_message_contains_marker_line() {
    let e = MemexError::MarkerRule("agents may not edit the footer".into());
    let msg = e.to_string();
    assert!(msg.contains("<!-- memex:topics -->"), "{msg}");
    assert!(msg.contains("agents may not edit the footer"), "{msg}");
}

#[test]
fn role_rule_message_contains_role() {
    let e = MemexError::RoleRule("target must be a topic note".into());
    let msg = e.to_string();
    assert!(msg.contains("role"), "{msg}");
    assert!(msg.contains("target must be a topic note"), "{msg}");
}

#[test]
fn pinned_rule_message_contains_name_and_json_omits_it() {
    let e = MemexError::PinnedRule {
        item: "01J9FOLDER0000000000000000".into(),
        name: "Project Atlas".into(),
    };
    let msg = e.to_string();
    assert!(msg.contains("Project Atlas"), "{msg}");
    assert_eq!(
        e.to_error_json(),
        json!({"error": {
            "code": "pinned_rule",
            "message": msg,
            "item": "01J9FOLDER0000000000000000"
        }})
    );
}

#[test]
fn change_entries_invalid_message_contains_violated_rule() {
    let e = MemexError::ChangeEntriesInvalid("entries must be sorted by ord".into());
    let msg = e.to_string();
    assert!(msg.contains("entries must be sorted by ord"), "{msg}");
}

#[test]
fn message_only_variants_keep_their_detail_in_the_message() {
    let cases = [
        MemexError::NameConflict("detail-name".into()),
        MemexError::FolderCycle("detail-cycle".into()),
        MemexError::InvalidDate("detail-date".into()),
        MemexError::BlockNotFound("detail-block".into()),
        MemexError::SettingInvalid("detail-setting".into()),
        MemexError::NetworkFilesystem("detail-network".into()),
    ];
    for e in cases {
        let detail = match &e {
            MemexError::NameConflict(s)
            | MemexError::FolderCycle(s)
            | MemexError::InvalidDate(s)
            | MemexError::BlockNotFound(s)
            | MemexError::SettingInvalid(s)
            | MemexError::NetworkFilesystem(s) => s.clone(),
            _ => unreachable!(),
        };
        let json = e.to_error_json();
        let msg = error_object(&json)["message"].as_str().unwrap().to_string();
        assert!(msg.contains(&detail), "{}: {msg}", variant_name(&e));
    }
}

#[test]
fn network_filesystem_json_is_c1_with_code_and_message_only() {
    let e = MemexError::NetworkFilesystem("/Volumes/share/vault (smbfs)".into());
    let got = e.to_error_json();
    assert_eq!(
        got,
        json!({"error": {"code": "network_filesystem", "message": e.to_string()}})
    );
    let msg = error_object(&got)["message"].as_str().unwrap();
    assert!(msg.contains("/Volumes/share/vault (smbfs)"), "{msg}");
    assert!(
        !msg.contains('\n'),
        "the message fits on the one C1 stderr line: {msg:?}"
    );
}

#[test]
fn v6_error_variants_serialize_with_their_exact_codes() {
    let samples = v6_samples();
    assert_eq!(samples.len(), 5);
    for (e, code, _) in samples {
        let detail = match &e {
            MemexError::UnknownTag(s)
            | MemexError::TagRemoved(s)
            | MemexError::GuideRule(s)
            | MemexError::FeedbackHandled(s)
            | MemexError::FeedbackInvalid(s) => s.clone(),
            other => panic!("not a V6 variant: {}", variant_name(other)),
        };
        assert_eq!(e.code(), code, "{}", variant_name(&e));
        let got = e.to_error_json();
        assert_eq!(
            got,
            json!({"error": {"code": code, "message": e.to_string()}}),
            "{}",
            variant_name(&e)
        );
        let msg = error_object(&got)["message"].as_str().unwrap();
        assert!(msg.contains(&detail), "{}: {msg}", variant_name(&e));
        assert!(!msg.contains('\n'), "{}: {msg:?}", variant_name(&e));
    }
}

#[test]
fn backup_error_variants_serialize_with_their_exact_codes() {
    let samples = backup_samples();
    assert_eq!(samples.len(), 7);
    let mut codes = BTreeSet::new();
    for (e, code, extras) in samples {
        assert_eq!(e.code(), code, "{}", variant_name(&e));
        assert!(codes.insert(code), "duplicate code {code}");
        let got = e.to_error_json();
        let obj = error_object(&got);
        assert_eq!(obj["code"], json!(code), "{}: {got}", variant_name(&e));
        assert_eq!(obj["message"], json!(e.to_string()), "{}", variant_name(&e));
        assert_eq!(
            obj.len(),
            2 + extras.as_object().unwrap().len(),
            "{}: exactly code, message and the listed fields: {got}",
            variant_name(&e)
        );
        for (k, v) in extras.as_object().unwrap() {
            assert_eq!(&obj[k], v, "{}: field {k}: {got}", variant_name(&e));
        }
        let msg = obj["message"].as_str().unwrap();
        assert!(!msg.contains('\n'), "{}: {msg:?}", variant_name(&e));
    }
}

#[test]
fn backup_message_variants_keep_their_detail_in_the_message() {
    for (e, _, _) in backup_samples() {
        let detail = match &e {
            MemexError::BackupDestinationUnavailable(s)
            | MemexError::BackupDestinationInsideVault(s)
            | MemexError::BackupInProgress(s)
            | MemexError::BackupFailed(s)
            | MemexError::BackupInvalid(s)
            | MemexError::RestoreTargetNotEmpty(s) => s.clone(),
            MemexError::BackupTooNew { .. } => continue,
            other => panic!("not a backup variant: {}", variant_name(other)),
        };
        assert_ne!(e.code(), "internal", "{}", variant_name(&e));
        let got = e.to_error_json();
        let msg = error_object(&got)["message"].as_str().unwrap();
        assert!(msg.contains(&detail), "{}: {msg}", variant_name(&e));
    }
}

/// `app/test/fixtures/backup/cli/errors/backup_too_new.json`, the C1 line
/// the app reads `schema_version` and `supported_schema_version` from
/// (`MemexException.fields`), never the message.
fn backup_too_new_fixture() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/backup/cli/errors/backup_too_new.json");
    let raw =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("backup_too_new.json is JSON")
}

#[test]
fn backup_too_new_json_carries_both_schema_versions_and_matches_the_shared_fixture() {
    let e = MemexError::BackupTooNew {
        backup: 7,
        supported: 6,
    };
    assert_eq!(e.to_error_json(), backup_too_new_fixture());

    // Built from run-time values: the fields follow the variant, not the fixture.
    let backup = i64::from(std::hint::black_box(12u8));
    let supported = memex_core::schema::APP_SCHEMA_VERSION;
    let e = MemexError::BackupTooNew { backup, supported };
    let got = e.to_error_json();
    let obj = error_object(&got);
    assert_eq!(obj["code"], json!("backup_too_new"));
    assert_eq!(obj["schema_version"].as_i64(), Some(backup), "{got}");
    assert_eq!(
        obj["supported_schema_version"].as_i64(),
        Some(supported),
        "{got}"
    );
    let msg = obj["message"].as_str().unwrap();
    assert!(
        msg.contains("V12") && msg.contains(&format!("V{supported}")),
        "{msg}"
    );
}

#[test]
fn schema_unsupported_stays_internal_and_backups_not_configured_is_not_a_memex_error() {
    let e = MemexError::SchemaUnsupported { db: 9, app: 6 };
    assert_eq!(e.code(), "internal");
    let all: Vec<&str> = c1_samples()
        .iter()
        .map(|(e, _, _)| e.code())
        .chain(internal_samples().iter().map(|e| e.code()))
        .collect();
    assert!(
        !all.contains(&"backups_not_configured"),
        "backups_not_configured is server-only (ApiError::new): {all:?}"
    );
    for code in [
        "backup_destination_unavailable",
        "backup_destination_inside_vault",
        "backup_in_progress",
        "backup_failed",
        "backup_invalid",
        "backup_too_new",
        "restore_target_not_empty",
    ] {
        assert_eq!(
            all.iter().filter(|c| **c == code).count(),
            1,
            "exactly one variant maps to {code}: {all:?}"
        );
    }
}
