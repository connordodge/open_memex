//! WI #140 (X1): `add-link --label` keeps the label for every kind, not only
//! `references`. A frontmatter-bound link is written as `[[Title|label]]` under
//! its kind key, and its `links` row stores `label`.
//!
//! Real `memex` binary (`CARGO_BIN_EXE_memex`) against temp vaults, plus the
//! MCP `add_link` tool called directly on an identical vault.
//!
//! Until X2 lands, two frontmatter links with byte-identical tokens on one
//! source note collide on `UNIQUE (from_note_id, position)`, so every test here
//! gives each kind its own source note and its own label.

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

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
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

fn ok_stdout(out: Output) -> String {
    if !out.status.success() {
        panic!(
            "exit={:?} stdout={} stderr={}",
            out.status.code(),
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    String::from_utf8(out.stdout).expect("utf8")
}

fn ok_json(out: Output) -> Value {
    let stdout = ok_stdout(out);
    serde_json::from_str(stdout.trim()).unwrap_or_else(|e| panic!("not JSON ({e}): {stdout}"))
}

fn path_str(p: &Path) -> String {
    p.to_str().unwrap().to_string()
}

fn init_vault() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    let out = run(&["init", &path_str(dir.path())], None);
    assert!(out.status.success(), "init failed: {out:?}");
    dir
}

fn add_note(vault: &Path, title: &str, body: &str) -> String {
    let stdout = ok_stdout(run(
        &["add", "--vault", &path_str(vault), "--title", title],
        Some(body),
    ));
    let re = regex::Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(&stdout)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .unwrap_or_else(|| panic!("no note_id in {stdout}"))
}

fn cli_add_link(vault: &Path, from: &str, to: &str, kind: &str, label: Option<&str>) -> Value {
    let v = path_str(vault);
    let mut args = vec![
        "add-link", "--vault", &v, "--from", from, "--to", to, "--kind", kind,
    ];
    if let Some(l) = label {
        args.push("--label");
        args.push(l);
    }
    ok_json(run(&args, None))
}

fn get_note(vault: &Path, id: &str) -> Value {
    ok_json(run(
        &["get", "--vault", &path_str(vault), "--note-id", id],
        None,
    ))
}

fn content_md(vault: &Path, id: &str) -> String {
    get_note(vault, id)["content_md"]
        .as_str()
        .expect("content_md")
        .to_string()
}

/// One `links` row as stored: (link_text, link_kind, label, source).
type Row = (String, String, Option<String>, String);

fn link_rows(vault: &Path, from: &str) -> Vec<Row> {
    let vault = Vault::open(vault).expect("open vault");
    let conn = vault.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT link_text, link_kind, label, source FROM links
                WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap();
    stmt.query_map([from], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn row_of_kind(vault: &Path, from: &str, kind: &str) -> Row {
    let rows = link_rows(vault, from);
    let mut of_kind: Vec<Row> = rows.iter().filter(|r| r.1 == kind).cloned().collect();
    assert_eq!(of_kind.len(), 1, "one {kind} link from {from}: {rows:?}");
    of_kind.remove(0)
}

fn params<T: DeserializeOwned>(v: Value) -> Parameters<T> {
    Parameters(serde_json::from_value(v).expect("params deserialize"))
}

#[test]
fn cli_add_link_extends_label_repro() {
    let dir = init_vault();
    let v = dir.path();
    let src = add_note(v, "Source", "# Source\n\nbody.\n");
    let alpha = add_note(v, "Alpha", "# Alpha\n");

    let refs = cli_add_link(v, &src, &alpha, "references", Some("Lbl-references"));
    assert_eq!(refs["was_existing"], false);
    let ext = cli_add_link(v, &src, &alpha, "extends", Some("Lbl-extends"));
    assert_eq!(ext["was_existing"], false);
    assert_eq!(ext["kind"], "extends");
    assert_eq!(ext["source"], "frontmatter");

    let md = content_md(v, &src);
    assert!(
        md.contains("extends:\n  - [[Alpha|Lbl-extends]]\n"),
        "content_md: {md:?}"
    );
    assert!(
        md.contains("[[Alpha|Lbl-references]]"),
        "content_md: {md:?}"
    );

    let tree = ok_stdout(run(
        &["links", "--vault", &path_str(v), "--note-id", &src],
        None,
    ));
    assert!(
        tree.contains("· Alpha \"Lbl-extends\""),
        "links output shows the label: {tree}"
    );

    assert_eq!(
        row_of_kind(v, &src, "extends"),
        (
            "Alpha".to_string(),
            "extends".to_string(),
            Some("Lbl-extends".to_string()),
            "frontmatter".to_string()
        )
    );
}

#[test]
fn cli_add_link_keeps_label_for_every_kind() {
    let dir = init_vault();
    let v = dir.path();
    let alpha = add_note(v, "Alpha", "# Alpha\n");

    for kind in [
        "references",
        "extends",
        "contradicts",
        "example-of",
        "inspired-by",
    ] {
        // One source note per kind (see the module doc).
        let src = add_note(v, &format!("Source {kind}"), "body\n");
        let label = format!("Lbl-{kind}");
        let out = cli_add_link(v, &src, &alpha, kind, Some(&label));
        assert_eq!(out["was_existing"], false, "{kind}: {out}");
        assert_eq!(out["kind"], kind);

        let md = content_md(v, &src);
        let row = row_of_kind(v, &src, kind);
        if kind == "references" {
            assert_eq!(out["source"], "auto_added", "{kind}: {out}");
            assert!(
                md.contains(&format!("## Auto-added links\n\n[[Alpha|{label}]]\n")),
                "{kind}: content_md: {md:?}"
            );
        } else {
            assert_eq!(out["source"], "frontmatter", "{kind}: {out}");
            assert!(
                md.contains(&format!("{kind}:\n  - [[Alpha|{label}]]\n")),
                "{kind}: content_md: {md:?}"
            );
            assert_eq!(row.3, "frontmatter", "{kind}: links.source");
        }
        assert_eq!(row.0, "Alpha", "{kind}: link_text");
        assert_eq!(
            row.2.as_deref(),
            Some(label.as_str()),
            "{kind}: links.label"
        );
    }
}

#[test]
fn cli_add_link_without_label_or_empty_label_writes_no_pipe() {
    let dir = init_vault();
    let v = dir.path();
    let alpha = add_note(v, "Alpha", "# Alpha\n");

    for (name, label) in [("none", None), ("empty", Some(""))] {
        for kind in ["references", "extends", "inspired-by"] {
            let src = add_note(v, &format!("Source {name} {kind}"), "body\n");
            cli_add_link(v, &src, &alpha, kind, label);

            let md = content_md(v, &src);
            assert!(md.contains("[[Alpha]]"), "{name} {kind}: {md:?}");
            assert!(!md.contains('|'), "{name} {kind}: no pipe: {md:?}");
            if kind != "references" {
                assert!(
                    md.contains(&format!("{kind}:\n  - [[Alpha]]\n")),
                    "{name} {kind}: {md:?}"
                );
            }
            let row = row_of_kind(v, &src, kind);
            assert_eq!(row.2, None, "{name} {kind}: label stays NULL");
        }
    }
}

#[test]
fn cli_add_link_special_character_label_round_trips() {
    let dir = init_vault();
    let v = dir.path();
    let alpha = add_note(v, "Alpha", "# Alpha\n");

    for (kind, label) in [
        ("extends", "a: b # c 'd' \"e\""),
        ("inspired-by", "two words: and # more 'single' \"double\""),
    ] {
        let src = add_note(v, &format!("Source {kind}"), "body\n");
        let out = cli_add_link(v, &src, &alpha, kind, Some(label));
        assert_eq!(out["source"], "frontmatter", "{kind}: {out}");

        let md = content_md(v, &src);
        assert!(
            md.contains(&format!("[[Alpha|{label}]]")),
            "{kind}: content_md: {md:?}"
        );
        let row = row_of_kind(v, &src, kind);
        assert_eq!(row.2.as_deref(), Some(label), "{kind}: byte for byte");
    }
}

#[test]
fn cli_add_link_readd_with_different_label_keeps_label_and_version() {
    let dir = init_vault();
    let v = dir.path();
    let alpha = add_note(v, "Alpha", "# Alpha\n");

    for kind in ["extends", "inspired-by"] {
        let src = add_note(v, &format!("Source {kind}"), "body\n");
        let first = cli_add_link(v, &src, &alpha, kind, Some("first"));
        assert_eq!(first["was_existing"], false, "{kind}: {first}");
        let md_after_first = content_md(v, &src);
        let version_after_first = get_note(v, &src)["version"].as_i64().unwrap();
        assert_eq!(first["note_version"].as_i64(), Some(version_after_first));

        let second = cli_add_link(v, &src, &alpha, kind, Some("second"));
        assert_eq!(second["was_existing"], true, "{kind}: {second}");
        assert_eq!(second["link_id"], first["link_id"], "{kind}");
        assert_eq!(
            second["note_version"].as_i64(),
            Some(version_after_first),
            "{kind}: version unchanged"
        );

        assert_eq!(
            content_md(v, &src),
            md_after_first,
            "{kind}: nothing written"
        );
        assert_eq!(
            get_note(v, &src)["version"].as_i64(),
            Some(version_after_first),
            "{kind}"
        );
        assert!(
            md_after_first.contains(&format!("{kind}:\n  - [[Alpha|first]]\n")),
            "{kind}: {md_after_first:?}"
        );
        let row = row_of_kind(v, &src, kind);
        assert_eq!(row.2.as_deref(), Some("first"), "{kind}: label unchanged");
    }
}

#[tokio::test]
async fn mcp_add_link_extends_label_matches_cli() {
    // Two vaults seeded the same way.
    let cli_dir = init_vault();
    let mcp_dir = init_vault();
    let cli_src = add_note(cli_dir.path(), "Source", "# Source\n\nbody.\n");
    let cli_alpha = add_note(cli_dir.path(), "Alpha", "# Alpha\n");
    let mcp_src = add_note(mcp_dir.path(), "Source", "# Source\n\nbody.\n");
    let mcp_alpha = add_note(mcp_dir.path(), "Alpha", "# Alpha\n");

    let cli_out = cli_add_link(cli_dir.path(), &cli_src, &cli_alpha, "extends", Some("x"));

    let mcp_out: Value = {
        let vault = Vault::open(mcp_dir.path()).expect("open vault");
        let state = Arc::new(AppState::new(vault, mcp_dir.path().to_path_buf(), None));
        let memex = Memex::new(state);
        let resp = memex
            .add_link(params(json!({
                "from_id": mcp_src,
                "to_id": mcp_alpha,
                "kind": "extends",
                "label": "x",
            })))
            .await;
        serde_json::from_str(&resp).unwrap_or_else(|e| panic!("non-JSON ({e}): {resp}"))
    };

    assert_eq!(mcp_out["was_existing"], false, "{mcp_out}");
    assert_eq!(mcp_out["kind"], cli_out["kind"]);
    assert_eq!(mcp_out["source"], cli_out["source"]);
    assert_eq!(mcp_out["note_version"], cli_out["note_version"]);

    let cli_md = content_md(cli_dir.path(), &cli_src);
    let mcp_md = content_md(mcp_dir.path(), &mcp_src);
    assert!(
        mcp_md.contains("extends:\n  - [[Alpha|x]]\n"),
        "mcp content_md: {mcp_md:?}"
    );
    assert_eq!(mcp_md, cli_md, "MCP and CLI write the same markdown");

    let mcp_row = row_of_kind(mcp_dir.path(), &mcp_src, "extends");
    assert_eq!(mcp_row.2.as_deref(), Some("x"), "mcp links.label");
    assert_eq!(
        link_rows(mcp_dir.path(), &mcp_src),
        link_rows(cli_dir.path(), &cli_src),
        "MCP and CLI store the same links rows"
    );
}
