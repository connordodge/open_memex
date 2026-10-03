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
use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{Caller, Vault};
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
