//! WI #141 (X2): add-link positions stay unique after update-link.
//!
//! Real `memex` binary (`CARGO_BIN_EXE_memex`) on temp vaults. Every
//! frontmatter wikilink is indexed at the byte offset of its own `[[`, so
//! repeated add-link / update-link sequences, and hand-written notes that
//! repeat a token under several keys, keep `(from_note_id, position)` unique
//! and point each link at its own token. The MCP `add_link` tool shares the
//! path and gets the shortest repro.

use std::collections::BTreeSet;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;

use memex_core::link_extractor;
use memex_core::notes::{self, CreateNote};
use memex_core::{indexer, Caller, Vault};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::handler::server::wrapper::Parameters;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tempfile::TempDir;

// ---------- subprocess helpers (as in cli_links.rs) ----------

fn memex_bin() -> String {
    env!("CARGO_BIN_EXE_memex").to_string()
}

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut cmd = Command::new(memex_bin());
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

fn ok_stdout(out: Output) -> String {
    assert!(out.status.success(), "{}", describe(&out));
    String::from_utf8(out.stdout).expect("utf8")
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

/// The C1 failure: exit 1 and one stderr JSON line; returns `error.code`.
fn error_code(out: &Output, what: &str) -> String {
    assert_eq!(out.status.code(), Some(1), "{what}: {}", describe(out));
    let stderr = String::from_utf8(out.stderr.clone()).expect("utf8");
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("{what}: stderr not JSON ({e}): {}", describe(out)));
    v["error"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("{what}: no error.code: {v}"))
        .to_string()
}

fn vault_path(dir: &TempDir) -> String {
    dir.path().to_str().unwrap().to_string()
}

fn init_vault() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    let out = run(&["init", &vault_path(&dir)], None);
    assert!(out.status.success(), "init failed: {}", describe(&out));
    dir
}

fn add_note(vault: &str, title: &str, body: &str) -> String {
    let out = run(&["add", "--vault", vault, "--title", title], Some(body));
    let stdout = ok_stdout(out);
    regex::Regex::new(r"note_id:\s*([0-9A-Z]{26})")
        .unwrap()
        .captures(&stdout)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .expect("note_id")
}

fn add_link(vault: &str, from: &str, to: &str, kind: &str) -> Value {
    let out = run(
        &[
            "add-link", "--vault", vault, "--from", from, "--to", to, "--kind", kind,
        ],
        None,
    );
    let v = one_line_json(out, &format!("add-link {kind}"));
    assert!(v["link_id"].is_string(), "add-link {kind}: {v}");
    v
}

fn update_link(vault: &str, link_id: &str, extra: &[&str]) -> Output {
    let mut args = vec!["update-link", "--vault", vault, "--link-id", link_id];
    args.extend_from_slice(extra);
    run(&args, None)
}

// ---------- vault readers ----------

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Row {
    position: i64,
    link_text: String,
    kind: String,
    label: Option<String>,
    source: String,
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

fn link_rows(vault: &str, id: &str) -> Vec<(String, Row)> {
    let v = Vault::open(Path::new(vault)).unwrap();
    let conn = v.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT id, position, link_text, link_kind, label, source
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
            },
        ))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// The id of the first (by position) link from `from` with this text and kind.
fn link_id(vault: &str, from: &str, text: &str, kind: &str) -> String {
    link_rows(vault, from)
        .into_iter()
        .find(|(_, r)| r.link_text == text && r.kind == kind)
        .unwrap_or_else(|| panic!("no {kind} link to {text} from {from}"))
        .0
}

/// The top-level frontmatter key whose span holds byte `pos` of `content`.
fn frontmatter_key_at(content: &str, pos: usize) -> String {
    for line in content[..pos].rsplit('\n') {
        let first = line.chars().next().unwrap_or(' ');
        if matches!(first, ' ' | '\t' | '-' | '#') {
            continue;
        }
        let key = line.split(':').next().unwrap_or("").trim();
        let key = key.trim_matches(|c| c == '"' || c == '\'');
        return if key == "example_of" {
            "example-of".to_string()
        } else {
            key.to_string()
        };
    }
    String::new()
}

/// The invariants this WI pins after every successful step:
/// - `COUNT(*) = COUNT(DISTINCT position)` for the note;
/// - every position starts its own token (`[[` or, for `from-day`, `![[`)
///   naming the link's title, and a frontmatter link sits under its kind's key;
/// - the index is fresh: the rows are exactly what the extractor yields for
///   the saved `content_md`.
fn assert_index_consistent(vault: &str, id: &str, step: &str) {
    let v = Vault::open(Path::new(vault)).unwrap();
    let (total, distinct): (i64, i64) = v
        .connection_ref()
        .query_row(
            "SELECT COUNT(*), COUNT(DISTINCT position) FROM links WHERE from_note_id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    drop(v);
    assert_eq!(total, distinct, "{step}: positions must be unique");

    let (content, _) = content_and_version(vault, id);
    let rows: Vec<Row> = link_rows(vault, id).into_iter().map(|(_, r)| r).collect();
    for r in &rows {
        let at = &content[r.position as usize..];
        let open = if r.kind == "from-day" { "![[" } else { "[[" };
        assert!(
            at.starts_with(&format!("{open}{}", r.link_text)),
            "{step}: {r:?} must start its own token, found {:?}",
            &at[..at.len().min(24)]
        );
        if r.source == "frontmatter" {
            assert_eq!(
                frontmatter_key_at(&content, r.position as usize),
                r.kind,
                "{step}: {r:?} must sit under its own key in {content:?}"
            );
        }
    }

    let extracted = link_extractor::extract(&content);
    let mut want: Vec<Row> = extracted
        .all()
        .map(|l| Row {
            position: l.position,
            link_text: l.link_text.clone(),
            kind: l.link_kind.as_str().to_string(),
            label: l.label.clone(),
            source: l.source.as_str().to_string(),
        })
        .collect();
    want.sort();
    let mut got = rows;
    got.sort();
    assert_eq!(got, want, "{step}: the index matches the saved content");
}

fn frontmatter_rows_to(vault: &str, id: &str, title: &str) -> Vec<Row> {
    link_rows(vault, id)
        .into_iter()
        .map(|(_, r)| r)
        .filter(|r| r.source == "frontmatter" && r.link_text == title)
        .collect()
}

// ---------- AC 1: Connor's exact sequence ----------

#[test]
fn connor_sequence_update_link_then_repeated_add_links_all_exit_zero() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(&v, "Source", "# Source\n\nbody.\n");
    let alpha = add_note(&v, "Alpha", "# Alpha\n");

    let first = add_link(&v, &src, &alpha, "extends");
    assert_eq!(first["was_existing"], false);
    let l = first["link_id"].as_str().unwrap().to_string();
    one_line_json(update_link(&v, &l, &["--label", "shown"]), "update-link");
    let second = add_link(&v, &src, &alpha, "contradicts");
    assert_eq!(second["was_existing"], false);
    let third = add_link(&v, &src, &alpha, "example-of");
    assert_eq!(third["was_existing"], false);

    assert_index_consistent(&v, &src, "after the sequence");
    let (content, _) = content_and_version(&v, &src);
    let fm = frontmatter_rows_to(&v, &src, "Alpha");
    let kinds: BTreeSet<&str> = fm.iter().map(|r| r.kind.as_str()).collect();
    assert_eq!(
        kinds,
        BTreeSet::from(["contradicts", "example-of", "extends"]),
        "{fm:?}"
    );
    let positions: BTreeSet<i64> = fm.iter().map(|r| r.position).collect();
    assert_eq!(positions.len(), 3, "three distinct positions: {fm:?}");
    let tokens: BTreeSet<i64> = content
        .match_indices("[[Alpha")
        .map(|(i, _)| i as i64)
        .collect();
    assert_eq!(
        positions, tokens,
        "each link at its own `[[` in {content:?}"
    );
    let extends = fm.iter().find(|r| r.kind == "extends").unwrap();
    assert!(
        content[extends.position as usize..].starts_with("[[Alpha|shown]]"),
        "the labelled token is the extends link's own: {content:?}"
    );
    assert_eq!(extends.label.as_deref(), Some("shown"));
}

// ---------- AC 2: one target under four frontmatter kinds ----------

#[test]
fn same_target_under_four_frontmatter_kinds_gets_distinct_positions() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(&v, "Source", "# Source\n");
    let alpha = add_note(&v, "Alpha", "# Alpha\n");

    for kind in ["extends", "contradicts", "example-of", "inspired-by"] {
        let out = add_link(&v, &src, &alpha, kind);
        assert_eq!(out["was_existing"], false, "{kind}: {out}");
        assert_index_consistent(&v, &src, &format!("after add-link {kind}"));
    }
    let fm = frontmatter_rows_to(&v, &src, "Alpha");
    let positions: BTreeSet<i64> = fm.iter().map(|r| r.position).collect();
    assert_eq!(fm.len(), 4, "{fm:?}");
    assert_eq!(positions.len(), 4, "{fm:?}");
}

// ---------- AC 3: any update/add sequence keeps positions unique ----------

enum Step {
    Add(&'static str, &'static str),
    Label(&'static str, &'static str, &'static str),
    ClearLabel(&'static str, &'static str),
    Kind(&'static str, &'static str, &'static str),
}

#[test]
fn mixed_add_and_update_link_sequence_keeps_positions_unique_after_every_step() {
    use Step::*;
    let dir = init_vault();
    let v = vault_path(&dir);
    // A transclusion token gives the note a `from-day` link (`![[`).
    let src = add_note(&v, "Source", "# Source\n\nSee ![[2026-10-01#^ab]] here.\n");
    let mut ids = std::collections::HashMap::new();
    for t in ["Alpha", "Beta", "Gamma"] {
        ids.insert(t, add_note(&v, t, &format!("# {t}\n")));
    }
    assert_index_consistent(&v, &src, "initial");

    let steps = [
        Add("Beta", "references"),
        Add("Alpha", "extends"),
        Add("Alpha", "contradicts"),
        Add("Beta", "extends"),
        Label("Alpha", "extends", "one"),
        Add("Alpha", "example-of"),
        Add("Alpha", "inspired-by"),
        ClearLabel("Alpha", "extends"),
        Add("Alpha", "references"),
        Kind("Alpha", "references", "supports"),
        Add("Alpha", "references"),
        Add("Beta", "contradicts"),
        Label("Beta", "contradicts", "two"),
        Add("Gamma", "references"),
        Add("Gamma", "extends"),
        Label("Alpha", "contradicts", "three"),
        Add("Gamma", "example-of"),
        Kind("Beta", "references", "contradicts"),
        ClearLabel("Alpha", "contradicts"),
        Add("Beta", "example-of"),
        Label("Alpha", "inspired-by", "four"),
        Add("Gamma", "inspired-by"),
    ];
    for (i, step) in steps.iter().enumerate() {
        let what = match step {
            Add(t, kind) => {
                add_link(&v, &src, &ids[t], kind);
                format!("step {i}: add-link {t} {kind}")
            }
            Label(t, kind, label) => {
                let l = link_id(&v, &src, t, kind);
                let what = format!("step {i}: update-link {t} {kind} --label {label}");
                one_line_json(update_link(&v, &l, &["--label", label]), &what);
                what
            }
            ClearLabel(t, kind) => {
                let l = link_id(&v, &src, t, kind);
                let what = format!("step {i}: update-link {t} {kind} --clear-label");
                one_line_json(update_link(&v, &l, &["--clear-label"]), &what);
                what
            }
            Kind(t, kind, new_kind) => {
                let l = link_id(&v, &src, t, kind);
                let what = format!("step {i}: update-link {t} {kind} --kind {new_kind}");
                one_line_json(update_link(&v, &l, &["--kind", new_kind]), &what);
                what
            }
        };
        assert_index_consistent(&v, &src, &what);
    }
}

#[test]
fn repeated_add_and_label_rounds_keep_positions_unique_in_a_loop() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(&v, "Source", "# Source\n");
    let kinds = ["extends", "contradicts", "example-of", "inspired-by"];
    for round in 0..3 {
        let target = add_note(&v, &format!("Target {round}"), "x\n");
        let title = format!("Target {round}");
        for (k, kind) in kinds.iter().enumerate() {
            add_link(&v, &src, &target, kind);
            assert_index_consistent(&v, &src, &format!("round {round}: add {kind}"));
            if k % 2 == 0 {
                let l = link_id(&v, &src, &title, kind);
                let label = format!("r{round}k{k}");
                let what = format!("round {round}: label {kind}");
                one_line_json(update_link(&v, &l, &["--label", &label]), &what);
                assert_index_consistent(&v, &src, &what);
            }
        }
        // Clearing a label makes the token byte-identical to its siblings.
        let l = link_id(&v, &src, &title, "extends");
        let what = format!("round {round}: clear extends label");
        one_line_json(update_link(&v, &l, &["--clear-label"]), &what);
        assert_index_consistent(&v, &src, &what);
    }
}

// ---------- AC 4: `memex add` of a hand-written note ----------

#[test]
fn memex_add_with_same_wikilink_under_two_kind_keys_indexes_both_links() {
    let dir = init_vault();
    let v = vault_path(&dir);
    add_note(&v, "Alpha", "# Alpha\n");
    let body = "---\nnotes: see [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody";
    let out = run(&["add", "--vault", &v, "--title", "Source"], Some(body));
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    let stdout = String::from_utf8(out.stdout).unwrap();
    let src = regex::Regex::new(r"note_id:\s*([0-9A-Z]{26})")
        .unwrap()
        .captures(&stdout)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .expect("note_id");

    assert_index_consistent(&v, &src, "after memex add");
    let kinds: BTreeSet<String> = frontmatter_rows_to(&v, &src, "Alpha")
        .into_iter()
        .map(|r| r.kind)
        .collect();
    assert_eq!(
        kinds,
        BTreeSet::from(["extends".to_string(), "notes".to_string()])
    );
}

// ---------- AC 5: a skipped key holding the same text ----------

#[test]
fn update_link_label_below_about_key_rewrites_only_its_own_token() {
    let dir = init_vault();
    let v = vault_path(&dir);
    add_note(&v, "Alpha", "# Alpha\n");
    let body = "---\nabout: [[Alpha]]\nextends:\n  - [[Alpha]]\n---\nbody\n";
    let src = add_note(&v, "Source", body);
    let (before, _) = content_and_version(&v, &src);
    let own = before.rfind("[[Alpha]]").unwrap();
    let rows = link_rows(&v, &src);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0].1.kind, "extends");
    assert_eq!(
        rows[0].1.position, own as i64,
        "its own token in {before:?}"
    );

    let out = update_link(&v, &rows[0].0, &["--label", "X"]);
    let json = one_line_json(out, "update-link --label X");
    assert_eq!(json["label"], "X", "{json}");
    assert_eq!(json["position"], own as i64, "{json}");

    let (after, _) = content_and_version(&v, &src);
    let mut expected = before.clone();
    expected.replace_range(own..own + "[[Alpha]]".len(), "[[Alpha|X]]");
    assert_eq!(after, expected);
    assert!(after.contains("about: [[Alpha]]\n"), "{after:?}");
    assert_index_consistent(&v, &src, "after update-link");
}

// ---------- AC 7: a token with no verbatim occurrence ----------

#[test]
fn update_link_on_token_without_verbatim_occurrence_exits_not_found_and_leaves_note_unchanged() {
    let dir = init_vault();
    let v = vault_path(&dir);
    add_note(&v, "Alpha", "# Alpha\n");
    // `\x5B\x5BAlpha]]` decodes to `[[Alpha]]` but never appears verbatim.
    let body = "---\nextends: \"\\x5B\\x5BAlpha]]\"\ncontradicts:\n  - [[Alpha]]\n---\nbody\n";
    let src = add_note(&v, "Source", body);
    let rows = link_rows(&v, &src);
    assert_eq!(rows.len(), 2, "{rows:?}");
    let positions: BTreeSet<i64> = rows.iter().map(|(_, r)| r.position).collect();
    assert_eq!(positions.len(), 2, "unique positions: {rows:?}");
    let escaped = link_id(&v, &src, "Alpha", "extends");

    let before = content_and_version(&v, &src);
    let rows_before = link_rows(&v, &src);
    let out = update_link(&v, &escaped, &["--label", "X"]);
    assert_eq!(
        error_code(&out, "update-link on the escaped token"),
        "not_found"
    );
    assert_eq!(content_and_version(&v, &src), before, "note unchanged");
    assert_eq!(link_rows(&v, &src), rows_before, "links unchanged");
}

// ---------- the next save of a note main left stale ----------

#[test]
fn memex_update_of_note_with_repeated_frontmatter_tokens_reindexes_cleanly() {
    let dir = init_vault();
    let v = vault_path(&dir);
    add_note(&v, "Beta", "# Beta\n");
    let src = add_note(&v, "Source", "# Source\n");
    // The content main saved before its reindex failed: the same target
    // under two kinds. Every later save of it failed the same way.
    let (_, version) = content_and_version(&v, &src);
    let body = "---\nextends:\n  - [[Beta]]\ncontradicts:\n  - [[Beta]]\n---\nzebrafinch\n";
    let out = run(
        &[
            "update",
            "--vault",
            &v,
            "--note-id",
            &src,
            "--expected-version",
            &version.to_string(),
        ],
        Some(body),
    );
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert_index_consistent(&v, &src, "after memex update");
    assert_eq!(frontmatter_rows_to(&v, &src, "Beta").len(), 2);

    let vault = Vault::open(Path::new(&v)).unwrap();
    let hits: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM chunk_fts WHERE note_id = ? AND chunk_fts MATCH 'zebrafinch'",
            [&src],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hits > 0, "FTS holds the saved content");
}

// ---------- AC 9: MCP parity ----------

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

fn parse(resp: &str) -> Value {
    serde_json::from_str(resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
}

async fn person_note(state: &AppState, title: &str, body: &str) -> String {
    let mut vault = state.vault.lock().await;
    let note = notes::create_note_as(
        &mut vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: None,
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

#[tokio::test]
async fn mcp_add_link_same_target_under_two_kinds_succeeds() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let vault = Vault::create(&path).unwrap();
    let state = Arc::new(AppState::new(vault, path.clone(), None));
    let memex = Memex::new(state.clone());
    let src = person_note(&state, "Source", "# Source\n").await;
    let beta = person_note(&state, "Beta", "# Beta\n").await;

    for kind in ["extends", "contradicts"] {
        let resp = parse(
            &memex
                .add_link(params(
                    json!({ "from_id": src, "to_id": beta, "kind": kind }),
                ))
                .await,
        );
        assert!(resp.get("error").is_none(), "add_link {kind}: {resp}");
        assert!(resp["link_id"].is_string(), "add_link {kind}: {resp}");
    }
    // Connor's update-link step over MCP, then a third kind.
    let l = {
        let vault = state.vault.lock().await;
        vault
            .connection_ref()
            .query_row(
                "SELECT id FROM links WHERE from_note_id = ? AND link_kind = 'extends'",
                [&src],
                |r| r.get::<_, String>(0),
            )
            .unwrap()
    };
    let resp = parse(
        &memex
            .update_link(params(json!({ "link_id": l, "label": "shown" })))
            .await,
    );
    assert!(resp.get("error").is_none(), "update_link: {resp}");
    let resp = parse(
        &memex
            .add_link(params(
                json!({ "from_id": src, "to_id": beta, "kind": "example-of" }),
            ))
            .await,
    );
    assert!(resp.get("error").is_none(), "add_link example-of: {resp}");

    drop(memex);
    drop(state);
    let p = path.to_str().unwrap();
    assert_index_consistent(p, &src, "after the MCP sequence");
    assert_eq!(frontmatter_rows_to(p, &src, "Beta").len(), 3);
}
