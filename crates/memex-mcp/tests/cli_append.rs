//! WI #12 (R9): `memex append --vault V [--date YYYY-MM-DD] [TEXT]` (quick
//! entry, CONTRACTS C2.12). Drives the real `memex` binary against temp
//! vaults.
//!
//! C2.12 stdout, one JSON line:
//! `{"vault_id":"01HV…","note_id":"01J9…","date":"2026-10-03","block_ids":["b7k2m9"],"content_version":4,"version":9,"prior_state":"Reviewed"}`
//!
//! - The text comes from TEXT, or stdin when TEXT is absent; empty text is
//!   `invalid_argument` (C1: one JSON line on stderr, exit 1).
//! - New blocks get `source: quick-entry`; no footer chip, no excerpt.
//! - The date defaults to today in the LOCAL time zone; a role-less note
//!   titled with the date is adopted as the daily note (Q2).

use std::collections::BTreeSet;
use std::io::Write;
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use memex_core::daily::{self, ReviewState};
use memex_core::Vault;
use regex::Regex;
use serde_json::Value;
use tempfile::TempDir;

const MARKER_LINE: &str = "<!-- memex:topics -->\n";

fn run_with_env(args: &[&str], stdin_body: Option<&str>, env: &[(&str, &str)]) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(args);
    for (k, v) in env {
        cmd.env(k, v);
    }
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

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    run_with_env(args, stdin_body, &[])
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

/// Asserts the C1 failure shape (exit 1, one JSON line on stderr, nothing on
/// stdout) and returns the parsed object.
fn error_json(out: &Output) -> Value {
    assert_eq!(
        out.status.code(),
        Some(1),
        "a failure must exit 1; {}",
        describe(out)
    );
    assert!(
        out.stdout.is_empty(),
        "no stdout on failure; {}",
        describe(out)
    );
    let stderr = String::from_utf8(out.stderr.clone()).expect("utf8 stderr");
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stderr must be exactly one line; {}",
        describe(out)
    );
    serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr is not JSON ({e}); {}", describe(out)))
}

/// Asserts a successful append: exit 0, exactly one JSON line on stdout with
/// `vault_id` first and exactly the C2.12 keys. Returns the parsed object.
fn append_json(out: Output) -> Value {
    let stdout = ok_stdout(out);
    let line = stdout
        .strip_suffix('\n')
        .unwrap_or_else(|| panic!("stdout ends with a newline: {stdout:?}"));
    assert!(!line.contains('\n'), "exactly one line: {stdout:?}");
    assert!(
        line.starts_with("{\"vault_id\":"),
        "vault_id comes first: {line}"
    );
    let v: Value = serde_json::from_str(line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"));
    let keys: BTreeSet<&str> = v
        .as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .map(String::as_str)
        .collect();
    let expected: BTreeSet<&str> = [
        "vault_id",
        "note_id",
        "date",
        "block_ids",
        "content_version",
        "version",
        "prior_state",
    ]
    .into_iter()
    .collect();
    assert_eq!(keys, expected, "C2.12 key set: {v}");
    assert!(v["vault_id"].is_string(), "{v}");
    assert!(v["note_id"].is_string(), "{v}");
    assert!(v["date"].is_string(), "{v}");
    assert!(v["block_ids"].is_array(), "{v}");
    assert!(v["content_version"].is_i64(), "{v}");
    assert!(v["version"].is_i64(), "{v}");
    assert!(v["prior_state"].is_string(), "{v}");
    v
}

fn init_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let path = path.to_str().unwrap().to_string();
    ok_stdout(run(&["init", &path], None));
    (dir, path)
}

fn parse_added_id(stdout: &str) -> String {
    let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(stdout)
        .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))[1]
        .to_string()
}

fn add_daily(vault: &str, title: &str, body: &str) -> String {
    let out = ok_stdout(run(
        &["add", "--vault", vault, "--role", "daily", "--title", title],
        Some(body),
    ));
    parse_added_id(&out)
}

fn add_plain(vault: &str, title: &str, body: &str) -> String {
    let out = ok_stdout(run(
        &["add", "--vault", vault, "--title", title],
        Some(body),
    ));
    parse_added_id(&out)
}

struct Stored {
    title: String,
    content_md: String,
    frontmatter: Value,
    version: i64,
}

fn stored(vault: &str, id: &str) -> Stored {
    let v = Vault::open(vault).expect("open vault");
    v.connection_ref()
        .query_row(
            "SELECT title, content_md, frontmatter, version FROM notes WHERE id = ?",
            [id],
            |r| {
                let fm: String = r.get(2)?;
                Ok(Stored {
                    title: r.get(0)?,
                    content_md: r.get(1)?,
                    frontmatter: serde_json::from_str(&fm).unwrap(),
                    version: r.get(3)?,
                })
            },
        )
        .unwrap()
}

/// Every note row, by id: `(id, title, content_md, frontmatter, version)`.
fn snapshot(vault: &str) -> Vec<(String, String, String, String, i64)> {
    let v = Vault::open(vault).expect("open vault");
    let conn = v.connection_ref();
    let mut stmt = conn
        .prepare("SELECT id, title, content_md, frontmatter, version FROM notes ORDER BY id")
        .unwrap();
    stmt.query_map([], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    })
    .unwrap()
    .collect::<Result<_, _>>()
    .unwrap()
}

/// `(block_id, text, source, created_version)` in `ord` order.
fn blocks_of(vault: &str, id: &str) -> Vec<(String, String, String, i64)> {
    let v = Vault::open(vault).expect("open vault");
    let conn = v.connection_ref();
    let mut stmt = conn
        .prepare(
            "SELECT block_id, text, source, created_version FROM blocks
             WHERE note_id = ? ORDER BY ord",
        )
        .unwrap();
    stmt.query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn content_version(vault: &str, id: &str) -> i64 {
    let v = Vault::open(vault).expect("open vault");
    v.connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

fn count(vault: &str, sql: &str) -> i64 {
    let v = Vault::open(vault).expect("open vault");
    v.connection_ref().query_row(sql, [], |r| r.get(0)).unwrap()
}

fn review_state(vault: &str, id: &str) -> ReviewState {
    let v = Vault::open(vault).expect("open vault");
    daily::review_state(v.connection_ref(), id).unwrap()
}

fn mark_reviewed(vault: &str, id: &str) {
    let v = Vault::open(vault).expect("open vault");
    let n = v
        .connection_ref()
        .execute(
            "UPDATE day_reviews SET reviewed_content_version = content_version, reviewed_at = 1
             WHERE note_id = ?",
            [id],
        )
        .unwrap();
    assert_eq!(n, 1);
}

fn block_ids(v: &Value) -> Vec<String> {
    v["block_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b.as_str().expect("block id string").to_string())
        .collect()
}

/// `YYYY-MM-DD` of a count of days since 1970-01-01 (proleptic Gregorian;
/// H. Hinnant's `civil_from_days`).
fn civil_from_days(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Today's date at a fixed UTC offset (whole hours east of UTC).
fn date_at_utc_offset(hours_east: i64) -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    civil_from_days((secs + hours_east * 3_600).div_euclid(86_400))
}

// ---------- AC 11: TEXT argument → one C2.12 JSON line, quick-entry ----------

#[test]
fn append_cli_prints_one_c2_12_json_line_and_exits_zero() {
    let (_dir, vault) = init_vault();
    let before = daily::today_with_clock(&memex_core::SystemClock).to_string();
    let v = append_json(run(&["append", "--vault", &vault, "Call the bank"], None));
    let after = daily::today_with_clock(&memex_core::SystemClock).to_string();

    let vault_id = Vault::open(&vault).unwrap().vault_id().to_string();
    assert_eq!(v["vault_id"], vault_id.as_str());
    let id = v["note_id"].as_str().unwrap().to_string();
    assert_eq!(id.len(), 26, "{v}");
    let date = v["date"].as_str().unwrap();
    assert!(date == before || date == after, "{date} is not today");

    let s = stored(&vault, &id);
    assert_eq!(s.title, date);
    assert_eq!(s.frontmatter["role"], "daily");
    assert_eq!(s.content_md, format!("Call the bank\n{MARKER_LINE}"));
    assert_eq!(v["version"], s.version);
    assert_eq!(v["content_version"], 1);
    assert_eq!(content_version(&vault, &id), 1);
    assert_eq!(v["prior_state"], "Unreviewed");

    let blocks = blocks_of(&vault, &id);
    assert_eq!(blocks.len(), 1);
    assert_eq!(block_ids(&v), vec![blocks[0].0.clone()]);
    assert_eq!(blocks[0].1, "Call the bank");
    assert_eq!(blocks[0].2, "quick-entry");
    assert_eq!(blocks[0].3, s.version);
}

#[test]
fn append_cli_defaults_the_date_to_local_today() {
    // `Etc/GMT-14` is UTC+14 and `Etc/GMT+12` is UTC-12 (POSIX sign). The two
    // local dates always differ, so a UTC-based default fails one run.
    for (tz, hours_east) in [("Etc/GMT-14", 14), ("Etc/GMT+12", -12)] {
        let (_dir, vault) = init_vault();
        let before = date_at_utc_offset(hours_east);
        let out = run_with_env(
            &["append", "--vault", &vault, "Call the bank"],
            None,
            &[("TZ", tz)],
        );
        let after = date_at_utc_offset(hours_east);
        let v = append_json(out);
        let date = v["date"].as_str().unwrap().to_string();
        assert!(
            date == before || date == after,
            "TZ={tz}: date {date} is not the local date {before}/{after}"
        );
        let s = stored(&vault, v["note_id"].as_str().unwrap());
        assert_eq!(s.title, date, "TZ={tz}");
    }
}

#[test]
fn append_cli_stamps_quick_entry_on_an_existing_daily_note() {
    let (_dir, vault) = init_vault();
    let id = add_daily(&vault, "2026-10-01", "Morning pages\n");

    let v = append_json(run(
        &[
            "append",
            "--vault",
            &vault,
            "--date",
            "2026-10-01",
            "Call the bank",
        ],
        None,
    ));

    assert_eq!(v["note_id"], id.as_str());
    assert_eq!(v["date"], "2026-10-01");
    let s = stored(&vault, &id);
    assert_eq!(
        s.content_md,
        format!("Morning pages\n\nCall the bank\n{MARKER_LINE}")
    );
    assert_eq!(v["version"], s.version);
    assert_eq!(s.version, 2);
    assert_eq!(v["content_version"], 2);
    let blocks = blocks_of(&vault, &id);
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0].2, "person");
    assert_eq!(block_ids(&v), vec![blocks[1].0.clone()]);
    assert_eq!(blocks[1].2, "quick-entry");
    assert_eq!(blocks[1].3, 2);
}

// ---------- AC 12: stdin; empty stdin ----------

#[test]
fn append_cli_reads_the_text_from_stdin_when_text_is_absent() {
    let (_dir, vault) = init_vault();
    add_daily(&vault, "2026-10-01", "Morning pages\n");

    let v = append_json(run(
        &["append", "--vault", &vault, "--date", "2026-10-01"],
        Some("Call the bank\nabout the card\n"),
    ));

    let id = v["note_id"].as_str().unwrap();
    // The trailing newline from stdin is not doubled.
    assert_eq!(
        stored(&vault, id).content_md,
        format!("Morning pages\n\nCall the bank\nabout the card\n{MARKER_LINE}")
    );
    let blocks = blocks_of(&vault, id);
    assert_eq!(blocks.len(), 2);
    assert_eq!(block_ids(&v), vec![blocks[1].0.clone()]);
    assert_eq!(blocks[1].1, "Call the bank\nabout the card");
    assert_eq!(blocks[1].2, "quick-entry");
}

#[test]
fn append_cli_with_empty_stdin_and_no_text_exits_1_with_invalid_argument() {
    let (_dir, vault) = init_vault();
    add_daily(&vault, "2026-10-01", "Morning pages\n");
    let before = snapshot(&vault);

    for stdin in [Some(""), None, Some("  \n\t\n")] {
        for date in [None, Some("2026-10-01")] {
            let mut args = vec!["append", "--vault", vault.as_str()];
            if let Some(d) = date {
                args.extend(["--date", d]);
            }
            let out = run(&args, stdin);
            let err = error_json(&out);
            assert_eq!(
                err["error"]["code"], "invalid_argument",
                "{stdin:?} {date:?}: {err}"
            );
            assert!(err["error"]["message"].is_string(), "{err}");
        }
    }
    assert_eq!(snapshot(&vault), before, "nothing written");
}

#[test]
fn append_cli_with_a_whitespace_text_argument_exits_1_with_invalid_argument() {
    let (_dir, vault) = init_vault();
    for text in ["", "   ", "\n\n"] {
        let out = run(&["append", "--vault", &vault, text], None);
        let err = error_json(&out);
        assert_eq!(err["error"]["code"], "invalid_argument", "{text:?}: {err}");
    }
    assert!(snapshot(&vault).is_empty(), "no daily note created");
}

// ---------- AC 13: no footer chip, no excerpt; Reviewed → Changed ----------

#[test]
fn append_cli_writes_no_footer_chip_and_no_excerpt() {
    let (_dir, vault) = init_vault();
    let topic = add_plain(&vault, "Player Loop", "The jump arc.\n");
    let topic_before = stored(&vault, &topic);

    let v = append_json(run(
        &[
            "append",
            "--vault",
            &vault,
            "Fixed the Player Loop jump arc.",
        ],
        None,
    ));

    let id = v["note_id"].as_str().unwrap();
    let s = stored(&vault, id);
    assert_eq!(
        s.content_md,
        format!("Fixed the Player Loop jump arc.\n{MARKER_LINE}"),
        "no footer chip in the body"
    );
    assert_eq!(count(&vault, "SELECT COUNT(*) FROM footer_chips"), 0);
    assert_eq!(count(&vault, "SELECT COUNT(*) FROM notes"), 2);
    let topic_after = stored(&vault, &topic);
    assert_eq!(
        topic_after.content_md, topic_before.content_md,
        "no excerpt"
    );
    assert_eq!(topic_after.version, topic_before.version);
    assert_eq!(
        count(
            &vault,
            "SELECT COUNT(*) FROM links WHERE link_kind IN ('from-day', 'about')"
        ),
        0
    );
}

#[test]
fn append_cli_turns_a_reviewed_day_into_changed_since_review() {
    let (_dir, vault) = init_vault();
    let id = add_daily(&vault, "2026-10-01", "Morning pages\n");
    mark_reviewed(&vault, &id);
    assert_eq!(review_state(&vault, &id), ReviewState::Reviewed);
    let before = content_version(&vault, &id);

    let v = append_json(run(
        &[
            "append",
            "--vault",
            &vault,
            "--date",
            "2026-10-01",
            "Call the bank",
        ],
        None,
    ));

    assert_eq!(v["prior_state"], "Reviewed");
    assert_eq!(v["content_version"], before + 1);
    assert_eq!(content_version(&vault, &id), before + 1);
    assert_eq!(review_state(&vault, &id), ReviewState::ChangedSinceReview);
}

// ---------- AC 14: adopt a role-less note titled with the date (Q2) ----------

#[test]
fn append_cli_adopts_a_role_less_note_titled_with_the_date() {
    let (_dir, vault) = init_vault();
    let old = add_plain(&vault, "2026-10-01", "Old note body\n");
    assert!(stored(&vault, &old).frontmatter.get("role").is_none());

    let v = append_json(run(
        &[
            "append",
            "--vault",
            &vault,
            "--date",
            "2026-10-01",
            "Call the bank",
        ],
        None,
    ));

    assert_eq!(v["note_id"], old.as_str(), "adopted, not a new note");
    assert_eq!(v["date"], "2026-10-01");
    assert_eq!(snapshot(&vault).len(), 1);
    let s = stored(&vault, &old);
    assert_eq!(s.title, "2026-10-01");
    assert_eq!(s.frontmatter["role"], "daily");
    assert_eq!(
        s.content_md,
        format!("Old note body\n\nCall the bank\n{MARKER_LINE}")
    );
    assert_eq!(v["version"], s.version);
    let blocks = blocks_of(&vault, &old);
    assert_eq!(blocks.len(), 2);
    assert_eq!(block_ids(&v), vec![blocks[1].0.clone()]);
    assert_eq!(blocks[1].2, "quick-entry");
    assert_eq!(blocks[1].3, s.version);
}

// ---------- AC 8 (CLI): malformed --date ----------

#[test]
fn append_cli_with_a_malformed_date_exits_1_with_invalid_date() {
    let (_dir, vault) = init_vault();
    for bad in ["2026-10-1", "2026-02-30"] {
        let out = run(
            &["append", "--vault", &vault, "--date", bad, "Call the bank"],
            None,
        );
        let err = error_json(&out);
        assert_eq!(err["error"]["code"], "invalid_date", "{bad}: {err}");
    }
    assert!(snapshot(&vault).is_empty(), "nothing written");
}
