//! WI #136 (Spec #123 R17, R43, R44; TDs "Extraction at store time,
//! isolated" and "No vault lease during heavy work"): attachment text
//! extraction in a child process, wired into the three store routes.
//!
//! - The hidden `memex extract-attachment <file>` subcommand prints a
//!   file's text, or exits non-zero with the reason on stderr. It is not
//!   listed in `--help`.
//! - `ChildExtractor` runs it (or a test child) under a time limit: a
//!   timeout, a crash, a non-zero exit or a program that can't start is
//!   `Outcome::Failed`, the caller keeps running, and only the child it
//!   started is killed and reaped.
//! - `memex attach` (in process), MCP `add_attachment` and the server
//!   upload (both through the child) leave an `attachments` row with its
//!   `extract_state` set when they return; the file is stored whatever the
//!   extraction does. A file already extracted is never extracted again,
//!   from any route. A note save never extracts. The server answers other
//!   requests on the vault while a child runs.
//! - `notices.sh` passes with pdf-extract linked.
//!
//! Test children are `/bin/sh -c <script>`, so `$1` is the file. Waits are
//! on events (a marker file, a child's exit) with a deadline, never a fixed
//! sleep in the test. The fixtures are memex-core's
//! (`tests/fixtures/attachments/`, made by its `generate.py`).

#[path = "support/server.rs"]
mod server;

use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use memex_core::attachments::{store_bytes, StoredAttachment};
use memex_core::attachments_extract::Outcome;
use memex_core::Vault;
use memex_mcp::attachment_extract_child::{
    extract_and_record, extract_and_record_blocking, ChildExtractor, MAX_CHILDREN, SUBCOMMAND,
    TIME_LIMIT,
};
use memex_mcp::server::{router, ServerConfig};
use memex_mcp::state::AppState;
use memex_mcp::tools::Memex;
use rmcp::model::{CallToolRequestParams, ClientCapabilities, ClientInfo, Implementation};
use rmcp::service::RunningService;
use rmcp::{RoleClient, ServiceExt};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use server::{client, make_vault, Reply, TEST_TOKEN, WAIT};

/// The served vault of every server test.
const VAULT: &str = "v";
const BASE: &str = "/vaults/v/api/v1";

/// The words of the text-layer fixture.
const PDF_TITLE: &str = "Quarterly zebra migration report";
const PDF_LINE: &str = "Striped kelp forests drift north";

/// The time limit given to test children that must hit it.
const SHORT_LIMIT: Duration = Duration::from_millis(500);
/// How long a test child that sleeps would run if nobody killed it.
const SLEEP_SECS: u32 = 30;
/// The longest an MCP call may take before the test fails.
const CALL_TIMEOUT: Duration = Duration::from_secs(120);

// ---------------------------------------------------------------- fixtures and files

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../memex-core/tests/fixtures/attachments")
        .join(name)
}

fn fixture_bytes(name: &str) -> Vec<u8> {
    fs::read(fixture(name)).unwrap_or_else(|e| panic!("read fixture {name}: {e}"))
}

/// A temp folder with no hidden component (`add_attachment` refuses hidden
/// paths; `tempfile`'s default prefix is `.tmp`).
fn visible_tempdir(prefix: &str) -> TempDir {
    tempfile::Builder::new().prefix(prefix).tempdir().unwrap()
}

/// `<dir>/<name>` holding `bytes`.
fn write_file(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, bytes).unwrap();
    path
}

fn memex() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_memex"))
}

fn run_memex(args: &[&str]) -> Output {
    Command::new(memex())
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

/// `path` single-quoted for a `/bin/sh` script.
fn q(path: &Path) -> String {
    let s = path.to_str().expect("utf8 path");
    assert!(!s.contains('\''), "a test path has no quote: {s}");
    format!("'{s}'")
}

/// The extractor that runs `/bin/sh -c <script> extract-attachment <file>`.
fn sh(script: &str) -> ChildExtractor {
    ChildExtractor::new("/bin/sh").with_args(["-c", script])
}

/// The built `memex` as the extraction child.
fn memex_child() -> ChildExtractor {
    ChildExtractor::new(memex())
}

/// A child that writes its pid to `pid_file`, then sleeps far past
/// [`SHORT_LIMIT`] as that same process.
fn sleeper(pid_file: &Path) -> ChildExtractor {
    sh(&format!(
        "echo $$ > {}; exec sleep {SLEEP_SECS}",
        q(pid_file)
    ))
    .with_time_limit(SHORT_LIMIT)
}

/// A child that dies of SIGABRT.
fn crasher() -> ChildExtractor {
    sh("kill -ABRT $$")
}

/// A child that prints some text, then fails with `wi136-boom` on stderr.
fn failer() -> ChildExtractor {
    sh("echo partial zebra text; echo wi136-boom >&2; exit 3")
}

/// A child that appends a line to `count_file` each time it runs, then
/// prints `counted zebra text`.
fn counter(count_file: &Path) -> ChildExtractor {
    sh(&format!(
        "echo run >> {}; printf 'counted zebra text'",
        q(count_file)
    ))
}

fn runs(count_file: &Path) -> usize {
    fs::read_to_string(count_file)
        .map(|s| s.lines().count())
        .unwrap_or(0)
}

/// Waits until `done()` holds, polling, for at most `limit`.
async fn wait_until(limit: Duration, done: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if done() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    done()
}

/// Whether process `pid` still exists (a zombie counts as existing).
fn process_exists(pid: &str) -> bool {
    Command::new("/bin/kill")
        .args(["-0", pid])
        .stderr(Stdio::null())
        .status()
        .expect("run kill -0")
        .success()
}

// ---------------------------------------------------------------- the index rows

#[derive(Debug, Clone, PartialEq)]
struct Row {
    state: String,
    error: Option<String>,
    extracted_at: Option<i64>,
}

/// The `attachments` row of `path` in the vault at `vault` (its own
/// connection, as another process would read it).
fn row(vault: &Path, path: &str) -> Option<Row> {
    let v = Vault::open(vault).unwrap();
    v.connection_ref()
        .query_row(
            "SELECT extract_state, extract_error, extracted_at FROM attachments WHERE path = ?",
            params![path],
            |r| {
                Ok(Row {
                    state: r.get(0)?,
                    error: r.get(1)?,
                    extracted_at: r.get(2)?,
                })
            },
        )
        .optional()
        .unwrap()
}

/// The FTS paths matching `query`.
fn fts_match(vault: &Path, query: &str) -> Vec<String> {
    let v = Vault::open(vault).unwrap();
    let mut stmt = v
        .connection_ref()
        .prepare("SELECT path FROM attachment_chunk_fts WHERE attachment_chunk_fts MATCH ?")
        .unwrap();
    stmt.query_map(params![query], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

fn chunk_count(vault: &Path, path: &str) -> i64 {
    let v = Vault::open(vault).unwrap();
    v.connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM attachment_chunks WHERE path = ?",
            params![path],
            |r| r.get(0),
        )
        .unwrap()
}

fn attachments_rows(vault: &Path) -> i64 {
    let v = Vault::open(vault).unwrap();
    v.connection_ref()
        .query_row("SELECT COUNT(*) FROM attachments", [], |r| r.get(0))
        .unwrap()
}

/// Asserts `path` has a `done` row whose text holds the PDF fixture's words.
fn assert_pdf_done(vault: &Path, path: &str) {
    let r = row(vault, path).unwrap_or_else(|| panic!("{path} has an attachments row"));
    assert_eq!(r.state, "done", "{path}: {r:?}");
    assert_eq!(r.error, None);
    assert!(r.extracted_at.is_some(), "{path}: extracted_at is set");
    assert!(chunk_count(vault, path) >= 1);
    assert_eq!(fts_match(vault, "zebra"), vec![path.to_string()]);
    assert_eq!(fts_match(vault, "kelp"), vec![path.to_string()]);
}

/// Asserts `path` has a `failed` row with an error, no chunks, and that
/// the stored file is `bytes`.
fn assert_failed_and_stored(vault: &Path, path: &str, bytes: &[u8]) -> String {
    let r = row(vault, path).unwrap_or_else(|| panic!("{path} has an attachments row"));
    assert_eq!(r.state, "failed", "{path}: {r:?}");
    assert!(r.extracted_at.is_some(), "{path}: extracted_at is set");
    let error = r.error.unwrap_or_default();
    assert!(
        !error.trim().is_empty(),
        "{path}: failed has an extract_error"
    );
    assert_eq!(chunk_count(vault, path), 0);
    assert_eq!(
        fs::read(vault.join(path)).unwrap(),
        bytes,
        "the file stays stored"
    );
    error
}

/// The stored path `bytes` as the plain name `name` get (R1, #134).
fn object_path(bytes: &[u8], name: &str) -> String {
    let hash: String = Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("objects/{}/{hash}/{name}", &hash[..2])
}

// ---------------------------------------------------------------- the hidden subcommand

#[test]
fn hidden_subcommand_prints_the_text_layer_of_a_pdf() {
    let dir = visible_tempdir("wi136-sub-");
    let file = write_file(dir.path(), "report.pdf", &fixture_bytes("text-layer.pdf"));
    let out = run_memex(&[SUBCOMMAND, file.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains(PDF_TITLE), "{}", describe(&out));
    assert!(text.contains(PDF_LINE), "{}", describe(&out));
}

#[test]
fn hidden_subcommand_prints_text_files_decoded_with_invalid_bytes_replaced() {
    let dir = visible_tempdir("wi136-sub-");
    let bytes = fixture_bytes("invalid-utf8.txt");
    let want = String::from_utf8_lossy(&bytes).into_owned();
    for name in ["notes.txt", "notes.CSV"] {
        let file = write_file(dir.path(), name, &bytes);
        let out = run_memex(&[SUBCOMMAND, file.to_str().unwrap()]);
        assert_eq!(out.status.code(), Some(0), "{name}: {}", describe(&out));
        // A trailing newline from the child is allowed.
        assert_eq!(
            String::from_utf8(out.stdout.clone())
                .expect("the child prints UTF-8")
                .trim_end(),
            want.trim_end(),
            "{name}"
        );
    }
}

#[test]
fn hidden_subcommand_prints_no_text_for_an_image_only_pdf() {
    let dir = visible_tempdir("wi136-sub-");
    let file = write_file(dir.path(), "scan.pdf", &fixture_bytes("image-only.pdf"));
    let out = run_memex(&[SUBCOMMAND, file.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(
        String::from_utf8_lossy(&out.stdout).trim().is_empty(),
        "{}",
        describe(&out)
    );
}

#[test]
fn hidden_subcommand_fails_with_a_reason_on_a_corrupt_pdf() {
    let dir = visible_tempdir("wi136-sub-");
    let file = write_file(dir.path(), "broken.pdf", &fixture_bytes("corrupt.pdf"));
    let out = run_memex(&[SUBCOMMAND, file.to_str().unwrap()]);
    let code = out.status.code();
    assert!(code.is_some_and(|c| c != 0), "{}", describe(&out));
    // Exit 2 is clap's usage error (and the app's "memex is too old").
    assert_ne!(code, Some(2), "not a usage error: {}", describe(&out));
    assert!(
        !String::from_utf8_lossy(&out.stderr).trim().is_empty(),
        "the reason is on stderr: {}",
        describe(&out)
    );
}

#[test]
fn hidden_subcommand_runs_but_is_not_listed_in_help() {
    let dir = visible_tempdir("wi136-sub-");
    let file = write_file(dir.path(), "a.txt", b"zebra");
    let out = run_memex(&[SUBCOMMAND, file.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim_end(), "zebra");

    let help = run_memex(&["--help"]);
    assert_eq!(help.status.code(), Some(0), "{}", describe(&help));
    let listing = String::from_utf8_lossy(&help.stdout);
    assert!(listing.contains("attach"), "help lists commands: {listing}");
    assert!(!listing.contains(SUBCOMMAND), "hidden: {listing}");
}

// ---------------------------------------------------------------- the runner

#[test]
fn runner_time_limit_is_20_seconds_by_default() {
    assert_eq!(TIME_LIMIT, Duration::from_secs(20), "TD: a 20 s limit");
    assert_eq!(memex_child().time_limit(), Duration::from_secs(20));
    let own = ChildExtractor::current_exe().expect("current_exe");
    assert_eq!(
        own.program(),
        std::env::current_exe().unwrap().as_path(),
        "the running binary is the default child"
    );
    assert_eq!(own.time_limit(), Duration::from_secs(20));
}

#[test]
fn runner_extracts_a_pdf_through_the_memex_child() {
    let dir = visible_tempdir("wi136-run-");
    let file = write_file(dir.path(), "report.pdf", &fixture_bytes("text-layer.pdf"));
    let outcome = memex_child().run(&file);
    let Outcome::Text(text) = &outcome else {
        panic!("the memex child extracts the text layer: {outcome:?}");
    };
    assert!(text.contains(PDF_TITLE), "{text:?}");
    assert!(text.contains(PDF_LINE), "{text:?}");

    let broken = write_file(dir.path(), "broken.pdf", &fixture_bytes("corrupt.pdf"));
    let outcome = memex_child().run(&broken);
    assert!(
        matches!(&outcome, Outcome::Failed(e) if !e.trim().is_empty()),
        "a corrupt PDF fails in the child: {outcome:?}"
    );
}

#[test]
fn runner_passes_the_file_to_the_child_and_reads_a_large_output() {
    let dir = visible_tempdir("wi136-run-");
    // 2,000,000 bytes on stdout: far past any pipe buffer.
    let file = write_file(dir.path(), "big.pdf", b"%PDF-1.4");
    let outcome = sh("test -f \"$1\" || exit 9; yes zebra | head -c 2000000").run(&file);
    let Outcome::Text(text) = &outcome else {
        panic!("a large output is read while the child runs: {outcome:?}");
    };
    assert!(
        text.starts_with("zebra\nzebra\n"),
        "{:?}",
        &text[..text.len().min(40)]
    );
    assert!(
        text.chars().count() >= 200_000,
        "{} chars",
        text.chars().count()
    );
}

#[test]
fn runner_records_failed_when_the_child_exceeds_the_time_limit() {
    let dir = visible_tempdir("wi136-run-");
    let file = write_file(dir.path(), "slow.pdf", b"%PDF-1.4");
    let pid_file = dir.path().join("child.pid");
    // A process this test started, which the runner must leave alone.
    let mut bystander: Child = Command::new("/bin/sleep")
        .arg(SLEEP_SECS.to_string())
        .spawn()
        .expect("start bystander");

    let started = Instant::now();
    let outcome = sleeper(&pid_file).run(&file);
    let took = started.elapsed();

    let bystander_alive = bystander.try_wait().expect("try_wait").is_none();
    let _ = bystander.kill();
    let _ = bystander.wait();

    assert!(
        matches!(&outcome, Outcome::Failed(e) if !e.trim().is_empty()),
        "a child past its limit is Failed: {outcome:?}"
    );
    assert!(
        took < Duration::from_secs(SLEEP_SECS as u64 / 2),
        "the runner stopped the child at its limit, not when it ended: {took:?}"
    );
    let pid = fs::read_to_string(&pid_file).expect("the child wrote its pid");
    let pid = pid.trim();
    assert!(
        !process_exists(pid),
        "the child {pid} was killed and reaped (no zombie)"
    );
    assert!(bystander_alive, "only the child it started was killed");
}

#[test]
fn runner_records_failed_when_the_child_crashes() {
    let dir = visible_tempdir("wi136-run-");
    let file = write_file(dir.path(), "crash.pdf", b"%PDF-1.4");
    let outcome = crasher().run(&file);
    assert!(
        matches!(&outcome, Outcome::Failed(e) if !e.trim().is_empty()),
        "a child killed by a signal is Failed: {outcome:?}"
    );
}

#[test]
fn runner_records_failed_with_stderr_when_the_child_exits_non_zero() {
    let dir = visible_tempdir("wi136-run-");
    let file = write_file(dir.path(), "bad.pdf", b"%PDF-1.4");
    let outcome = failer().run(&file);
    let Outcome::Failed(error) = &outcome else {
        panic!("a non-zero exit is Failed even after printing text: {outcome:?}");
    };
    assert!(
        error.contains("wi136-boom"),
        "the error is the child's stderr: {error:?}"
    );
}

#[test]
fn runner_records_failed_when_the_program_cannot_start() {
    let dir = visible_tempdir("wi136-run-");
    let file = write_file(dir.path(), "x.pdf", b"%PDF-1.4");
    let outcome = ChildExtractor::new(dir.path().join("no-such-memex")).run(&file);
    assert!(
        matches!(&outcome, Outcome::Failed(e) if !e.trim().is_empty()),
        "a child that can't start is Failed: {outcome:?}"
    );
}

/// A four-byte character (U+10348).
const FOUR_BYTES: &str = "\u{10348}";

fn failure_of(outcome: Outcome) -> String {
    match outcome {
        Outcome::Failed(e) => e,
        Outcome::Text(t) => panic!("expected Failed, got Text({t:?})"),
    }
}

#[test]
fn runner_failure_messages_name_the_cause() {
    let dir = visible_tempdir("wi136-msg-");
    let file = write_file(dir.path(), "x.pdf", b"%PDF-1.4");

    // A non-zero exit with nothing on stderr names the status.
    let error = failure_of(sh("exit 7").run(&file));
    assert!(error.contains("status 7"), "{error:?}");

    // A non-zero exit with stderr gives that text, trimmed, and nothing else.
    let error = failure_of(sh("printf '  spaced boom \\n\\n' >&2; exit 4").run(&file));
    assert_eq!(error, "spaced boom");

    // A crash says so, with and without stderr.
    let error = failure_of(crasher().run(&file));
    assert!(error.contains("crashed"), "{error:?}");
    let error = failure_of(sh("echo wi136-sig >&2; kill -ABRT $$").run(&file));
    assert!(error.contains("crashed"), "{error:?}");
    assert!(error.contains("wi136-sig"), "{error:?}");

    // A timeout names the limit; a program that can't start names itself.
    let pid_file = dir.path().join("child.pid");
    let error = failure_of(sleeper(&pid_file).run(&file));
    assert!(error.contains("longer than 0.5 s"), "{error:?}");
    let missing = dir.path().join("no-such-memex");
    let error = failure_of(ChildExtractor::new(&missing).run(&file));
    assert!(error.contains("could not start"), "{error:?}");
    assert!(error.contains("no-such-memex"), "{error:?}");
}

#[test]
fn runner_keeps_the_first_200000_characters_of_a_large_output_of_four_byte_characters() {
    let dir = visible_tempdir("wi136-cap-");
    // The child prints the file: one ASCII byte, then far more four-byte
    // characters than the cap, so the byte offsets are not multiples of
    // four.
    let body = format!("a{}", FOUR_BYTES.repeat(250_000));
    let file = write_file(dir.path(), "big.pdf", body.as_bytes());
    let outcome = sh("cat \"$1\"").run(&file);
    let Outcome::Text(text) = outcome else {
        panic!("a large output is text: {outcome:?}");
    };
    assert_eq!(text.chars().count(), 200_000);
    assert_eq!(text, format!("a{}", FOUR_BYTES.repeat(199_999)));

    // The output of fewer characters is kept whole.
    let small = write_file(dir.path(), "small.pdf", "zebr\u{e4}".as_bytes());
    assert_eq!(
        sh("cat \"$1\"").run(&small),
        Outcome::Text("zebr\u{e4}".to_string())
    );
}

#[test]
fn runner_keeps_at_most_4096_bytes_of_stderr() {
    let dir = visible_tempdir("wi136-cap-");
    let file = write_file(dir.path(), "x.pdf", b"%PDF-1.4");
    let error = failure_of(sh("head -c 10000 /dev/zero | tr '\\0' 'e' >&2; exit 1").run(&file));
    assert_eq!(error, "e".repeat(4096));
}

#[test]
fn runner_does_not_wait_for_a_grandchild_that_keeps_the_pipes_open() {
    let dir = visible_tempdir("wi136-drain-");
    let file = write_file(dir.path(), "x.pdf", b"%PDF-1.4");
    let started = Instant::now();
    // The child ends at once, but its background sleep holds both pipes.
    let outcome = sh("sleep 8 & echo hi").run(&file);
    let took = started.elapsed();
    assert!(
        took < Duration::from_secs(7),
        "the runner gave up on the open pipes: {took:?}"
    );
    // Its output may be cut short, so it is not recorded as a final `done`
    // or `empty`: it is a failure that says so.
    let error = failure_of(outcome);
    assert!(
        error.contains("output did not end within 2 s"),
        "a drain timeout after a clean exit is `failed`: {error:?}"
    );
}

#[test]
fn hidden_subcommand_prints_at_most_the_first_200000_characters() {
    let dir = visible_tempdir("wi136-sub-");
    let body = format!("a{}", FOUR_BYTES.repeat(250_000));
    let file = write_file(dir.path(), "big.txt", body.as_bytes());
    let out = run_memex(&[SUBCOMMAND, file.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0), "exit status");
    assert_eq!(
        String::from_utf8(out.stdout).expect("UTF-8"),
        format!("a{}", FOUR_BYTES.repeat(199_999))
    );
}

// ---------------------------------------------------------------- memex attach (in process)

fn new_vault(dir: &Path) -> PathBuf {
    let vault = dir.join("vault");
    drop(Vault::create(&vault).unwrap());
    vault
}

/// `memex attach --vault <vault> <file>`: exit 0 and its JSON line.
fn attach(vault: &Path, file: &Path) -> Value {
    let out = run_memex(&[
        "attach",
        "--vault",
        vault.to_str().unwrap(),
        file.to_str().unwrap(),
    ]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    let stdout = String::from_utf8(out.stdout.clone()).unwrap();
    serde_json::from_str(stdout.trim()).unwrap_or_else(|e| panic!("{e}: {}", describe(&out)))
}

#[test]
fn memex_attach_records_done_for_a_text_layer_pdf() {
    let dir = visible_tempdir("wi136-cli-");
    let vault = new_vault(dir.path());
    let file = write_file(
        dir.path(),
        "Q3 report.pdf",
        &fixture_bytes("text-layer.pdf"),
    );
    let stored = attach(&vault, &file);
    assert_pdf_done(&vault, stored["path"].as_str().unwrap());
}

#[test]
fn memex_attach_records_empty_for_an_image_only_pdf_and_a_png() {
    let dir = visible_tempdir("wi136-cli-");
    let vault = new_vault(dir.path());
    for (name, bytes) in [
        ("scan.pdf", fixture_bytes("image-only.pdf")),
        ("photo.png", b"\x89PNG\r\n\x1a\nzebra words".to_vec()),
    ] {
        let file = write_file(dir.path(), name, &bytes);
        let stored = attach(&vault, &file);
        let path = stored["path"].as_str().unwrap();
        let r = row(&vault, path).unwrap_or_else(|| panic!("{name}: a row"));
        assert_eq!(r.state, "empty", "{name}");
        assert_eq!(chunk_count(&vault, path), 0, "{name}");
    }
}

#[test]
fn memex_attach_records_failed_for_a_corrupt_pdf_and_still_attaches() {
    let dir = visible_tempdir("wi136-cli-");
    let vault = new_vault(dir.path());
    let bytes = fixture_bytes("corrupt.pdf");
    let file = write_file(dir.path(), "broken.pdf", &bytes);
    let stored = attach(&vault, &file);
    assert_eq!(stored["name"], json!("broken.pdf"));
    assert_failed_and_stored(&vault, stored["path"].as_str().unwrap(), &bytes);
}

#[test]
fn memex_attach_of_the_same_file_again_keeps_extracted_at() {
    let dir = visible_tempdir("wi136-cli-");
    let vault = new_vault(dir.path());
    let file = write_file(dir.path(), "report.pdf", &fixture_bytes("text-layer.pdf"));
    let first = attach(&vault, &file);
    let path = first["path"].as_str().unwrap().to_string();
    let before = row(&vault, &path).expect("a row after the first attach");
    let chunks = chunk_count(&vault, &path);
    assert_eq!(before.state, "done");

    let second = attach(&vault, &file);
    assert_eq!(second, first, "the same file stores to the same place");
    assert_eq!(row(&vault, &path), Some(before), "extracted once");
    assert_eq!(chunk_count(&vault, &path), chunks);
    assert_eq!(attachments_rows(&vault), 1);
}

// ---------------------------------------------------------------- MCP add_attachment (child)

/// `Memex::new` over an rmcp duplex for the vault at `<tmp>/vault`, with
/// `extractor` as its extraction child.
struct Local {
    dir: TempDir,
    vault: PathBuf,
    client: RunningService<RoleClient, ClientInfo>,
    server: JoinHandle<()>,
}

impl Drop for Local {
    fn drop(&mut self) {
        self.server.abort();
    }
}

async fn local(extractor: ChildExtractor) -> Local {
    let dir = visible_tempdir("wi136-mcp-");
    let vault = new_vault(dir.path());
    let state =
        AppState::new(Vault::open(&vault).unwrap(), vault.clone(), None).with_extractor(extractor);
    let memex = Memex::new(Arc::new(state));
    let (server_io, client_io) = tokio::io::duplex(1 << 20);
    let server = tokio::spawn(async move {
        if let Ok(running) = memex.serve(server_io).await {
            let _ = running.waiting().await;
        }
    });
    let client = ClientInfo::new(
        ClientCapabilities::default(),
        Implementation::new("wi136-test", "1.0.0"),
    )
    .serve(client_io)
    .await
    .expect("initialize handshake");
    Local {
        dir,
        vault,
        client,
        server,
    }
}

impl Local {
    /// Calls `tool`; returns its text payload parsed as JSON.
    async fn call(&self, tool: &str, args: Value) -> Value {
        let Value::Object(arguments) = args else {
            panic!("tool arguments are an object");
        };
        let call = self
            .client
            .call_tool(CallToolRequestParams::new(tool.to_string()).with_arguments(arguments));
        let result = tokio::time::timeout(CALL_TIMEOUT, call)
            .await
            .unwrap_or_else(|_| panic!("{tool}: no answer within {CALL_TIMEOUT:?}"))
            .unwrap_or_else(|e| panic!("{tool}: {e}"));
        let result = serde_json::to_value(result).unwrap();
        assert_ne!(result["isError"], json!(true), "{tool} failed: {result}");
        let text = result["content"][0]["text"].as_str().unwrap_or_default();
        let v: Value =
            serde_json::from_str(text).unwrap_or_else(|e| panic!("{tool}: not JSON ({e}): {text}"));
        assert!(v.get("error").is_none(), "{tool} failed: {v}");
        v
    }

    async fn add_path(&self, file: &Path) -> Value {
        self.call(
            "add_attachment",
            json!({ "file_path": file.to_str().unwrap() }),
        )
        .await
    }

    async fn add_data(&self, bytes: &[u8], name: &str) -> Value {
        let data = base64::engine::general_purpose::STANDARD.encode(bytes);
        self.call("add_attachment", json!({ "data": data, "name": name }))
            .await
    }

    fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let files = self.dir.path().join("files");
        fs::create_dir_all(&files).unwrap();
        write_file(&files, name, bytes)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_attachment_records_extract_state_before_it_returns() {
    let mcp = local(memex_child()).await;

    let pdf = mcp.file("report.pdf", &fixture_bytes("text-layer.pdf"));
    let stored = mcp.add_path(&pdf).await;
    assert_pdf_done(&mcp.vault, stored["path"].as_str().unwrap());

    let stored = mcp
        .add_data(b"Walrus tundra ledger notes.", "notes.md")
        .await;
    let path = stored["path"].as_str().unwrap();
    assert_eq!(row(&mcp.vault, path).expect("a row").state, "done");
    assert_eq!(fts_match(&mcp.vault, "tundra"), vec![path.to_string()]);

    let stored = mcp.add_data(b"\x89PNG\r\n\x1a\n", "photo.png").await;
    let path = stored["path"].as_str().unwrap();
    assert_eq!(row(&mcp.vault, path).expect("a row").state, "empty");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_attachment_records_failed_when_the_child_crashes_and_still_attaches() {
    let mcp = local(crasher()).await;
    let bytes = fixture_bytes("text-layer.pdf");
    let stored = mcp.add_data(&bytes, "report.pdf").await;
    assert_eq!(stored["name"], json!("report.pdf"));
    assert_eq!(stored["size"], json!(bytes.len()));
    assert_failed_and_stored(&mcp.vault, stored["path"].as_str().unwrap(), &bytes);

    // The server process kept running: the next call is answered.
    let again = mcp.add_data(b"second file", "second.pdf").await;
    assert_failed_and_stored(&mcp.vault, again["path"].as_str().unwrap(), b"second file");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_attachment_records_failed_when_the_child_exits_non_zero() {
    let mcp = local(failer()).await;
    let bytes = fixture_bytes("text-layer.pdf");
    let stored = mcp.add_data(&bytes, "report.pdf").await;
    let error = assert_failed_and_stored(&mcp.vault, stored["path"].as_str().unwrap(), &bytes);
    assert!(error.contains("wi136-boom"), "{error:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_attachment_of_a_file_already_extracted_runs_no_child() {
    let count = visible_tempdir("wi136-count-");
    let count_file = count.path().join("runs");
    let mcp = local(counter(&count_file)).await;
    let bytes = fixture_bytes("text-layer.pdf");

    // Another route extracted these bytes and name first (in process).
    let file = mcp.file("report.pdf", &bytes);
    let by_cli = attach(&mcp.vault, &file);
    let path = by_cli["path"].as_str().unwrap().to_string();
    let before = row(&mcp.vault, &path).expect("the CLI recorded a row");

    let by_data = mcp.add_data(&bytes, "report.pdf").await;
    assert_eq!(by_data["path"], json!(path));
    let by_path = mcp.add_path(&file).await;
    assert_eq!(by_path["path"], json!(path));

    assert_eq!(
        runs(&count_file),
        0,
        "no child ran for a file already extracted"
    );
    assert_eq!(
        row(&mcp.vault, &path),
        Some(before),
        "extracted_at unchanged"
    );

    // A new file runs the child exactly once, however often it is stored.
    let fresh = mcp.add_data(b"%PDF-1.4 fresh", "fresh.pdf").await;
    mcp.add_data(b"%PDF-1.4 fresh", "fresh.pdf").await;
    let fresh_path = fresh["path"].as_str().unwrap();
    assert_eq!(runs(&count_file), 1, "extracted once");
    assert_eq!(row(&mcp.vault, fresh_path).unwrap().state, "done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_attachment_runs_the_child_only_for_a_type_with_text() {
    let count = visible_tempdir("wi136-count-");
    let count_file = count.path().join("runs");
    let mcp = local(counter(&count_file)).await;

    for name in ["photo.png", "bundle.zip", "slides.pptx", "Makefile"] {
        let stored = mcp
            .add_data(format!("bytes of {name}").as_bytes(), name)
            .await;
        let path = stored["path"].as_str().unwrap();
        assert_eq!(
            row(&mcp.vault, path).expect("a row").state,
            "empty",
            "{name}"
        );
        assert_eq!(runs(&count_file), 0, "{name}: no child for no text");
    }
    let mut want = 0;
    for name in ["a.pdf", "b.TXT", "c.md", "d.Csv", "e.json"] {
        let stored = mcp
            .add_data(format!("bytes of {name}").as_bytes(), name)
            .await;
        want += 1;
        assert_eq!(runs(&count_file), want, "{name}: one child");
        let path = stored["path"].as_str().unwrap();
        assert_eq!(
            row(&mcp.vault, path).expect("a row").state,
            "done",
            "{name}"
        );
    }
}

/// A `memex serve --vault <vault>` subprocess (the person's own machine:
/// no extractor is configured, so the running `memex` is the child), spoken
/// to over newline-delimited JSON-RPC.
struct StdioServer {
    child: Child,
    stdin: std::process::ChildStdin,
    lines: std::sync::mpsc::Receiver<String>,
}

impl StdioServer {
    fn start(vault: &Path) -> Self {
        use std::io::{BufRead, BufReader};
        let mut child = Command::new(memex())
            .args(["serve", "--vault", vault.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut server = Self {
            child,
            stdin,
            lines,
        };
        let init = server.request(
            1,
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi136-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        server.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        server
    }

    fn send(&mut self, msg: Value) {
        use std::io::Write;
        writeln!(self.stdin, "{msg}").expect("write to server");
        self.stdin.flush().unwrap();
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(120))
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }
}

impl Drop for StdioServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn serve_extracts_through_the_running_memex_when_no_child_is_configured() {
    let dir = visible_tempdir("wi136-stdio-");
    let vault = new_vault(dir.path());
    let mut server = StdioServer::start(&vault);
    let mut id = 1;
    let mut add = |name: &str, bytes: &[u8]| -> String {
        id += 1;
        let data = base64::engine::general_purpose::STANDARD.encode(bytes);
        let reply = server.request(
            id,
            "tools/call",
            json!({ "name": "add_attachment", "arguments": { "data": data, "name": name } }),
        );
        let text = reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("add_attachment answered: {reply}"));
        let stored: Value = serde_json::from_str(text).unwrap_or_else(|e| panic!("{e}: {text}"));
        stored["path"]
            .as_str()
            .unwrap_or_else(|| panic!("a stored path: {text}"))
            .to_string()
    };

    let pdf = add("report.pdf", &fixture_bytes("text-layer.pdf"));
    assert_pdf_done(&vault, &pdf);

    let bytes = fixture_bytes("corrupt.pdf");
    let broken = add("broken.pdf", &bytes);
    let error = assert_failed_and_stored(&vault, &broken, &bytes);
    assert!(
        !error.contains("could not start") && !error.contains("not found"),
        "the child ran and rejected the file: {error:?}"
    );

    let notes = add("notes.md", b"Walrus tundra ledger notes.");
    assert_eq!(row(&vault, &notes).expect("a row").state, "done");
    assert_eq!(fts_match(&vault, "tundra"), vec![notes]);
}

// ---------------------------------------------------------------- server upload (child)

/// The full vault server over a fresh root holding [`VAULT`], with
/// `extractor` as its extraction child.
struct ExtractServer {
    root: TempDir,
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl Drop for ExtractServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl ExtractServer {
    async fn start(extractor: ChildExtractor) -> Self {
        let root = visible_tempdir("wi136-srv-");
        make_vault(root.path(), VAULT);
        let config =
            ServerConfig::new(root.path().to_path_buf(), TEST_TOKEN).with_extractor(extractor);
        let app = router(config);
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self { root, addr, task }
    }

    fn vault(&self) -> PathBuf {
        self.root.path().join(VAULT)
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }

    async fn upload(&self, name: &str, bytes: &[u8]) -> Reply {
        upload_to(self.url(&format!("{BASE}/attachments?name={name}")), bytes).await
    }

    async fn get(&self, path: &str) -> Reply {
        let req = client()
            .get(self.url(path))
            .header("authorization", format!("Bearer {TEST_TOKEN}"));
        Reply::read(req.send().await.expect("send GET")).await
    }

    async fn post_json(&self, path: &str, body: Value) -> Reply {
        let req = client()
            .post(self.url(path))
            .header("authorization", format!("Bearer {TEST_TOKEN}"))
            .json(&body);
        Reply::read(req.send().await.expect("send POST")).await
    }
}

async fn upload_to(url: String, bytes: &[u8]) -> Reply {
    let req = client()
        .post(url)
        .header("authorization", format!("Bearer {TEST_TOKEN}"))
        .header("content-type", "application/octet-stream")
        .body(bytes.to_vec());
    Reply::read(req.send().await.expect("send upload")).await
}

/// The stored JSON of a successful upload.
fn uploaded(reply: &Reply) -> Value {
    assert!(
        matches!(reply.status, 200 | 201),
        "upload stored: {} {}",
        reply.status,
        reply.body
    );
    reply.json()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn server_upload_records_extract_state_before_it_returns() {
    let srv = ExtractServer::start(memex_child()).await;
    let vault = srv.vault();

    let stored = uploaded(
        &srv.upload("report.pdf", &fixture_bytes("text-layer.pdf"))
            .await,
    );
    assert_pdf_done(&vault, stored["path"].as_str().unwrap());

    let bytes = fixture_bytes("invalid-utf8.txt");
    let stored = uploaded(&srv.upload("notes.TXT", &bytes).await);
    let path = stored["path"].as_str().unwrap();
    assert_eq!(row(&vault, path).expect("a row").state, "done");
    assert_eq!(fts_match(&vault, "tundra"), vec![path.to_string()]);

    let bytes = fixture_bytes("corrupt.pdf");
    let stored = uploaded(&srv.upload("broken.pdf", &bytes).await);
    assert_failed_and_stored(&vault, stored["path"].as_str().unwrap(), &bytes);

    let stored = uploaded(&srv.upload("bundle.zip", b"PK\x03\x04 zebra").await);
    let path = stored["path"].as_str().unwrap();
    assert_eq!(row(&vault, path).expect("a row").state, "empty");
    assert_eq!(chunk_count(&vault, path), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn server_upload_records_failed_when_the_child_times_out_and_keeps_serving() {
    let pids = visible_tempdir("wi136-pid-");
    let pid_file = pids.path().join("child.pid");
    let srv = ExtractServer::start(sleeper(&pid_file)).await;
    let vault = srv.vault();
    let bytes = fixture_bytes("text-layer.pdf");

    let reply = srv.upload("slow.pdf", &bytes).await;
    let stored = uploaded(&reply);
    assert_eq!(stored["name"], json!("slow.pdf"));
    assert_failed_and_stored(&vault, stored["path"].as_str().unwrap(), &bytes);
    let pid = fs::read_to_string(&pid_file).expect("the child ran");
    assert!(
        !process_exists(pid.trim()),
        "the timed-out child was reaped"
    );

    let notes = srv.get(&format!("{BASE}/notes?limit=3")).await;
    assert_eq!(
        notes.status, 200,
        "the server keeps serving: {}",
        notes.body
    );
    let file = srv
        .get(&format!(
            "{BASE}/attachments/{}",
            stored["path"].as_str().unwrap()
        ))
        .await;
    assert_eq!(file.status, 200, "the file attached: {}", file.body);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn server_upload_records_failed_when_the_child_crashes_or_exits_non_zero() {
    for (label, extractor) in [("crash", crasher()), ("non-zero", failer())] {
        let srv = ExtractServer::start(extractor).await;
        let vault = srv.vault();
        let bytes = fixture_bytes("text-layer.pdf");
        let stored = uploaded(&srv.upload("report.pdf", &bytes).await);
        let error = assert_failed_and_stored(&vault, stored["path"].as_str().unwrap(), &bytes);
        if label == "non-zero" {
            assert!(error.contains("wi136-boom"), "{label}: {error:?}");
        }
        let notes = srv.get(&format!("{BASE}/notes?limit=3")).await;
        assert_eq!(notes.status, 200, "{label}: the server keeps serving");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn server_upload_of_a_file_already_extracted_runs_no_child() {
    let count = visible_tempdir("wi136-count-");
    let count_file = count.path().join("runs");
    let srv = ExtractServer::start(counter(&count_file)).await;
    let vault = srv.vault();
    let bytes = fixture_bytes("text-layer.pdf");

    // `memex attach` extracted these bytes and name first.
    let file = write_file(count.path(), "report.pdf", &bytes);
    let by_cli = attach(&vault, &file);
    let path = by_cli["path"].as_str().unwrap().to_string();
    let before = row(&vault, &path).expect("the CLI recorded a row");

    let by_upload = uploaded(&srv.upload("report.pdf", &bytes).await);
    assert_eq!(by_upload["path"], json!(path));
    assert_eq!(runs(&count_file), 0, "no child ran");
    assert_eq!(row(&vault, &path), Some(before), "extracted_at unchanged");

    // The same new upload twice runs the child once.
    let first = uploaded(&srv.upload("fresh.pdf", b"%PDF-1.4 fresh").await);
    uploaded(&srv.upload("fresh.pdf", b"%PDF-1.4 fresh").await);
    assert_eq!(runs(&count_file), 1, "extracted once");
    let fresh = first["path"].as_str().unwrap();
    assert_eq!(row(&vault, fresh).unwrap().state, "done");
    assert_eq!(fts_match(&vault, "counted"), vec![fresh.to_string()]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_note_save_that_references_an_attachment_runs_no_extraction() {
    let count = visible_tempdir("wi136-count-");
    let count_file = count.path().join("runs");
    let srv = ExtractServer::start(counter(&count_file)).await;
    let vault = srv.vault();
    let stored: StoredAttachment = store_bytes(&vault, b"%PDF-1.4 kept", "kept.pdf").unwrap();

    let note = srv
        .post_json(
            &format!("{BASE}/notes"),
            json!({ "title": "Refers", "content_md": format!("See:\n\n{}\n", stored.markdown) }),
        )
        .await;
    assert_eq!(note.status, 201, "{}", note.body);

    let mcp = local(counter(&count_file)).await;
    store_bytes(&mcp.vault, b"%PDF-1.4 kept", "kept.pdf").unwrap();
    mcp.call(
        "create_note",
        json!({ "title": "Also refers", "content_md": format!("{}\n", stored.markdown) }),
    )
    .await;

    assert_eq!(runs(&count_file), 0, "a save never runs extraction");
    assert_eq!(row(&vault, &stored.path), None);
    assert_eq!(row(&mcp.vault, &stored.path), None);
}

/// Creates the release file when dropped, so a failing test never leaves
/// the gated child waiting (its time limit stops it in any case).
struct ReleaseOnDrop(PathBuf);

impl Drop for ReleaseOnDrop {
    fn drop(&mut self) {
        let _ = fs::write(&self.0, b"go");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn another_request_completes_while_the_server_extracts_an_upload() {
    let marks = visible_tempdir("wi136-gate-");
    let started = marks.path().join("started");
    let release = marks.path().join("release");
    let _release = ReleaseOnDrop(release.clone());
    // The child says it started, then waits for the test's release.
    let gate = sh(&format!(
        ": > {}; while [ ! -e {} ]; do sleep 0.05; done; printf 'gated zebra text'",
        q(&started),
        q(&release)
    ))
    .with_time_limit(Duration::from_secs(120));
    let srv = Arc::new(ExtractServer::start(gate).await);
    let vault = srv.vault();
    let bytes = fixture_bytes("text-layer.pdf");
    let path = object_path(&bytes, "slow.pdf");

    let upload = {
        let url = srv.url(&format!("{BASE}/attachments?name=slow.pdf"));
        let bytes = bytes.clone();
        tokio::spawn(async move { upload_to(url, &bytes).await })
    };
    let s = started.clone();
    if !wait_until(WAIT, move || s.exists()).await {
        let state = if upload.is_finished() {
            format!("{:?}", upload.await.map(|r| (r.status, r.body)))
        } else {
            "still waiting".to_string()
        };
        panic!("the upload never started its extraction child; upload: {state}");
    }
    assert!(vault.join(&path).is_file(), "stored before extraction");

    // The child is running. Other requests on the vault still complete.
    let notes = tokio::time::timeout(WAIT, srv.get(&format!("{BASE}/notes?limit=3")))
        .await
        .expect("GET /notes completed during the extraction");
    assert_eq!(notes.status, 200, "{}", notes.body);
    let added = tokio::time::timeout(
        WAIT,
        srv.post_json(
            &format!("{BASE}/notes"),
            json!({ "title": "During", "content_md": "written while extracting" }),
        ),
    )
    .await
    .expect("POST /notes completed during the extraction");
    assert_eq!(added.status, 201, "{}", added.body);
    assert!(!upload.is_finished(), "the extraction is still running");

    fs::write(&release, b"go").unwrap();
    let reply = tokio::time::timeout(WAIT, upload)
        .await
        .expect("the upload finished once released")
        .expect("upload task");
    let stored = uploaded(&reply);
    assert_eq!(stored["path"], json!(path));
    assert_eq!(row(&vault, &path).expect("a row").state, "done");
    assert_eq!(fts_match(&vault, "gated"), vec![path]);
}

// ---------------------------------------------------------------- the child turns

/// Marker files for test children that wait on the test. `hold*` children
/// write `started.<name>`, then wait for `release.<name>`; any other child
/// appends its name to `runs` and ends at once. All print `text of <name>`.
struct Gate {
    dir: TempDir,
}

impl Gate {
    fn new() -> Self {
        Self {
            dir: visible_tempdir("wi136-gate-"),
        }
    }

    fn extractor(&self) -> ChildExtractor {
        let script = "n=$(basename \"$1\"); \
            case \"$n\" in \
            hold*) : > @D@/started.$n; while [ ! -e @D@/release.$n ] && [ -d @D@ ]; do sleep 0.05; done;; \
            *) echo \"$n\" >> @D@/runs;; \
            esac; \
            printf 'text of %s' \"$n\"";
        sh(&script.replace("@D@", &q(self.dir.path()))).with_time_limit(Duration::from_secs(120))
    }

    fn started_count(&self) -> usize {
        fs::read_dir(self.dir.path())
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("started.")
            })
            .count()
    }

    fn release(&self, name: &str) {
        fs::write(self.dir.path().join(format!("release.{name}")), b"go").unwrap();
    }

    fn release_all(&self) {
        for i in 1..=9 {
            self.release(&format!("hold{i}.pdf"));
        }
    }

    /// The names of the non-gated children that ran, in order.
    fn runs(&self) -> Vec<String> {
        fs::read_to_string(self.dir.path().join("runs"))
            .map(|s| s.lines().map(str::to_string).collect())
            .unwrap_or_default()
    }
}

impl Drop for Gate {
    /// A failing test never leaves a child waiting: it is released here, and
    /// a child also ends once the folder is gone (its time limit stops it in
    /// any case).
    fn drop(&mut self) {
        self.release_all();
    }
}

/// A state over a new vault in `dir` whose extraction child is `extractor`.
fn state_with(dir: &Path, extractor: ChildExtractor) -> (AppState, PathBuf) {
    let vault = new_vault(dir);
    let state =
        AppState::new(Vault::open(&vault).unwrap(), vault.clone(), None).with_extractor(extractor);
    (state, vault)
}

/// Stores `name` (its own name as its bytes) and runs
/// [`extract_and_record`] for it on its own task.
fn store_and_extract(
    state: &AppState,
    vault: &Path,
    name: &str,
) -> (StoredAttachment, JoinHandle<memex_core::Result<()>>) {
    let stored = store_bytes(vault, name.as_bytes(), name).unwrap();
    let state = state.clone();
    let task_stored = stored.clone();
    let task = tokio::spawn(async move { extract_and_record(&state, &task_stored).await });
    (stored, task)
}

async fn finished(task: JoinHandle<memex_core::Result<()>>) {
    tokio::time::timeout(WAIT, task)
        .await
        .expect("the extraction finished")
        .expect("extraction task")
        .expect("extraction wrote its row");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn at_most_two_extraction_children_run_at_once() {
    assert_eq!(MAX_CHILDREN, 2, "the cap on concurrent children");
    let gate = Gate::new();
    let dir = visible_tempdir("wi136-turns-");
    let (state, vault) = state_with(dir.path(), gate.extractor());

    // Five different files stored at once, each with a child that waits.
    let mut stored = Vec::new();
    let mut tasks = Vec::new();
    for i in 1..=5 {
        let (s, t) = store_and_extract(&state, &vault, &format!("hold{i}.pdf"));
        stored.push(s);
        tasks.push(t);
    }

    let two = wait_until(WAIT, || gate.started_count() >= 2).await;
    assert!(two, "two children started: {}", gate.started_count());
    // A third never starts while two run (a wait that can only pass late).
    let third = wait_until(Duration::from_millis(600), || gate.started_count() > 2).await;
    assert!(!third, "a third child started beside two");
    assert_eq!(gate.started_count(), 2);

    // Once they end, the others run (two at a time) and every file is done.
    gate.release_all();
    for task in tasks {
        finished(task).await;
    }
    assert_eq!(gate.started_count(), 5);
    for s in &stored {
        assert_eq!(row(&vault, &s.path).expect("a row").state, "done");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_store_that_waited_for_a_turn_runs_no_child_when_the_file_was_extracted_meanwhile() {
    let gate = Gate::new();
    let dir = visible_tempdir("wi136-recheck-");
    let (state, vault) = state_with(dir.path(), gate.extractor());

    // Both turns are taken by children that wait.
    let (_, hold1) = store_and_extract(&state, &vault, "hold1.pdf");
    let (_, hold2) = store_and_extract(&state, &vault, "hold2.pdf");
    let both = wait_until(WAIT, || gate.started_count() >= 2).await;
    assert!(both, "both turns are taken");

    // Two stores of the same file find it not yet extracted, and wait.
    let (dup, first) = store_and_extract(&state, &vault, "dup.pdf");
    let (same, second) = store_and_extract(&state, &vault, "dup.pdf");
    assert_eq!(same.path, dup.path);
    // Settle: both have passed their first check and queued for a turn.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(gate.runs().is_empty(), "no turn is free yet");

    // One turn frees: one store runs the child; the other, given a turn
    // after that, finds the row and runs none.
    gate.release("hold1.pdf");
    finished(first).await;
    finished(second).await;
    assert_eq!(gate.runs(), vec!["dup.pdf".to_string()], "one child ran");
    assert_eq!(row(&vault, &dup.path).expect("a row").state, "done");
    assert_eq!(chunk_count(&vault, &dup.path), 1, "one set of chunks");

    gate.release_all();
    finished(hold1).await;
    finished(hold2).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_request_dropped_while_its_child_runs_still_gets_its_row_written() {
    let gate = Gate::new();
    let dir = visible_tempdir("wi136-dropped-");
    let (state, vault) = state_with(dir.path(), gate.extractor());
    let (stored, task) = store_and_extract(&state, &vault, "hold1.pdf");
    let started = wait_until(WAIT, || gate.started_count() >= 1).await;
    assert!(started, "the child started");
    assert_eq!(row(&vault, &stored.path), None, "not recorded yet");

    // The caller goes away (a dropped request, a cancelled tool call).
    task.abort();
    let outcome = task.await;
    assert!(outcome.is_err_and(|e| e.is_cancelled()), "the caller ended");

    gate.release_all();
    let path = stored.path.clone();
    let v = vault.clone();
    let written = wait_until(WAIT, move || row(&v, &path).is_some()).await;
    assert!(written, "the row is written although nobody waits");
    assert_eq!(row(&vault, &stored.path).unwrap().state, "done");
    assert_eq!(fts_match(&vault, "hold1"), vec![stored.path]);
}

#[test]
fn blocking_extraction_runs_in_a_child_process_not_in_this_one() {
    // This test binary is the running "memex": its child is another run of
    // the binary (the file name is not a test name), never this process.
    // Extracted in this process, the file's own words would be indexed.
    let dir = visible_tempdir("wi136-blocking-");
    let vault = new_vault(dir.path());
    let bytes = b"wi136marker words that only an in-process read could index";
    let stored = store_bytes(&vault, bytes, "notes.txt").unwrap();

    extract_and_record_blocking(&vault, &stored).unwrap();

    let r = row(&vault, &stored.path).expect("a row is recorded");
    assert!(r.extracted_at.is_some(), "{r:?}");
    assert_ne!(r.state, "pending", "{r:?}");
    assert_eq!(
        fts_match(&vault, "wi136marker"),
        Vec::<String>::new(),
        "the text was not read in this process"
    );

    // A type with no text needs no child at all: `empty`, no chunks.
    let png = store_bytes(&vault, b"\x89PNG not really", "pic.png").unwrap();
    extract_and_record_blocking(&vault, &png).unwrap();
    assert_eq!(row(&vault, &png.path).unwrap().state, "empty");
    assert_eq!(chunk_count(&vault, &png.path), 0);
}

// ---------------------------------------------------------------- the child's own limits

/// The hidden subcommand on a FIFO named `blocked.txt`: it opens the file
/// and blocks (nothing writes to it), after it has set its limits.
fn blocked_memex_child(dir: &Path) -> Child {
    let fifo = dir.join("blocked.txt");
    let made = Command::new("mkfifo").arg(&fifo).status().expect("mkfifo");
    assert!(made.success(), "mkfifo");
    Command::new(memex())
        .args([SUBCOMMAND, fifo.to_str().unwrap()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start the extraction child")
}

/// The soft `Max data size` of Linux process `pid`, once it is a number.
fn data_limit(pid: u32) -> Option<u64> {
    let limits = fs::read_to_string(format!("/proc/{pid}/limits")).ok()?;
    let line = limits.lines().find(|l| l.starts_with("Max data size"))?;
    line.split_whitespace().nth(3)?.parse().ok()
}

#[tokio::test]
async fn the_extraction_child_caps_its_data_memory_at_1_gib_on_linux() {
    if !cfg!(target_os = "linux") {
        // macOS does not enforce RLIMIT_DATA on mmap, and the child sets none.
        return;
    }
    let dir = visible_tempdir("wi136-rlimit-");
    let mut child = blocked_memex_child(dir.path());
    let pid = child.id();
    let capped = wait_until(WAIT, move || data_limit(pid) == Some(1 << 30)).await;
    let seen = data_limit(pid);
    let _ = child.kill();
    let _ = child.wait();
    assert!(capped, "RLIMIT_DATA of the child is 1 GiB, saw {seen:?}");
}

/// The body of `fn run_subcommand`, up to the next top-level item.
fn run_subcommand_body() -> String {
    let src = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("src/attachment_extract_child.rs"),
    )
    .expect("read the child module source");
    let start = src
        .find("pub fn run_subcommand(")
        .expect("run_subcommand is defined");
    let rest = &src[start..];
    let end = rest.find("\n}\n").expect("run_subcommand ends");
    rest[..end].to_string()
}

/// macOS never enforces `RLIMIT_DATA`, so the behaviour test above cannot run
/// there; this pins on every OS that the child applies the kernel cap (a
/// no-op off Linux) before the watchdog limit and before it reads the file.
#[test]
fn the_child_subcommand_applies_the_kernel_data_cap_before_extracting() {
    let body = run_subcommand_body();
    let cap = body
        .find("attachments_extract::cap_data_memory(MEMORY_LIMIT_BYTES);")
        .expect("run_subcommand caps the data memory at MEMORY_LIMIT_BYTES");
    let watchdog = body
        .find("attachments_extract::limit_memory(MEMORY_LIMIT_BYTES);")
        .expect("run_subcommand starts the memory watchdog");
    let extract = body
        .find("extract(file, &name)")
        .expect("run_subcommand extracts the file");
    assert!(cap < watchdog, "the kernel cap is set before the watchdog");
    assert!(cap < extract, "the kernel cap is set before extraction");
}

// ---------------------------------------------------------------- notices

#[test]
fn notices_pass_with_pdf_extract_listed() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let out_dir = visible_tempdir("wi136-notices-");
    let out_file = out_dir.path().join("THIRD_PARTY_NOTICES.txt");
    let out = Command::new("bash")
        .arg(root.join("scripts/release/notices.sh"))
        .arg(&out_file)
        .current_dir(&root)
        .stdin(Stdio::null())
        .output()
        .expect("run notices.sh");
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    let notices = fs::read_to_string(&out_file).expect("notices written");
    let lines: Vec<&str> = notices.lines().collect();
    let at = lines
        .iter()
        .position(|l| l.starts_with("pdf-extract 0.12."))
        .unwrap_or_else(|| panic!("pdf-extract 0.12.x is listed in the notices"));
    assert_eq!(
        lines.get(at + 1),
        Some(&"License: MIT"),
        "pdf-extract is MIT"
    );
}
