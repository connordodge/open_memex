//! WI #138 (Spec #123 R16, R15): `memex attach [--vault <path>] <file>
//! [--name <name>]`. Drives the built `memex` binary against temp vaults.
//!
//! - Success: exit 0, one JSON line `{markdown, path, name, size, type}` on
//!   stdout, the file stored under `objects/<h2>/<h>/<name>`, and no note
//!   changed (id, version, text and updated_at of every note kept).
//! - A refused file (R15: over 100 MB, a folder, a FIFO) exits 1 with one C1
//!   line on stderr, `{"error":{"code":"invalid_argument","message":<R15
//!   text>}}`, and stores nothing. Never exit 2: the app reads exit 2 as
//!   "this memex is too old" (`app/lib/src/cli/search_cli.dart:47`).
//! - The CLI is the person's channel: it has no hidden-path limit (R19's
//!   last line), and a symlink attaches the file it points to (R15).
//!
//! The expected `markdown`, `path` and `type` come from memex-core's
//! attachments module, which pins those rules itself; these tests pin that
//! the CLI prints them for the file it stored.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use memex_core::attachments::{markdown_for, mime_for, MAX_ATTACHMENT_BYTES};
use memex_core::notes::{self, CreateNote};
use memex_core::{Caller, Vault};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

/// The longest a refused FIFO may take before the test calls it blocked.
const FIFO_DEADLINE: Duration = Duration::from_secs(30);

// ---------- harness ----------

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Success: exit 0 and exactly one JSON line on stdout; returns it parsed.
fn ok_json(out: &Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "{}", describe(out));
    let stdout = String::from_utf8(out.stdout.clone()).expect("utf8 stdout");
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one JSON line; {}",
        describe(out)
    );
    serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stdout not JSON ({e}); {}", describe(out)))
}

/// Failure: exit 1 (never 2) and exactly one C1 JSON line on stderr.
fn error_json(out: &Output) -> Value {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a refusal exits 1, never 2 (the app reads 2 as too old); {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).expect("utf8 stderr");
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be one line; {}",
        describe(out)
    );
    serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)))
}

/// The R15 refusal's C1 object.
fn refusal(message: &str) -> Value {
    json!({ "error": { "code": "invalid_argument", "message": message } })
}

fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// A temp folder with a vault at `<tmp>/vault` holding one person note, and
/// a `<tmp>/files` folder for the files to attach.
struct World {
    _dir: TempDir,
    root: PathBuf,
    vault: PathBuf,
}

impl World {
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("wi138-cli-")
            .tempdir()
            .unwrap();
        let root = dir.path().to_path_buf();
        let vault = root.join("vault");
        let mut v = Vault::create(&vault).unwrap();
        notes::create_note_as(
            &mut v,
            CreateNote {
                title: Some("Project log".into()),
                content_md: "Screenshots go here.\n".into(),
                frontmatter: None,
            },
            Caller::Person,
        )
        .unwrap();
        drop(v);
        fs::create_dir(root.join("files")).unwrap();
        Self {
            _dir: dir,
            root,
            vault,
        }
    }

    fn vault_arg(&self) -> &str {
        self.vault.to_str().unwrap()
    }

    /// Writes `bytes` to `<tmp>/<rel>`, making its folders.
    fn file(&self, rel: &str, bytes: &[u8]) -> PathBuf {
        let path = self.root.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        path
    }

    /// `memex attach --vault <vault> <file> [extra…]`.
    fn attach(&self, file: &Path, extra: &[&str]) -> Output {
        let mut args = vec![
            "attach",
            "--vault",
            self.vault_arg(),
            file.to_str().unwrap(),
        ];
        args.extend_from_slice(extra);
        run(&args)
    }

    /// Every note as (id, version, content_md, updated_at), by id.
    fn notes(&self) -> Vec<(String, i64, String, i64)> {
        let conn = rusqlite::Connection::open_with_flags(
            self.vault.join("memex.db"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        let mut stmt = conn
            .prepare("SELECT id, version, content_md, updated_at FROM notes ORDER BY id")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap();
        rows.map(Result::unwrap).collect()
    }

    /// Every file under `objects/` (temp files included), vault-relative.
    fn objects(&self) -> Vec<String> {
        let mut out = Vec::new();
        walk(&self.vault.join("objects"), &self.vault, &mut out);
        out.sort();
        out
    }
}

fn walk(dir: &Path, base: &Path, out: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries {
        let path = entry.unwrap().path();
        if path.is_dir() {
            walk(&path, base, out);
        } else {
            out.push(
                path.strip_prefix(base)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
            );
        }
    }
}

/// The `{markdown, path, name, size, type}` the store of `bytes` under the
/// stored name `name` prints.
fn expected(bytes: &[u8], name: &str) -> Value {
    let hash = hex_sha256(bytes);
    json!({
        "markdown": markdown_for(name, &hash),
        "path": format!("objects/{}/{hash}/{name}", &hash[..2]),
        "name": name,
        "size": bytes.len() as u64,
        "type": mime_for(name),
    })
}

/// Asserts `printed` is exactly `expected(bytes, name)` and the vault holds
/// the bytes at its `path`.
fn assert_stored(w: &World, printed: &Value, bytes: &[u8], name: &str) {
    assert_eq!(*printed, expected(bytes, name), "the printed object");
    let path = printed["path"].as_str().unwrap();
    assert_eq!(
        fs::read(w.vault.join(path)).unwrap(),
        bytes,
        "the file at {path} holds the attached bytes"
    );
}

/// A file of `len` bytes that takes no disk space (a hole).
fn sparse(path: &Path, len: u64) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::File::create(path).unwrap().set_len(len).unwrap();
}

// ---------- AC 1: store and print; --name; no note changes ----------

#[test]
fn attach_stores_the_file_and_prints_markdown_path_name_size_type() {
    let w = World::new();
    let before = w.notes();
    assert_eq!(before.len(), 1, "precondition: one note");

    let png: &[u8] = b"\x89PNG\r\n\x1a\nwi138 screenshot pixels";
    let shot = w.file("files/Screenshot 2026-11-18.png", png);
    let out = w.attach(&shot, &[]);
    let printed = ok_json(&out);
    assert_stored(&w, &printed, png, "Screenshot 2026-11-18.png");
    assert!(
        printed["markdown"].as_str().unwrap().starts_with("!["),
        "an image's markdown is an image reference: {printed}"
    );

    let pdf: &[u8] = b"%PDF-1.4 wi138 report";
    let report = w.file("files/report.pdf", pdf);
    let printed = ok_json(&w.attach(&report, &[]));
    assert_stored(&w, &printed, pdf, "report.pdf");

    let unknown: &[u8] = b"\x00\x01wi138 blob";
    let blob = w.file("files/data.wi138blob", unknown);
    let printed = ok_json(&w.attach(&blob, &[]));
    assert_eq!(
        printed["type"],
        json!("application/octet-stream"),
        "{printed}"
    );
    assert_stored(&w, &printed, unknown, "data.wi138blob");

    assert_eq!(w.notes(), before, "no note's version or text changed");
}

#[test]
fn attach_with_name_sets_the_stored_name() {
    let w = World::new();
    let before = w.notes();
    let bytes: &[u8] = b"%PDF-1.4 quarterly numbers";
    let src = w.file("files/export-7f3a.pdf", bytes);

    let printed = ok_json(&w.attach(&src, &["--name", "Q3 report.pdf"]));

    assert_stored(&w, &printed, bytes, "Q3 report.pdf");
    let hash = hex_sha256(bytes);
    assert_eq!(
        printed["markdown"],
        json!(format!(
            "[Q3 report.pdf](objects/{}/{hash}/Q3%20report.pdf)",
            &hash[..2]
        )),
        "{printed}"
    );
    assert_eq!(printed["type"], json!("application/pdf"));
    assert_eq!(w.notes(), before, "no note changed");
}

#[test]
fn attach_follows_a_symlink_and_has_no_hidden_path_limit() {
    let w = World::new();
    // The person's channel: a hidden file and a link into a hidden folder
    // both attach (R19 limits only MCP).
    let secret: &[u8] = b"wi138 person-owned hidden notes";
    let hidden = w.file(".private/plan.txt", secret);
    let printed = ok_json(&w.attach(&hidden, &[]));
    assert_stored(&w, &printed, secret, "plan.txt");

    let link = w.root.join("files/plan-link.txt");
    std::os::unix::fs::symlink(&hidden, &link).unwrap();
    let printed = ok_json(&w.attach(&link, &["--name", "plan copy.txt"]));
    assert_stored(&w, &printed, secret, "plan copy.txt");
}

// ---------- AC 2: refusals (R15), exit 1, C1 JSON, nothing stored ----------

#[test]
fn attach_of_a_file_over_100_mb_exits_1_with_the_r15_text_and_stores_nothing() {
    let w = World::new();
    let before = w.notes();
    let big = w.root.join("files/big.bin");
    sparse(&big, MAX_ATTACHMENT_BYTES + 1);

    let out = w.attach(&big, &[]);

    assert_eq!(
        error_json(&out),
        refusal("big.bin is larger than 100 MB and wasn't attached.")
    );
    assert!(
        out.stdout.is_empty(),
        "nothing printed on stdout; {}",
        describe(&out)
    );
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
    assert_eq!(w.notes(), before);
}

#[test]
fn attach_of_exactly_100_mb_is_stored() {
    let w = World::new();
    let edge = w.root.join("files/edge.bin");
    sparse(&edge, MAX_ATTACHMENT_BYTES);

    let printed = ok_json(&w.attach(&edge, &[]));

    assert_eq!(printed["size"], json!(MAX_ATTACHMENT_BYTES), "{printed}");
    assert_eq!(printed["name"], json!("edge.bin"));
    let path = printed["path"].as_str().unwrap();
    assert_eq!(
        fs::metadata(w.vault.join(path)).unwrap().len(),
        MAX_ATTACHMENT_BYTES,
        "the stored file is 104,857,600 bytes"
    );
}

#[test]
fn attach_of_a_folder_exits_1_with_the_r15_text_and_stores_nothing() {
    let w = World::new();
    let folder = w.root.join("files/Screenshots");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("inside.png"), b"\x89PNG inside").unwrap();

    let out = w.attach(&folder, &[]);

    assert_eq!(error_json(&out), refusal("Folders can't be attached."));
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
}

#[test]
fn attach_of_a_fifo_exits_1_with_the_r15_text_without_blocking() {
    let w = World::new();
    let fifo = w.root.join("files/pipe");
    let made = Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .expect("run mkfifo");
    assert!(made.success(), "mkfifo {}", fifo.display());

    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["attach", "--vault", w.vault_arg(), fifo.to_str().unwrap()])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex attach");
    let started = Instant::now();
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if started.elapsed() > FIFO_DEADLINE {
            child.kill().ok();
            child.wait().ok();
            // Unblock nothing further: the child is gone.
            panic!("memex attach of a FIFO still running after {FIFO_DEADLINE:?}: it blocked");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let out = child.wait_with_output().unwrap();

    assert_eq!(
        error_json(&out),
        refusal("pipe isn't a regular file and wasn't attached.")
    );
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
}

#[test]
fn attach_of_a_missing_file_exits_1_with_c1_json_not_2() {
    let w = World::new();
    let missing = w.root.join("files/never-written.png");

    let out = w.attach(&missing, &[]);

    let err = error_json(&out);
    assert!(
        err["error"]["code"].is_string() && err["error"]["message"].is_string(),
        "a C1 object: {err}"
    );
    assert_eq!(w.objects(), Vec::<String>::new(), "nothing stored");
}

#[test]
fn attach_stores_a_pasted_image_temp_file_under_the_given_name() {
    // R16's last line: the app stores a pasted image by running
    // `memex attach <temp file> --name "<R9 name>"`; options may follow the
    // file.
    let w = World::new();
    let bytes: &[u8] = b"\x89PNG\r\n\x1a\npasted pixels";
    let tmp = w.file("files/paste-7c2e.tmp", bytes);
    let out = run(&[
        "attach",
        tmp.to_str().unwrap(),
        "--name",
        "Pasted image 2026-11-18 at 09.41.07.png",
        "--vault",
        w.vault_arg(),
    ]);

    let printed = ok_json(&out);
    assert_stored(
        &w,
        &printed,
        bytes,
        "Pasted image 2026-11-18 at 09.41.07.png",
    );
    assert!(
        printed["markdown"].as_str().unwrap().starts_with("!["),
        "{printed}"
    );
}

#[test]
fn attach_to_a_folder_that_is_not_a_vault_exits_1_and_creates_no_objects() {
    // `attach` opens the vault before it stores anything, so a stray folder
    // is not turned into a vault by a file landing in `objects/`.
    let w = World::new();
    let bytes: &[u8] = b"wi138 stray";
    let file = w.file("files/stray.txt", bytes);
    let stray = w.root.join("not-a-vault");
    fs::create_dir(&stray).unwrap();

    let out = run(&[
        "attach",
        "--vault",
        stray.to_str().unwrap(),
        file.to_str().unwrap(),
    ]);

    let err = error_json(&out);
    assert!(
        err["error"]["code"].is_string() && err["error"]["message"].is_string(),
        "a C1 object: {err}"
    );
    assert!(
        !stray.join("objects").exists(),
        "nothing was stored in a folder that is not a vault"
    );
}
