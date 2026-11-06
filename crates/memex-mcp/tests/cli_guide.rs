//! WI #256: `memex guide get|revisions|restore` (the frozen Contract). Drives
//! the real `memex` binary against temp vaults; agent writes to the guide go
//! through core, as `update_vault_guide` does.
//!
//! - `memex guide get --vault V` -> `{vault_id, note_id, version, content_md}`
//! - `memex guide revisions --vault V` -> `{vault_id, revisions: [{id, agent_change_id, created_at}]}`
//! - `memex guide restore --vault V --revision-id R` -> `{vault_id, note_id, version}`
//!
//! Failures exit 1 with one C1 JSON line on stderr.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use chrono::Local;
use memex_core::guide;
use memex_core::{Clock, Vault};
use serde_json::{json, Value};
use tempfile::TempDir;

const T0: i64 = 1_790_000_000_000;
const SEED_BODY: &str = "## Framework\n\n## Decisions\n";
const AGENT_TEXT: &str = "## Framework\n\nGames go under Design.\n\n## Decisions\n";
const NO_SUCH_ID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

struct StoppedClock(i64);

impl Clock for StoppedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

struct Fixture {
    _dir: TempDir,
    path: PathBuf,
}

impl Fixture {
    fn vault(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn open(&self) -> Vault {
        Vault::open(Path::new(&self.path)).unwrap()
    }

    fn vault_id(&self) -> String {
        self.open().vault_id().to_string()
    }

    fn notes(&self) -> i64 {
        self.open()
            .connection_ref()
            .query_row("SELECT count(*) FROM notes", [], |r| r.get(0))
            .unwrap()
    }

    /// The agent's `update_vault_guide`, over the guide's current version.
    /// Returns the guide's version after it.
    fn agent_update(&self, text: &str) -> i64 {
        let mut vault = self.open();
        let clock = StoppedClock(T0);
        let doc = guide::get_or_create(&mut vault, &clock, None).unwrap();
        guide::update(
            &mut vault,
            doc.version,
            text,
            &["Updated the framework".to_string()],
            "2026-09-05",
            &clock,
            None,
        )
        .unwrap()
        .version
    }

    /// The newest revision's id.
    fn newest_revision(&self) -> String {
        guide::revisions(&self.open()).unwrap()[0].id.clone()
    }
}

fn fresh() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    drop(Vault::create(&path).unwrap());
    Fixture { _dir: dir, path }
}

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

/// Exit 0 and exactly one JSON line on stdout.
fn ok_json(out: Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "exit 0; {}", describe(&out));
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

/// Exit 1, nothing on stdout and one C1 JSON line on stderr with `code`.
fn assert_c1_failure(out: &Output, code: &str) {
    assert_eq!(out.status.code(), Some(1), "exits 1; {}", describe(out));
    assert!(out.stdout.is_empty(), "no output; {}", describe(out));
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not one JSON line ({e}); {}", describe(out)));
    assert_eq!(v["error"]["code"], json!(code), "{v}");
    assert!(v["error"]["message"].is_string(), "{v}");
}

fn get(f: &Fixture) -> Output {
    run(&["guide", "get", "--vault", f.vault()])
}

fn revisions(f: &Fixture) -> Output {
    run(&["guide", "revisions", "--vault", f.vault()])
}

fn restore(f: &Fixture, id: &str) -> Output {
    run(&[
        "guide",
        "restore",
        "--vault",
        f.vault(),
        "--revision-id",
        id,
    ])
}

// ---------- AC 1 and 5: `guide get` ----------

#[test]
fn guide_get_creates_the_guide_on_first_call_and_prints_the_contract_object() {
    let f = fresh();
    assert_eq!(f.notes(), 0, "precondition: migration makes no guide");

    let got = ok_json(get(&f));

    assert_eq!(f.notes(), 1, "the first read created the guide");
    let (id, role, version): (String, String, i64) = f
        .open()
        .connection_ref()
        .query_row(
            "SELECT id, json_extract(frontmatter, '$.role'), version FROM notes",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(role, "guide");
    assert_eq!(
        got,
        json!({
            "vault_id": f.vault_id(),
            "note_id": id,
            "version": version,
            "content_md": SEED_BODY,
        })
    );
}

#[test]
fn guide_get_on_a_later_call_returns_the_same_guide_and_creates_nothing() {
    let f = fresh();
    let first = ok_json(get(&f));

    let second = ok_json(get(&f));

    assert_eq!(second, first);
    assert_eq!(f.notes(), 1, "still one note");
}

// ---------- AC 1: `guide revisions` ----------

#[test]
fn guide_revisions_prints_the_contract_object() {
    let f = fresh();
    assert_eq!(
        ok_json(revisions(&f)),
        json!({ "vault_id": f.vault_id(), "revisions": [] }),
        "a vault with no agent write lists none"
    );

    f.agent_update(AGENT_TEXT);

    let vault = f.open();
    let (id, change): (String, String) = vault
        .connection_ref()
        .query_row(
            "SELECT id, agent_change_id FROM vault_guide_revisions",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        ok_json(revisions(&f)),
        json!({
            "vault_id": f.vault_id(),
            "revisions": [{ "id": id, "agent_change_id": change, "created_at": T0 }],
        })
    );
}

#[test]
fn guide_revisions_lists_the_newest_first() {
    let f = fresh();
    f.agent_update("First rewrite.\n");
    let older = f.newest_revision();
    f.agent_update("Second rewrite.\n");
    let newer = f.newest_revision();
    assert_ne!(older, newer);

    let got = ok_json(revisions(&f));

    let ids: Vec<&str> = got["revisions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, [newer.as_str(), older.as_str()]);
}

// ---------- AC 1 and 5: `guide restore` ----------

#[test]
fn guide_restore_prints_the_contract_object_and_restores_the_text() {
    let f = fresh();
    let version = f.agent_update(AGENT_TEXT);
    let revision = f.newest_revision();
    let guide_id = ok_json(get(&f))["note_id"].clone();

    let got = ok_json(restore(&f, &revision));

    assert_eq!(
        got,
        json!({
            "vault_id": f.vault_id(),
            "note_id": guide_id,
            "version": version + 1,
        })
    );
    let after = ok_json(get(&f));
    assert_eq!(after["content_md"], json!(SEED_BODY), "{after}");
    assert_eq!(after["version"], json!(version + 1), "{after}");
}

#[test]
fn guide_restore_keeps_the_replaced_text_as_a_revision_to_return_to() {
    let f = fresh();
    f.agent_update(AGENT_TEXT);
    let revision = f.newest_revision();

    ok_json(restore(&f, &revision));

    let listed = ok_json(revisions(&f));
    let rows = listed["revisions"].as_array().unwrap();
    assert_eq!(rows.len(), 2, "the restore kept a revision: {listed}");
    let kept = rows[0]["id"].as_str().unwrap();
    assert_ne!(kept, revision);
    // Restoring that revision brings back the text the restore replaced.
    ok_json(restore(&f, kept));
    assert_eq!(ok_json(get(&f))["content_md"], json!(AGENT_TEXT));
}

/// Lead decision 5: the entry's `day` is today on the surface's clock, never a
/// supplied string; the CLI's clock is the wall clock in the local zone.
#[test]
fn guide_restore_dates_its_activity_entry_today() {
    let f = fresh();
    f.agent_update(AGENT_TEXT);
    let revision = f.newest_revision();

    let before = Local::now().date_naive().to_string();
    ok_json(restore(&f, &revision));
    let after = Local::now().date_naive().to_string();

    let (day, bullets): (String, String) = f
        .open()
        .connection_ref()
        .query_row(
            "SELECT day, bullets_json FROM agent_changes ORDER BY rowid DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert!(
        day == before || day == after,
        "{day} is {before} or {after}"
    );
    assert_eq!(bullets, r#"["Restored an earlier version"]"#);
}

// ---------- AC 2 and 5: failures ----------

#[test]
fn guide_restore_of_an_unknown_revision_is_not_found_and_changes_nothing() {
    let f = fresh();
    let before = ok_json(get(&f));

    assert_c1_failure(&restore(&f, NO_SUCH_ID), "not_found");

    assert_eq!(ok_json(get(&f)), before);
    assert_eq!(
        ok_json(revisions(&f)),
        json!({ "vault_id": f.vault_id(), "revisions": [] })
    );
}

#[test]
fn guide_restore_with_no_guide_yet_is_not_found() {
    let f = fresh();
    ok_json(revisions(&f));

    assert_c1_failure(&restore(&f, NO_SUCH_ID), "not_found");

    assert_eq!(f.notes(), 0, "restore creates no guide");
}

#[test]
fn memex_rm_on_the_guide_fails_with_guide_rule() {
    let f = fresh();
    let doc = ok_json(get(&f));
    let id = doc["note_id"].as_str().unwrap();
    let version = doc["version"].to_string();

    let out = run(&[
        "rm",
        "--vault",
        f.vault(),
        "--note-id",
        id,
        "--expected-version",
        &version,
    ]);

    assert_c1_failure(&out, "guide_rule");
    assert_eq!(ok_json(get(&f)), doc, "the guide is still there");
}

/// R26: a person's `memex folder add` on the guide fails with `guide_rule`.
#[test]
fn memex_folder_add_on_the_guide_fails_with_guide_rule() {
    let f = fresh();
    let id = ok_json(get(&f))["note_id"].as_str().unwrap().to_string();
    let folder = ok_json(run(&[
        "folder",
        "new",
        "--vault",
        f.vault(),
        "--name",
        "Design",
    ]));

    let out = run(&[
        "folder",
        "add",
        "--vault",
        f.vault(),
        "--id",
        folder["id"].as_str().unwrap(),
        "--note-id",
        &id,
    ]);

    assert_c1_failure(&out, "guide_rule");
}
