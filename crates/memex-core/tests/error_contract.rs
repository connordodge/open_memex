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
        MemexError::ModelNotDownloaded => "ModelNotDownloaded",
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
        MemexError::WordInvalid(_) => "WordInvalid",
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
        MemexError::ReadOnlyRule(_) => "ReadOnlyRule",
        MemexError::ExcerptRule(_) => "ExcerptRule",
        MemexError::EditNotFound { .. } => "EditNotFound",
        MemexError::EditAmbiguous { .. } => "EditAmbiguous",
        MemexError::EditInvalid(_) => "EditInvalid",
    }
}

const VARIANT_COUNT: usize = 48;

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
    .chain(e0_samples())
    .chain(v8_samples())
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

/// The codes Spec #391 adds (WI #416, ruling D7): message only, no rule
/// fields. The embedder variants left `internal` for `embedder_unavailable`.
fn e0_samples() -> Vec<(MemexError, &'static str, Value)> {
    vec![
        (
            MemexError::ModelNotDownloaded,
            "model_not_downloaded",
            json!({}),
        ),
        (
            MemexError::EmbedderInit("Failed to retrieve onnx/model.onnx".into()),
            "embedder_unavailable",
            json!({}),
        ),
        (
            MemexError::EmbedderInfer("tensor shape [1, 7] != [1, 384]".into()),
            "embedder_unavailable",
            json!({}),
        ),
        (
            MemexError::WordInvalid("`two words` is not one word".into()),
            "word_invalid",
            json!({}),
        ),
    ]
}

/// The five variants Spec #7 adds (WI #8, ruling D2). `edit_not_found` and
/// `edit_ambiguous` carry the rule field `index`; the others are message only.
fn v8_samples() -> Vec<(MemexError, &'static str, Value)> {
    vec![
        (
            MemexError::ReadOnlyRule(
                "\"Pricing notes\" is read-only for agents; the person can change this in the app"
                    .into(),
            ),
            "read_only_rule",
            json!({}),
        ),
        (
            MemexError::ExcerptRule("the edit drops ![[2026-11-02#^b1]]".into()),
            "excerpt_rule",
            json!({}),
        ),
        (
            MemexError::EditNotFound {
                index: 2,
                message: "edit 2: old_text is not in the note".into(),
            },
            "edit_not_found",
            json!({"index": 2}),
        ),
        (
            MemexError::EditAmbiguous {
                index: 0,
                message: "edit 0: old_text appears 3 times".into(),
            },
            "edit_ambiguous",
            json!({"index": 0}),
        ),
        (
            MemexError::EditInvalid("give edits or content_md, not both".into()),
            "edit_invalid",
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

// ======================================================================
// WI #416 (Spec #391 req 18, ruling D7): model_not_downloaded,
// embedder_unavailable and word_invalid. Their HTTP statuses are pinned in
// memex-mcp's tests/server_vaults.rs (memex-core can't see the server).
// ======================================================================

#[test]
fn e0_variants_are_counted_and_each_new_code_belongs_to_exactly_its_variants() {
    // 43 after E0; Spec #7 (WI #8) adds five more.
    assert_eq!(VARIANT_COUNT, 48);
    let samples = e0_samples();
    assert_eq!(samples.len(), 4);
    for (e, code, _) in &samples {
        assert_eq!(e.code(), *code, "{}", variant_name(e));
    }
    let all: Vec<(&str, &str)> = c1_samples()
        .iter()
        .map(|(e, _, _)| (variant_name(e), e.code()))
        .chain(
            internal_samples()
                .iter()
                .map(|e| (variant_name(e), e.code())),
        )
        .collect();
    for (code, variants) in [
        ("model_not_downloaded", vec!["ModelNotDownloaded"]),
        (
            "embedder_unavailable",
            vec!["EmbedderInit", "EmbedderInfer"],
        ),
        ("word_invalid", vec!["WordInvalid"]),
    ] {
        let got: Vec<&str> = all
            .iter()
            .filter(|(_, c)| *c == code)
            .map(|(v, _)| *v)
            .collect();
        assert_eq!(got, variants, "the variants with code {code}: {all:?}");
    }
    for name in [
        "EmbedderInit",
        "EmbedderInfer",
        "ModelNotDownloaded",
        "WordInvalid",
    ] {
        assert!(
            !internal_samples().iter().any(|e| variant_name(e) == name),
            "{name} is no longer internal"
        );
    }
}

#[test]
fn model_not_downloaded_has_its_code_and_exact_message() {
    let e = MemexError::ModelNotDownloaded;
    assert_eq!(e.code(), "model_not_downloaded");
    assert_eq!(e.to_string(), "embedding model not downloaded");
    assert_eq!(
        e.to_error_json(),
        json!({"error": {
            "code": "model_not_downloaded",
            "message": "embedding model not downloaded"
        }})
    );
}

#[test]
fn embedder_init_and_infer_are_embedder_unavailable_and_keep_their_cause() {
    // Built from run-time values: the cause follows the error, not a literal.
    let n = std::hint::black_box(7u8);
    let init_cause = format!("hub refused connection {n}");
    let infer_cause = format!("tensor shape [1, {n}] != [1, 384]");
    for (e, cause) in [
        (MemexError::EmbedderInit(init_cause.clone()), &init_cause),
        (MemexError::EmbedderInfer(infer_cause.clone()), &infer_cause),
    ] {
        assert_eq!(e.code(), "embedder_unavailable", "{}", variant_name(&e));
        let got = e.to_error_json();
        assert_eq!(
            got,
            json!({"error": {"code": "embedder_unavailable", "message": e.to_string()}}),
            "{}",
            variant_name(&e)
        );
        let msg = error_object(&got)["message"].as_str().unwrap();
        assert!(msg.contains(cause.as_str()), "{}: {msg}", variant_name(&e));
        assert!(!msg.contains('\n'), "{}: {msg:?}", variant_name(&e));
    }
    // The two stay told apart by their message.
    assert_ne!(
        MemexError::EmbedderInit("x".into()).to_string(),
        MemexError::EmbedderInfer("x".into()).to_string()
    );
}

#[test]
fn word_invalid_has_code_word_invalid_and_keeps_its_message() {
    let word = format!("echo-{}", std::hint::black_box(3u8));
    let detail = format!("`{word} two` is not one word");
    let e = MemexError::WordInvalid(detail.clone());
    assert_eq!(e.code(), "word_invalid");
    let got = e.to_error_json();
    assert_eq!(
        got,
        json!({"error": {"code": "word_invalid", "message": e.to_string()}})
    );
    let msg = error_object(&got)["message"].as_str().unwrap();
    assert!(msg.contains(&detail), "{msg}");
    assert!(!msg.contains('\n'), "{msg:?}");
}

// ======================================================================
// WI #8 (Spec #7 Req 9, ruling D2): read_only_rule, excerpt_rule,
// edit_not_found, edit_ambiguous and edit_invalid. Their HTTP statuses and
// the MCP rule list are pinned in memex-mcp (tests/v8_error_codes.rs and
// the test module at the end of src/tools.rs).
// ======================================================================

/// Every (variant, code) pair the contract held before Spec #7, frozen here
/// so the V8 change can't move one.
const PRE_V8_CODES: [(&str, &str); 43] = [
    ("Io", "internal"),
    ("Sqlite", "internal"),
    ("Json", "internal"),
    ("InvalidId", "invalid_id"),
    ("NotFound", "not_found"),
    ("VersionConflict", "version_conflict"),
    ("ManifestInvalid", "internal"),
    ("SchemaUnsupported", "internal"),
    ("InvalidPath", "internal"),
    ("EmbedderInit", "embedder_unavailable"),
    ("EmbedderInfer", "embedder_unavailable"),
    ("ModelNotDownloaded", "model_not_downloaded"),
    ("TitleConflict", "title_conflict"),
    ("TitleInvalid", "internal"),
    ("TooManyDedupCollisions", "internal"),
    ("InvalidLinkKind", "internal"),
    ("Yaml", "internal"),
    ("DailyNoteExists", "daily_note_exists"),
    ("MarkerRule", "marker_rule"),
    ("RoleRule", "role_rule"),
    ("PinnedRule", "pinned_rule"),
    ("DepthExceeded", "depth_exceeded"),
    ("ChangeEntriesInvalid", "change_entries_invalid"),
    ("ReviewStale", "review_stale"),
    ("NameConflict", "name_conflict"),
    ("FolderCycle", "folder_cycle"),
    ("InvalidDate", "invalid_date"),
    ("BlockNotFound", "block_not_found"),
    ("SettingInvalid", "setting_invalid"),
    ("WordInvalid", "word_invalid"),
    ("NetworkFilesystem", "network_filesystem"),
    ("UnknownTag", "unknown_tag"),
    ("TagRemoved", "tag_removed"),
    ("GuideRule", "guide_rule"),
    ("FeedbackHandled", "feedback_handled"),
    ("FeedbackInvalid", "feedback_invalid"),
    (
        "BackupDestinationUnavailable",
        "backup_destination_unavailable",
    ),
    (
        "BackupDestinationInsideVault",
        "backup_destination_inside_vault",
    ),
    ("BackupInProgress", "backup_in_progress"),
    ("BackupFailed", "backup_failed"),
    ("BackupInvalid", "backup_invalid"),
    ("BackupTooNew", "backup_too_new"),
    ("RestoreTargetNotEmpty", "restore_target_not_empty"),
];

/// The five codes Spec #7 adds, by variant.
const V8_CODES: [(&str, &str); 5] = [
    ("ReadOnlyRule", "read_only_rule"),
    ("ExcerptRule", "excerpt_rule"),
    ("EditNotFound", "edit_not_found"),
    ("EditAmbiguous", "edit_ambiguous"),
    ("EditInvalid", "edit_invalid"),
];

/// (variant, code) of every sample, C1 and internal.
fn every_code() -> Vec<(&'static str, &'static str)> {
    c1_samples()
        .iter()
        .map(|(e, _, _)| (variant_name(e), e.code()))
        .chain(
            internal_samples()
                .iter()
                .map(|e| (variant_name(e), e.code())),
        )
        .collect()
}

#[test]
fn read_only_rule_serializes_with_code_read_only_rule_and_exactly_the_given_message() {
    let text = "\"Pricing notes\" is read-only for agents; the person can change this in the app";
    let e = MemexError::ReadOnlyRule(text.into());
    assert_eq!(e.code(), "read_only_rule");
    assert_eq!(e.to_string(), text, "the Display is the text itself");
    assert_eq!(
        e.to_error_json(),
        json!({"error": {"code": "read_only_rule", "message": text}})
    );

    // Built from run-time values: the message follows the variant's text.
    let title = format!("Launch plan {}", std::hint::black_box(8u8));
    let text =
        format!("\"{title}\" is read-only for agents; the person can change this in the app");
    let got = MemexError::ReadOnlyRule(text.clone()).to_error_json();
    let obj = error_object(&got);
    assert_eq!(obj["code"], json!("read_only_rule"), "{got}");
    assert_eq!(obj["message"], json!(text), "{got}");
    assert_eq!(obj.len(), 2, "code and message only: {got}");
}

#[test]
fn v8_error_variants_serialize_as_excerpt_rule_edit_not_found_edit_ambiguous_and_edit_invalid() {
    // Built from run-time values: the index and the detail follow the error.
    let n = std::hint::black_box(7usize);
    let excerpt = format!("the edit drops {n} transclusions");
    let missing = format!("edit {n}: old_text is not in the note");
    let ambiguous = format!("edit {}: old_text appears twice", n + 1);
    let invalid = format!("edits must hold 1 to {n} pairs");
    let cases: Vec<(MemexError, &str, Value, &String)> = vec![
        (
            MemexError::ExcerptRule(excerpt.clone()),
            "excerpt_rule",
            json!({}),
            &excerpt,
        ),
        (
            MemexError::EditNotFound {
                index: n,
                message: missing.clone(),
            },
            "edit_not_found",
            json!({"index": 7}),
            &missing,
        ),
        (
            MemexError::EditAmbiguous {
                index: n + 1,
                message: ambiguous.clone(),
            },
            "edit_ambiguous",
            json!({"index": 8}),
            &ambiguous,
        ),
        (
            MemexError::EditInvalid(invalid.clone()),
            "edit_invalid",
            json!({}),
            &invalid,
        ),
    ];
    for (e, code, extras, detail) in cases {
        assert_eq!(e.code(), code, "{}", variant_name(&e));
        let got = e.to_error_json();
        let obj = error_object(&got);
        let mut expected = serde_json::Map::new();
        expected.insert("code".into(), json!(code));
        expected.insert("message".into(), json!(e.to_string()));
        for (k, v) in extras.as_object().unwrap() {
            expected.insert(k.clone(), v.clone());
        }
        assert_eq!(obj, &expected, "{}: {got}", variant_name(&e));
        let msg = obj["message"].as_str().unwrap();
        assert!(msg.contains(detail.as_str()), "{}: {msg}", variant_name(&e));
        assert!(!msg.contains('\n'), "{}: {msg:?}", variant_name(&e));
    }
    // The index is a JSON number, never a string, and 0 is kept.
    let got = MemexError::EditAmbiguous {
        index: 0,
        message: "edit 0: old_text appears twice".into(),
    }
    .to_error_json();
    let obj = error_object(&got);
    assert_eq!(obj["index"].as_u64(), Some(0), "{got}");
    assert_eq!(obj["code"], json!("edit_ambiguous"), "{got}");
}

#[test]
fn error_contract_lists_the_five_v8_codes_and_every_existing_code_keeps_its_value() {
    assert_eq!(VARIANT_COUNT, PRE_V8_CODES.len() + V8_CODES.len());
    let samples = v8_samples();
    assert_eq!(samples.len(), 5);
    let got: BTreeSet<(&str, &str)> = samples
        .iter()
        .map(|(e, _, _)| (variant_name(e), e.code()))
        .collect();
    assert_eq!(got, V8_CODES.into_iter().collect::<BTreeSet<_>>());

    let all = every_code();
    assert_eq!(all.len(), VARIANT_COUNT);
    for (variant, code) in PRE_V8_CODES.into_iter().chain(V8_CODES) {
        assert!(
            all.contains(&(variant, code)),
            "{variant} has code {code}: {all:?}"
        );
    }
    // Each new code belongs to exactly its one variant, and none is internal.
    for (variant, code) in V8_CODES {
        let owners: Vec<&str> = all
            .iter()
            .filter(|(_, c)| *c == code)
            .map(|(v, _)| *v)
            .collect();
        assert_eq!(owners, [variant], "the variants with code {code}");
        assert!(
            !internal_samples()
                .iter()
                .any(|e| variant_name(e) == variant),
            "{variant} is not internal"
        );
    }
}
