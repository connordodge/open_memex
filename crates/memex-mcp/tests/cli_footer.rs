//! WI #8 (R5): `memex footer add` (CONTRACTS C2.3, Req 17) and the person
//! save of a daily note with a stale footer (AC 11). Drives the real `memex`
//! binary against temp vaults.
//!
//! C2.3 `memex footer add --vault V --daily-note-id D --topic-note-id T`
//! `{"vault_id":"01HV…","daily_note_id":"01J9…","topic_note_id":"01J9…","origin":"person","version":7}`
//! (`version` = the daily note's new notes.version.) errors: `role_rule`
//! (T not topic; since WI #238 D may be any note but a guide), `not_found`.
//! Idempotent; upgrades an
//! `excerpt` chip to `person`.
//!
//! JSON is compared as parsed values.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use memex_core::footer::{self, ChipOrigin};
use memex_core::notes::NoteId;
use memex_core::Vault;
use regex::Regex;
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
            .unwrap()
            .write_all(body.as_bytes())
            .unwrap();
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

/// One JSON line on stdout.
fn ok_json(out: Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

/// The C1 failure: exit 1, one JSON line on stderr.
fn error_json(out: &Output) -> Value {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a failure exits 1; {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be one line; {}",
        describe(out)
    );
    serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)))
}

fn init_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault").to_str().unwrap().to_string();
    ok_stdout(run(&["init", &path], None));
    (dir, path)
}

fn parse_added_id(stdout: &str) -> String {
    let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(stdout)
        .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))[1]
        .to_string()
}

fn add(vault: &str, title: &str, body: &str, role: Option<&str>) -> String {
    let mut args = vec!["add", "--vault", vault, "--title", title];
    if let Some(r) = role {
        args.extend(["--role", r]);
    }
    parse_added_id(&ok_stdout(run(&args, Some(body))))
}

fn add_daily(vault: &str, date: &str, body: &str) -> String {
    add(vault, date, body, Some("daily"))
}

fn add_topic(vault: &str, title: &str) -> String {
    add(
        vault,
        title,
        &format!("All about {title}.\n"),
        Some("topic"),
    )
}

fn footer_add(vault: &str, daily: &str, topic: &str) -> Output {
    run(
        &[
            "footer",
            "add",
            "--vault",
            vault,
            "--daily-note-id",
            daily,
            "--topic-note-id",
            topic,
        ],
        None,
    )
}

fn open(vault: &str) -> Vault {
    Vault::open(Path::new(vault)).unwrap()
}

/// `(content_md, version)` of a note.
fn note_row(vault: &str, id: &str) -> (String, i64) {
    open(vault)
        .connection_ref()
        .query_row(
            "SELECT content_md, version FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

fn content_version(vault: &str, id: &str) -> i64 {
    open(vault)
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

/// `(topic_note_id, origin)` in rowid order.
fn chip_rows(vault: &str, daily: &str) -> Vec<(String, String)> {
    open(vault)
        .connection_ref()
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap()
        .query_map([daily], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn chip_count(vault: &str) -> i64 {
    open(vault)
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM footer_chips", [], |r| r.get(0))
        .unwrap()
}

fn c23(vault: &str, daily: &str, topic: &str, version: i64) -> Value {
    json!({
        "vault_id": open(vault).vault_id(),
        "daily_note_id": daily,
        "topic_note_id": topic,
        "origin": "person",
        "version": version,
    })
}

// ---------- AC 12: C2.3 output, idempotence, excerpt upgrade ----------

#[test]
fn footer_add_prints_c23_with_origin_person_and_the_new_daily_version() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let daily = add_daily(&v, "2026-10-01", "Morning pages.\n");
    let (_, before) = note_row(&v, &daily);
    let cv = content_version(&v, &daily);

    let out = ok_json(footer_add(&v, &daily, &topic));

    let (body, version) = note_row(&v, &daily);
    assert_eq!(
        version,
        before + 1,
        "the daily note's notes.version goes up by 1"
    );
    assert_eq!(out, c23(&v, &daily, &topic, version));
    assert_eq!(
        body,
        "Morning pages.\n<!-- memex:topics -->\n[[Player Loop~about]]\n"
    );
    assert_eq!(
        chip_rows(&v, &daily),
        vec![(topic.clone(), "person".to_string())]
    );
    assert_eq!(content_version(&v, &daily), cv, "content_version unchanged");
}

#[test]
fn footer_add_twice_leaves_exactly_one_footer_line_for_the_topic() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let other = add_topic(&v, "Sleep");
    let daily = add_daily(&v, "2026-10-01", "Morning pages.\n");

    ok_json(footer_add(&v, &daily, &topic));
    ok_json(footer_add(&v, &daily, &other));
    let out = ok_json(footer_add(&v, &daily, &topic));

    let (body, version) = note_row(&v, &daily);
    assert_eq!(out, c23(&v, &daily, &topic, version));
    assert_eq!(body.matches("[[Player Loop~about]]").count(), 1, "{body:?}");
    assert_eq!(
        body,
        "Morning pages.\n<!-- memex:topics -->\n[[Player Loop~about]]\n[[Sleep~about]]\n"
    );
    assert_eq!(
        chip_rows(&v, &daily),
        vec![
            (topic.clone(), "person".to_string()),
            (other.clone(), "person".to_string()),
        ]
    );
}

#[test]
fn footer_add_on_an_excerpt_chip_reports_and_stores_person() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let daily = add_daily(&v, "2026-10-01", "Morning pages.\n");
    {
        let mut vault = open(&v);
        footer::set_chip(
            &mut vault,
            &NoteId::parse(&daily).unwrap(),
            &NoteId::parse(&topic).unwrap(),
            ChipOrigin::Excerpt,
            None,
        )
        .expect("excerpt chip");
    }
    assert_eq!(
        chip_rows(&v, &daily),
        vec![(topic.clone(), "excerpt".to_string())]
    );

    let out = ok_json(footer_add(&v, &daily, &topic));

    let (body, version) = note_row(&v, &daily);
    assert_eq!(out, c23(&v, &daily, &topic, version));
    assert_eq!(out["origin"], json!("person"));
    assert_eq!(
        chip_rows(&v, &daily),
        vec![(topic.clone(), "person".to_string())]
    );
    assert_eq!(body.matches("[[Player Loop~about]]").count(), 1, "{body:?}");
}

// ---------- AC 13: role_rule and not_found ----------

/// WI #238: the footer is on every note, so a topic note may hold chips; the
/// target must still be a topic note.
#[test]
fn footer_add_on_a_topic_note_succeeds_and_a_non_topic_target_exits_1_with_role_rule() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let other = add_topic(&v, "Sleep");
    let daily = add_daily(&v, "2026-10-01", "Morning pages.\n");
    let (_, other_version) = note_row(&v, &other);
    let (_, daily_version) = note_row(&v, &daily);

    // T is a daily note: role_rule, on a daily or a topic host.
    for host in [&daily, &other] {
        let e = error_json(&footer_add(&v, host, &daily));
        assert_eq!(e["error"]["code"], json!("role_rule"), "{e}");
        assert!(
            e["error"]["message"]
                .as_str()
                .unwrap_or_default()
                .contains("role"),
            "{e}"
        );
    }
    assert_eq!(chip_count(&v), 0, "nothing recorded");
    assert_eq!(note_row(&v, &other).1, other_version);
    assert_eq!(note_row(&v, &daily).1, daily_version);

    // The host is a topic note: the chip goes in its Note footer.
    let out = ok_json(footer_add(&v, &other, &topic));
    assert_eq!(out, c23(&v, &other, &topic, other_version + 1));
    assert_eq!(
        note_row(&v, &other).0,
        "All about Sleep.\n<!-- memex:topics -->\n[[Player Loop~about]]\n"
    );
    assert_eq!(chip_count(&v), 1);
}

#[test]
fn footer_add_with_an_unknown_id_exits_1_with_not_found() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let daily = add_daily(&v, "2026-10-01", "Morning pages.\n");
    let ghost = NoteId::new().to_string();

    for (d, t) in [(&ghost, &topic), (&daily, &ghost)] {
        let e = error_json(&footer_add(&v, d, t));
        assert_eq!(e["error"]["code"], json!("not_found"), "{d} {t}: {e}");
    }
    assert_eq!(chip_count(&v), 0);
    assert_eq!(note_row(&v, &daily).1, 1);
}

// ---------- AC 11: person save with a stale footer ----------

#[test]
fn memex_update_with_a_stale_footer_stores_the_footer_rendered_from_records() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let daily = add_daily(&v, "2026-10-01", "Morning pages.\n");
    ok_json(footer_add(&v, &daily, &topic));
    let (_, version) = note_row(&v, &daily);

    let submitted =
        "Morning pages.\n\nAfternoon walk.\n<!-- memex:topics -->\n[[Unrecorded~about]]\n";
    let out = run(
        &[
            "update",
            "--vault",
            &v,
            "--note-id",
            &daily,
            "--expected-version",
            &version.to_string(),
        ],
        Some(submitted),
    );
    ok_stdout(out);

    let (body, after) = note_row(&v, &daily);
    assert_eq!(after, version + 1);
    assert_eq!(
        body, "Morning pages.\n\nAfternoon walk.\n<!-- memex:topics -->\n[[Player Loop~about]]\n",
        "the recorded chip is present and the unrecorded line is dropped"
    );
    assert_eq!(
        chip_rows(&v, &daily),
        vec![(topic.clone(), "person".to_string())]
    );
}
