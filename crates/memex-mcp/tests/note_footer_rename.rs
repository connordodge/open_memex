//! WI #240 (Spec #234): the "Note footer" rename and the shared tool list.
//!
//! - AC 1: `GLOSSARY.md` holds the Note footer and Tag entries verbatim, in
//!   place, and Smart Folder's `_Avoid_` line no longer lists `tag`.
//! - AC 2: "Topics footer" is gone from the prompts, the served tool
//!   descriptions, `docs/` and `README.md` (the `<!-- memex:topics -->` marker
//!   and `memex footer` stay).
//! - AC 3: the Review prompt says "Note footer", and the blessed
//!   `prompt_review.json` fixture is the current Review prompt, byte for byte.
//! - AC 4: `review_sequence.rs`, `serve_args.rs` and `docs_readme.rs` read
//!   their tool lists from `support/tool_names.rs` and carry no count in a
//!   test name.
//! - AC 5: the README's count line equals the length of that tool list.
//! - AC 6 (green on main): the marker constant is unchanged.

#[path = "support/tool_names.rs"]
mod tool_names;

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use memex_core::Vault;
use memex_mcp::prompts::{CAPTURE, REVIEW_DAILY_NOTES};
use regex::Regex;
use serde_json::{json, Value};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn read_repo_file(rel: &str) -> String {
    let path = repo_root().join(rel);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{rel} must exist and be readable ({}): {e}", path.display()))
}

fn mcp_test_file(name: &str) -> String {
    read_repo_file(&format!("crates/memex-mcp/tests/{name}"))
}

/// Every file under `dir` (relative to the repo root) with the extension.
fn files_under(dir: &Path, ext: &str, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .flatten()
    {
        let path = entry.path();
        if path.is_dir() {
            files_under(&path, ext, out);
        } else if path.extension().is_some_and(|e| e == ext) {
            out.push(path);
        }
    }
}

/// `Topics footer`, in any case.
fn topics_footer() -> Regex {
    Regex::new(r"(?i)\btopics\s+footer\b").unwrap()
}

// ======================================================================
// AC 1: GLOSSARY.md
// ======================================================================

const NOTE_FOOTER_ENTRY: &str = "**Note footer**:\n\
The managed block at the bottom of a note, below a marker line, holding its topic links and its tags not written in the body. On a daily note, everything above the marker belongs to the person.\n\
_Avoid_: Topics footer, links section, related\n";

const TAG_ENTRY: &str = "**Tag**:\n\
A short label on a whole note, written as `#name` in the note's body or added without touching the body, by the agent or the CLI. It is separate from Topic notes and Smart Folders.\n\
_Avoid_: label, keyword, category\n";

#[test]
fn glossary_holds_the_note_footer_and_tag_entries_verbatim_in_place() {
    let glossary = read_repo_file("GLOSSARY.md");
    assert!(
        !glossary.contains("**Topics footer**"),
        "the Topics footer entry is replaced by Note footer"
    );
    // Note footer replaces the old entry (right after Topic note, right before
    // Review), and Tag goes right after it.
    let at = glossary
        .find(&format!("{NOTE_FOOTER_ENTRY}\n{TAG_ENTRY}\n**Review**:"))
        .unwrap_or_else(|| {
            panic!("GLOSSARY.md must hold the Note footer entry, then the Tag entry, then Review")
        });
    let before = &glossary[..at];
    assert!(
        before
            .trim_end()
            .ends_with("_Avoid_: subject note, concept note, chunk"),
        "the Note footer entry sits where the Topics footer entry was, right after Topic note"
    );
    assert_eq!(glossary.matches("**Tag**:").count(), 1, "one Tag entry");
    assert_eq!(
        glossary.matches("**Note footer**:").count(),
        1,
        "one Note footer entry"
    );
}

#[test]
fn smart_folder_avoid_line_no_longer_lists_tag() {
    let glossary = read_repo_file("GLOSSARY.md");
    let start = glossary
        .find("**Smart Folder**:")
        .expect("a Smart Folder entry");
    let entry = glossary[start..]
        .split("\n\n")
        .next()
        .expect("the entry's paragraph");
    let avoid = entry
        .lines()
        .find(|l| l.starts_with("_Avoid_"))
        .expect("Smart Folder has an _Avoid_ line");
    assert_eq!(
        avoid, "_Avoid_: folder, grouping, category",
        "Smart Folder's _Avoid_ drops `tag` and nothing else"
    );
}

// ======================================================================
// AC 2 and 3: the rename in prompts, tool descriptions, docs and README
// ======================================================================

#[test]
fn no_topics_footer_in_prompts_tool_sources_docs_or_readme() {
    let root = repo_root();
    let mut files = vec![
        root.join("README.md"),
        root.join("crates/memex-mcp/src/prompts.rs"),
    ];
    files_under(&root.join("docs"), "md", &mut files);
    files_under(&root.join("crates/memex-mcp/src/tools"), "rs", &mut files);
    assert!(
        files.len() >= 8,
        "README, prompts.rs, the docs and the tool sources are all scanned: {files:?}"
    );

    let re = topics_footer();
    let hits: Vec<String> = files
        .iter()
        .flat_map(|path| {
            let text = std::fs::read_to_string(path)
                .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
            let name = path.strip_prefix(&root).unwrap().display().to_string();
            text.lines()
                .enumerate()
                .filter(|(_, l)| re.is_match(l))
                .map(|(i, _)| format!("{name}:{}", i + 1))
                .collect::<Vec<_>>()
        })
        .collect();
    assert!(
        hits.is_empty(),
        "\"Topics footer\" is now \"Note footer\"; still found at: {hits:?}"
    );
}

#[test]
fn review_prompt_says_note_footer_and_neither_prompt_says_topics_footer() {
    assert!(
        REVIEW_DAILY_NOTES.contains("Note footer"),
        "the Review prompt names the Note footer"
    );
    let re = topics_footer();
    for (name, text) in [("review", REVIEW_DAILY_NOTES), ("capture", CAPTURE)] {
        assert!(!re.is_match(text), "the {name} prompt says Topics footer");
    }
}

#[test]
fn prompt_review_fixture_is_the_current_review_prompt_byte_for_byte() {
    let raw = read_repo_file("app/test/fixtures/api_v1/topics/prompt_review.json");
    let fixture: Value = serde_json::from_str(&raw).expect("the fixture is JSON");
    let text = fixture["text"].as_str().expect("a text field");
    assert_eq!(
        text, REVIEW_DAILY_NOTES,
        "re-bless prompt_review.json (MEMEX_BLESS=1), never hand-merge it"
    );
    assert!(
        text.contains("Note footer"),
        "the blessed text says Note footer"
    );
    assert!(!topics_footer().is_match(text));
}

/// Descriptions of every tool a stdio `memex serve` lists.
fn served_tool_descriptions() -> Vec<(String, String)> {
    let dir = tempfile::tempdir().unwrap();
    let vault = dir.path().join("vault");
    Vault::create(&vault).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--vault", vault.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn memex serve");
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut send = |msg: Value| {
        writeln!(stdin, "{msg}").expect("write to server");
        stdin.flush().unwrap();
    };
    let recv = |id: i64| -> Value {
        loop {
            let line = rx
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|e| panic!("no response to request {id}: {e}"));
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if v["id"] == json!(id) {
                    return v;
                }
            }
        }
    };
    send(json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": { "name": "wi240-test", "version": "0" },
        },
    }));
    assert!(recv(1)["result"].is_object());
    send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
    send(json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} }));
    let resp = recv(2);
    let out = resp["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list failed: {resp}"))
        .iter()
        .map(|t| {
            (
                t["name"].as_str().unwrap().to_string(),
                t["description"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    let _ = child.kill();
    let _ = child.wait();
    out
}

#[test]
fn served_tool_descriptions_say_note_footer_never_topics_footer() {
    let tools = served_tool_descriptions();
    let re = topics_footer();
    let old: Vec<&str> = tools
        .iter()
        .filter(|(_, d)| re.is_match(d))
        .map(|(n, _)| n.as_str())
        .collect();
    assert!(old.is_empty(), "tools still saying Topics footer: {old:?}");

    for name in [
        "append_to_daily_note",
        "remove_excerpt",
        "list_unreviewed_days",
    ] {
        let (_, description) = tools
            .iter()
            .find(|(n, _)| n == name)
            .unwrap_or_else(|| panic!("{name} is listed"));
        assert!(
            description.contains("Note footer"),
            "{name} names the Note footer: {description}"
        );
    }
}

// ======================================================================
// AC 4: the shared tool list
// ======================================================================

#[test]
fn tool_list_tests_read_support_tool_names_and_carry_no_count_in_their_names() {
    let name_has_count = Regex::new(r"(?i)(twenty|thirteen|(^|_)(13|26)(_|$))").unwrap();
    let test_fn = Regex::new(r"(?m)^\s*(?:async\s+)?fn\s+(\w+)\s*\(").unwrap();
    let local_list = Regex::new(r"(?m)^\s*(?:pub\s+)?const\s+\w*TOOLS\s*:").unwrap();

    for file in [
        "review_sequence.rs",
        "serve_args.rs",
        "docs_readme.rs",
        "server_request_clock.rs",
    ] {
        let src = mcp_test_file(file);
        assert!(
            src.contains("support/tool_names.rs"),
            "{file} reads the tool list from support/tool_names.rs"
        );
        assert!(
            !local_list.is_match(&src),
            "{file} keeps no tool list of its own"
        );
        let counted: Vec<&str> = test_fn
            .captures_iter(&src)
            .map(|c| c.get(1).unwrap().as_str())
            .filter(|name| name_has_count.is_match(name))
            .collect();
        assert!(
            counted.is_empty(),
            "{file}: test names hold a count: {counted:?}"
        );
    }
}

#[test]
fn shared_tool_list_has_one_block_per_feature_and_distinct_sorted_names() {
    let src = mcp_test_file("support/tool_names.rs");
    for block in ["EXISTING_TOOLS", "TAG_TOOLS", "FEEDBACK_TOOLS"] {
        assert!(
            Regex::new(&format!(r"(?m)^pub const {block}\b"))
                .unwrap()
                .is_match(&src),
            "support/tool_names.rs has a {block} block"
        );
    }
    let all = tool_names::all_tool_names();
    assert_eq!(all.len(), tool_names::TOOL_COUNT);
    let mut sorted = all.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(all, sorted, "every name once, sorted");
    assert!(
        tool_names::EXISTING_TOOLS.contains(&"append_to_daily_note"),
        "the existing block holds the tools the server already lists"
    );
}

// ======================================================================
// AC 5: README count line
// ======================================================================

#[test]
fn readme_count_line_equals_the_length_of_the_shared_tool_list() {
    let readme = read_repo_file("README.md");
    let count_line = Regex::new(r"(?m)^- (\d+) MCP tools:[ \t]*$").unwrap();
    let caps = count_line
        .captures(&readme)
        .expect("README.md has a line that is only `- <n> MCP tools:`");
    assert_eq!(
        caps[1].parse::<usize>().unwrap(),
        tool_names::TOOL_COUNT,
        "the README's count line matches support/tool_names.rs"
    );
    assert_eq!(count_line.find_iter(&readme).count(), 1, "one count line");
}

#[test]
fn readme_invariant_is_its_own_line_apart_from_the_count_line() {
    let readme = read_repo_file("README.md");
    let counted = Regex::new(r"\d+ MCP tools").unwrap();
    let invariant: Vec<&str> = readme
        .lines()
        .filter(|l| l.contains("renames, edits or deletes"))
        .collect();
    assert_eq!(invariant.len(), 1, "one invariant line: {invariant:?}");
    assert!(
        !counted.is_match(invariant[0]),
        "the invariant is not on the count line, so a tool WI bumps only the number"
    );
    assert!(
        invariant[0].contains("append_to_daily_note"),
        "the invariant keeps the daily-note write exception: {}",
        invariant[0]
    );
}

// ======================================================================
// AC 6 (green on main): the marker and `memex footer` are unchanged
// ======================================================================

#[test]
fn topics_marker_constant_is_unchanged() {
    assert_eq!(memex_core::daily::TOPICS_MARKER, "<!-- memex:topics -->");
}
