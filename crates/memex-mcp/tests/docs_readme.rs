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
fn readme_no_longer_claims_a_stale_tool_count_or_future_mcp_update_and_delete_tools() {
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
    let v5 = hosted_section(&readme, "the V5 upgrade", r"upgrading to schema v5").body;
    // WI #328: the backup is `memex backup`, not a hand copy of the database
    // files, and it comes before anything opens the vault with the new binary.
    assert!(
        v5.contains("`memex backup"),
        "the V5 note tells the reader to run `memex backup`: {v5}"
    );
    for file in ["memex.db-wal", "memex.db-shm"] {
        assert!(
            !v5.contains(file),
            "the V5 note no longer lists the manual copy of {file}: {v5}"
        );
    }
    let backup_at = v5.find("`memex backup").expect("memex backup");
    let install_at = v5.find("cargo install").expect("the install step");
    assert!(
        backup_at < install_at,
        "`memex backup` comes before the step that installs the new binary: {v5}"
    );
    for phrase in ["restart", "scratch vault", "together"] {
        assert!(
            lower.contains(phrase),
            "the V5 note says `{phrase}` (install the binary and app together; \
             restart MCP clients; try a scratch vault first)"
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

/// The one third-party product name the docs may spell out: the Spec bans
/// the word for a Backup, not for the name of a NAS package.
const SYNC_PRODUCT_NAME: &str = "Synology Cloud Sync";

/// Words starting with `sync` on one line, after the exact product name
/// `Synology Cloud Sync` (case-sensitive) is set aside.
fn sync_words(line: &str) -> Vec<String> {
    let word = Regex::new(r"(?i)\bsync([a-z]*)").unwrap();
    let line = line.replace(SYNC_PRODUCT_NAME, "");
    word.captures_iter(&line)
        // `async` never matches (no word boundary); `synchron...` is allowed.
        .filter(|c| !c[1].to_lowercase().starts_with("hron"))
        .map(|c| c[0].to_string())
        .collect()
}

#[test]
fn sync_scan_exempts_only_the_exact_product_name_synology_cloud_sync() {
    assert!(sync_words("Use Synology Cloud Sync or Hyper Backup.").is_empty());
    assert!(sync_words("Synology Cloud Sync, then Synology Cloud Sync again").is_empty());
    for bare in [
        "The backup is a sync.",
        "Use Cloud Sync.",
        "Use Cloud Sync on Synology.",
        "Use Synology cloud sync.",
        "Use synology Cloud Sync.",
        "Use Synology Cloud Sync and then sync the vault.",
        "A synced vault.",
    ] {
        assert!(!sync_words(bare).is_empty(), "must be flagged: {bare}");
    }
}

#[test]
fn no_word_starting_with_sync_appears_in_readme_or_any_doc() {
    let root = repo_root();
    let mut files = vec![root.join("README.md")];
    wi104_walk(&root.join("docs"), &mut files);
    let mut hits = Vec::new();
    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue; // not text
        };
        for (n, line) in text.lines().enumerate() {
            for _ in sync_words(line) {
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

// ======================================================================
// WI #243 (Spec #234 R41-R44, D44): the tag tools and `memex tag` in the docs.
//
// The prose is read by hand; these tests pin the facts that can be checked
// mechanically. Helpers carry a `wi243_` prefix.
// ======================================================================

const WI243_TAG_NAMES: [&str; 4] = ["list_tags", "tag_note", "untag_note", "add_footer_topic"];

fn wi243_desktop_setup() -> String {
    read_repo_file("docs/claude-desktop-setup.md")
}

/// The text from the heading line that starts with `heading` to the next
/// `## ` or `### ` line.
fn wi243_section(md: &str, heading: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    for line in md.lines() {
        if line.starts_with(heading) {
            inside = true;
        } else if inside && (line.starts_with("## ") || line.starts_with("### ")) {
            break;
        }
        if inside {
            out.push_str(line);
            out.push('\n');
        }
    }
    assert!(inside, "no heading starting with {heading:?}");
    out
}

/// The lines of `md` that contain `needle`.
fn wi243_lines_with<'a>(md: &'a str, needle: &str) -> Vec<&'a str> {
    md.lines().filter(|l| l.contains(needle)).collect()
}

/// Asserts the `line` says the three footer-writing tools write footer text
/// and never the person's own text.
fn wi243_assert_footer_write_line(what: &str, line: &str) {
    for tool in ["tag_note", "untag_note", "add_footer_topic"] {
        assert!(
            line.contains(&format!("`{tool}`")),
            "{what} must name `{tool}` in the same statement: {line}"
        );
    }
    let lower = line.to_lowercase();
    assert!(
        lower.contains("footer"),
        "{what} must say these tools write footer text: {line}"
    );
    assert!(
        lower.contains("daily note"),
        "{what} must say this includes daily notes: {line}"
    );
    assert!(
        Regex::new(r"(?i)\b(never|not|no)\b")
            .unwrap()
            .is_match(line),
        "{what} must say they never write the person's text: {line}"
    );
}

#[test]
fn docs_name_the_four_tag_tools_in_the_readme_the_review_guide_and_the_setup_guide() {
    for (name, doc) in [
        ("README.md", readme()),
        ("docs/daily-review.md", daily_review()),
        ("docs/claude-desktop-setup.md", wi243_desktop_setup()),
    ] {
        for tool in WI243_TAG_NAMES {
            assert!(
                doc.contains(&format!("`{tool}`")),
                "{name} must name `{tool}` in backticks"
            );
        }
    }
}

#[test]
fn desktop_setup_tool_list_gains_the_four_tag_tools_and_create_note_keeps_its_auto_tags() {
    let doc = wi243_desktop_setup();
    let section = wi243_section(&doc, "## 5. Restart Claude Desktop");
    for tool in WI243_TAG_NAMES {
        assert!(
            section.contains(&format!("`{tool}`")),
            "the setup guide's tool list (section 5) names `{tool}`:\n{section}"
        );
    }
    let create = wi243_lines_with(&section, "- `create_note`");
    assert_eq!(create.len(), 1, "one `create_note` bullet:\n{section}");
    assert!(
        create[0].contains("`inbox`") && create[0].contains("`agent-authored`"),
        "the bullet keeps the auto-tags: {}",
        create[0]
    );
    assert!(
        create[0].contains("`invalid_argument`")
            && Regex::new(r"(?i)grammar").unwrap().is_match(create[0]),
        "the bullet says a tag name outside the tag grammar is `invalid_argument` (D43): {}",
        create[0]
    );
}

#[test]
fn review_guide_lists_list_tags_and_tag_note_in_the_order_a_review_uses_the_tools() {
    let doc = daily_review();
    let line = wi243_lines_with(&doc, "in the order a review uses them");
    assert_eq!(line.len(), 1, "one ordered tool list: {line:?}");
    let line = line[0];
    let mut from = 0;
    for tool in [
        "list_unreviewed_days",
        "get_daily_note_changes",
        "list_tags",
        "tag_note",
        "mark_day_reviewed",
    ] {
        let needle = format!("`{tool}`");
        let at = line[from..]
            .find(&needle)
            .unwrap_or_else(|| panic!("{needle} missing or out of order in: {line}"));
        from += at + needle.len();
    }
}

#[test]
fn review_guide_names_no_tool_count_and_points_to_the_readme_list() {
    // TEST-CHANGE (#257, lead decision 2): the guide used to state the served
    // count and went stale again when the Feedback tools landed. It now names no
    // count at all and points to the README's list, so it cannot go stale.
    let doc = daily_review();
    let count = Regex::new(r"\b\d+ (MCP )?tools\b").unwrap();
    let stale: Vec<&str> = count.find_iter(&doc).map(|m| m.as_str()).collect();
    assert!(
        stale.is_empty(),
        "docs/daily-review.md names a tool count, which goes stale: {stale:?}"
    );
    let line = wi243_lines_with(&doc, "The full list of tools is in the");
    assert_eq!(
        line.len(),
        1,
        "one line says 'The full list of tools is in the README': {line:?}"
    );
    assert!(
        line[0].contains("[README](../README.md)"),
        "that line links the README: {}",
        line[0]
    );
}

#[test]
fn review_guide_says_the_tag_tools_write_footer_text_including_on_daily_notes_and_never_the_persons_text(
) {
    let doc = daily_review();
    let section = wi243_section(&doc, "### What the agent can and cannot do");
    let lines = wi243_lines_with(&section, "`tag_note`");
    let line = lines
        .iter()
        .find(|l| l.contains("`untag_note`") && l.contains("`add_footer_topic`"))
        .unwrap_or_else(|| {
            panic!(
                "'What the agent can and cannot do' has one statement naming `tag_note`, \
                 `untag_note` and `add_footer_topic`:\n{section}"
            )
        });
    wi243_assert_footer_write_line("docs/daily-review.md", line);
}

#[test]
fn setup_guide_limits_say_the_tag_tools_write_footer_text_including_on_daily_notes_and_never_the_persons_text(
) {
    let doc = wi243_desktop_setup();
    let section = wi243_section(&doc, "## Notes / known limits");
    let line = wi243_lines_with(&section, "`tag_note`");
    assert_eq!(
        line.len(),
        1,
        "one statement in 'Notes / known limits' names `tag_note`:\n{section}"
    );
    wi243_assert_footer_write_line("docs/claude-desktop-setup.md", line[0]);
}

#[test]
fn readme_not_yet_list_says_the_tag_tools_write_footer_text_including_on_daily_notes_and_never_the_persons_text(
) {
    let readme = readme();
    let line = wi243_lines_with(&readme, "by design agents only");
    assert_eq!(line.len(), 1, "one 'by design agents only' line: {line:?}");
    wi243_assert_footer_write_line("README.md", line[0]);
}

#[test]
fn readme_and_review_guide_document_memex_tag_ls_tag_filter_and_footer_add_by_note_id() {
    let ls_tag = Regex::new(r"memex ls[^\n]*--tag").unwrap();
    let footer_add = Regex::new(r"memex footer add[^\n]*--note-id").unwrap();
    for (name, doc) in [
        ("README.md", readme()),
        ("docs/daily-review.md", daily_review()),
    ] {
        for sub in ["add", "rm", "ls"] {
            let re = Regex::new(&format!(r"memex tag (?:[a-z]+\|)*{sub}(?:\|[a-z]+)*\b")).unwrap();
            assert!(
                re.is_match(&doc),
                "{name} documents `memex tag {sub}` (alone or as `memex tag add|rm|ls`)"
            );
        }
        assert!(ls_tag.is_match(&doc), "{name} documents `memex ls --tag`");
        assert!(
            footer_add.is_match(&doc),
            "{name} documents `memex footer add --note-id`"
        );
        assert_commands_are_real(name, &doc);
    }
}

// ======================================================================
// WI #257 (Spec #233 R34-R38, R46, D44): Feedback, Corrections and the Vault
// Guide in the README and the docs.
//
// The prose is read by hand; these tests pin the facts that can be checked
// mechanically. Helpers carry a `wi257_` prefix.
// ======================================================================

/// The tool names a doc may name in code formatting for Feedback and the guide.
fn wi257_assert_feedback_tool_names_are_real(what: &str, text: &str) {
    let real = tool_names::all_tool_names();
    let name = Regex::new(r"`([a-z][a-z_]*)`").unwrap();
    let verbs = [
        "resolve_", "record_", "get_", "list_", "update_", "remove_", "tag_", "untag_",
    ];
    for c in name.captures_iter(text) {
        let token = &c[1];
        if verbs.iter().any(|v| token.starts_with(v)) && token.contains('_') {
            assert!(
                real.contains(&token) || ["update_note", "delete_note"].contains(&token),
                "{what} names `{token}`, which the server does not expose: {real:?}"
            );
        }
    }
}

/// Every match of `(?i)vault guide` in prose is spelled `Vault Guide`.
fn wi257_assert_vault_guide_spelling(what: &str, md: &str) {
    let re = Regex::new(r"(?i)\bvault guide\b").unwrap();
    for m in re.find_iter(&prose_only(md)) {
        assert_eq!(m.as_str(), "Vault Guide", "{what} spells the glossary term");
    }
}

#[test]
fn readme_invariant_line_names_the_vault_guide_exception_and_the_three_footer_writers() {
    let readme = readme();
    let lines: Vec<&str> = readme
        .lines()
        .filter(|l| l.contains("`append_to_daily_note`") && l.contains("daily note body"))
        .collect();
    assert_eq!(
        lines.len(),
        1,
        "one README line states the invariant (it names `append_to_daily_note` as the only write \
         into a daily note body): {lines:?}"
    );
    let line = lines[0];
    assert!(line.starts_with("- "), "it stays one bullet line: {line}");
    // The Vault Guide is the one note the agent may rewrite.
    assert!(
        line.contains("Vault Guide") && line.contains("`update_vault_guide`"),
        "the invariant names the Vault Guide and `update_vault_guide`: {line}"
    );
    assert!(
        Regex::new(r"(?i)\b(one|only)\b[^.]{0,40}\bnote\b[^.]{0,60}\b(rewrit\w*|edit\w*)")
            .unwrap()
            .is_match(line),
        "the Vault Guide is the one note the agent may rewrite: {line}"
    );
    // The footer writers, by name, and what they write.
    for tool in ["tag_note", "untag_note", "add_footer_topic"] {
        assert!(
            line.contains(&format!("`{tool}`")),
            "the invariant names `{tool}` as a writer of Note footer text: {line}"
        );
    }
    assert!(
        line.contains("Note footer"),
        "the invariant says Note footer, the glossary term: {line}"
    );
    // The invariant for every other note stays.
    let lower = line.to_lowercase();
    assert!(
        lower.contains("renames") && lower.contains("deletes"),
        "the invariant still says no tool renames or deletes a note: {line}"
    );
}

#[test]
fn readme_by_design_bullet_adds_the_vault_guide_exception_to_the_footer_writers() {
    let readme = readme();
    let line = wi243_lines_with(&readme, "by design agents only");
    assert_eq!(line.len(), 1, "one 'by design agents only' line: {line:?}");
    let line = line[0];
    assert!(
        line.contains("Vault Guide") && line.contains("`update_vault_guide`"),
        "the 'by design' bullet names the Vault Guide exception (`update_vault_guide`): {line}"
    );
    // The #243 statement is kept.
    wi243_assert_footer_write_line("README.md", line);
}

#[test]
fn review_guide_tool_order_starts_with_the_vault_guide_and_open_feedback_and_places_resolve_feedback(
) {
    let doc = daily_review();
    let line = wi243_lines_with(&doc, "in the order a review uses them");
    assert_eq!(line.len(), 1, "one ordered tool list: {line:?}");
    let line = line[0];
    let at = |tool: &str| {
        line.find(&format!("`{tool}`"))
            .unwrap_or_else(|| panic!("`{tool}` missing from the ordered tool list: {line}"))
    };
    assert!(
        at("get_vault_guide") < at("list_open_feedback"),
        "the guide is read first: {line}"
    );
    assert!(
        at("list_open_feedback") < at("list_unreviewed_days"),
        "Feedback is worked before the unreviewed days: {line}"
    );
    assert!(
        at("list_open_feedback") < at("resolve_feedback"),
        "`resolve_feedback` comes after `list_open_feedback`: {line}"
    );
}

#[test]
fn review_guide_agent_limits_name_the_vault_guide_as_the_one_note_the_agent_rewrites() {
    let doc = daily_review();
    let section = wi243_section(&doc, "### What the agent can and cannot do");
    let lines = wi243_lines_with(&section, "`update_vault_guide`");
    assert_eq!(
        lines.len(),
        1,
        "one statement in 'What the agent can and cannot do' names `update_vault_guide`:\n{section}"
    );
    let line = lines[0];
    assert!(line.contains("Vault Guide"), "{line}");
    assert!(
        Regex::new(r"(?i)\b(one|only)\b[^.]{0,40}\bnote\b")
            .unwrap()
            .is_match(line)
            && Regex::new(r"(?i)\brewrit\w*\b").unwrap().is_match(line),
        "it says the Vault Guide is the one note the agent may rewrite: {line}"
    );
    // The other limits stay: no rename, delete or merge of notes.
    assert!(
        section.contains("It cannot rename, delete or merge notes"),
        "the rename/delete/merge limit stays:\n{section}"
    );
}

#[test]
fn review_guide_model_defines_feedback_correction_vault_guide_and_handled_in_glossary_terms() {
    let doc = daily_review();
    let model = wi243_section(&doc, "## 1. The model");
    let bullet = |term: &str| -> String {
        let lines = wi243_lines_with(&model, &format!("- **{term}**"));
        assert_eq!(
            lines.len(),
            1,
            "the model section has one `- **{term}**` bullet:\n{model}"
        );
        lines[0].to_string()
    };
    let feedback = bullet("Feedback");
    assert!(
        feedback.to_lowercase().contains("comment") && feedback.contains("Correction"),
        "Feedback is a written comment or a Correction: {feedback}"
    );
    let correction = bullet("Correction");
    assert!(
        correction.contains("Feedback"),
        "a Correction is recorded as Feedback: {correction}"
    );
    let guide = bullet("Vault Guide");
    let guide_lower = guide.to_lowercase();
    assert!(
        guide_lower.contains("agent")
            && guide_lower.contains("review")
            && guide_lower.contains("capture"),
        "the Vault Guide is read by the agent before every Review and Capture: {guide}"
    );
    assert!(
        model.contains("Handled"),
        "the model section says what Handled means:\n{model}"
    );
    wi257_assert_vault_guide_spelling("docs/daily-review.md", &doc);
    wi257_assert_vault_guide_spelling("README.md", &readme());
    wi257_assert_vault_guide_spelling("docs/daily-acceptance.md", &daily_acceptance());
}

#[test]
fn review_guide_has_an_activity_section_on_comments_corrections_chat_feedback_and_the_vault_guide()
{
    let doc = daily_review();
    let section = hosted_section(&doc, "the Activity tab", r"activity");
    let flat = section.body.clone();
    for term in [
        "Feedback",
        "Correction",
        "Handled",
        "From chat",
        "Vault Guide",
        "Comment",
    ] {
        assert!(
            flat.contains(term),
            "the Activity section uses `{term}`:\n{flat}"
        );
    }
    // How a person writes a comment from the shell.
    assert!(
        flat.contains("memex feedback add"),
        "the Activity section shows `memex feedback add`:\n{flat}"
    );
    assert_commands_are_real("docs/daily-review.md", &doc);
}

#[test]
fn review_guide_prompts_section_describes_the_feedback_pass_and_the_capture_guide_read() {
    let doc = daily_review();
    let prompts = wi243_section(&doc, "## 2. The two prompts");
    let review = wi243_lines_with(&prompts, "**`review_daily_notes`**");
    assert_eq!(review.len(), 1, "one review paragraph: {review:?}");
    let review = review[0];
    for tool in ["get_vault_guide", "list_open_feedback", "resolve_feedback"] {
        assert!(
            review.contains(&format!("`{tool}`")),
            "the review paragraph names `{tool}`: {review}"
        );
    }
    assert!(
        review.contains("Feedback") && review.contains("Vault Guide"),
        "the review paragraph says Feedback and Vault Guide: {review}"
    );
    assert!(
        Regex::new(r"(?i)\beven (when|if)\b")
            .unwrap()
            .is_match(review),
        "the review paragraph says Feedback is worked even when no day is unreviewed: {review}"
    );

    let capture = wi243_lines_with(&prompts, "**`capture`**");
    assert_eq!(capture.len(), 1, "one capture paragraph: {capture:?}");
    let capture = capture[0];
    assert!(
        capture.contains("Vault Guide") && capture.contains("`get_vault_guide`"),
        "the capture paragraph says it reads the Vault Guide: {capture}"
    );
    assert!(
        Regex::new(r"(?i)\b(never|does not|do not)\b[^.]{0,40}\bwrit\w*\b")
            .unwrap()
            .is_match(capture),
        "the capture paragraph says capture does not write the guide: {capture}"
    );
    wi257_assert_feedback_tool_names_are_real("docs/daily-review.md", &doc);
}

/// `(number, heading, body)` of each numbered `## N. ` section; the body runs to
/// the next `## ` heading, so `## Clean up` ends the last one.
fn wi257_numbered_sections(doc: &str) -> Vec<(u32, String, String)> {
    let heading = Regex::new(r"^## (\d+)\. (.+)$").unwrap();
    let mut out: Vec<(u32, String, String)> = Vec::new();
    let mut inside = false;
    for line in doc.lines() {
        if let Some(c) = heading.captures(line) {
            out.push((c[1].parse().unwrap(), c[2].to_string(), String::new()));
            inside = true;
        } else if line.starts_with("## ") {
            inside = false;
        } else if inside {
            let body = &mut out.last_mut().unwrap().2;
            body.push_str(line);
            body.push('\n');
        }
    }
    out
}

#[test]
fn daily_acceptance_script_has_a_section_for_each_manual_feedback_journey_before_clean_up() {
    let doc = daily_acceptance();
    let sections = wi257_numbered_sections(&doc);
    let numbers: Vec<u32> = sections.iter().map(|(n, _, _)| *n).collect();
    assert_eq!(
        numbers,
        (1..=numbers.len() as u32).collect::<Vec<_>>(),
        "sections are numbered 1..n in order"
    );
    assert!(
        numbers.len() >= 11,
        "sections 1-8 stay and three new ones follow (one per manual journey): {numbers:?}"
    );
    let clean_up = doc
        .find("## Clean up")
        .expect("the script keeps `## Clean up`");
    let last_numbered = doc
        .rfind(&format!("## {}. ", numbers.len()))
        .expect("the last numbered heading");
    assert!(
        last_numbered < clean_up,
        "every numbered section comes before `## Clean up`"
    );

    // The three MANUAL ACs, each in a section of its own.
    let new: Vec<&(u32, String, String)> = sections.iter().filter(|(n, _, _)| *n >= 9).collect();
    let fixes_feedback = |s: &str| {
        s.contains("Feedback")
            && s.contains("Correction")
            && s.contains("Vault Guide")
            && s.contains("Handled")
            && s.contains("`resolve_feedback`")
            && Regex::new(r"memex (feedback add|excerpt (move|remove-block))")
                .unwrap()
                .is_match(s)
    };
    let fixes_on_the_spot = |s: &str| {
        s.contains("`record_feedback`")
            && s.contains("From chat")
            && s.contains("Activity")
            && s.contains("/mcp__memex__review_daily_notes")
    };
    let does_not_redo = |s: &str| {
        s.contains("Correction")
            && s.contains("review_daily_notes")
            && Regex::new(r"(?i)\b(redo|redone|re-?fil\w*|re-?add\w*)\b")
                .unwrap()
                .is_match(s)
    };
    let mut found = false;
    for a in &new {
        for b in &new {
            for c in &new {
                if a.0 != b.0
                    && a.0 != c.0
                    && b.0 != c.0
                    && fixes_feedback(&a.2)
                    && fixes_on_the_spot(&b.2)
                    && does_not_redo(&c.2)
                {
                    found = true;
                }
            }
        }
    }
    assert!(
        found,
        "three different new sections: (1) open Feedback and a Correction are fixed, replied to \
         (Handled) and the Vault Guide updated, seeded with `memex feedback add` or `memex excerpt \
         move`/`remove-block`; (2) a comment in a live Review session is recorded with \
         `record_feedback` and shows `From chat` in Activity; (3) a later `review_daily_notes` run \
         does not redo a Correction. Sections: {:?}",
        new.iter()
            .map(|(n, h, _)| format!("{n}. {h}"))
            .collect::<Vec<_>>()
    );

    // Real tool names only, like the rest of the script.
    for (_, _, body) in &new {
        wi257_assert_feedback_tool_names_are_real("docs/daily-acceptance.md", body);
    }
}

// ---- WI 257 verify: doc claims the implementer's handoff listed as unpinned ----

#[test]
fn review_guide_activity_section_says_what_handled_shows_what_restore_does_and_that_deleted_open_feedback_is_skipped(
) {
    let doc = daily_review();
    let section = hosted_section(&doc, "the Activity tab", r"activity");
    let body = section.body.clone();
    // Open Feedback reads `Open`, then `Handled` with the agent's one-line reply.
    assert!(
        Regex::new(r"(?is)reads `Open`.{0,120}`Handled`.{0,60}\bone-line reply\b")
            .unwrap()
            .is_match(&body),
        "Open becomes Handled with the agent's one-line reply:\n{body}"
    );
    assert!(
        Regex::new(r"(?is)reply,? which never quotes your text")
            .unwrap()
            .is_match(&body),
        "the reply never quotes the person's text:\n{body}"
    );
    // Deleting open Feedback before the agent reaches it is safe.
    assert!(
        Regex::new(r"(?is)\bdelete open Feedback\b.{0,80}\bcarries on without it\b")
            .unwrap()
            .is_match(&body),
        "deleted open Feedback is skipped:\n{body}"
    );
    // The guide's own Activity tab, with Restore and the three guide commands.
    assert!(
        Regex::new(r"(?is)`Restore`.{0,80}\bearlier text\b")
            .unwrap()
            .is_match(&body),
        "`Restore` returns to the earlier text:\n{body}"
    );
    for cmd in [
        "memex guide get",
        "memex guide revisions",
        "memex guide restore",
    ] {
        assert!(
            body.contains(cmd),
            "the Activity section shows `{cmd}`:\n{body}"
        );
    }
    // Corrections: the things a person can undo, and where each one shows (R3, R23).
    for what in [
        "moving a block to another topic note",
        "`File in…`",
        "a tag Review applied",
        "a Smart Folder the agent placed it in",
        "a Smart Folder the agent created",
        "the day's daily note",
    ] {
        assert!(
            body.contains(what),
            "a Correction is recorded when you {what}:\n{body}"
        );
    }
    assert_commands_are_real("docs/daily-review.md", &doc);
}

#[test]
fn review_guide_no_shell_access_list_names_the_new_write_subcommands() {
    let doc = daily_review();
    let line = wi243_lines_with(&doc, "do not give an agent shell access");
    assert_eq!(line.len(), 1, "one no-shell-access paragraph: {line:?}");
    for sub in [
        "`excerpt move`",
        "`excerpt remove-block`",
        "`feedback add`",
        "`guide restore`",
    ] {
        assert!(
            line[0].contains(sub),
            "the no-shell-access list names {sub}: {}",
            line[0]
        );
    }
}

#[test]
fn review_guide_prompts_section_says_the_review_never_redoes_a_correction_and_capture_never_writes_the_guide(
) {
    let doc = daily_review();
    let prompts = wi243_section(&doc, "## 2. The two prompts");
    assert!(
        Regex::new(r"(?is)never redoes a Correction")
            .unwrap()
            .is_match(&prompts),
        "the Review paragraph says the agent never redoes a Correction:\n{prompts}"
    );
    assert!(
        Regex::new(r"(?is)\bit never writes the guide\b")
            .unwrap()
            .is_match(&prompts),
        "the Capture paragraph says it never writes the guide:\n{prompts}"
    );
    assert!(
        Regex::new(r"(?is)\bcomment from you about filing is Feedback\b.{0,200}`record_feedback`")
            .unwrap()
            .is_match(&prompts),
        "a comment about filing in a live session is Feedback, recorded with `record_feedback`:\n{prompts}"
    );
}

#[test]
fn daily_acceptance_feedback_sections_each_have_an_expected_line_and_state_what_must_not_happen() {
    let doc = daily_acceptance();
    let sections = wi257_numbered_sections(&doc);
    for n in [9u32, 10, 11] {
        let (_, heading, body) = sections
            .iter()
            .find(|(k, _, _)| *k == n)
            .unwrap_or_else(|| panic!("acceptance section {n} exists"));
        assert!(
            body.contains("**Expected**"),
            "section {n} ({heading}) has an **Expected** line:\n{body}"
        );
    }
    let body = |n: u32| {
        sections
            .iter()
            .find(|(k, _, _)| *k == n)
            .map(|(_, _, b)| b.clone())
            .unwrap()
    };
    // 9: oldest first, no sweep of older days, reply never quotes, Correction not undone.
    let nine = body(9);
    for phrase in [
        "oldest first",
        "does not sweep older days",
        "never quotes your text",
        "the Correction is not undone",
        "`update_vault_guide`",
    ] {
        assert!(
            nine.contains(phrase),
            "section 9 expects `{phrase}`:\n{nine}"
        );
    }
    // 10: the fix, the verbatim record, the `From chat` row already Handled, never open.
    let ten = body(10);
    for phrase in [
        "fixes the filing on the spot",
        "as you typed them",
        "`From chat`",
        "never shows as open",
    ] {
        assert!(
            ten.contains(phrase),
            "section 10 expects `{phrase}`:\n{ten}"
        );
    }
    // 11: no re-file into the topic note, no re-add to the Smart Folder, then a real change is judged.
    let eleven = body(11);
    for phrase in [
        "does not re-file the block into the topic note",
        "does not re-add a topic note to a Smart Folder",
        "the block is not back in that topic note",
        "the earlier Correction still shows in Activity",
    ] {
        assert!(
            eleven.contains(phrase),
            "section 11 expects `{phrase}`:\n{eleven}"
        );
    }
}

// ======================================================================
// WI #328 (Spec #315 req 18, 36, 38, 38a; architecture D25): the backup
// docs. `docs/backups.md` (new), the README's commands and upgrade steps,
// the link from `docs/hosted-vault.md` and the GLOSSARY.md Backups section.
//
// Facts that the shipped code decides are read off the code: the error codes
// off `MemexError`, the server's HTTP statuses off `status_for_code`, the
// JSON keys off a real `memex backup` and `memex restore`, every flag off
// `memex <command> --help`. The prose itself is reviewed by hand.
// ======================================================================

const BACKUPS_DOC: &str = "docs/backups.md";

fn wi328_doc() -> String {
    read_repo_file(BACKUPS_DOC)
}

/// The logical paragraphs and list items (soft-wrapped lines joined) outside
/// fenced blocks, lower-cased with whitespace collapsed.
fn wi328_items(md: &str) -> Vec<String> {
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
            || trimmed.starts_with('|')
            || trimmed.starts_with('#')
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
    items
        .into_iter()
        .map(|i| hosted_flat_lower(&i))
        .filter(|i| !i.is_empty())
        .collect()
}

/// Some paragraph or list item holds every needle.
fn wi328_assert_item_with_all(what: &str, md: &str, needles: &[&str]) {
    let items = wi328_items(md);
    assert!(
        items
            .iter()
            .any(|i| needles.iter().all(|n| i.contains(&n.to_lowercase()))),
        "{what}: no single paragraph or list item mentions all of {needles:?}"
    );
}

/// Some paragraph or list item holds every needle and at least one of
/// `any_of`.
fn wi328_assert_item_with(what: &str, md: &str, needles: &[&str], any_of: &[&str]) {
    let items = wi328_items(md);
    assert!(
        items.iter().any(|i| {
            needles.iter().all(|n| i.contains(&n.to_lowercase()))
                && any_of.iter().any(|a| i.contains(&a.to_lowercase()))
        }),
        "{what}: no single paragraph or list item mentions all of {needles:?} and one of {any_of:?}"
    );
}

/// Code (fenced blocks and inline spans) with backslash line continuations
/// joined.
fn wi328_code_text(md: &str) -> String {
    let joined = code_snippets(md).join("\n");
    Regex::new(r"\\[ \t]*\n[ \t]*")
        .unwrap()
        .replace_all(&joined, " ")
        .to_string()
}

fn wi328_flags_in(text: &str) -> BTreeSet<String> {
    Regex::new(r"--[a-z][a-z-]*")
        .unwrap()
        .find_iter(text)
        .map(|m| m.as_str().to_string())
        .collect()
}

type Wi328Flags = std::collections::BTreeMap<String, BTreeSet<String>>;

/// The `--flag`s each `memex <sub>` command shows in the code of `md`
/// (`backup`, `restore`, `serve`), each checked against `memex <sub> --help`.
fn wi328_flags_shown(doc_name: &str, md: &str) -> Wi328Flags {
    let code = wi328_code_text(md);
    let mut seen = Wi328Flags::new();
    for sub in ["backup", "restore", "serve"] {
        let out = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args([sub, "--help"])
            .output()
            .expect("run memex --help");
        assert!(out.status.success(), "memex {sub} --help failed");
        let help_flags = wi328_flags_in(&String::from_utf8_lossy(&out.stdout));
        let line = Regex::new(&format!(r"\bmemex {sub}\b([^\n|;&`]*)")).unwrap();
        let mut flags = BTreeSet::new();
        for c in line.captures_iter(&code) {
            for flag in wi328_flags_in(&c[1]) {
                assert!(
                    help_flags.contains(&flag),
                    "{doc_name} shows `memex {sub} … {flag}`, which memex {sub} --help does not list: {help_flags:?}"
                );
                flags.insert(flag);
            }
        }
        seen.insert(sub.to_string(), flags);
    }
    seen
}

fn wi328_assert_flags(doc_name: &str, seen: &Wi328Flags, sub: &str, required: &[&str]) {
    let shown = &seen[sub];
    for flag in required {
        assert!(
            shown.contains(*flag),
            "{doc_name} shows `memex {sub}` with {flag} (flags shown: {shown:?})"
        );
    }
}

/// Runs the real binary; returns (success, stdout, stderr).
fn wi328_run(args: &[&std::ffi::OsStr]) -> (bool, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .output()
        .expect("run memex");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).to_string(),
        String::from_utf8_lossy(&out.stderr).to_string(),
    )
}

/// `(a real backup's JSON, an --if-changed repeat's JSON, a restore's JSON)`.
fn wi328_real_json() -> (Value, Value, Value) {
    use std::ffi::OsStr;
    let scratch = tempfile::tempdir().unwrap();
    let vault = scratch.path().join("vault");
    let dest = scratch.path().join("dest");
    let restored = scratch.path().join("restored");
    Vault::create(&vault).unwrap();
    std::fs::create_dir(&dest).unwrap();
    let backup = |extra: &[&str]| -> Value {
        let mut args: Vec<&OsStr> = vec![
            OsStr::new("backup"),
            OsStr::new("--vault"),
            vault.as_os_str(),
            OsStr::new("--dest"),
            dest.as_os_str(),
        ];
        args.extend(extra.iter().map(OsStr::new));
        let (ok, stdout, stderr) = wi328_run(&args);
        assert!(ok, "memex backup failed: {stderr}");
        serde_json::from_str(stdout.trim()).expect("one JSON line")
    };
    let created = backup(&[]);
    let unchanged = backup(&["--if-changed"]);
    let file = created["file"].as_str().expect("file").to_string();
    let (ok, stdout, stderr) = wi328_run(&[
        OsStr::new("restore"),
        OsStr::new("--from"),
        OsStr::new(&file),
        OsStr::new("--to"),
        restored.as_os_str(),
    ]);
    assert!(ok, "memex restore failed: {stderr}");
    let restore = serde_json::from_str(stdout.trim()).expect("one JSON line");
    (created, unchanged, restore)
}

// ---------- docs/backups.md exists and says what a backup holds ----------

#[test]
fn backups_doc_has_a_title_and_says_what_a_backup_contains_and_leaves_out() {
    let doc = wi328_doc();
    let title = doc
        .lines()
        .find(|l| l.starts_with("# "))
        .expect("docs/backups.md has a level 1 title");
    assert!(title.to_lowercase().contains("backup"), "{title}");
    hosted_assert_mentions(
        BACKUPS_DOC,
        &doc,
        &[".memex.zip", "memex.db", "manifest.json", "objects/"],
    );
    let left_out = [
        "leave",
        "not include",
        "exclude",
        "without",
        "skip",
        "not in",
        "not contain",
    ];
    wi328_assert_item_with(
        "what a backup leaves out (the vault's .memex/ folder)",
        &doc,
        &[".memex/"],
        &left_out,
    );
    wi328_assert_item_with(
        "what a backup leaves out (backup-state.json)",
        &doc,
        &["backup-state.json"],
        &left_out,
    );
    // The UI state and logs live in `.memex/`.
    wi328_assert_item_with(
        "why .memex/ is left out",
        &doc,
        &[".memex/"],
        &["log", "ui state"],
    );
}

// ---------- choosing a destination: iCloud Drive, Google Drive, OneDrive ----------

#[test]
fn backups_doc_covers_choosing_icloud_google_drive_onedrive_or_any_folder() {
    let doc = wi328_doc();
    hosted_assert_mentions(
        BACKUPS_DOC,
        &doc,
        &[
            "iCloud Drive",
            "Google Drive",
            "OneDrive",
            "any folder",
            "Open Memex Backups",
        ],
    );
    // "The provider's app uploads it": the client must be installed and signed in.
    wi328_assert_item_with_all(
        "the provider's app uploads the backup",
        &doc,
        &["uploads", "app"],
    );
    wi328_assert_item_with_all(
        "the provider's app must be installed and signed in",
        &doc,
        &["installed", "signed in"],
    );
    // iCloud's "Optimise Mac Storage" may keep only a placeholder locally.
    let spelled = doc.to_lowercase().replace("optimize mac", "optimise mac");
    wi328_assert_item_with_all(
        "Optimise Mac Storage may leave only a placeholder",
        &spelled,
        &["optimise mac storage", "placeholder"],
    );
    // The app's entry points.
    hosted_assert_mentions(
        BACKUPS_DOC,
        &doc,
        &["sidebar", "turn on backups", "back up now"],
    );
}

#[test]
fn backups_doc_explains_the_macos_files_and_folders_prompt_and_allowing_after_a_refusal() {
    let doc = wi328_doc();
    hosted_assert_mentions(
        BACKUPS_DOC,
        &doc,
        &["Files and Folders", "Privacy & Security", "System Settings"],
    );
    wi328_assert_item_with(
        "the Files and Folders prompt and allowing",
        &doc,
        &["files and folders"],
        &["allow", "turn on", "enable"],
    );
    wi328_assert_item_with(
        "allowing Open Memex after a refusal",
        &doc,
        &["system settings", "open memex"],
        &["refus", "denied", "declin", "don't allow", "said no"],
    );
}

#[test]
fn backups_doc_says_never_to_put_a_live_vault_in_a_provider_folder() {
    let doc = wi328_doc();
    wi328_assert_item_with(
        "a live vault never goes in a provider folder",
        &doc,
        &["live vault"],
        &["never", "do not", "don't"],
    );
    wi328_assert_item_with_all(
        "the live vault warning names the providers",
        &doc,
        &["live vault", "icloud drive", "google drive", "onedrive"],
    );
}

// ---------- memex backup, its flags and JSON, and the launchd example ----------

#[test]
fn backups_doc_shows_only_real_commands_and_flags_for_backup_restore_and_serve() {
    let doc = wi328_doc();
    assert_commands_are_real(BACKUPS_DOC, &doc);
    let seen = wi328_flags_shown(BACKUPS_DOC, &doc);
    wi328_assert_flags(
        BACKUPS_DOC,
        &seen,
        "backup",
        &["--vault", "--dest", "--keep", "--if-changed"],
    );
    wi328_assert_flags(BACKUPS_DOC, &seen, "restore", &["--from", "--to"]);
    wi328_assert_flags(
        BACKUPS_DOC,
        &seen,
        "serve",
        &["--root", "--listen", "--backup-dir", "--backup-keep"],
    );
}

#[test]
fn backups_doc_states_the_keep_default_and_range_the_binary_enforces() {
    let doc = wi328_doc();
    let default = memex_core::backup::KEEP_DEFAULT.to_string();
    let max = memex_core::backup::KEEP_MAX.to_string();
    wi328_assert_item_with_all(
        "--keep: default and range",
        &doc,
        &["--keep", &default, &max],
    );
    wi328_assert_item_with_all(
        "--backup-keep: default and range",
        &doc,
        &["--backup-keep", &default, &max],
    );
}

#[test]
fn backups_doc_lists_every_key_memex_backup_and_memex_restore_print() {
    let doc = wi328_doc();
    let (created, unchanged, restore) = wi328_real_json();
    assert_eq!(created["result"], "created");
    assert_eq!(unchanged["result"], "unchanged");
    let mentions =
        |key: &str| doc.contains(&format!("\"{key}\"")) || doc.contains(&format!("`{key}`"));
    for (what, json) in [
        ("memex backup (created)", &created),
        ("memex backup --if-changed (unchanged)", &unchanged),
        ("memex restore", &restore),
    ] {
        for key in json.as_object().expect("a JSON object").keys() {
            assert!(
                mentions(key),
                "{BACKUPS_DOC} documents the `{key}` key of {what}"
            );
        }
    }
    for result in ["created", "unchanged"] {
        assert!(
            mentions(result),
            "{BACKUPS_DOC} documents the `{result}` result"
        );
    }
}

#[test]
fn backups_doc_has_a_launchd_example_that_runs_memex_backup_on_a_schedule() {
    let doc = wi328_doc();
    let plist = hosted_fenced_blocks(&doc)
        .into_iter()
        .map(|(_, body)| body)
        .find(|body| body.contains("<key>ProgramArguments</key>"))
        .expect("a launchd property list with ProgramArguments");
    for needle in [
        "<key>Label</key>",
        "<string>backup</string>",
        "<string>--vault</string>",
        "<string>--dest</string>",
    ] {
        assert!(
            plist.contains(needle),
            "the launchd example has {needle}:\n{plist}"
        );
    }
    assert!(
        plist.contains("<key>StartCalendarInterval</key>")
            || plist.contains("<key>StartInterval</key>"),
        "the launchd example runs on a schedule:\n{plist}"
    );
    hosted_assert_mentions(BACKUPS_DOC, &doc, &["launchctl", "LaunchAgents"]);
    // It is for a Mac where the app is not always running.
    wi328_assert_item_with(
        "when the launchd example is for",
        &doc,
        &["launchd"],
        &[
            "not always",
            "isn't always",
            "is not open",
            "isn't open",
            "not running",
        ],
    );
}

// ---------- the vault server: --backup-dir / --backup-keep ----------

#[test]
fn backups_doc_covers_the_vault_server_backup_dir_a_nas_docker_and_cloud_tools() {
    let doc = wi328_doc();
    hosted_assert_mentions(
        BACKUPS_DOC,
        &doc,
        &[
            "--backup-dir",
            "--backup-keep",
            "<root>/.backups",
            "vault server",
            "Docker",
            "Synology Cloud Sync",
            "Synology Hyper Backup",
            "QNAP HBS 3",
        ],
    );
    // The Docker route: the same volume mount pattern as docs/hosted-vault.md.
    let docker = hosted_fenced_blocks(&doc)
        .into_iter()
        .map(|(_, body)| body)
        .find(|body| body.contains("docker run") && body.contains("--backup-dir"))
        .expect("a `docker run` example that passes --backup-dir");
    assert!(
        docker.contains("-v "),
        "the Docker example mounts a volume:\n{docker}"
    );
    // `--backup-dir` needs `--root`.
    wi328_assert_item_with_all(
        "--backup-dir needs --root",
        &doc,
        &["--backup-dir", "--root"],
    );
}

#[test]
fn backups_doc_says_what_a_vault_server_backs_up_and_when() {
    let doc = wi328_doc();
    wi328_assert_item_with(
        "the server backs up every vault it serves",
        &doc,
        &["--backup-dir"],
        &[
            "every vault",
            "each vault",
            "all vaults",
            "every served vault",
        ],
    );
    wi328_assert_item_with(
        "how often the server backs up",
        &doc,
        &["vault server"],
        &[
            "once a day",
            "daily",
            "every day",
            "24 hours",
            "hourly",
            "every hour",
        ],
    );
}

// ---------- restore ----------

#[test]
fn backups_doc_covers_restore_with_the_cli_the_app_and_a_vault_server() {
    let doc = wi328_doc();
    hosted_assert_mentions(
        BACKUPS_DOC,
        &doc,
        &[
            "memex restore",
            "--from",
            "--to",
            "Restore from backup",
            ".incoming",
            "hosted-vault.md",
        ],
    );
    // Onto a vault server: restore anywhere, then copy in through `.incoming`.
    wi328_assert_item_with_all(
        "restoring onto a vault server goes through <root>/.incoming/",
        &doc,
        &["restore", ".incoming", "vault server"],
    );
    // The new folder must not exist or be empty (restore_target_not_empty).
    wi328_assert_item_with(
        "memex restore --to must be absent or empty",
        &doc,
        &["--to"],
        &["empty", "does not exist", "doesn't exist", "must not exist"],
    );
}

#[test]
fn backups_doc_says_a_restored_copy_shares_keep_last_n_with_its_original() {
    let doc = wi328_doc();
    // L8: a restored vault keeps its vault id, so two vaults that back up into
    // one folder count against the same keep-last-N.
    wi328_assert_item_with_all(
        "a restored copy shares keep-last-N with its original in one folder",
        &doc,
        &["restored", "original", "keep", "folder"],
    );
    wi328_assert_item_with(
        "why: the restored vault keeps its vault id",
        &doc,
        &["restored", "original"],
        &["vault id", "vault_id", "same id"],
    );
}

// ---------- the vault server's status, cadence and file names ----------

#[path = "support/server.rs"]
mod wi328_server;

/// `GET …/backup` bodies of a real in-process vault server: `(without
/// --backup-dir, with it, the POST status without it)`.
fn wi328_server_status() -> (Value, Value, u16) {
    use memex_mcp::server::backup::BackupConfig;
    use memex_mcp::server::{router, ServerConfig};
    use wi328_server as server;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async {
        let scratch = tempfile::tempdir().unwrap();
        let root = scratch.path().join("root");
        let dir = scratch.path().join("backups");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(&dir).unwrap();
        server::make_vault(&root, "notes");
        let bearer = format!("Bearer {}", server::TEST_TOKEN);
        let path = "/vaults/notes/api/v1/backup";
        let mut bodies = Vec::new();
        let mut post_status = 0;
        for configured in [false, true] {
            let mut config = ServerConfig::new(root.clone(), server::TEST_TOKEN);
            if configured {
                config = config.with_backups(BackupConfig {
                    dir: dir.clone(),
                    keep: 30,
                });
            }
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let app = router(config);
            let task = tokio::spawn(async move {
                axum::serve(listener, app).await.expect("serve");
            });
            let get = server::client()
                .get(format!("http://{addr}{path}"))
                .header("authorization", &bearer)
                .send()
                .await
                .expect("GET backup");
            let reply = server::Reply::read(get).await;
            assert_eq!(reply.status, 200, "GET {path}: {}", reply.body);
            bodies.push(reply.json());
            if !configured {
                let post = server::client()
                    .post(format!("http://{addr}{path}"))
                    .header("authorization", &bearer)
                    .send()
                    .await
                    .expect("POST backup");
                post_status = server::Reply::read(post).await.status;
            }
            task.abort();
        }
        let configured = bodies.pop().unwrap();
        let disabled = bodies.pop().unwrap();
        (disabled, configured, post_status)
    })
}

#[test]
fn backups_doc_lists_every_key_of_the_vault_server_status_and_its_real_path() {
    let doc = wi328_doc();
    let (disabled, configured, post_status) = wi328_server_status();
    let keys_of =
        |v: &Value| -> BTreeSet<String> { v.as_object().unwrap().keys().cloned().collect() };
    assert_eq!(
        keys_of(&disabled),
        keys_of(&configured),
        "the status has the same keys with and without --backup-dir"
    );
    assert_eq!(disabled["enabled"], json!(false));
    assert_eq!(configured["enabled"], json!(true));
    assert_eq!(configured["keep"], json!(30));
    let keys = keys_of(&configured);
    assert_eq!(keys.len(), 10, "{keys:?}");
    // The one paragraph that describes the status names the real path (the
    // server answered 200 to GET there above) and every key, each as a code
    // span.
    let mut needles: Vec<String> = keys.iter().map(|k| format!("`{k}`")).collect();
    needles.push("/vaults/<name>/api/v1/backup".to_string());
    needles.push("post".to_string());
    let refs: Vec<&str> = needles.iter().map(String::as_str).collect();
    wi328_assert_item_with_all("the vault server status keys and path", &doc, &refs);
    // A POST to a server without --backup-dir is the 409 the table lists.
    assert_eq!(post_status, 409, "POST without --backup-dir");
}

#[test]
fn backups_doc_states_the_vault_servers_hourly_check_and_once_a_day_cadence_the_code_has() {
    let doc = wi328_doc();
    // Once a day: a backup is due 24 hours after the last success.
    assert_eq!(memex_core::backup::DUE_AFTER_MS, 24 * 60 * 60 * 1000);
    wi328_assert_item_with(
        "a vault server backs up a vault once a day",
        &doc,
        &["vault server", "once a day"],
        &["changed", "edits"],
    );
    // Hourly: the check interval is a private constant of the server, so it
    // is read off the source text (its behaviour is tested in
    // server_backup.rs).
    let source = include_str!("../src/server/mod.rs");
    let every =
        Regex::new(r"const BACKUP_CHECK_EVERY: [^=]*=\s*[\w:]*Duration::from_secs\(([\d\s*]+)\)")
            .unwrap()
            .captures(source)
            .expect("src/server/mod.rs defines BACKUP_CHECK_EVERY");
    let seconds: u64 = every[1]
        .split('*')
        .map(|n| n.trim().parse::<u64>().unwrap())
        .product();
    assert_eq!(seconds, 60 * 60, "the vault server checks every hour");
    wi328_assert_item_with(
        "a vault server checks when it starts and then every hour",
        &doc,
        &["vault server", "every hour", "starts"],
        &["checks"],
    );
    wi328_assert_item_with(
        "a vault copied in later is picked up by the next hourly check",
        &doc,
        &["hourly check"],
        &["copied into the root"],
    );
}

#[test]
fn backups_doc_file_name_pattern_and_partial_name_are_the_ones_the_code_writes() {
    use memex_core::backup::names;
    let doc = wi328_doc();
    // A real name, built by the code.
    let at_ms = 1_794_232_980_000_i64;
    let vault_id = "01J8Z6K3Q4W9X2V5B7N1M0C8DA";
    let name = names::file_name("Notes", at_ms, vault_id);
    assert_eq!(
        name,
        "Notes-20261109T140300Z-01J8Z6K3Q4W9X2V5B7N1M0C8DA.memex.zip"
    );
    let parsed = names::parse_file_name(&name).expect("a real name parses");
    assert_eq!(
        (parsed.label.as_str(), parsed.vault_id.as_str()),
        ("Notes", vault_id)
    );
    // The doc's pattern and its example are that shape.
    assert!(
        doc.contains("`<label>-<YYYYMMDDTHHMMSSZ>-<vault_id>.memex.zip`"),
        "the doc gives the file name pattern"
    );
    assert!(doc.contains(&name), "the doc's example is {name}");
    // The partial name is a dot, the final name, then `.partial`.
    assert_eq!(names::partial_name(&name), format!(".{name}.partial"));
    assert!(
        doc.contains("`.<name>.partial`"),
        "the doc names the partial file `.<name>.partial`"
    );
    wi328_assert_item_with(
        "a half-written backup never has a real name",
        &doc,
        &["hidden name", "renamed"],
        &["complete"],
    );
    // The restore example's created_at is the example file's timestamp.
    let at = chrono::DateTime::from_timestamp_millis(at_ms).unwrap();
    assert_eq!(at.format("%Y%m%dT%H%M%SZ").to_string(), parsed.timestamp);
    assert!(
        doc.contains(&format!("\"created_at\":{at_ms}")),
        "the restore JSON example has created_at {at_ms}, the time in the example file name"
    );
}

// ---------- the error codes table ----------

fn wi328_error_codes() -> Vec<String> {
    use memex_core::MemexError as E;
    let s = || String::from("x");
    let mut codes: Vec<String> = [
        E::BackupDestinationUnavailable(s()),
        E::BackupDestinationInsideVault(s()),
        E::BackupInProgress(s()),
        E::BackupFailed(s()),
        E::BackupInvalid(s()),
        E::BackupTooNew {
            backup: 7,
            supported: 6,
        },
        E::RestoreTargetNotEmpty(s()),
    ]
    .iter()
    .map(|e| e.code().to_string())
    .collect();
    codes.push("backups_not_configured".to_string());
    codes
}

/// The cells of the table row (under "Error codes") that names `code`.
fn wi328_error_row(table: &str, code: &str) -> Vec<String> {
    let line = table
        .lines()
        .find(|l| l.trim_start().starts_with('|') && l.contains(&format!("`{code}`")))
        .unwrap_or_else(|| panic!("the Error codes table has a row for `{code}`"));
    line.trim()
        .trim_matches('|')
        .split('|')
        .map(|c| c.trim().to_string())
        .collect()
}

#[test]
fn backups_doc_error_codes_table_has_all_eight_codes_with_a_meaning_each() {
    let doc = wi328_doc();
    let section = hosted_section(&doc, "the Error codes table", r"error codes");
    let codes = wi328_error_codes();
    assert_eq!(codes.len(), 8, "{codes:?}");
    for code in &codes {
        let cells = wi328_error_row(&section.body, code);
        assert!(
            cells.len() >= 3,
            "the `{code}` row has a code, an HTTP status and a meaning: {cells:?}"
        );
        let meaning = cells.last().unwrap();
        assert!(
            meaning.chars().count() >= 20,
            "the `{code}` row says what it means and when it happens: {meaning:?}"
        );
        assert_eq!(
            section.body.matches(&format!("`{code}`")).count(),
            1,
            "`{code}` has exactly one row in the table"
        );
    }
}

#[test]
fn backups_doc_error_codes_table_gives_the_http_status_where_the_server_sends_one() {
    let doc = wi328_doc();
    let section = hosted_section(&doc, "the Error codes table", r"error codes");
    for code in wi328_error_codes() {
        let cells = wi328_error_row(&section.body, &code);
        let status_cell = cells[1].as_str();
        let server_status = memex_mcp::server::error::status_for_code(&code).as_u16();
        if code == "backup_in_progress" || code == "backups_not_configured" {
            // The only two codes a vault server answers a request with.
            assert_eq!(server_status, 409, "{code}");
            assert_eq!(status_cell, "409", "the `{code}` row says 409: {cells:?}");
        } else {
            // A POST answers at once, so a failed automatic backup is never an
            // HTTP status: the cell says `none`, not a number.
            assert_eq!(
                status_cell, "none",
                "the `{code}` row says `none` for the HTTP status: {cells:?}"
            );
        }
    }
}

#[test]
fn backups_doc_error_codes_table_says_what_each_code_means_in_its_own_row() {
    let doc = wi328_doc();
    let section = hosted_section(&doc, "the Error codes table", r"error codes");
    // Every one of these phrases must be in that code's own meaning cell, so
    // two meanings swapped between rows fail.
    let expected: [(&str, &[&str]); 8] = [
        (
            "backup_destination_unavailable",
            &["is missing", "not a folder", "macos refused"],
        ),
        (
            "backup_destination_inside_vault",
            &["the vault folder", "inside it", "outside the vault"],
        ),
        (
            "backup_in_progress",
            &["already running", "second back up now"],
        ),
        (
            "backup_failed",
            &["part way", "integrity check", "no backup file is left"],
        ),
        ("backup_invalid", &["not a zip", "damaged parts"]),
        ("backup_too_new", &["newer schema", "update memex"]),
        (
            "restore_target_not_empty",
            &["`--to`", "not empty", "empty one"],
        ),
        (
            "backups_not_configured",
            &["only a vault server", "without `--backup-dir`", "restart"],
        ),
    ];
    let codes = wi328_error_codes();
    assert_eq!(expected.len(), codes.len());
    for (code, phrases) in expected {
        assert!(codes.iter().any(|c| c == code), "{code} is a real code");
        let meaning = wi328_error_row(&section.body, code)[2].to_lowercase();
        for phrase in phrases {
            assert!(
                meaning.contains(phrase),
                "the `{code}` meaning says `{phrase}`: {meaning}"
            );
        }
    }
}

#[test]
fn backups_doc_error_codes_intro_names_the_codes_other_failures_carry() {
    use memex_core::MemexError as E;
    let doc = wi328_doc();
    let section = hosted_section(&doc, "the Error codes table", r"error codes");
    let intro = hosted_flat_lower(section.body.split("\n|").next().unwrap());
    // The two other codes the text names are real `memex` codes.
    assert_eq!(
        E::NetworkFilesystem("x".into()).code(),
        "network_filesystem"
    );
    assert_eq!(E::Io(std::io::Error::other("x")).code(), "internal");
    for code in ["network_filesystem", "internal"] {
        assert!(
            intro.contains(&format!("`{code}`")),
            "the intro names `{code}`: {intro}"
        );
    }
    // It must not claim that the eight codes are the only ones.
    assert!(
        !intro.contains("every failure"),
        "the intro does not say every failure carries one of the eight: {intro}"
    );
    assert!(
        intro.contains("specific to backups and restores"),
        "the eight are the backup and restore specific failures: {intro}"
    );
    assert!(
        intro.contains("any code not listed here"),
        "scripts are told to treat an unlisted code as a failure: {intro}"
    );
}

#[test]
fn backups_doc_other_codes_are_what_the_binary_prints_for_a_missing_vault_or_backup_file() {
    use std::ffi::OsStr;
    let scratch = tempfile::tempdir().unwrap();
    let dest = scratch.path().join("dest");
    std::fs::create_dir(&dest).unwrap();
    let missing = scratch.path().join("missing");
    let code_of = |stderr: &str| -> String {
        let line = stderr.lines().last().unwrap_or("");
        let v: Value = serde_json::from_str(line)
            .unwrap_or_else(|e| panic!("one line of JSON on stderr ({e}): {stderr:?}"));
        v["error"]["code"].as_str().unwrap().to_string()
    };
    // "the vault folder or its manifest.json is missing"
    let (ok, _, stderr) = wi328_run(&[
        OsStr::new("backup"),
        OsStr::new("--vault"),
        missing.as_os_str(),
        OsStr::new("--dest"),
        dest.as_os_str(),
    ]);
    assert!(!ok, "a backup of a missing vault fails");
    assert_eq!(code_of(&stderr), "internal", "{stderr}");
    // "the `--from` file does not exist"
    let (ok, _, stderr) = wi328_run(&[
        OsStr::new("restore"),
        OsStr::new("--from"),
        missing.as_os_str(),
        OsStr::new("--to"),
        scratch.path().join("restored").as_os_str(),
    ]);
    assert!(!ok, "a restore of a missing file fails");
    assert_eq!(code_of(&stderr), "internal", "{stderr}");
    let section = hosted_section(&wi328_doc(), "the Error codes table", r"error codes");
    let intro = hosted_flat_lower(section.body.split("\n|").next().unwrap());
    assert!(
        intro.contains("manifest.json") && intro.contains("`--from` file does not exist"),
        "the intro gives both examples of `internal`: {intro}"
    );
}

#[test]
fn backups_doc_error_codes_table_names_the_two_fields_of_backup_too_new() {
    let doc = wi328_doc();
    let section = hosted_section(&doc, "the Error codes table", r"error codes");
    let row = wi328_error_row(&section.body, "backup_too_new").join(" | ");
    // The fields the error really carries, read off the error itself.
    let json = memex_core::MemexError::BackupTooNew {
        backup: 7,
        supported: 6,
    }
    .to_error_json();
    let mut fields: Vec<String> = json["error"]
        .as_object()
        .unwrap()
        .keys()
        .filter(|k| *k != "code" && *k != "message")
        .cloned()
        .collect();
    fields.sort();
    assert_eq!(fields, ["schema_version", "supported_schema_version"]);
    for field in fields {
        assert!(
            row.contains(&field),
            "the backup_too_new row names `{field}`: {row}"
        );
    }
    let without_supported = row.replace("supported_schema_version", "");
    assert!(
        without_supported.contains("schema_version"),
        "the backup_too_new row names `schema_version` on its own: {row}"
    );
}

// ---------- links, glossary terms and avoided terms ----------

#[test]
fn backups_doc_uses_glossary_terms_and_none_of_the_avoided_ones() {
    let doc = wi328_doc();
    has_all_terms(
        BACKUPS_DOC,
        &doc,
        &[
            "backup destination",
            "vault server",
            "hosted vault",
            "local vault",
        ],
    );
    assert_no_avoided_terms(BACKUPS_DOC, &doc);
    wi104_assert_no_hosted_avoided_terms(BACKUPS_DOC, &doc);
    // Never "symlink" (a GLOSSARY.md `_Avoid_` term), in prose or in code.
    assert!(
        !doc.to_lowercase().contains("symlink"),
        "no symlink in {BACKUPS_DOC}"
    );
}

#[test]
fn backups_doc_and_hosted_vault_doc_link_each_other_and_every_relative_link_resolves() {
    let doc = wi328_doc();
    let hosted = hosted_vault_doc();
    let link_to = |md: &str, target: &str| {
        Regex::new(&format!(
            r"\]\((\./)?(docs/)?{}(#[^)]*)?\)",
            regex::escape(target)
        ))
        .unwrap()
        .is_match(md)
    };
    assert!(
        link_to(&hosted, "backups.md"),
        "{HOSTED_DOC} links to docs/backups.md"
    );
    assert!(
        link_to(&doc, "hosted-vault.md"),
        "{BACKUPS_DOC} links to docs/hosted-vault.md"
    );
    assert!(
        link_to(&readme(), "backups.md"),
        "README.md links to docs/backups.md"
    );
    let root = repo_root();
    let link = Regex::new(r"\]\(([^)#\s]+)(#[^)]*)?\)").unwrap();
    for c in link.captures_iter(&doc) {
        let target = &c[1];
        if target.contains("://") || target.starts_with("mailto:") {
            continue;
        }
        let path = root.join("docs").join(target);
        assert!(
            path.exists(),
            "{BACKUPS_DOC} links to {target}, which does not exist"
        );
    }
}

#[test]
fn glossary_has_a_backups_section_with_backup_backup_destination_and_restore() {
    let glossary = read_repo_file("GLOSSARY.md");
    let section = hosted_section(&glossary, "the Backups section", r"^backups\b");
    assert_eq!(
        section.level, 2,
        "Backups is a `## ` section: {}",
        section.title
    );
    for term in ["Backup", "Backup destination", "Restore"] {
        let heading = format!("**{term}**:");
        assert_eq!(
            glossary.matches(&heading).count(),
            1,
            "GLOSSARY.md has exactly one {heading} entry"
        );
        let entry = section
            .body
            .split("\n\n")
            .find(|p| p.trim_start().starts_with(&heading))
            .unwrap_or_else(|| panic!("{heading} is in the Backups section"));
        let definition: Vec<&str> = entry
            .lines()
            .skip(1)
            .filter(|l| !l.starts_with("_Avoid_"))
            .collect();
        assert!(
            definition.iter().any(|l| l.trim().len() >= 20),
            "{heading} has a definition: {entry}"
        );
        if term == "Backup" {
            let avoid = entry
                .lines()
                .find(|l| l.starts_with("_Avoid_:"))
                .unwrap_or_else(|| panic!("{heading} has an _Avoid_ line: {entry}"))
                .to_lowercase();
            for avoided in ["snapshot", "export", "sync", "archive"] {
                assert!(
                    avoid.contains(avoided),
                    "Backup avoids `{avoided}`: {avoid}"
                );
            }
        }
    }
}

// ---------- README: commands and the upgrade steps ----------

#[test]
fn readme_lists_memex_backup_and_memex_restore_with_real_flags() {
    let readme = readme();
    let works = hosted_section(&readme, "`What works today`", r"what works today");
    for needle in ["memex backup", "memex restore"] {
        assert!(
            works.body.contains(needle),
            "README.md `What works today` lists `{needle}`"
        );
    }
    assert_commands_are_real("README.md", &readme);
    let seen = wi328_flags_shown("README.md", &readme);
    wi328_assert_flags("README.md", &seen, "backup", &["--vault", "--dest"]);
    wi328_assert_flags("README.md", &seen, "restore", &["--from", "--to"]);
    assert!(
        readme.contains("docs/backups.md"),
        "README.md links docs/backups.md"
    );
}

#[test]
fn readme_upgrade_sections_run_memex_backup_before_the_new_binary_opens_the_vault() {
    let readme = readme();
    for (what, title_re) in [
        ("V5", r"upgrading to schema v5"),
        ("V6", r"upgrading to schema v6"),
    ] {
        let section = hosted_section(&readme, what, title_re).body;
        let backup_at = section
            .find("`memex backup")
            .unwrap_or_else(|| panic!("the {what} section runs `memex backup`:\n{section}"));
        let install_at = section
            .find("cargo install")
            .unwrap_or_else(|| panic!("the {what} section installs the new binary:\n{section}"));
        assert!(
            backup_at < install_at,
            "{what}: `memex backup` comes before the install step:\n{section}"
        );
        for file in ["memex.db-wal", "memex.db-shm"] {
            assert!(
                !section.contains(file),
                "the {what} section no longer lists the manual copy of {file}:\n{section}"
            );
        }
    }
}

#[test]
fn readme_upgrade_sections_cover_an_older_memex_that_has_no_memex_backup() {
    let readme = readme();
    let do_step = Regex::new(r"do step (\d+) first").unwrap();
    for (what, title_re) in [
        ("V5", r"upgrading to schema v5"),
        ("V6", r"upgrading to schema v6"),
    ] {
        let section = hosted_section(&readme, what, title_re).body;
        // The backup step says what to do with a `memex` that predates
        // `memex backup`: do the install step first, then back up, and keep
        // everything closed until the backup is done.
        let step = section
            .lines()
            .find(|l| l.contains("`memex backup"))
            .unwrap_or_else(|| panic!("the {what} section has a backup step:\n{section}"));
        let flat = hosted_flat_lower(step);
        assert!(
            flat.contains("older and has no `memex backup`"),
            "{what}: the backup step covers an older memex without the command: {step}"
        );
        assert!(
            flat.contains("until the backup is done"),
            "{what}: the old-binary case says to wait for the backup: {step}"
        );
        assert!(
            flat.contains("keep everything closed") || flat.contains("do not start the app"),
            "{what}: the old-binary case says to keep the app and clients closed: {step}"
        );
        // "do step N first" points at the step that installs the binary.
        let n = do_step
            .captures(&flat)
            .unwrap_or_else(|| panic!("{what}: the backup step says `do step N first`: {step}"))[1]
            .to_string();
        let install_step = section
            .lines()
            .find(|l| l.starts_with(&format!("{n}. ")))
            .unwrap_or_else(|| panic!("{what}: the section has a step {n}:\n{section}"));
        assert!(
            install_step.contains("cargo install"),
            "{what}: step {n} is the install step: {install_step}"
        );
    }
}

#[test]
fn readme_v6_upgrade_section_keeps_the_quit_clients_and_memex_serve_text() {
    let readme = readme();
    let v6 = hosted_section(&readme, "V6", r"upgrading to schema v6").body;
    let flat = hosted_flat_lower(&v6);
    for phrase in ["quit", "mcp client", "`memex serve`", "first v6 open"] {
        assert!(
            flat.contains(phrase),
            "the V6 section still says `{phrase}`:\n{v6}"
        );
    }
}
