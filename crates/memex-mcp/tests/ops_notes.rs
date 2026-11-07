//! WI #73 (R1): the note ops in `memex_mcp::ops::notes` (D2), called directly
//! on temp vaults.
//!
//! - AC 1: `add`, `update`, `get` and `rm` return typed structs carrying what
//!   the CLI prints today.
//! - AC 6 (op side): their failures map through `cli::error_json` to the same
//!   C1 object the CLI prints.
//! - AC 7: `add` reads the passed clock.
//! - AC 8: `add` and `update` index with the passed embedder.
//! - AC 9: a daily `add` adopts a role-less note titled with the date.

use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

use memex_core::embedder::{Embedder, FakeEmbedder};
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{daily, excerpts, indexer, tags, Caller, Clock, SystemClock, Vault};
use memex_mcp::cli::{self, Role};
use memex_mcp::ops::notes::{self as ops, AddInput, GetInput, RmInput, UpdateInput};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains.
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

/// 2001-09-09T01:46:40Z: far from today, so a fixed-clock date can't be
/// mistaken for the wall clock's.
const T0: i64 = 1_000_000_000_000;

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

    /// A note created through core on the person path and indexed.
    fn note(&mut self, title: &str, body: &str, role: Option<&str>) -> String {
        let note = notes::create_note_as(
            &mut self.vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: role.map(|r| json!({ "role": r })),
            },
            Caller::Person,
        )
        .unwrap();
        indexer::reindex_note(
            self.vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            None,
        )
        .unwrap();
        note.id.to_string()
    }

    fn stored(&self, id: &str) -> notes::Note {
        notes::get_note(&self.vault, &NoteId::parse(id).unwrap()).unwrap()
    }

    fn count(&self, sql: &str, id: &str) -> i64 {
        self.vault
            .connection_ref()
            .query_row(sql, params![id], |r| r.get(0))
            .unwrap_or(0)
    }

    /// `(chunks, chunk_fts rows, chunks embedded by FakeEmbedder, chunk_vec rows)`
    /// for one note.
    fn index_counts(&self, id: &str) -> (i64, i64, i64, i64) {
        (
            self.count("SELECT COUNT(*) FROM chunks WHERE note_id = ?", id),
            self.count("SELECT COUNT(*) FROM chunk_fts WHERE note_id = ?", id),
            self.count(
                "SELECT COUNT(*) FROM chunks WHERE note_id = ? AND embed_model_version = 'fake-v1'",
                id,
            ),
            self.count(
                "SELECT COUNT(*) FROM chunk_vec WHERE chunk_id IN (SELECT id FROM chunks WHERE note_id = ?)",
                id,
            ),
        )
    }
}

fn add(title: Option<&str>, body: &str) -> AddInput {
    AddInput {
        title: title.map(str::to_string),
        content_md: body.to_string(),
        ..Default::default()
    }
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

fn cli_with_stdin(args: &[&str], body: &str) -> Output {
    use std::io::Write;
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(body.as_bytes())
        .unwrap();
    child.wait_with_output().expect("wait")
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

fn c1(err: &anyhow::Error) -> Value {
    cli::error_json(err)
}

// ---------- AC 1: add ----------

#[test]
fn ops_add_returns_note_id_title_tags_and_created() {
    let mut f = Fx::new();
    let input = AddInput {
        title: Some("Alpha".into()),
        content_md: "Alpha body.\n".into(),
        tags: vec!["loop".into(), "games".into()],
        role: None,
    };
    let out = ops::add(&mut f.vault, input, &SystemClock, None).unwrap();
    assert_eq!(out.title, "Alpha");
    assert_eq!(out.tags, vec!["loop".to_string(), "games".to_string()]);
    assert!(!out.adopted, "a plain add creates");
    let stored = f.stored(&out.note_id);
    assert_eq!(stored.title, "Alpha");
    assert_eq!(
        stored.content_md, "Alpha body.\n<!-- memex:topics -->\n#games\n#loop\n",
        "non-system tags get their footer text in the same call (R40)"
    );
    assert_eq!(stored.frontmatter, json!({}));
    assert_eq!(
        tags::tags_for_note(&f.vault, &out.note_id).unwrap(),
        vec!["games".to_string(), "loop".to_string()]
    );
}

#[test]
fn ops_add_derives_the_title_from_the_first_line() {
    let mut f = Fx::new();
    let out = ops::add(
        &mut f.vault,
        add(None, "# First line wins\nmore\n"),
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.title, "First line wins");
    assert!(out.tags.is_empty());
    assert_eq!(f.stored(&out.note_id).title, "First line wins");
}

#[test]
fn ops_add_with_role_topic_stores_the_role() {
    let mut f = Fx::new();
    let input = AddInput {
        role: Some(Role::Topic),
        ..add(Some("Player Loop"), "Core loop.\n")
    };
    let out = ops::add(&mut f.vault, input, &SystemClock, None).unwrap();
    assert_eq!(
        f.stored(&out.note_id).frontmatter,
        json!({ "role": "topic" })
    );
}

#[test]
fn ops_add_daily_with_an_empty_body_creates_the_day() {
    let mut f = Fx::new();
    let input = AddInput {
        role: Some(Role::Daily),
        ..add(Some("2026-09-05"), "")
    };
    let out = ops::add(&mut f.vault, input, &SystemClock, None).unwrap();
    assert_eq!(out.title, "2026-09-05");
    assert!(!out.adopted);
    assert_eq!(f.stored(&out.note_id).frontmatter["role"], "daily");
}

#[test]
fn ops_add_output_serializes_the_fields_memex_add_prints() {
    let mut f = Fx::new();
    let input = AddInput {
        tags: vec!["games".into()],
        ..add(Some("Alpha"), "a\n")
    };
    let out = ops::add(&mut f.vault, input, &SystemClock, None).unwrap();
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        json!({
            "note_id": out.note_id,
            "title": "Alpha",
            "tags": ["games"],
            "adopted": false,
        })
    );
}

// ---------- AC 6 (op side): add errors ----------

#[test]
fn ops_add_with_an_empty_body_and_no_daily_role_is_invalid_argument() {
    let mut f = Fx::new();
    for body in ["", "  \n\t"] {
        let err = ops::add(&mut f.vault, add(Some("Empty"), body), &SystemClock, None).unwrap_err();
        assert_eq!(
            c1(&err),
            json!({ "error": { "code": "invalid_argument", "message": "stdin was empty — nothing to add" } }),
            "body {body:?}"
        );
    }
    assert_eq!(notes::list_notes(&f.vault, 10).unwrap().len(), 0);
}

#[test]
fn ops_add_with_a_taken_title_is_title_conflict_naming_the_existing_note() {
    let mut f = Fx::new();
    let beta = f.note("Beta", "b\n", None);
    let err = ops::add(
        &mut f.vault,
        add(Some("Beta"), "again\n"),
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = c1(&err);
    assert_eq!(got["error"]["code"], "title_conflict", "{got}");
    assert_eq!(got["error"]["existing_id"], json!(beta));
    // The same object the CLI prints for the same request.
    let out = cli_with_stdin(&["add", "--vault", f.v(), "--title", "Beta"], "again\n");
    assert_eq!(out.status.code(), Some(1));
    let cli_got: Value = serde_json::from_slice(&out.stderr).unwrap();
    assert_eq!(got, cli_got);
}

#[test]
fn ops_add_daily_for_a_day_that_has_one_is_daily_note_exists() {
    let mut f = Fx::new();
    let day = f.note("2026-09-05", "Day.\n", Some("daily"));
    let input = AddInput {
        role: Some(Role::Daily),
        ..add(Some("2026-09-05"), "Again.\n")
    };
    let err = ops::add(&mut f.vault, input, &SystemClock, None).unwrap_err();
    let got = c1(&err);
    assert_eq!(got["error"]["code"], "daily_note_exists", "{got}");
    assert_eq!(got["error"]["existing_id"], json!(day));
    assert_eq!(got["error"]["date"], "2026-09-05");
}

#[test]
fn ops_add_daily_with_a_non_iso_title_is_invalid_date() {
    let mut f = Fx::new();
    let input = AddInput {
        role: Some(Role::Daily),
        ..add(Some("Sept 5"), "x\n")
    };
    let err = ops::add(&mut f.vault, input, &SystemClock, None).unwrap_err();
    assert_eq!(c1(&err)["error"]["code"], "invalid_date");
}

// ---------- AC 7: the clock ----------

#[test]
fn ops_add_daily_without_a_title_uses_the_clock_date() {
    let mut f = Fx::new();
    let clock = FixedClock(T0);
    let input = AddInput {
        role: Some(Role::Daily),
        ..add(None, "Morning.\n")
    };
    let out = ops::add(&mut f.vault, input, &clock, None).unwrap();
    let want = daily::today_with_clock(&clock).to_string();
    assert!(want.starts_with("2001-09-0"), "{want}");
    assert_ne!(want, daily::today_with_clock(&SystemClock).to_string());
    assert_eq!(out.title, want);
    let stored = f.stored(&out.note_id);
    assert_eq!(stored.title, want);
    assert_eq!(
        stored.created_at, T0,
        "the daily create is stamped by the clock"
    );
}

#[test]
fn ops_add_stamps_created_at_with_the_clock() {
    let mut f = Fx::new();
    let out = ops::add(
        &mut f.vault,
        add(Some("Alpha"), "a\n"),
        &FixedClock(T0),
        None,
    )
    .unwrap();
    let stored = f.stored(&out.note_id);
    assert_eq!(stored.created_at, T0);
    assert_eq!(stored.updated_at, T0);
}

// ---------- AC 8: the embedder ----------

#[test]
fn vector_probe_sees_vectors_core_reindex_writes() {
    // Control for the AC 8 tests: the probe counts what a FakeEmbedder writes.
    let mut f = Fx::new();
    let id = f.note("Alpha", "One two three.\n\nFour five six.\n", None);
    let note = f.stored(&id);
    let emb = FakeEmbedder::new(8);
    indexer::reindex_note(
        f.vault.connection_mut(),
        &id,
        &note.content_md,
        Some(&emb as &dyn Embedder),
    )
    .unwrap();
    let (chunks, fts, embedded, vecs) = f.index_counts(&id);
    assert!(chunks > 0);
    assert_eq!((fts, embedded, vecs), (chunks, chunks, chunks));
}

#[test]
fn ops_add_with_a_fake_embedder_stores_a_vector_per_chunk() {
    let mut f = Fx::new();
    let emb = FakeEmbedder::new(8);
    let out = ops::add(
        &mut f.vault,
        add(Some("Alpha"), "One two three.\n\nFour five six.\n"),
        &SystemClock,
        Some(&emb),
    )
    .unwrap();
    let (chunks, fts, embedded, vecs) = f.index_counts(&out.note_id);
    assert!(chunks > 0, "the note is chunked");
    assert_eq!((fts, embedded, vecs), (chunks, chunks, chunks));
}

#[test]
fn ops_add_without_an_embedder_indexes_text_only() {
    let mut f = Fx::new();
    let out = ops::add(
        &mut f.vault,
        add(Some("Alpha"), "One two three.\n"),
        &SystemClock,
        None,
    )
    .unwrap();
    let (chunks, fts, embedded, vecs) = f.index_counts(&out.note_id);
    assert!(chunks > 0, "the note is chunked");
    assert_eq!((fts, embedded, vecs), (chunks, 0, 0));
}

#[test]
fn ops_update_with_a_fake_embedder_stores_a_vector_per_chunk() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "old\n", None);
    let emb = FakeEmbedder::new(8);
    let input = UpdateInput {
        note_id: id.clone(),
        expected_version: 1,
        content_md: "New words here.\n\nAnd more.\n".into(),
        ..Default::default()
    };
    ops::update(&mut f.vault, input, &SystemClock, Some(&emb)).unwrap();
    let (chunks, fts, embedded, vecs) = f.index_counts(&id);
    assert!(chunks > 0);
    assert_eq!((fts, embedded, vecs), (chunks, chunks, chunks));
}

#[test]
fn ops_update_without_an_embedder_indexes_text_only() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "old\n", None);
    let input = UpdateInput {
        note_id: id.clone(),
        expected_version: 1,
        content_md: "Brand new text.\n".into(),
        ..Default::default()
    };
    ops::update(&mut f.vault, input, &SystemClock, None).unwrap();
    let (chunks, fts, embedded, vecs) = f.index_counts(&id);
    assert!(chunks > 0);
    assert_eq!((fts, embedded, vecs), (chunks, 0, 0));
    let fts_text: String = f
        .vault
        .connection_ref()
        .query_row(
            "SELECT group_concat(content, ' ') FROM chunk_fts WHERE note_id = ?",
            params![id],
            |r| r.get(0),
        )
        .unwrap();
    assert!(fts_text.contains("Brand new text"), "reindexed: {fts_text}");
}

// ---------- AC 9: daily adopt ----------

#[test]
fn ops_add_daily_adopts_a_role_less_note_titled_with_the_date() {
    let mut f = Fx::new();
    let plain = f.note("2026-09-06", "Before it was a day.\n", None);
    let input = AddInput {
        role: Some(Role::Daily),
        ..add(Some("2026-09-06"), "After.\n")
    };
    let out = ops::add(&mut f.vault, input, &SystemClock, None).unwrap();
    assert!(out.adopted, "the person path adopts (Adopted note)");
    assert_eq!(out.note_id, plain, "adopting keeps the id");
    assert_eq!(out.title, "2026-09-06");
    let stored = f.stored(&plain);
    assert_eq!(stored.frontmatter["role"], "daily");
    assert!(stored.content_md.contains("Before it was a day."));
    assert!(stored.content_md.contains("After."));
    assert_eq!(notes::list_notes(&f.vault, 10).unwrap().len(), 1);
}

// ---------- AC 1: update ----------

#[test]
fn ops_update_returns_note_id_version_and_updated_at() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "v1\n", None);
    let input = UpdateInput {
        note_id: id.clone(),
        expected_version: 1,
        content_md: "v2\n".into(),
        ..Default::default()
    };
    let out = ops::update(&mut f.vault, input, &SystemClock, None).unwrap();
    let stored = f.stored(&id);
    assert_eq!(out.note_id, id);
    assert_eq!(out.version, 2);
    assert_eq!(stored.version, 2);
    assert_eq!(out.updated_at, stored.updated_at);
    assert_eq!(stored.content_md, "v2\n");
    assert_eq!(stored.title, "Alpha", "no title keeps the title");
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        json!({ "note_id": id, "version": 2, "updated_at": stored.updated_at })
    );
}

#[test]
fn ops_update_with_a_title_renames_and_rewrites_linkers() {
    let mut f = Fx::new();
    let beta = f.note("Beta", "b\n", None);
    let alpha = f.note("Alpha", "See [[Beta]].\n", None);
    let input = UpdateInput {
        note_id: beta.clone(),
        expected_version: 1,
        title: Some("Beta Two".into()),
        content_md: "b\n".into(),
        no_rename_links: false,
    };
    ops::update(&mut f.vault, input, &SystemClock, None).unwrap();
    assert_eq!(f.stored(&beta).title, "Beta Two");
    assert_eq!(f.stored(&alpha).content_md, "See [[Beta Two]].\n");
}

#[test]
fn ops_update_with_no_rename_links_leaves_linkers_alone() {
    let mut f = Fx::new();
    let beta = f.note("Beta", "b\n", None);
    let alpha = f.note("Alpha", "See [[Beta]].\n", None);
    let input = UpdateInput {
        note_id: beta.clone(),
        expected_version: 1,
        title: Some("Beta Two".into()),
        content_md: "b\n".into(),
        no_rename_links: true,
    };
    ops::update(&mut f.vault, input, &SystemClock, None).unwrap();
    assert_eq!(f.stored(&beta).title, "Beta Two");
    assert_eq!(f.stored(&alpha).content_md, "See [[Beta]].\n");
    assert_eq!(f.stored(&alpha).version, 1);
}

#[test]
fn ops_update_with_a_stale_version_is_version_conflict() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "v1\n", None);
    let ok = UpdateInput {
        note_id: id.clone(),
        expected_version: 1,
        content_md: "v2\n".into(),
        ..Default::default()
    };
    ops::update(&mut f.vault, ok.clone(), &SystemClock, None).unwrap();
    let stale = UpdateInput {
        content_md: "v3\n".into(),
        ..ok
    };
    let err = ops::update(&mut f.vault, stale, &SystemClock, None).unwrap_err();
    let got = c1(&err);
    assert_eq!(got["error"]["code"], "version_conflict", "{got}");
    assert_eq!(got["error"]["expected"], 1);
    assert_eq!(got["error"]["current"], 2);
    assert_eq!(f.stored(&id).content_md, "v2\n", "nothing written");
}

#[test]
fn ops_update_unknown_and_malformed_ids_map_like_the_cli() {
    let mut f = Fx::new();
    for id in [ABSENT_ULID, "not-a-ulid"] {
        let input = UpdateInput {
            note_id: id.into(),
            expected_version: 1,
            content_md: "x\n".into(),
            ..Default::default()
        };
        let err = ops::update(&mut f.vault, input, &SystemClock, None).unwrap_err();
        let want = cli_err(&["get", "--vault", f.v(), "--note-id", id]);
        assert_eq!(c1(&err), want, "{id}");
    }
}

// ---------- AC 1: get ----------

#[test]
fn ops_get_returns_note_fields_and_tags() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "Alpha body.\n", Some("topic"));
    tags::add_tag(&f.vault, &id, "games").unwrap();
    let input = GetInput {
        note_id: id.clone(),
        include_links: false,
    };
    let out = ops::get(&mut f.vault, input, &SystemClock, None).unwrap();
    let stored = f.stored(&id);
    assert_eq!(out.note_id, id);
    assert_eq!(out.title, "Alpha");
    assert_eq!(out.content_md, "Alpha body.\n");
    assert_eq!(out.frontmatter, json!({ "role": "topic" }));
    assert_eq!(out.version, 1);
    assert_eq!(out.created_at, stored.created_at);
    assert_eq!(out.updated_at, stored.updated_at);
    assert_eq!(out.tags, vec!["games".to_string()]);
    let v = serde_json::to_value(&out).unwrap();
    assert!(
        v.get("links").is_none() && v.get("backlinks").is_none(),
        "{v}"
    );
    assert_eq!(v, cli_json(&["get", "--vault", f.v(), "--note-id", &id]));
}

#[test]
fn ops_get_with_include_links_returns_links_and_backlinks_by_kind() {
    let mut f = Fx::new();
    let beta = f.note("Beta", "b\n", None);
    let alpha = f.note("Alpha", "See [[Beta]] and [[Beta~extends|more]].\n", None);
    let out = ops::get(
        &mut f.vault,
        GetInput {
            note_id: alpha.clone(),
            include_links: true,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let links = out.links.as_ref().expect("links with include_links");
    let kinds: Vec<&String> = links.keys().collect();
    assert_eq!(kinds, ["extends", "references"]);
    assert_eq!(links["extends"][0]["to_note_id"], json!(beta));
    assert_eq!(links["extends"][0]["label"], "more");
    assert_eq!(out.backlinks.as_ref().map(|b| b.len()), Some(0));
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(
        v,
        cli_json(&[
            "get",
            "--vault",
            f.v(),
            "--note-id",
            &alpha,
            "--include-links"
        ])
    );

    let out = ops::get(
        &mut f.vault,
        GetInput {
            note_id: beta.clone(),
            include_links: true,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let back = out.backlinks.as_ref().expect("backlinks");
    assert_eq!(back["references"][0]["from_note_id"], json!(alpha));
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        cli_json(&[
            "get",
            "--vault",
            f.v(),
            "--note-id",
            &beta,
            "--include-links"
        ])
    );
}

#[test]
fn ops_get_of_a_daily_note_carries_the_review_fields() {
    let mut f = Fx::new();
    let day = f.note("2026-09-05", "Fixed the jump arc.\n", Some("daily"));
    let out = ops::get(
        &mut f.vault,
        GetInput {
            note_id: day.clone(),
            include_links: false,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(v["review"]["state"], "Unreviewed", "{v}");
    assert_eq!(v["review"]["content_version"], 1);
    assert_eq!(v["latest_change"], Value::Null);
    assert!(v.as_object().unwrap().contains_key("latest_change"));
    assert_eq!(v, cli_json(&["get", "--vault", f.v(), "--note-id", &day]));
}

#[test]
fn ops_get_of_a_topic_with_an_excerpt_carries_transclusions() {
    let mut f = Fx::new();
    let day = f.note("2026-09-05", "Fixed it.\n\nSlept.\n", Some("daily"));
    f.vault
        .connection_ref()
        .execute(
            "UPDATE blocks SET block_id = 'b7k2m9' WHERE note_id = ? AND ord = 0",
            params![day],
        )
        .unwrap();
    let topic = f.note("Player Loop", "About.\n", Some("topic"));
    excerpts::add_excerpt(
        &mut f.vault,
        &NoteId::parse(&topic).unwrap(),
        "2026-09-05",
        &["b7k2m9".to_string()],
        Caller::Agent,
        None,
    )
    .unwrap();
    let out = ops::get(
        &mut f.vault,
        GetInput {
            note_id: topic.clone(),
            include_links: false,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let v = serde_json::to_value(&out).unwrap();
    let t = &v["transclusions"][0];
    assert_eq!(t["date"], "2026-09-05", "{v}");
    assert_eq!(t["from"], "b7k2m9");
    assert!(t["text"].as_str().unwrap().contains("Fixed it"), "{v}");
    assert_eq!(v, cli_json(&["get", "--vault", f.v(), "--note-id", &topic]));
}

#[test]
fn ops_get_unknown_note_is_not_found() {
    let mut f = Fx::new();
    let err = ops::get(
        &mut f.vault,
        GetInput {
            note_id: ABSENT_ULID.into(),
            include_links: true,
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    assert_eq!(
        c1(&err),
        json!({ "error": { "code": "not_found", "message": format!("not found: note {ABSENT_ULID}") } })
    );
}

// ---------- AC 1: rm ----------

#[test]
fn ops_rm_deletes_the_note_and_returns_vault_id_note_id_deleted() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "a\n", None);
    let out = ops::rm(
        &mut f.vault,
        RmInput {
            note_id: id.clone(),
            expected_version: 1,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.note_id, id);
    assert!(out.deleted);
    assert!(notes::get_note(&f.vault, &NoteId::parse(&id).unwrap()).is_err());
    assert_eq!(f.index_counts(&id), (0, 0, 0, 0), "indexes purged");
    assert_eq!(
        serde_json::to_string(&out).unwrap(),
        format!(
            "{{\"vault_id\":\"{}\",\"note_id\":\"{id}\",\"deleted\":true}}",
            f.vault.vault_id()
        )
    );
}

#[test]
fn ops_rm_with_a_stale_version_is_version_conflict_and_keeps_the_note() {
    let mut f = Fx::new();
    let id = f.note("Alpha", "a\n", None);
    let err = ops::rm(
        &mut f.vault,
        RmInput {
            note_id: id.clone(),
            expected_version: 7,
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = c1(&err);
    assert_eq!(got["error"]["code"], "version_conflict", "{got}");
    assert_eq!(got["error"]["expected"], 7);
    assert_eq!(got["error"]["current"], 1);
    assert_eq!(f.stored(&id).title, "Alpha");
}
