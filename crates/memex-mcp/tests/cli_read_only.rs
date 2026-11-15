//! WI #12 (Spec #7 Req 7, 7a, 37; rulings D5, D13, D14): `memex read-only
//! set|clear`, the person's channel for the Agent read-only flag. Drives the
//! real `memex` binary against temp vaults, plus the shared op
//! (`memex_mcp::ops::note_edits::set_agent_read_only`) the app API calls.
//!
//! Frozen output (D14): `{vault_id, note_id, agent_read_only}`.
//!
//! - Setting it on a daily note or on the Vault Guide is `role_rule`;
//!   clearing always works.
//! - Setting the value the note already has succeeds and writes nothing:
//!   `version`, `updated_at` and `content_revision.n` stay.
//! - An unknown note is `not_found`.
//!
//! Failures exit 1 with one C1 JSON line on stderr. The help texts are pinned
//! against `tests/golden/help/read_only*.txt` (D13: `cli_golden.rs` and
//! `memex.txt` are not edited).

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::notes::{self, CreateNote};
use memex_core::{indexer, Caller, Clock, SystemClock, Vault};
use memex_mcp::cli::error_json;
use memex_mcp::ops::note_edits::{self as ops, AgentReadOnlyOutput, SetAgentReadOnlyInput};
use serde_json::{json, Value};
use tempfile::TempDir;

/// A well-formed ULID no test vault holds.
const NO_SUCH_ID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

// ---------- harness ----------

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

    /// A person-created note with `frontmatter`; returns its id.
    fn note(&self, title: &str, body: &str, frontmatter: Option<Value>) -> String {
        let mut vault = self.open();
        let note = notes::create_note_as(
            &mut vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter,
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

    fn plain(&self) -> String {
        self.note("Pricing notes", "Tier one costs ten.\n", None)
    }

    fn topic(&self) -> String {
        self.note(
            "Pricing",
            "Pricing topic.\n",
            Some(json!({ "role": "topic" })),
        )
    }

    fn daily(&self) -> String {
        self.note(
            "2026-10-18",
            "Played the prototype.\n",
            Some(json!({ "role": "daily" })),
        )
    }

    fn guide(&self) -> String {
        let mut vault = self.open();
        memex_core::guide::get_or_create(&mut vault, &SystemClock, None)
            .expect("the Vault Guide is created on first read")
            .note_id
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

    /// Raw SQL, for states the setter refuses to make (a flagged daily note).
    fn raw_flag(&self, id: &str) {
        let n = self
            .open()
            .connection_ref()
            .execute("UPDATE notes SET agent_read_only = 1 WHERE id = ?", [id])
            .unwrap();
        assert_eq!(n, 1, "the note exists");
    }

    /// `(version, updated_at, title, content_md, frontmatter)`.
    fn stored(&self, id: &str) -> (i64, i64, String, String, String) {
        self.open()
            .connection_ref()
            .query_row(
                "SELECT version, updated_at, title, content_md, frontmatter
                 FROM notes WHERE id = ?",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap()
    }

    fn content_revision(&self) -> i64 {
        self.open()
            .connection_ref()
            .query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn notes(&self) -> i64 {
        self.open()
            .connection_ref()
            .query_row("SELECT count(*) FROM notes", [], |r| r.get(0))
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

/// Exit 0 and stdout as text.
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

fn set(f: &Fixture, id: &str) -> Output {
    run(&["read-only", "set", "--vault", f.vault(), "--note-id", id])
}

fn clear(f: &Fixture, id: &str) -> Output {
    run(&["read-only", "clear", "--vault", f.vault(), "--note-id", id])
}

fn contract(f: &Fixture, id: &str, on: bool) -> Value {
    json!({ "vault_id": f.vault_id(), "note_id": id, "agent_read_only": on })
}

// ---------- AC 1: set ----------

#[test]
fn read_only_set_on_a_plain_or_topic_note_prints_the_contract_object_and_sets_the_flag() {
    let f = fresh();
    for (what, id) in [("plain", f.plain()), ("topic", f.topic())] {
        let before = f.stored(&id);
        assert_eq!(f.flag(&id), 0, "{what}: precondition");

        let got = ok_json(set(&f, &id));

        assert_eq!(got, contract(&f, &id, true), "{what}");
        assert_eq!(f.flag(&id), 1, "{what}: the flag is set");
        assert_eq!(
            f.stored(&id),
            before,
            "{what}: version, updated_at, title, body and frontmatter stay (Req 7a)"
        );
    }
}

// ---------- AC 2: clear ----------

#[test]
fn read_only_clear_prints_agent_read_only_false_and_clears_the_flag() {
    let f = fresh();
    for (what, id) in [("plain", f.plain()), ("topic", f.topic())] {
        ok_json(set(&f, &id));
        assert_eq!(f.flag(&id), 1, "{what}: precondition");
        let before = f.stored(&id);

        let got = ok_json(clear(&f, &id));

        assert_eq!(got, contract(&f, &id, false), "{what}");
        assert_eq!(f.flag(&id), 0, "{what}: the flag is cleared");
        assert_eq!(f.stored(&id), before, "{what}: only the flag changed");
    }
}

#[test]
fn read_only_clear_on_a_note_without_the_flag_succeeds_and_writes_nothing() {
    let f = fresh();
    let id = f.plain();
    let before = (f.stored(&id), f.content_revision());

    let got = ok_json(clear(&f, &id));

    assert_eq!(got, contract(&f, &id, false));
    assert_eq!(f.flag(&id), 0);
    assert_eq!(
        (f.stored(&id), f.content_revision()),
        before,
        "nothing written"
    );
}

// ---------- AC 3: daily note and Vault Guide ----------

#[test]
fn read_only_set_on_a_daily_note_or_the_vault_guide_is_role_rule_and_writes_nothing() {
    let f = fresh();
    for (what, id) in [("daily note", f.daily()), ("Vault Guide", f.guide())] {
        let before = (f.stored(&id), f.content_revision());

        assert_c1_failure(&set(&f, &id), "role_rule");

        assert_eq!(f.flag(&id), 0, "{what}: the flag stays off");
        assert_eq!(
            (f.stored(&id), f.content_revision()),
            before,
            "{what}: nothing written"
        );
    }
}

#[test]
fn read_only_clear_on_a_daily_note_or_the_vault_guide_succeeds() {
    let f = fresh();
    for (what, id) in [("daily note", f.daily()), ("Vault Guide", f.guide())] {
        // Not flagged: clearing still answers.
        assert_eq!(
            ok_json(clear(&f, &id)),
            contract(&f, &id, false),
            "{what}: unflagged"
        );
        // Flagged by raw SQL (no person channel can make this state): clear
        // takes it off.
        f.raw_flag(&id);
        let before = f.stored(&id);

        assert_eq!(
            ok_json(clear(&f, &id)),
            contract(&f, &id, false),
            "{what}: flagged"
        );
        assert_eq!(f.flag(&id), 0, "{what}: cleared");
        assert_eq!(f.stored(&id), before, "{what}: only the flag changed");
    }
}

// ---------- AC 4: set again ----------

#[test]
fn read_only_set_on_an_already_flagged_note_succeeds_and_leaves_its_version_unchanged() {
    let f = fresh();
    let id = f.plain();
    ok_json(set(&f, &id));
    let before = (f.stored(&id), f.content_revision());

    let got = ok_json(set(&f, &id));

    assert_eq!(got, contract(&f, &id, true));
    assert_eq!(f.flag(&id), 1);
    assert_eq!(
        (f.stored(&id), f.content_revision()),
        before,
        "set again writes nothing: version, updated_at and content_revision stay"
    );
}

// ---------- AC 5: unknown note ----------

#[test]
fn read_only_set_and_clear_on_an_unknown_note_are_not_found() {
    let f = fresh();
    f.plain();
    let notes = f.notes();

    assert_c1_failure(&set(&f, NO_SUCH_ID), "not_found");
    assert_c1_failure(&clear(&f, NO_SUCH_ID), "not_found");

    assert_eq!(f.notes(), notes, "no note created");
}

/// A note id that is not a ULID fails like the other `--note-id` commands.
#[test]
fn read_only_set_with_a_malformed_note_id_is_invalid_id() {
    let f = fresh();

    assert_c1_failure(&set(&f, "not-a-ulid"), "invalid_id");
    assert_c1_failure(&clear(&f, "not-a-ulid"), "invalid_id");
}

#[test]
fn read_only_set_is_reported_by_memex_get() {
    let f = fresh();
    let id = f.plain();

    ok_json(set(&f, &id));
    let got = ok_json(run(&["get", "--vault", f.vault(), "--note-id", &id]));
    assert_eq!(got["agent_read_only"], json!(true), "{got}");

    ok_json(clear(&f, &id));
    let got = ok_json(run(&["get", "--vault", f.vault(), "--note-id", &id]));
    assert_eq!(got["agent_read_only"], json!(false), "{got}");
}

// ---------- AC 12: help ----------

fn golden(file: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/help")
        .join(format!("{file}.txt"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn read_only_help_texts_match_their_goldens() {
    let mut mismatches = Vec::new();
    for (args, file) in [
        ("read-only", "read_only"),
        ("read-only set", "read_only_set"),
        ("read-only clear", "read_only_clear"),
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
        // GLOSSARY: the flag is "Agent read-only", never locked, protected or
        // pinned (Pinned is the Smart Folder flag).
        let lower = got.to_lowercase();
        for word in ["lock", "protect", "pin"] {
            assert!(
                !lower.contains(word),
                "memex {args} --help mentions {word:?}"
            );
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn top_level_help_lists_read_only() {
    let help = ok_stdout(run(&["--help"]));
    let rows: Vec<&str> = help
        .lines()
        .map(str::trim_start)
        .filter(|l| l.starts_with("read-only "))
        .collect();
    assert_eq!(rows.len(), 1, "{help}");
    let about = rows[0].trim_start_matches("read-only").trim_start();
    assert_eq!(
        about,
        "Make a note read-only for agents, or let agents edit it again"
    );
}

// ---------- the shared op (the seam the app API calls) ----------

fn ops_set(vault: &mut Vault, id: &str, on: bool) -> anyhow::Result<AgentReadOnlyOutput> {
    let input = SetAgentReadOnlyInput {
        note_id: id.to_string(),
        agent_read_only: on,
    };
    ops::set_agent_read_only(vault, input, &SystemClock as &dyn Clock, None)
}

fn ops_code(result: anyhow::Result<AgentReadOnlyOutput>) -> String {
    match result {
        Ok(out) => panic!("expected a failure, got {out:?}"),
        Err(e) => error_json(&e)["error"]["code"]
            .as_str()
            .unwrap()
            .to_string(),
    }
}

#[test]
fn ops_set_agent_read_only_returns_the_frozen_object_for_set_and_clear() {
    let f = fresh();
    let id = f.plain();
    let mut vault = f.open();
    let vault_id = vault.vault_id().to_string();

    let on = ops_set(&mut vault, &id, true).unwrap();
    assert_eq!(
        on,
        AgentReadOnlyOutput {
            vault_id: vault_id.clone(),
            note_id: id.clone(),
            agent_read_only: true,
        }
    );
    assert_eq!(
        serde_json::to_value(&on).unwrap(),
        json!({ "vault_id": vault_id, "note_id": id, "agent_read_only": true })
    );
    assert_eq!(f.flag(&id), 1);

    // Set again: the flag the note has, not "what changed".
    let again = ops_set(&mut vault, &id, true).unwrap();
    assert!(again.agent_read_only, "{again:?}");

    let off = ops_set(&mut vault, &id, false).unwrap();
    assert_eq!(
        serde_json::to_value(&off).unwrap(),
        json!({ "vault_id": vault_id, "note_id": id, "agent_read_only": false })
    );
    assert_eq!(f.flag(&id), 0);

    let off_again = ops_set(&mut vault, &id, false).unwrap();
    assert!(!off_again.agent_read_only, "{off_again:?}");
    assert_eq!(off_again.note_id, id);
}

#[test]
fn ops_set_agent_read_only_failures_carry_the_cli_codes() {
    let f = fresh();
    let daily = f.daily();
    let guide = f.guide();
    let mut vault = f.open();

    assert_eq!(ops_code(ops_set(&mut vault, &daily, true)), "role_rule");
    assert_eq!(ops_code(ops_set(&mut vault, &guide, true)), "role_rule");
    assert_eq!(ops_code(ops_set(&mut vault, NO_SUCH_ID, true)), "not_found");
    assert_eq!(
        ops_code(ops_set(&mut vault, NO_SUCH_ID, false)),
        "not_found"
    );
    assert_eq!(f.flag(&daily), 0);
    assert_eq!(f.flag(&guide), 0);

    // Clearing them works.
    assert!(!ops_set(&mut vault, &daily, false).unwrap().agent_read_only);
    assert!(!ops_set(&mut vault, &guide, false).unwrap().agent_read_only);
}
