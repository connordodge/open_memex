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

#[path = "support/tool_names.rs"]
mod tool_names;

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
fn readme_names_all_tools_and_both_prompts_the_server_exposes() {
    let (tools, prompts) = served_names();
    assert_eq!(
        tools.iter().map(String::as_str).collect::<Vec<_>>(),
        tool_names::all_tool_names(),
        "the server exposes exactly the shared tool list"
    );
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
    assert!(!readme.contains("13 MCP tools"), "the tool count is stale");
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
            "Note footer",
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
            "Note footer",
            "agent",
        ],
    );
    assert_no_avoided_terms("docs/daily-acceptance.md", &doc);
}

// ======================================================================
// docs/claude-desktop-setup.md stays in step with the served tools.
// ======================================================================

#[test]
fn claude_desktop_setup_doc_names_only_real_tools_and_no_stale_count() {
    let doc = read_repo_file("docs/claude-desktop-setup.md");
    let (tools, prompts) = served_names();
    assert_tool_names_exist("docs/claude-desktop-setup.md", &doc, &tools, true);
    for stale in [
        "13 MCP tools",
        "13 tools",
        "not yet exposed",
        "exposed as MCP tools",
    ] {
        assert!(
            !doc.contains(stale),
            "docs/claude-desktop-setup.md carries the stale claim `{stale}`"
        );
    }
    assert!(
        doc.contains(&format!("{} tools", tools.len())),
        "the doc states the served tool count ({})",
        tools.len()
    );
    for prompt in &prompts {
        assert!(
            doc.contains(&format!("`{prompt}`")),
            "docs/claude-desktop-setup.md mentions the `{prompt}` prompt"
        );
    }
    assert!(
        doc.contains("daily-review.md"),
        "the doc links the review guide"
    );
}

// ======================================================================
// WI #104 (D1): docs/hosted-vault.md and the docs that point to it
// (Spec #67, req 2, 29, 55, 56; User Story 12).
//
// The prose is read by hand and followed on real hardware (MANUAL); these
// tests pin the facts that can be checked mechanically. Helpers here carry a
// `hosted_` / `wi104_` prefix so sibling WIs editing this file do not collide.
// ======================================================================

const HOSTED_DOC: &str = "docs/hosted-vault.md";

fn hosted_vault_doc() -> String {
    read_repo_file(HOSTED_DOC)
}

/// A markdown heading (outside fenced blocks) and everything under it, down to
/// the next heading of the same or a shallower level.
struct HostedSection {
    level: usize,
    title: String,
    body: String,
}

fn hosted_sections(md: &str) -> Vec<HostedSection> {
    let lines: Vec<&str> = md.lines().collect();
    // (level, title, line index) of each heading.
    let mut heads: Vec<(usize, String, usize)> = Vec::new();
    let mut in_fence = false;
    for (i, line) in lines.iter().enumerate() {
        if line.trim_start().starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            continue;
        }
        let hashes = line.chars().take_while(|c| *c == '#').count();
        if (1..=6).contains(&hashes) && line[hashes..].starts_with(' ') {
            heads.push((hashes, line[hashes..].trim().to_string(), i));
        }
    }
    let mut out = Vec::new();
    for (n, (level, title, start)) in heads.iter().enumerate() {
        let end = heads[n + 1..]
            .iter()
            .find(|(l, _, _)| l <= level)
            .map(|(_, _, i)| *i)
            .unwrap_or(lines.len());
        out.push(HostedSection {
            level: *level,
            title: title.clone(),
            body: lines[*start..end].join("\n"),
        });
    }
    out
}

/// The first section whose title matches `title_re` (case-insensitive).
fn hosted_section(md: &str, what: &str, title_re: &str) -> HostedSection {
    let re = Regex::new(&format!("(?i){title_re}")).unwrap();
    let sections = hosted_sections(md);
    let titles: Vec<String> = sections.iter().map(|s| s.title.clone()).collect();
    sections
        .into_iter()
        .find(|s| re.is_match(&s.title))
        .unwrap_or_else(|| {
            panic!("the doc has a section for {what} (a heading matching /{title_re}/): {titles:?}")
        })
}

/// `(language, body)` of every fenced code block.
fn hosted_fenced_blocks(md: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut current: Option<(String, Vec<&str>)> = None;
    for line in md.lines() {
        let trimmed = line.trim_start();
        if let Some(info) = trimmed.strip_prefix("```") {
            match current.take() {
                Some((lang, body)) => out.push((lang, body.join("\n"))),
                None => current = Some((info.trim().to_lowercase(), Vec::new())),
            }
        } else if let Some((_, body)) = current.as_mut() {
            body.push(line);
        }
    }
    out
}

/// Lower-cased text with every run of whitespace collapsed to one space.
fn hosted_flat_lower(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn hosted_assert_mentions(what: &str, text: &str, needles: &[&str]) {
    let flat = hosted_flat_lower(text);
    for needle in needles {
        assert!(
            flat.contains(&needle.to_lowercase()),
            "{what} mentions `{needle}`"
        );
    }
}

const HOSTED_NAS: (&str, &str) = ("a NAS (Synology or QNAP)", r"\bnas\b|synology|qnap");
const HOSTED_LINUX: (&str, &str) = ("Linux (systemd)", r"linux|systemd");
const HOSTED_MAC: (&str, &str) = ("an always-on Mac (launchd)", r"\bmac\b|launchd");
const HOSTED_MOVE: (&str, &str) = ("moving a local vault onto the server", r"\bmove|moving");

/// Every file under `dir` (not following symlinks), skipping build output,
/// dependency and VCS directories.
fn wi104_walk(dir: &std::path::Path, out: &mut Vec<PathBuf>) {
    const SKIP: [&str; 9] = [
        ".git",
        "target",
        "node_modules",
        "build",
        ".dart_tool",
        "Pods",
        "ephemeral",
        ".symlinks",
        ".claude",
    ];
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !SKIP.contains(&name.as_str()) {
                wi104_walk(&path, out);
            }
        } else if kind.is_file() {
            out.push(path);
        }
    }
}

// ---------- AC 1: platform sections, req 55 topics, TZ ----------

#[test]
fn hosted_vault_doc_has_a_section_per_platform_and_every_req_55_topic() {
    let doc = hosted_vault_doc();
    assert!(
        doc.lines().next().is_some_and(|l| l.starts_with("# ")),
        "{HOSTED_DOC} opens with a title"
    );
    // A8 set-up sheet step 1: "see docs/hosted-vault.md for a nas, linux or a mac".
    for (what, re) in [HOSTED_NAS, HOSTED_LINUX, HOSTED_MAC, HOSTED_MOVE] {
        hosted_section(&doc, what, re);
    }
    // The other req 55 topics each get a heading.
    hosted_section(&doc, "choosing the listen address", r"listen");
    hosted_section(&doc, "the access token and rotating it", r"token");
    hosted_section(&doc, "connecting the app and agents", r"connect");
    hosted_section(&doc, "troubleshooting", r"troubleshoot");
    // The A8 set-up sheet steps the doc keeps in step with.
    hosted_assert_mentions(
        HOSTED_DOC,
        &doc,
        &[
            "memex init",
            "memex serve --root",
            "--listen",
            ".memex/access-token",
        ],
    );
}

#[test]
fn hosted_vault_doc_nas_section_covers_docker_ssh_and_a_rust_container_build() {
    let doc = hosted_vault_doc();
    let nas = hosted_section(&doc, HOSTED_NAS.0, HOSTED_NAS.1);
    hosted_assert_mentions(
        "the NAS section",
        &nas.body,
        &["synology", "qnap", "docker", "ssh", "rust", "cargo build"],
    );
}

#[test]
fn hosted_vault_doc_sets_tz_in_the_docker_systemd_and_launchd_examples() {
    let doc = hosted_vault_doc();

    let nas = hosted_section(&doc, HOSTED_NAS.0, HOSTED_NAS.1);
    let docker_tz = Regex::new(r"\bTZ\s*[=:]\s*\S+").unwrap();
    assert!(
        hosted_fenced_blocks(&nas.body)
            .iter()
            .any(|(_, b)| b.to_lowercase().contains("docker") && docker_tz.is_match(b)),
        "the NAS section has a Docker example that sets TZ"
    );

    let linux = hosted_section(&doc, HOSTED_LINUX.0, HOSTED_LINUX.1);
    let systemd_tz = Regex::new(r#"(?m)^\s*Environment="?TZ=\S+"#).unwrap();
    assert!(
        hosted_fenced_blocks(&linux.body)
            .iter()
            .any(|(_, b)| b.contains("[Service]") && systemd_tz.is_match(b)),
        "the Linux section has a systemd unit with Environment=TZ=..."
    );

    let mac = hosted_section(&doc, HOSTED_MAC.0, HOSTED_MAC.1);
    let plist_tz = Regex::new(r"<key>TZ</key>\s*<string>[^<]+</string>").unwrap();
    assert!(
        hosted_fenced_blocks(&mac.body)
            .iter()
            .any(|(_, b)| b.contains("<plist") && plist_tz.is_match(b)),
        "the Mac section has a launchd plist with a TZ key"
    );

    // Req 59: the server's own zone is only the fallback for callers that
    // send no UTC offset.
    hosted_assert_mentions(HOSTED_DOC, &doc, &["fallback", "offset"]);
}

#[test]
fn hosted_vault_doc_service_examples_run_memex_serve_with_root_and_listen() {
    let doc = hosted_vault_doc();
    for ((what, re), marker) in [
        (HOSTED_NAS, "docker"),
        (HOSTED_LINUX, "[Service]"),
        (HOSTED_MAC, "<plist"),
    ] {
        let section = hosted_section(&doc, what, re);
        let block = hosted_fenced_blocks(&section.body)
            .into_iter()
            .map(|(_, b)| b)
            .find(|b| b.to_lowercase().contains(&marker.to_lowercase()))
            .unwrap_or_else(|| panic!("the {what} section has a `{marker}` example block"));
        for needle in ["serve", "--root", "--listen"] {
            assert!(
                block.contains(needle),
                "the {what} example runs `memex serve` with `{needle}`: {block}"
            );
        }
    }
}

#[test]
fn hosted_vault_doc_moves_a_local_vault_through_incoming_copy_then_rename() {
    let doc = hosted_vault_doc();
    let moving = hosted_section(&doc, HOSTED_MOVE.0, HOSTED_MOVE.1);
    let flat = hosted_flat_lower(&moving.body);
    for needle in ["quit", "smb", "half-copied"] {
        assert!(
            flat.contains(needle),
            "the move section mentions `{needle}`"
        );
    }
    // The vault-name rule (req 15): letters, digits, - and _, 1-64 characters,
    // compared case-insensitively.
    for needle in ["letters", "digits", "64", "case-insensitive"] {
        assert!(
            flat.contains(needle),
            "the move section states the vault-name rule (`{needle}`)"
        );
    }

    // Copy into <root>/.incoming/ first, then `mv` it into <root>/<name>.
    let blocks: String = hosted_fenced_blocks(&moving.body)
        .into_iter()
        .map(|(_, b)| b)
        .collect::<Vec<_>>()
        .join("\n");
    let lines: Vec<&str> = blocks.lines().map(str::trim).collect();
    let copy_at = lines
        .iter()
        .position(|l| (l.starts_with("cp ") || l.starts_with("rsync ")) && l.contains(".incoming"))
        .expect("a `cp` or `rsync` line copies the vault into .incoming");
    let rename_at = lines
        .iter()
        .position(|l| l.starts_with("mv ") && l.contains(".incoming"))
        .expect("a `mv` line renames the copy out of .incoming");
    assert!(copy_at < rename_at, "copy first, rename second: {lines:?}");
    let words: Vec<&str> = lines[rename_at].split_whitespace().collect();
    assert!(
        words.len() >= 3 && words[1].contains(".incoming") && !words[2].contains(".incoming"),
        "`mv` moves <root>/.incoming/<x> to <root>/<name>, outside .incoming: {}",
        lines[rename_at]
    );
}

#[test]
fn hosted_vault_doc_explains_the_token_file_and_how_to_rotate_it() {
    let doc = hosted_vault_doc();
    let token = hosted_section(&doc, "the access token and rotating it", r"token");
    let flat = hosted_flat_lower(&token.body);
    for needle in [
        "memex_access_token",
        ".memex/access-token",
        "0600",
        "rotate",
        "delete",
        "restart",
    ] {
        assert!(
            flat.contains(needle),
            "the token section mentions `{needle}`"
        );
    }
    // Req 4: the token is never printed or logged.
    assert!(
        flat.contains("never printed") || flat.contains("never logged"),
        "the token section says the token is never printed or logged"
    );
}

#[test]
fn hosted_vault_doc_explains_how_to_choose_the_listen_address() {
    let doc = hosted_vault_doc();
    let listen = hosted_section(&doc, "choosing the listen address", r"listen");
    let flat = hosted_flat_lower(&listen.body);
    for needle in [
        "--listen",
        "no default",
        "0.0.0.0:7878",
        "lan",
        "tailscale",
        "tailnet-ip",
    ] {
        assert!(
            flat.contains(needle),
            "the listen section mentions `{needle}`"
        );
    }
}

#[test]
fn hosted_vault_doc_troubleshooting_has_entries_for_401_cannot_reach_firewall_and_network_drive() {
    let doc = hosted_vault_doc();
    let trouble = hosted_section(&doc, "troubleshooting", r"troubleshoot");
    let entries: Vec<String> = hosted_sections(&trouble.body)
        .into_iter()
        .filter(|s| s.level > trouble.level)
        .map(|s| s.title.to_lowercase())
        .collect();
    for (what, needle) in [
        ("401", "401"),
        ("cannot reach the server", "reach"),
        ("the firewall", "firewall"),
        ("the network-drive refusal", "network drive"),
    ] {
        assert!(
            entries.iter().any(|t| t.contains(needle)),
            "troubleshooting has an entry for {what} (a sub-heading with `{needle}`): {entries:?}"
        );
    }
    let flat = hosted_flat_lower(&trouble.body);
    for needle in [
        "network_filesystem",
        "memex vault check --vault",
        "exits 0",
        "access token",
    ] {
        assert!(flat.contains(needle), "troubleshooting mentions `{needle}`");
    }
}

// ---------- AC 2: trusted network only (req 2) ----------

#[test]
fn hosted_vault_doc_says_lan_or_tailnet_only_plain_http_no_tls_and_carries_the_never_expose_line() {
    let doc = hosted_vault_doc();
    let flat = hosted_flat_lower(&doc.replace(['*', '_'], ""));
    for needle in [
        "trusted lan",
        "tailnet",
        "public internet",
        "plain http",
        "no tls",
    ] {
        assert!(flat.contains(needle), "{HOSTED_DOC} says `{needle}`");
    }
    // The A8 set-up sheet's line, verbatim (case aside).
    assert!(
        flat.contains(
            "use your home network or tailscale. never expose the server to the internet."
        ),
        "{HOSTED_DOC} carries the set-up sheet's never-expose line"
    );
}

// ---------- AC 3: Claude Desktop and Raycast configs (req 29) ----------

/// One client's `command` / `args` / `env` as written in the doc.
struct Wi104ClientConfig {
    command: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
}

/// Parses every ```json block of the client's section; returns the first server
/// entry (inside `mcpServers`, or the block's own object).
fn wi104_client_config(client_title_re: &str, what: &str) -> Wi104ClientConfig {
    let doc = hosted_vault_doc();
    let section = hosted_section(&doc, what, client_title_re);
    let blocks: Vec<(String, String)> = hosted_fenced_blocks(&section.body)
        .into_iter()
        .filter(|(lang, _)| lang == "json")
        .collect();
    assert!(
        !blocks.is_empty(),
        "the {what} section has a ```json config block"
    );
    let mut entry: Option<Value> = None;
    for (_, body) in &blocks {
        let parsed: Value = serde_json::from_str(body)
            .unwrap_or_else(|e| panic!("the {what} config parses as JSON ({e}): {body}"));
        let candidate = match parsed.get("mcpServers").and_then(Value::as_object) {
            Some(servers) => servers.values().next().cloned(),
            None => Some(parsed.clone()),
        };
        if entry.is_none() {
            entry = candidate.filter(|v| v.get("command").is_some());
        }
    }
    let entry = entry.unwrap_or_else(|| panic!("the {what} config has a server with `command`"));
    let command = entry["command"]
        .as_str()
        .unwrap_or_else(|| panic!("the {what} `command` is a string: {entry}"))
        .to_string();
    let args = entry["args"]
        .as_array()
        .unwrap_or_else(|| panic!("the {what} `args` is an array: {entry}"))
        .iter()
        .map(|a| {
            a.as_str()
                .unwrap_or_else(|| panic!("the {what} args are strings: {entry}"))
                .to_string()
        })
        .collect();
    let env = entry["env"]
        .as_object()
        .unwrap_or_else(|| panic!("the {what} `env` is an object: {entry}"))
        .iter()
        .map(|(k, v)| {
            (
                k.clone(),
                v.as_str()
                    .unwrap_or_else(|| panic!("the {what} env values are strings: {entry}"))
                    .to_string(),
            )
        })
        .collect();
    Wi104ClientConfig { command, args, env }
}

fn wi104_assert_serve_remote_config(what: &str, cfg: &Wi104ClientConfig) {
    let basename = cfg.command.rsplit('/').next().unwrap();
    assert_eq!(basename, "memex", "the {what} command runs memex");
    assert_eq!(
        cfg.args.len(),
        3,
        "the {what} args are [serve, --remote, <url>]: {:?}",
        cfg.args
    );
    assert_eq!(cfg.args[0], "serve", "{what} args start with serve");
    assert_eq!(cfg.args[1], "--remote", "{what} args pass --remote");
    let url = Regex::new(r"^https?://[^/\s]+/vaults/[A-Za-z0-9_-]{1,64}/mcp$").unwrap();
    assert!(
        url.is_match(&cfg.args[2]),
        "the {what} URL is <server-url>/vaults/<name>/mcp with a concrete vault name: {}",
        cfg.args[2]
    );
    let token = cfg
        .env
        .iter()
        .find(|(k, _)| k == "MEMEX_ACCESS_TOKEN")
        .map(|(_, v)| v.as_str());
    assert!(
        token.is_some_and(|t| !t.trim().is_empty()),
        "the {what} env sets MEMEX_ACCESS_TOKEN: {:?}",
        cfg.env
    );
}

/// Runs the config's `args` through the real binary, with the URL's host and
/// port swapped for a closed local port; returns `(exit code, stderr)`.
fn wi104_run_config_at_closed_port(cfg: &Wi104ClientConfig) -> (Option<i32>, String) {
    let closed = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    let rewrite = Regex::new(r"^(https?://)[^/]+(/.*)$").unwrap();
    let args: Vec<String> = cfg
        .args
        .iter()
        .map(|a| {
            rewrite
                .replace(a, format!("${{1}}127.0.0.1:{closed}${{2}}"))
                .to_string()
        })
        .collect();
    let scratch = tempfile::tempdir().unwrap();
    let stderr_path = scratch.path().join("stderr");
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.args(&args)
        .env_remove("MEMEX_ACCESS_TOKEN")
        .env_remove("RUST_LOG")
        .current_dir(scratch.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(std::fs::File::create(&stderr_path).unwrap()));
    for key in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    ] {
        cmd.env_remove(key);
    }
    for (k, v) in &cfg.env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().expect("spawn memex with the documented args");
    let started = std::time::Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break Some(status);
        }
        if started.elapsed() > Duration::from_secs(30) {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let stderr = std::fs::read_to_string(&stderr_path).unwrap_or_default();
    (status.and_then(|s| s.code()), stderr)
}

fn wi104_assert_closed_port_exit(what: &str, cfg: &Wi104ClientConfig) {
    let (code, stderr) = wi104_run_config_at_closed_port(cfg);
    assert_eq!(
        code,
        Some(1),
        "the {what} args exit 1 (preflight), never 2 (usage): stderr={stderr:?}"
    );
    let lines: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(lines.len(), 1, "exactly one C1 line on stderr: {stderr:?}");
    let c1: Value = serde_json::from_str(lines[0])
        .unwrap_or_else(|e| panic!("the stderr line is JSON ({e}): {:?}", lines[0]));
    assert!(
        c1["error"]["message"].is_string(),
        "a C1 line has a string message: {c1}"
    );
    assert_eq!(
        c1["error"]["code"], "server_unreachable",
        "a closed port is reported as server_unreachable: {c1}"
    );
}

#[test]
fn hosted_vault_doc_claude_desktop_config_parses_and_runs_serve_remote() {
    let cfg = wi104_client_config(r"claude desktop", "Claude Desktop");
    wi104_assert_serve_remote_config("Claude Desktop", &cfg);
}

#[test]
fn hosted_vault_doc_raycast_config_parses_and_runs_serve_remote() {
    let cfg = wi104_client_config(r"raycast", "Raycast");
    wi104_assert_serve_remote_config("Raycast", &cfg);
}

#[test]
fn hosted_vault_doc_claude_desktop_args_exit_1_with_a_c1_line_at_a_closed_port() {
    let cfg = wi104_client_config(r"claude desktop", "Claude Desktop");
    wi104_assert_closed_port_exit("Claude Desktop", &cfg);
}

#[test]
fn hosted_vault_doc_raycast_args_exit_1_with_a_c1_line_at_a_closed_port() {
    let cfg = wi104_client_config(r"raycast", "Raycast");
    wi104_assert_closed_port_exit("Raycast", &cfg);
}

// ---------- AC 4: Claude Code over native HTTP (req 29) ----------

#[test]
fn hosted_vault_doc_claude_code_command_has_both_headers_and_the_dst_note() {
    let doc = hosted_vault_doc();
    let section = hosted_section(&doc, "Claude Code", r"claude code");
    // Join shell line continuations, then collapse whitespace.
    let joined = section.body.replace("\\\n", " ");
    let flat = joined.split_whitespace().collect::<Vec<_>>().join(" ");
    let command = Regex::new(concat!(
        r#"claude mcp add --transport http (\S+) (https?://[^/\s]+/vaults/[A-Za-z0-9_-]{1,64}/mcp) "#,
        r#"--header "Authorization: Bearer \$MEMEX_ACCESS_TOKEN" "#,
        r#"--header "X-Memex-UTC-Offset: ([^"\s]+)""#,
    ))
    .unwrap();
    let caps = command.captures(&flat).unwrap_or_else(|| {
        panic!(
            "the Claude Code section shows `claude mcp add --transport http <name> <url> \
             --header \"Authorization: Bearer $MEMEX_ACCESS_TOKEN\" \
             --header \"X-Memex-UTC-Offset: <+-HH:MM>\"` with a /vaults/<name>/mcp URL: {flat}"
        )
    });
    let offset = &caps[3];
    assert!(
        offset.contains("HH:MM") || Regex::new(r"^[+\-]\d{2}:\d{2}$").unwrap().is_match(offset),
        "the offset header value is <+-HH:MM> or a concrete +-HH:MM: {offset}"
    );
    // The DST note, next to the command.
    let lower = flat.to_lowercase();
    assert!(
        lower.contains("dst") || lower.contains("daylight"),
        "the Claude Code section notes the static offset needs updating at DST changes"
    );
    assert!(
        lower.contains("bridge") && lower.contains("automatically"),
        "the Claude Code section says the bridge sends the offset automatically"
    );
}

// ---------- AC 5: real commands, serve --help ----------

#[test]
fn hosted_vault_doc_shows_only_real_commands_and_serve_help_lists_the_flags_it_uses() {
    let doc = hosted_vault_doc();
    assert_commands_are_real(HOSTED_DOC, &doc);
    let shown: Vec<(String, Option<String>)> = memex_invocations(&doc);
    for (sub, next) in [
        ("init", None),
        ("serve", None),
        ("vault", Some("check".to_string())),
    ] {
        assert!(
            shown
                .iter()
                .any(|(s, n)| *s == sub && (next.is_none() || *n == next)),
            "{HOSTED_DOC} shows `memex {sub}`"
        );
    }
    let help = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--help"])
        .output()
        .expect("run memex serve --help");
    assert!(help.status.success(), "memex serve --help succeeds");
    let help = String::from_utf8_lossy(&help.stdout).to_string();
    for flag in ["--root", "--listen", "--remote"] {
        assert!(help.contains(flag), "memex serve --help lists {flag}");
    }
    // Every flag the doc's `memex serve` lines pass is one `serve --help` lists,
    // and the three modes are all shown.
    let flag = Regex::new(r"\s(--[a-z][a-z-]*)").unwrap();
    let mut used = BTreeSet::new();
    for snippet in code_snippets(&doc) {
        for line in snippet.lines().filter(|l| l.contains("memex serve")) {
            for c in flag.captures_iter(line) {
                used.insert(c[1].to_string());
            }
        }
    }
    for needed in ["--root", "--listen", "--remote"] {
        assert!(
            used.contains(needed),
            "{HOSTED_DOC} shows `memex serve {needed}`: {used:?}"
        );
    }
    for f in &used {
        assert!(
            help.contains(f.as_str()),
            "{HOSTED_DOC} passes `{f}`, which memex serve --help does not list"
        );
    }
}

// ---------- AC 6: glossary terms (D22) ----------

/// The avoided terms of GLOSSARY.md that concern the hosted vault (lines 76-92).
const WI104_AVOID_TERMS: [&str; 7] = [
    "sync server",
    "NAS mode",
    "remote vault",
    "shared vault",
    "network vault",
    "API key",
    "synced vault",
];

fn wi104_assert_no_hosted_avoided_terms(doc_name: &str, md: &str) {
    let glossary = read_repo_file("GLOSSARY.md");
    let avoid_lines: String = glossary
        .lines()
        .filter(|l| l.starts_with("_Avoid_"))
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase();
    for term in WI104_AVOID_TERMS {
        assert!(
            avoid_lines.contains(&term.to_lowercase()),
            "{term} is an `_Avoid_` term in GLOSSARY.md"
        );
    }
    let prose = hosted_flat_lower(&prose_only(md));
    for term in WI104_AVOID_TERMS {
        let re = Regex::new(&format!(r"\b{}\b", regex::escape(&term.to_lowercase()))).unwrap();
        assert!(
            !re.is_match(&prose),
            "{doc_name} uses the GLOSSARY.md `_Avoid_` term `{term}`"
        );
    }
}

#[test]
fn hosted_vault_doc_uses_glossary_terms_and_none_of_the_avoided_ones() {
    let doc = hosted_vault_doc();
    has_all_terms(
        HOSTED_DOC,
        &doc,
        &[
            "vault server",
            "vault root",
            "hosted vault",
            "local vault",
            "access token",
        ],
    );
    assert_no_avoided_terms(HOSTED_DOC, &doc);
    wi104_assert_no_hosted_avoided_terms(HOSTED_DOC, &doc);
}

// ---------- AC 7: the older docs drop single-device lines and link the new doc ----------

#[test]
fn readme_claude_desktop_setup_and_canvas_drop_single_device_lines_and_link_the_hosted_vault_doc() {
    let link = Regex::new(r"\]\(([^)\s#]*hosted-vault\.md)(#[^)\s]*)?\)").unwrap();
    for rel in [
        "README.md",
        "docs/claude-desktop-setup.md",
        "docs/canvas.md",
    ] {
        let text = read_repo_file(rel);
        let lower = hosted_flat_lower(&text);
        for stale in ["single device", "single-device", "no sync"] {
            assert!(!lower.contains(stale), "{rel} still says `{stale}`");
        }
        let target = link
            .captures(&text)
            .unwrap_or_else(|| panic!("{rel} links docs/hosted-vault.md in a markdown link"))[1]
            .to_string();
        let dir = std::path::Path::new(rel).parent().unwrap();
        let resolved = repo_root().join(dir).join(&target);
        assert!(
            resolved.is_file(),
            "{rel} links `{target}`, which resolves to {}",
            resolved.display()
        );
        assert_eq!(
            resolved.canonicalize().unwrap(),
            repo_root().join(HOSTED_DOC).canonicalize().unwrap(),
            "{rel}'s link `{target}` points at {HOSTED_DOC}"
        );
    }
}

// ---------- AC 8: no word starting with "sync" (req 56) ----------

#[test]
fn no_word_starting_with_sync_appears_in_readme_or_any_doc() {
    let root = repo_root();
    let mut files = vec![root.join("README.md")];
    wi104_walk(&root.join("docs"), &mut files);
    let word = Regex::new(r"(?i)\bsync([a-z]*)").unwrap();
    let mut hits = Vec::new();
    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue; // not text
        };
        for (n, line) in text.lines().enumerate() {
            for c in word.captures_iter(line) {
                // `async` never matches (no word boundary); `synchron...` is allowed.
                if c[1].to_lowercase().starts_with("hron") {
                    continue;
                }
                hits.push(format!(
                    "{}:{}: {}",
                    path.strip_prefix(&root).unwrap().display(),
                    n + 1,
                    line.trim()
                ));
            }
        }
    }
    assert!(
        files.len() > 1,
        "the scan reaches README.md and the files under docs/"
    );
    assert!(
        hits.is_empty(),
        "words starting with `sync` in README.md or docs/:\n{}",
        hits.join("\n")
    );
}

// ---------- AC 9: README "What works today" ----------

#[test]
fn readme_what_works_today_lists_the_serve_root_serve_remote_and_vault_check_commands() {
    let readme = readme();
    let section = hosted_section(&readme, "`What works today`", r"what works today");
    for (what, pattern) in [
        (
            "memex serve --root <dir> --listen <host:port>",
            r"memex serve --root \S+ --listen \S+",
        ),
        ("memex serve --remote <url>", r"memex serve --remote \S+"),
        (
            "memex vault check --vault <path>",
            r"memex vault check --vault \S+",
        ),
    ] {
        assert!(
            Regex::new(pattern).unwrap().is_match(&section.body),
            "README `What works today` lists `{what}`"
        );
    }
    assert!(
        section.body.contains("docs/hosted-vault.md"),
        "README `What works today` links docs/hosted-vault.md"
    );
}

// ---------- AC 10: no container definitions ship (L3) ----------

#[test]
fn repository_has_no_dockerfile_compose_file_or_image_definition() {
    // The doc is where Docker is described (inline); nothing in the tree builds one.
    let doc = hosted_vault_doc();
    assert!(
        doc.to_lowercase().contains("docker"),
        "{HOSTED_DOC} describes the Docker route for a NAS in text"
    );
    let root = repo_root();
    let mut files = Vec::new();
    wi104_walk(&root, &mut files);
    assert!(files.len() > 50, "the walk reaches the repository's files");
    let offenders: Vec<String> = files
        .iter()
        .filter(|p| {
            let name = p.file_name().unwrap().to_string_lossy().to_lowercase();
            name.starts_with("dockerfile")
                || name.ends_with(".dockerfile")
                || name.starts_with("containerfile")
                || name.starts_with("docker-compose")
                || name.starts_with("compose.")
        })
        .map(|p| p.strip_prefix(&root).unwrap().display().to_string())
        .collect();
    assert!(
        offenders.is_empty(),
        "the repository ships no Dockerfile, compose file or image definition: {offenders:?}"
    );
}

// ---------- Verify round: contracts the guide states in prose (WI #104) ----------
//
// Each of these pins one sentence of the guide to a fact about the real
// binary, so the page cannot drift from the server it describes.

/// The logical paragraph or list item (soft-wrapped lines joined, whitespace
/// collapsed) outside fenced blocks that contains `needle`, lower-cased.
fn wi104_item_with(md: &str, what: &str, needle: &str) -> String {
    let mut items: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut in_fence = false;
    for line in md.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            items.push(std::mem::take(&mut current));
            continue;
        }
        let starts_item = trimmed.starts_with("- ")
            || trimmed.starts_with("* ")
            || (trimmed.chars().next().is_some_and(|c| c.is_ascii_digit())
                && trimmed.contains(". "));
        if in_fence || trimmed.is_empty() || starts_item {
            items.push(std::mem::take(&mut current));
        }
        if !in_fence && !trimmed.is_empty() {
            current.push(' ');
            current.push_str(trimmed);
        }
    }
    items.push(current);
    let needle = needle.to_lowercase();
    items
        .into_iter()
        .map(|i| hosted_flat_lower(&i))
        .find(|i| i.contains(&needle))
        .unwrap_or_else(|| panic!("the guide has a paragraph or list item for {what} (`{needle}`)"))
}

/// A running `memex serve --root`, killed through its own handle on drop.
struct Wi104Server {
    child: Child,
    addr: String,
    _scratch: tempfile::TempDir,
}

impl Drop for Wi104Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn wi104_start_server(root: &std::path::Path) -> Wi104Server {
    let scratch = tempfile::tempdir().unwrap();
    let stderr_path = scratch.path().join("stderr");
    let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--root"])
        .arg(root)
        .args(["--listen", "127.0.0.1:0"])
        .env_remove("MEMEX_ACCESS_TOKEN")
        .env_remove("RUST_LOG")
        .current_dir(scratch.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(std::fs::File::create(&stderr_path).unwrap()))
        .spawn()
        .expect("spawn memex serve --root");
    let listening = Regex::new(r"vault server listening on http://(\S+)").unwrap();
    let started = std::time::Instant::now();
    loop {
        let stderr = std::fs::read_to_string(&stderr_path).unwrap_or_default();
        if let Some(c) = listening.captures(&stderr) {
            return Wi104Server {
                child,
                addr: c[1].to_string(),
                _scratch: scratch,
            };
        }
        if let Some(status) = child.try_wait().unwrap() {
            panic!("memex serve exited before listening ({status}): {stderr}");
        }
        if started.elapsed() > Duration::from_secs(30) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("memex serve never printed its listening line: {stderr}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// `GET path` with a bearer token over a bare socket: `(status, whole reply)`.
fn wi104_get(addr: &str, path: &str, token: &str) -> (u16, String) {
    use std::io::Read;
    let mut stream = std::net::TcpStream::connect(addr).expect("connect to the vault server");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {addr}\r\nAuthorization: Bearer {token}\r\n\
         Connection: close\r\n\r\n"
    )
    .unwrap();
    let mut reply = String::new();
    stream.read_to_string(&mut reply).unwrap();
    let status = reply
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| panic!("an HTTP status line: {reply:?}"));
    (status, reply)
}

fn wi104_server_logs(root: &std::path::Path) -> Vec<(String, String)> {
    let Ok(entries) = std::fs::read_dir(root.join(".memex")) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.starts_with("server.log"))
        .map(|n| {
            let text = std::fs::read_to_string(root.join(".memex").join(&n)).unwrap_or_default();
            (n, text)
        })
        .collect()
}

#[test]
fn hosted_vault_doc_names_the_rolled_server_log_files_the_server_really_writes() {
    let doc = hosted_vault_doc();
    let item = wi104_item_with(&doc, "the vault server log", "server.log.<date>");
    assert!(
        item.contains("<root>/.memex/") && item.contains("daily"),
        "the guide says where the log is and that it rolls daily: {item}"
    );
    // The troubleshooting entry points at the same rolled file name.
    let reach = hosted_section(&doc, "cannot reach the server", r"reach");
    assert!(
        hosted_flat_lower(&reach.body).contains("<root>/.memex/server.log.<date>"),
        "the cannot-reach entry reads <root>/.memex/server.log.<date>"
    );
    // The real server writes exactly that name.
    let root = tempfile::tempdir().unwrap();
    let _server = wi104_start_server(root.path());
    let dated = Regex::new(r"^server\.log\.\d{4}-\d{2}-\d{2}$").unwrap();
    let names: Vec<String> = wi104_server_logs(root.path())
        .into_iter()
        .map(|(n, _)| n)
        .collect();
    assert!(
        names.iter().any(|n| dated.is_match(n)),
        "the server writes <root>/.memex/server.log.<date>: {names:?}"
    );
    assert!(
        !names.iter().any(|n| n == "server.log"),
        "there is no plain server.log: {names:?}"
    );
}

#[test]
fn hosted_vault_doc_says_dot_folders_are_never_served_and_a_hand_copied_vault_needs_no_restart() {
    let doc = hosted_vault_doc();
    let item = wi104_item_with(&doc, "which folders are served", "start with a dot");
    assert!(
        item.contains("never served"),
        "the guide says folders that start with a dot are never served: {item}"
    );
    assert!(
        item.contains("copy in by hand") && item.contains("without a restart"),
        "the guide says a hand-copied vault shows up without a restart: {item}"
    );
    // The real server behaves that way.
    let root = tempfile::tempdir().unwrap();
    drop(Vault::create(root.path().join("home")).unwrap());
    drop(Vault::create(root.path().join(".hidden")).unwrap());
    let server = wi104_start_server(root.path());
    let token = std::fs::read_to_string(root.path().join(".memex/access-token")).unwrap();
    let token = token.trim();
    let (status, listed) = wi104_get(&server.addr, "/api/v1/vaults", token);
    assert_eq!(status, 200, "{listed}");
    assert!(listed.contains(r#""name":"home""#), "{listed}");
    assert!(
        !listed.contains(".hidden"),
        "a folder that starts with a dot is not served: {listed}"
    );
    // Copy a vault in by hand (complete elsewhere, then renamed into place).
    std::fs::create_dir_all(root.path().join(".incoming")).unwrap();
    drop(Vault::create(root.path().join(".incoming/later")).unwrap());
    std::fs::rename(
        root.path().join(".incoming/later"),
        root.path().join("later"),
    )
    .unwrap();
    let (status, listed) = wi104_get(&server.addr, "/api/v1/vaults", token);
    assert_eq!(status, 200, "{listed}");
    assert!(
        listed.contains(r#""name":"later""#),
        "a hand-copied vault is served without restarting the server: {listed}"
    );
}

#[test]
fn hosted_vault_doc_says_with_embeddings_applies_to_every_vault() {
    let doc = hosted_vault_doc();
    let item = wi104_item_with(
        &doc,
        "--with-embeddings on the vault server",
        "--with-embeddings",
    );
    assert!(
        item.contains("memex serve --root") && item.contains("every vault it serves"),
        "the guide says --with-embeddings on `memex serve --root` applies to every vault it \
         serves: {item}"
    );
    assert!(
        item.contains("keyword search only"),
        "the guide says leaving it off means keyword search only: {item}"
    );
    let help = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["serve", "--help"])
        .output()
        .expect("run memex serve --help");
    assert!(
        String::from_utf8_lossy(&help.stdout).contains("--with-embeddings"),
        "memex serve --help lists --with-embeddings"
    );
}

#[test]
fn hosted_vault_doc_says_an_older_memex_refuses_a_newer_vault() {
    let doc = hosted_vault_doc();
    let moving = hosted_section(&doc, "moving a local vault", r"\bmove|moving");
    let item = wi104_item_with(&moving.body, "the version rule", "an older one refuses it");
    assert!(
        item.contains("same version") && item.contains("or newer") && item.contains("upgrades"),
        "the guide says the server's memex must be the same version or newer, and that a \
         newer memex upgrades the vault when it first opens it: {item}"
    );
    // The real binary refuses a vault written by a newer schema.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("future");
    drop(Vault::create(&path).unwrap());
    let manifest_path = path.join("manifest.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&manifest_path).unwrap()).unwrap();
    manifest["schema_version"] = json!(memex_core::schema::APP_SCHEMA_VERSION + 1);
    std::fs::write(&manifest_path, manifest.to_string()).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(["ls", "--vault"])
        .arg(&path)
        .output()
        .expect("run memex ls");
    assert_eq!(out.status.code(), Some(1), "a newer vault is refused");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("schema version unsupported"),
        "the refusal names the unsupported schema version: {stderr}"
    );
}

#[test]
fn hosted_vault_doc_warns_that_a_group_or_other_readable_token_file_logs_a_warning() {
    use std::os::unix::fs::PermissionsExt;
    let doc = hosted_vault_doc();
    let token = hosted_section(&doc, "the access token", r"token");
    let item = wi104_item_with(
        &token.body,
        "the loose token file warning",
        "readable by group or others",
    );
    assert!(
        item.contains("still starts")
            && item.contains("logs a warning")
            && item.contains("chmod 600"),
        "the guide says a group- or other-readable token file still starts, logs a warning, \
         and to run chmod 600: {item}"
    );
    // The real server logs it.
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(root.path().join(".memex")).unwrap();
    let file = root.path().join(".memex/access-token");
    std::fs::write(&file, "wi104-loose-token-file\n").unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    let _server = wi104_start_server(root.path());
    let started = std::time::Instant::now();
    loop {
        let logged = wi104_server_logs(root.path())
            .iter()
            .any(|(_, text)| text.contains("WARN") && text.contains("readable by group or others"));
        if logged {
            break;
        }
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the server logs a warning for a 0644 token file: {:?}",
            wi104_server_logs(root.path())
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn hosted_vault_doc_says_which_callers_send_the_utc_offset_and_that_the_server_zone_is_a_fallback()
{
    let doc = hosted_vault_doc();
    let zone = hosted_section(&doc, "the time zone", r"time zone");
    let flat = hosted_flat_lower(&zone.body);
    let sentences: Vec<&str> = flat.split(". ").collect();
    let senders = sentences
        .iter()
        .find(|s| s.contains("send their utc offset"))
        .unwrap_or_else(|| panic!("the time zone section says who sends the UTC offset: {flat}"));
    for caller in ["the app", "memex serve --remote", "claude code"] {
        assert!(
            senders.contains(caller),
            "the sentence on who sends the UTC offset names {caller}: {senders}"
        );
    }
    assert!(
        senders.contains("with each request") && senders.contains("which day"),
        "the sentence says each request carries it and the server uses it to decide which day \
         today is: {senders}"
    );
    let fallback = sentences
        .iter()
        .find(|s| s.contains("fallback"))
        .unwrap_or_else(|| {
            panic!("the time zone section calls the server zone a fallback: {flat}")
        });
    assert!(
        fallback.contains("only the fallback") && fallback.contains("no offset"),
        "the server zone is only the fallback for a caller that sends no offset: {fallback}"
    );
}
