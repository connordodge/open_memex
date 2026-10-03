//! WI #7 (R4): `memex add --role daily` and the D8 reindex of daily notes on
//! the CLI (person) path. Drives the real `memex` binary against temp vaults.
//!
//! - CONTRACTS C2.1: stdin may be empty for `--role daily`; the title
//!   defaults to today in the LOCAL time zone; stdout stays text (`Created
//!   note` / `Adopted note`); an existing daily note is `daily_note_exists`.
//! - D8: after `memex update` / `memex update-link` on a daily note, `chunks`
//!   and `links` are derived from the stored, normalized `content_md`.

use std::io::Write;
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use memex_core::{MemexError, Vault};
use regex::Regex;
use serde_json::Value;
use tempfile::TempDir;

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

/// Asserts the C1 failure shape (exit 1, one JSON line on stderr) and
/// returns the parsed object.
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
        !line.is_empty() && !line.contains('\n'),
        "stderr must be exactly one line; {}",
        describe(out)
    );
    serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr is not JSON ({e}); {}", describe(out)))
}

fn init_vault() -> (TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let path = path.to_str().unwrap().to_string();
    ok_stdout(run(&["init", &path], None));
    (dir, path)
}

/// memex_cli.dart:72 parses the id with this regex.
fn parse_added_id(stdout: &str) -> String {
    let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
    re.captures(stdout)
        .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))[1]
        .to_string()
}

/// The C2.1 text block.
fn c21(first_line: &str, id: &str, title: &str) -> String {
    format!("{first_line}\n  note_id: {id}\n  title:   {title}\n")
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

fn note_ids(vault: &str) -> Vec<String> {
    let v = Vault::open(vault).expect("open vault");
    let conn = v.connection_ref();
    let mut stmt = conn.prepare("SELECT id FROM notes ORDER BY id").unwrap();
    stmt.query_map([], |r| r.get(0))
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

// ---------- AC 16: empty stdin, default title = local today ----------

#[test]
fn add_role_daily_with_empty_stdin_creates_todays_daily_note_in_local_time() {
    // `Etc/GMT-14` is UTC+14 and `Etc/GMT+12` is UTC-12 (POSIX sign). The two
    // local dates always differ, so a UTC-based default title fails one run.
    for (tz, hours_east) in [("Etc/GMT-14", 14), ("Etc/GMT+12", -12)] {
        let (_dir, vault) = init_vault();
        let before = date_at_utc_offset(hours_east);
        let out = run_with_env(
            &["add", "--vault", &vault, "--role", "daily"],
            Some(""),
            &[("TZ", tz)],
        );
        let after = date_at_utc_offset(hours_east);
        let stdout = ok_stdout(out);
        let id = parse_added_id(&stdout);
        let s = stored(&vault, &id);
        assert!(
            s.title == before || s.title == after,
            "TZ={tz}: title {:?} is not the local date {before}/{after}",
            s.title
        );
        assert_eq!(stdout, c21("Created note", &id, &s.title), "TZ={tz}");
        assert_eq!(s.content_md, "<!-- memex:topics -->\n", "TZ={tz}");
        assert_eq!(s.frontmatter["role"], "daily", "TZ={tz}");
        assert_eq!(s.version, 1);
        assert_eq!(content_version(&vault, &id), 0);
    }
}

#[test]
fn add_role_daily_with_no_stdin_at_all_and_a_title_creates_an_empty_daily_note() {
    let (_dir, vault) = init_vault();
    let stdout = ok_stdout(run(
        &[
            "add",
            "--vault",
            &vault,
            "--role",
            "daily",
            "--title",
            "2026-09-05",
        ],
        None,
    ));
    let id = parse_added_id(&stdout);
    assert_eq!(stdout, c21("Created note", &id, "2026-09-05"));
    let s = stored(&vault, &id);
    assert_eq!(s.title, "2026-09-05");
    assert_eq!(s.content_md, "<!-- memex:topics -->\n");

    // Empty stdin stays an error without `--role daily`.
    for extra in [&[][..], &["--role", "topic"][..]] {
        let mut args = vec!["add", "--vault", &vault, "--title", "Empty"];
        args.extend_from_slice(extra);
        let v = error_json(&run(&args, Some("  \n")));
        assert_eq!(v["error"]["code"], "invalid_argument", "{extra:?}: {v}");
    }
    assert_eq!(note_ids(&vault), vec![id]);
}

#[test]
fn add_role_daily_with_body_stores_the_canonical_body_and_indexes_it() {
    let (_dir, vault) = init_vault();
    add_plain(&vault, "Player Loop", "jump, land, repeat");
    let id = add_daily(
        &vault,
        "2026-09-05",
        "Fixed the jump arc in [[Player Loop]].\n",
    );
    let s = stored(&vault, &id);
    assert_eq!(
        s.content_md,
        "Fixed the jump arc in [[Player Loop]].\n<!-- memex:topics -->\n"
    );
    assert_eq!(content_version(&vault, &id), 1);
    assert_indexed_from_stored_content(&vault, &id);
}

#[test]
fn add_role_daily_with_a_non_iso_title_fails_with_invalid_date() {
    let (_dir, vault) = init_vault();
    for bad in ["Groceries", "2026-02-30"] {
        let out = run(
            &["add", "--vault", &vault, "--role", "daily", "--title", bad],
            Some(""),
        );
        let v = error_json(&out);
        assert_eq!(v["error"]["code"], "invalid_date", "{bad}: {v}");
    }
    assert!(note_ids(&vault).is_empty());
}

// ---------- AC 17: an existing daily note -> daily_note_exists ----------

#[test]
fn add_role_daily_for_a_date_with_a_daily_note_fails_with_daily_note_exists() {
    let (_dir, vault) = init_vault();
    let existing = add_daily(&vault, "2026-09-05", "First.\n");

    for body in ["", "Second.\n"] {
        let out = run(
            &[
                "add",
                "--vault",
                &vault,
                "--role",
                "daily",
                "--title",
                "2026-09-05",
            ],
            Some(body),
        );
        let v = error_json(&out);
        let want = MemexError::DailyNoteExists {
            date: "2026-09-05".into(),
            existing_id: existing.clone(),
        }
        .to_error_json();
        assert_eq!(v, want, "{body:?}");
        assert_eq!(v["error"]["date"], "2026-09-05");
        assert_eq!(v["error"]["existing_id"], existing.as_str());
        assert!(
            out.stdout.is_empty(),
            "nothing on stdout: {}",
            describe(&out)
        );
    }
    assert_eq!(note_ids(&vault), vec![existing.clone()]);
    assert_eq!(
        stored(&vault, &existing).content_md,
        "First.\n<!-- memex:topics -->\n"
    );
}

// ---------- AC 18: Q2 adoption prints `Adopted note` ----------

#[test]
fn add_role_daily_over_a_role_less_note_adopts_it_and_prints_adopted_note() {
    let (_dir, vault) = init_vault();
    let old = add_plain(&vault, "2026-09-05", "old\n");
    assert_eq!(stored(&vault, &old).frontmatter.get("role"), None);

    let stdout = ok_stdout(run(
        &[
            "add",
            "--vault",
            &vault,
            "--role",
            "daily",
            "--title",
            "2026-09-05",
        ],
        Some(""),
    ));
    assert_eq!(stdout, c21("Adopted note", &old, "2026-09-05"));
    assert_eq!(
        parse_added_id(&stdout),
        old,
        "the Dart regex reads the existing id"
    );

    let s = stored(&vault, &old);
    assert_eq!(s.title, "2026-09-05");
    assert_eq!(s.frontmatter["role"], "daily");
    assert_eq!(s.content_md, "old\n<!-- memex:topics -->\n");
    assert_eq!(note_ids(&vault), vec![old.clone()]);
    assert_eq!(content_version(&vault, &old), 1);
    assert_indexed_from_stored_content(&vault, &old);

    // Once adopted it is the daily note: a second add is daily_note_exists.
    let v = error_json(&run(
        &[
            "add",
            "--vault",
            &vault,
            "--role",
            "daily",
            "--title",
            "2026-09-05",
        ],
        Some(""),
    ));
    assert_eq!(v["error"]["code"], "daily_note_exists");
    assert_eq!(v["error"]["existing_id"], old.as_str());
}

// ---------- AC 20: D8 after update and update-link on daily notes ----------

#[test]
fn update_of_a_daily_note_with_stray_text_reindexes_from_the_normalized_body() {
    let (_dir, vault) = init_vault();
    add_plain(&vault, "Player Loop", "jump, land, repeat");
    let id = add_daily(&vault, "2026-09-05", "Morning.\n");

    let out = ok_stdout(run(
        &[
            "update",
            "--vault",
            &vault,
            "--note-id",
            &id,
            "--expected-version",
            "1",
        ],
        Some("Morning.\n<!-- memex:topics -->\nSee [[Player Loop]] later\n"),
    ));
    let v: Value = serde_json::from_str(out.trim()).expect("update prints JSON");
    assert_eq!(v["version"], 2);

    let s = stored(&vault, &id);
    assert_eq!(
        s.content_md,
        "Morning.\nSee [[Player Loop]] later\n<!-- memex:topics -->\n"
    );
    assert_eq!(content_version(&vault, &id), 2);
    assert_indexed_from_stored_content(&vault, &id);
}

#[test]
fn update_link_on_a_daily_note_reindexes_from_the_normalized_body() {
    let (_dir, vault) = init_vault();
    let topic = add_plain(&vault, "Player Loop", "jump, land, repeat");
    let id = add_daily(&vault, "2026-09-05", "Worked on [[Player Loop]] today.\n");

    // A footer record made after the last save: the next daily write renders
    // it, so the saved body differs from the one update_link submitted.
    let link_id: String = {
        let v = Vault::open(&vault).unwrap();
        v.connection_ref()
            .execute(
                "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
                 VALUES (?, ?, 'person', 0)",
                [id.as_str(), topic.as_str()],
            )
            .unwrap();
        v.connection_ref()
            .query_row(
                "SELECT id FROM links WHERE from_note_id = ? AND link_text = 'Player Loop'",
                [id.as_str()],
                |r| r.get(0),
            )
            .unwrap()
    };

    ok_stdout(run(
        &[
            "update-link",
            "--vault",
            &vault,
            "--link-id",
            &link_id,
            "--kind",
            "extends",
        ],
        None,
    ));

    let s = stored(&vault, &id);
    assert_eq!(
        s.content_md,
        "Worked on [[Player Loop~extends]] today.\n<!-- memex:topics -->\n[[Player Loop~about]]\n"
    );
    assert_eq!(s.version, 2);
    assert_indexed_from_stored_content(&vault, &id);
}
