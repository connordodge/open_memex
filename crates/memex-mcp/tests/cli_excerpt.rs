//! WI #10 (R7): `memex excerpt rm` (CONTRACTS C2.4) and the additive
//! `transclusions` field of `memex get`. Drives the real `memex` binary
//! against temp vaults; the fixtures are built through core.
//!
//! C2.4 `memex excerpt rm --vault V --topic-note-id T --date YYYY-MM-DD --block-ids b7k2m9[,c3d4e5]`
//! (ids = the transclusion's endpoints: one id for a single block, `from,to` for a range)
//! `{"vault_id":"01HV…","topic_note_id":"01J9…","version":5}` (`version` = topic note's new version)
//! errors: `role_rule`, `not_found` (no such transclusion), `invalid_date`
//!
//! Failures exit 1 with one C1 JSON line on stderr. JSON is compared as
//! parsed values.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::excerpts;
use memex_core::feedback::{self, Feedback};
use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::review::{self, ChangeEntry};
use memex_core::{Caller, Clock, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
/// The C4 render-fixture daily note: blocks (0, b7k2m9), (1, c3d4e5), (2, f6g7h8).
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const DAY_BLOCK_IDS: [&str; 3] = ["b7k2m9", "c3d4e5", "f6g7h8"];
const TOPIC_BODY: &str = "All about the player loop.\n";

struct Fixture {
    _dir: TempDir,
    path: PathBuf,
    day: String,
    topic: String,
}

impl Fixture {
    fn vault(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn open(&self) -> Vault {
        Vault::open(Path::new(&self.path)).unwrap()
    }
}

/// A vault with the C4 fixture day `2026-09-05` and the topic `Player Loop`.
fn fresh() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let mut vault = Vault::create(&path).unwrap();
    let day = create(&mut vault, DAY, DAY_BODY, Some("daily"));
    for (ord, id) in DAY_BLOCK_IDS.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, day, ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "precondition: block at ord {ord}");
    }
    let topic = create(&mut vault, "Player Loop", TOPIC_BODY, Some("topic"));
    drop(vault);
    Fixture {
        _dir: dir,
        path,
        day,
        topic,
    }
}

fn create(vault: &mut Vault, title: &str, body: &str, role: Option<&str>) -> String {
    let note = notes::create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: role.map(|r| json!({ "role": r })),
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

/// Files `block_ids` of the fixture day into the topic through core, as the
/// agent's `add_excerpt` would.
fn add_excerpt(f: &Fixture, block_ids: &[&str]) {
    let mut vault = f.open();
    let ids: Vec<String> = block_ids.iter().map(|s| s.to_string()).collect();
    excerpts::add_excerpt(
        &mut vault,
        &NoteId::parse(&f.topic).unwrap(),
        DAY,
        &ids,
        Caller::Agent,
        None,
    )
    .unwrap_or_else(|e| panic!("add_excerpt {block_ids:?}: {e}"));
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

fn excerpt_rm(vault: &str, topic: &str, date: &str, block_ids: &str) -> Output {
    run(&[
        "excerpt",
        "rm",
        "--vault",
        vault,
        "--topic-note-id",
        topic,
        "--date",
        date,
        "--block-ids",
        block_ids,
    ])
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

/// Exit 1 and one C1 JSON line on stderr with `code`.
fn assert_c1_failure(out: &Output, code: &str) {
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
    assert_eq!(v["error"]["code"], json!(code), "{v}");
    let message = v["error"]["message"]
        .as_str()
        .unwrap_or_else(|| panic!("message: {v}"));
    if code == "role_rule" {
        assert!(message.contains("role"), "the message names the role: {v}");
    }
}

/// `(content_md, version)` of a note.
fn note_row(f: &Fixture, id: &str) -> (String, i64) {
    f.open()
        .connection_ref()
        .query_row(
            "SELECT content_md, version FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

/// `(topic_note_id, origin)` of the fixture day's chips, in rowid order.
fn chip_rows(f: &Fixture) -> Vec<(String, String)> {
    f.open()
        .connection_ref()
        .prepare(
            "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
        )
        .unwrap()
        .query_map([f.day.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Every note's `(id, content_md, version)` and every chip.
/// `(id, content_md, version)` of every note, and every chip row.
type Snapshot = (Vec<(String, String, i64)>, Vec<(String, String, String)>);

fn snapshot(f: &Fixture) -> Snapshot {
    let vault = f.open();
    let conn = vault.connection_ref();
    let notes = conn
        .prepare("SELECT id, content_md, version FROM notes ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let chips = conn
        .prepare("SELECT daily_note_id, topic_note_id, origin FROM footer_chips ORDER BY rowid")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    (notes, chips)
}

fn c24(f: &Fixture) -> Value {
    json!({
        "vault_id": f.open().vault_id(),
        "topic_note_id": f.topic,
        "version": note_row(f, &f.topic).1,
    })
}

// ---------- AC 16: C2.4 output ----------

#[test]
fn excerpt_rm_prints_the_c24_json_line_and_exits_zero() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9", "c3d4e5"]);
    let (_, before) = note_row(&f, &f.topic);

    let out = excerpt_rm(f.vault(), &f.topic, DAY, "b7k2m9,c3d4e5");

    let v = ok_json(out);
    assert_eq!(v, c24(&f), "exactly vault_id, topic_note_id, version");
    assert_eq!(
        v["version"],
        json!(before + 1),
        "the topic note's new version"
    );
    let (body, _) = note_row(&f, &f.topic);
    assert_eq!(body.trim_end(), TOPIC_BODY.trim_end(), "{body}");
    assert_eq!(chip_rows(&f), [], "the excerpt chip went with the excerpt");
}

#[test]
fn excerpt_rm_with_one_block_id_removes_a_single_block_token() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9", "f6g7h8"]);

    let v = ok_json(excerpt_rm(f.vault(), &f.topic, DAY, "f6g7h8"));

    assert_eq!(v, c24(&f));
    let (body, _) = note_row(&f, &f.topic);
    assert!(body.contains("![[2026-09-05#^b7k2m9]]"), "{body}");
    assert!(!body.contains("f6g7h8"), "{body}");
    assert_eq!(
        chip_rows(&f),
        [(f.topic.clone(), "excerpt".to_string())],
        "another excerpt from the day remains"
    );
}

#[test]
fn excerpt_rm_keeps_a_person_chip() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9"]);
    footer::set_chip(
        &mut f.open(),
        &NoteId::parse(&f.day).unwrap(),
        &NoteId::parse(&f.topic).unwrap(),
        ChipOrigin::Person,
        None,
    )
    .unwrap();

    let v = ok_json(excerpt_rm(f.vault(), &f.topic, DAY, "b7k2m9"));

    assert_eq!(v, c24(&f));
    assert_eq!(chip_rows(&f), [(f.topic.clone(), "person".to_string())]);
}

// ---------- AC 17: role_rule, not_found, invalid_date ----------

#[test]
fn excerpt_rm_on_a_non_topic_note_fails_with_role_rule() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9"]);
    let plain = create(
        &mut f.open(),
        "Loose note",
        "![[2026-09-05#^b7k2m9]]\n",
        None,
    );
    let before = snapshot(&f);

    assert_c1_failure(&excerpt_rm(f.vault(), &plain, DAY, "b7k2m9"), "role_rule");
    assert_c1_failure(&excerpt_rm(f.vault(), &f.day, DAY, "b7k2m9"), "role_rule");

    assert_eq!(snapshot(&f), before, "nothing written");
}

#[test]
fn excerpt_rm_with_an_unmatched_transclusion_fails_with_not_found() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9", "c3d4e5"]);
    let before = snapshot(&f);

    for ids in ["b7k2m9", "c3d4e5", "b7k2m9,f6g7h8", "zzzzzz"] {
        assert_c1_failure(&excerpt_rm(f.vault(), &f.topic, DAY, ids), "not_found");
    }
    assert_c1_failure(
        &excerpt_rm(f.vault(), &f.topic, "2026-09-06", "b7k2m9,c3d4e5"),
        "not_found",
    );
    assert_c1_failure(
        &excerpt_rm(
            f.vault(),
            "01J9Z8Y7X6W5V4T3S2R1Q0P9N8",
            DAY,
            "b7k2m9,c3d4e5",
        ),
        "not_found",
    );

    assert_eq!(snapshot(&f), before, "nothing written");
}

#[test]
fn excerpt_rm_with_a_malformed_date_fails_with_invalid_date() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9", "c3d4e5"]);
    let before = snapshot(&f);

    assert_c1_failure(
        &excerpt_rm(f.vault(), &f.topic, "2026-9-5", "b7k2m9,c3d4e5"),
        "invalid_date",
    );

    assert_eq!(snapshot(&f), before, "nothing written");
}

// ---------- AC 18: memex get includes `transclusions` ----------

fn memex_get(f: &Fixture, id: &str) -> Value {
    ok_json(run(&["get", "--vault", f.vault(), "--note-id", id]))
}

#[test]
fn memex_get_lists_transclusions_rendered_per_c4() {
    let f = fresh();
    let body = "## 2026-09-05\n\n\
                ![[2026-09-05#^b7k2m9]]\n\n\
                ![[2026-09-05#^b7k2m9..^c3d4e5]]\n\n\
                ![[2026-09-05#^zzzzzz]]\n\n\
                ![[2026-09-05#^b7k2m9..^zzzzzz]]\n\n\
                ![[2026-09-06#^b7k2m9]]\n";
    let fixtures = create(&mut f.open(), "Fixtures", body, Some("topic"));

    let v = memex_get(&f, &fixtures);

    assert_eq!(v["note_id"], json!(fixtures), "{v}");
    assert_eq!(
        v["transclusions"],
        json!([
            { "date": "2026-09-05", "from": "b7k2m9", "to": null,
              "text": "Fixed the jump arc." },
            { "date": "2026-09-05", "from": "b7k2m9", "to": "c3d4e5",
              "text": "Fixed the jump arc.\n- tried coyote time" },
            { "date": "2026-09-05", "from": "zzzzzz", "to": null,
              "text": "removed from 2026-09-05" },
            { "date": "2026-09-05", "from": "b7k2m9", "to": "zzzzzz",
              "text": "removed from 2026-09-05" },
            { "date": "2026-09-06", "from": "b7k2m9", "to": null,
              "text": "removed from 2026-09-06" },
        ]),
        "{v}"
    );
}

#[test]
fn memex_get_drops_transclusions_after_the_last_excerpt_is_removed() {
    let f = fresh();
    let plain = memex_get(&f, &f.topic);
    assert!(
        plain.get("transclusions").is_none(),
        "absent without tokens: {plain}"
    );
    add_excerpt(&f, &["c3d4e5"]);
    let v = memex_get(&f, &f.topic);
    assert_eq!(
        v["transclusions"],
        json!([
            { "date": "2026-09-05", "from": "c3d4e5", "to": null, "text": "- tried coyote time" },
        ]),
        "{v}"
    );

    ok_json(excerpt_rm(f.vault(), &f.topic, DAY, "c3d4e5"));

    let v = memex_get(&f, &f.topic);
    assert!(v["note_id"].is_string(), "{v}");
    assert!(
        v.get("transclusions").is_none(),
        "absent once the last token is gone: {v}"
    );
}

// ---------- Implementer addition (#10), lead ruling: blank ids ----------

#[test]
fn excerpt_rm_with_a_blank_block_id_fails_with_invalid_argument() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9"]);
    let before = snapshot(&f);

    for ids in ["", "b7k2m9,", ",b7k2m9"] {
        assert_c1_failure(
            &excerpt_rm(f.vault(), &f.topic, DAY, ids),
            "invalid_argument",
        );
    }

    assert_eq!(snapshot(&f), before, "nothing written");
}

// ---------------------------------------------------------------------------
// WI #256: `memex filing`, `excerpt add`, `excerpt remove-block`, `excerpt move`
//
// `memex filing --vault V --date D`
//   -> {vault_id, date, note_id, reviewed, topics: [{topic_note_id, title,
//      blocks: [{id, text}]}], not_filed: [{id, text}]}
// `memex excerpt add --vault V --topic-note-id T --date D --block-id B [--note TEXT]`
// `memex excerpt remove-block --vault V --topic-note-id T --date D --block-id B [--note TEXT]`
//   -> {vault_id, topic_note_id, version}
// `memex excerpt move --vault V --date D --block-id B --from-topic-note-id A
//      --to-topic-note-id C [--note TEXT]`
//   -> {vault_id, from_topic_note_id, from_version, to_topic_note_id, to_version}
// ---------------------------------------------------------------------------

const REVIEWED_AT: i64 = 1_790_000_000_000;
const NO_SUCH_NOTE: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

struct StoppedClock(i64);

impl Clock for StoppedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

fn second_topic(f: &Fixture) -> String {
    let mut vault = f.open();
    create(
        &mut vault,
        "Economy Design",
        "Sources and sinks.\n",
        Some("topic"),
    )
}

/// Files `block_ids` of the fixture day into `topic` as the agent would.
fn agent_files(f: &Fixture, topic: &str, block_ids: &[&str]) {
    let mut vault = f.open();
    let ids: Vec<String> = block_ids.iter().map(|s| s.to_string()).collect();
    excerpts::add_excerpt(
        &mut vault,
        &NoteId::parse(topic).unwrap(),
        DAY,
        &ids,
        Caller::Agent,
        None,
    )
    .unwrap_or_else(|e| panic!("add_excerpt {block_ids:?}: {e}"));
}

/// Marks the fixture day reviewed with one Activity entry on it.
fn review_day(f: &Fixture) {
    let mut vault = f.open();
    let version: i64 = vault
        .connection_ref()
        .query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [f.day.as_str()],
            |r| r.get(0),
        )
        .unwrap();
    review::mark_day_reviewed(
        &mut vault,
        DAY,
        version,
        &[ChangeEntry {
            note_id: f.day.clone(),
            bullets: vec!["Filed the jump notes".into()],
        }],
        &StoppedClock(REVIEWED_AT),
    )
    .unwrap();
}

fn filing(f: &Fixture, date: &str) -> Output {
    run(&["filing", "--vault", f.vault(), "--date", date])
}

fn excerpt_add(f: &Fixture, topic: &str, date: &str, block: &str, note: Option<&str>) -> Output {
    let mut args = vec![
        "excerpt",
        "add",
        "--vault",
        f.vault(),
        "--topic-note-id",
        topic,
        "--date",
        date,
        "--block-id",
        block,
    ];
    if let Some(note) = note {
        args.extend(["--note", note]);
    }
    run(&args)
}

fn excerpt_remove_block(
    f: &Fixture,
    topic: &str,
    date: &str,
    block: &str,
    note: Option<&str>,
) -> Output {
    let mut args = vec![
        "excerpt",
        "remove-block",
        "--vault",
        f.vault(),
        "--topic-note-id",
        topic,
        "--date",
        date,
        "--block-id",
        block,
    ];
    if let Some(note) = note {
        args.extend(["--note", note]);
    }
    run(&args)
}

fn excerpt_move(
    f: &Fixture,
    from: &str,
    to: &str,
    date: &str,
    block: &str,
    note: Option<&str>,
) -> Output {
    let mut args = vec![
        "excerpt",
        "move",
        "--vault",
        f.vault(),
        "--date",
        date,
        "--block-id",
        block,
        "--from-topic-note-id",
        from,
        "--to-topic-note-id",
        to,
    ];
    if let Some(note) = note {
        args.extend(["--note", note]);
    }
    run(&args)
}

/// The Corrections of the fixture day, oldest first.
fn corrections(f: &Fixture) -> Vec<Feedback> {
    let vault = f.open();
    let mut rows = feedback::list_for_note(&vault, Some(&f.day)).unwrap();
    rows.retain(|r| r.kind == "correction");
    rows.reverse();
    rows
}

/// The single Correction of the fixture day.
fn one_correction(f: &Fixture) -> Feedback {
    let mut rows = corrections(f);
    assert_eq!(rows.len(), 1, "exactly one Correction: {rows:?}");
    rows.remove(0)
}

// ---------- AC 1: the output objects ----------

#[test]
fn filing_prints_the_contract_object() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["b7k2m9", "c3d4e5"]);
    agent_files(&f, &economy, &["b7k2m9"]);
    review_day(&f);

    let got = ok_json(filing(&f, DAY));

    assert_eq!(
        got,
        json!({
            "vault_id": f.open().vault_id(),
            "date": DAY,
            "note_id": f.day,
            "reviewed": true,
            "topics": [
                {
                    "topic_note_id": economy,
                    "title": "Economy Design",
                    "blocks": [{"id": "b7k2m9", "text": "Fixed the jump arc."}],
                },
                {
                    "topic_note_id": f.topic,
                    "title": "Player Loop",
                    "blocks": [
                        {"id": "b7k2m9", "text": "Fixed the jump arc."},
                        {"id": "c3d4e5", "text": "- tried coyote time"},
                    ],
                },
            ],
            "not_filed": [{"id": "f6g7h8", "text": "Sleep was bad."}],
        })
    );
}

#[test]
fn filing_of_a_never_reviewed_day_is_reviewed_false_with_empty_lists() {
    let f = fresh();
    agent_files(&f, &f.topic, &["b7k2m9"]);

    let got = ok_json(filing(&f, DAY));

    assert_eq!(
        got,
        json!({
            "vault_id": f.open().vault_id(),
            "date": DAY,
            "note_id": f.day,
            "reviewed": false,
            "topics": [],
            "not_filed": [],
        })
    );
}

#[test]
fn excerpt_add_prints_the_contract_object_and_files_the_block() {
    let f = fresh();
    let (_, before) = note_row(&f, &f.topic);

    let got = ok_json(excerpt_add(&f, &f.topic, DAY, "c3d4e5", None));

    let (body, version) = note_row(&f, &f.topic);
    assert_eq!(version, before + 1, "the write bumped the topic once");
    assert_eq!(
        got,
        json!({
            "vault_id": f.open().vault_id(),
            "topic_note_id": f.topic,
            "version": version,
        })
    );
    assert!(body.contains("![[2026-09-05#^c3d4e5]]"), "{body}");
}

#[test]
fn excerpt_remove_block_prints_the_contract_object_and_splits_the_range() {
    let f = fresh();
    agent_files(&f, &f.topic, &["b7k2m9", "f6g7h8"]);
    let (_, before) = note_row(&f, &f.topic);

    let got = ok_json(excerpt_remove_block(&f, &f.topic, DAY, "c3d4e5", None));

    let (body, version) = note_row(&f, &f.topic);
    assert_eq!(version, before + 1, "the write bumped the topic once");
    assert_eq!(
        got,
        json!({
            "vault_id": f.open().vault_id(),
            "topic_note_id": f.topic,
            "version": version,
        })
    );
    assert!(body.contains("![[2026-09-05#^b7k2m9]]"), "{body}");
    assert!(body.contains("![[2026-09-05#^f6g7h8]]"), "{body}");
    assert!(!body.contains("c3d4e5"), "{body}");
}

#[test]
fn excerpt_move_prints_the_contract_object_and_moves_the_block() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["b7k2m9"]);
    let (_, from_before) = note_row(&f, &f.topic);
    let (_, to_before) = note_row(&f, &economy);

    let got = ok_json(excerpt_move(&f, &f.topic, &economy, DAY, "b7k2m9", None));

    let (from_body, from_version) = note_row(&f, &f.topic);
    let (to_body, to_version) = note_row(&f, &economy);
    assert_eq!(from_version, from_before + 1, "the source was written once");
    assert_eq!(to_version, to_before + 1, "the target was written once");
    assert_eq!(
        got,
        json!({
            "vault_id": f.open().vault_id(),
            "from_topic_note_id": f.topic,
            "from_version": from_version,
            "to_topic_note_id": economy,
            "to_version": to_version,
        })
    );
    assert!(!from_body.contains("b7k2m9"), "{from_body}");
    assert!(to_body.contains("![[2026-09-05#^b7k2m9]]"), "{to_body}");
}

/// R13: a fix applies with no model and leaves the day's Reviewed state alone,
/// and `memex filing` shows it.
#[test]
fn excerpt_fixes_show_in_filing_and_keep_the_day_reviewed() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["b7k2m9"]);
    review_day(&f);

    ok_json(excerpt_move(&f, &f.topic, &economy, DAY, "b7k2m9", None));
    ok_json(excerpt_add(&f, &f.topic, DAY, "f6g7h8", None));
    ok_json(excerpt_remove_block(&f, &economy, DAY, "b7k2m9", None));

    let got = ok_json(filing(&f, DAY));
    assert_eq!(got["reviewed"], json!(true), "{got}");
    assert_eq!(
        got["topics"],
        json!([{
            "topic_note_id": f.topic,
            "title": "Player Loop",
            "blocks": [{"id": "f6g7h8", "text": "Sleep was bad."}],
        }])
    );
    assert_eq!(
        got["not_filed"],
        json!([
            {"id": "b7k2m9", "text": "Fixed the jump arc."},
            {"id": "c3d4e5", "text": "- tried coyote time"},
        ])
    );
}

// ---------- AC 2: failures ----------

#[test]
fn filing_failures_exit_nonzero_with_their_c1_codes() {
    let f = fresh();
    let before = snapshot(&f);

    assert_c1_failure(&filing(&f, "2026-13-01"), "invalid_date");
    assert_c1_failure(&filing(&f, "not-a-date"), "invalid_date");
    assert_c1_failure(&filing(&f, "2026-09-06"), "not_found");

    assert_eq!(snapshot(&f), before, "a failed read wrote nothing");
}

#[test]
fn excerpt_add_failures_exit_nonzero_with_their_c1_codes() {
    let f = fresh();
    let before = snapshot(&f);

    let cases: [(&str, &str, &str, &str); 6] = [
        (NO_SUCH_NOTE, DAY, "b7k2m9", "not_found"),
        (&f.topic, "2026-09-06", "b7k2m9", "not_found"),
        (&f.topic, DAY, "zzzzzz", "block_not_found"),
        (&f.topic, "2026-13-01", "b7k2m9", "invalid_date"),
        (&f.day, DAY, "b7k2m9", "role_rule"),
        ("not-a-ulid", DAY, "b7k2m9", "invalid_id"),
    ];
    for (topic, date, block, code) in cases {
        assert_c1_failure(&excerpt_add(&f, topic, date, block, Some("why")), code);
    }

    assert_eq!(snapshot(&f), before, "no failure wrote anything");
    assert!(corrections(&f).is_empty(), "no failure recorded anything");
}

#[test]
fn excerpt_remove_block_failures_exit_nonzero_with_their_c1_codes() {
    let f = fresh();
    agent_files(&f, &f.topic, &["b7k2m9"]);
    let before = snapshot(&f);

    let cases: [(&str, &str, &str, &str); 6] = [
        (NO_SUCH_NOTE, DAY, "b7k2m9", "not_found"),
        // A real block of the day that this topic does not hold.
        (&f.topic, DAY, "f6g7h8", "not_found"),
        (&f.topic, DAY, "zzzzzz", "block_not_found"),
        (&f.topic, "2026-13-01", "b7k2m9", "invalid_date"),
        (&f.day, DAY, "b7k2m9", "role_rule"),
        ("not-a-ulid", DAY, "b7k2m9", "invalid_id"),
    ];
    for (topic, date, block, code) in cases {
        assert_c1_failure(
            &excerpt_remove_block(&f, topic, date, block, Some("why")),
            code,
        );
    }

    assert_eq!(snapshot(&f), before, "no failure wrote anything");
    assert!(corrections(&f).is_empty(), "no failure recorded anything");
}

#[test]
fn excerpt_move_failures_exit_nonzero_with_their_c1_codes() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["b7k2m9"]);
    let before = snapshot(&f);

    let cases: [(&str, &str, &str, &str, &str); 7] = [
        (NO_SUCH_NOTE, &economy, DAY, "b7k2m9", "not_found"),
        (&f.topic, NO_SUCH_NOTE, DAY, "b7k2m9", "not_found"),
        // A real block of the day that the source does not hold.
        (&f.topic, &economy, DAY, "f6g7h8", "not_found"),
        (&f.topic, &economy, DAY, "zzzzzz", "block_not_found"),
        (&f.topic, &economy, "2026-13-01", "b7k2m9", "invalid_date"),
        ("not-a-ulid", &economy, DAY, "b7k2m9", "invalid_id"),
        (&f.topic, "not-a-ulid", DAY, "b7k2m9", "invalid_id"),
    ];
    for (from, to, date, block, code) in cases {
        assert_c1_failure(&excerpt_move(&f, from, to, date, block, Some("why")), code);
    }

    assert_eq!(snapshot(&f), before, "no failure wrote anything");
    assert!(corrections(&f).is_empty(), "no failure recorded anything");
}

/// Lead decision 4: equal topics are C1 `invalid_argument`, before the vault
/// opens, so a path with no vault at it still answers with that code.
#[test]
fn excerpt_move_with_equal_topics_is_invalid_argument_before_the_vault_opens() {
    let f = fresh();
    agent_files(&f, &f.topic, &["b7k2m9"]);
    let before = snapshot(&f);

    let same = excerpt_move(&f, &f.topic, &f.topic, DAY, "b7k2m9", None);
    assert_c1_failure(&same, "invalid_argument");
    assert_eq!(snapshot(&f), before, "nothing was written");

    let missing = f.path.join("no-vault-here");
    let out = run(&[
        "excerpt",
        "move",
        "--vault",
        missing.to_str().unwrap(),
        "--date",
        DAY,
        "--block-id",
        "b7k2m9",
        "--from-topic-note-id",
        &f.topic,
        "--to-topic-note-id",
        &f.topic,
    ]);
    assert_c1_failure(&out, "invalid_argument");
}

/// Lead decision 4: both topic ids are parsed before the vault opens.
#[test]
fn excerpt_move_with_a_malformed_topic_id_is_invalid_id_before_the_vault_opens() {
    let f = fresh();
    let missing = f.path.join("no-vault-here");
    for (from, to) in [("not-a-ulid", NO_SUCH_NOTE), (NO_SUCH_NOTE, "not-a-ulid")] {
        let out = run(&[
            "excerpt",
            "move",
            "--vault",
            missing.to_str().unwrap(),
            "--date",
            DAY,
            "--block-id",
            "b7k2m9",
            "--from-topic-note-id",
            from,
            "--to-topic-note-id",
            to,
        ]);
        assert_c1_failure(&out, "invalid_id");
    }
}

// ---------- AC 3: one Correction, with the note as its text ----------

#[test]
fn excerpt_add_records_one_correction_with_the_note_as_its_text() {
    let f = fresh();

    ok_json(excerpt_add(
        &f,
        &f.topic,
        DAY,
        "c3d4e5",
        Some("Belongs with the loop."),
    ));

    let row = one_correction(&f);
    assert_eq!(row.text.as_deref(), Some("Belongs with the loop."));
    assert_eq!(row.status, "open");
    assert_eq!(row.source, "person");
    assert_eq!(row.note_id.as_deref(), Some(f.day.as_str()));
    assert_eq!(row.day.as_deref(), Some(DAY));
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_added",
            "date": DAY,
            "block_id": "c3d4e5",
            "preview": "- tried coyote time",
            "topic_note_id": f.topic,
            "title": "Player Loop",
        }))
    );
}

#[test]
fn excerpt_remove_block_records_one_correction_with_the_note_as_its_text() {
    let f = fresh();
    agent_files(&f, &f.topic, &["b7k2m9", "f6g7h8"]);

    ok_json(excerpt_remove_block(
        &f,
        &f.topic,
        DAY,
        "c3d4e5",
        Some("Not about the loop."),
    ));

    let row = one_correction(&f);
    assert_eq!(row.text.as_deref(), Some("Not about the loop."));
    assert_eq!(row.status, "open");
    assert_eq!(row.source, "person");
    assert_eq!(row.note_id.as_deref(), Some(f.day.as_str()));
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_removed",
            "date": DAY,
            "block_ids": ["c3d4e5"],
            "preview": "- tried coyote time",
            "topic_note_id": f.topic,
            "title": "Player Loop",
        }))
    );
}

#[test]
fn excerpt_move_records_one_correction_with_the_note_as_its_text() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["b7k2m9"]);

    ok_json(excerpt_move(
        &f,
        &f.topic,
        &economy,
        DAY,
        "b7k2m9",
        Some("This is about prices."),
    ));

    let row = one_correction(&f);
    assert_eq!(row.text.as_deref(), Some("This is about prices."));
    assert_eq!(row.status, "open");
    assert_eq!(row.source, "person");
    assert_eq!(row.note_id.as_deref(), Some(f.day.as_str()));
    assert_eq!(
        row.correction,
        Some(json!({
            "kind": "excerpt_moved",
            "date": DAY,
            "block_id": "b7k2m9",
            "preview": "Fixed the jump arc.",
            "from_topic_note_id": f.topic,
            "from_title": "Player Loop",
            "to_topic_note_id": economy,
            "to_title": "Economy Design",
        }))
    );
}

#[test]
fn excerpt_writes_without_a_note_record_a_correction_with_null_text() {
    let f = fresh();
    agent_files(&f, &f.topic, &["c3d4e5"]);
    let economy = second_topic(&f);
    agent_files(&f, &economy, &["f6g7h8"]);

    ok_json(excerpt_add(&f, &f.topic, DAY, "b7k2m9", None));
    ok_json(excerpt_remove_block(&f, &f.topic, DAY, "c3d4e5", None));
    ok_json(excerpt_move(&f, &economy, &f.topic, DAY, "f6g7h8", None));

    let rows = corrections(&f);
    let kinds: Vec<&str> = rows
        .iter()
        .map(|r| r.correction.as_ref().unwrap()["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["excerpt_added", "excerpt_removed", "excerpt_moved"]);
    for row in &rows {
        assert_eq!(row.text, None, "{row:?}");
    }
}

/// Lead decision 8: `--note` is passed as given, with no trimming on the way.
#[test]
fn excerpt_note_text_reaches_the_correction_as_given() {
    let f = fresh();
    let note = "  Wrong \u{2603} topic.\nSecond line.  ";

    ok_json(excerpt_add(&f, &f.topic, DAY, "b7k2m9", Some(note)));

    assert_eq!(one_correction(&f).text.as_deref(), Some(note));
}

/// Lead decision 8: an empty or whitespace-only `--note` is no note, so R18's
/// `Why?` never shows blank.
#[test]
fn excerpt_blank_note_records_a_correction_with_null_text() {
    for blank in ["", "   ", " \n\t "] {
        let f = fresh();
        let economy = second_topic(&f);
        agent_files(&f, &f.topic, &["c3d4e5"]);
        agent_files(&f, &economy, &["f6g7h8"]);

        ok_json(excerpt_add(&f, &f.topic, DAY, "b7k2m9", Some(blank)));
        ok_json(excerpt_remove_block(
            &f,
            &f.topic,
            DAY,
            "c3d4e5",
            Some(blank),
        ));
        ok_json(excerpt_move(
            &f,
            &economy,
            &f.topic,
            DAY,
            "f6g7h8",
            Some(blank),
        ));

        let rows = corrections(&f);
        assert_eq!(rows.len(), 3, "{blank:?}: {rows:?}");
        for row in &rows {
            assert_eq!(row.text, None, "{blank:?}: {row:?}");
        }
    }
}

/// Lead decision 8: the limit counts the raw text's chars, not its bytes, and
/// the text stays verbatim.
#[test]
fn excerpt_note_of_exactly_two_thousand_chars_is_stored_on_each_command() {
    let longest = "\u{2603}".repeat(2000);
    let padded = format!("  {}  ", "x".repeat(1996));
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["c3d4e5"]);
    agent_files(&f, &economy, &["f6g7h8"]);

    ok_json(excerpt_add(&f, &f.topic, DAY, "b7k2m9", Some(&longest)));
    ok_json(excerpt_remove_block(
        &f,
        &f.topic,
        DAY,
        "c3d4e5",
        Some(&padded),
    ));
    ok_json(excerpt_move(
        &f,
        &economy,
        &f.topic,
        DAY,
        "f6g7h8",
        Some(&longest),
    ));

    let texts: Vec<Option<String>> = corrections(&f).into_iter().map(|r| r.text).collect();
    assert_eq!(
        texts,
        [
            Some(longest.clone()),
            Some(padded.clone()),
            Some(longest.clone()),
        ]
    );
}

/// Lead decision 8: one char over is `feedback_invalid` before any write, even
/// when trimming the text would bring it under the limit.
#[test]
fn excerpt_note_over_two_thousand_chars_is_feedback_invalid_before_any_write() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["c3d4e5"]);
    agent_files(&f, &economy, &["f6g7h8"]);
    let before = snapshot(&f);

    for over in ["\u{2603}".repeat(2001), format!("  {}  ", "x".repeat(1997))] {
        assert_c1_failure(
            &excerpt_add(&f, &f.topic, DAY, "b7k2m9", Some(&over)),
            "feedback_invalid",
        );
        assert_c1_failure(
            &excerpt_remove_block(&f, &f.topic, DAY, "c3d4e5", Some(&over)),
            "feedback_invalid",
        );
        assert_c1_failure(
            &excerpt_move(&f, &economy, &f.topic, DAY, "f6g7h8", Some(&over)),
            "feedback_invalid",
        );
    }

    assert_eq!(snapshot(&f), before, "no failure wrote anything");
    assert!(corrections(&f).is_empty(), "no failure recorded anything");
}

/// Lead decision 8a: a blank block id is `invalid_argument`, as `excerpt rm`.
#[test]
fn excerpt_block_commands_with_a_blank_block_id_are_invalid_argument() {
    let f = fresh();
    let economy = second_topic(&f);
    agent_files(&f, &f.topic, &["c3d4e5"]);
    let before = snapshot(&f);

    for blank in ["", "   "] {
        assert_c1_failure(
            &excerpt_add(&f, &f.topic, DAY, blank, None),
            "invalid_argument",
        );
        assert_c1_failure(
            &excerpt_remove_block(&f, &f.topic, DAY, blank, None),
            "invalid_argument",
        );
        assert_c1_failure(
            &excerpt_move(&f, &f.topic, &economy, DAY, blank, None),
            "invalid_argument",
        );
    }

    assert_eq!(snapshot(&f), before, "no failure wrote anything");
    assert!(corrections(&f).is_empty(), "no failure recorded anything");
}

/// `excerpt rm` keeps its contract: it records its Correction in core and takes
/// no `--note`; only the new block commands do. A regression guard.
#[test]
fn excerpt_rm_records_a_correction_with_null_text_and_takes_no_note() {
    let f = fresh();
    add_excerpt(&f, &["b7k2m9"]);

    let refused = run(&[
        "excerpt",
        "rm",
        "--vault",
        f.vault(),
        "--topic-note-id",
        &f.topic,
        "--date",
        DAY,
        "--block-ids",
        "b7k2m9",
        "--note",
        "why",
    ]);
    assert_eq!(refused.status.code(), Some(2), "{}", describe(&refused));

    ok_json(excerpt_rm(f.vault(), &f.topic, DAY, "b7k2m9"));
    let row = one_correction(&f);
    assert_eq!(row.text, None);
    assert_eq!(row.correction.unwrap()["kind"], json!("excerpt_removed"));
}
