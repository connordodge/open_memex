//! WI #17 (D1): the person-facing docs and the README.
//!
//! - `README.md` names every MCP tool and both prompts the server exposes
//!   (read off a served `tools/list` and `prompts/list`, so a tool added later
//!   without a README entry fails here), lists the new CLI subcommands, drops
//!   the stale "13 MCP tools" count and the "future MCP update/delete tools"
//!   line, and carries the schema V5 upgrade note (Spec Req 70, release note).
//! - `docs/daily-review.md` carries the Req 69 contents and the Req 75 caller
//!   identity warning.
//! - `docs/daily-acceptance.md` is the manual acceptance script in the style of
//!   `docs/canvas-acceptance.md` (numbered sections, **Expected** lines).
//! - Every `memex` command shown is a real subcommand, every tool named exists,
//!   and the new docs use GLOSSARY.md terms and none of its `_Avoid_` terms
//!   that cannot be mistaken for ordinary English.
//!
//! The prose itself is reviewed by hand (AC 7 to 10); these tests pin the
//! facts that can be checked mechanically.

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use memex_core::Vault;
use regex::Regex;
use serde_json::{json, Value};

// ---------- files ----------

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

fn readme() -> String {
    read_repo_file("README.md")
}

fn daily_review() -> String {
    read_repo_file("docs/daily-review.md")
}

fn daily_acceptance() -> String {
    read_repo_file("docs/daily-acceptance.md")
}

// ---------- what the server exposes, read off a served `memex serve` ----------

struct Server {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: i64,
}

impl Server {
    fn start(vault: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut server = Self {
            child,
            stdin,
            lines,
            next_id: 1,
        };
        let init = server.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi17-docs-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        writeln!(
            server.stdin,
            "{}",
            json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
        )
        .unwrap();
        server.stdin.flush().unwrap();
        server
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        writeln!(
            self.stdin,
            "{}",
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
        )
        .unwrap();
        self.stdin.flush().unwrap();
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }

    fn names(&mut self, method: &str, field: &str) -> BTreeSet<String> {
        let resp = self.request(method, json!({}));
        resp["result"][field]
            .as_array()
            .unwrap_or_else(|| panic!("{method} failed: {resp}"))
            .iter()
            .map(|t| t["name"].as_str().expect("name").to_string())
            .collect()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// `(tool names, prompt names)` of a served vault.
fn served_names() -> (BTreeSet<String>, BTreeSet<String>) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    Vault::create(&path).unwrap();
    let mut server = Server::start(path.to_str().unwrap());
    let tools = server.names("tools/list", "tools");
    let prompts = server.names("prompts/list", "prompts");
    (tools, prompts)
}

/// The top-level subcommands of `memex --help`.
fn subcommands_of(args: &[&str]) -> BTreeSet<String> {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .arg("--help")
        .output()
        .expect("run memex --help");
    assert!(out.status.success(), "memex {args:?} --help failed");
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let mut names = BTreeSet::new();
    let mut in_commands = false;
    for line in text.lines() {
        if line.trim_end() == "Commands:" {
            in_commands = true;
            continue;
        }
        if in_commands {
            if line.trim().is_empty() {
                break;
            }
            if let Some(name) = line.split_whitespace().next() {
                names.insert(name.to_string());
            }
        }
    }
    names
}

// ---------- markdown helpers ----------

/// Fenced code blocks and inline code spans of a markdown file.
fn code_snippets(md: &str) -> Vec<String> {
    let fenced = Regex::new(r"(?s)```.*?```").unwrap();
    let mut out: Vec<String> = fenced
        .find_iter(md)
        .map(|m| m.as_str().to_string())
        .collect();
    let prose = fenced.replace_all(md, "");
    let inline = Regex::new(r"`([^`\n]+)`").unwrap();
    out.extend(inline.captures_iter(&prose).map(|c| c[1].to_string()));
    out
}

/// The prose of a markdown file: no fenced blocks and no inline code.
fn prose_only(md: &str) -> String {
    let fenced = Regex::new(r"(?s)```.*?```").unwrap();
    let no_fences = fenced.replace_all(md, " ");
    Regex::new(r"`[^`\n]+`")
        .unwrap()
        .replace_all(&no_fences, " ")
        .to_string()
}

/// The `memex <subcommand> [<next>]` invocations shown in code: a segment of a
/// code line (split at `|`, `&&` and `;`) that starts with `memex `.
fn memex_invocations(md: &str) -> Vec<(String, Option<String>)> {
    let mut out = Vec::new();
    for snippet in code_snippets(md) {
        for line in snippet.lines() {
            let line = line.trim().trim_start_matches('`');
            for segment in line.split(['|', ';']).flat_map(|s| s.split("&&")) {
                let segment = segment.trim().trim_start_matches("$ ").trim();
                let mut words = segment.split_whitespace();
                if words.next() != Some("memex") {
                    continue;
                }
                let Some(sub) = words.next() else { continue };
                if !sub.chars().next().is_some_and(|c| c.is_ascii_lowercase()) {
                    continue;
                }
                let next = words.next().map(|s| s.to_string());
                out.push((sub.trim_matches('`').to_string(), next));
            }
        }
    }
    out
}

fn assert_commands_are_real(doc_name: &str, md: &str) {
    let top = subcommands_of(&[]);
    assert!(
        top.contains("append") && top.contains("prompt"),
        "memex --help lists the new subcommands: {top:?}"
    );
    let invocations = memex_invocations(md);
    assert!(
        !invocations.is_empty(),
        "{doc_name} shows at least one `memex <subcommand>` command"
    );
    for (sub, next) in invocations {
        assert!(
            top.contains(&sub),
            "{doc_name} shows `memex {sub}`, which is not a subcommand: {top:?}"
        );
        let Some(next) = next else { continue };
        if !next.chars().next().is_some_and(|c| c.is_ascii_lowercase()) {
            continue;
        }
        let nested = subcommands_of(&[sub.as_str()]);
        if nested.is_empty() {
            continue; // a plain argument such as `memex append quick note`
        }
        assert!(
            nested.contains(&next),
            "{doc_name} shows `memex {sub} {next}`, which is not a subcommand: {nested:?}"
        );
    }
}

/// Tool-shaped names in backticks (`verb_noun…`) must be real tools. The two
/// names a doc may mention only to say they do not exist are exempt.
fn assert_tool_names_exist(doc_name: &str, md: &str, tools: &BTreeSet<String>, require_any: bool) {
    let verbs = [
        "list_", "get_", "create_", "update_", "delete_", "add_", "remove_", "mark_", "append_",
    ];
    let exempt = ["update_note", "delete_note"];
    let name = Regex::new(r"`([a-z][a-z_]*)`").unwrap();
    let mut seen = 0;
    for c in name.captures_iter(md) {
        let token = &c[1];
        if !verbs.iter().any(|v| token.starts_with(v)) || exempt.contains(&token) {
            continue;
        }
        seen += 1;
        assert!(
            tools.contains(token),
            "{doc_name} names `{token}`, which the server does not expose: {tools:?}"
        );
    }
    assert!(
        seen > 0 || !require_any,
        "{doc_name} names at least one MCP tool"
    );
}

fn has_all_terms(doc_name: &str, md: &str, terms: &[&str]) {
    let lower = md.to_lowercase();
    for term in terms {
        assert!(
            lower.contains(&term.to_lowercase()),
            "{doc_name} uses the GLOSSARY.md term `{term}`"
        );
    }
}

/// Distinctive `_Avoid_` terms of GLOSSARY.md. Ordinary English words from
/// the glossary (line, edge, copy, process, tag, log, map, folder, ...) are
/// left to the manual read (AC 10): they would flag innocent prose.
const AVOID_TERMS: [&str; 16] = [
    "journal",
    "day page",
    "dictation",
    "quick add",
    "snippet",
    "subject note",
    "concept note",
    "spiderweb",
    "background AI",
    "user-owned",
    "links section",
    "excerpt copy",
    "by subject",
    "symlink",
    "category",
    "inbox",
];

fn assert_no_avoided_terms(doc_name: &str, md: &str) {
    // The terms really are in GLOSSARY.md's `_Avoid_` lines.
    let glossary = read_repo_file("GLOSSARY.md");
    let avoid_lines: String = glossary
        .lines()
        .filter(|l| l.starts_with("_Avoid_"))
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase();
    for term in AVOID_TERMS {
        assert!(
            avoid_lines.contains(&term.to_lowercase()),
            "{term} is an `_Avoid_` term in GLOSSARY.md"
        );
    }
    let prose = prose_only(md).to_lowercase();
    for term in AVOID_TERMS {
        let re = Regex::new(&format!(r"\b{}\b", regex::escape(&term.to_lowercase()))).unwrap();
        assert!(
            !re.is_match(&prose),
            "{doc_name} uses the GLOSSARY.md `_Avoid_` term `{term}`"
        );
    }
}

// ======================================================================
// AC 5: README.md names every MCP tool and both prompts.
// ======================================================================

#[test]
fn readme_names_all_twenty_six_tools_and_both_prompts_the_server_exposes() {
    let (tools, prompts) = served_names();
    assert_eq!(tools.len(), 26, "the server exposes 26 tools: {tools:?}");
    assert_eq!(
        prompts,
        ["capture", "review_daily_notes"]
            .iter()
            .map(|s| s.to_string())
            .collect::<BTreeSet<_>>(),
        "the server exposes exactly the two prompts"
    );

    let readme = readme();
    let missing: Vec<&String> = tools
        .iter()
        .chain(prompts.iter())
        .filter(|name| !readme.contains(&format!("`{name}`")))
        .collect();
    assert!(
        missing.is_empty(),
        "README.md must name each tool and prompt in backticks; missing: {missing:?}"
    );
}

#[test]
fn readme_no_longer_claims_thirteen_tools_or_future_mcp_update_and_delete_tools() {
    let readme = readme();
    assert!(
        !readme.contains("13 MCP tools"),
        "the tool count is stale: the server exposes 26"
    );
    assert!(
        !readme.contains("exposed as MCP tools"),
        "Req 45/76: there are no MCP update or delete tools, not even as future work"
    );
    assert!(
        readme.contains("memex rm"),
        "note deletion is person-only, through `memex rm`"
    );
}

#[test]
fn readme_lists_the_new_cli_subcommands_and_links_the_new_docs() {
    let readme = readme();
    for needle in [
        "memex append",
        "memex prompt",
        "memex rm",
        "memex excerpt rm",
        "memex footer add",
        "memex folder",
        "memex settings",
        "docs/daily-review.md",
        "docs/daily-acceptance.md",
    ] {
        assert!(readme.contains(needle), "README.md mentions `{needle}`");
    }
    assert_commands_are_real("README.md", &readme);
}

#[test]
fn readme_what_works_today_describes_the_daily_note_features_in_glossary_terms() {
    let readme = readme();
    let start = readme
        .find("## What works today")
        .expect("README.md has a `What works today` section");
    let rest = &readme[start + 3..];
    let end = rest.find("\n## ").map(|i| i + 3).unwrap_or(rest.len());
    let section = &readme[start..start + end];
    has_all_terms(
        "README.md `What works today`",
        section,
        &[
            "daily note",
            "Days",
            "Topics",
            "reviewed",
            "excerpt",
            "Smart Folder",
            "pinned",
            "Graph view",
            "append",
        ],
    );
}

#[test]
fn readme_carries_the_schema_v5_upgrade_note() {
    let readme = readme();
    let lower = readme.to_lowercase();
    assert!(readme.contains("V5"), "README.md mentions schema V5");
    for needle in ["memex.db", "memex.db-wal", "memex.db-shm"] {
        assert!(
            readme.contains(needle),
            "the backup list names {needle} (back up all three files first)"
        );
    }
    for phrase in ["back up", "restart", "scratch vault", "together"] {
        assert!(
            lower.contains(phrase),
            "the V5 note says `{phrase}` (back up first; install the binary and \
             app together; restart MCP clients; try a scratch vault first)"
        );
    }
    assert!(
        lower.contains("older") && lower.contains("refuse"),
        "the V5 note says older `memex` binaries refuse V5 vaults"
    );
}

// ======================================================================
// AC 6: docs/daily-review.md
// ======================================================================

#[test]
fn daily_review_doc_contains_the_prompt_commands_the_append_command_and_claude_dash_p() {
    let doc = daily_review();
    for needle in [
        "memex prompt review",
        "memex prompt capture",
        "memex append",
        "claude -p",
    ] {
        assert!(
            doc.contains(needle),
            "docs/daily-review.md contains `{needle}`"
        );
    }
}

#[test]
fn daily_review_doc_warns_that_memex_append_is_the_one_cli_write_intended_for_automation() {
    let doc = daily_review();
    let flat = doc.split_whitespace().collect::<Vec<_>>().join(" ");
    // The sentence that names `memex append` as the one CLI write for automation.
    let sentence = flat
        .split_inclusive(['.', '!', '?'])
        .find(|s| s.contains("one CLI write intended for automation"))
        .unwrap_or_else(|| {
            panic!("docs/daily-review.md says `the one CLI write intended for automation`")
        });
    assert!(
        sentence.contains("memex append"),
        "that sentence names `memex append`: {sentence}"
    );
    // And the companion warning: no shell access to the write subcommands.
    let lower = flat.to_lowercase();
    assert!(
        lower.contains("shell access") && lower.contains("write subcommands"),
        "docs/daily-review.md tells people not to give agents shell access to `memex` \
         write subcommands"
    );
    assert!(
        lower.contains("caller identity") || lower.contains("transport"),
        "docs/daily-review.md explains that the caller identity is the transport"
    );
}

#[test]
fn daily_review_doc_shows_the_append_output_contract_verbatim() {
    let doc = daily_review();
    let c212 = r#"{"vault_id":"01HV…","note_id":"01J9…","date":"2026-10-03","block_ids":["b7k2m9"],"content_version":4,"version":9,"prior_state":"Reviewed"}"#;
    assert!(
        doc.contains(c212),
        "the `memex append` worked example prints the C2.12 output line verbatim"
    );
    assert!(
        doc.contains("memex append --vault"),
        "the worked example passes --vault"
    );
}

#[test]
fn daily_review_doc_covers_both_prompts_every_client_and_the_recurring_runs() {
    let doc = daily_review();
    let lower = doc.to_lowercase();
    for needle in [
        "review_daily_notes",
        "capture",
        "claude desktop",
        "claude code",
        "raycast",
        "scheduled task",
        "cron",
        "claude-desktop-setup.md",
    ] {
        assert!(
            lower.contains(needle),
            "docs/daily-review.md covers `{needle}`"
        );
    }
    // The Raycast / MCP client config runs `memex serve`.
    assert!(
        doc.contains("\"command\"") && doc.contains("\"serve\""),
        "a client config block runs `memex serve`"
    );
    // A real crontab line running `claude -p`.
    let cron = Regex::new(r"(?m)^\s*[\d*/,-]+(\s+[\d*/,-]+){4}\s+.*claude -p").unwrap();
    assert!(
        cron.is_match(&doc),
        "docs/daily-review.md has a cron line running `claude -p`"
    );
    // Req 74: the app depends on none of this and never launches an agent.
    let flat = lower.split_whitespace().collect::<Vec<_>>().join(" ");
    let app_never = Regex::new(r"app[^.]*never[^.]*(launch|schedul)").unwrap();
    assert!(
        app_never.is_match(&flat),
        "docs/daily-review.md says the app never launches or schedules an agent"
    );
}

#[test]
fn daily_review_doc_uses_glossary_terms_and_none_of_the_avoided_ones() {
    let doc = daily_review();
    has_all_terms(
        "docs/daily-review.md",
        &doc,
        &[
            "daily note",
            "topic note",
            "Smart Folder",
            "pinned",
            "reviewed",
            "review",
            "capture",
            "block",
            "transclusion",
            "excerpt",
            "Topics footer",
            "agent",
        ],
    );
    assert_no_avoided_terms("docs/daily-review.md", &doc);
}

#[test]
fn daily_review_doc_shows_only_real_commands_and_real_tool_names() {
    let doc = daily_review();
    let (tools, _) = served_names();
    assert_commands_are_real("docs/daily-review.md", &doc);
    assert_tool_names_exist("docs/daily-review.md", &doc, &tools, true);
}

// ======================================================================
// AC 8: docs/daily-acceptance.md exists in the canvas-acceptance style.
// (Running it with a real Claude Code session is manual; its shape is not.)
// ======================================================================

#[test]
fn daily_acceptance_script_has_numbered_sections_with_expected_lines() {
    let doc = daily_acceptance();
    assert!(
        doc.lines().next().is_some_and(|l| l.starts_with("# ")),
        "the script opens with a title"
    );
    assert!(
        doc.contains("## Prereqs"),
        "like docs/canvas-acceptance.md, the script opens with `## Prereqs`"
    );
    let heading = Regex::new(r"(?m)^## (\d+)\. .+$").unwrap();
    let numbers: Vec<u32> = heading
        .captures_iter(&doc)
        .map(|c| c[1].parse().unwrap())
        .collect();
    assert!(
        numbers.len() >= 5,
        "at least five numbered sections: {numbers:?}"
    );
    let expected_run: Vec<u32> = (1..=numbers.len() as u32).collect();
    assert_eq!(numbers, expected_run, "sections are numbered 1..n in order");

    // Every numbered section ends in at least one **Expected** line.
    let starts: Vec<usize> = heading.find_iter(&doc).map(|m| m.start()).collect();
    for (i, start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(doc.len());
        let section = &doc[*start..end];
        assert!(
            section.contains("**Expected**"),
            "numbered section {} has an **Expected** line: {}",
            i + 1,
            section.lines().next().unwrap_or_default()
        );
    }
}

#[test]
fn daily_acceptance_script_covers_review_capture_quick_entry_pinning_and_depth() {
    let doc = daily_acceptance();
    let heading = Regex::new(r"(?m)^## \d+\. (.+)$").unwrap();
    let titles: Vec<String> = heading
        .captures_iter(&doc)
        .map(|c| c[1].to_lowercase())
        .collect();
    for (what, keyword) in [
        ("review", "review"),
        ("capture", "capture"),
        ("Raycast-style quick entry", "append"),
        ("pinning", "pinn"),
        ("depth", "depth"),
    ] {
        assert!(
            titles.iter().any(|t| t.contains(keyword)),
            "a numbered section covers {what} (heading containing `{keyword}`): {titles:?}"
        );
    }
    for needle in [
        "review_daily_notes",
        "memex append",
        "smart_folder_max_depth",
    ] {
        assert!(
            doc.contains(needle),
            "docs/daily-acceptance.md uses `{needle}`"
        );
    }
    assert!(
        doc.contains("claude"),
        "the script is run with a real Claude Code session"
    );
}

#[test]
fn daily_acceptance_script_runs_against_a_scratch_vault_never_the_real_one() {
    let doc = daily_acceptance();
    assert!(
        !doc.contains("~/memex"),
        "the script never touches the real vault"
    );
    assert!(
        doc.to_lowercase().contains("scratch"),
        "the script says it runs against a scratch vault"
    );
    assert!(
        doc.contains("memex init"),
        "the script creates its scratch vault with `memex init`"
    );
}

#[test]
fn daily_acceptance_script_shows_only_real_commands_and_real_tool_names() {
    let doc = daily_acceptance();
    let (tools, _) = served_names();
    assert_commands_are_real("docs/daily-acceptance.md", &doc);
    assert_tool_names_exist("docs/daily-acceptance.md", &doc, &tools, false);
}

#[test]
fn daily_acceptance_script_uses_glossary_terms_and_none_of_the_avoided_ones() {
    let doc = daily_acceptance();
    has_all_terms(
        "docs/daily-acceptance.md",
        &doc,
        &[
            "daily note",
            "topic note",
            "Smart Folder",
            "pinned",
            "reviewed",
            "capture",
            "excerpt",
            "Topics footer",
            "agent",
        ],
    );
    assert_no_avoided_terms("docs/daily-acceptance.md", &doc);
}
