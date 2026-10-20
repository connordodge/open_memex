//! WI #73 (R1): golden CLI output, so the move of the subcommand handlers into
//! `memex_mcp::ops` (D2) leaves every byte the person's scripts and the app
//! parse unchanged.
//!
//! Each test drives the real `memex` binary against a temp vault and pins
//! stdout, stderr and the exit code exactly. Values that differ per run are
//! normalized before the compare: the vault id and the note ids the test
//! created become named tags (`<VAULT>`, `<A>`, ...), any other ULID becomes
//! `<ULID>` and any millisecond timestamp becomes `<MS>`. Key order, spacing
//! and every literal value are compared byte for byte.
//!
//! The `--help` goldens live in `tests/golden/help/`, captured from the
//! binary before the extraction.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use memex_core::notes::{self, CreateNote, NoteId};
use memex_core::{excerpts, indexer, Caller, Vault};
use memex_mcp::prompts::{CAPTURE, REVIEW_DAILY_NOTES};
use regex::Regex;
use rusqlite::params;
use serde_json::json;
use tempfile::TempDir;

/// A well-formed ULID that no test vault contains.
const ABSENT_ULID: &str = "01J9Z8Y7X6W5V4T3S2R1Q0P9N8";

// ---------- harness ----------

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
            .expect("stdin")
            .write_all(body.as_bytes())
            .expect("write stdin");
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

/// Success: exit 0 and an empty stderr. Returns stdout.
fn ok(out: Output) -> String {
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty; {}",
        describe(&out)
    );
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

/// Failure: exit 1 and an empty stdout. Returns stderr.
fn fail(out: Output) -> String {
    assert_eq!(out.status.code(), Some(1), "{}", describe(&out));
    assert!(
        out.stdout.is_empty(),
        "stdout must be empty; {}",
        describe(&out)
    );
    String::from_utf8(out.stderr).expect("utf8 stderr")
}

/// A temp vault plus the tags its ids normalize to.
struct Fx {
    _dir: TempDir,
    path: PathBuf,
    tags: Vec<(String, String)>,
}

impl Fx {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let vault = Vault::create(&path).unwrap();
        let vault_id = vault.vault_id().to_string();
        Fx {
            _dir: dir,
            path,
            tags: vec![(vault_id, "<VAULT>".into())],
        }
    }

    fn v(&self) -> &str {
        self.path.to_str().unwrap()
    }

    fn open(&self) -> Vault {
        Vault::open(Path::new(&self.path)).unwrap()
    }

    /// Records `id` so outputs show it as `tag`.
    fn tag(&mut self, id: &str, tag: &str) -> String {
        self.tags.push((id.to_string(), tag.to_string()));
        id.to_string()
    }

    /// `memex add` through the binary; returns the new note id, tagged.
    fn add(&mut self, tag: &str, args: &[&str], body: &str) -> String {
        let mut full = vec!["add", "--vault", self.v()];
        full.extend_from_slice(args);
        let out = ok(run(&full, Some(body)));
        let re = Regex::new(r"note_id: ([0-9A-Z]{26})").unwrap();
        let id = re.captures(&out).expect("note_id in add stdout")[1].to_string();
        self.tag(&id, tag)
    }

    /// Normalizes per-run values (see the module docs).
    fn norm(&self, s: &str) -> String {
        let mut s = s.to_string();
        for (id, tag) in &self.tags {
            s = s.replace(id.as_str(), tag);
        }
        let ulid = Regex::new(r"\b[0-9A-HJKMNP-TV-Z]{26}\b").unwrap();
        let s = ulid.replace_all(&s, "<ULID>");
        let ms = Regex::new(r"\b1\d{12}\b").unwrap();
        ms.replace_all(&s, "<MS>").into_owned()
    }

    /// Runs `args`, expects success, returns the normalized stdout.
    fn ok(&self, args: &[&str], stdin_body: Option<&str>) -> String {
        self.norm(&ok(run(args, stdin_body)))
    }

    /// Runs `args`, expects the C1 failure, returns the normalized stderr.
    fn fail(&self, args: &[&str], stdin_body: Option<&str>) -> String {
        self.norm(&fail(run(args, stdin_body)))
    }

    /// The JSON line `memex` printed, parsed (for ids the test needs next).
    fn json(&self, args: &[&str]) -> serde_json::Value {
        serde_json::from_str(&ok(run(args, None))).expect("stdout JSON")
    }
}

fn create_core(vault: &mut Vault, title: &str, body: &str, role: Option<&str>) -> String {
    let note = notes::create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: role.map(|r| json!({ "role": r })),
        },
        Caller::Person,
    )
    .unwrap();
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note.id.to_string()
}

// ---------- notes ----------

#[test]
fn golden_add_prints_created_and_adopted_text() {
    let mut f = Fx::new();
    let out = ok(run(
        &[
            "add",
            "--vault",
            f.v(),
            "--title",
            "Alpha",
            "--tags",
            "games,loop",
        ],
        Some("Alpha body.\n"),
    ));
    let re = Regex::new(r"note_id: ([0-9A-Z]{26})").unwrap();
    let a = re.captures(&out).unwrap()[1].to_string();
    f.tag(&a, "<A>");
    assert_eq!(
        f.norm(&out),
        "Created note\n  note_id: <A>\n  title:   Alpha\n  tags:    games, loop\n"
    );

    let out = f.ok(&["add", "--vault", f.v()], Some("First line wins\nmore\n"));
    assert_eq!(
        out,
        "Created note\n  note_id: <ULID>\n  title:   First line wins\n"
    );

    let out = f.ok(
        &[
            "add",
            "--vault",
            f.v(),
            "--role",
            "daily",
            "--title",
            "2026-09-05",
        ],
        Some(""),
    );
    assert_eq!(
        out,
        "Created note\n  note_id: <ULID>\n  title:   2026-09-05\n"
    );

    let plain = f.add("<P>", &["--title", "2026-09-06"], "Before it was a day.\n");
    let out = f.ok(
        &[
            "add",
            "--vault",
            f.v(),
            "--role",
            "daily",
            "--title",
            "2026-09-06",
        ],
        Some("After.\n"),
    );
    assert_eq!(out, "Adopted note\n  note_id: <P>\n  title:   2026-09-06\n");
    assert!(!plain.is_empty());
}

#[test]
fn golden_update_prints_note_id_version_updated_at() {
    let mut f = Fx::new();
    let a = f.add("<A>", &["--title", "Alpha"], "v1\n");
    let out = f.ok(
        &[
            "update",
            "--vault",
            f.v(),
            "--note-id",
            &a,
            "--expected-version",
            "1",
            "--title",
            "Alpha Two",
        ],
        Some("v2\n"),
    );
    assert_eq!(
        out,
        "{\"note_id\":\"<A>\",\"version\":2,\"updated_at\":<MS>}\n"
    );
}

#[test]
fn golden_get_prints_the_note_object_with_and_without_links() {
    let mut f = Fx::new();
    let b = f.add("<B>", &["--title", "Beta"], "Beta body.\n");
    let a = f.add(
        "<A>",
        &["--title", "Alpha", "--tags", "games"],
        "Alpha links [[Beta]] and [[Beta~extends|more]].\n",
    );
    assert!(!b.is_empty());
    let out = f.ok(&["get", "--vault", f.v(), "--note-id", &a], None);
    assert_eq!(out, "{\"content_md\":\"Alpha links [[Beta]] and [[Beta~extends|more]].\\n\",\"created_at\":<MS>,\"frontmatter\":{},\"note_id\":\"<A>\",\"tags\":[\"games\"],\"title\":\"Alpha\",\"updated_at\":<MS>,\"version\":1}\n");
    let out = f.ok(
        &["get", "--vault", f.v(), "--note-id", &a, "--include-links"],
        None,
    );
    assert_eq!(out, "{\"backlinks\":{},\"content_md\":\"Alpha links [[Beta]] and [[Beta~extends|more]].\\n\",\"created_at\":<MS>,\"frontmatter\":{},\"links\":{\"extends\":[{\"from_note_id\":\"<A>\",\"label\":\"more\",\"link_id\":\"<ULID>\",\"link_text\":\"Beta\",\"position\":25,\"source\":\"inline_body\",\"to_note_id\":\"<B>\"}],\"references\":[{\"from_note_id\":\"<A>\",\"label\":null,\"link_id\":\"<ULID>\",\"link_text\":\"Beta\",\"position\":12,\"source\":\"inline_body\",\"to_note_id\":\"<B>\"}]},\"note_id\":\"<A>\",\"tags\":[\"games\"],\"title\":\"Alpha\",\"updated_at\":<MS>,\"version\":1}\n");
    let out = f.ok(
        &["get", "--vault", f.v(), "--note-id", &b, "--include-links"],
        None,
    );
    assert_eq!(out, "{\"backlinks\":{\"extends\":[{\"from_note_id\":\"<A>\",\"label\":\"more\",\"link_id\":\"<ULID>\",\"link_text\":\"Beta\",\"position\":25,\"source\":\"inline_body\",\"to_note_id\":\"<B>\"}],\"references\":[{\"from_note_id\":\"<A>\",\"label\":null,\"link_id\":\"<ULID>\",\"link_text\":\"Beta\",\"position\":12,\"source\":\"inline_body\",\"to_note_id\":\"<B>\"}]},\"content_md\":\"Beta body.\\n\",\"created_at\":<MS>,\"frontmatter\":{},\"links\":{},\"note_id\":\"<B>\",\"tags\":[],\"title\":\"Beta\",\"updated_at\":<MS>,\"version\":1}\n");
}

#[test]
fn golden_get_prints_review_fields_for_a_daily_note() {
    let mut f = Fx::new();
    let d = f.add(
        "<D>",
        &["--role", "daily", "--title", "2026-09-05"],
        "Fixed the jump arc.\n",
    );
    let out = f.ok(&["get", "--vault", f.v(), "--note-id", &d], None);
    assert_eq!(out, "{\"content_md\":\"Fixed the jump arc.\\n<!-- memex:topics -->\\n\",\"created_at\":<MS>,\"frontmatter\":{\"role\":\"daily\"},\"latest_change\":null,\"note_id\":\"<D>\",\"review\":{\"content_version\":1,\"reviewed_at\":null,\"reviewed_content_version\":null,\"state\":\"Unreviewed\"},\"tags\":[],\"title\":\"2026-09-05\",\"updated_at\":<MS>,\"version\":1}\n");
}

#[test]
fn golden_ls_prints_id_and_title_rows() {
    let mut f = Fx::new();
    let out = f.ok(&["ls", "--vault", f.v()], None);
    assert_eq!(out, "(empty vault)\n");
    f.add("<A>", &["--title", "Alpha"], "a\n");
    f.add("<B>", &["--title", "Beta"], "b\n");
    let out = f.ok(&["ls", "--vault", f.v()], None);
    assert_eq!(out, "<B>  Beta\n<A>  Alpha\n");
}

#[test]
fn golden_links_prints_the_link_tree() {
    let mut f = Fx::new();
    f.add("<B>", &["--title", "Beta"], "Beta body.\n");
    let a = f.add(
        "<A>",
        &["--title", "Alpha"],
        "See [[Beta]], [[Beta~extends|more]], [[Beta~inspired-by]] and [[Ghost]].\n",
    );
    let out = f.ok(&["links", "--vault", f.v(), "--note-id", &a], None);
    assert_eq!(out, "Alpha  (<A>)\n├─ outgoing (4)\n│   references (2)\n│       · Beta\n│       · (ghost: Ghost)\n│   extends (1)\n│       · Beta \"more\"\n│   inspired-by (1)\n│       · Beta\n├─ incoming (0)\n│   (none)\n");
    let out = f.ok(
        &[
            "links",
            "--vault",
            f.v(),
            "--note-id",
            &a,
            "--dir",
            "out",
            "--kind",
            "extends",
        ],
        None,
    );
    assert_eq!(
        out,
        "Alpha  (<A>)\n├─ outgoing (1)\n│   extends (1)\n│       · Beta \"more\"\n"
    );
}

#[test]
fn golden_rm_prints_vault_id_note_id_deleted() {
    let mut f = Fx::new();
    let a = f.add("<A>", &["--title", "Alpha"], "a\n");
    let out = f.ok(
        &[
            "rm",
            "--vault",
            f.v(),
            "--note-id",
            &a,
            "--expected-version",
            "1",
        ],
        None,
    );
    assert_eq!(
        out,
        "{\"vault_id\":\"<VAULT>\",\"note_id\":\"<A>\",\"deleted\":true}\n"
    );
}

// ---------- links ----------

#[test]
fn golden_add_link_prints_new_and_existing_links() {
    let mut f = Fx::new();
    let a = f.add("<A>", &["--title", "Alpha"], "Alpha body.\n");
    let b = f.add("<B>", &["--title", "Beta"], "Beta body.\n");
    let args = [
        "add-link",
        "--vault",
        f.v(),
        "--from",
        &a,
        "--to",
        &b,
        "--kind",
        "extends",
        "--label",
        "more",
    ];
    let out = f.ok(&args, None);
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"link_id\":\"<ULID>\",\"from\":\"<A>\",\"to\":\"<B>\",\"kind\":\"extends\",\"source\":\"frontmatter\",\"was_existing\":false,\"note_version\":2}\n");
    let out = f.ok(&args, None);
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"link_id\":\"<ULID>\",\"from\":\"<A>\",\"to\":\"<B>\",\"kind\":\"extends\",\"source\":\"frontmatter\",\"was_existing\":true,\"note_version\":2}\n");
    let out = f.ok(
        &["add-link", "--vault", f.v(), "--from", &b, "--to", &a],
        None,
    );
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"link_id\":\"<ULID>\",\"from\":\"<B>\",\"to\":\"<A>\",\"kind\":\"references\",\"source\":\"auto_added\",\"was_existing\":false,\"note_version\":2}\n");
}

#[test]
fn golden_update_link_prints_the_rewritten_link() {
    let mut f = Fx::new();
    let a = f.add("<A>", &["--title", "Alpha"], "Alpha body.\n");
    let b = f.add("<B>", &["--title", "Beta"], "Beta body.\n");
    let added = f.json(&[
        "add-link",
        "--vault",
        f.v(),
        "--from",
        &a,
        "--to",
        &b,
        "--kind",
        "extends",
    ]);
    let link = added["link_id"].as_str().unwrap().to_string();
    f.tag(&link, "<L>");
    let out = f.ok(
        &[
            "update-link",
            "--vault",
            f.v(),
            "--link-id",
            &link,
            "--label",
            "named",
        ],
        None,
    );
    assert_eq!(out, "{\"from_note_id\":\"<A>\",\"kind\":\"extends\",\"label\":\"named\",\"link_id\":\"<ULID>\",\"position\":17,\"source\":\"frontmatter\",\"to_note_id\":\"<B>\",\"vault_id\":\"<VAULT>\"}\n");

    // An inline body link can change kind and lose its label.
    let c = f.add("<C>", &["--title", "Gamma"], "Gamma links [[Beta|old]].\n");
    let after = f.json(&["get", "--vault", f.v(), "--note-id", &c, "--include-links"]);
    let link = after["links"]["references"][0]["link_id"]
        .as_str()
        .unwrap()
        .to_string();
    f.tag(&link, "<L2>");
    let out = f.ok(
        &[
            "update-link",
            "--vault",
            f.v(),
            "--link-id",
            &link,
            "--kind",
            "contradicts",
            "--clear-label",
        ],
        None,
    );
    assert_eq!(out, "{\"from_note_id\":\"<C>\",\"kind\":\"contradicts\",\"label\":null,\"link_id\":\"<ULID>\",\"position\":12,\"source\":\"inline_body\",\"to_note_id\":\"<B>\",\"vault_id\":\"<VAULT>\"}\n");
}

// ---------- canvas ----------

#[test]
fn golden_canvas_subcommands_print_their_json_lines() {
    let mut f = Fx::new();
    let a = f.add("<A>", &["--title", "Alpha"], "Alpha links [[Beta]].\n");
    let b = f.add("<B>", &["--title", "Beta"], "Beta body.\n");

    let out = ok(run(
        &["canvas", "new", "--vault", f.v(), "--title", "Board"],
        None,
    ));
    let c = Regex::new(r#""canvas_id":"([0-9A-Z]{26})""#)
        .unwrap()
        .captures(&out)
        .unwrap()[1]
        .to_string();
    f.tag(&c, "<C>");
    assert_eq!(f.norm(&out), "{\"canvas_id\":\"<C>\",\"created_at\":<MS>,\"title\":\"Board\",\"updated_at\":<MS>,\"vault_id\":\"<VAULT>\",\"version\":1}\n");

    let out = f.ok(
        &[
            "canvas",
            "add",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--note-id",
            &a,
            "--x",
            "10",
            "--y=-2.5",
        ],
        None,
    );
    assert_eq!(out, "{\"canvas_id\":\"<C>\",\"note_id\":\"<A>\",\"note_title\":\"Alpha\",\"placed_at\":<MS>,\"vault_id\":\"<VAULT>\",\"x\":10.0,\"y\":-2.5,\"z_order\":0}\n");
    f.ok(
        &[
            "canvas",
            "add",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--note-id",
            &b,
        ],
        None,
    );
    let out = f.ok(
        &[
            "canvas",
            "move",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--note-id",
            &a,
            "--x",
            "3",
            "--y",
            "4",
            "--z",
            "7",
        ],
        None,
    );
    assert_eq!(out, "{\"canvas_id\":\"<C>\",\"note_id\":\"<A>\",\"note_title\":\"Alpha\",\"vault_id\":\"<VAULT>\",\"x\":3.0,\"y\":4.0,\"z_order\":7}\n");
    let out = f.ok(&["canvas", "ls", "--vault", f.v()], None);
    assert_eq!(out, "{\"canvases\":[{\"canvas_id\":\"<C>\",\"created_at\":<MS>,\"node_count\":2,\"title\":\"Board\",\"updated_at\":<MS>,\"version\":4}],\"vault_id\":\"<VAULT>\"}\n");
    let out = f.ok(
        &["canvas", "get", "--vault", f.v(), "--canvas-id", &c],
        None,
    );
    assert_eq!(out, "{\"canvas_id\":\"<C>\",\"created_at\":<MS>,\"edges\":[],\"nodes\":[{\"note_id\":\"<B>\",\"note_title\":\"Beta\",\"placed_at\":<MS>,\"x\":0.0,\"y\":0.0,\"z_order\":0},{\"note_id\":\"<A>\",\"note_title\":\"Alpha\",\"placed_at\":<MS>,\"x\":3.0,\"y\":4.0,\"z_order\":7}],\"title\":\"Board\",\"updated_at\":<MS>,\"vault_id\":\"<VAULT>\",\"version\":4}\n");
    let out = f.ok(
        &[
            "canvas",
            "remove",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--note-id",
            &b,
        ],
        None,
    );
    assert_eq!(
        out,
        "{\"canvas_id\":\"<C>\",\"note_id\":\"<B>\",\"vault_id\":\"<VAULT>\"}\n"
    );
    let out = f.ok(
        &[
            "canvas",
            "rename",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--title",
            "Board Two",
            "--expected-version",
            "5",
        ],
        None,
    );
    assert_eq!(out, "{\"canvas_id\":\"<C>\",\"title\":\"Board Two\",\"updated_at\":<MS>,\"vault_id\":\"<VAULT>\",\"version\":6}\n");
    let out = f.ok(
        &[
            "canvas",
            "rm",
            "--vault",
            f.v(),
            "--canvas-id",
            &c,
            "--expected-version",
            "6",
        ],
        None,
    );
    assert_eq!(out, "{\"canvas_id\":\"<C>\",\"vault_id\":\"<VAULT>\"}\n");
}

// ---------- areas ----------

#[test]
fn golden_excerpt_rm_prints_vault_id_topic_note_id_version() {
    let mut f = Fx::new();
    let (day, topic) = {
        let mut vault = f.open();
        let day = create_core(
            &mut vault,
            "2026-09-05",
            "Fixed it.\n\nSlept.\n",
            Some("daily"),
        );
        for (ord, id) in ["b7k2m9", "c3d4e5"].iter().enumerate() {
            vault
                .connection_ref()
                .execute(
                    "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                    params![id, day, ord as i64],
                )
                .unwrap();
        }
        let topic = create_core(&mut vault, "Player Loop", "About.\n", Some("topic"));
        excerpts::add_excerpt(
            &mut vault,
            &NoteId::parse(&topic).unwrap(),
            "2026-09-05",
            &["b7k2m9".to_string()],
            Caller::Agent,
            None,
        )
        .unwrap();
        (day, topic)
    };
    f.tag(&day, "<D>");
    f.tag(&topic, "<T>");
    let out = f.ok(
        &[
            "excerpt",
            "rm",
            "--vault",
            f.v(),
            "--topic-note-id",
            &topic,
            "--date",
            "2026-09-05",
            "--block-ids",
            "b7k2m9",
        ],
        None,
    );
    assert_eq!(
        out,
        "{\"vault_id\":\"<VAULT>\",\"topic_note_id\":\"<T>\",\"version\":3}\n"
    );
}

#[test]
fn golden_footer_add_prints_the_c23_line() {
    let mut f = Fx::new();
    let d = f.add(
        "<D>",
        &["--role", "daily", "--title", "2026-09-05"],
        "Day.\n",
    );
    let t = f.add(
        "<T>",
        &["--role", "topic", "--title", "Player Loop"],
        "About.\n",
    );
    let out = f.ok(
        &[
            "footer",
            "add",
            "--vault",
            f.v(),
            "--daily-note-id",
            &d,
            "--topic-note-id",
            &t,
        ],
        None,
    );
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"daily_note_id\":\"<D>\",\"topic_note_id\":\"<T>\",\"origin\":\"person\",\"version\":2}\n");
}

#[test]
fn golden_folder_subcommands_print_their_json_lines() {
    let mut f = Fx::new();
    let t = f.add("<T>", &["--title", "Player Loop"], "About.\n");
    f.add("<U>", &["--title", "Loose"], "Unsorted.\n");

    let out = ok(run(
        &["folder", "new", "--vault", f.v(), "--name", "Games"],
        None,
    ));
    let g = Regex::new(r#""id":"([0-9A-Z]{26})""#)
        .unwrap()
        .captures(&out)
        .unwrap()[1]
        .to_string();
    f.tag(&g, "<G>");
    assert_eq!(f.norm(&out), "{\"vault_id\":\"<VAULT>\",\"id\":\"<G>\",\"name\":\"Games\",\"parent_id\":null,\"pinned\":true,\"depth\":1,\"created_at\":<MS>,\"updated_at\":<MS>}\n");
    let child = f.json(&[
        "folder",
        "new",
        "--vault",
        f.v(),
        "--name",
        "Platformers",
        "--parent-id",
        &g,
    ]);
    let k = child["id"].as_str().unwrap().to_string();
    f.tag(&k, "<K>");

    let out = f.ok(
        &[
            "folder",
            "add",
            "--vault",
            f.v(),
            "--id",
            &g,
            "--note-id",
            &t,
        ],
        None,
    );
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"smart_folder_id\":\"<G>\",\"note_id\":\"<T>\",\"pinned\":true,\"role_set\":true}\n");
    let out = f.ok(
        &[
            "folder",
            "update",
            "--vault",
            f.v(),
            "--id",
            &k,
            "--name",
            "Platform Games",
            "--to-root",
            "--pinned",
            "false",
        ],
        None,
    );
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"id\":\"<K>\",\"name\":\"Platform Games\",\"parent_id\":null,\"pinned\":false,\"depth\":1,\"created_at\":<MS>,\"updated_at\":<MS>}\n");
    let out = f.ok(&["folder", "ls", "--vault", f.v()], None);
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"max_depth\":2,\"folders\":[{\"id\":\"<G>\",\"name\":\"Games\",\"parent_id\":null,\"pinned\":true,\"depth\":1,\"created_at\":<MS>,\"updated_at\":<MS>,\"members\":[{\"note_id\":\"<T>\",\"title\":\"Player Loop\",\"pinned\":true}]},{\"id\":\"<K>\",\"name\":\"Platform Games\",\"parent_id\":null,\"pinned\":false,\"depth\":1,\"created_at\":<MS>,\"updated_at\":<MS>,\"members\":[]}],\"unsorted\":[{\"note_id\":\"<U>\",\"title\":\"Loose\"}]}\n");
    let out = f.ok(
        &[
            "folder",
            "remove",
            "--vault",
            f.v(),
            "--id",
            &g,
            "--note-id",
            &t,
        ],
        None,
    );
    assert_eq!(out, "{\"vault_id\":\"<VAULT>\",\"smart_folder_id\":\"<G>\",\"note_id\":\"<T>\",\"removed\":true}\n");
    let out = f.ok(&["folder", "rm", "--vault", f.v(), "--id", &k], None);
    assert_eq!(
        out,
        "{\"vault_id\":\"<VAULT>\",\"id\":\"<K>\",\"deleted\":true}\n"
    );
}

#[test]
fn golden_settings_get_and_set_print_the_c211_line() {
    let f = Fx::new();
    let key = "smart_folder_max_depth";
    let out = f.ok(&["settings", "get", "--vault", f.v(), "--key", key], None);
    assert_eq!(
        out,
        "{\"vault_id\":\"<VAULT>\",\"key\":\"smart_folder_max_depth\",\"value\":2}\n"
    );
    let out = f.ok(
        &[
            "settings",
            "set",
            "--vault",
            f.v(),
            "--key",
            key,
            "--value",
            "4",
        ],
        None,
    );
    assert_eq!(
        out,
        "{\"vault_id\":\"<VAULT>\",\"key\":\"smart_folder_max_depth\",\"value\":4}\n"
    );
    let out = f.ok(&["settings", "get", "--vault", f.v(), "--key", key], None);
    assert_eq!(
        out,
        "{\"vault_id\":\"<VAULT>\",\"key\":\"smart_folder_max_depth\",\"value\":4}\n"
    );
}

#[test]
fn golden_prompt_prints_the_prompt_constants_byte_for_byte() {
    let out = run(&["prompt", "review"], None);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty());
    assert_eq!(out.stdout, REVIEW_DAILY_NOTES.as_bytes());
    let out = run(&["prompt", "capture"], None);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty());
    assert_eq!(out.stdout, CAPTURE.as_bytes());
}

// ---------- AC 6: C1 failures ----------

#[test]
fn golden_failures_print_one_c1_line_and_exit_1() {
    let mut f = Fx::new();
    let a = f.add("<A>", &["--title", "Alpha"], "a\n");
    let b = f.add("<B>", &["--title", "Beta"], "b\n");
    f.tag(ABSENT_ULID, "<ABSENT>");

    // version_conflict on a stale update.
    let update = |v: &str| {
        vec![
            "update".to_string(),
            "--vault".into(),
            f.v().into(),
            "--note-id".into(),
            a.clone(),
            "--expected-version".into(),
            v.into(),
        ]
    };
    let args = update("1");
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    f.ok(&args, Some("a2\n"));
    let err = f.fail(&args, Some("a3\n"));
    assert_eq!(err, "{\"error\":{\"code\":\"version_conflict\",\"current\":2,\"expected\":1,\"message\":\"version conflict: expected 1, current 2\"}}\n");

    // not_found.
    let err = f.fail(&["get", "--vault", f.v(), "--note-id", ABSENT_ULID], None);
    assert_eq!(
        err,
        "{\"error\":{\"code\":\"not_found\",\"message\":\"not found: note <ABSENT>\"}}\n"
    );

    // title_conflict.
    let err = f.fail(
        &["add", "--vault", f.v(), "--title", "Beta"],
        Some("again\n"),
    );
    assert_eq!(err, "{\"error\":{\"code\":\"title_conflict\",\"existing_id\":\"<B>\",\"message\":\"title conflicts with existing note <B>: Beta\"}}\n");

    // daily_note_exists.
    f.add(
        "<D>",
        &["--role", "daily", "--title", "2026-09-05"],
        "Day.\n",
    );
    let err = f.fail(
        &[
            "add",
            "--vault",
            f.v(),
            "--role",
            "daily",
            "--title",
            "2026-09-05",
        ],
        Some("Again.\n"),
    );
    assert_eq!(err, "{\"error\":{\"code\":\"daily_note_exists\",\"date\":\"2026-09-05\",\"existing_id\":\"<D>\",\"message\":\"a daily note for 2026-09-05 already exists: <D>\"}}\n");

    // invalid_argument: empty stdin.
    let err = f.fail(&["add", "--vault", f.v()], Some(" \n"));
    assert_eq!(err, "{\"error\":{\"code\":\"invalid_argument\",\"message\":\"stdin was empty — nothing to add\"}}\n");

    // invalid_argument: a bad --kind.
    let err = f.fail(
        &[
            "add-link",
            "--vault",
            f.v(),
            "--from",
            &a,
            "--to",
            &b,
            "--kind",
            "9bad!",
        ],
        None,
    );
    assert_eq!(err, "{\"error\":{\"code\":\"invalid_argument\",\"message\":\"invalid --kind: invalid link kind: 9bad!\"}}\n");
    let err = f.fail(
        &[
            "links",
            "--vault",
            f.v(),
            "--note-id",
            &a,
            "--kind",
            "9bad!",
        ],
        None,
    );
    assert_eq!(err, "{\"error\":{\"code\":\"invalid_argument\",\"message\":\"invalid kind: invalid link kind: 9bad!\"}}\n");
}

// ---------- AC 10: --help ----------

/// The person subcommands whose rows `memex --help` must keep. Other rows
/// (`serve`, `help`, and subcommands other Work Items add) are not this
/// WI's surface.
const PERSON_COMMANDS: [&str; 16] = [
    "init",
    "add",
    "ls",
    "update",
    "get",
    "links",
    "add-link",
    "update-link",
    "canvas",
    "append",
    "prompt",
    "rm",
    "excerpt",
    "footer",
    "folder",
    "settings",
];

fn golden_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/help")
}

/// `memex --help` with only the person subcommand rows kept, each row's
/// name-to-about padding collapsed to one space.
fn person_view_of_top_help(help: &str) -> String {
    let mut out = String::new();
    let mut in_commands = false;
    for line in help.lines() {
        if line == "Commands:" {
            in_commands = true;
        } else if line.is_empty() {
            in_commands = false;
        } else if in_commands {
            let row = line.trim_start();
            let (name, about) = row.split_once(' ').unwrap_or((row, ""));
            if PERSON_COMMANDS.contains(&name) {
                out.push_str(&format!("  {name} {}\n", about.trim_start()));
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

#[test]
fn top_level_help_keeps_every_person_subcommand_row() {
    let golden = std::fs::read_to_string(golden_dir().join("memex.txt")).unwrap();
    let got = ok(run(&["--help"], None));
    assert_eq!(
        person_view_of_top_help(&got),
        person_view_of_top_help(&golden)
    );
    let rows = person_view_of_top_help(&golden);
    for name in PERSON_COMMANDS {
        assert!(
            rows.contains(&format!("  {name} ")),
            "golden lists {name}: {rows}"
        );
    }
}

/// Every person subcommand and sub-subcommand, as (args, golden file).
const HELP_CASES: [(&str, &str); 36] = [
    ("init", "init"),
    ("add", "add"),
    ("ls", "ls"),
    ("update", "update"),
    ("get", "get"),
    ("links", "links"),
    ("add-link", "add_link"),
    ("update-link", "update_link"),
    ("canvas", "canvas"),
    ("canvas new", "canvas_new"),
    ("canvas ls", "canvas_ls"),
    ("canvas get", "canvas_get"),
    ("canvas rename", "canvas_rename"),
    ("canvas rm", "canvas_rm"),
    ("canvas add", "canvas_add"),
    ("canvas remove", "canvas_remove"),
    ("canvas move", "canvas_move"),
    ("append", "append"),
    ("prompt", "prompt"),
    ("prompt review", "prompt_review"),
    ("prompt capture", "prompt_capture"),
    ("rm", "rm"),
    ("excerpt", "excerpt"),
    ("excerpt rm", "excerpt_rm"),
    ("footer", "footer"),
    ("footer add", "footer_add"),
    ("folder", "folder"),
    ("folder ls", "folder_ls"),
    ("folder new", "folder_new"),
    ("folder update", "folder_update"),
    ("folder rm", "folder_rm"),
    ("folder add", "folder_add"),
    ("folder remove", "folder_remove"),
    ("settings", "settings"),
    ("settings get", "settings_get"),
    ("settings set", "settings_set"),
];

#[test]
fn every_person_subcommand_help_matches_its_golden_text() {
    let mut mismatches = Vec::new();
    for (args, file) in HELP_CASES {
        let golden = std::fs::read_to_string(golden_dir().join(format!("{file}.txt")))
            .unwrap_or_else(|e| panic!("golden {file}.txt: {e}"));
        let mut argv: Vec<&str> = args.split(' ').collect();
        argv.push("--help");
        let got = ok(run(&argv, None));
        if got != golden {
            mismatches.push(format!(
                "memex {args} --help\n--- golden\n{golden}--- got\n{got}"
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn no_person_subcommand_takes_a_server_url() {
    for (args, _) in HELP_CASES {
        let mut argv: Vec<&str> = args.split(' ').collect();
        argv.push("--help");
        let help = ok(run(&argv, None)).to_lowercase();
        for word in ["url", "server", "http", "token", "--host", "--port"] {
            assert!(
                !help.contains(word),
                "memex {args} --help mentions {word:?}: {help}"
            );
        }
    }
}
