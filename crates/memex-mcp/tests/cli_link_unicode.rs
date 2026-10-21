//! WI #145 (X4): frontmatter keeps non-ASCII text when extracting links.
//!
//! Real `memex` binary (`CARGO_BIN_EXE_memex`) on temp vaults, plus the MCP
//! tools on the same vault. Every save path shares the indexer, so a note
//! whose frontmatter holds non-ASCII text (Latin accents, CJK, emoji, 4-byte
//! chars) parses, resolves its frontmatter links to the right notes, and
//! stores the same `links` rows whether it was saved by `memex add`,
//! `memex update` or the MCP `create_note` tool.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;

use memex_core::Vault;
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------- subprocess helpers (as in cli_link_positions.rs) ----------

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args);
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("spawn memex");
    if let Some(body) = stdin_body {
        child
            .stdin
            .as_mut()
            .expect("stdin")
            .write_all(body.as_bytes())
            .expect("write stdin");
    }
    drop(child.stdin.take());
    child.wait_with_output().expect("wait")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?} stdout={} stderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn init_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_str().unwrap().to_string();
    let out = run(&["init", &path], None);
    assert!(out.status.success(), "init failed: {}", describe(&out));
    (dir, path)
}

fn add_note(vault: &str, title: &str, body: &str) -> String {
    let out = run(&["add", "--vault", vault, "--title", title], Some(body));
    assert_eq!(
        out.status.code(),
        Some(0),
        "add {title}: {}",
        describe(&out)
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8");
    regex::Regex::new(r"note_id:\s*([0-9A-Z]{26})")
        .unwrap()
        .captures(&stdout)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .unwrap_or_else(|| panic!("add {title}: no note_id in {stdout:?}"))
}

fn update_note(vault: &str, id: &str, body: &str) {
    let (_, version) = content_and_version(vault, id);
    let version = version.to_string();
    let out = run(
        &[
            "update",
            "--vault",
            vault,
            "--note-id",
            id,
            "--expected-version",
            &version,
        ],
        Some(body),
    );
    assert_eq!(out.status.code(), Some(0), "update: {}", describe(&out));
}

/// Exit 0 and exactly one stdout line that parses as JSON.
fn one_line_json(out: Output, what: &str) -> Value {
    assert_eq!(out.status.code(), Some(0), "{what}: {}", describe(&out));
    let stdout = String::from_utf8(out.stdout.clone()).expect("utf8");
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "{what}: stdout must be one JSON line; {}",
        describe(&out)
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("{what}: not JSON ({e}): {line}"))
}

// ---------- vault readers ----------

/// One `links` row, without its id.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Row {
    position: i64,
    link_text: String,
    kind: String,
    label: Option<String>,
    source: String,
    to_note_id: Option<String>,
}

fn content_and_version(vault: &str, id: &str) -> (String, i64) {
    let v = Vault::open(Path::new(vault)).unwrap();
    v.connection_ref()
        .query_row(
            "SELECT content_md, version FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

fn parse_error_flag(vault: &str, id: &str) -> i64 {
    let v = Vault::open(Path::new(vault)).unwrap();
    v.connection_ref()
        .query_row(
            "SELECT frontmatter_parse_error FROM notes WHERE id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

/// The note's links as `(id, row)`, by position.
fn link_rows(vault: &str, id: &str) -> Vec<(String, Row)> {
    let v = Vault::open(Path::new(vault)).unwrap();
    let conn = v.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, position, link_text, link_kind, label, source, to_note_id
             FROM links WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap();
    stmt.query_map([id], |r| {
        Ok((
            r.get(0)?,
            Row {
                position: r.get(1)?,
                link_text: r.get(2)?,
                kind: r.get(3)?,
                label: r.get(4)?,
                source: r.get(5)?,
                to_note_id: r.get(6)?,
            },
        ))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

fn rows(vault: &str, id: &str) -> Vec<Row> {
    link_rows(vault, id).into_iter().map(|(_, r)| r).collect()
}

fn row(at: i64, text: &str, kind: &str, label: Option<&str>, source: &str, to: &str) -> Row {
    Row {
        position: at,
        link_text: text.to_string(),
        kind: kind.to_string(),
        label: label.map(str::to_string),
        source: source.to_string(),
        to_note_id: Some(to.to_string()),
    }
}

// ---------- MCP helpers ----------

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
}

fn mcp_on(vault: &str) -> (Arc<AppState>, Memex) {
    let path = Path::new(vault).to_path_buf();
    let v = Vault::open(&path).unwrap();
    let state = Arc::new(AppState::new(v, path, None));
    let memex = Memex::new(state.clone());
    (state, memex)
}

// ---------- the note every save path stores ----------

/// Non-ASCII text in every frontmatter shape: a title value, a quoted value
/// under a non-ASCII key, a comment, bare and quoted tokens with non-ASCII
/// titles and labels, plus body links after it all.
const UNICODE_NOTE: &str = "---\n\
title: Ünïcødé – 日本語 😀 𠜎\n\
# été 🎉\n\
résumé: \"naïve façade\"\n\
extends:\n  - [[Alpha]]\n  - [[Café|Crème – brûlée]]\n\
contradicts: \"[[日本語]]\"\n\
example-of: '[[Café|ラベル 𝄞]]'\n\
---\n\
# Ünïcødé\n\n\
Body sees [[日本語|ラベル]] and [[Alpha]].\n";

#[tokio::test]
async fn memex_add_update_and_mcp_create_note_give_identical_non_ascii_link_rows() {
    let (_dir, v) = init_vault();
    let alpha = add_note(&v, "Alpha", "# Alpha\n");
    let cafe = add_note(&v, "Café", "# Café\n");
    let nihongo = add_note(&v, "日本語", "# 日本語\n");

    // `memex add` with the note as its body.
    let via_add = add_note(&v, "Src add", UNICODE_NOTE);
    // `memex add` of a placeholder, then `memex update` to the note.
    let via_update = add_note(&v, "Src update", "# placeholder\n");
    update_note(&v, &via_update, UNICODE_NOTE);
    // The MCP `create_note` tool on the same vault.
    let via_mcp = {
        let (state, memex) = mcp_on(&v);
        let resp = parse(
            &memex
                .create_note(params(
                    json!({ "title": "Src mcp", "content_md": UNICODE_NOTE }),
                ))
                .await,
        );
        assert!(resp.get("error").is_none(), "create_note: {resp}");
        let id = resp["note_id"].as_str().expect("note_id").to_string();
        drop(memex);
        drop(state);
        id
    };

    let at: Vec<i64> = UNICODE_NOTE
        .match_indices("[[")
        .map(|(i, _)| i as i64)
        .collect();
    let want = vec![
        row(at[0], "Alpha", "extends", None, "frontmatter", &alpha),
        row(
            at[1],
            "Café",
            "extends",
            Some("Crème – brûlée"),
            "frontmatter",
            &cafe,
        ),
        row(
            at[2],
            "日本語",
            "contradicts",
            None,
            "frontmatter",
            &nihongo,
        ),
        row(
            at[3],
            "Café",
            "example-of",
            Some("ラベル 𝄞"),
            "frontmatter",
            &cafe,
        ),
        row(
            at[4],
            "日本語",
            "references",
            Some("ラベル"),
            "inline_body",
            &nihongo,
        ),
        row(at[5], "Alpha", "references", None, "inline_body", &alpha),
    ];
    for (path, id) in [
        ("memex add", &via_add),
        ("memex update", &via_update),
        ("MCP create_note", &via_mcp),
    ] {
        let (content, _) = content_and_version(&v, id);
        assert_eq!(content, UNICODE_NOTE, "{path}: stored byte for byte");
        assert_eq!(
            parse_error_flag(&v, id),
            0,
            "{path}: non-ASCII frontmatter must not set frontmatter_parse_error"
        );
        assert_eq!(rows(&v, id), want, "{path}: links rows");
    }
}

#[test]
fn memex_add_with_non_ascii_title_frontmatter_indexes_extends_link() {
    let (_dir, v) = init_vault();
    let alpha = add_note(&v, "Alpha", "# Alpha\n");
    let body = "---\ntitle: Ünïcødé\nextends:\n  - [[Alpha]]\n---\nbody\n";
    let src = add_note(&v, "Source", body);

    assert_eq!(parse_error_flag(&v, &src), 0, "no frontmatter_parse_error");
    let at = body.find("[[Alpha]]").unwrap() as i64;
    assert_eq!(
        rows(&v, &src),
        vec![row(at, "Alpha", "extends", None, "frontmatter", &alpha)]
    );
}

#[tokio::test]
async fn cli_and_mcp_update_link_round_trip_non_ascii_label_on_quoted_token() {
    let (_dir, v) = init_vault();
    let alpha = add_note(&v, "Alpha", "# Alpha\n");
    let body = "---\nextends: \"[[Alpha]]\"\ncontradicts: '[[Alpha]]'\n---\nbody\n";
    let src = add_note(&v, "Source", body);
    let before = link_rows(&v, &src);
    assert_eq!(before.len(), 2, "both quoted tokens index: {before:?}");
    let at: Vec<i64> = body.match_indices("[[").map(|(i, _)| i as i64).collect();

    // CLI update-link on the double-quoted token.
    let label = "Ünïcode – dash";
    let out = run(
        &[
            "update-link",
            "--vault",
            &v,
            "--link-id",
            &before[0].0,
            "--label",
            label,
        ],
        None,
    );
    let json = one_line_json(out, "update-link --label");
    assert_eq!(json["label"], label, "{json}");

    // MCP update_link on the single-quoted token. A reindex rewrites the
    // rows, so its id is read again.
    let mcp_label = "日本語 😀 𠜎";
    let contradicts = link_rows(&v, &src)
        .into_iter()
        .find(|(_, r)| r.kind == "contradicts")
        .expect("the contradicts link survives the CLI update-link")
        .0;
    {
        let (state, memex) = mcp_on(&v);
        let resp = parse(
            &memex
                .update_link(params(
                    json!({ "link_id": contradicts, "label": mcp_label }),
                ))
                .await,
        );
        assert!(resp.get("error").is_none(), "update_link: {resp}");
        drop(memex);
        drop(state);
    }

    let (content, _) = content_and_version(&v, &src);
    assert_eq!(
        content,
        "---\nextends: \"[[Alpha|Ünïcode – dash]]\"\n\
         contradicts: '[[Alpha|日本語 😀 𠜎]]'\n---\nbody\n"
    );
    assert_eq!(parse_error_flag(&v, &src), 0);
    let at_after: Vec<i64> = content.match_indices("[[").map(|(i, _)| i as i64).collect();
    assert_eq!(at_after[0], at[0], "the first token did not move");
    assert_eq!(
        rows(&v, &src),
        vec![
            row(
                at_after[0],
                "Alpha",
                "extends",
                Some(label),
                "frontmatter",
                &alpha,
            ),
            row(
                at_after[1],
                "Alpha",
                "contradicts",
                Some(mcp_label),
                "frontmatter",
                &alpha,
            ),
        ]
    );
}
