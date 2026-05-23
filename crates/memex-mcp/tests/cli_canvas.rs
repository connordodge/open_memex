//! CLI subprocess integration tests for the `canvas` subcommand group and
//! `update-link`. Real binary, real vault.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::Value;
use tempfile::TempDir;

fn memex_bin() -> String {
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

fn init_vault() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    let out = run(&["init", dir.path().to_str().unwrap()], None);
    assert!(out.status.success());
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
    let re = regex::Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(&stdout).unwrap()[1].to_string()
}

fn canvas_new(vault: &Path, title: &str) -> Value {
    let out = run(
        &[
            "canvas",
            "new",
            "--vault",
            vault.to_str().unwrap(),
            "--title",
            title,
        ],
        None,
    );
    serde_json::from_str(&ok_stdout(out)).unwrap()
}

#[test]
fn canvas_new_then_ls_round_trip() {
    let dir = init_vault();
    let c = canvas_new(dir.path(), "Board A");
    let cid = c["canvas_id"].as_str().unwrap().to_string();
    assert_eq!(c["title"].as_str().unwrap(), "Board A");

    let out = run(
        &["canvas", "ls", "--vault", dir.path().to_str().unwrap()],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    let arr = v["canvases"].as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["canvas_id"].as_str().unwrap(), cid);
    assert_eq!(arr[0]["node_count"].as_i64().unwrap(), 0);
}

#[test]
fn canvas_add_get_move_remove_round_trip() {
    let dir = init_vault();
    let c = canvas_new(dir.path(), "Board");
    let cid = c["canvas_id"].as_str().unwrap().to_string();
    let nid = add_note(dir.path(), "Note A", "# Note A\n");

    // Add.
    let out = run(
        &[
            "canvas",
            "add",
            "--vault",
            dir.path().to_str().unwrap(),
            "--canvas-id",
            &cid,
            "--note-id",
            &nid,
            "--x",
            "1.5",
            "--y",
            "2.5",
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    assert_eq!(v["x"].as_f64().unwrap(), 1.5);
    assert_eq!(v["y"].as_f64().unwrap(), 2.5);

    // Move.
    let out = run(
        &[
            "canvas",
            "move",
            "--vault",
            dir.path().to_str().unwrap(),
            "--canvas-id",
            &cid,
            "--note-id",
            &nid,
            "--x",
            "10.0",
            "--y",
            "20.0",
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    assert_eq!(v["x"].as_f64().unwrap(), 10.0);

    // Get.
    let out = run(
        &[
            "canvas",
            "get",
            "--vault",
            dir.path().to_str().unwrap(),
            "--canvas-id",
            &cid,
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    assert_eq!(v["nodes"].as_array().unwrap().len(), 1);
    assert_eq!(v["nodes"][0]["x"].as_f64().unwrap(), 10.0);

    // Remove.
    let out = run(
        &[
            "canvas",
            "remove",
            "--vault",
            dir.path().to_str().unwrap(),
            "--canvas-id",
            &cid,
            "--note-id",
            &nid,
        ],
        None,
    );
    assert!(out.status.success());

    // Get again — placement gone.
    let out = run(
        &[
            "canvas",
            "get",
            "--vault",
            dir.path().to_str().unwrap(),
            "--canvas-id",
            &cid,
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    assert_eq!(v["nodes"].as_array().unwrap().len(), 0);
}

#[test]
fn canvas_rm_with_correct_version_succeeds() {
    let dir = init_vault();
    let c = canvas_new(dir.path(), "ToDelete");
    let cid = c["canvas_id"].as_str().unwrap().to_string();
    let version = c["version"].as_i64().unwrap();
    let out = run(
        &[
            "canvas",
            "rm",
            "--vault",
            dir.path().to_str().unwrap(),
            "--canvas-id",
            &cid,
            "--expected-version",
            &version.to_string(),
        ],
        None,
    );
    assert!(out.status.success(), "stderr: {:?}", String::from_utf8_lossy(&out.stderr));

    // Ls returns empty.
    let out = run(
        &["canvas", "ls", "--vault", dir.path().to_str().unwrap()],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    assert_eq!(v["canvases"].as_array().unwrap().len(), 0);
}

#[test]
fn update_link_via_cli_rewrites_kind_in_body() {
    let dir = init_vault();
    let _target = add_note(dir.path(), "Target", "# Target\n");
    let source = add_note(dir.path(), "Source", "Hello [[Target]] world.");

    // Read the source note to get the link id from the included links map.
    let out = run(
        &[
            "get",
            "--vault",
            dir.path().to_str().unwrap(),
            "--note-id",
            &source,
            "--include-links",
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    let link_id = v["links"]["references"][0]["link_id"]
        .as_str()
        .unwrap()
        .to_string();

    let out = run(
        &[
            "update-link",
            "--vault",
            dir.path().to_str().unwrap(),
            "--link-id",
            &link_id,
            "--kind",
            "extends",
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    assert_eq!(v["kind"].as_str().unwrap(), "extends");

    // Re-read source and confirm body contains the new wikilink.
    let out = run(
        &[
            "get",
            "--vault",
            dir.path().to_str().unwrap(),
            "--note-id",
            &source,
        ],
        None,
    );
    let v: Value = serde_json::from_str(&ok_stdout(out)).unwrap();
    let body = v["content_md"].as_str().unwrap();
    assert!(body.contains("[[Target~extends]]"), "{body:?}");
}
