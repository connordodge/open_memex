//! WI #73 (R1): the area ops `memex_mcp::ops::{excerpt, folder, footer,
//! settings, prompt}` (D2), called directly on temp vaults.
//!
//! - AC 4: excerpt rm, folder ls/new/update/rm/add/remove, footer add,
//!   settings get/set and prompt return typed structs equal to what the CLI
//!   prints (prompt returns its text).
//! - AC 7: folder new and update are stamped with the passed clock.
//! - AC 9: op folder update renames a folder the person pinned, where MCP
//!   `update_smart_folder` returns `pinned_rule`.

use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;

use memex_core::footer::{self as core_footer, ChipOrigin};
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::smart_folders as sf;
use memex_core::{excerpts, indexer, Caller, Clock, SystemClock, Vault};
use memex_mcp::cli;
use memex_mcp::ops::{excerpt, folder, footer, prompt, settings};
use memex_mcp::prompts::{CAPTURE, REVIEW_DAILY_NOTES};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains.
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

const T0: i64 = 1_000_000_000_000;
const T1: i64 = 1_000_000_123_456;

const DAY: &str = "2026-09-05";

struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

struct Fx {
    _dir: TempDir,
    path: PathBuf,
    vault: Vault,
}

impl Fx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let vault = Vault::create(&path).unwrap();
        Fx {
            _dir: dir,
            path,
            vault,
        }
    }

    fn v(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn note(&mut self, title: &str, body: &str, role: Option<&str>) -> String {
        create(&mut self.vault, title, body, role)
    }

    fn stored(&self, id: &str) -> notes::Note {
        notes::get_note(&self.vault, &NoteId::parse(id).unwrap()).unwrap()
    }

    /// The fixture day (`b7k2m9`, `c3d4e5`) and a topic holding an excerpt
    /// of `b7k2m9` from it.
    fn day_with_excerpt(&mut self) -> (String, String) {
        let day = self.note(DAY, "Fixed it.\n\nSlept.\n", Some("daily"));
        for (ord, id) in ["b7k2m9", "c3d4e5"].iter().enumerate() {
            self.vault
                .connection_ref()
                .execute(
                    "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                    params![id, day, ord as i64],
                )
                .unwrap();
        }
        let topic = self.note("Player Loop", "About.\n", Some("topic"));
        excerpts::add_excerpt(
            &mut self.vault,
            &NoteId::parse(&topic).unwrap(),
            DAY,
            &["b7k2m9".to_string()],
            Caller::Agent,
            None,
        )
        .unwrap();
        (day, topic)
    }

    fn folder_row(&self, id: &str) -> (String, Option<String>, bool, i64, i64) {
        self.vault
            .connection_ref()
            .query_row(
                "SELECT name, parent_id, pinned, created_at, updated_at FROM smart_folders WHERE id = ?",
                [id],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get::<_, i64>(2)? != 0,
                        r.get(3)?,
                        r.get(4)?,
                    ))
                },
            )
            .unwrap()
    }
}

fn create(vault: &mut Vault, title: &str, body: &str, role: Option<&str>) -> String {
    let note = notes::create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: role.map(|r| json!({ "role": r })),
        },
        Caller::Person,
    )
    .unwrap();
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note.id.to_string()
}

fn cli(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn cli_json(args: &[&str]) -> Value {
    let out = cli(args);
    assert!(
        out.status.success(),
        "memex {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("stdout JSON")
}

fn cli_err(args: &[&str]) -> Value {
    let out = cli(args);
    assert_eq!(out.status.code(), Some(1), "memex {args:?}");
    serde_json::from_slice(&out.stderr).expect("stderr JSON")
}

fn to_value<T: serde::Serialize>(t: &T) -> Value {
    serde_json::to_value(t).unwrap()
}

fn keys(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
    k.sort();
    k
}

// ---------- excerpt rm ----------

#[test]
fn ops_excerpt_rm_removes_the_transclusion_and_returns_the_topic_version() {
    let mut f = Fx::new();
    let (_day, topic) = f.day_with_excerpt();
    let before = f.stored(&topic);
    assert!(
        before.content_md.contains("b7k2m9"),
        "{}",
        before.content_md
    );
    let out = excerpt::rm(
        &mut f.vault,
        excerpt::RmInput {
            topic_note_id: topic.clone(),
            date: DAY.into(),
            block_ids: vec!["b7k2m9".into()],
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let after = f.stored(&topic);
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.topic_note_id, topic);
    assert_eq!(out.version, after.version);
    assert_eq!(out.version, before.version + 1);
    assert!(!after.content_md.contains("b7k2m9"), "{}", after.content_md);
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"topic_note_id\":\"{topic}\",\"version\":{}}}",
            f.vault.vault_id(),
            after.version
        )
    );
}

#[test]
fn ops_excerpt_rm_with_a_blank_block_id_is_invalid_argument() {
    let mut f = Fx::new();
    let (_day, topic) = f.day_with_excerpt();
    let err = excerpt::rm(
        &mut f.vault,
        excerpt::RmInput {
            topic_note_id: topic.clone(),
            date: DAY.into(),
            block_ids: vec!["b7k2m9".into(), " ".into()],
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    assert_eq!(
        cli::error_json(&err),
        json!({ "error": { "code": "invalid_argument", "message": "--block-ids must list one or two non-empty block ids" } })
    );
    assert!(f.stored(&topic).content_md.contains("b7k2m9"));
}

#[test]
fn ops_excerpt_rm_of_a_missing_transclusion_maps_like_the_cli() {
    let mut f = Fx::new();
    let (_day, topic) = f.day_with_excerpt();
    let err = excerpt::rm(
        &mut f.vault,
        excerpt::RmInput {
            topic_note_id: topic.clone(),
            date: DAY.into(),
            block_ids: vec!["c3d4e5".into()],
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "not_found", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "excerpt",
            "rm",
            "--vault",
            f.v(),
            "--topic-note-id",
            &topic,
            "--date",
            DAY,
            "--block-ids",
            "c3d4e5"
        ])
    );
}

// ---------- footer add ----------

#[test]
fn ops_footer_add_records_a_person_chip_and_returns_the_daily_version() {
    let mut f = Fx::new();
    let day = f.note(DAY, "Day.\n", Some("daily"));
    let topic = f.note("Player Loop", "About.\n", Some("topic"));
    let out = footer::add(
        &mut f.vault,
        footer::AddInput {
            daily_note_id: day.clone(),
            topic_note_id: topic.clone(),
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let stored = f.stored(&day);
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.daily_note_id, day);
    assert_eq!(out.topic_note_id, topic);
    assert_eq!(out.origin, "person");
    assert_eq!(out.version, stored.version);
    assert_eq!(out.version, 2);
    assert!(
        stored.content_md.contains("[[Player Loop"),
        "{}",
        stored.content_md
    );
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"daily_note_id\":\"{day}\",\"topic_note_id\":\"{topic}\",\"origin\":\"person\",\"version\":2}}",
            f.vault.vault_id()
        )
    );

    // Idempotent: the same call writes nothing.
    let again = footer::add(
        &mut f.vault,
        footer::AddInput {
            daily_note_id: day.clone(),
            topic_note_id: topic.clone(),
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(again, out);
}

#[test]
fn ops_footer_add_upgrades_an_excerpt_chip_to_person() {
    let mut f = Fx::new();
    let day = f.note(DAY, "Day.\n", Some("daily"));
    let topic = f.note("Player Loop", "About.\n", Some("topic"));
    core_footer::set_chip(
        &mut f.vault,
        &NoteId::parse(&day).unwrap(),
        &NoteId::parse(&topic).unwrap(),
        ChipOrigin::Excerpt,
        None,
    )
    .unwrap();
    let out = footer::add(
        &mut f.vault,
        footer::AddInput {
            daily_note_id: day.clone(),
            topic_note_id: topic.clone(),
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.origin, "person");
}

#[test]
fn ops_footer_add_with_a_non_topic_maps_like_the_cli() {
    let mut f = Fx::new();
    let day = f.note(DAY, "Day.\n", Some("daily"));
    let plain = f.note("Plain", "p\n", None);
    let err = footer::add(
        &mut f.vault,
        footer::AddInput {
            daily_note_id: day.clone(),
            topic_note_id: plain.clone(),
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "role_rule", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "footer",
            "add",
            "--vault",
            f.v(),
            "--daily-note-id",
            &day,
            "--topic-note-id",
            &plain
        ])
    );
}

// ---------- folder ----------

#[test]
fn ops_folder_new_is_person_pinned_and_stamped_with_the_clock() {
    let mut f = Fx::new();
    let out = folder::new(
        &mut f.vault,
        folder::NewInput {
            name: "Games".into(),
            parent_id: None,
        },
        &FixedClock(T0),
        None,
    )
    .unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    let g = &out.body;
    assert_eq!(g.name, "Games");
    assert_eq!(g.parent_id, None);
    assert!(g.pinned, "a person folder is pinned");
    assert_eq!(g.depth, 1);
    assert_eq!((g.created_at, g.updated_at), (T0, T0));
    assert_eq!(f.folder_row(&g.id), ("Games".into(), None, true, T0, T0));

    let child = folder::new(
        &mut f.vault,
        folder::NewInput {
            name: "Platformers".into(),
            parent_id: Some(g.id.clone()),
        },
        &FixedClock(T1),
        None,
    )
    .unwrap();
    assert_eq!(child.body.depth, 2);
    assert_eq!(child.body.parent_id.as_deref(), Some(g.id.as_str()));
    assert_eq!(child.body.created_at, T1);

    let cli_out = cli_json(&["folder", "new", "--vault", f.v(), "--name", "Work"]);
    assert_eq!(keys(&to_value(&out)), keys(&cli_out));
    let line = serde_json::to_string(&out).unwrap();
    assert!(
        line.starts_with(&format!(
            "{{\"vault_id\":\"{}\",\"id\":",
            f.vault.vault_id()
        )),
        "vault_id first, then the folder: {line}"
    );
}

#[tokio::test]
async fn ops_folder_update_renames_a_person_pinned_folder_where_mcp_returns_pinned_rule() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    let games = {
        let mut v = state.vault.lock().await;
        sf::create_folder(&mut v, "Games", None, Caller::Person, &SystemClock)
            .unwrap()
            .id
    };

    let args = json!({ "id": games, "name": "Gaming" });
    let resp = memex
        .update_smart_folder(Parameters(serde_json::from_value(args).unwrap()))
        .await;
    let resp: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(
        resp["error"]["code"], "pinned_rule",
        "MCP is the agent: {resp}"
    );

    let mut v = state.vault.lock().await;
    let out = folder::update(
        &mut v,
        folder::UpdateInput {
            id: games.clone(),
            name: Some("Gaming".into()),
            ..Default::default()
        },
        &FixedClock(T1),
        None,
    )
    .expect("the person may rename a pinned folder");
    assert_eq!(out.body.id, games);
    assert_eq!(out.body.name, "Gaming");
    assert!(out.body.pinned);
    assert_eq!(out.body.updated_at, T1, "stamped with the clock");
    let listed = sf::list_folders(&v).unwrap();
    assert_eq!(listed.folders[0].folder.name, "Gaming");
}

#[test]
fn ops_folder_update_moves_to_root_and_unpins() {
    let mut f = Fx::new();
    let g = sf::create_folder(&mut f.vault, "Games", None, Caller::Person, &SystemClock)
        .unwrap()
        .id;
    let k = sf::create_folder(
        &mut f.vault,
        "Platformers",
        Some(&g),
        Caller::Person,
        &SystemClock,
    )
    .unwrap()
    .id;
    let out = folder::update(
        &mut f.vault,
        folder::UpdateInput {
            id: k.clone(),
            name: Some("Platform Games".into()),
            parent_id: Some(g.clone()),
            to_root: true,
            pinned: Some(false),
        },
        &FixedClock(T1),
        None,
    )
    .unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.body.parent_id, None, "to_root wins");
    assert_eq!(out.body.depth, 1);
    assert!(!out.body.pinned);
    let row = f.folder_row(&k);
    assert_eq!(
        (row.0.as_str(), row.1, row.2, row.4),
        ("Platform Games", None, false, T1)
    );

    // A parent without to_root re-parents.
    let out = folder::update(
        &mut f.vault,
        folder::UpdateInput {
            id: k.clone(),
            parent_id: Some(g.clone()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.body.parent_id.as_deref(), Some(g.as_str()));
    assert_eq!(out.body.depth, 2);
}

#[test]
fn ops_folder_update_of_an_unknown_folder_maps_like_the_cli() {
    let mut f = Fx::new();
    let err = folder::update(
        &mut f.vault,
        folder::UpdateInput {
            id: ABSENT_ULID.into(),
            name: Some("X".into()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "not_found", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "folder",
            "update",
            "--vault",
            f.v(),
            "--id",
            ABSENT_ULID,
            "--name",
            "X"
        ])
    );
}

#[test]
fn ops_folder_rm_deletes_the_folder_and_returns_id_deleted() {
    let mut f = Fx::new();
    let g = sf::create_folder(&mut f.vault, "Games", None, Caller::Person, &SystemClock)
        .unwrap()
        .id;
    let out = folder::rm(
        &mut f.vault,
        folder::RmInput { id: g.clone() },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"id\":\"{g}\",\"deleted\":true}}",
            f.vault.vault_id()
        )
    );
    assert!(sf::list_folders(&f.vault).unwrap().folders.is_empty());
}

#[test]
fn ops_folder_add_returns_the_membership() {
    let mut f = Fx::new();
    let g = sf::create_folder(&mut f.vault, "Games", None, Caller::Person, &SystemClock)
        .unwrap()
        .id;
    let plain = f.note("Player Loop", "About.\n", None);
    let out = folder::add(
        &mut f.vault,
        folder::AddInput {
            id: g.clone(),
            note_id: plain.clone(),
            pinned: true,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.body.smart_folder_id, g);
    assert_eq!(out.body.note_id, plain);
    assert!(out.body.pinned);
    assert!(out.body.role_set, "a role-less note becomes a topic");
    assert_eq!(f.stored(&plain).frontmatter["role"], "topic");
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"smart_folder_id\":\"{g}\",\"note_id\":\"{plain}\",\"pinned\":true,\"role_set\":true}}",
            f.vault.vault_id()
        )
    );

    // The person may change the pin.
    let out = folder::add(
        &mut f.vault,
        folder::AddInput {
            id: g.clone(),
            note_id: plain.clone(),
            pinned: false,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert!(!out.body.pinned);
    assert!(!out.body.role_set);
}

#[test]
fn ops_folder_add_of_a_daily_note_maps_like_the_cli() {
    let mut f = Fx::new();
    let g = sf::create_folder(&mut f.vault, "Games", None, Caller::Person, &SystemClock)
        .unwrap()
        .id;
    let day = f.note(DAY, "Day.\n", Some("daily"));
    let err = folder::add(
        &mut f.vault,
        folder::AddInput {
            id: g.clone(),
            note_id: day.clone(),
            pinned: true,
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "role_rule", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "folder",
            "add",
            "--vault",
            f.v(),
            "--id",
            &g,
            "--note-id",
            &day
        ])
    );
}

#[test]
fn ops_folder_remove_returns_removed() {
    let mut f = Fx::new();
    let g = sf::create_folder(&mut f.vault, "Games", None, Caller::Person, &SystemClock)
        .unwrap()
        .id;
    let t = f.note("Player Loop", "About.\n", Some("topic"));
    sf::add_member(&mut f.vault, &g, &t, None, Caller::Person, None).unwrap();
    let out = folder::remove(
        &mut f.vault,
        folder::RemoveInput {
            id: g.clone(),
            note_id: t.clone(),
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"smart_folder_id\":\"{g}\",\"note_id\":\"{t}\",\"removed\":true}}",
            f.vault.vault_id()
        )
    );
    assert!(sf::list_folders(&f.vault).unwrap().folders[0]
        .members
        .is_empty());
}

#[test]
fn ops_folder_ls_equals_the_cli_json() {
    let mut f = Fx::new();
    let g = sf::create_folder(&mut f.vault, "Games", None, Caller::Person, &SystemClock)
        .unwrap()
        .id;
    let t = f.note("Player Loop", "About.\n", Some("topic"));
    f.note("Loose", "Unsorted.\n", None);
    sf::add_member(&mut f.vault, &g, &t, None, Caller::Person, None).unwrap();
    let out = folder::ls(&mut f.vault, folder::LsInput, &SystemClock, None).unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.body.folders.len(), 1);
    assert_eq!(out.body.folders[0].members[0].note_id, t);
    assert_eq!(out.body.unsorted.len(), 1);
    assert_eq!(out.body.max_depth, 2);
    assert_eq!(
        to_value(&out),
        cli_json(&["folder", "ls", "--vault", f.v()])
    );
}

// ---------- settings ----------

#[test]
fn ops_settings_get_and_set_return_the_c211_line() {
    let mut f = Fx::new();
    let key = "smart_folder_max_depth";
    let got = settings::get(
        &mut f.vault,
        settings::GetInput { key: key.into() },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(got.vault_id, f.vault.vault_id());
    assert_eq!(got.key, key);
    assert_eq!(got.value, 2);
    assert_eq!(
        serde_json::to_string(&got).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"key\":\"{key}\",\"value\":2}}",
            f.vault.vault_id()
        )
    );

    let set = settings::set(
        &mut f.vault,
        settings::SetInput {
            key: key.into(),
            value: "4".into(),
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(set.value, 4);
    assert_eq!(
        memex_core::vault_settings::get_setting(&f.vault, key).unwrap(),
        4
    );
    assert_eq!(
        to_value(&set),
        cli_json(&["settings", "get", "--vault", f.v(), "--key", key])
    );
}

#[test]
fn ops_settings_invalid_key_and_value_map_like_the_cli() {
    let mut f = Fx::new();
    let err = settings::set(
        &mut f.vault,
        settings::SetInput {
            key: "smart_folder_max_depth".into(),
            value: "-1".into(),
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "setting_invalid", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "settings",
            "set",
            "--vault",
            f.v(),
            "--key",
            "smart_folder_max_depth",
            "--value",
            "-1"
        ])
    );
    let err = settings::get(
        &mut f.vault,
        settings::GetInput { key: "nope".into() },
        &SystemClock,
        None,
    )
    .unwrap_err();
    assert_eq!(
        cli::error_json(&err),
        cli_err(&["settings", "get", "--vault", f.v(), "--key", "nope"])
    );
}

// ---------- prompt ----------

#[test]
fn ops_prompt_returns_each_prompt_text_byte_for_byte() {
    let review = prompt::get(prompt::PromptKind::Review).unwrap();
    assert_eq!(review.text, REVIEW_DAILY_NOTES);
    let capture = prompt::get(prompt::PromptKind::Capture).unwrap();
    assert_eq!(capture.text, CAPTURE);
    assert_ne!(review.text, capture.text);
    assert_eq!(cli(&["prompt", "review"]).stdout, review.text.as_bytes());
}

// ---------- hygiene ----------

#[test]
fn ops_ship_no_placeholder_bodies() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/ops");
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        let src = std::fs::read_to_string(&path).unwrap();
        for stub in ["not implemented yet", "todo!(", "unimplemented!("] {
            assert!(!src.contains(stub), "{} contains {stub:?}", path.display());
        }
    }
}
