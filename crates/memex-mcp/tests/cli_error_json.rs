//! WI #5 (R2b): the CLI side of the scaffolding. Drives the real `memex`
//! binary against temp vaults.
//!
//! - The JSON error contract (CONTRACTS C1): on any failure every subcommand
//!   prints ONE line `{"error":{"code":…,"message":…, …rule fields}}` on
//!   stderr and exits 1; clap usage errors keep clap's output and exit 2.
//! - `memex add --role <daily|topic>` (text stdout unchanged, C2.1).
//! - The new subcommands accept the argument names of CONTRACTS C2.2–C2.12.
//! - `memex get` merges the review and transclusion field maps (D7).
//! - CLI writes reindex from the stored note's `content_md` (D8).

use std::collections::BTreeSet;
use std::io::Write;
use std::process::{Command, Output, Stdio};

use memex_core::notes::{self, NoteId};
use memex_core::{excerpts, review, MemexError, Vault};
use regex::Regex;
use serde_json::Value;
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains (CONTRACTS C1 sample id).
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

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
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn ok_stdout(out: Output) -> String {
    assert!(
        out.status.success(),
        "expected success, got {}",
        describe(&out)
    );
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

/// Asserts the C1 failure shape (exit 1, exactly one stderr line that parses
/// as `{"error":{...}}`) and returns the whole parsed object.
fn error_json(out: &Output) -> Value {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a failure must exit 1; {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).expect("utf8 stderr");
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty(),
        "stderr must carry the JSON error line; {}",
        describe(out)
    );
    assert!(
        !line.contains('\n'),
        "stderr must be exactly one line; {}",
        describe(out)
    );
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr is not JSON ({e}); {}", describe(out)));
    let obj = v.as_object().expect("top level is an object");
    assert_eq!(
        obj.keys().collect::<Vec<_>>(),
        vec!["error"],
        "top level holds only `error`: {v}"
    );
    assert!(
        v["error"]["code"].is_string(),
        "error.code is a string: {v}"
    );
    assert!(
        v["error"]["message"].is_string(),
        "error.message is a string: {v}"
    );
    v
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .expect("object")
        .keys()
        .cloned()
        .collect::<BTreeSet<_>>()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn init_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let path = path.to_str().unwrap().to_string();
    ok_stdout(run(&["init", &path], None));
    (dir, path)
}

/// `memex add` stdout is text (C2.1); memex_cli.dart:72 parses the id with
/// this regex.
fn parse_added_id(stdout: &str) -> String {
    let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(stdout)
        .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))[1]
        .to_string()
}

fn add_note(vault: &str, title: &str, body: &str) -> String {
    let out = ok_stdout(run(
        &["add", "--vault", vault, "--title", title],
        Some(body),
    ));
    parse_added_id(&out)
}

fn get_json(vault: &str, id: &str, extra: &[&str]) -> Value {
    let mut args = vec!["get", "--vault", vault, "--note-id", id];
    args.extend_from_slice(extra);
    let out = ok_stdout(run(&args, None));
    serde_json::from_str(out.trim()).expect("get prints JSON")
}

fn note_count(vault: &str) -> i64 {
    let v = Vault::open(vault).expect("open vault");
    v.connection_ref()
        .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
        .unwrap()
}

/// D8: the note's `chunks` and `links` rows are exactly what the indexer
/// derives from the stored `notes.content_md`.
fn assert_indexed_from_stored_content(vault: &str, note_id: &str) {
    let v = Vault::open(vault).expect("open vault");
    let conn = v.connection_ref();
    let stored: String = conn
        .query_row(
            "SELECT content_md FROM notes WHERE id = ?",
            [note_id],
            |r| r.get(0),
        )
        .unwrap();

    let mut stmt = conn
        .prepare("SELECT ord, content FROM chunks WHERE note_id = ? ORDER BY ord")
        .unwrap();
    let chunk_rows: Vec<(i64, String)> = stmt
        .query_map([note_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let expected_chunks: Vec<(i64, String)> = memex_core::chunker::chunk(&stored)
        .into_iter()
        .map(|c| (c.ord, c.content))
        .collect();
    assert!(!expected_chunks.is_empty(), "test body must produce chunks");
    assert_eq!(
        chunk_rows, expected_chunks,
        "chunks must be derived from the stored content_md"
    );

    let mut stmt = conn
        .prepare(
            "SELECT link_text, link_kind, position FROM links
             WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap();
    let link_rows: Vec<(String, String, i64)> = stmt
        .query_map([note_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut expected_links: Vec<(String, String, i64)> =
        memex_core::link_extractor::extract(&stored)
            .all()
            .map(|l| {
                (
                    l.link_text.clone(),
                    l.link_kind.as_str().to_string(),
                    l.position,
                )
            })
            .collect();
    expected_links.sort_by_key(|l| l.2);
    assert_eq!(
        link_rows, expected_links,
        "links must be derived from the stored content_md"
    );
}

// ---------- AC 1: version conflict ----------

#[test]
fn update_with_stale_expected_version_prints_version_conflict_json() {
    let (_dir, vault) = init_vault();
    let id = add_note(&vault, "Stale", "first body\n");
    ok_stdout(run(
        &[
            "update",
            "--vault",
            &vault,
            "--note-id",
            &id,
            "--expected-version",
            "1",
        ],
        Some("second body\n"),
    ));

    let out = run(
        &[
            "update",
            "--vault",
            &vault,
            "--note-id",
            &id,
            "--expected-version",
            "1",
        ],
        Some("third body\n"),
    );
    let v = error_json(&out);
    let err = &v["error"];
    assert_eq!(err["code"], "version_conflict", "{v}");
    assert_eq!(err["expected"], 1, "{v}");
    assert_eq!(err["current"], 2, "{v}");
    assert!(
        err["message"]
            .as_str()
            .unwrap()
            .contains("version conflict"),
        "message must contain `version conflict` (memex_cli.dart:104-106): {v}"
    );
    assert_eq!(
        keys(err),
        set(&["code", "message", "expected", "current"]),
        "{v}"
    );
    // The CLI maps the core error through `to_error_json()` (C1).
    assert_eq!(
        v,
        MemexError::VersionConflict {
            expected: 1,
            current: 2
        }
        .to_error_json()
    );
    assert!(
        out.stdout.is_empty(),
        "nothing on stdout on failure; {}",
        describe(&out)
    );
    assert_eq!(get_json(&vault, &id, &[])["content_md"], "second body\n");
}

// ---------- AC 2: not_found / invalid_id ----------

#[test]
fn get_unknown_note_id_prints_not_found_json() {
    let (_dir, vault) = init_vault();
    let out = run(&["get", "--vault", &vault, "--note-id", ABSENT_ULID], None);
    let v = error_json(&out);
    assert_eq!(v["error"]["code"], "not_found", "{v}");
    assert!(
        v["error"]["message"]
            .as_str()
            .unwrap()
            .contains(ABSENT_ULID),
        "message names the missing note: {v}"
    );
    assert_eq!(keys(&v["error"]), set(&["code", "message"]), "{v}");
}

#[test]
fn get_malformed_note_id_prints_invalid_id_json() {
    let (_dir, vault) = init_vault();
    let out = run(&["get", "--vault", &vault, "--note-id", "not-a-ulid"], None);
    let v = error_json(&out);
    assert_eq!(v["error"]["code"], "invalid_id", "{v}");
    assert!(
        v["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not-a-ulid"),
        "{v}"
    );
}

#[test]
fn update_and_links_with_malformed_note_id_print_invalid_id_json() {
    let (_dir, vault) = init_vault();
    let out = run(
        &[
            "update",
            "--vault",
            &vault,
            "--note-id",
            "not-a-ulid",
            "--expected-version",
            "1",
        ],
        Some("body\n"),
    );
    assert_eq!(error_json(&out)["error"]["code"], "invalid_id");

    let out = run(
        &["links", "--vault", &vault, "--note-id", "not-a-ulid"],
        None,
    );
    assert_eq!(error_json(&out)["error"]["code"], "invalid_id");
}

// ---------- AC 3: empty stdin ----------

#[test]
fn add_with_empty_stdin_prints_invalid_argument_json() {
    let (_dir, vault) = init_vault();
    for body in ["", "  \n\t\n"] {
        let out = run(&["add", "--vault", &vault], Some(body));
        let v = error_json(&out);
        assert_eq!(v["error"]["code"], "invalid_argument", "body {body:?}: {v}");
        assert!(
            v["error"]["message"]
                .as_str()
                .unwrap()
                .contains("stdin was empty"),
            "{v}"
        );
    }
    assert_eq!(note_count(&vault), 0, "no note created");
}

// ---------- other failures on every subcommand ----------

#[test]
fn add_link_with_invalid_kind_prints_invalid_argument_json() {
    let (_dir, vault) = init_vault();
    let a = add_note(&vault, "A", "alpha\n");
    let b = add_note(&vault, "B", "beta\n");
    let out = run(
        &[
            "add-link", "--vault", &vault, "--from", &a, "--to", &b, "--kind", "Made_Up",
        ],
        None,
    );
    let v = error_json(&out);
    assert_eq!(v["error"]["code"], "invalid_argument", "{v}");
}

#[test]
fn ls_on_directory_without_vault_prints_internal_json() {
    let dir = tempfile::tempdir().unwrap();
    let not_a_vault = dir.path().to_str().unwrap();
    let out = run(&["ls", "--vault", not_a_vault], None);
    let v = error_json(&out);
    assert_eq!(v["error"]["code"], "internal", "{v}");
    assert!(!v["error"]["message"].as_str().unwrap().is_empty(), "{v}");
}

#[test]
fn canvas_get_unknown_canvas_prints_not_found_json() {
    let (_dir, vault) = init_vault();
    let out = run(
        &[
            "canvas",
            "get",
            "--vault",
            &vault,
            "--canvas-id",
            ABSENT_ULID,
        ],
        None,
    );
    let v = error_json(&out);
    assert_eq!(v["error"]["code"], "not_found", "{v}");
}

#[test]
fn clap_usage_error_keeps_clap_output_and_exit_2() {
    let (_dir, vault) = init_vault();
    let out = run(&["get", "--vault", &vault], None);
    assert_eq!(out.status.code(), Some(2), "{}", describe(&out));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("--note-id"),
        "clap names the missing flag: {stderr}"
    );
    assert!(
        serde_json::from_str::<Value>(stderr.trim()).is_err(),
        "clap usage errors are not JSON: {stderr}"
    );
}

// ---------- AC 4 / AC 5: `memex add --role` ----------

#[test]
fn add_with_role_topic_stores_role_and_keeps_text_stdout() {
    let (_dir, vault) = init_vault();
    let out = ok_stdout(run(
        &[
            "add",
            "--vault",
            &vault,
            "--role",
            "topic",
            "--title",
            "Player Loop",
        ],
        Some("Core loop: jump, land, repeat.\n"),
    ));
    let re = Regex::new(r"\ACreated note\n  note_id: ([0-9A-Z]{26})\n  title:   Player Loop\n\z")
        .unwrap();
    let caps = re
        .captures(&out)
        .unwrap_or_else(|| panic!("add stdout must stay text (C2.1), got: {out:?}"));
    let id = caps[1].to_string();

    let got = get_json(&vault, &id, &[]);
    assert_eq!(got["frontmatter"]["role"], "topic", "{got}");
    assert_eq!(got["title"], "Player Loop");
    assert_eq!(got["content_md"], "Core loop: jump, land, repeat.\n");
}

#[test]
fn add_without_role_stores_no_role_key() {
    let (_dir, vault) = init_vault();
    let id = add_note(&vault, "Plain", "no role here\n");
    let got = get_json(&vault, &id, &[]);
    let fm = got["frontmatter"].as_object().expect("frontmatter object");
    assert!(
        !fm.contains_key("role"),
        "no role key without --role: {got}"
    );
}

#[test]
fn add_with_bogus_role_is_rejected_by_argument_parsing() {
    let (_dir, vault) = init_vault();
    let out = run(
        &[
            "add", "--vault", &vault, "--role", "bogus", "--title", "Nope",
        ],
        Some("body\n"),
    );
    assert!(!out.status.success(), "{}", describe(&out));
    assert_eq!(
        out.status.code(),
        Some(2),
        "clap usage error; {}",
        describe(&out)
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("bogus"), "{stderr}");
    assert!(
        stderr.contains("possible values") && stderr.contains("daily") && stderr.contains("topic"),
        "`--role` is a value enum of daily|topic: {stderr}"
    );
    assert_eq!(note_count(&vault), 0, "no note created");
}

// ---------- AC 6: new subcommands accept the C2 argument names ----------

#[test]
fn new_subcommands_help_lists_every_c2_flag() {
    // (subcommand path, flags and positionals from CONTRACTS C2.2–C2.13)
    let table: &[(&[&str], &[&str])] = &[
        (&["append"], &["--vault", "--date", "[TEXT]"]),
        (&["prompt"], &["review", "capture"]),
        (&["prompt", "review"], &[]),
        (&["prompt", "capture"], &[]),
        (&["rm"], &["--vault", "--note-id", "--expected-version"]),
        (
            &["excerpt", "rm"],
            &["--vault", "--topic-note-id", "--date", "--block-ids"],
        ),
        (
            &["footer", "add"],
            &["--vault", "--daily-note-id", "--topic-note-id"],
        ),
        (&["folder", "ls"], &["--vault"]),
        (&["folder", "new"], &["--vault", "--name", "--parent-id"]),
        (
            &["folder", "update"],
            &[
                "--vault",
                "--id",
                "--name",
                "--parent-id",
                "--to-root",
                "--pinned",
            ],
        ),
        (&["folder", "rm"], &["--vault", "--id"]),
        (
            &["folder", "add"],
            &["--vault", "--id", "--note-id", "--pinned"],
        ),
        (&["folder", "remove"], &["--vault", "--id", "--note-id"]),
        (&["settings", "get"], &["--vault", "--key"]),
        (&["settings", "set"], &["--vault", "--key", "--value"]),
    ];

    let mut failures = Vec::new();
    for (path, flags) in table {
        let mut args: Vec<&str> = path.to_vec();
        args.push("--help");
        let out = run(&args, None);
        let shown = path.join(" ");
        if out.status.code() != Some(0) {
            failures.push(format!("`memex {shown} --help` failed: {}", describe(&out)));
            continue;
        }
        let help = String::from_utf8_lossy(&out.stdout).to_string();
        for flag in *flags {
            // Whole-token match so `--id` is not satisfied by `--note-id`.
            let re = Regex::new(&format!(
                r"(^|[\s\[,|]){}($|[\s=<,\]|])",
                regex::escape(flag)
            ))
            .unwrap();
            if !help.lines().any(|l| re.is_match(l)) {
                failures.push(format!(
                    "`memex {shown} --help` does not list {flag}:\n{help}"
                ));
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

// ---------- AC 9: `memex get` merges the stub field maps ----------

#[test]
fn get_merges_empty_stub_fields_and_keeps_todays_keys() {
    let (_dir, vault) = init_vault();
    let id = add_note(&vault, "Plain note", "Just text.\n");

    let (review_fields, transclusion_fields) = {
        let v = Vault::open(&vault).unwrap();
        let note = notes::get_note(&v, &NoteId::parse(&id).unwrap()).unwrap();
        (
            review::note_review_fields(&v, &note).expect("review fields"),
            excerpts::note_transclusion_fields(&v, &note).expect("transclusion fields"),
        )
    };
    assert!(review_fields.is_empty(), "plain note has no review fields");
    assert!(
        transclusion_fields.is_empty(),
        "plain note has no transclusion fields"
    );

    let base = [
        "note_id",
        "title",
        "content_md",
        "frontmatter",
        "version",
        "created_at",
        "updated_at",
        "tags",
    ];
    let mut expected = set(&base);
    expected.extend(review_fields.keys().cloned());
    expected.extend(transclusion_fields.keys().cloned());
    assert_eq!(keys(&get_json(&vault, &id, &[])), expected);

    let mut expected_links = expected.clone();
    expected_links.extend(set(&["links", "backlinks"]));
    assert_eq!(
        keys(&get_json(&vault, &id, &["--include-links"])),
        expected_links
    );
}

// ---------- AC 11: CLI writes reindex from the stored content (D8) ----------

#[test]
fn cli_add_update_and_add_link_reindex_from_stored_content() {
    let (_dir, vault) = init_vault();
    let target = add_note(&vault, "Target", "target body\n");

    let id = add_note(
        &vault,
        "Source",
        "# Source\n\nFirst paragraph mentions [[Target]].\n\nSecond paragraph.\n",
    );
    assert_indexed_from_stored_content(&vault, &id);

    ok_stdout(run(
        &[
            "update",
            "--vault",
            &vault,
            "--note-id",
            &id,
            "--expected-version",
            "1",
        ],
        Some("# Source\n\nRewritten body links [[Target~extends]] and [[Ghost]].\n"),
    ));
    assert_indexed_from_stored_content(&vault, &id);

    ok_stdout(run(
        &[
            "add-link",
            "--vault",
            &vault,
            "--from",
            &id,
            "--to",
            &target,
            "--kind",
            "references",
        ],
        None,
    ));
    assert_indexed_from_stored_content(&vault, &id);

    let role_id = parse_added_id(&ok_stdout(run(
        &[
            "add",
            "--vault",
            &vault,
            "--role",
            "topic",
            "--title",
            "Topic With Link",
        ],
        Some("Topic body pointing at [[Target]].\n"),
    )));
    assert_indexed_from_stored_content(&vault, &role_id);
}

// ---------- WI #142 (X3): update-link and add-link reject unwritable kinds ----------

/// The kinds a person or agent may not write: syntactically invalid input
/// plus the server-written `from-day` and `about` (also in the spellings
/// that normalise to them).
const WI142_BAD_KINDS: [&str; 12] = [
    "Bad_Kind", "9x", "a.b", "", "x~y", "a|b", "from-day", "about", "About", "ABOUT", "From Day",
    "FROM-DAY",
];

type Wi142LinkRow = (String, String, Option<String>, String, Option<String>);

/// The stored state of a source note: its markdown, version and every link
/// row it owns (`id, link_kind, label, source, to_note_id`).
#[derive(Debug, PartialEq)]
struct Wi142Snapshot {
    content_md: String,
    version: i64,
    links: Vec<Wi142LinkRow>,
}

fn wi142_snapshot(vault: &str, note_id: &str) -> Wi142Snapshot {
    let v = Vault::open(vault).expect("open vault");
    let note = notes::get_note(&v, &NoteId::parse(note_id).unwrap()).unwrap();
    let mut stmt = v
        .connection_ref()
        .prepare(
            "SELECT id, link_kind, label, source, to_note_id FROM links
             WHERE from_note_id = ? ORDER BY position, id",
        )
        .unwrap();
    let links = stmt
        .query_map([note_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    Wi142Snapshot {
        content_md: note.content_md,
        version: note.version,
        links,
    }
}

/// `memex add-link` with `kind`, success path; returns `(link_id, source)`
/// from the stdout JSON.
fn wi142_add_link_ok(vault: &str, from: &str, to: &str, kind: &str) -> (String, String) {
    let out = ok_stdout(run(
        &[
            "add-link", "--vault", vault, "--from", from, "--to", to, "--kind", kind,
        ],
        None,
    ));
    let v: Value = serde_json::from_str(out.trim_end()).expect("add-link stdout JSON");
    (
        v["link_id"].as_str().expect("link_id").to_string(),
        v["source"].as_str().expect("source").to_string(),
    )
}

/// A vault with notes A and B and a body link A -> B (`[[Beta]]`).
/// Returns `(dir, vault, a, b, body_link_id)`.
fn wi142_body_link_fixture() -> (TempDir, String, String, String, String) {
    let (dir, vault) = init_vault();
    let a = add_note(&vault, "Alpha", "alpha\n");
    let b = add_note(&vault, "Beta", "beta\n");
    let (link_id, source) = wi142_add_link_ok(&vault, &a, &b, "references");
    assert_eq!(source, "auto_added", "fixture: a body link");
    (dir, vault, a, b, link_id)
}

fn wi142_update_link(vault: &str, link_id: &str, kind: &str) -> Output {
    run(
        &[
            "update-link",
            "--vault",
            vault,
            "--link-id",
            link_id,
            "--kind",
            kind,
        ],
        None,
    )
}

fn wi142_add_link(vault: &str, from: &str, to: &str, kind: &str) -> Output {
    run(
        &[
            "add-link", "--vault", vault, "--from", from, "--to", to, "--kind", kind,
        ],
        None,
    )
}

#[test]
fn update_link_with_server_written_kind_is_invalid_argument_and_changes_nothing() {
    let (_dir, vault, a, _b, link_id) = wi142_body_link_fixture();
    let before = wi142_snapshot(&vault, &a);
    for kind in ["from-day", "about"] {
        let out = wi142_update_link(&vault, &link_id, kind);
        let v = error_json(&out);
        assert_eq!(v["error"]["code"], "invalid_argument", "{kind}: {v}");
        assert!(
            v["error"]["message"]
                .as_str()
                .unwrap()
                .starts_with("invalid --kind: "),
            "{kind}: {v}"
        );
        assert!(
            out.stdout.is_empty(),
            "{kind}: a failure prints nothing on stdout; {}",
            describe(&out)
        );
        assert_eq!(
            wi142_snapshot(&vault, &a),
            before,
            "{kind}: the link row, content_md and version are unchanged"
        );
    }
}

#[test]
fn add_link_with_server_written_kind_is_invalid_argument_and_changes_nothing() {
    let (_dir, vault) = init_vault();
    let a = add_note(&vault, "Alpha", "alpha\n");
    let b = add_note(&vault, "Beta", "beta\n");
    let before = wi142_snapshot(&vault, &a);
    for kind in ["from-day", "about"] {
        let out = wi142_add_link(&vault, &a, &b, kind);
        let v = error_json(&out);
        assert_eq!(v["error"]["code"], "invalid_argument", "{kind}: {v}");
        assert!(
            v["error"]["message"]
                .as_str()
                .unwrap()
                .starts_with("invalid --kind: "),
            "{kind}: {v}"
        );
        assert_eq!(
            wi142_snapshot(&vault, &a),
            before,
            "{kind}: content_md, version and links of the source are unchanged"
        );
    }
}

#[test]
fn update_link_bad_kinds_match_add_link_byte_for_byte() {
    let (_dir, vault, a, b, link_id) = wi142_body_link_fixture();
    let before = wi142_snapshot(&vault, &a);
    for kind in WI142_BAD_KINDS {
        let update = wi142_update_link(&vault, &link_id, kind);
        let v = error_json(&update);
        assert_eq!(v["error"]["code"], "invalid_argument", "{kind:?}: {v}");
        let add = wi142_add_link(&vault, &a, &b, kind);
        assert_eq!(add.status.code(), Some(1), "{kind:?}: {}", describe(&add));
        assert_eq!(
            update.stderr,
            add.stderr,
            "{kind:?}: update-link and add-link print the same error line\nupdate: {}\nadd: {}",
            String::from_utf8_lossy(&update.stderr),
            String::from_utf8_lossy(&add.stderr)
        );
        assert_eq!(
            wi142_snapshot(&vault, &a),
            before,
            "{kind:?}: the stored link and note are unchanged"
        );
    }
}

#[test]
fn update_link_validates_kind_before_opening_the_vault() {
    let dir = tempfile::tempdir().unwrap();
    let not_a_vault = dir.path().to_str().unwrap();
    let add = wi142_add_link(not_a_vault, ABSENT_ULID, ABSENT_ULID, "Bad_Kind");
    let add_err = error_json(&add);
    assert_eq!(add_err["error"]["code"], "invalid_argument", "{add_err}");
    for kind in ["Bad_Kind", "from-day", "about", ""] {
        let out = wi142_update_link(not_a_vault, ABSENT_ULID, kind);
        let v = error_json(&out);
        assert_eq!(
            v["error"]["code"], "invalid_argument",
            "{kind:?}: a bad kind wins over a bad --vault: {v}"
        );
        assert!(
            v["error"]["message"]
                .as_str()
                .unwrap()
                .starts_with("invalid --kind: "),
            "{kind:?}: {v}"
        );
    }
    let same_as_add = wi142_update_link(not_a_vault, ABSENT_ULID, "Bad_Kind");
    assert_eq!(
        same_as_add.stderr, add.stderr,
        "update-link reports it exactly as add-link does"
    );
}

#[test]
fn update_link_kind_change_on_a_frontmatter_link_is_invalid_argument_and_changes_nothing() {
    let (_dir, vault) = init_vault();
    let a = add_note(&vault, "Alpha", "alpha\n");
    let b = add_note(&vault, "Beta", "beta\n");
    let (link_id, _) = wi142_add_link_ok(&vault, &a, &b, "extends");
    let before = wi142_snapshot(&vault, &a);
    assert_eq!(
        before.links.len(),
        1,
        "fixture: one link: {:?}",
        before.links
    );
    assert_eq!(
        before.links[0].3, "frontmatter",
        "fixture: a frontmatter link"
    );
    let out = wi142_update_link(&vault, &link_id, "contradicts");
    let v = error_json(&out);
    assert_eq!(v["error"]["code"], "invalid_argument", "{v}");
    assert!(
        v["error"]["message"]
            .as_str()
            .unwrap()
            .contains("frontmatter link kind cannot be changed"),
        "the refusal message is kept, only its code changes: {v}"
    );
    assert!(out.stdout.is_empty(), "{}", describe(&out));
    assert_eq!(
        wi142_snapshot(&vault, &a),
        before,
        "the link row, content_md and version are unchanged"
    );
}

#[test]
fn update_link_and_add_link_still_accept_normalised_kinds() {
    let (_dir, vault, a, b, mut link_id) = wi142_body_link_fixture();
    // update-link normalises exactly as add-link does.
    for (given, stored) in [("EXTENDS", "extends"), ("Has Space", "has-space")] {
        let out = ok_stdout(wi142_update_link(&vault, &link_id, given));
        let v: Value = serde_json::from_str(out.trim_end()).expect("update-link stdout JSON");
        assert_eq!(v["kind"], stored, "update-link {given:?}: {v}");
        // A rewrite re-extracts the note's links: the row has a new id.
        link_id = v["link_id"].as_str().expect("link_id").to_string();
        let snap = wi142_snapshot(&vault, &a);
        assert!(
            snap.content_md.contains(&format!("[[Beta~{stored}]]")),
            "update-link {given:?}: {}",
            snap.content_md
        );
        assert_eq!(snap.links.len(), 1, "{:?}", snap.links);
        assert_eq!(snap.links[0].1, stored);
    }
    // add-link: two more targets so each kind adds a fresh link.
    let c = add_note(&vault, "Gamma", "gamma\n");
    let d = add_note(&vault, "Delta", "delta\n");
    for (to, given, stored) in [(&c, "EXTENDS", "extends"), (&d, "Has Space", "has-space")] {
        let out = ok_stdout(wi142_add_link(&vault, &b, to, given));
        let v: Value = serde_json::from_str(out.trim_end()).expect("add-link stdout JSON");
        assert_eq!(v["kind"], stored, "add-link {given:?}: {v}");
    }
}

#[test]
fn update_link_still_accepts_built_in_and_user_kinds() {
    let (_dir, vault, a, _b, mut link_id) = wi142_body_link_fixture();
    for kind in ["contradicts", "example-of", "inspired-by", "references"] {
        let out = ok_stdout(wi142_update_link(&vault, &link_id, kind));
        let v: Value = serde_json::from_str(out.trim_end()).expect("update-link stdout JSON");
        assert_eq!(v["kind"], kind, "{v}");
        link_id = v["link_id"].as_str().expect("link_id").to_string();
        assert_eq!(wi142_snapshot(&vault, &a).links[0].1, kind);
    }
}

#[test]
fn links_kind_filter_still_accepts_server_written_kinds() {
    let (_dir, vault, a, _b, _link_id) = wi142_body_link_fixture();
    for kind in ["about", "from-day"] {
        ok_stdout(run(
            &["links", "--vault", &vault, "--note-id", &a, "--kind", kind],
            None,
        ));
    }
}
