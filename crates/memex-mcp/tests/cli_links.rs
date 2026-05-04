//! CLI subprocess integration tests for the new `links` and `add-link`
//! subcommands plus the `--no-rename-links` and `--include-links` flags. Real
//! `memex` binary, real vault, real subprocess pipes — these are what catch
//! end-to-end regressions that direct-call tests miss.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::Value;
use tempfile::TempDir;

fn memex_bin() -> String {
    // `cargo test` builds the bin; `env!("CARGO_BIN_EXE_<name>")` gives us
    // its absolute path.
    env!("CARGO_BIN_EXE_memex").to_string()
}

fn run(args: &[&str], stdin_body: Option<&str>) -> std::process::Output {
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

fn ok_stdout(out: std::process::Output) -> String {
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

fn vault_path(dir: &TempDir) -> String {
    dir.path().to_str().unwrap().to_string()
}

fn init_vault() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    let path = vault_path(&dir);
    let out = run(&["init", &path], None);
    assert!(out.status.success(), "init failed: {:?}", out);
    dir
}

fn add_note(vault: &Path, title: &str, body: &str) -> String {
    let out = run(
        &[
            "add",
            "--vault",
            vault.to_str().unwrap(),
            "--title",
            title,
        ],
        Some(body),
    );
    let stdout = ok_stdout(out);
    // stdout has "  note_id: 01HXXXX..."; pull the ULID.
    regex_capture(&stdout, r"note_id:\s*([0-9A-Z]{26})").expect("note_id")
}

fn regex_capture(s: &str, pattern: &str) -> Option<String> {
    let re = regex::Regex::new(pattern).unwrap();
    re.captures(s)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
}

#[test]
fn add_link_with_references_kind_writes_to_auto_added_section() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "# Source\n\nbody.\n");
    let tgt = add_note(dir.path(), "Target", "# Target\n");

    let out = run(
        &[
            "add-link",
            "--vault",
            &v,
            "--from",
            &src,
            "--to",
            &tgt,
            "--kind",
            "references",
        ],
        None,
    );
    let stdout = ok_stdout(out);
    let v: Value = serde_json::from_str(stdout.trim()).expect("json");
    assert_eq!(v["was_existing"], false);
    assert_eq!(v["kind"], "references");
    assert_eq!(v["source"], "auto_added");
    assert!(v["link_id"].is_string());

    // Source content should now contain the auto-added section + wikilink.
    let get_out = run(
        &[
            "get",
            "--vault",
            dir.path().to_str().unwrap(),
            "--note-id",
            &src,
        ],
        None,
    );
    let get_payload: Value = serde_json::from_str(ok_stdout(get_out).trim()).unwrap();
    let body = get_payload["content_md"].as_str().unwrap();
    assert!(body.contains("## Auto-added links"));
    assert!(body.contains("[[Target]]"));
}

#[test]
fn add_link_with_typed_kind_writes_to_frontmatter() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "body.\n");
    let tgt = add_note(dir.path(), "Target", "x");

    let out = run(
        &[
            "add-link",
            "--vault",
            &v,
            "--from",
            &src,
            "--to",
            &tgt,
            "--kind",
            "contradicts",
        ],
        None,
    );
    let stdout = ok_stdout(out);
    let v: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(v["kind"], "contradicts");
    assert_eq!(v["source"], "frontmatter");

    let body: String = {
        let g = run(
            &[
                "get",
                "--vault",
                dir.path().to_str().unwrap(),
                "--note-id",
                &src,
            ],
            None,
        );
        let payload: Value = serde_json::from_str(ok_stdout(g).trim()).unwrap();
        payload["content_md"].as_str().unwrap().to_string()
    };
    assert!(body.starts_with("---\n"), "body: {body:?}");
    assert!(body.contains("contradicts:\n  - [[Target]]"));
}

#[test]
fn add_link_user_defined_kind_is_first_class() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "body");
    let tgt = add_note(dir.path(), "Target", "x");

    let out = run(
        &[
            "add-link",
            "--vault",
            &v,
            "--from",
            &src,
            "--to",
            &tgt,
            "--kind",
            "inspired-by",
        ],
        None,
    );
    let stdout = ok_stdout(out);
    let v: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(v["kind"], "inspired-by");
    assert_eq!(v["source"], "frontmatter");
}

#[test]
fn add_link_is_idempotent() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "body");
    let tgt = add_note(dir.path(), "Target", "x");

    let first = run(
        &[
            "add-link", "--vault", &v, "--from", &src, "--to", &tgt, "--kind", "references",
        ],
        None,
    );
    let first_payload: Value =
        serde_json::from_str(ok_stdout(first).trim()).expect("first ok");
    assert_eq!(first_payload["was_existing"], false);
    let first_id = first_payload["link_id"].as_str().unwrap().to_string();

    let second = run(
        &[
            "add-link", "--vault", &v, "--from", &src, "--to", &tgt, "--kind", "references",
        ],
        None,
    );
    let second_payload: Value =
        serde_json::from_str(ok_stdout(second).trim()).expect("second ok");
    assert_eq!(second_payload["was_existing"], true);
    assert_eq!(second_payload["link_id"].as_str().unwrap(), first_id);
}

#[test]
fn add_link_invalid_kind_is_rejected() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "body");
    let tgt = add_note(dir.path(), "Target", "x");

    let out = run(
        &[
            "add-link",
            "--vault",
            &v,
            "--from",
            &src,
            "--to",
            &tgt,
            "--kind",
            "Made_Up", // mixed-case + underscore, fails regex
        ],
        None,
    );
    assert!(!out.status.success(), "expected failure for invalid kind");
}

#[test]
fn links_command_prints_outgoing_grouped_by_kind() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "body");
    let a = add_note(dir.path(), "A", "x");
    let b = add_note(dir.path(), "B", "x");
    ok_stdout(run(
        &[
            "add-link", "--vault", &v, "--from", &src, "--to", &a, "--kind", "references",
        ],
        None,
    ));
    ok_stdout(run(
        &[
            "add-link", "--vault", &v, "--from", &src, "--to", &b, "--kind", "extends",
        ],
        None,
    ));

    let stdout = ok_stdout(run(
        &["links", "--vault", &v, "--note-id", &src, "--dir", "out"],
        None,
    ));
    assert!(stdout.contains("outgoing"), "stdout: {stdout}");
    assert!(stdout.contains("references"));
    assert!(stdout.contains("extends"));
    assert!(stdout.contains("A"));
    assert!(stdout.contains("B"));
}

#[test]
fn get_with_include_links_returns_links_and_backlinks() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Source", "body");
    let tgt = add_note(dir.path(), "Target", "x");
    ok_stdout(run(
        &[
            "add-link", "--vault", &v, "--from", &src, "--to", &tgt, "--kind", "extends",
        ],
        None,
    ));

    // From the source: outgoing 'extends' to Target.
    let src_payload: Value = serde_json::from_str(
        ok_stdout(run(
            &[
                "get",
                "--vault",
                &v,
                "--note-id",
                &src,
                "--include-links",
            ],
            None,
        ))
        .trim(),
    )
    .unwrap();
    assert!(src_payload["links"].is_object());
    let extends = src_payload["links"]["extends"].as_array().unwrap();
    assert_eq!(extends.len(), 1);
    assert_eq!(extends[0]["link_text"], "Target");

    // Target should see Source as a backlink under 'extends'.
    let tgt_payload: Value = serde_json::from_str(
        ok_stdout(run(
            &[
                "get",
                "--vault",
                &v,
                "--note-id",
                &tgt,
                "--include-links",
            ],
            None,
        ))
        .trim(),
    )
    .unwrap();
    assert!(tgt_payload["backlinks"].is_object());
    let bl_extends = tgt_payload["backlinks"]["extends"].as_array().unwrap();
    assert_eq!(bl_extends.len(), 1);
    assert_eq!(bl_extends[0]["from_note_id"], src);
}

#[test]
fn update_with_no_rename_links_skips_linker_rewrite() {
    let dir = init_vault();
    let v = vault_path(&dir);
    let src = add_note(dir.path(), "Linker", "Refers to [[OldTitle]] here.");
    let target = add_note(dir.path(), "OldTitle", "Original.");

    // Get current target version (will be 1 after add).
    let g = run(
        &[
            "get",
            "--vault",
            &v,
            "--note-id",
            &target,
        ],
        None,
    );
    let payload: Value = serde_json::from_str(ok_stdout(g).trim()).unwrap();
    let version = payload["version"].as_i64().unwrap();

    // Update with a new title AND --no-rename-links. Body comes from stdin.
    let out = run(
        &[
            "update",
            "--vault",
            &v,
            "--note-id",
            &target,
            "--expected-version",
            &version.to_string(),
            "--title",
            "NewTitle",
            "--no-rename-links",
        ],
        Some("Original."),
    );
    ok_stdout(out);

    // Linker's content should still reference [[OldTitle]] verbatim.
    let g2 = run(
        &[
            "get",
            "--vault",
            &v,
            "--note-id",
            &src,
        ],
        None,
    );
    let payload2: Value = serde_json::from_str(ok_stdout(g2).trim()).unwrap();
    let body = payload2["content_md"].as_str().unwrap();
    assert!(body.contains("[[OldTitle]]"), "body unchanged: {body}");
}
