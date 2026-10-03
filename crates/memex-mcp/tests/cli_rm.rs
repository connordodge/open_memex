//! WI #8 (R5): `memex rm` (CONTRACTS C2.2, Req 76, D24). Drives the real
//! `memex` binary against temp vaults.
//!
//! C2.2 `memex rm --vault V --note-id ID --expected-version N`
//! `{"vault_id":"01HV…","note_id":"01J9Z8Y7X6W5V4T3S2R1Q0P9N8","deleted":true}`
//! errors: `version_conflict`, `not_found`
//!
//! D24: the search indexes are purged before the delete; blocks, review rows,
//! chips, change entries and memberships cascade; every daily footer that
//! showed a deleted topic is re-rendered (version + 1, content_version kept).
//!
//! JSON is compared as parsed values.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use memex_core::canvas::SystemClock;
use memex_core::notes::NoteId;
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::{smart_folders, Caller, Vault};
use regex::Regex;
use rusqlite::params;
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

fn ok_json(out: Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

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

fn footer_add(vault: &str, daily: &str, topic: &str) {
    ok_stdout(run(
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
    ));
}

fn rm(vault: &str, id: &str, expected_version: i64) -> Output {
    run(
        &[
            "rm",
            "--vault",
            vault,
            "--note-id",
            id,
            "--expected-version",
            &expected_version.to_string(),
        ],
        None,
    )
}

fn open(vault: &str) -> Vault {
    Vault::open(Path::new(vault)).unwrap()
}

fn note_exists(vault: &str, id: &str) -> bool {
    open(vault)
        .connection_ref()
        .query_row("SELECT COUNT(*) FROM notes WHERE id = ?", [id], |r| {
            r.get::<_, i64>(0)
        })
        .unwrap()
        == 1
}

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

fn count_where(vault: &str, table: &str, column: &str, id: &str) -> i64 {
    open(vault)
        .connection_ref()
        .query_row(
            &format!("SELECT COUNT(*) FROM {table} WHERE {column} = ?"),
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

fn fts_hits(vault: &str, word: &str) -> Vec<String> {
    let v = open(vault);
    search(
        v.connection_ref(),
        SearchOptions {
            query: word,
            k: 10,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap()
    .hits
    .into_iter()
    .map(|h| h.note_id)
    .collect()
}

fn add_agent_change(vault: &str, id: &str) {
    open(vault)
        .connection_ref()
        .execute(
            "INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json)
             VALUES (?, ?, '2026-10-01', 1, '[\"Added a section\"]')",
            params![NoteId::new().as_str(), id],
        )
        .unwrap();
}

fn add_review_snapshot(vault: &str, id: &str) {
    open(vault)
        .connection_ref()
        .execute(
            "INSERT INTO day_review_blocks (note_id, block_id, content_hash, text)
             SELECT note_id, block_id, content_hash, text FROM blocks WHERE note_id = ?",
            [id],
        )
        .unwrap();
}

fn add_membership(vault: &str, folder_name: &str, id: &str) {
    let mut v = open(vault);
    let folder =
        smart_folders::create_folder(&mut v, folder_name, None, Caller::Person, &SystemClock)
            .unwrap();
    smart_folders::add_member(&mut v, &folder.id, id, None, Caller::Person, None).unwrap();
}

// ---------- AC 14: C2.2 output, version_conflict, not_found ----------

#[test]
fn rm_prints_c22_and_the_note_no_longer_exists() {
    let (_dir, v) = init_vault();
    let note = add(&v, "Scratch", "Throwaway thought.\n", None);
    let keep = add(&v, "Keeper", "Stays.\n", None);

    let out = ok_json(rm(&v, &note, 1));

    assert_eq!(
        out,
        json!({ "vault_id": open(&v).vault_id(), "note_id": note, "deleted": true })
    );
    assert!(!note_exists(&v, &note));
    assert!(note_exists(&v, &keep));
    let get = run(&["get", "--vault", &v, "--note-id", &note], None);
    assert_eq!(error_json(&get)["error"]["code"], json!("not_found"));
}

#[test]
fn rm_with_a_stale_expected_version_exits_1_with_version_conflict() {
    let (_dir, v) = init_vault();
    let note = add(&v, "Scratch", "Throwaway thought.\n", None);
    ok_stdout(run(
        &[
            "update",
            "--vault",
            &v,
            "--note-id",
            &note,
            "--expected-version",
            "1",
        ],
        Some("Edited thought.\n"),
    ));

    for stale in [1, 3] {
        let e = error_json(&rm(&v, &note, stale));
        let err = &e["error"];
        assert_eq!(err["code"], json!("version_conflict"), "{e}");
        assert_eq!(err["expected"], json!(stale), "{e}");
        assert_eq!(err["current"], json!(2), "{e}");
        assert!(
            err["message"]
                .as_str()
                .unwrap_or_default()
                .contains("version conflict"),
            "{e}"
        );
        assert!(note_exists(&v, &note), "a refused rm deletes nothing");
    }
    assert!(
        count_where(&v, "chunk_fts", "note_id", &note) > 0,
        "indexes kept"
    );

    ok_json(rm(&v, &note, 2));
    assert!(!note_exists(&v, &note));
}

#[test]
fn rm_of_an_unknown_id_exits_1_with_not_found() {
    let (_dir, v) = init_vault();
    let keep = add(&v, "Keeper", "Stays.\n", None);
    let ghost = NoteId::new().to_string();

    let e = error_json(&rm(&v, &ghost, 1));
    assert_eq!(e["error"]["code"], json!("not_found"), "{e}");
    assert!(note_exists(&v, &keep));
}

// ---------- AC 15: rm of a daily note ----------

#[test]
fn rm_of_a_daily_note_removes_its_rows_and_its_search_index() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let daily = add_daily(
        &v,
        "2026-10-01",
        "Saw a quokka at dawn.\n\nSecond thought.\n",
    );
    let other = add_daily(&v, "2026-10-02", "Nothing unusual.\n");
    footer_add(&v, &daily, &topic);
    footer_add(&v, &other, &topic);
    add_review_snapshot(&v, &daily);
    add_agent_change(&v, &daily);
    let tables = [
        ("blocks", "note_id"),
        ("day_reviews", "note_id"),
        ("day_review_blocks", "note_id"),
        ("footer_chips", "daily_note_id"),
        ("agent_changes", "note_id"),
        ("chunk_fts", "note_id"),
    ];
    for (table, column) in tables {
        assert!(
            count_where(&v, table, column, &daily) > 0,
            "setup: {table} has rows for the daily note"
        );
    }
    assert_eq!(fts_hits(&v, "quokka"), vec![daily.as_str()]);
    let (_, version) = note_row(&v, &daily);
    let (_, topic_version) = note_row(&v, &topic);

    ok_json(rm(&v, &daily, version));

    assert!(!note_exists(&v, &daily));
    for (table, column) in tables {
        assert_eq!(
            count_where(&v, table, column, &daily),
            0,
            "{table} rows of the deleted daily note"
        );
    }
    assert!(
        fts_hits(&v, "quokka").is_empty(),
        "no search hit for the deleted note"
    );
    let stray: i64 = open(&v)
        .connection_ref()
        .query_row(
            "SELECT COUNT(*) FROM chunk_fts WHERE note_id = ? OR chunk_id NOT IN (SELECT id FROM chunks)",
            [&daily],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stray, 0, "no chunk_fts row references the deleted note");
    // The other daily note and the topic keep their rows.
    assert_eq!(count_where(&v, "footer_chips", "daily_note_id", &other), 1);
    assert!(count_where(&v, "blocks", "note_id", &other) > 0);
    assert_eq!(note_row(&v, &topic).1, topic_version);
}

// ---------- AC 16: rm of a topic note ----------

#[test]
fn rm_of_a_topic_note_drops_its_memberships_change_entries_and_footer_lines() {
    let (_dir, v) = init_vault();
    let topic = add_topic(&v, "Player Loop");
    let other = add_topic(&v, "Sleep");
    let d1 = add_daily(&v, "2026-10-01", "Day one.\n");
    let d2 = add_daily(&v, "2026-10-02", "Day two.\n");
    let untouched = add_daily(&v, "2026-10-03", "Day three.\n");
    footer_add(&v, &d1, &topic);
    footer_add(&v, &d1, &other);
    footer_add(&v, &d2, &other);
    footer_add(&v, &d2, &topic);
    footer_add(&v, &untouched, &other);
    add_membership(&v, "Games", &topic);
    add_membership(&v, "Rest", &other);
    add_agent_change(&v, &topic);
    add_agent_change(&v, &other);
    assert_eq!(
        count_where(&v, "smart_folder_members", "note_id", &topic),
        1
    );
    let before: Vec<(String, i64, i64)> = [&d1, &d2, &untouched]
        .iter()
        .map(|d| ((*d).clone(), note_row(&v, d).1, content_version(&v, d)))
        .collect();
    let (_, topic_version) = note_row(&v, &topic);

    let out = ok_json(rm(&v, &topic, topic_version));
    assert_eq!(out["deleted"], json!(true));
    assert_eq!(out["note_id"], json!(topic));

    assert!(!note_exists(&v, &topic));
    assert_eq!(
        count_where(&v, "smart_folder_members", "note_id", &topic),
        0
    );
    assert_eq!(count_where(&v, "agent_changes", "note_id", &topic), 0);
    assert_eq!(count_where(&v, "footer_chips", "topic_note_id", &topic), 0);
    assert_eq!(
        count_where(&v, "smart_folder_members", "note_id", &other),
        1
    );
    assert_eq!(count_where(&v, "agent_changes", "note_id", &other), 1);

    assert_eq!(
        note_row(&v, &d1).0,
        "Day one.\n<!-- memex:topics -->\n[[Sleep~about]]\n"
    );
    assert_eq!(
        note_row(&v, &d2).0,
        "Day two.\n<!-- memex:topics -->\n[[Sleep~about]]\n"
    );
    for (id, version, cv) in &before[..2] {
        let (body, after) = note_row(&v, id);
        assert!(!body.contains("[[Player Loop~about]]"), "{id}: {body:?}");
        assert_eq!(after, version + 1, "{id}: notes.version goes up by 1");
        assert_eq!(
            content_version(&v, id),
            *cv,
            "{id}: content_version unchanged"
        );
    }
    let (id, version, _) = &before[2];
    assert_eq!(
        note_row(&v, id).1,
        *version,
        "a footer without the topic is not written"
    );
}
