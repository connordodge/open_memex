//! WI #242 (T4b): `memex tag add|rm|ls`, `memex ls --tag`, `memex footer add
//! --note-id` and `memex add --tags` (Spec #234 R20, R34, R35, R37, R40, R45,
//! R46; rulings D10, D16, D28, D43). Drives the real `memex` binary against
//! temp vaults.
//!
//! | Command | Output |
//! |---|---|
//! | `memex tag add --vault V --note-id N --tag T` | `{"note_id","tag","origin":"person","changed","version"}` |
//! | `memex tag rm --vault V --note-id N --tag T` | `{"note_id","tag","removed","correction_id","version"}` |
//! | `memex tag ls --vault V` | `{"tags":[{"tag","note_count","system"}]}` |
//! | `memex tag ls --vault V --note-id N` | `{"note_id","tags":[{"tag","origin"}]}` |
//! | `memex ls --vault V --tag T [--limit L]` | today's `ls` output, filtered |
//! | `memex footer add --vault V --note-id N --topic-note-id T` | `{vault_id,daily_note_id,topic_note_id,origin,version}` |
//!
//! JSON is compared as parsed values. Rows the commands can't make (agent
//! tags, legacy names, guides) are written with `memex_core`, or raw SQL for a
//! legacy row, with the vault closed.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

use memex_core::notes::NoteId;
use memex_core::tags::{self, TagOrigin};
use memex_core::{guide, MemexError, SystemClock, Vault};
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use tempfile::TempDir;

const MARKER: &str = "<!-- memex:topics -->";
/// A valid ULID no note has.
const UNKNOWN: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

fn run(args: &[&str], stdin_body: Option<&str>) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn memex");
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

/// The C1 failure: exit 1, one JSON line on stderr. Returns `(code, message)`.
fn c1_error(out: &Output) -> (String, String) {
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
    let v: Value = serde_json::from_str(line)
        .unwrap_or_else(|e| panic!("stderr not JSON ({e}); {}", describe(out)));
    (
        v["error"]["code"].as_str().expect("error.code").to_string(),
        v["error"]["message"]
            .as_str()
            .expect("error.message")
            .to_string(),
    )
}

/// A temp vault and the commands the tests run on it.
struct Fx {
    _dir: TempDir,
    path: String,
}

impl Fx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault").to_str().unwrap().to_string();
        ok_stdout(run(&["init", &path], None));
        Self { _dir: dir, path }
    }

    fn v(&self) -> &str {
        &self.path
    }

    /// `memex add --title <title> <extra…>`; returns the note id.
    fn add(&self, title: &str, body: &str, extra: &[&str]) -> String {
        let mut args = vec!["add", "--vault", self.v(), "--title", title];
        args.extend(extra);
        let stdout = ok_stdout(run(&args, Some(body)));
        let re = Regex::new(r"note_id:\s*([0-9A-Z]{26})").unwrap();
        re.captures(&stdout)
            .unwrap_or_else(|| panic!("no note_id in add stdout: {stdout}"))[1]
            .to_string()
    }

    fn topic(&self, title: &str) -> String {
        self.add(title, "Topic body.\n", &["--role", "topic"])
    }

    fn tag_add(&self, note: &str, tag: &str) -> Output {
        run(
            &[
                "tag",
                "add",
                "--vault",
                self.v(),
                "--note-id",
                note,
                "--tag",
                tag,
            ],
            None,
        )
    }

    fn tag_rm(&self, note: &str, tag: &str) -> Output {
        run(
            &[
                "tag",
                "rm",
                "--vault",
                self.v(),
                "--note-id",
                note,
                "--tag",
                tag,
            ],
            None,
        )
    }

    fn tag_ls(&self) -> Value {
        ok_json(run(&["tag", "ls", "--vault", self.v()], None))
    }

    fn tag_ls_note(&self, note: &str) -> Output {
        run(&["tag", "ls", "--vault", self.v(), "--note-id", note], None)
    }

    fn ls(&self, extra: &[&str]) -> String {
        let mut args = vec!["ls", "--vault", self.v()];
        args.extend(extra);
        ok_stdout(run(&args, None))
    }

    /// A direct connection, for reads and for rows no command can make.
    fn db(&self) -> Connection {
        Connection::open(PathBuf::from(&self.path).join("memex.db")).expect("open memex.db")
    }

    fn vault(&self) -> Vault {
        Vault::open(&self.path).expect("open vault")
    }

    /// Writes a row the CLI refuses: a legacy name, as stored before V6.
    fn legacy_row(&self, note: &str, tag: &str) {
        self.db()
            .execute(
                "INSERT INTO tags (note_id, tag) VALUES (?, ?)",
                params![note, tag],
            )
            .unwrap();
    }

    fn set_updated_at(&self, note: &str, ms: i64) {
        self.db()
            .execute(
                "UPDATE notes SET updated_at = ? WHERE id = ?",
                params![ms, note],
            )
            .unwrap();
    }

    /// The stored `(origin, first_line)` of a tag on a note.
    fn row(&self, note: &str, tag: &str) -> Option<(String, Option<String>)> {
        let conn = self.db();
        let mut stmt = conn
            .prepare("SELECT origin, first_line FROM tags WHERE note_id = ? AND tag = ?")
            .unwrap();
        let mut rows = stmt
            .query_map(params![note, tag], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        rows.next().map(|r| r.unwrap())
    }

    fn tag_names(&self, note: &str) -> Vec<String> {
        let conn = self.db();
        let mut stmt = conn
            .prepare("SELECT tag FROM tags WHERE note_id = ? ORDER BY tag")
            .unwrap();
        let rows = stmt.query_map([note], |r| r.get(0)).unwrap();
        rows.map(|r| r.unwrap()).collect()
    }

    fn body(&self, note: &str) -> String {
        self.db()
            .query_row("SELECT content_md FROM notes WHERE id = ?", [note], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn version(&self, note: &str) -> i64 {
        self.db()
            .query_row("SELECT version FROM notes WHERE id = ?", [note], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn note_count(&self) -> i64 {
        self.db()
            .query_row("SELECT COUNT(*) FROM notes", [], |r| r.get(0))
            .unwrap()
    }

    fn correction_count(&self) -> i64 {
        self.db()
            .query_row("SELECT COUNT(*) FROM tag_corrections", [], |r| r.get(0))
            .unwrap()
    }

    /// `#tag` in another note's text puts `tag` in the vocabulary, then the
    /// agent applies it to `note`.
    fn agent_tag(&self, note: &str, tag: &str) {
        self.add(&format!("Vocabulary {tag}"), &format!("#{tag}\n"), &[]);
        let mut vault = self.vault();
        let write = tags::agent_tag_note(&mut vault, &parse_id(note), tag, None).unwrap();
        assert!(write.changed, "the agent's tag is new");
    }

    /// The vault's guide, created the only way the guide rule allows: on first read.
    fn guide(&self) -> String {
        let mut vault = self.vault();
        guide::get_or_create(&mut vault, &SystemClock, None)
            .unwrap()
            .note_id
    }
}

fn parse_id(id: &str) -> NoteId {
    NoteId::parse(id).unwrap()
}

// ---------------------------------------------------------------------------
// `memex tag add`
// ---------------------------------------------------------------------------

#[test]
fn tag_add_adds_a_bodyless_person_tag_with_footer_text() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    let before = f.version(&note);

    let out = ok_json(f.tag_add(&note, "work"));

    let version = f.version(&note);
    assert!(version > before, "a footer write moves the version");
    assert_eq!(
        out,
        json!({
            "note_id": note,
            "tag": "work",
            "origin": "person",
            "changed": true,
            "version": version,
        })
    );
    assert_eq!(
        f.row(&note, "work"),
        Some(("person".to_string(), None)),
        "a body-less person row has no first line"
    );
    assert_eq!(
        f.body(&note),
        format!("Plain text.\n{MARKER}\n#work\n"),
        "the person's text stays and the footer holds the tag"
    );
}

#[test]
fn tag_add_lifts_a_block_so_the_agent_can_apply_the_tag_again() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    f.agent_tag(&note, "pricing");
    ok_json(f.tag_rm(&note, "pricing"));
    let err = tags::agent_tag_note(&mut f.vault(), &parse_id(&note), "pricing", None).unwrap_err();
    assert!(
        matches!(err, MemexError::TagRemoved(_)),
        "blocked after the person's removal: {err:?}"
    );

    let added = ok_json(f.tag_add(&note, "pricing"));
    assert_eq!(added["changed"], true);

    let cleared_at: Option<i64> = f
        .db()
        .query_row(
            "SELECT cleared_at FROM tag_corrections WHERE note_id = ? AND tag = 'pricing'",
            [&note],
            |r| r.get(0),
        )
        .unwrap();
    assert!(cleared_at.is_some(), "the person's add clears the block");

    // Taken off again without a Correction: the agent may now re-apply it.
    let removed = ok_json(f.tag_rm(&note, "pricing"));
    assert_eq!(removed["correction_id"], Value::Null);
    let write = tags::agent_tag_note(&mut f.vault(), &parse_id(&note), "pricing", None)
        .expect("the block is gone");
    assert!(write.changed);
}

#[test]
fn tag_add_with_an_invalid_name_fails_with_invalid_argument_and_writes_nothing() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    let version = f.version(&note);
    let body = f.body(&note);
    for bad in ["not a tag!", "123", "a/b", "#", "", "work!"] {
        let out = f.tag_add(&note, bad);
        let (code, message) = c1_error(&out);
        assert_eq!(code, "invalid_argument", "{bad:?}: {message}");
    }
    assert!(f.tag_names(&note).is_empty(), "no row written");
    assert_eq!(f.version(&note), version, "no version moved");
    assert_eq!(f.body(&note), body, "no text written");
}

#[test]
fn tag_add_on_a_guide_note_fails_with_guide_rule() {
    let f = Fx::new();
    let guide = f.guide();
    let version = f.version(&guide);
    let out = f.tag_add(&guide, "work");
    let (code, _) = c1_error(&out);
    assert_eq!(code, "guide_rule");
    assert!(f.tag_names(&guide).is_empty(), "no row written");
    assert_eq!(f.version(&guide), version);
    assert!(!f.body(&guide).contains(MARKER), "a guide has no footer");
}

#[test]
fn tag_add_on_an_unknown_note_is_not_found_and_a_malformed_id_is_invalid_id() {
    let f = Fx::new();
    let (code, _) = c1_error(&f.tag_add(UNKNOWN, "work"));
    assert_eq!(code, "not_found");
    let (code, _) = c1_error(&f.tag_add("not-a-ulid", "work"));
    assert_eq!(code, "invalid_id");
}

#[test]
fn tag_add_lowercases_the_name_and_drops_a_leading_hash() {
    // R38, R45: `#Pricing` in a call means `pricing`.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    let out = ok_json(f.tag_add(&note, "#Pricing"));
    assert_eq!(out["tag"], "pricing");
    assert_eq!(f.tag_names(&note), ["pricing"]);
    assert_eq!(f.body(&note), format!("Plain text.\n{MARKER}\n#pricing\n"));
}

#[test]
fn tag_add_of_a_tag_the_note_has_changes_nothing() {
    let f = Fx::new();
    let note = f.add("Written", "About #work today.\n", &[]);
    ok_json(f.tag_add(&note, "extra"));
    let version = f.version(&note);
    let body = f.body(&note);

    for (tag, origin) in [("work", "body"), ("extra", "person")] {
        let out = ok_json(f.tag_add(&note, tag));
        assert_eq!(out["note_id"], note.as_str());
        assert_eq!(out["tag"], tag);
        assert_eq!(out["changed"], false, "{tag}");
        assert_eq!(out["version"], version, "{tag}: the version doesn't move");
        assert_eq!(f.row(&note, tag).unwrap().0, origin, "{tag}: keeps origin");
    }
    assert_eq!(f.body(&note), body, "no text written");
}

#[test]
fn tag_add_matches_a_legacy_stored_name_exactly_first() {
    // R38: the stored name first, so a legacy `Work` is not added again as
    // `work`, and the output names the row the call means.
    let f = Fx::new();
    let note = f.add("Legacy", "Legacy text.\n", &[]);
    f.legacy_row(&note, "Work");
    let out = ok_json(f.tag_add(&note, "Work"));
    assert_eq!(out["tag"], "Work");
    assert_eq!(out["changed"], false);
    assert_eq!(f.tag_names(&note), ["Work"]);
}

#[test]
fn tag_add_of_a_system_tag_writes_a_row_and_no_footer_text() {
    // R20: never in the footer. A row with no note write keeps the version.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    let version = f.version(&note);
    let out = ok_json(f.tag_add(&note, "inbox"));
    assert_eq!(out["tag"], "inbox");
    assert_eq!(out["changed"], true);
    assert_eq!(out["version"], version);
    assert_eq!(f.row(&note, "inbox"), Some(("person".to_string(), None)));
    assert_eq!(f.body(&note), "Plain text.\n");
}

#[test]
fn tag_add_on_a_daily_note_keeps_its_review_state() {
    // R16: a footer write moves `version` but never `content_version`.
    let f = Fx::new();
    let daily = f.add("2026-09-05", "Fixed the jump arc.\n", &["--role", "daily"]);
    let get = |note: &str| ok_json(run(&["get", "--vault", f.v(), "--note-id", note], None));
    let review = get(&daily)["review"].clone();

    let out = ok_json(f.tag_add(&daily, "jump"));

    assert_eq!(out["changed"], true);
    assert_eq!(get(&daily)["review"], review);
    assert_eq!(
        f.body(&daily),
        format!("Fixed the jump arc.\n{MARKER}\n#jump\n")
    );
}

// ---------------------------------------------------------------------------
// `memex tag rm`
// ---------------------------------------------------------------------------

#[test]
fn tag_rm_on_an_agent_tag_records_one_correction_and_returns_its_id() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    f.agent_tag(&note, "pricing");
    assert_eq!(f.body(&note), format!("Plain text.\n{MARKER}\n#pricing\n"));
    let before = f.version(&note);

    let out = ok_json(f.tag_rm(&note, "pricing"));

    let (id, title, kind, cleared_at): (i64, String, String, Option<i64>) = f
        .db()
        .query_row(
            "SELECT id, note_title, kind, cleared_at FROM tag_corrections
             WHERE note_id = ? AND tag = 'pricing'",
            [&note],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .unwrap();
    assert_eq!(f.correction_count(), 1, "one Correction");
    assert_eq!(
        (title.as_str(), kind.as_str(), cleared_at),
        ("Plain", "removed", None)
    );
    let version = f.version(&note);
    assert!(version > before, "the footer changed");
    assert_eq!(
        out,
        json!({
            "note_id": note,
            "tag": "pricing",
            "removed": true,
            "correction_id": id,
            "version": version,
        })
    );
    assert!(f.row(&note, "pricing").is_none(), "the row went");
    assert_eq!(f.body(&note), "Plain text.\n", "the footer went with it");
}

#[test]
fn tag_rm_on_a_system_tag_returns_a_null_correction_id() {
    // R20: an agent-origin `inbox`, as `create_note`'s auto-tags store it.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    tags::apply_tag(
        &mut f.vault(),
        &parse_id(&note),
        "inbox",
        TagOrigin::Agent,
        None,
    )
    .unwrap();
    let version = f.version(&note);

    let out = ok_json(f.tag_rm(&note, "inbox"));

    assert_eq!(
        out,
        json!({
            "note_id": note,
            "tag": "inbox",
            "removed": true,
            "correction_id": null,
            "version": version,
        })
    );
    assert!(f.row(&note, "inbox").is_none());
    assert_eq!(f.correction_count(), 0);
}

#[test]
fn tag_rm_on_a_person_tag_returns_a_null_correction_id() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    ok_json(f.tag_add(&note, "work"));

    let out = ok_json(f.tag_rm(&note, "work"));

    let version = f.version(&note);
    assert_eq!(
        out,
        json!({
            "note_id": note,
            "tag": "work",
            "removed": true,
            "correction_id": null,
            "version": version,
        })
    );
    assert_eq!(f.correction_count(), 0);
    assert_eq!(
        f.body(&note),
        "Plain text.\n",
        "the last item takes the marker"
    );
}

#[test]
fn tag_rm_on_a_body_tag_fails_and_names_deleting_the_text() {
    let f = Fx::new();
    let note = f.add("Written", "About #work today.\n", &[]);
    let version = f.version(&note);
    let body = f.body(&note);

    let out = f.tag_rm(&note, "work");

    let (code, message) = c1_error(&out);
    assert_eq!(code, "invalid_argument", "{message}");
    assert!(
        message.contains("delete the text"),
        "the error says to delete the text: {message}"
    );
    assert_eq!(f.row(&note, "work").unwrap().0, "body", "the row stays");
    assert_eq!(f.version(&note), version);
    assert_eq!(f.body(&note), body);
    assert_eq!(f.correction_count(), 0);
}

#[test]
fn tag_rm_on_a_missing_tag_returns_removed_false() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    let version = f.version(&note);

    let out = ok_json(f.tag_rm(&note, "gone"));

    assert_eq!(
        out,
        json!({
            "note_id": note,
            "tag": "gone",
            "removed": false,
            "correction_id": null,
            "version": version,
        })
    );
    assert_eq!(f.version(&note), version);
}

#[test]
fn tag_rm_on_an_unknown_note_is_not_found_and_a_malformed_id_is_invalid_id() {
    let f = Fx::new();
    let (code, _) = c1_error(&f.tag_rm(UNKNOWN, "work"));
    assert_eq!(code, "not_found");
    let (code, _) = c1_error(&f.tag_rm("not-a-ulid", "work"));
    assert_eq!(code, "invalid_id");
}

#[test]
fn tag_rm_input_means_the_stored_name_then_the_lowercased_one() {
    // R38, and the output names the row that went.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    ok_json(f.tag_add(&note, "work"));
    let out = ok_json(f.tag_rm(&note, "#Work"));
    assert_eq!(out["removed"], true);
    assert_eq!(out["tag"], "work");
    assert!(f.row(&note, "work").is_none());

    f.legacy_row(&note, "Legacy");
    f.legacy_row(&note, "legacy");
    let out = ok_json(f.tag_rm(&note, "Legacy"));
    assert_eq!(out["removed"], true);
    assert_eq!(out["tag"], "Legacy", "the exact row, not its lowercase");
    assert_eq!(f.tag_names(&note), ["legacy"]);
}

#[test]
fn tag_rm_removes_a_legacy_name_outside_the_grammar() {
    // R50: legacy rows stay as stored, and this is how a person removes one.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    f.legacy_row(&note, "two words");
    let out = ok_json(f.tag_rm(&note, "two words"));
    assert_eq!(out["removed"], true);
    assert_eq!(out["tag"], "two words");
    assert!(f.tag_names(&note).is_empty());
}

// ---------------------------------------------------------------------------
// `memex tag ls`
// ---------------------------------------------------------------------------

#[test]
fn tag_ls_lists_every_tag_with_its_note_count_and_system() {
    let f = Fx::new();
    let a = f.add("A", "About #work.\n", &[]);
    let b = f.add("B", "Also #work and #q3-plan.\n", &[]);
    ok_json(f.tag_add(&a, "footer-only"));
    ok_json(f.tag_add(&b, "inbox"));
    f.legacy_row(&a, "agent-authored");

    assert_eq!(
        f.tag_ls(),
        json!({"tags": [
            {"tag": "agent-authored", "note_count": 1, "system": true},
            {"tag": "footer-only", "note_count": 1, "system": false},
            {"tag": "inbox", "note_count": 1, "system": true},
            {"tag": "q3-plan", "note_count": 1, "system": false},
            {"tag": "work", "note_count": 2, "system": false},
        ]})
    );
}

#[test]
fn tag_ls_on_a_vault_with_no_tags_is_an_empty_list() {
    let f = Fx::new();
    f.add("Plain", "Plain text.\n", &[]);
    assert_eq!(f.tag_ls(), json!({"tags": []}));
}

#[test]
fn tag_ls_orders_mixed_case_tags_by_nocase_then_tag() {
    // D28.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    for name in ["beta", "Zeta", "Beta", "alpha", "BETA"] {
        f.legacy_row(&note, name);
    }
    let names: Vec<Value> = f.tag_ls()["tags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["tag"].clone())
        .collect();
    assert_eq!(names, ["alpha", "BETA", "Beta", "beta", "Zeta"]);
}

#[test]
fn tag_ls_with_note_id_lists_each_tag_and_its_origin() {
    let f = Fx::new();
    let note = f.add("Written", "About #written today.\n", &[]);
    f.agent_tag(&note, "applied");
    ok_json(f.tag_add(&note, "added"));
    tags::apply_tag(
        &mut f.vault(),
        &parse_id(&note),
        "inbox",
        TagOrigin::Agent,
        None,
    )
    .unwrap();
    let other = f.add("Other", "Plain text.\n", &[]);
    ok_json(f.tag_add(&other, "elsewhere"));

    assert_eq!(
        ok_json(f.tag_ls_note(&note)),
        json!({
            "note_id": note,
            "tags": [
                {"tag": "added", "origin": "person"},
                {"tag": "applied", "origin": "agent"},
                {"tag": "inbox", "origin": "agent"},
                {"tag": "written", "origin": "body"},
            ],
        })
    );
    let empty = f.add("Empty", "No tags.\n", &[]);
    assert_eq!(
        ok_json(f.tag_ls_note(&empty)),
        json!({"note_id": empty, "tags": []})
    );
}

#[test]
fn tag_ls_with_note_id_orders_mixed_case_tags_by_nocase_then_tag() {
    // D28 names `memex tag ls`; one order for both forms.
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    for name in ["beta", "Zeta", "Beta", "alpha"] {
        f.legacy_row(&note, name);
    }
    let out = ok_json(f.tag_ls_note(&note));
    let names: Vec<Value> = out["tags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["tag"].clone())
        .collect();
    assert_eq!(names, ["alpha", "Beta", "beta", "Zeta"]);
}

#[test]
fn tag_ls_with_an_unknown_note_is_not_found_and_a_malformed_id_is_invalid_id() {
    let f = Fx::new();
    let (code, _) = c1_error(&f.tag_ls_note(UNKNOWN));
    assert_eq!(code, "not_found");
    let (code, _) = c1_error(&f.tag_ls_note("not-a-ulid"));
    assert_eq!(code, "invalid_id");
}

// ---------------------------------------------------------------------------
// `memex ls --tag`
// ---------------------------------------------------------------------------

#[test]
fn ls_tag_lists_only_notes_with_that_tag_in_todays_output() {
    let f = Fx::new();
    let written = f.add("Written", "About #work.\n", &[]);
    let added = f.add("Added", "Plain text.\n", &[]);
    ok_json(f.tag_add(&added, "work"));
    let other = f.add("Other", "About #play.\n", &[]);
    f.set_updated_at(&written, 1_000);
    f.set_updated_at(&added, 3_000);
    f.set_updated_at(&other, 5_000);

    assert_eq!(
        f.ls(&["--tag", "work"]),
        format!("{added}  Added\n{written}  Written\n"),
        "any origin, most recently updated first, `<id>  <title>` lines"
    );
    assert_eq!(
        f.ls(&[]),
        format!("{other}  Other\n{added}  Added\n{written}  Written\n"),
        "no --tag lists every note"
    );
}

#[test]
fn ls_tag_applies_the_limit_after_the_filter() {
    let f = Fx::new();
    let older = f.add("Older", "About #work.\n", &[]);
    let newer = f.add("Newer", "About #work.\n", &[]);
    let newest = f.add("Newest", "About #play.\n", &[]);
    f.set_updated_at(&older, 1_000);
    f.set_updated_at(&newer, 3_000);
    f.set_updated_at(&newest, 5_000);

    assert_eq!(
        f.ls(&["--tag", "work", "--limit", "1"]),
        format!("{newer}  Newer\n"),
        "the newest note with the tag, though another note is newer"
    );
}

#[test]
fn ls_tag_input_means_the_stored_name_then_the_lowercased_one() {
    // R38.
    let f = Fx::new();
    let lower = f.add("Lower", "About #work.\n", &[]);
    assert_eq!(f.ls(&["--tag", "WORK"]), format!("{lower}  Lower\n"));
    assert_eq!(f.ls(&["--tag", "#Work"]), format!("{lower}  Lower\n"));

    let legacy = f.add("Legacy", "Legacy text.\n", &[]);
    f.legacy_row(&legacy, "Work");
    assert_eq!(f.ls(&["--tag", "Work"]), format!("{legacy}  Legacy\n"));
    assert_eq!(f.ls(&["--tag", "work"]), format!("{lower}  Lower\n"));
}

#[test]
fn ls_tag_with_no_match_lists_no_note() {
    let f = Fx::new();
    let note = f.add("Plain", "About #work.\n", &[]);
    let stdout = f.ls(&["--tag", "nobody"]);
    assert!(!stdout.contains(&note), "{stdout}");
    assert!(!stdout.contains("Plain"), "{stdout}");
}

// ---------------------------------------------------------------------------
// `memex footer add --note-id`
// ---------------------------------------------------------------------------

#[test]
fn footer_add_note_id_works_on_a_plain_note_and_daily_note_id_stays_an_alias() {
    let f = Fx::new();
    let topic = f.topic("Pricing");
    let plain = f.add("Plain", "Plain text.\n", &[]);
    let vault_id = f.vault().vault_id().to_string();

    let out = ok_json(run(
        &[
            "footer",
            "add",
            "--vault",
            f.v(),
            "--note-id",
            &plain,
            "--topic-note-id",
            &topic,
        ],
        None,
    ));

    assert_eq!(
        out,
        json!({
            "vault_id": vault_id,
            "daily_note_id": plain,
            "topic_note_id": topic,
            "origin": "person",
            "version": f.version(&plain),
        }),
        "the existing keys, with `daily_note_id` holding the note"
    );
    assert_eq!(
        f.body(&plain),
        format!("Plain text.\n{MARKER}\n[[Pricing~about]]\n"),
        "the chip is in the note's footer"
    );

    let daily = f.add("2026-09-05", "Fixed the jump arc.\n", &["--role", "daily"]);
    let out = ok_json(run(
        &[
            "footer",
            "add",
            "--vault",
            f.v(),
            "--daily-note-id",
            &daily,
            "--topic-note-id",
            &topic,
        ],
        None,
    ));
    assert_eq!(
        out,
        json!({
            "vault_id": vault_id,
            "daily_note_id": daily,
            "topic_note_id": topic,
            "origin": "person",
            "version": f.version(&daily),
        }),
        "--daily-note-id still works"
    );
}

#[test]
fn footer_add_note_id_keeps_the_rule_failures() {
    let f = Fx::new();
    let topic = f.topic("Pricing");
    let plain = f.add("Plain", "Plain text.\n", &[]);
    let guide = f.guide();
    let add = |note: &str, topic: &str| {
        run(
            &[
                "footer",
                "add",
                "--vault",
                f.v(),
                "--note-id",
                note,
                "--topic-note-id",
                topic,
            ],
            None,
        )
    };
    let (code, _) = c1_error(&add(&guide, &topic));
    assert_eq!(code, "guide_rule", "a guide has no footer");
    let (code, _) = c1_error(&add(&topic, &plain));
    assert_eq!(code, "role_rule", "the target must be a topic");
    let (code, _) = c1_error(&add(&topic, &topic));
    assert_eq!(code, "invalid_argument", "a note can't chip itself");
    let (code, _) = c1_error(&add(UNKNOWN, &topic));
    assert_eq!(code, "not_found");
}

// ---------------------------------------------------------------------------
// `memex add --tags`
// ---------------------------------------------------------------------------

#[test]
fn add_tags_stores_person_origin_with_footer_text_and_keeps_the_add_output() {
    let f = Fx::new();
    let stdout = ok_stdout(run(
        &["add", "--vault", f.v(), "--title", "Alpha", "--tags", "x,y"],
        Some("Alpha body.\n"),
    ));
    let note = Regex::new(r"note_id:\s*([0-9A-Z]{26})")
        .unwrap()
        .captures(&stdout)
        .unwrap()[1]
        .to_string();
    assert_eq!(
        stdout,
        format!("Created note\n  note_id: {note}\n  title:   Alpha\n  tags:    x, y\n"),
        "today's add output"
    );
    assert_eq!(f.row(&note, "x"), Some(("person".to_string(), None)));
    assert_eq!(f.row(&note, "y"), Some(("person".to_string(), None)));
    assert_eq!(
        f.body(&note),
        format!("Alpha body.\n{MARKER}\n#x\n#y\n"),
        "footer text in the same call"
    );
}

#[test]
fn add_tags_on_a_daily_note_puts_the_footer_text_below_the_marker() {
    let f = Fx::new();
    let daily = f.add(
        "2026-09-05",
        "Fixed the jump arc.\n",
        &["--role", "daily", "--tags", "jump"],
    );
    assert_eq!(f.row(&daily, "jump"), Some(("person".to_string(), None)));
    assert_eq!(
        f.body(&daily),
        format!("Fixed the jump arc.\n{MARKER}\n#jump\n")
    );
}

#[test]
fn add_tags_with_a_system_tag_stores_it_with_no_footer_text() {
    let f = Fx::new();
    let note = f.add("Alpha", "Alpha body.\n", &["--tags", "inbox,x"]);
    assert_eq!(f.row(&note, "inbox"), Some(("person".to_string(), None)));
    assert_eq!(f.body(&note), format!("Alpha body.\n{MARKER}\n#x\n"));
}

#[test]
fn add_tags_with_a_tag_written_in_the_body_keeps_the_body_row() {
    // `body` outranks the others (TD1), so no footer line repeats the text.
    let f = Fx::new();
    let note = f.add("Alpha", "About #x today.\n", &["--tags", "x"]);
    assert_eq!(
        f.row(&note, "x"),
        Some(("body".to_string(), Some("About #x today.".to_string())))
    );
    assert_eq!(f.body(&note), "About #x today.\n");
}

#[test]
fn add_tags_rejects_a_name_outside_the_grammar_and_writes_nothing() {
    // D43: validated up front, so the good name before it isn't kept either.
    let f = Fx::new();
    for tags in ["not a tag!", "good,not a tag!", "not a tag!,good", "123"] {
        let out = run(
            &["add", "--vault", f.v(), "--title", "Alpha", "--tags", tags],
            Some("Alpha body.\n"),
        );
        let (code, message) = c1_error(&out);
        assert_eq!(code, "invalid_argument", "{tags:?}: {message}");
        assert_eq!(f.note_count(), 0, "{tags:?}: no note was created");
    }
    assert_eq!(f.tag_ls(), json!({"tags": []}), "no tag was written");
}

// ---------------------------------------------------------------------------
// Contracts pinned in verify mode (the handoff's unpinned list)
// ---------------------------------------------------------------------------

/// A vault path that doesn't exist: a command that opens the vault first
/// fails with another code than `invalid_id`.
fn missing_vault(f: &Fx) -> String {
    format!("{}-missing", f.v())
}

#[test]
fn add_tags_index_the_note_without_its_footer_lines() {
    // The reindex runs after the tags and chunks only the person section,
    // so the footer tag lines are in no chunk (WI #418, Spec #391 req 1).
    let f = Fx::new();
    let note = f.add("Alpha", "Alpha body.\n", &["--tags", "x,y"]);
    let chunks: String = f
        .db()
        .query_row(
            "SELECT group_concat(content, ' ') FROM chunks WHERE note_id = ?",
            [&note],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!chunks.contains("#x"), "{chunks}");
    assert!(!chunks.contains("#y"), "{chunks}");
    assert!(!chunks.contains("memex:topics"), "{chunks}");
    assert!(chunks.contains("Alpha body."), "{chunks}");
}

#[test]
fn add_tags_accepts_a_leading_hash_and_stores_the_bare_name() {
    let f = Fx::new();
    let note = f.add("Alpha", "Alpha body.\n", &["--tags", "#x"]);
    assert_eq!(f.tag_names(&note), ["x"]);
    assert_eq!(f.body(&note), format!("Alpha body.\n{MARKER}\n#x\n"));
}

#[test]
fn add_tags_output_names_the_stored_name() {
    let f = Fx::new();
    let stdout = ok_stdout(run(
        &[
            "add",
            "--vault",
            f.v(),
            "--title",
            "Alpha",
            "--tags",
            "Work",
        ],
        Some("Alpha body.\n"),
    ));
    assert!(stdout.contains("  tags:    work\n"), "{stdout}");
}

#[test]
fn tag_commands_parse_the_note_id_before_they_open_the_vault() {
    let f = Fx::new();
    let gone = missing_vault(&f);
    let cases: [Vec<&str>; 4] = [
        vec![
            "tag",
            "add",
            "--vault",
            &gone,
            "--note-id",
            "nope",
            "--tag",
            "x",
        ],
        vec![
            "tag",
            "rm",
            "--vault",
            &gone,
            "--note-id",
            "nope",
            "--tag",
            "x",
        ],
        vec!["tag", "ls", "--vault", &gone, "--note-id", "nope"],
        vec![
            "footer",
            "add",
            "--vault",
            &gone,
            "--note-id",
            "nope",
            "--topic-note-id",
            UNKNOWN,
        ],
    ];
    for args in cases {
        let out = run(&args, None);
        let (code, message) = c1_error(&out);
        assert_eq!(code, "invalid_id", "{args:?}: {message}");
    }
}

#[test]
fn tag_ls_with_note_id_still_lists_a_note_whose_frontmatter_does_not_parse() {
    let f = Fx::new();
    let note = f.add("Plain", "About #work.\n", &[]);
    ok_json(f.tag_add(&note, "extra"));
    f.db()
        .execute(
            "UPDATE notes SET frontmatter = 'not json {' WHERE id = ?",
            [&note],
        )
        .unwrap();
    let out = ok_json(f.tag_ls_note(&note));
    assert_eq!(
        out,
        json!({"note_id": note, "tags": [
            {"tag": "extra", "origin": "person"},
            {"tag": "work", "origin": "body"},
        ]})
    );
}

#[test]
fn ls_tag_with_a_negative_limit_lists_every_match() {
    let f = Fx::new();
    let a = f.add("A", "About #work.\n", &[]);
    let b = f.add("B", "About #work.\n", &[]);
    let c = f.add("C", "About #work.\n", &[]);
    f.set_updated_at(&a, 1_000);
    f.set_updated_at(&b, 2_000);
    f.set_updated_at(&c, 3_000);
    assert_eq!(
        f.ls(&["--tag", "work", "--limit=-1"]),
        format!("{c}  C\n{b}  B\n{a}  A\n"),
        "no limit, as in `memex ls`"
    );
    assert_eq!(
        f.ls(&["--tag", "work", "--limit", "2"]),
        format!("{c}  C\n{b}  B\n")
    );
}

#[test]
fn tag_rm_of_a_tag_the_note_lacks_names_the_lowercased_bare_input() {
    let f = Fx::new();
    let note = f.add("Plain", "Plain text.\n", &[]);
    let out = ok_json(f.tag_rm(&note, "#Gone"));
    assert_eq!(out["tag"], "gone");
    assert_eq!(out["removed"], false);
}
