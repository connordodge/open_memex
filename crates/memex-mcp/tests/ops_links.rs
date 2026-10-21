//! WI #73 (R1): the link ops in `memex_mcp::ops::links` (D2), called directly
//! on temp vaults.
//!
//! - AC 2: `add_link` and `update_link` return their typed structs;
//!   `add_link` is idempotent (`was_existing`, the existing `link_id`, the
//!   source's `note_version`).
//! - AC 6 (op side): a bad kind is `invalid_argument`, as the CLI prints it.
//! - AC 8: `add_link` reindexes the source with the passed embedder.
//! - AC 9: op `add_link` from a daily note succeeds where MCP `add_link`
//!   returns `marker_rule`.

use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;

use memex_core::embedder::FakeEmbedder;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{indexer, Caller, SystemClock, Vault};
use memex_mcp::cli;
use memex_mcp::ops::links::{self as ops, AddLinkInput, UpdateLinkInput};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains.
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

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

    /// `(id, link_kind, label, source)` of every link from `from` to `to`.
    fn links(&self, from: &str, to: &str) -> Vec<(String, String, Option<String>, String)> {
        let conn = self.vault.connection_ref();
        let mut stmt = conn
            .prepare(
                "SELECT id, link_kind, label, source FROM links
                 WHERE from_note_id = ? AND to_note_id = ? ORDER BY position",
            )
            .unwrap();
        stmt.query_map(params![from, to], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
    }

    fn count(&self, sql: &str, id: &str) -> i64 {
        self.vault
            .connection_ref()
            .query_row(sql, params![id], |r| r.get(0))
            .unwrap_or(0)
    }

    /// `(chunks, chunks embedded by FakeEmbedder, chunk_vec rows)` for a note.
    fn vector_counts(&self, id: &str) -> (i64, i64, i64) {
        (
            self.count("SELECT COUNT(*) FROM chunks WHERE note_id = ?", id),
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

fn link(from: &str, to: &str, kind: &str, label: Option<&str>) -> AddLinkInput {
    AddLinkInput {
        from: from.into(),
        to: to.into(),
        kind: kind.into(),
        label: label.map(str::to_string),
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

fn keys(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
    k.sort();
    k
}

// ---------- AC 2: add_link ----------

#[test]
fn ops_add_link_writes_the_link_and_returns_its_row() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let out = ops::add_link(
        &mut f.vault,
        link(&a, &b, "extends", None),
        &SystemClock,
        None,
    )
    .unwrap();
    let rows = f.links(&a, &b);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(out.link_id.as_deref(), Some(rows[0].0.as_str()));
    assert_eq!(rows[0].1, "extends");
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.from, a);
    assert_eq!(out.to, b);
    assert_eq!(out.kind, "extends");
    assert_eq!(out.source, "frontmatter");
    assert!(!out.was_existing);
    assert_eq!(out.note_version, 2);
    assert_eq!(f.stored(&a).version, 2);
    assert!(f.stored(&a).content_md.contains("Beta"));
    assert_eq!(f.stored(&b).version, 1, "the target is untouched");
}

#[test]
fn ops_add_link_of_kind_references_is_auto_added_into_the_body() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let out = ops::add_link(
        &mut f.vault,
        link(&a, &b, "references", None),
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.kind, "references");
    assert_eq!(out.source, "auto_added");
    assert!(f.stored(&a).content_md.contains("[[Beta]]"));
    let rows = f.links(&a, &b);
    assert_eq!(out.link_id.as_deref(), Some(rows[0].0.as_str()));
}

#[test]
fn ops_add_link_label_becomes_the_wikilink_alias() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    ops::add_link(
        &mut f.vault,
        link(&a, &b, "references", Some("more")),
        &SystemClock,
        None,
    )
    .unwrap();
    assert!(
        f.stored(&a).content_md.contains("[[Beta|more]]"),
        "{}",
        f.stored(&a).content_md
    );
    assert_eq!(f.links(&a, &b)[0].2.as_deref(), Some("more"));
}

#[test]
fn ops_add_link_twice_is_idempotent_with_was_existing() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let first = ops::add_link(
        &mut f.vault,
        link(&a, &b, "extends", None),
        &SystemClock,
        None,
    )
    .unwrap();
    let body = f.stored(&a).content_md;
    let again = ops::add_link(
        &mut f.vault,
        link(&a, &b, "extends", None),
        &SystemClock,
        None,
    )
    .unwrap();
    assert!(again.was_existing);
    assert_eq!(again.link_id, first.link_id, "the existing link's id");
    assert_eq!(again.note_version, first.note_version);
    assert_eq!(again.source, "frontmatter");
    assert_eq!(f.stored(&a).version, 2, "nothing written");
    assert_eq!(f.stored(&a).content_md, body);
    assert_eq!(f.links(&a, &b).len(), 1);
}

#[test]
fn ops_add_link_existing_references_link_reports_auto_added() {
    let mut f = Fx::new();
    let b = f.note("Beta", "Beta body.\n", None);
    let a = f.note("Alpha", "See [[Beta]].\n", None);
    let out = ops::add_link(
        &mut f.vault,
        link(&a, &b, "references", None),
        &SystemClock,
        None,
    )
    .unwrap();
    assert!(out.was_existing);
    assert_eq!(out.source, "auto_added");
    assert_eq!(out.note_version, 1);
    assert_eq!(out.link_id.as_deref(), Some(f.links(&a, &b)[0].0.as_str()));
}

#[test]
fn ops_add_link_output_has_the_cli_add_link_fields() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let c = f.note("Gamma", "Gamma body.\n", None);
    let out = ops::add_link(
        &mut f.vault,
        link(&a, &b, "extends", None),
        &SystemClock,
        None,
    )
    .unwrap();
    let cli_out = cli_json(&[
        "add-link",
        "--vault",
        f.v(),
        "--from",
        &c,
        "--to",
        &b,
        "--kind",
        "extends",
    ]);
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(keys(&v), keys(&cli_out));
    for k in [
        "vault_id",
        "to",
        "kind",
        "source",
        "was_existing",
        "note_version",
    ] {
        assert_eq!(v[k], cli_out[k], "{k}");
    }
}

#[test]
fn ops_add_link_with_an_invalid_kind_is_invalid_argument() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let err = ops::add_link(
        &mut f.vault,
        link(&a, &b, "9bad!", None),
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(
        got,
        json!({ "error": { "code": "invalid_argument", "message": "invalid --kind: invalid link kind: 9bad!" } })
    );
    assert_eq!(
        got,
        cli_err(&[
            "add-link",
            "--vault",
            f.v(),
            "--from",
            &a,
            "--to",
            &b,
            "--kind",
            "9bad!"
        ])
    );
    assert_eq!(f.stored(&a).version, 1);
}

#[test]
fn ops_add_link_to_an_unknown_note_is_not_found() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let err = ops::add_link(
        &mut f.vault,
        link(&a, ABSENT_ULID, "references", None),
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "not_found", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "add-link",
            "--vault",
            f.v(),
            "--from",
            &a,
            "--to",
            ABSENT_ULID
        ])
    );
}

// ---------- AC 8: the embedder ----------

#[test]
fn ops_add_link_with_a_fake_embedder_stores_vectors_for_the_source() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body words.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let emb = FakeEmbedder::new(8);
    ops::add_link(
        &mut f.vault,
        link(&a, &b, "references", None),
        &SystemClock,
        Some(&emb),
    )
    .unwrap();
    let (chunks, embedded, vecs) = f.vector_counts(&a);
    assert!(chunks > 0);
    assert_eq!((embedded, vecs), (chunks, chunks));
}

#[test]
fn ops_add_link_without_an_embedder_indexes_text_only() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body words.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    ops::add_link(
        &mut f.vault,
        link(&a, &b, "references", None),
        &SystemClock,
        None,
    )
    .unwrap();
    let (chunks, embedded, vecs) = f.vector_counts(&a);
    assert!(chunks > 0);
    assert_eq!((embedded, vecs), (0, 0));
    let fts: String = f
        .vault
        .connection_ref()
        .query_row(
            "SELECT group_concat(content, ' ') FROM chunk_fts WHERE note_id = ?",
            params![a],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        fts.contains("[[Beta]]"),
        "reindexed from the new body: {fts}"
    );
}

// ---------- AC 9: person semantics ----------

#[tokio::test]
async fn ops_add_link_from_a_daily_note_succeeds_where_mcp_returns_marker_rule() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    let (day, topic) = {
        let mut v = state.vault.lock().await;
        (
            create(&mut v, "2026-09-05", "Fixed the jump arc.\n", Some("daily")),
            create(&mut v, "Player Loop", "About.\n", Some("topic")),
        )
    };

    let args = json!({ "from_id": day, "to_id": topic });
    let resp = memex
        .add_link(Parameters(serde_json::from_value(args).unwrap()))
        .await;
    let resp: Value = serde_json::from_str(&resp).unwrap();
    assert_eq!(
        resp["error"]["code"], "marker_rule",
        "MCP is the agent: {resp}"
    );

    let mut v = state.vault.lock().await;
    let out = ops::add_link(
        &mut v,
        link(&day, &topic, "references", None),
        &SystemClock,
        None,
    )
    .expect("the person may link from a daily note");
    assert!(!out.was_existing);
    assert_eq!(out.from, day);
    let stored = notes::get_note(&v, &NoteId::parse(&day).unwrap()).unwrap();
    assert!(
        stored.content_md.contains("[[Player Loop]]"),
        "{}",
        stored.content_md
    );
}

// ---------- AC 2: update_link ----------

#[test]
fn ops_update_link_sets_the_label_and_returns_the_link() {
    let mut f = Fx::new();
    let b = f.note("Beta", "Beta body.\n", None);
    let a = f.note("Alpha", "See [[Beta]].\n", None);
    let id = f.links(&a, &b)[0].0.clone();
    let out = ops::update_link(
        &mut f.vault,
        UpdateLinkInput {
            link_id: id.clone(),
            label: Some("named".into()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.vault_id, f.vault.vault_id());
    assert_eq!(out.from_note_id, a);
    assert_eq!(out.to_note_id.as_deref(), Some(b.as_str()));
    assert_eq!(out.kind, "references");
    assert_eq!(out.label.as_deref(), Some("named"));
    assert_eq!(out.source, "inline_body");
    assert_eq!(f.stored(&a).content_md, "See [[Beta|named]].\n");
    let rows = f.links(&a, &b);
    assert_eq!(out.link_id, rows[0].0);
}

#[test]
fn ops_update_link_changes_the_kind_and_clears_the_label() {
    let mut f = Fx::new();
    let b = f.note("Beta", "Beta body.\n", None);
    let a = f.note("Alpha", "See [[Beta|old]].\n", None);
    let id = f.links(&a, &b)[0].0.clone();
    let out = ops::update_link(
        &mut f.vault,
        UpdateLinkInput {
            link_id: id,
            kind: Some("contradicts".into()),
            label: Some("ignored".into()),
            clear_label: true,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(out.kind, "contradicts");
    assert_eq!(out.label, None, "clear_label overrides label");
    assert_eq!(f.stored(&a).content_md, "See [[Beta~contradicts]].\n");
    let rows = f.links(&a, &b);
    assert_eq!(rows[0].1, "contradicts");
    assert_eq!(out.link_id, rows[0].0);
    assert_eq!(out.position, 4);
}

#[test]
fn ops_update_link_output_equals_the_cli_update_link_json() {
    let mut f = Fx::new();
    let b = f.note("Beta", "Beta body.\n", None);
    let a = f.note("Alpha", "See [[Beta]].\n", None);
    let c = f.note("Gamma", "See [[Beta]].\n", None);
    let id_a = f.links(&a, &b)[0].0.clone();
    let id_c = f.links(&c, &b)[0].0.clone();
    let out = ops::update_link(
        &mut f.vault,
        UpdateLinkInput {
            link_id: id_a,
            kind: Some("extends".into()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap();
    let cli_out = cli_json(&[
        "update-link",
        "--vault",
        f.v(),
        "--link-id",
        &id_c,
        "--kind",
        "extends",
    ]);
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(keys(&v), keys(&cli_out));
    for k in [
        "kind",
        "label",
        "position",
        "source",
        "to_note_id",
        "vault_id",
    ] {
        assert_eq!(v[k], cli_out[k], "{k}");
    }
}

#[test]
fn ops_update_link_with_an_invalid_kind_is_invalid_argument() {
    let mut f = Fx::new();
    let b = f.note("Beta", "Beta body.\n", None);
    let a = f.note("Alpha", "See [[Beta]].\n", None);
    let id = f.links(&a, &b)[0].0.clone();
    let err = ops::update_link(
        &mut f.vault,
        UpdateLinkInput {
            link_id: id.clone(),
            kind: Some("9bad!".into()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "invalid_argument", "{got}");
    assert_eq!(
        got,
        cli_err(&[
            "update-link",
            "--vault",
            f.v(),
            "--link-id",
            &id,
            "--kind",
            "9bad!"
        ])
    );
    assert_eq!(f.stored(&a).version, 1);
}

#[test]
fn ops_update_link_unknown_link_maps_like_the_cli() {
    let mut f = Fx::new();
    let err = ops::update_link(
        &mut f.vault,
        UpdateLinkInput {
            link_id: ABSENT_ULID.into(),
            label: Some("x".into()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    assert_eq!(
        cli::error_json(&err),
        cli_err(&[
            "update-link",
            "--vault",
            f.v(),
            "--link-id",
            ABSENT_ULID,
            "--label",
            "x"
        ])
    );
}

// ---------- WI #142 (X3): server-written kinds are not user-writable ----------

/// Kinds written only by the server (block transclusion, a daily note's
/// footer), in the spellings that normalise to them.
const WI142_SERVER_KINDS: [&str; 5] = ["from-day", "about", "From Day", "ABOUT", "About"];

/// `(id, link_kind, label, source, to_note_id)` of every link from `from`.
type Wi142Row = (String, String, Option<String>, String, Option<String>);

fn wi142_rows(vault: &Vault, from: &str) -> Vec<Wi142Row> {
    let mut stmt = vault
        .connection_ref()
        .prepare(
            "SELECT id, link_kind, label, source, to_note_id FROM links
             WHERE from_note_id = ? ORDER BY position, id",
        )
        .unwrap();
    stmt.query_map(params![from], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// `(content_md, version, link rows)` of a note.
fn wi142_state(vault: &Vault, id: &str) -> (String, i64, Vec<Wi142Row>) {
    let n = notes::get_note(vault, &NoteId::parse(id).unwrap()).unwrap();
    (n.content_md, n.version, wi142_rows(vault, id))
}

fn wi142_mcp_fixture() -> (TempDir, Arc<AppState>, Memex) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path, None));
    let memex = Memex::new(state.clone());
    (dir, state, memex)
}

async fn wi142_mcp(resp: impl std::future::Future<Output = String>) -> Value {
    let resp = resp.await;
    serde_json::from_str(&resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
}

#[test]
fn ops_parse_kind_rejects_server_written_kinds_as_invalid_argument() {
    for kind in WI142_SERVER_KINDS {
        let err = ops::parse_kind(kind).unwrap_err();
        let got = cli::error_json(&err);
        assert_eq!(got["error"]["code"], "invalid_argument", "{kind}: {got}");
        assert!(
            got["error"]["message"]
                .as_str()
                .unwrap()
                .starts_with("invalid --kind: "),
            "{kind}: {got}"
        );
    }
}

#[test]
fn ops_parse_kind_still_normalises_and_accepts_every_other_kind() {
    for (given, stored) in [
        ("references", "references"),
        ("extends", "extends"),
        ("EXTENDS", "extends"),
        ("contradicts", "contradicts"),
        ("example-of", "example-of"),
        ("Has Space", "has-space"),
        ("inspired-by", "inspired-by"),
    ] {
        assert_eq!(ops::parse_kind(given).unwrap().as_str(), stored, "{given}");
    }
}

#[test]
fn ops_update_link_with_a_server_written_kind_is_invalid_argument_and_changes_nothing() {
    let mut f = Fx::new();
    let b = f.note("Beta", "Beta body.\n", None);
    let a = f.note("Alpha", "See [[Beta]].\n", None);
    let id = f.links(&a, &b)[0].0.clone();
    let before = wi142_state(&f.vault, &a);
    for kind in WI142_SERVER_KINDS {
        let err = ops::update_link(
            &mut f.vault,
            UpdateLinkInput {
                link_id: id.clone(),
                kind: Some(kind.into()),
                ..Default::default()
            },
            &SystemClock,
            None,
        )
        .unwrap_err();
        let got = cli::error_json(&err);
        assert_eq!(got["error"]["code"], "invalid_argument", "{kind}: {got}");
        assert_eq!(
            got,
            cli_err(&[
                "update-link",
                "--vault",
                f.v(),
                "--link-id",
                &id,
                "--kind",
                kind
            ]),
            "{kind}: the op and the CLI print the same error"
        );
        assert_eq!(wi142_state(&f.vault, &a), before, "{kind}: unchanged");
    }
}

#[test]
fn ops_add_link_with_a_server_written_kind_is_invalid_argument_and_changes_nothing() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let before = wi142_state(&f.vault, &a);
    for kind in WI142_SERVER_KINDS {
        let err =
            ops::add_link(&mut f.vault, link(&a, &b, kind, None), &SystemClock, None).unwrap_err();
        let got = cli::error_json(&err);
        assert_eq!(got["error"]["code"], "invalid_argument", "{kind}: {got}");
        assert_eq!(wi142_state(&f.vault, &a), before, "{kind}: unchanged");
    }
}

#[test]
fn ops_update_link_kind_change_on_a_frontmatter_link_is_invalid_argument_and_changes_nothing() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n", None);
    let b = f.note("Beta", "Beta body.\n", None);
    let added = ops::add_link(
        &mut f.vault,
        link(&a, &b, "extends", None),
        &SystemClock,
        None,
    )
    .unwrap();
    let id = added.link_id.expect("link_id");
    let before = wi142_state(&f.vault, &a);
    assert_eq!(before.2.len(), 1, "fixture: one link {:?}", before.2);
    assert_eq!(before.2[0].3, "frontmatter", "fixture: a frontmatter link");
    let err = ops::update_link(
        &mut f.vault,
        UpdateLinkInput {
            link_id: id.clone(),
            kind: Some("contradicts".into()),
            ..Default::default()
        },
        &SystemClock,
        None,
    )
    .unwrap_err();
    let got = cli::error_json(&err);
    assert_eq!(got["error"]["code"], "invalid_argument", "{got}");
    assert!(
        got["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("invalid link kind: frontmatter link kind cannot be changed"),
        "the core message is kept behind the invalid link kind prefix: {got}"
    );
    assert_eq!(wi142_state(&f.vault, &a), before, "unchanged");
}

#[tokio::test]
async fn mcp_add_link_and_update_link_reject_server_written_kinds_and_change_nothing() {
    let (_dir, state, memex) = wi142_mcp_fixture();
    let (a, b, link_id) = {
        let mut v = state.vault.lock().await;
        let b = create(&mut v, "Beta", "Beta body.\n", None);
        let a = create(&mut v, "Alpha", "See [[Beta]].\n", None);
        let id = wi142_rows(&v, &a)[0].0.clone();
        (a, b, id)
    };
    let before = {
        let v = state.vault.lock().await;
        wi142_state(&v, &a)
    };
    for kind in WI142_SERVER_KINDS {
        let resp = wi142_mcp(memex.add_link(Parameters(
            serde_json::from_value(json!({ "from_id": a, "to_id": b, "kind": kind })).unwrap(),
        )))
        .await;
        assert_eq!(
            resp["error"]["code"], "add_link.invalid_kind",
            "add_link {kind}: an error payload, not success: {resp}"
        );
        let resp = wi142_mcp(memex.update_link(Parameters(
            serde_json::from_value(json!({ "link_id": link_id, "kind": kind })).unwrap(),
        )))
        .await;
        assert_eq!(
            resp["error"]["code"], "update_link.invalid_kind",
            "update_link {kind}: an error payload, not success: {resp}"
        );
        let v = state.vault.lock().await;
        assert_eq!(wi142_state(&v, &a), before, "{kind}: vault unchanged");
    }
}

#[tokio::test]
async fn mcp_add_link_and_update_link_still_accept_the_cli_kinds() {
    let (_dir, state, memex) = wi142_mcp_fixture();
    let (a, b, c, mut link_id) = {
        let mut v = state.vault.lock().await;
        let b = create(&mut v, "Beta", "Beta body.\n", None);
        let c = create(&mut v, "Gamma", "Gamma body.\n", None);
        let a = create(&mut v, "Alpha", "See [[Beta]].\n", None);
        let id = wi142_rows(&v, &a)[0].0.clone();
        (a, b, c, id)
    };
    for (given, stored) in [
        ("contradicts", "contradicts"),
        ("EXTENDS", "extends"),
        ("Has Space", "has-space"),
        ("example-of", "example-of"),
    ] {
        let resp = wi142_mcp(memex.update_link(Parameters(
            serde_json::from_value(json!({ "link_id": link_id, "kind": given })).unwrap(),
        )))
        .await;
        assert!(resp.get("error").is_none(), "update_link {given}: {resp}");
        let v = state.vault.lock().await;
        assert_eq!(wi142_rows(&v, &a)[0].1, stored, "update_link {given}");
        // A rewrite re-extracts the note's links: the row has a new id.
        link_id = wi142_rows(&v, &a)[0].0.clone();
    }
    for (to, given, stored) in [(&b, "EXTENDS", "extends"), (&c, "Has Space", "has-space")] {
        let resp = wi142_mcp(memex.add_link(Parameters(
            serde_json::from_value(json!({ "from_id": a, "to_id": to, "kind": given })).unwrap(),
        )))
        .await;
        assert!(resp.get("error").is_none(), "add_link {given}: {resp}");
        let v = state.vault.lock().await;
        assert!(
            wi142_rows(&v, &a).iter().any(|r| r.1 == stored),
            "add_link {given}"
        );
    }
}

#[tokio::test]
async fn mcp_neighbors_kind_filter_still_accepts_server_written_kinds() {
    let (_dir, state, memex) = wi142_mcp_fixture();
    let a = {
        let mut v = state.vault.lock().await;
        create(&mut v, "Alpha", "Alpha body.\n", None)
    };
    for kind in ["about", "from-day"] {
        let resp = wi142_mcp(memex.neighbors(Parameters(
            serde_json::from_value(json!({ "note_id": a, "kind": kind })).unwrap(),
        )))
        .await;
        assert!(resp.get("error").is_none(), "neighbors {kind}: {resp}");
        assert_eq!(resp["results"], json!([]), "{kind}");
    }
}
