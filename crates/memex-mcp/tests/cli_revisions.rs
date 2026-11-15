//! WI #12 (Spec #7 Req 24, 27, 28, 37; rulings D11, D13, D14, D21): `memex
//! revisions list|restore`, the person's channel for a note's agent-edit
//! revisions. Drives the real `memex` binary against temp vaults (agent edits
//! go through core, as `edit_note` does), plus the shared ops
//! (`memex_mcp::ops::note_edits::{note_revisions, restore_note_revision}`) the
//! app API calls.
//!
//! Frozen output (D14):
//!
//! - `memex revisions list --vault V --note-id N` ->
//!   `{vault_id, revisions: [{id, agent_change_id | null, created_at}]}`,
//!   newest first; an unknown note is `not_found`.
//! - `memex revisions restore --vault V --revision-id R` ->
//!   `{vault_id, note_id, version, content_md}`; an unknown or pruned
//!   revision is `not_found`.
//!
//! Failures exit 1 with one C1 JSON line on stderr. The help texts are pinned
//! against `tests/golden/help/revisions*.txt` (D13).

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use chrono::{FixedOffset, Local, TimeZone, Utc};
use memex_core::note_edits::{self, EditInput, NoteRevision};
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{indexer, Caller, Clock, Vault};
use memex_mcp::cli::error_json;
use memex_mcp::ops::note_edits::{
    self as ops, NoteRevisionsInput, NoteRevisionsOutput, RestoreNoteRevisionInput,
    RestoreNoteRevisionOutput,
};
use serde_json::{json, Value};
use tempfile::TempDir;

const T0: i64 = 1_790_000_000_000;
const AGENT_DAY: &str = "2026-09-05";
const FIRST: &str = "The person's first text.\n";
const SECOND: &str = "The agent's second text.\n";
const THIRD: &str = "The agent's third text.\n";
const RESTORE_BULLET: &str = "Restored an earlier version";
/// A well-formed ULID no test vault holds.
const NO_SUCH_ID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

struct StoppedClock(i64);

impl Clock for StoppedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// A clock at `now` in a fixed UTC offset, whatever the machine's zone.
struct ZonedClock {
    now: i64,
    offset: FixedOffset,
}

impl Clock for ZonedClock {
    fn now_ms(&self) -> i64 {
        self.now
    }

    fn utc_offset_at(&self, _now_ms: i64) -> FixedOffset {
        self.offset
    }
}

// ---------- harness ----------

struct Fixture {
    _dir: TempDir,
    path: PathBuf,
}

/// One `note_revisions` row as the contract lists it.
#[derive(Debug, Clone, PartialEq)]
struct Row {
    id: String,
    agent_change_id: Option<String>,
    created_at: i64,
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

    /// A person-created note; returns its id.
    fn note(&self, title: &str, body: &str) -> String {
        let mut vault = self.open();
        let note = notes::create_note_as(
            &mut vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: None,
            },
            Caller::Person,
        )
        .unwrap_or_else(|e| panic!("create {title}: {e}"));
        indexer::reindex_note(
            vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            None,
        )
        .unwrap();
        note.id.to_string()
    }

    /// `(version, content_md)`.
    fn stored(&self, id: &str) -> (i64, String) {
        self.open()
            .connection_ref()
            .query_row(
                "SELECT version, content_md FROM notes WHERE id = ?",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    }

    /// The agent's `edit_note` (Form B) of `id` to `text` at `at`; returns the
    /// note's version after it.
    fn agent_rewrite(&self, id: &str, text: &str, at: i64) -> i64 {
        let mut vault = self.open();
        let note_id = NoteId::parse(id).unwrap();
        let version = self.stored(id).0;
        let out = note_edits::edit_note(
            &mut vault,
            EditInput {
                note_id,
                bullets: vec!["Rewrote the note".to_string()],
                edits: None,
                content_md: Some(text.to_string()),
                expected_version: Some(version),
            },
            AGENT_DAY,
            &StoppedClock(at),
            None,
        )
        .unwrap_or_else(|e| panic!("edit_note {id}: {e}"));
        assert!(out.changed, "the edit wrote");
        out.version
    }

    /// The note's revisions, newest first, from SQLite.
    fn rows(&self, id: &str) -> Vec<Row> {
        let vault = self.open();
        let mut stmt = vault
            .connection_ref()
            .prepare(
                "SELECT id, agent_change_id, created_at FROM note_revisions
                 WHERE note_id = ? ORDER BY new_version DESC",
            )
            .unwrap();
        stmt.query_map([id], |r| {
            Ok(Row {
                id: r.get(0)?,
                agent_change_id: r.get(1)?,
                created_at: r.get(2)?,
            })
        })
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
    }

    fn newest(&self, id: &str) -> Row {
        self.rows(id).into_iter().next().expect("a revision")
    }

    fn revision_count(&self) -> i64 {
        self.open()
            .connection_ref()
            .query_row("SELECT count(*) FROM note_revisions", [], |r| r.get(0))
            .unwrap()
    }

    fn change_count(&self) -> i64 {
        self.open()
            .connection_ref()
            .query_row("SELECT count(*) FROM agent_changes", [], |r| r.get(0))
            .unwrap()
    }

    /// `(note_id, day, bullets_json)` of an `agent_changes` row.
    fn change(&self, change_id: &str) -> (String, String, String) {
        self.open()
            .connection_ref()
            .query_row(
                "SELECT note_id, day, bullets_json FROM agent_changes WHERE id = ?",
                [change_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap()
    }

    fn flag(&self, id: &str) -> i64 {
        self.open()
            .connection_ref()
            .query_row(
                "SELECT agent_read_only FROM notes WHERE id = ?",
                [id],
                |r| r.get(0),
            )
            .unwrap()
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

/// Exit 0, an empty stderr and exactly one JSON line on stdout.
fn ok_json(out: Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "exit 0; {}", describe(&out));
    assert!(out.stderr.is_empty(), "no stderr; {}", describe(&out));
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let line = stdout.strip_suffix('\n').unwrap_or(&stdout);
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be one line: {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout not JSON ({e}): {stdout}"))
}

fn ok_stdout(out: Output) -> String {
    assert_eq!(out.status.code(), Some(0), "exit 0; {}", describe(&out));
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

/// Exit 1, nothing on stdout and one C1 JSON line on stderr with `code`.
fn assert_c1_failure(out: &Output, code: &str) {
    assert_eq!(out.status.code(), Some(1), "exits 1; {}", describe(out));
    assert!(out.stdout.is_empty(), "no output; {}", describe(out));
    let stderr = String::from_utf8(out.stderr.clone()).unwrap();
    let line = stderr.strip_suffix('\n').unwrap_or(&stderr);
    assert!(!line.contains('\n'), "one stderr line; {}", describe(out));
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not one JSON line ({e}); {}", describe(out)));
    assert_eq!(v["error"]["code"], json!(code), "{v}");
    assert!(v["error"]["message"].is_string(), "{v}");
}

fn list(f: &Fixture, id: &str) -> Output {
    run(&["revisions", "list", "--vault", f.vault(), "--note-id", id])
}

fn restore(f: &Fixture, revision_id: &str) -> Output {
    run(&[
        "revisions",
        "restore",
        "--vault",
        f.vault(),
        "--revision-id",
        revision_id,
    ])
}

fn row_json(r: &Row) -> Value {
    json!({ "id": r.id, "agent_change_id": r.agent_change_id, "created_at": r.created_at })
}

// ---------- AC 6: revisions list ----------

#[test]
fn revisions_list_prints_the_contract_object() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    assert_eq!(
        ok_json(list(&f, &id)),
        json!({ "vault_id": f.vault_id(), "revisions": [] }),
        "a note no agent edited lists none"
    );

    f.agent_rewrite(&id, SECOND, T0);

    let row = f.newest(&id);
    assert!(row.agent_change_id.is_some(), "precondition: linked");
    assert_eq!(
        ok_json(list(&f, &id)),
        json!({
            "vault_id": f.vault_id(),
            "revisions": [{
                "id": row.id,
                "agent_change_id": row.agent_change_id,
                "created_at": T0,
            }],
        })
    );
}

/// Newest first is by the write order, not by `created_at`: a wall clock
/// that jumped back (NTP, a manual change) does not reorder the list.
#[test]
fn revisions_list_prints_the_newest_first_even_when_the_clock_went_back() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0 + 2_000);
    let oldest = f.newest(&id);
    f.agent_rewrite(&id, THIRD, T0 + 1_000);
    let middle = f.newest(&id);
    f.agent_rewrite(&id, "The agent's fourth text.\n", T0);
    let newest = f.newest(&id);

    let got = ok_json(list(&f, &id));

    assert_eq!(
        got["revisions"],
        json!([row_json(&newest), row_json(&middle), row_json(&oldest)]),
        "{got}"
    );
}

#[test]
fn revisions_list_shows_a_null_agent_change_id_once_its_entry_is_gone() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0);
    let row = f.newest(&id);
    f.open()
        .connection_ref()
        .execute(
            "UPDATE note_revisions SET agent_change_id = NULL WHERE id = ?",
            [&row.id],
        )
        .unwrap();

    let got = ok_json(list(&f, &id));

    let listed = &got["revisions"][0];
    let keys: Vec<&String> = listed.as_object().unwrap().keys().collect();
    assert_eq!(
        keys.len(),
        3,
        "id, agent_change_id and created_at, the null kept: {got}"
    );
    assert_eq!(
        *listed,
        json!({ "id": row.id, "agent_change_id": null, "created_at": T0 }),
        "{got}"
    );
}

#[test]
fn revisions_list_lists_only_that_notes_revisions() {
    let f = fresh();
    let a = f.note("Plan", FIRST);
    let b = f.note("Other", "Another note.\n");
    f.agent_rewrite(&a, SECOND, T0);
    f.agent_rewrite(&b, "Another, rewritten.\n", T0 + 1);
    let a_row = f.newest(&a);

    let got = ok_json(list(&f, &a));

    assert_eq!(got["revisions"], json!([row_json(&a_row)]), "{got}");
}

#[test]
fn revisions_list_of_an_unknown_note_is_not_found() {
    let f = fresh();
    f.note("Plan", FIRST);

    assert_c1_failure(&list(&f, NO_SUCH_ID), "not_found");
}

/// A note id that is not a ULID fails like the other `--note-id` commands.
#[test]
fn revisions_list_with_a_malformed_note_id_is_invalid_id() {
    let f = fresh();
    f.note("Plan", FIRST);

    assert_c1_failure(&list(&f, "not-a-ulid"), "invalid_id");
}

// ---------- AC 7: revisions restore ----------

#[test]
fn revisions_restore_prints_the_contract_object_and_restores_the_text() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    let edited = f.agent_rewrite(&id, SECOND, T0);
    let revision = f.newest(&id).id;

    let got = ok_json(restore(&f, &revision));

    let (version, content_md) = f.stored(&id);
    assert_eq!(version, edited + 1, "a restore is one write");
    assert_eq!(content_md, FIRST, "the text the agent replaced is back");
    assert_eq!(
        got,
        json!({
            "vault_id": f.vault_id(),
            "note_id": id,
            "version": version,
            "content_md": content_md,
        })
    );
}

#[test]
fn revisions_restore_keeps_the_replaced_text_as_a_new_revision_dated_today() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0);
    let revision = f.newest(&id);

    let before = Local::now().date_naive().to_string();
    ok_json(restore(&f, &revision.id));
    let after = Local::now().date_naive().to_string();

    let listed = ok_json(list(&f, &id));
    let rows = listed["revisions"].as_array().unwrap();
    assert_eq!(rows.len(), 2, "the restore kept a revision: {listed}");
    let kept = f.newest(&id);
    assert_ne!(kept.id, revision.id);
    assert_eq!(rows[0]["id"], json!(kept.id), "{listed}");
    let change_id = kept.agent_change_id.clone().expect("linked to an entry");
    let (note_id, day, bullets) = f.change(&change_id);
    assert_eq!(note_id, id);
    assert!(
        day == before || day == after,
        "{day} is {before} or {after}"
    );
    assert_eq!(bullets, format!(r#"["{RESTORE_BULLET}"]"#));

    // Restoring the kept revision brings back the text the restore replaced.
    let back = ok_json(restore(&f, &kept.id));
    assert_eq!(back["content_md"], json!(SECOND), "{back}");
    assert_eq!(f.stored(&id).1, SECOND);
}

/// Req 27: Restore is a person write, so a note flagged Agent read-only is
/// restored too, and keeps its flag.
#[test]
fn revisions_restore_works_on_an_agent_read_only_note_and_keeps_the_flag() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0);
    let revision = f.newest(&id).id;
    ok_json(run(&[
        "read-only",
        "set",
        "--vault",
        f.vault(),
        "--note-id",
        &id,
    ]));

    let got = ok_json(restore(&f, &revision));

    assert_eq!(got["content_md"], json!(FIRST), "{got}");
    assert_eq!(f.stored(&id).1, FIRST);
    assert_eq!(f.flag(&id), 1, "Restore leaves the flag alone");
}

#[test]
fn revisions_restore_of_an_unknown_or_pruned_revision_is_not_found_and_writes_nothing() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0);
    let pruned = f.newest(&id).id;
    // 20 more agent edits: the vault keeps the newest 20 revisions (Req 24),
    // so the first one is pruned.
    for i in 0..20 {
        f.agent_rewrite(&id, &format!("Agent text number {i}.\n"), T0 + 1 + i);
    }
    assert!(
        f.rows(&id).iter().all(|r| r.id != pruned),
        "precondition: pruned"
    );
    let before = (f.stored(&id), f.revision_count(), f.change_count());

    assert_c1_failure(&restore(&f, NO_SUCH_ID), "not_found");
    assert_c1_failure(&restore(&f, &pruned), "not_found");

    assert_eq!(
        (f.stored(&id), f.revision_count(), f.change_count()),
        before,
        "nothing written"
    );
}

// ---------- AC 12: help ----------

fn golden(file: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/help")
        .join(format!("{file}.txt"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn revisions_help_texts_match_their_goldens() {
    let mut mismatches = Vec::new();
    for (args, file) in [
        ("revisions", "revisions"),
        ("revisions list", "revisions_list"),
        ("revisions restore", "revisions_restore"),
    ] {
        let mut argv: Vec<&str> = args.split(' ').collect();
        argv.push("--help");
        let got = ok_stdout(run(&argv));
        let want = golden(file);
        if got != want {
            mismatches.push(format!(
                "memex {args} --help\n--- golden\n{want}--- got\n{got}"
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn top_level_help_lists_revisions() {
    let help = ok_stdout(run(&["--help"]));
    let rows: Vec<&str> = help
        .lines()
        .map(str::trim_start)
        .filter(|l| l.starts_with("revisions "))
        .collect();
    assert_eq!(rows.len(), 1, "{help}");
    let about = rows[0].trim_start_matches("revisions").trim_start();
    assert_eq!(
        about,
        "List or restore the earlier texts agent edits kept of a note"
    );
}

// ---------- the shared ops (the seam the app API calls) ----------

fn ops_list(vault: &mut Vault, id: &str) -> anyhow::Result<NoteRevisionsOutput> {
    let input = NoteRevisionsInput {
        note_id: id.to_string(),
    };
    ops::note_revisions(vault, input, &StoppedClock(T0) as &dyn Clock, None)
}

fn ops_restore(
    vault: &mut Vault,
    revision_id: &str,
    note_id: Option<&str>,
    clock: &dyn Clock,
) -> anyhow::Result<RestoreNoteRevisionOutput> {
    let input = RestoreNoteRevisionInput {
        revision_id: revision_id.to_string(),
        note_id: note_id.map(str::to_string),
    };
    ops::restore_note_revision(vault, input, clock, None)
}

fn code_of<T: std::fmt::Debug>(result: anyhow::Result<T>) -> String {
    match result {
        Ok(out) => panic!("expected a failure, got {out:?}"),
        Err(e) => error_json(&e)["error"]["code"]
            .as_str()
            .unwrap()
            .to_string(),
    }
}

#[test]
fn ops_note_revisions_returns_the_frozen_object() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0);
    f.agent_rewrite(&id, THIRD, T0 + 1);
    let rows = f.rows(&id);
    let mut vault = f.open();

    let out = ops_list(&mut vault, &id).unwrap();

    assert_eq!(out.vault_id, f.vault_id());
    let want: Vec<NoteRevision> = rows
        .iter()
        .map(|r| NoteRevision {
            id: r.id.clone(),
            agent_change_id: r.agent_change_id.clone(),
            created_at: r.created_at,
        })
        .collect();
    assert_eq!(out.revisions, want, "newest first");
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        json!({
            "vault_id": f.vault_id(),
            "revisions": [row_json(&rows[0]), row_json(&rows[1])],
        })
    );
    assert_eq!(code_of(ops_list(&mut vault, NO_SUCH_ID)), "not_found");
}

/// D11: the API passes its path's `note_id`; a revision of another note is
/// `not_found` and writes nothing, the owning note restores.
#[test]
fn ops_restore_note_revision_with_another_notes_id_is_not_found_and_writes_nothing() {
    let f = fresh();
    let owner = f.note("Plan", FIRST);
    let other = f.note("Other", "Another note.\n");
    f.agent_rewrite(&owner, SECOND, T0);
    let revision = f.newest(&owner).id;
    let before = (
        f.stored(&owner),
        f.stored(&other),
        f.revision_count(),
        f.change_count(),
    );
    let mut vault = f.open();
    let clock = StoppedClock(T0 + 5_000);

    assert_eq!(
        code_of(ops_restore(&mut vault, &revision, Some(&other), &clock)),
        "not_found"
    );
    assert_eq!(
        code_of(ops_restore(&mut vault, &revision, Some(NO_SUCH_ID), &clock)),
        "not_found"
    );
    assert_eq!(
        (
            f.stored(&owner),
            f.stored(&other),
            f.revision_count(),
            f.change_count()
        ),
        before,
        "nothing written"
    );

    let out = ops_restore(&mut vault, &revision, Some(&owner), &clock).unwrap();
    let (version, content_md) = f.stored(&owner);
    assert_eq!(content_md, FIRST);
    assert_eq!(
        out,
        RestoreNoteRevisionOutput {
            vault_id: f.vault_id(),
            note_id: owner.clone(),
            version,
            content_md,
        }
    );
    assert_eq!(
        serde_json::to_value(&out).unwrap(),
        json!({
            "vault_id": f.vault_id(),
            "note_id": owner,
            "version": version,
            "content_md": FIRST,
        })
    );
}

/// The path's `note_id` must be a ULID: a malformed one is `invalid_id` and
/// writes nothing, before any revision is looked up.
#[test]
fn ops_restore_note_revision_with_a_malformed_note_id_is_invalid_id_and_writes_nothing() {
    let f = fresh();
    let owner = f.note("Plan", FIRST);
    f.agent_rewrite(&owner, SECOND, T0);
    let revision = f.newest(&owner).id;
    let before = (f.stored(&owner), f.revision_count(), f.change_count());
    let mut vault = f.open();

    assert_eq!(
        code_of(ops_restore(
            &mut vault,
            &revision,
            Some("not-a-ulid"),
            &StoppedClock(T0 + 5_000)
        )),
        "invalid_id"
    );
    assert_eq!(code_of(ops_list(&mut vault, "not-a-ulid")), "invalid_id");
    assert_eq!(
        (f.stored(&owner), f.revision_count(), f.change_count()),
        before,
        "nothing written"
    );
}

#[test]
fn ops_restore_note_revision_without_a_note_id_restores_any_notes_revision() {
    let f = fresh();
    let id = f.note("Plan", FIRST);
    f.agent_rewrite(&id, SECOND, T0);
    let revision = f.newest(&id).id;
    let mut vault = f.open();

    let out = ops_restore(&mut vault, &revision, None, &StoppedClock(T0 + 1)).unwrap();

    assert_eq!(out.note_id, id);
    assert_eq!(out.content_md, FIRST);
    assert_eq!(
        code_of(ops_restore(
            &mut vault,
            NO_SUCH_ID,
            None,
            &StoppedClock(T0 + 2)
        )),
        "not_found"
    );
}

/// The entry is dated today in the clock's zone, and the kept revision is
/// stamped with the clock: 2026-11-05T12:00Z is 2026-11-06 at +14:00 and
/// 2026-11-05 at -12:00.
#[test]
fn ops_restore_note_revision_dates_its_entry_in_the_clocks_zone_and_stamps_the_clock() {
    let now = Utc
        .with_ymd_and_hms(2026, 11, 5, 12, 0, 0)
        .unwrap()
        .timestamp_millis();
    for (offset_s, day) in [(14 * 3600, "2026-11-06"), (-12 * 3600, "2026-11-05")] {
        let f = fresh();
        let id = f.note("Plan", FIRST);
        f.agent_rewrite(&id, SECOND, T0);
        let revision = f.newest(&id).id;
        let clock = ZonedClock {
            now,
            offset: FixedOffset::east_opt(offset_s).unwrap(),
        };
        let mut vault = f.open();

        ops_restore(&mut vault, &revision, Some(&id), &clock).unwrap();

        let kept = f.newest(&id);
        assert_eq!(kept.created_at, now, "at {offset_s}s");
        let (_, got_day, bullets) = f.change(&kept.agent_change_id.unwrap());
        assert_eq!(got_day, day, "at {offset_s}s");
        assert_eq!(bullets, format!(r#"["{RESTORE_BULLET}"]"#));
    }
}
