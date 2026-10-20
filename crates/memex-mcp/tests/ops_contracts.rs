//! WI #73 (R1), verify pass: the documented contracts of the shared ops that
//! the AC tests reach only indirectly.
//!
//! - `ops::notes::get` reads missing tags and links as empty (`[]` / `{}`),
//!   as `memex get` always has.
//! - `AddInput::validate`, `AddLinkInput::validate` and
//!   `excerpt::RmInput::validate` make their checks in the documented order,
//!   and the CLI makes them before it opens the vault.
//! - `ordered_kinds`: built-ins in canonical order, then user kinds
//!   alphabetically.
//! - `--with-embeddings` builds the embedder before the op runs; a failing
//!   `add` / `update` / `add-link` still prints the same stderr and stdout as
//!   it does without the flag.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{indexer, Caller, SystemClock, Vault};
use memex_mcp::cli::{self, Role};
use memex_mcp::ops::excerpt::RmInput as ExcerptRmInput;
use memex_mcp::ops::links::{self as link_ops, AddLinkInput};
use memex_mcp::ops::notes::{self as note_ops, AddInput, GetInput};
use serde_json::{json, Value};
use tempfile::TempDir;

/// Well-formed ULIDs that no test vault contains.
const ULID_A: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";
const ULID_B: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N9";

struct Fx {
    _dir: TempDir,
    path: PathBuf,
    vault: Vault,
}

impl Fx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let vault = Vault::create(&path).unwrap();
        Fx {
            _dir: dir,
            path,
            vault,
        }
    }

    fn v(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn note(&mut self, title: &str, body: &str) -> String {
        let note = notes::create_note_as(
            &mut self.vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: None,
            },
            Caller::Person,
        )
        .unwrap();
        indexer::reindex_note(
            self.vault.connection_mut(),
            note.id.as_str(),
            &note.content_md,
            None,
        )
        .unwrap();
        note.id.to_string()
    }

    /// Hides a table so every read of it fails with `no such table`.
    fn hide_table(&mut self, table: &str) {
        self.vault
            .connection_mut()
            .execute_batch(&format!("ALTER TABLE {table} RENAME TO {table}_hidden_73"))
            .unwrap();
    }
}

fn cli(args: &[&str], stdin_body: Option<&str>) -> Output {
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

fn code_and_message(err: &anyhow::Error) -> (String, String) {
    let v = cli::error_json(err);
    (
        v["error"]["code"].as_str().unwrap_or_default().to_string(),
        v["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
    )
}

fn link_input(from: &str, to: &str, kind: &str) -> AddLinkInput {
    AddLinkInput {
        from: from.to_string(),
        to: to.to_string(),
        kind: kind.to_string(),
        label: None,
    }
}

// ---------- ops::notes::get fallbacks ----------

#[test]
fn ops_get_reads_unreadable_tags_as_an_empty_list() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n");
    memex_core::tags::add_tag(&f.vault, &a, "kept").unwrap();
    let before = note_ops::get(
        &mut f.vault,
        GetInput {
            note_id: a.clone(),
            include_links: false,
        },
        &SystemClock,
        None,
    )
    .unwrap();
    assert_eq!(before.tags, vec!["kept".to_string()]);

    f.hide_table("tags");
    let out = note_ops::get(
        &mut f.vault,
        GetInput {
            note_id: a.clone(),
            include_links: false,
        },
        &SystemClock,
        None,
    )
    .expect("a failing tag read is not an error");
    assert_eq!(out.tags, Vec::<String>::new());
    assert_eq!(out.note_id, a);
    assert_eq!(out.title, "Alpha");
    assert_eq!(serde_json::to_value(&out).unwrap()["tags"], json!([]));
}

#[test]
fn ops_get_reads_unreadable_links_as_empty_maps() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n");
    let b = f.note("Beta", "Beta body.\n");
    link_ops::add_link(
        &mut f.vault,
        link_input(&a, &b, "extends"),
        &SystemClock,
        None,
    )
    .unwrap();
    link_ops::add_link(
        &mut f.vault,
        link_input(&b, &a, "references"),
        &SystemClock,
        None,
    )
    .unwrap();
    let input = || GetInput {
        note_id: a.clone(),
        include_links: true,
    };
    let before = note_ops::get(&mut f.vault, input(), &SystemClock, None).unwrap();
    assert!(before.links.as_ref().unwrap().contains_key("extends"));
    assert!(before
        .backlinks
        .as_ref()
        .unwrap()
        .contains_key("references"));

    f.hide_table("links");
    let out = note_ops::get(&mut f.vault, input(), &SystemClock, None)
        .expect("a failing link read is not an error");
    assert_eq!(out.links, Some(serde_json::Map::new()));
    assert_eq!(out.backlinks, Some(serde_json::Map::new()));
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(v["links"], json!({}));
    assert_eq!(v["backlinks"], json!({}));
}

// ---------- AddInput::validate ----------

#[test]
fn add_input_validate_requires_a_body_unless_the_note_is_daily() {
    let cases: [(&str, &str, Option<Role>, bool); 7] = [
        ("empty body, no role", "", None, false),
        ("blank body, no role", " \n\t\n", None, false),
        ("empty body, topic", "", Some(Role::Topic), false),
        ("empty body, daily", "", Some(Role::Daily), true),
        ("blank body, daily", "  \n", Some(Role::Daily), true),
        ("body, no role", "x", None, true),
        ("body, topic", "Some text\n", Some(Role::Topic), true),
    ];
    for (name, body, role, valid) in cases {
        let input = AddInput {
            title: None,
            content_md: body.to_string(),
            tags: vec![],
            role,
        };
        match input.validate() {
            Ok(()) => assert!(valid, "{name}: expected an error"),
            Err(e) => {
                assert!(!valid, "{name}: unexpected {e:#}");
                assert_eq!(
                    code_and_message(&e),
                    (
                        "invalid_argument".to_string(),
                        "stdin was empty — nothing to add".to_string()
                    ),
                    "{name}"
                );
            }
        }
    }
}

// ---------- AddLinkInput::validate order ----------

#[test]
fn add_link_validate_checks_from_then_to_then_kind() {
    let cases: [(&str, &str, &str, &str, &str); 4] = [
        // (case, from, to, kind, expected `code` and message fragment)
        (
            "all bad",
            "bad-from",
            "bad-to",
            "9bad!",
            "invalid_id:bad-from",
        ),
        (
            "to and kind bad",
            ULID_A,
            "bad-to",
            "9bad!",
            "invalid_id:bad-to",
        ),
        (
            "kind bad",
            ULID_A,
            ULID_B,
            "9bad!",
            "invalid_argument:invalid --kind: ",
        ),
        (
            "from bad only",
            "bad-from",
            ULID_B,
            "extends",
            "invalid_id:bad-from",
        ),
    ];
    for (name, from, to, kind, want) in cases {
        let err = link_input(from, to, kind).validate().unwrap_err();
        let (code, message) = code_and_message(&err);
        let (want_code, want_fragment) = want.split_once(':').unwrap();
        assert_eq!(code, want_code, "{name}: {message}");
        assert!(
            message.contains(want_fragment),
            "{name}: {message:?} lacks {want_fragment:?}"
        );
    }
}

#[test]
fn add_link_validate_returns_the_parsed_ids_and_kind() {
    let (from, to, kind) = link_input(ULID_A, ULID_B, "user-kind").validate().unwrap();
    assert_eq!(from, NoteId::parse(ULID_A).unwrap());
    assert_eq!(to, NoteId::parse(ULID_B).unwrap());
    assert_eq!(kind.as_str(), "user-kind");
}

#[test]
fn ops_add_link_checks_from_then_to_then_kind_like_validate() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n");
    let cases: [(&str, &str, &str, &str); 3] = [
        ("bad-from", "bad-to", "9bad!", "invalid_id:bad-from"),
        (a.as_str(), "bad-to", "9bad!", "invalid_id:bad-to"),
        (
            a.as_str(),
            ULID_B,
            "9bad!",
            "invalid_argument:invalid --kind: ",
        ),
    ];
    for (from, to, kind, want) in cases {
        let err = link_ops::add_link(&mut f.vault, link_input(from, to, kind), &SystemClock, None)
            .unwrap_err();
        let (code, message) = code_and_message(&err);
        let (want_code, want_fragment) = want.split_once(':').unwrap();
        assert_eq!(code, want_code, "{from} {to} {kind}: {message}");
        assert!(message.contains(want_fragment), "{message:?}");
    }
}

// ---------- excerpt::RmInput::validate order ----------

#[test]
fn excerpt_rm_validate_checks_block_ids_before_the_topic_id() {
    let rm = |topic: &str, ids: &[&str]| ExcerptRmInput {
        topic_note_id: topic.to_string(),
        date: "2026-10-20".to_string(),
        block_ids: ids.iter().map(|s| s.to_string()).collect(),
    };
    let blank = "--block-ids must list one or two non-empty block ids";
    let cases: [(&str, ExcerptRmInput, &str, &str); 5] = [
        (
            "blank id and bad topic",
            rm("bad-topic", &["  "]),
            "invalid_argument",
            blank,
        ),
        (
            "empty second id",
            rm(ULID_A, &["b7k2m9", ""]),
            "invalid_argument",
            blank,
        ),
        (
            "blank first id",
            rm(ULID_A, &["\t", "c3d4e5"]),
            "invalid_argument",
            blank,
        ),
        (
            "bad topic",
            rm("bad-topic", &["b7k2m9"]),
            "invalid_id",
            "bad-topic",
        ),
        (
            "bad topic, range",
            rm("bad-topic", &["b7k2m9", "c3d4e5"]),
            "invalid_id",
            "bad-topic",
        ),
    ];
    for (name, input, want_code, want_fragment) in cases {
        let err = input.validate().unwrap_err();
        let (code, message) = code_and_message(&err);
        assert_eq!(code, want_code, "{name}: {message}");
        assert!(message.contains(want_fragment), "{name}: {message:?}");
    }
    assert_eq!(
        rm(ULID_A, &["b7k2m9", "c3d4e5"]).validate().unwrap(),
        NoteId::parse(ULID_A).unwrap()
    );
}

// ---------- the CLI checks before it opens the vault ----------

#[test]
fn cli_input_checks_run_before_the_vault_opens() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("no-vault-here");
    let v = missing.to_str().unwrap();
    // (args, stdin, code, message fragment): with no vault at `v`, a check
    // made after `Vault::open` would report the missing manifest instead.
    let cases: Vec<(Vec<&str>, Option<&str>, &str, &str)> = vec![
        (
            vec!["add", "--vault", v],
            Some(""),
            "invalid_argument",
            "stdin was empty",
        ),
        (
            vec![
                "add-link", "--vault", v, "--from", "bad-from", "--to", "bad-to", "--kind", "9bad!",
            ],
            None,
            "invalid_id",
            "bad-from",
        ),
        (
            vec![
                "add-link", "--vault", v, "--from", ULID_A, "--to", "bad-to", "--kind", "9bad!",
            ],
            None,
            "invalid_id",
            "bad-to",
        ),
        (
            vec![
                "add-link", "--vault", v, "--from", ULID_A, "--to", ULID_B, "--kind", "9bad!",
            ],
            None,
            "invalid_argument",
            "invalid --kind: ",
        ),
        (
            vec![
                "excerpt",
                "rm",
                "--vault",
                v,
                "--topic-note-id",
                "bad-topic",
                "--date",
                "2026-10-20",
                "--block-ids",
                "b7k2m9, ",
            ],
            None,
            "invalid_argument",
            "--block-ids must list",
        ),
        (
            vec![
                "excerpt",
                "rm",
                "--vault",
                v,
                "--topic-note-id",
                "bad-topic",
                "--date",
                "2026-10-20",
                "--block-ids",
                "b7k2m9",
            ],
            None,
            "invalid_id",
            "bad-topic",
        ),
        (
            vec![
                "update",
                "--vault",
                v,
                "--note-id",
                "bad-note",
                "--expected-version",
                "1",
            ],
            Some("body\n"),
            "invalid_id",
            "bad-note",
        ),
        (
            vec!["get", "--vault", v, "--note-id", "bad-note"],
            None,
            "invalid_id",
            "bad-note",
        ),
        (
            vec![
                "rm",
                "--vault",
                v,
                "--note-id",
                "bad-note",
                "--expected-version",
                "1",
            ],
            None,
            "invalid_id",
            "bad-note",
        ),
        (
            vec![
                "footer",
                "add",
                "--vault",
                v,
                "--daily-note-id",
                "bad-daily",
                "--topic-note-id",
                "bad-topic",
            ],
            None,
            "invalid_id",
            "bad-daily",
        ),
    ];
    for (args, stdin_body, want_code, want_fragment) in cases {
        let out = cli(&args, stdin_body);
        assert_eq!(out.status.code(), Some(1), "{args:?}");
        assert!(out.stdout.is_empty(), "{args:?}");
        let err: Value = serde_json::from_slice(&out.stderr)
            .unwrap_or_else(|_| panic!("{args:?}: {}", String::from_utf8_lossy(&out.stderr)));
        assert_eq!(err["error"]["code"], want_code, "{args:?}: {err}");
        let message = err["error"]["message"].as_str().unwrap();
        assert!(message.contains(want_fragment), "{args:?}: {message:?}");
        assert!(!missing.exists(), "{args:?} created the vault dir");
    }
}

// ---------- ordered_kinds ----------

#[test]
fn ordered_kinds_puts_built_ins_in_canonical_order_then_user_kinds_alphabetically() {
    let s = |v: &[&str]| v.iter().map(|k| k.to_string()).collect::<Vec<_>>();
    let cases: [(&str, Vec<String>, Vec<String>); 6] = [
        ("empty", s(&[]), s(&[])),
        (
            "all built-ins reversed",
            s(&["example-of", "contradicts", "extends", "references"]),
            s(&["references", "extends", "contradicts", "example-of"]),
        ),
        (
            "built-in subset",
            s(&["example-of", "references"]),
            s(&["references", "example-of"]),
        ),
        (
            "user kinds only",
            s(&["zeta", "alpha", "mid-kind"]),
            s(&["alpha", "mid-kind", "zeta"]),
        ),
        (
            "mixed",
            s(&[
                "zeta",
                "extends",
                "alpha",
                "references",
                "example-of",
                "contradicts",
            ]),
            s(&[
                "references",
                "extends",
                "contradicts",
                "example-of",
                "alpha",
                "zeta",
            ]),
        ),
        (
            "user kind sorting before a built-in name",
            s(&["contradicts", "aaa", "references"]),
            s(&["references", "contradicts", "aaa"]),
        ),
    ];
    for (name, input, want) in cases {
        assert_eq!(note_ops::ordered_kinds(input), want, "{name}");
    }
}

// ---------- --with-embeddings on a failing write ----------

/// Runs `args` with and without `--with-embeddings` against the same vault
/// state and returns both outputs.
fn with_and_without_embeddings(args: &[&str], stdin_body: Option<&str>) -> (Output, Output) {
    let plain = cli(args, stdin_body);
    let mut flagged_args = args.to_vec();
    flagged_args.push("--with-embeddings");
    let flagged = cli(&flagged_args, stdin_body);
    (plain, flagged)
}

fn assert_same_failure(name: &str, plain: &Output, flagged: &Output) {
    assert_eq!(plain.status.code(), Some(1), "{name} (plain)");
    assert_eq!(flagged.status.code(), Some(1), "{name} (flagged)");
    assert!(plain.stdout.is_empty(), "{name}");
    assert!(flagged.stdout.is_empty(), "{name}");
    assert_eq!(
        String::from_utf8_lossy(&flagged.stderr),
        String::from_utf8_lossy(&plain.stderr),
        "{name}: --with-embeddings changed stderr"
    );
    let err: Value = serde_json::from_slice(&flagged.stderr).unwrap();
    assert!(err["error"]["code"].is_string(), "{name}: {err}");
}

#[test]
fn with_embeddings_failing_writes_print_the_same_c1_line() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n");
    let v = f.v().to_string();

    let (plain, flagged) =
        with_and_without_embeddings(&["add", "--vault", &v, "--title", "Alpha"], Some("again\n"));
    assert_same_failure("add title conflict", &plain, &flagged);

    let (plain, flagged) = with_and_without_embeddings(
        &[
            "update",
            "--vault",
            &v,
            "--note-id",
            &a,
            "--expected-version",
            "7",
        ],
        Some("new body\n"),
    );
    assert_same_failure("update version conflict", &plain, &flagged);

    let (plain, flagged) = with_and_without_embeddings(
        &["add-link", "--vault", &v, "--from", &a, "--to", ULID_B],
        None,
    );
    assert_same_failure("add-link unknown target", &plain, &flagged);

    // Nothing was written by any of the failing calls.
    let stored = notes::get_note(&f.vault, &NoteId::parse(&a).unwrap()).unwrap();
    assert_eq!(stored.version, 1);
    assert_eq!(stored.content_md, "Alpha body.\n");
    assert_eq!(notes::list_notes(&f.vault, 10).unwrap().len(), 1);
}

#[test]
fn with_embeddings_existing_add_link_prints_the_same_line() {
    let mut f = Fx::new();
    let a = f.note("Alpha", "Alpha body.\n");
    let b = f.note("Beta", "Beta body.\n");
    link_ops::add_link(
        &mut f.vault,
        link_input(&a, &b, "extends"),
        &SystemClock,
        None,
    )
    .unwrap();
    let v = f.v().to_string();
    // The link exists, so neither call reindexes and no model loads.
    let (plain, flagged) = with_and_without_embeddings(
        &[
            "add-link", "--vault", &v, "--from", &a, "--to", &b, "--kind", "extends",
        ],
        None,
    );
    assert_eq!(plain.status.code(), Some(0));
    assert_eq!(flagged.status.code(), Some(0));
    assert!(flagged.stderr.is_empty());
    assert_eq!(flagged.stdout, plain.stdout);
    let line: Value = serde_json::from_slice(&flagged.stdout).unwrap();
    assert_eq!(line["was_existing"], json!(true));
}
